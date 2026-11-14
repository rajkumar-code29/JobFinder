// AI calls for the resume builder: the user's own keys first, then shared keys with a value (only if an admin
// switched shared keys on for them). Tries each model in the chain with each key, like the agents do.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

export class BuilderError extends Error {
  constructor(message: string, public status = 400, public code?: string) {
    super(message);
  }
}

type Provider = "gemini" | "groq" | "openrouter";
const AI_PROVIDERS: Provider[] = ["gemini", "groq", "openrouter"];

export type Key = { provider: Provider; value: string; label: string };

const OPENAI_COMPATIBLE: Record<string, { base: string; headers?: Record<string, string> }> = {
  groq: { base: "https://api.groq.com/openai/v1" },
  openrouter: {
    base: "https://openrouter.ai/api/v1",
    headers: { "HTTP-Referer": "https://jobs.rajkumar.codes", "X-Title": "Pounce" },
  },
};

// keep in sync with the 'builder' default in app/lib/screens/models.dart
export const DEFAULT_CHAIN = ["gemini:flash-lite", "gemini:flash"];
const FALLBACK_MODELS: Record<string, string[]> = {
  "flash": ["gemini-3.5-flash"],
  "flash-lite": ["gemini-3.5-flash-lite"],
};
const MODEL_NAME = /^gemini-(\d+(?:\.\d+)?)-(flash-lite|flash|pro)(?:-(.+))?$/;
const SPECIAL = /tts|image|audio|live|transcribe|robotics|native|embedding|computer/i;

export async function loadKeys(db: SupabaseClient, userId: string, useShared: boolean): Promise<Key[]> {
  const now = new Date().toISOString();
  const later = (k: { exhausted_until: string | null }) => (k.exhausted_until && k.exhausted_until > now ? 1 : 0);
  const { data: own } = await db.from("api_keys")
    .select("provider,key_value,label,priority,exhausted_until,created_at")
    .eq("user_id", userId).in("provider", AI_PROVIDERS)
    .order("priority").order("created_at");
  const keys = [...(own ?? [])].sort((a, b) => later(a) - later(b))
    .map((k) => ({ provider: k.provider as Provider, value: k.key_value as string, label: k.label ?? "" }));
  if (useShared) {
    const { data: shared } = await db.from("shared_api_keys")
      .select("provider,key_value,label,priority,exhausted_until")
      .eq("enabled", true).in("provider", AI_PROVIDERS).not("key_value", "is", null)
      .order("priority");
    for (const k of [...(shared ?? [])].sort((a, b) => later(a) - later(b))) {
      keys.push({ provider: k.provider as Provider, value: k.key_value as string, label: k.label ?? "" });
    }
  }
  return keys.filter((k) => k.value);
}

export async function loadChain(db: SupabaseClient): Promise<string[]> {
  const { data } = await db.from("model_routing").select("chain").eq("agent", "builder").maybeSingle();
  return (data?.chain as string[] | undefined)?.length ? data!.chain : DEFAULT_CHAIN;
}

// Gemini model list, newest stable first, cached while the function instance stays warm
let discovered: { at: number; models: Record<string, string[]> } | null = null;

function rank(name: string): number[] {
  const m = MODEL_NAME.exec(name)!;
  const suffix = m[3] ?? "";
  return [suffix === "" || suffix === "latest" ? 1 : 0, parseFloat(m[1]), suffix === "" ? 1 : 0];
}

async function geminiModels(key: string): Promise<Record<string, string[]>> {
  if (discovered && Date.now() - discovered.at < 3600_000) return discovered.models;
  const found: Record<string, string[]> = { "flash": [], "flash-lite": [] };
  try {
    const r = await fetch("https://generativelanguage.googleapis.com/v1beta/models?pageSize=200", {
      headers: { "x-goog-api-key": key },
      signal: AbortSignal.timeout(10_000),
    });
    if (r.ok) {
      const body = await r.json();
      for (const m of body.models ?? []) {
        const name = String(m.name ?? "").replace(/^models\//, "");
        const family = MODEL_NAME.exec(name)?.[2];
        const actions: string[] = m.supportedGenerationMethods ?? [];
        if (family && family in found && !SPECIAL.test(name) && (!actions.length || actions.includes("generateContent"))) {
          found[family].push(name);
        }
      }
    }
  } catch (_) {
    // fall back to the defaults below
  }
  for (const family of Object.keys(found)) {
    const names = found[family].sort((a, b) => {
      const ra = rank(a), rb = rank(b);
      for (let i = 0; i < ra.length; i++) if (ra[i] !== rb[i]) return rb[i] - ra[i];
      return 0;
    });
    found[family] = names.some((n) => rank(n)[0]) ? names.filter((n) => rank(n)[0]) : names;
    if (!found[family].length) found[family] = FALLBACK_MODELS[family];
  }
  discovered = { at: Date.now(), models: found };
  return found;
}

async function expand(chain: string[], keys: Key[]): Promise<[Provider, string][]> {
  const out: [Provider, string][] = [];
  const geminiKey = keys.find((k) => k.provider === "gemini");
  for (const spec of chain) {
    const i = spec.indexOf(":");
    const provider = spec.slice(0, i) as Provider;
    const model = spec.slice(i + 1);
    if (!model || !keys.some((k) => k.provider === provider)) continue;
    if (provider === "gemini" && (model === "flash" || model === "flash-lite")) {
      const models = geminiKey ? (await geminiModels(geminiKey.value))[model] : FALLBACK_MODELS[model];
      for (const m of models.slice(0, 2)) out.push(["gemini", m]);
    } else if (provider === "gemini" || provider in OPENAI_COMPATIBLE) {
      out.push([provider, model]);
    }
  }
  // anything usable if the chain had nothing for this user's keys
  if (!out.length) {
    if (geminiKey) out.push(["gemini", (await geminiModels(geminiKey.value))["flash-lite"][0]]);
    if (keys.some((k) => k.provider === "groq")) out.push(["groq", "openai/gpt-oss-120b"]);
  }
  return out.filter(([p, m], idx) => out.findIndex(([p2, m2]) => p2 === p && m2 === m) === idx);
}

class CallError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

async function call(provider: Provider, key: string, model: string, system: string, prompt: string,
  pdf: string | null, temperature: number): Promise<string> {
  if (provider === "gemini") {
    const parts: unknown[] = [{ text: prompt }];
    if (pdf) parts.push({ inline_data: { mime_type: "application/pdf", data: pdf } });
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: "POST",
      headers: { "x-goog-api-key": key, "Content-Type": "application/json" },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: system }] },
        contents: [{ role: "user", parts }],
        generationConfig: { temperature, maxOutputTokens: 8192, responseMimeType: "application/json" },
      }),
      signal: AbortSignal.timeout(70_000),
    });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new CallError(r.status, body?.error?.message ?? r.statusText);
    const text = (body.candidates?.[0]?.content?.parts ?? []).map((p: { text?: string }) => p.text ?? "").join("");
    if (!text) throw new CallError(502, `empty answer (${body.candidates?.[0]?.finishReason ?? "no candidates"})`);
    return text;
  }
  const cfg = OPENAI_COMPATIBLE[provider];
  const r = await fetch(`${cfg.base}/chat/completions`, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", ...(cfg.headers ?? {}) },
    body: JSON.stringify({
      model,
      messages: [{ role: "system", content: system }, { role: "user", content: prompt }],
      temperature,
      max_tokens: 8192,
      response_format: { type: "json_object" },
    }),
    signal: AbortSignal.timeout(70_000),
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new CallError(r.status, body?.error?.message ?? r.statusText);
  const text = body.choices?.[0]?.message?.content ?? "";
  if (!text) throw new CallError(502, "empty answer");
  return text;
}

export function parseJson(text: string): Record<string, unknown> {
  const clean = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/, "");
  try {
    return JSON.parse(clean);
  } catch (_) {
    const start = clean.indexOf("{"), end = clean.lastIndexOf("}");
    if (start >= 0 && end > start) return JSON.parse(clean.slice(start, end + 1));
    throw new Error("the answer wasn't valid JSON");
  }
}

export type AskOptions = { pdf?: string | null; temperature?: number };

/** Runs the prompt through the chain until a model returns valid JSON. */
export async function askJson(keys: Key[], chain: string[], system: string, prompt: string,
  opts: AskOptions = {}): Promise<{ data: Record<string, unknown>; model: string }> {
  const pdf = opts.pdf ?? null;
  const usable = pdf ? keys.filter((k) => k.provider === "gemini") : keys;
  if (!usable.length) {
    throw new BuilderError(pdf
      ? "Reading a PDF needs a Gemini key. Add one in Settings > API keys, or upload the resume as a .docx"
      : "Add an AI key (Gemini, Groq or OpenRouter) in Settings > API keys first", 400, "no_key");
  }
  const deadline = Date.now() + 130_000;
  const problems: string[] = [];
  let rateLimited = 0;
  for (const [provider, model] of await expand(chain, usable)) {
    for (const key of usable.filter((k) => k.provider === provider)) {
      if (Date.now() > deadline) break;
      try {
        const text = await call(provider, key.value, model, system, prompt, pdf, opts.temperature ?? 0.7);
        return { data: parseJson(text), model: `${provider}:${model}` };
      } catch (e) {
        const status = e instanceof CallError ? e.status : 0;
        problems.push(`${model}: ${status || ""} ${(e as Error).message}`.slice(0, 200));
        if (status === 429) {
          rateLimited++;
          continue; // next key, same model
        }
        if (status === 401 || status === 403 || (status === 400 && /api key/i.test((e as Error).message))) continue;
        break; // overloaded, retired, too large or bad JSON: next model
      }
    }
  }
  if (rateLimited && rateLimited === problems.length) {
    throw new BuilderError("Your AI keys are rate-limited right now. Wait a minute and try again.", 429, "rate_limited");
  }
  console.error("all models failed", problems);
  throw new BuilderError(`The AI couldn't do this right now (${problems.slice(-1)[0] ?? "no model available"}). Try again in a minute.`, 502, "ai_failed");
}

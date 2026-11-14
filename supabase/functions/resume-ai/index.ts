// resume-ai: the AI behind the Resume builder page.
//   {action: "cv", ...}      write or rewrite CV sections from the user's answers
//   {action: "parse", ...}   read an existing resume (uploaded file or the master resume) into answers
//   {action: "letter", ...}  write or rewrite cover letter parts from a CV
// Deployed with --no-verify-jwt; the user is checked here instead (works with the new API keys).
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { askJson, BuilderError, type Key, loadChain, loadKeys } from "./llm.ts";
import { fromBase64, masterResume, readResume, type ResumeSource } from "./files.ts";
import { cleanAnswers, cleanSection, obj, str } from "./clean.ts";
import {
  CV_SYSTEM, CV_TYPES, cvPrompt, LETTER_PARTS, LETTER_SYSTEM, letterPrompt, PARSE_SYSTEM, parsePrompt,
  SECTION_GUIDE, TARGETS,
} from "./prompts.ts";

const DAILY_LIMIT = Number(Deno.env.get("BUILDER_DAILY_LIMIT") ?? "60");

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

type Ctx = { db: SupabaseClient; uid: string; keys: Key[]; chain: string[]; body: Record<string, unknown> };

async function resumeFrom(ctx: Ctx): Promise<ResumeSource | null> {
  const b = ctx.body;
  if (typeof b.file_b64 === "string" && b.file_b64) {
    return readResume(String(b.filename ?? "resume.docx"), fromBase64(b.file_b64));
  }
  if (typeof b.resume_text === "string" && b.resume_text.trim().length > 80) {
    return { text: b.resume_text, pdf: null, name: "draft" };
  }
  return await masterResume(ctx.db, ctx.uid);
}

async function cv(ctx: Ctx) {
  const b = ctx.body;
  const layout = (Array.isArray(b.sections) ? b.sections : []).map(obj)
    .map((s) => ({ key: str(s.key), guide: str(s.guide) || str(s.key) }))
    .filter((s) => s.key && SECTION_GUIDE[s.guide]);
  if (!layout.length) throw new BuilderError("Nothing to write: fill in some answers first");
  const target = str(b.target), cvType = str(b.cv_type);
  if (!TARGETS[target] || !CV_TYPES[cvType]) throw new BuilderError("Pick what the CV is for first");
  const current = obj(b.current), notes = obj(b.notes);
  const prompt = cvPrompt({
    target, cvType, role: str(b.role), jobAd: str(b.job_ad), answers: b.answers ?? {},
    sections: layout,
    notes: Object.fromEntries(Object.entries(notes).map(([k, v]) => [k, str(v)])),
    current,
  });
  const { data, model } = await askJson(ctx.keys, ctx.chain, CV_SYSTEM, prompt,
    { temperature: Object.keys(current).length ? 0.9 : 0.7 });
  const sections = obj(data.sections);
  const out: Record<string, unknown> = {};
  for (const { key } of layout) out[key] = cleanSection(sections[key]);
  return { sections: out, model };
}

async function parse(ctx: Ctx) {
  const source = await resumeFrom(ctx);
  if (!source) throw new BuilderError("Upload your resume first", 400, "no_resume");
  const { data, model } = await askJson(ctx.keys, ctx.chain, PARSE_SYSTEM, parsePrompt(source.text, str(ctx.body.role)),
    { pdf: source.pdf, temperature: 0.1 });
  return { answers: cleanAnswers(data), model, source: source.name };
}

async function letter(ctx: Ctx) {
  const b = ctx.body;
  const inputs = Object.fromEntries(Object.entries(obj(b.inputs)).map(([k, v]) => [k, str(v)]));
  if (!inputs.job_title || !inputs.company) throw new BuilderError("Add the job title and the organisation");
  const parts = (Array.isArray(b.parts) && b.parts.length ? b.parts : Object.keys(LETTER_PARTS))
    .map(str).filter((p) => LETTER_PARTS[p]);
  const source = await resumeFrom(ctx);
  if (!source) throw new BuilderError("Upload your resume first, the letter is built from it", 400, "no_resume");
  const current = Object.fromEntries(Object.entries(obj(b.current)).map(([k, v]) => [k, str(v)]));
  const notes = Object.fromEntries(Object.entries(obj(b.notes)).map(([k, v]) => [k, str(v)]));
  const { data, model } = await askJson(ctx.keys, ctx.chain, LETTER_SYSTEM,
    letterPrompt({ inputs, resumeText: source.text, parts, notes, current }),
    { pdf: source.pdf, temperature: Object.keys(current).length ? 0.9 : 0.7 });
  const got = obj(data.parts);
  return { parts: Object.fromEntries(parts.map((p) => [p, str(got[p])])), model };
}

const ACTIONS: Record<string, (ctx: Ctx) => Promise<Record<string, unknown>>> = { cv, parse, letter };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply(405, { error: "POST only" });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: auth, error: authError } = await db.auth.getUser(token);
  if (authError || !auth?.user) return reply(401, { error: "Please sign in again" });
  const uid = auth.user.id;

  const { data: account } = await db.from("accounts").select("status,enabled,use_shared_keys")
    .eq("user_id", uid).maybeSingle();
  if (!account || (account.status ?? "approved") !== "approved") {
    return reply(403, { error: "Your account needs to be approved first" });
  }

  let body: Record<string, unknown>;
  try {
    body = obj(await req.json());
  } catch (_) {
    return reply(400, { error: "Bad request" });
  }
  const action = ACTIONS[str(body.action)];
  if (!action) return reply(400, { error: "Unknown action" });

  const since = new Date(Date.now() - 24 * 3600_000).toISOString();
  const { count } = await db.from("builder_usage").select("id", { count: "exact", head: true })
    .eq("user_id", uid).gte("at", since);
  if ((count ?? 0) >= DAILY_LIMIT) {
    return reply(429, {
      error: `That's the ${DAILY_LIMIT} AI requests for today. Try again tomorrow, or edit the text yourself.`,
      code: "daily_limit",
    });
  }

  const keys = await loadKeys(db, uid, !!account.use_shared_keys);
  const ctx: Ctx = { db, uid, keys, chain: await loadChain(db), body };
  try {
    const result = await action(ctx);
    await db.from("builder_usage").insert({ user_id: uid, action: str(body.action), model: result.model, ok: true });
    return reply(200, { ...result, used_today: (count ?? 0) + 1, daily_limit: DAILY_LIMIT });
  } catch (e) {
    const known = e instanceof BuilderError;
    const message = known ? e.message : "Something went wrong on our side. Try again.";
    if (!known) console.error(e);
    // only failed AI calls count towards the limit, not missing input
    if (!known || ["ai_failed", "rate_limited"].includes(e.code ?? "")) {
      await db.from("builder_usage").insert({ user_id: uid, action: str(body.action), ok: false, error: message.slice(0, 500) });
    }
    return reply(known ? e.status : 500, { error: message, code: known ? e.code : "server" });
  }
});

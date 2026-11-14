// deno test --no-lock supabase/functions/tests/
import { strict as nodeAssert } from "node:assert";

const assert = (ok: unknown, msg?: string) => nodeAssert.ok(ok, msg);
const assertEquals = (a: unknown, b: unknown) => nodeAssert.deepStrictEqual(a, b);
async function assertRejects(fn: () => Promise<unknown>, type: typeof BuilderError): Promise<BuilderError> {
  try {
    await fn();
  } catch (e) {
    nodeAssert.ok(e instanceof type, `expected ${type.name}, got ${e}`);
    return e as BuilderError;
  }
  throw new Error("expected a rejection");
}
import { strToU8, zipSync } from "npm:fflate@0.8.2";
import { cleanAnswers, cleanSection } from "../resume-ai/clean.ts";
import { docxText, readResume } from "../resume-ai/files.ts";
import { askJson, BuilderError, type Key, parseJson } from "../resume-ai/llm.ts";
import { cvPrompt, letterPrompt, parsePrompt } from "../resume-ai/prompts.ts";

Deno.test("cleanSection keeps the shape and drops empties", () => {
  const s = cleanSection({
    heading: " Marketing Experience ",
    paragraphs: "Final year student — looking for a role",
    entries: [{ title: "Intern", org: "Acme", bullets: ["Ran campaigns", ""], lines: null }, { title: "" }],
    groups: [{ label: "Tech", text: "SQL" }, {}],
  });
  assertEquals(s.heading, "Marketing Experience");
  assertEquals(s.paragraphs, ["Final year student, looking for a role"]);
  assertEquals((s.entries as unknown[]).length, 1);
  assertEquals((s.groups as unknown[]).length, 1);
  assertEquals(s.bullets, []);
});

Deno.test("cleanAnswers fixes unknown experience kinds", () => {
  const a = cleanAnswers({ experience: [{ kind: "paid", title: "Barista" }, { kind: "volunteering", title: "Scout leader" }] });
  assertEquals(a.experience.map((e) => e.kind), ["other", "volunteering"]);
  assertEquals(a.contact.name, "");
});

Deno.test("parseJson copes with fences and chatter", () => {
  assertEquals(parseJson('```json\n{"a": 1}\n```'), { a: 1 });
  assertEquals(parseJson('Here you go: {"a": {"b": 2}} hope that helps'), { a: { b: 2 } });
});

Deno.test("docxText reads paragraphs, tabs and entities", () => {
  const xml = `<w:document><w:body><w:p><w:r><w:t>Jane Smith</w:t></w:r></w:p>` +
    `<w:p><w:r><w:t>Barista</w:t></w:r><w:r><w:tab/><w:t>2023 &amp; 2024</w:t></w:r></w:p></w:body></w:document>`;
  const bytes = zipSync({ "word/document.xml": strToU8(xml), "[Content_Types].xml": strToU8("<Types/>") });
  assertEquals(docxText(bytes), "Jane Smith\nBarista\t2023 & 2024");
  assertEquals(readResume("cv.pdf", new Uint8Array([37, 80, 68, 70])).pdf, "JVBERg==");
});

Deno.test("prompts carry the material", () => {
  const p = cvPrompt({
    target: "part_time", cvType: "part_time", role: "Retail assistant", jobAd: "", answers: { about: "Student" },
    sections: [{ key: "profile", guide: "profile" }], notes: {}, current: {},
  });
  assert(p.includes("part-time job") && p.includes("Retail assistant") && p.includes("- profile:"));
  assert(parsePrompt(null, "").includes("attached PDF"));
  assert(letterPrompt({ inputs: { job_title: "Analyst", company: "Acme" }, resumeText: "CV text", parts: ["opening"], notes: {}, current: {} })
    .includes("speculative"));
});

// fake providers
type Handler = (url: string, init: RequestInit) => Response;
function withFetch(handler: Handler, fn: () => Promise<void>) {
  return async () => {
    const real = globalThis.fetch;
    globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) =>
      Promise.resolve(handler(String(input instanceof Request ? input.url : input), init ?? {}))) as typeof fetch;
    try {
      await fn();
    } finally {
      globalThis.fetch = real;
    }
  };
}
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status });
const models = {
  models: [
    { name: "models/gemini-3.5-flash-lite", supportedGenerationMethods: ["generateContent"] },
    { name: "models/gemini-3.6-flash-lite", supportedGenerationMethods: ["generateContent"] },
    { name: "models/gemini-3.7-flash-lite-preview-11-2026", supportedGenerationMethods: ["generateContent"] },
    { name: "models/gemini-3.6-flash", supportedGenerationMethods: ["generateContent"] },
    { name: "models/gemini-3.6-flash-image", supportedGenerationMethods: ["generateContent"] },
  ],
};
const answer = (obj: unknown) => json(200, { candidates: [{ content: { parts: [{ text: JSON.stringify(obj) }] } }] });
const gemini: Key[] = [{ provider: "gemini", value: "k1", label: "" }, { provider: "gemini", value: "k2", label: "" }];

Deno.test("429 on one key moves to the next key, newest stable model first", withFetch((url, init) => {
  if (url.includes("/models?")) return json(200, models);
  const key = (init.headers as Record<string, string>)["x-goog-api-key"];
  assert(url.includes("gemini-3.6-flash-lite:generateContent"), url);
  return key === "k1" ? json(429, { error: { message: "quota" } }) : answer({ ok: true });
}, async () => {
  const r = await askJson(gemini, ["gemini:flash-lite", "gemini:flash"], "sys", "prompt");
  assertEquals(r.data, { ok: true });
  assertEquals(r.model, "gemini:gemini-3.6-flash-lite");
}));

Deno.test("503 and bad JSON move to the next model", withFetch((url) => {
  if (url.includes("gemini-3.6-flash-lite:")) return json(503, { error: { message: "overloaded" } });
  if (url.includes("gemini-3.5-flash-lite:")) return json(200, { candidates: [{ content: { parts: [{ text: "not json" }] } }] });
  if (url.includes("gemini-3.6-flash:")) return answer({ ok: 2 });
  return json(404, {});
}, async () => {
  const r = await askJson(gemini, ["gemini:flash-lite", "gemini:flash"], "sys", "prompt");
  assertEquals(r.model, "gemini:gemini-3.6-flash");
}));

Deno.test("all keys rate-limited gives a clear error", withFetch(() => json(429, { error: { message: "quota" } }), async () => {
  const e = await assertRejects(() => askJson(gemini, ["gemini:flash-lite"], "s", "p"), BuilderError);
  assertEquals(e.code, "rate_limited");
}));

Deno.test("a PDF needs a Gemini key", async () => {
  const e = await assertRejects(
    () => askJson([{ provider: "groq", value: "g", label: "" }], ["groq:x"], "s", "p", { pdf: "JVBE" }), BuilderError);
  assertEquals(e.code, "no_key");
});

Deno.test("groq is called the OpenAI way", withFetch((url, init) => {
  assert(url.startsWith("https://api.groq.com/openai/v1/chat/completions"));
  const body = JSON.parse(String(init.body));
  assertEquals(body.response_format, { type: "json_object" });
  return json(200, { choices: [{ message: { content: '{"done": true}' } }] });
}, async () => {
  const r = await askJson([{ provider: "groq", value: "g", label: "" }], ["groq:openai/gpt-oss-120b"], "s", "p");
  assertEquals(r.data, { done: true });
}));

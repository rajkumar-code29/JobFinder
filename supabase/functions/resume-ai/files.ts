// Reading resumes: .docx is unzipped and its text pulled out here; PDFs are passed to Gemini as they are.
import { strFromU8, unzipSync } from "npm:fflate@0.8.2";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { BuilderError } from "./llm.ts";

const ENTITIES: Record<string, string> = { "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&apos;": "'" };

export function docxText(bytes: Uint8Array): string {
  let files: Record<string, Uint8Array>;
  try {
    files = unzipSync(bytes, { filter: (f) => f.name === "word/document.xml" });
  } catch (_) {
    throw new BuilderError("That file isn't a readable .docx");
  }
  const xml = files["word/document.xml"];
  if (!xml) throw new BuilderError("That file isn't a readable .docx");
  return strFromU8(xml)
    .replace(/<w:tab\/>/g, "\t")
    .replace(/<w:br[^>]*\/>/g, "\n")
    .replace(/<\/w:p>/g, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&(amp|lt|gt|quot|apos);/g, (m) => ENTITIES[m])
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export function fromBase64(b64: string): Uint8Array {
  const binary = atob(b64);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

export type ResumeSource = { text: string | null; pdf: string | null; name: string };

/** A resume either as text (docx/txt) or as base64 PDF for Gemini. */
export function readResume(name: string, bytes: Uint8Array): ResumeSource {
  const lower = name.toLowerCase();
  if (bytes.length > 8 * 1024 * 1024) throw new BuilderError("That file is over 8 MB");
  if (lower.endsWith(".docx")) {
    const text = docxText(bytes);
    if (text.length < 80) throw new BuilderError("Couldn't find much text in that .docx");
    return { text, pdf: null, name };
  }
  if (lower.endsWith(".pdf")) return { text: null, pdf: base64(bytes), name };
  if (lower.endsWith(".txt")) return { text: new TextDecoder().decode(bytes), pdf: null, name };
  throw new BuilderError("Upload the resume as .docx or .pdf");
}

/** The user's master resume from storage (parent/<uid>/resume), .docx preferred. */
export async function masterResume(db: SupabaseClient, userId: string): Promise<ResumeSource | null> {
  const { data: files } = await db.storage.from("parent").list(`${userId}/resume`);
  const pick = (files ?? []).filter((f) => f.id)
    .sort((a, b) => (a.name.toLowerCase().endsWith(".docx") ? 0 : 1) - (b.name.toLowerCase().endsWith(".docx") ? 0 : 1))[0];
  if (!pick) return null;
  const { data, error } = await db.storage.from("parent").download(`${userId}/resume/${pick.name}`);
  if (error || !data) return null;
  return readResume(pick.name, new Uint8Array(await data.arrayBuffer()));
}

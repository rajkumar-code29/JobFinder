import { strict as assert } from "node:assert";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { deleteFiles, listAll } from "../account/index.ts";

// a fake bucket: folder -> entries (id null = sub-folder)
function fakeDb(tree: Record<string, Record<string, { name: string; id: string | null }[]>>, removed: string[]) {
  return {
    storage: {
      from: (bucket: string) => ({
        list: (folder: string) => Promise.resolve({ data: tree[bucket]?.[folder] ?? [], error: null }),
        remove: (paths: string[]) => {
          removed.push(...paths.map((p) => `${bucket}:${p}`));
          return Promise.resolve({ data: [], error: null });
        },
      }),
    },
  } as unknown as SupabaseClient;
}

const tree = {
  parent: {
    "u1": [{ name: "resume", id: null }, { name: "cover_letter", id: null }],
    "u1/resume": [{ name: "CV.docx", id: "a" }, { name: "CV.pdf", id: "b" }],
    "u1/cover_letter": [{ name: "Letter.docx", id: "c" }],
  },
  jobs: {
    "u1": [{ name: "JF-1", id: null }],
    "u1/JF-1": [{ name: "report.json", id: "d" }],
  },
};

Deno.test("listAll walks sub-folders", async () => {
  assert.deepStrictEqual(await listAll(fakeDb(tree, []), "parent", "u1"),
    ["u1/resume/CV.docx", "u1/resume/CV.pdf", "u1/cover_letter/Letter.docx"]);
});

Deno.test("deleteFiles removes everything in both buckets and nothing of other users", async () => {
  const removed: string[] = [];
  const n = await deleteFiles(fakeDb(tree, removed), "u1");
  assert.equal(n, 4);
  assert.deepStrictEqual(removed.sort(), [
    "jobs:u1/JF-1/report.json", "parent:u1/cover_letter/Letter.docx", "parent:u1/resume/CV.docx", "parent:u1/resume/CV.pdf",
  ]);
  assert.equal(await deleteFiles(fakeDb(tree, []), "u2"), 0);
});

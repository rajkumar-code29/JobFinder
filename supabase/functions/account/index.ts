// account: things a user does to their own account that need the service key.
//   {action: "delete"}  deletes their files, then the user; every table cascades from auth.users.
// Deployed with --no-verify-jwt; the user is checked here.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

/** Every object under a folder, however deep. */
export async function listAll(db: SupabaseClient, bucket: string, folder: string): Promise<string[]> {
  const out: string[] = [];
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await db.storage.from(bucket).list(folder, { limit: 1000, offset });
    if (error) throw error;
    for (const item of data ?? []) {
      const path = `${folder}/${item.name}`;
      if (item.id) out.push(path);
      else out.push(...await listAll(db, bucket, path)); // a folder
    }
    if (!data || data.length < 1000) break;
  }
  return out;
}

export async function deleteFiles(db: SupabaseClient, userId: string): Promise<number> {
  let removed = 0;
  for (const bucket of ["parent", "jobs"]) {
    const paths = await listAll(db, bucket, userId);
    for (let i = 0; i < paths.length; i += 100) {
      const { error } = await db.storage.from(bucket).remove(paths.slice(i, i + 100));
      if (error) throw error;
    }
    removed += paths.length;
  }
  return removed;
}

if (import.meta.main) {
  Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
    if (req.method !== "POST") return reply(405, { error: "POST only" });

    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: auth, error: authError } = await db.auth.getUser(token);
    if (authError || !auth?.user) return reply(401, { error: "Please sign in again" });

    let body: Record<string, unknown> = {};
    try {
      body = await req.json();
    } catch (_) {
      // empty body
    }
    if (body.action !== "delete") return reply(400, { error: "Unknown action" });
    if (body.confirm !== "DELETE") return reply(400, { error: "Type DELETE to confirm" });

    const uid = auth.user.id;
    try {
      const files = await deleteFiles(db, uid);
      const { error } = await db.auth.admin.deleteUser(uid);
      if (error) throw error;
      console.log(`deleted account ${uid} with ${files} files`);
      return reply(200, { deleted: true, files });
    } catch (e) {
      console.error("account deletion failed", uid, e);
      return reply(500, { error: "Couldn't delete the account. Try again, or email the support address in Privacy." });
    }
  });
}

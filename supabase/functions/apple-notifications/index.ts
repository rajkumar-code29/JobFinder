// apple-notifications: App Store Server Notifications (version 2). On a refund or revocation the transaction is
// looked up with Apple's API (so a forged notification can't do anything) and the credits are taken back.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { type AppleConfig, type AppleTransaction, appleConfig, fetchAppleTransaction, jwsPayload } from "../_shared/payments.ts";

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ error: unknown }>;

export async function handleNotification(signedPayload: string, cfg: AppleConfig, rpc: Rpc,
  lookup: (id: string) => Promise<AppleTransaction | null> = (id) => fetchAppleTransaction(cfg, id)): Promise<string> {
  const note = jwsPayload<{ notificationType?: string; data?: { signedTransactionInfo?: string; bundleId?: string } }>(signedPayload);
  if (!["REFUND", "REVOKE"].includes(note.notificationType ?? "")) return `ignored ${note.notificationType}`;
  const claimed = note.data?.signedTransactionInfo ? jwsPayload<AppleTransaction>(note.data.signedTransactionInfo) : null;
  if (!claimed?.transactionId) return "no transaction";
  const t = await lookup(claimed.transactionId); // what Apple says, not what the notification says
  if (!t || t.bundleId !== cfg.bundleId || !t.revocationDate) return `not revoked: ${claimed.transactionId}`;
  const { error } = await rpc("refund_purchase", { p_source: "apple", p_ref: t.transactionId });
  if (error) throw error;
  return `refunded ${t.transactionId}`;
}

if (import.meta.main) {
  Deno.serve(async (req) => {
    if (req.method !== "POST") return new Response("POST only", { status: 405 });
    const cfg = appleConfig();
    if (!cfg) return new Response("not configured", { status: 503 });
    let body: Record<string, unknown> = {};
    try {
      body = await req.json();
    } catch (_) {
      return new Response("bad request", { status: 400 });
    }
    if (typeof body.signedPayload !== "string") return new Response("bad request", { status: 400 });
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    try {
      console.log(await handleNotification(body.signedPayload, cfg,
        (fn, args) => db.rpc(fn, args) as unknown as Promise<{ error: unknown }>));
      return new Response("ok");
    } catch (e) {
      console.error("apple notification failed", e);
      return new Response("failed, retry", { status: 500 }); // Apple retries
    }
  });
}

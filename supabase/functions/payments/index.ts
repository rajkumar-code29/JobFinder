// payments: buying credits from the app.
//   {action: "checkout", pack}                     -> a Stripe Checkout page (website and Android)
//   {action: "apple", transaction_id, product_id}  -> checks an App Store purchase with Apple, then adds the credits
// Deployed with --no-verify-jwt; the user is checked here. Secrets: STRIPE_SECRET_KEY, APPLE_IAP_ISSUER_ID,
// APPLE_IAP_KEY_ID, APPLE_IAP_PRIVATE_KEY (optional APPLE_BUNDLE_ID, SITE_URL).
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { type AppleTransaction, appleConfig, fetchAppleTransaction, packForAppleProduct, PACKS } from "../_shared/payments.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

export async function stripeCheckout(opts: {
  secret: string; site: string; userId: string; email: string; pack: string; fetcher?: typeof fetch;
}): Promise<string> {
  const p = PACKS[opts.pack];
  const form = new URLSearchParams({
    "mode": "payment",
    "line_items[0][quantity]": "1",
    "line_items[0][price_data][currency]": "gbp",
    "line_items[0][price_data][unit_amount]": String(p.amount),
    "line_items[0][price_data][product_data][name]": `${p.credits} Pounce credits`,
    "line_items[0][price_data][product_data][description]": "Tailored resumes, cover letters and interview prep: 1 credit each",
    "success_url": `${opts.site}/credits?paid=1`,
    "cancel_url": `${opts.site}/credits`,
    "client_reference_id": opts.userId,
    "customer_email": opts.email,
    "metadata[user_id]": opts.userId,
    "metadata[pack]": opts.pack,
    "metadata[credits]": String(p.credits),
    "payment_intent_data[metadata][user_id]": opts.userId,
    "payment_intent_data[metadata][pack]": opts.pack,
  });
  const r = await (opts.fetcher ?? fetch)("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: { Authorization: `Bearer ${opts.secret}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: form,
    signal: AbortSignal.timeout(20_000),
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok || !body.url) throw new Error(`Stripe ${r.status}: ${body?.error?.message ?? "no checkout url"}`);
  return body.url;
}

/** Whether an Apple transaction may be turned into credits for this user. Returns the pack, or why not. */
export function checkAppleTransaction(t: AppleTransaction | null, bundleId: string, userId: string):
  { pack: string; credits: number; amount: number } | { error: string } {
  if (!t) return { error: "Apple doesn't know this purchase" };
  if (t.bundleId !== bundleId) return { error: "This purchase is for a different app" };
  if (t.revocationDate) return { error: "This purchase was refunded" };
  if (t.appAccountToken && t.appAccountToken.toLowerCase() !== userId.toLowerCase()) {
    return { error: "This purchase belongs to a different account" };
  }
  const hit = packForAppleProduct(t.productId);
  if (!hit) return { error: "Unknown product" };
  return { pack: hit[0], credits: hit[1].credits, amount: hit[1].amount };
}

async function grant(db: SupabaseClient, args: Record<string, unknown>) {
  const { data, error } = await db.rpc("grant_purchase", args);
  if (error) throw error;
  return data as { granted: boolean; balance: number };
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
    const user = auth.user;
    const { data: account } = await db.from("accounts").select("status").eq("user_id", user.id).maybeSingle();
    if (!account || account.status !== "approved" || !user.email_confirmed_at) {
      return reply(403, { error: "Your account needs to be verified first" });
    }
    let body: Record<string, unknown> = {};
    try {
      body = await req.json();
    } catch (_) {
      return reply(400, { error: "Bad request" });
    }

    try {
      if (body.action === "checkout") {
        const pack = String(body.pack ?? "");
        if (!PACKS[pack]) return reply(400, { error: "Pick a pack" });
        const secret = Deno.env.get("STRIPE_SECRET_KEY");
        if (!secret) return reply(503, { error: "Buying credits isn't switched on yet" });
        const url = await stripeCheckout({
          secret, site: Deno.env.get("SITE_URL") ?? "https://jobs.rajkumar.codes", userId: user.id,
          email: user.email ?? "", pack,
        });
        return reply(200, { url });
      }

      if (body.action === "apple") {
        const cfg = appleConfig();
        if (!cfg) return reply(503, { error: "App Store purchases aren't switched on yet" });
        const txId = String(body.transaction_id ?? "");
        const t = await fetchAppleTransaction(cfg, txId);
        const ok = checkAppleTransaction(t, cfg.bundleId, user.id);
        if ("error" in ok) {
          // permanent: the app finishes the transaction so StoreKit stops offering it again
          return reply(400, { error: ok.error, code: "rejected" });
        }
        const result = await grant(db, {
          p_user: user.id, p_source: "apple", p_ref: t!.transactionId, p_pack: ok.pack,
          p_credits: ok.credits, p_amount: t!.price != null ? Math.round(t!.price / 10) : null,
          p_currency: t!.currency ?? null, p_environment: (t!.environment ?? "Production").toLowerCase(),
        });
        return reply(200, { ...result, credits: ok.credits });
      }
      return reply(400, { error: "Unknown action" });
    } catch (e) {
      console.error("payments failed", e);
      return reply(502, { error: "The payment service didn't answer. Try again in a minute." });
    }
  });
}

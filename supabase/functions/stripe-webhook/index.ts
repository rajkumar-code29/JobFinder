// stripe-webhook: Stripe tells us about payments here. Every request's signature is checked with
// STRIPE_WEBHOOK_SECRET; a paid Checkout session adds the credits (once), a refunded charge takes them back.
// Events to send: checkout.session.completed, checkout.session.async_payment_succeeded, charge.refunded.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.45.4";
import { PACKS, verifyStripeSignature } from "../_shared/payments.ts";

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ error: unknown }>;

/** What to do for one verified event. Returns a short note for the log. */
export async function handleEvent(event: Record<string, any>, rpc: Rpc): Promise<string> {
  const obj = event?.data?.object ?? {};
  switch (event.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded": {
      if (obj.payment_status !== "paid") return `session ${obj.id} not paid yet`;
      const userId = obj.metadata?.user_id ?? obj.client_reference_id;
      const pack = obj.metadata?.pack;
      if (!userId || !PACKS[pack]) return `session ${obj.id} has no user or pack`;
      const { error } = await rpc("grant_purchase", {
        p_user: userId, p_source: "stripe", p_ref: obj.id, p_pack: pack, p_credits: PACKS[pack].credits,
        p_amount: obj.amount_total ?? null, p_currency: obj.currency ?? null,
        p_payment_intent: typeof obj.payment_intent === "string" ? obj.payment_intent : obj.payment_intent?.id ?? null,
        p_environment: obj.livemode === false ? "test" : "production",
      });
      if (error) throw error;
      return `granted ${pack} for ${obj.id}`;
    }
    case "charge.refunded": {
      const intent = typeof obj.payment_intent === "string" ? obj.payment_intent : obj.payment_intent?.id;
      if (!intent) return "refund without a payment intent";
      const { error } = await rpc("refund_purchase", { p_source: "stripe", p_payment_intent: intent });
      if (error) throw error;
      return `refunded ${intent}`;
    }
    default:
      return `ignored ${event.type}`;
  }
}

if (import.meta.main) {
  Deno.serve(async (req) => {
    if (req.method !== "POST") return new Response("POST only", { status: 405 });
    const raw = await req.text();
    const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
    if (!(await verifyStripeSignature(raw, req.headers.get("Stripe-Signature"), secret))) {
      return new Response("bad signature", { status: 400 });
    }
    const db: SupabaseClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    try {
      const note = await handleEvent(JSON.parse(raw), (fn, args) => db.rpc(fn, args) as unknown as Promise<{ error: unknown }>);
      console.log(note);
      return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
    } catch (e) {
      console.error("stripe webhook failed", e);
      return new Response("failed, retry", { status: 500 }); // Stripe retries
    }
  });
}

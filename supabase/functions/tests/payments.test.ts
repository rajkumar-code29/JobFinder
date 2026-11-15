import { strict as assert } from "node:assert";
import { appleToken, fetchAppleTransaction, jwsPayload, verifyStripeSignature } from "../_shared/payments.ts";
import { checkAppleTransaction, stripeCheckout } from "../payments/index.ts";
import { handleEvent } from "../stripe-webhook/index.ts";
import { handleNotification } from "../apple-notifications/index.ts";

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

async function stripeHeader(body: string, secret: string, t: number) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return `t=${t},v1=${hex(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${body}`)))}`;
}

Deno.test("stripe signatures: right secret and fresh only", async () => {
  const now = 1_800_000_000, body = '{"id":"evt_1"}';
  const header = await stripeHeader(body, "whsec_test", now);
  assert.equal(await verifyStripeSignature(body, header, "whsec_test", now + 10), true);
  assert.equal(await verifyStripeSignature(body, header, "whsec_other", now + 10), false);
  assert.equal(await verifyStripeSignature(body + " ", header, "whsec_test", now + 10), false);
  assert.equal(await verifyStripeSignature(body, header, "whsec_test", now + 600), false);
  assert.equal(await verifyStripeSignature(body, null, "whsec_test", now), false);
});

Deno.test("stripe events: paid sessions grant once, refunds take back", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  const rpc = (fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve({ error: null });
  };
  const session = (status: string) => ({
    type: "checkout.session.completed",
    data: { object: { id: "cs_1", payment_status: status, amount_total: 1000, currency: "gbp", payment_intent: "pi_1",
      livemode: true, metadata: { user_id: "u1", pack: "pack_50" } } },
  });
  assert.match(await handleEvent(session("unpaid"), rpc), /not paid/);
  assert.match(await handleEvent(session("paid"), rpc), /granted pack_50/);
  assert.deepEqual(calls[0], ["grant_purchase", { p_user: "u1", p_source: "stripe", p_ref: "cs_1", p_pack: "pack_50",
    p_credits: 50, p_amount: 1000, p_currency: "gbp", p_payment_intent: "pi_1", p_environment: "production" }]);
  await handleEvent({ type: "charge.refunded", data: { object: { payment_intent: "pi_1" } } }, rpc);
  assert.deepEqual(calls[1], ["refund_purchase", { p_source: "stripe", p_payment_intent: "pi_1" }]);
  assert.match(await handleEvent({ type: "invoice.paid", data: { object: {} } }, rpc), /ignored/);
  assert.match(await handleEvent({ type: "checkout.session.completed", data: { object: { id: "x", payment_status: "paid", metadata: { pack: "pack_999", user_id: "u" } } } }, rpc), /no user or pack/);
  assert.equal(calls.length, 2);
});

Deno.test("checkout asks Stripe for the right price", async () => {
  let sent = "";
  const url = await stripeCheckout({
    secret: "sk_test", site: "https://jobs.example", userId: "u1", email: "a@b.co", pack: "pack_20",
    fetcher: ((_: string, init: RequestInit) => {
      sent = String(init.body);
      return Promise.resolve(new Response(JSON.stringify({ url: "https://checkout.stripe.com/c/1" })));
    }) as typeof fetch,
  });
  assert.equal(url, "https://checkout.stripe.com/c/1");
  const form = new URLSearchParams(sent);
  assert.equal(form.get("line_items[0][price_data][unit_amount]"), "500");
  assert.equal(form.get("line_items[0][price_data][currency]"), "gbp");
  assert.equal(form.get("metadata[user_id]"), "u1");
  assert.equal(form.get("metadata[pack]"), "pack_20");
});

async function testKey() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
  return { pair, pem };
}

const fakeJws = (payload: unknown) => `e30.${btoa(JSON.stringify(payload)).replace(/=+$/, "")}.sig`;

Deno.test("apple token is a valid ES256 JWT for the App Store Server API", async () => {
  const { pair, pem } = await testKey();
  const cfg = { issuerId: "iss-1", keyId: "KEY123", privateKey: pem, bundleId: "com.rajkumargk.jobfinder" };
  const token = await appleToken(cfg, 1_800_000_000);
  const [h, p, s] = token.split(".");
  const fromB64url = (x: string) => Uint8Array.from(atob(x.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(x.length / 4) * 4, "=")), (c) => c.charCodeAt(0));
  assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, fromB64url(s), enc.encode(`${h}.${p}`)), true);
  assert.deepEqual(jwsPayload(token), { iss: "iss-1", iat: 1_800_000_000, exp: 1_800_000_300, aud: "appstoreconnect-v1", bid: "com.rajkumargk.jobfinder" });
  assert.equal(JSON.parse(new TextDecoder().decode(fromB64url(h))).kid, "KEY123");
});

Deno.test("apple lookup falls back to the sandbox", async () => {
  const { pem } = await testKey();
  const cfg = { issuerId: "i", keyId: "k", privateKey: pem, bundleId: "com.rajkumargk.jobfinder" };
  const seen: string[] = [];
  const fetcher = ((url: string) => {
    seen.push(url);
    return Promise.resolve(url.includes("sandbox")
      ? new Response(JSON.stringify({ signedTransactionInfo: fakeJws({ transactionId: "2000", productId: "p", bundleId: "b", environment: "Sandbox" }) }))
      : new Response("{}", { status: 404 }));
  }) as typeof fetch;
  const t = await fetchAppleTransaction(cfg, "2000", fetcher);
  assert.equal(t?.environment, "Sandbox");
  assert.equal(seen.length, 2);
  assert.equal(await fetchAppleTransaction(cfg, "../etc", fetcher), null);
});

Deno.test("apple purchases are checked before credits", () => {
  const ok = { transactionId: "1", bundleId: "com.rajkumargk.jobfinder", productId: "com.rajkumargk.jobfinder.credits50" };
  assert.deepEqual(checkAppleTransaction(ok, "com.rajkumargk.jobfinder", "U"), { pack: "pack_50", credits: 50, amount: 1000 });
  assert.ok("error" in checkAppleTransaction(null, "com.rajkumargk.jobfinder", "U"));
  assert.ok("error" in checkAppleTransaction({ ...ok, bundleId: "com.other" }, "com.rajkumargk.jobfinder", "U"));
  assert.ok("error" in checkAppleTransaction({ ...ok, revocationDate: 1 }, "com.rajkumargk.jobfinder", "U"));
  assert.ok("error" in checkAppleTransaction({ ...ok, appAccountToken: "someone-else" }, "com.rajkumargk.jobfinder", "U"));
  assert.ok("error" in checkAppleTransaction({ ...ok, productId: "com.rajkumargk.jobfinder.free" }, "com.rajkumargk.jobfinder", "U"));
  assert.ok(!("error" in checkAppleTransaction({ ...ok, appAccountToken: "u" }, "com.rajkumargk.jobfinder", "U")));
});

Deno.test("apple refunds are confirmed with Apple first", async () => {
  const cfg = { issuerId: "i", keyId: "k", privateKey: "", bundleId: "com.rajkumargk.jobfinder" };
  const calls: unknown[] = [];
  const rpc = (fn: string, args: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve({ error: null });
  };
  const note = (type: string) => fakeJws({ notificationType: type, data: { signedTransactionInfo: fakeJws({ transactionId: "77" }) } });
  const revoked = () => Promise.resolve({ transactionId: "77", bundleId: "com.rajkumargk.jobfinder", productId: "p", revocationDate: 1 });
  const fine = () => Promise.resolve({ transactionId: "77", bundleId: "com.rajkumargk.jobfinder", productId: "p" });
  assert.match(await handleNotification(note("DID_RENEW"), cfg, rpc, revoked), /ignored/);
  assert.match(await handleNotification(note("REFUND"), cfg, rpc, fine), /not revoked/);
  assert.equal(calls.length, 0);
  assert.match(await handleNotification(note("REFUND"), cfg, rpc, revoked), /refunded 77/);
  assert.deepEqual(calls, [["refund_purchase", { p_source: "apple", p_ref: "77" }]]);
});

// Shared by the payments, stripe-webhook and apple-notifications functions.

/** Credit packs. Keep in sync with creditPacks in app/lib/screens/buy_credits.dart and the App Store products. */
export const PACKS: Record<string, { credits: number; amount: number; apple: string }> = {
  pack_20: { credits: 20, amount: 500, apple: "com.rajkumargk.jobfinder.credits20" },
  pack_50: { credits: 50, amount: 1000, apple: "com.rajkumargk.jobfinder.credits50" },
  pack_200: { credits: 200, amount: 2000, apple: "com.rajkumargk.jobfinder.credits200" },
};

export function packForAppleProduct(productId: string): [string, { credits: number; amount: number }] | null {
  const hit = Object.entries(PACKS).find(([, p]) => p.apple === productId);
  return hit ?? null;
}

const enc = new TextEncoder();

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Checks a Stripe-Signature header ("t=...,v1=...") against the raw body, within 5 minutes. */
export async function verifyStripeSignature(rawBody: string, header: string | null, secret: string,
  nowSeconds = Math.floor(Date.now() / 1000)): Promise<boolean> {
  if (!header || !secret) return false;
  const parts = header.split(",").map((p) => p.trim().split("="));
  const t = parts.find(([k]) => k === "t")?.[1];
  const sigs = parts.filter(([k]) => k === "v1").map(([, v]) => v);
  if (!t || !sigs.length || Math.abs(nowSeconds - Number(t)) > 300) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const expected = hex(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${rawBody}`)));
  return sigs.some((s) => safeEqual(s, expected));
}

// Apple: the App Store Server API, signed with the In-App Purchase key from App Store Connect

function b64url(data: Uint8Array | string): string {
  const bytes = typeof data === "string" ? enc.encode(data) : data;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** The payload of a JWS (the signature isn't checked: only use it on data fetched from Apple over HTTPS). */
export function jwsPayload<T = Record<string, unknown>>(jws: string): T {
  const part = jws.split(".")[1] ?? "";
  const b64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
  return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))));
}

async function signingKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\\n/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

export type AppleConfig = { issuerId: string; keyId: string; privateKey: string; bundleId: string };

export function appleConfig(): AppleConfig | null {
  const issuerId = Deno.env.get("APPLE_IAP_ISSUER_ID") ?? "";
  const keyId = Deno.env.get("APPLE_IAP_KEY_ID") ?? "";
  const privateKey = Deno.env.get("APPLE_IAP_PRIVATE_KEY") ?? "";
  if (!issuerId || !keyId || !privateKey) return null;
  return { issuerId, keyId, privateKey, bundleId: Deno.env.get("APPLE_BUNDLE_ID") ?? "com.rajkumargk.jobfinder" };
}

export async function appleToken(cfg: AppleConfig, nowSeconds = Math.floor(Date.now() / 1000)): Promise<string> {
  const header = b64url(JSON.stringify({ alg: "ES256", kid: cfg.keyId, typ: "JWT" }));
  const payload = b64url(JSON.stringify({
    iss: cfg.issuerId, iat: nowSeconds, exp: nowSeconds + 300, aud: "appstoreconnect-v1", bid: cfg.bundleId,
  }));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await signingKey(cfg.privateKey),
    enc.encode(`${header}.${payload}`));
  return `${header}.${payload}.${b64url(new Uint8Array(sig))}`;
}

export type AppleTransaction = {
  transactionId: string;
  originalTransactionId?: string;
  bundleId: string;
  productId: string;
  type?: string;
  appAccountToken?: string;
  revocationDate?: number;
  price?: number;     // milli-units
  currency?: string;
  environment?: string;
};

/** Looks a transaction up with Apple: production first, then the sandbox (TestFlight and App Review). */
export async function fetchAppleTransaction(cfg: AppleConfig, transactionId: string,
  fetcher: typeof fetch = fetch): Promise<AppleTransaction | null> {
  if (!/^\d{1,30}$/.test(transactionId)) return null;
  const token = await appleToken(cfg);
  for (const host of ["https://api.storekit.itunes.apple.com", "https://api.storekit-sandbox.itunes.apple.com"]) {
    const r = await fetcher(`${host}/inApps/v1/transactions/${transactionId}`, {
      headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(15_000),
    });
    if (r.status === 404) continue;
    if (!r.ok) throw new Error(`App Store Server API ${r.status}: ${(await r.text()).slice(0, 200)}`);
    const body = await r.json();
    return jwsPayload<AppleTransaction>(body.signedTransactionInfo);
  }
  return null;
}

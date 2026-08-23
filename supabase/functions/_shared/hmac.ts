// 85Blends 2.3.0 — Phase B1. RevenueCat webhook HMAC-SHA256 verification.
//
// Pure Web Crypto (`crypto.subtle`) + standard `TextEncoder` — no Deno-specific APIs, so this
// module runs and is unit-testable under both Deno (the real Edge Function runtime) and Node
// (this repo's local validation — see supabase/functions/_shared/hmac.test.ts).
//
// RevenueCat signs webhook deliveries with:
//
//   X-RevenueCat-Webhook-Signature: t=<unix_timestamp_seconds>,v1=<hex_hmac_sha256>
//
// where the signed message is exactly `"<timestamp>." + <raw request body bytes>` — the ORIGINAL
// bytes as received, before any JSON parse/reserialization (parsing and re-stringifying JSON is
// not guaranteed to reproduce byte-identical output, so verification must happen against the raw
// body — see revenuecat-webhook/index.ts, which reads the body exactly once via
// `req.arrayBuffer()` before anything else touches it).

const SIGNATURE_HEADER_PATTERN = /^t=(\d+),v1=([0-9a-fA-F]+)$/;

export interface ParsedWebhookSignature {
  timestamp: number;
  signatureHex: string;
}

/**
 * Parses `X-RevenueCat-Webhook-Signature`'s `t=...,v1=...` shape. Returns `null` for anything
 * that doesn't match exactly — missing header, extra/reordered fields, non-numeric timestamp,
 * non-hex signature, etc. Never throws.
 */
export function parseWebhookSignatureHeader(headerValue: string | null): ParsedWebhookSignature | null {
  if (!headerValue) return null;
  const match = SIGNATURE_HEADER_PATTERN.exec(headerValue.trim());
  if (!match) return null;

  const timestamp = Number(match[1]);
  if (!Number.isSafeInteger(timestamp) || timestamp < 0) return null;

  // Normalize to lowercase for the constant-time comparison below — hex case doesn't carry
  // meaning, but comparing mismatched case as raw strings would falsely fail a valid signature.
  return { timestamp, signatureHex: match[2].toLowerCase() };
}

/** Hex-encodes a byte array using lowercase digits, matching RevenueCat's `v1` format. */
function bytesToHex(bytes: Uint8Array): string {
  let hex = "";
  for (const byte of bytes) {
    hex += byte.toString(16).padStart(2, "0");
  }
  return hex;
}

/**
 * Computes HMAC-SHA256 over `"<timestamp>." + rawBody` using `secret`, returning lowercase hex.
 * `rawBody` must be the exact original request bytes — see this module's header comment.
 */
export async function computeWebhookSignature(
  secret: string,
  timestamp: number,
  rawBody: Uint8Array,
): Promise<string> {
  const encoder = new TextEncoder();
  const prefix = encoder.encode(`${timestamp}.`);
  const message = new Uint8Array(prefix.length + rawBody.length);
  message.set(prefix, 0);
  message.set(rawBody, prefix.length);

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signatureBytes = new Uint8Array(await crypto.subtle.sign("HMAC", key, message));
  return bytesToHex(signatureBytes);
}

/**
 * Constant-time comparison of two ASCII/hex strings. Always compares the same number of bytes
 * regardless of where (or whether) the two strings first differ, and never short-circuits on a
 * length mismatch before completing that full comparison — so timing does not reveal how many
 * leading characters matched. Do not replace with `a === b`.
 */
export function constantTimeEqual(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const bytesA = encoder.encode(a);
  const bytesB = encoder.encode(b);
  const length = Math.max(bytesA.length, bytesB.length, 1);

  let diff = bytesA.length === bytesB.length ? 0 : 1;
  for (let i = 0; i < length; i++) {
    const byteA = i < bytesA.length ? bytesA[i] : 0;
    const byteB = i < bytesB.length ? bytesB[i] : 0;
    diff |= byteA ^ byteB;
  }
  return diff === 0;
}

export interface VerifyWebhookSignatureParams {
  secret: string;
  rawBody: Uint8Array;
  signatureHeaderValue: string | null;
  /** Injected for testability — defaults to `Date.now() / 1000` at the real call site. */
  nowUnixSeconds: number;
  /**
   * 300s (5 minutes) per Phase 5. RevenueCat RECOMPUTES the `t`/`v1` signature header for every
   * delivery attempt, including retries — it does NOT reuse the first delivery's timestamp or
   * signature. (What retries DO reuse is `event.id` and `event.event_timestamp_ms` inside the
   * JSON body itself — see idempotency.ts — which is a completely separate mechanism from this
   * header.) This tolerance exists to allow for ordinary clock skew and network/processing delay
   * on each individual delivery's own fresh timestamp, not to accommodate a stale reused one.
   */
  toleranceSeconds?: number;
}

/**
 * Full signature verification: parse → timestamp freshness → constant-time HMAC compare.
 * Returns a plain boolean — callers (see auth.ts) are responsible for turning `false` into a
 * generic, non-revealing 401 response rather than surfacing which specific check failed.
 */
export async function verifyWebhookSignature(params: VerifyWebhookSignatureParams): Promise<boolean> {
  const { secret, rawBody, signatureHeaderValue, nowUnixSeconds, toleranceSeconds = 300 } = params;

  const parsed = parseWebhookSignatureHeader(signatureHeaderValue);
  if (!parsed) return false;

  if (Math.abs(nowUnixSeconds - parsed.timestamp) > toleranceSeconds) return false;

  const expectedHex = await computeWebhookSignature(secret, parsed.timestamp, rawBody);
  return constantTimeEqual(expectedHex, parsed.signatureHex);
}

// 85Blends 2.3.0 — Phase B1. Combined webhook authentication: Authorization header + HMAC.
//
// Defense in depth per the task spec: BOTH the configured Authorization header value AND a
// valid RevenueCat HMAC signature are required. Neither check alone is ever sufficient. Uses
// only `constantTimeEqual`/`verifyWebhookSignature` from hmac.ts — no Deno-specific APIs, so
// this is directly unit-testable under Node using real Fetch API `Headers` objects (Node has a
// global `Headers` implementation, same as Deno) — see auth.test.ts.

import { constantTimeEqual, verifyWebhookSignature } from "./hmac.ts";

export interface WebhookAuthConfig {
  authHeaderSecret: string;
  hmacSecret: string;
}

export type WebhookAuthResult =
  | { ok: true }
  /** Deliberately carries no detail about which check failed — see this module's header comment. */
  | { ok: false };

export interface VerifyWebhookAuthParams {
  headers: Headers;
  rawBody: Uint8Array;
  config: WebhookAuthConfig;
  nowUnixSeconds: number;
}

/**
 * Verifies both required layers and returns a single pass/fail result. Both checks are always
 * computed (never short-circuited) so a caller inspecting only the boolean result — and RevenueCat
 * inspecting only the HTTP response — cannot distinguish "wrong Authorization header" from "wrong
 * HMAC signature" from "both wrong." See revenuecat-webhook/index.ts for the generic 401 this
 * produces.
 */
export async function verifyWebhookAuth(params: VerifyWebhookAuthParams): Promise<WebhookAuthResult> {
  const { headers, rawBody, config, nowUnixSeconds } = params;

  const authHeaderValue = headers.get("authorization");
  const authOk = authHeaderValue !== null && constantTimeEqual(authHeaderValue, config.authHeaderSecret);

  const signatureHeaderValue = headers.get("x-revenuecat-webhook-signature");
  const hmacOk = await verifyWebhookSignature({
    secret: config.hmacSecret,
    rawBody,
    signatureHeaderValue,
    nowUnixSeconds,
  });

  return authOk && hmacOk ? { ok: true } : { ok: false };
}

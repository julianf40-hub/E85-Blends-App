// 85Blends 2.3.0 — Phase B1. Tests for auth.ts. Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { verifyWebhookAuth } from "./auth.ts";
import { computeWebhookSignature } from "./hmac.ts";

const AUTH_SECRET = "expected-authorization-header-value";
const HMAC_SECRET = "hmac-secret";

async function signedHeaders(rawBody: Uint8Array, timestamp: number, authValue: string): Promise<Headers> {
  const signatureHex = await computeWebhookSignature(HMAC_SECRET, timestamp, rawBody);
  const headers = new Headers();
  headers.set("Authorization", authValue);
  headers.set("X-RevenueCat-Webhook-Signature", `t=${timestamp},v1=${signatureHex}`);
  return headers;
}

test("verifyWebhookAuth: both Authorization and HMAC valid -> ok", async () => {
  const rawBody = new TextEncoder().encode(JSON.stringify({ event: { id: "1", type: "TEST" } }));
  const timestamp = 1700000000;
  const headers = await signedHeaders(rawBody, timestamp, AUTH_SECRET);

  const result = await verifyWebhookAuth({
    headers,
    rawBody,
    config: { authHeaderSecret: AUTH_SECRET, hmacSecret: HMAC_SECRET },
    nowUnixSeconds: timestamp,
  });
  assert.deepEqual(result, { ok: true });
});

test("verifyWebhookAuth: wrong Authorization, valid HMAC -> rejected", async () => {
  const rawBody = new TextEncoder().encode(JSON.stringify({ event: { id: "1", type: "TEST" } }));
  const timestamp = 1700000000;
  const headers = await signedHeaders(rawBody, timestamp, "wrong-value");

  const result = await verifyWebhookAuth({
    headers,
    rawBody,
    config: { authHeaderSecret: AUTH_SECRET, hmacSecret: HMAC_SECRET },
    nowUnixSeconds: timestamp,
  });
  assert.deepEqual(result, { ok: false });
});

test("verifyWebhookAuth: valid Authorization, wrong HMAC -> rejected", async () => {
  const rawBody = new TextEncoder().encode(JSON.stringify({ event: { id: "1", type: "TEST" } }));
  const timestamp = 1700000000;
  const headers = new Headers();
  headers.set("Authorization", AUTH_SECRET);
  headers.set("X-RevenueCat-Webhook-Signature", `t=${timestamp},v1=${"0".repeat(64)}`);

  const result = await verifyWebhookAuth({
    headers,
    rawBody,
    config: { authHeaderSecret: AUTH_SECRET, hmacSecret: HMAC_SECRET },
    nowUnixSeconds: timestamp,
  });
  assert.deepEqual(result, { ok: false });
});

test("verifyWebhookAuth: both missing -> rejected", async () => {
  const rawBody = new TextEncoder().encode(JSON.stringify({ event: { id: "1", type: "TEST" } }));
  const result = await verifyWebhookAuth({
    headers: new Headers(),
    rawBody,
    config: { authHeaderSecret: AUTH_SECRET, hmacSecret: HMAC_SECRET },
    nowUnixSeconds: 1700000000,
  });
  assert.deepEqual(result, { ok: false });
});

test("verifyWebhookAuth: header lookups are case-insensitive (standard Headers behavior)", async () => {
  const rawBody = new TextEncoder().encode(JSON.stringify({ event: { id: "1", type: "TEST" } }));
  const timestamp = 1700000000;
  const signatureHex = await computeWebhookSignature(HMAC_SECRET, timestamp, rawBody);
  const headers = new Headers();
  headers.set("aUtHoRiZaTiOn", AUTH_SECRET);
  headers.set("x-revenuecat-webhook-signature", `t=${timestamp},v1=${signatureHex}`);

  const result = await verifyWebhookAuth({
    headers,
    rawBody,
    config: { authHeaderSecret: AUTH_SECRET, hmacSecret: HMAC_SECRET },
    nowUnixSeconds: timestamp,
  });
  assert.deepEqual(result, { ok: true });
});

// 85Blends 2.3.0 — Phase B1. Tests for hmac.ts.
//
// Run under Node (`node --test supabase/functions/_shared/*.test.ts`) — see this repo's Phase B1
// final report for why Node rather than `deno test` (Deno isn't installed in this environment).
// Uses only Web Crypto + standard globals, identical to the module under test.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  computeWebhookSignature,
  constantTimeEqual,
  parseWebhookSignatureHeader,
  verifyWebhookSignature,
} from "./hmac.ts";

const SECRET = "test-hmac-secret-value";

function bodyBytes(json: unknown): Uint8Array {
  return new TextEncoder().encode(JSON.stringify(json));
}

test("parseWebhookSignatureHeader: valid header parses t and v1", () => {
  const parsed = parseWebhookSignatureHeader("t=1700000000,v1=abcDEF0123");
  assert.deepEqual(parsed, { timestamp: 1700000000, signatureHex: "abcdef0123" });
});

test("parseWebhookSignatureHeader: rejects missing header", () => {
  assert.equal(parseWebhookSignatureHeader(null), null);
});

test("parseWebhookSignatureHeader: rejects malformed shapes", () => {
  assert.equal(parseWebhookSignatureHeader(""), null);
  assert.equal(parseWebhookSignatureHeader("v1=abc,t=123"), null); // wrong order
  assert.equal(parseWebhookSignatureHeader("t=abc,v1=abc123"), null); // non-numeric timestamp
  assert.equal(parseWebhookSignatureHeader("t=123,v1=zzz"), null); // non-hex signature
  assert.equal(parseWebhookSignatureHeader("t=123"), null); // missing v1
  assert.equal(parseWebhookSignatureHeader("garbage"), null);
});

test("constantTimeEqual: equal strings match", () => {
  assert.equal(constantTimeEqual("abc123", "abc123"), true);
});

test("constantTimeEqual: differing strings (same length) do not match", () => {
  assert.equal(constantTimeEqual("abc123", "abc124"), false);
});

test("constantTimeEqual: differing lengths do not match", () => {
  assert.equal(constantTimeEqual("abc", "abc123"), false);
  assert.equal(constantTimeEqual("abc123", "abc"), false);
});

test("computeWebhookSignature: deterministic for identical inputs", async () => {
  const body = bodyBytes({ hello: "world" });
  const sig1 = await computeWebhookSignature(SECRET, 1700000000, body);
  const sig2 = await computeWebhookSignature(SECRET, 1700000000, body);
  assert.equal(sig1, sig2);
  assert.match(sig1, /^[0-9a-f]{64}$/); // SHA-256 -> 32 bytes -> 64 hex chars
});

test("computeWebhookSignature: different secret produces a different signature", async () => {
  const body = bodyBytes({ hello: "world" });
  const sig1 = await computeWebhookSignature(SECRET, 1700000000, body);
  const sig2 = await computeWebhookSignature("a-different-secret", 1700000000, body);
  assert.notEqual(sig1, sig2);
});

test("verifyWebhookSignature: valid signature is accepted", async () => {
  const rawBody = bodyBytes({ event: { id: "evt_1", type: "TEST" } });
  const timestamp = 1700000000;
  const signatureHex = await computeWebhookSignature(SECRET, timestamp, rawBody);

  const ok = await verifyWebhookSignature({
    secret: SECRET,
    rawBody,
    signatureHeaderValue: `t=${timestamp},v1=${signatureHex}`,
    nowUnixSeconds: timestamp + 10, // within tolerance
  });
  assert.equal(ok, true);
});

test("verifyWebhookSignature: altered body is rejected", async () => {
  const timestamp = 1700000000;
  const originalBody = bodyBytes({ event: { id: "evt_1", type: "TEST" } });
  const signatureHex = await computeWebhookSignature(SECRET, timestamp, originalBody);

  const tamperedBody = bodyBytes({ event: { id: "evt_1", type: "TEST_TAMPERED" } });
  const ok = await verifyWebhookSignature({
    secret: SECRET,
    rawBody: tamperedBody,
    signatureHeaderValue: `t=${timestamp},v1=${signatureHex}`,
    nowUnixSeconds: timestamp,
  });
  assert.equal(ok, false);
});

test("verifyWebhookSignature: altered signature is rejected", async () => {
  const timestamp = 1700000000;
  const rawBody = bodyBytes({ event: { id: "evt_1", type: "TEST" } });
  const signatureHex = await computeWebhookSignature(SECRET, timestamp, rawBody);
  const flippedHex = signatureHex.slice(0, -1) + (signatureHex.at(-1) === "0" ? "1" : "0");

  const ok = await verifyWebhookSignature({
    secret: SECRET,
    rawBody,
    signatureHeaderValue: `t=${timestamp},v1=${flippedHex}`,
    nowUnixSeconds: timestamp,
  });
  assert.equal(ok, false);
});

test("verifyWebhookSignature: stale timestamp is rejected even with a correct signature", async () => {
  const timestamp = 1700000000;
  const rawBody = bodyBytes({ event: { id: "evt_1", type: "TEST" } });
  const signatureHex = await computeWebhookSignature(SECRET, timestamp, rawBody);

  const ok = await verifyWebhookSignature({
    secret: SECRET,
    rawBody,
    signatureHeaderValue: `t=${timestamp},v1=${signatureHex}`,
    nowUnixSeconds: timestamp + 301, // just past the 300s tolerance
    toleranceSeconds: 300,
  });
  assert.equal(ok, false);
});

test("verifyWebhookSignature: timestamp exactly at the tolerance boundary is accepted", async () => {
  const timestamp = 1700000000;
  const rawBody = bodyBytes({ event: { id: "evt_1", type: "TEST" } });
  const signatureHex = await computeWebhookSignature(SECRET, timestamp, rawBody);

  const ok = await verifyWebhookSignature({
    secret: SECRET,
    rawBody,
    signatureHeaderValue: `t=${timestamp},v1=${signatureHex}`,
    nowUnixSeconds: timestamp + 300,
    toleranceSeconds: 300,
  });
  assert.equal(ok, true);
});

test("verifyWebhookSignature: malformed header is rejected", async () => {
  const rawBody = bodyBytes({ event: { id: "evt_1", type: "TEST" } });
  const ok = await verifyWebhookSignature({
    secret: SECRET,
    rawBody,
    signatureHeaderValue: "not-a-valid-header",
    nowUnixSeconds: 1700000000,
  });
  assert.equal(ok, false);
});

test("verifyWebhookSignature: missing header is rejected", async () => {
  const rawBody = bodyBytes({ event: { id: "evt_1", type: "TEST" } });
  const ok = await verifyWebhookSignature({
    secret: SECRET,
    rawBody,
    signatureHeaderValue: null,
    nowUnixSeconds: 1700000000,
  });
  assert.equal(ok, false);
});

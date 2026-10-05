// 85Blends 2.4.1 — FCM response classification (the device-invalidation decision).
// Run under Node: node --test supabase/functions/price-alerts-worker/fcm.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { classifyFcmResponse, fcmErrorCode } from "./fcm.ts";

// FCM v1 error bodies: { error: { code, message, status, details: [{ "@type": ..., errorCode }] } }
const fcmError = (status: string, errorCode?: string) => ({
  error: {
    code: 0,
    message: "synthetic test error",
    status,
    details: errorCode ? [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode }] : [],
  },
});

test("success: 200 is sent, never retried, never invalidated", () => {
  const r = classifyFcmResponse(200, null);
  assert.deepEqual(r, { kind: "sent", ok: true, status: 200, reason: "sent", retryable: false, invalidate: false });
});

test("HTTP 404 + UNREGISTERED invalidates the device (the only token-is-bad evidence), not retryable", () => {
  const r = classifyFcmResponse(404, fcmError("NOT_FOUND", "UNREGISTERED"));
  assert.equal(r.kind, "invalid_token");
  assert.equal(r.invalidate, true);
  assert.equal(r.retryable, false);
  assert.equal(r.reason, "UNREGISTERED");
  assert.equal(r.ok, false);
});

test("UNREGISTERED reported through the rpc status alone is still an explicit token verdict", () => {
  const r = classifyFcmResponse(404, { error: { status: "UNREGISTERED" } });
  assert.equal(r.invalidate, true);
});

test("a generic HTTP 404 WITHOUT UNREGISTERED never invalidates the device", () => {
  for (const body of [null, {}, fcmError("NOT_FOUND"), { error: { status: "NOT_FOUND", message: "Requested entity was not found." } }, "not json"]) {
    const r = classifyFcmResponse(404, body);
    assert.equal(r.invalidate, false, JSON.stringify(body));
    assert.equal(r.kind, "configuration");
    assert.equal(r.retryable, true);
  }
});

test("SENDER_ID_MISMATCH is a configuration failure, never an invalid device", () => {
  for (const status of [403, 400, 404]) {
    const r = classifyFcmResponse(status, fcmError("PERMISSION_DENIED", "SENDER_ID_MISMATCH"));
    assert.equal(r.invalidate, false, `status ${status}`);
    assert.equal(r.kind, "configuration");
    assert.equal(r.reason, "SENDER_ID_MISMATCH");
  }
});

test("401 / 403 authentication and configuration failures never invalidate the device", () => {
  const cases: Array<[number, unknown]> = [
    [401, fcmError("UNAUTHENTICATED")],
    [401, fcmError("UNAUTHENTICATED", "THIRD_PARTY_AUTH_ERROR")],
    [403, fcmError("PERMISSION_DENIED")],
    [403, null],
    [401, null],
    [400, fcmError("FAILED_PRECONDITION", "THIRD_PARTY_AUTH_ERROR")],
  ];
  for (const [status, body] of cases) {
    const r = classifyFcmResponse(status, body);
    assert.equal(r.invalidate, false, `${status} ${JSON.stringify(body)}`);
    assert.equal(r.kind, "configuration");
    assert.equal(r.retryable, true, "fixable server configuration is retried inside the window");
  }
});

test("429 and quota exhaustion are retryable and never invalidate", () => {
  for (const body of [fcmError("RESOURCE_EXHAUSTED", "QUOTA_EXCEEDED"), fcmError("RESOURCE_EXHAUSTED"), null]) {
    const r = classifyFcmResponse(429, body);
    assert.equal(r.retryable, true);
    assert.equal(r.invalidate, false);
    assert.equal(r.kind, "transient");
  }
  assert.equal(classifyFcmResponse(429, fcmError("RESOURCE_EXHAUSTED", "QUOTA_EXCEEDED")).retryable, true);
});

test("500 / 502 / 503 / 504 are retryable and never invalidate", () => {
  for (const status of [500, 502, 503, 504]) {
    const r = classifyFcmResponse(status, null);
    assert.equal(r.retryable, true, String(status));
    assert.equal(r.invalidate, false, String(status));
    assert.equal(r.kind, "transient");
  }
});

test("UNAVAILABLE and INTERNAL are retryable even when carried on an unexpected HTTP status", () => {
  for (const code of ["UNAVAILABLE", "INTERNAL", "UNSPECIFIED_ERROR", "DEADLINE_EXCEEDED"]) {
    const r = classifyFcmResponse(503, fcmError(code, code));
    assert.equal(r.retryable, true, code);
    assert.equal(r.invalidate, false, code);
  }
  const odd = classifyFcmResponse(400, fcmError("UNAVAILABLE", "UNAVAILABLE"));
  assert.equal(odd.retryable, true);
  assert.equal(odd.invalidate, false);
});

test("INVALID_ARGUMENT is rejected: not retryable, and the device is NOT disabled", () => {
  const r = classifyFcmResponse(400, fcmError("INVALID_ARGUMENT", "INVALID_ARGUMENT"));
  assert.equal(r.kind, "rejected");
  assert.equal(r.retryable, false);
  assert.equal(r.invalidate, false);
});

test("an unknown error on an unknown status is not retried and never invalidates", () => {
  const r = classifyFcmResponse(418, null);
  assert.equal(r.invalidate, false);
  assert.equal(r.retryable, false);
  assert.equal(r.reason, "http_418");
});

test("a status-less or non-object body never crashes and never invalidates", () => {
  for (const body of [undefined, null, 5, "x", [], { error: null }, { error: [] }, { error: { details: "nope" } }, { error: { details: [null, 3, []] } }]) {
    assert.equal(classifyFcmResponse(404, body).invalidate, false);
    assert.equal(classifyFcmResponse(500, body).invalidate, false);
  }
});

test("only the explicit code decides invalidation: UNREGISTERED in details wins over a different rpc status", () => {
  assert.equal(fcmErrorCode(fcmError("NOT_FOUND", "UNREGISTERED")), "UNREGISTERED");
  assert.equal(fcmErrorCode(fcmError("NOT_FOUND")), "NOT_FOUND");
  assert.equal(fcmErrorCode({ error: { details: [{ errorCode: "SENDER_ID_MISMATCH" }], status: "PERMISSION_DENIED" } }), "SENDER_ID_MISMATCH");
  assert.equal(fcmErrorCode(null), null);
});

test("reason codes are bounded to what last_error_code accepts (<= 128) and carry no token text", () => {
  const long = "X".repeat(500);
  const r = classifyFcmResponse(400, { error: { status: long } });
  assert.ok(r.reason.length <= 128);
  assert.ok(!JSON.stringify(r).includes("fcm-token"));
});

test("the worker uses the classifier and no longer decides invalidation inline", () => {
  const index = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  assert.ok(index.includes('from "./fcm.ts"') && index.includes("classifyFcmResponse(res.status"), "index.ts delegates to fcm.ts");
  assert.ok(!/res\.status\s*===\s*404/.test(index), "no inline 404 => invalidate rule");
  assert.ok(!/SENDER_ID_MISMATCH/.test(index), "no inline SENDER_ID_MISMATCH rule");
  assert.ok(!/invalidate\s*=\s*code/.test(index), "no inline invalidate decision");
});

// 85Blends 2.3.0 — Phase B1. Tests for idempotency.ts. Run under Node — see hmac.test.ts's header.

import { test } from "node:test";
import assert from "node:assert/strict";
import { decideIdempotency } from "./idempotency.ts";

test("decideIdempotency: no existing row -> new", () => {
  assert.deepEqual(decideIdempotency(null, "hash_a"), { kind: "new" });
});

test("decideIdempotency: existing row, same hash, status processed -> duplicate_processed (no reapply)", () => {
  const result = decideIdempotency({ payloadHash: "hash_a", processingStatus: "processed" }, "hash_a");
  assert.deepEqual(result, { kind: "duplicate_processed" });
});

test("decideIdempotency: existing row, same hash, status received -> duplicate_retryable", () => {
  const result = decideIdempotency({ payloadHash: "hash_a", processingStatus: "received" }, "hash_a");
  assert.deepEqual(result, { kind: "duplicate_retryable" });
});

test("decideIdempotency: existing row, same hash, status error -> duplicate_retryable", () => {
  const result = decideIdempotency({ payloadHash: "hash_a", processingStatus: "error" }, "hash_a");
  assert.deepEqual(result, { kind: "duplicate_retryable" });
});

test("decideIdempotency: existing row, different hash -> hash_mismatch regardless of status", () => {
  assert.deepEqual(
    decideIdempotency({ payloadHash: "hash_a", processingStatus: "processed" }, "hash_b"),
    { kind: "hash_mismatch" },
  );
  assert.deepEqual(
    decideIdempotency({ payloadHash: "hash_a", processingStatus: "received" }, "hash_b"),
    { kind: "hash_mismatch" },
  );
});

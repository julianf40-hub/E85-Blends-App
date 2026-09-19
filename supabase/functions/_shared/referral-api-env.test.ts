// 85Blends 2.4.0 — Tests for referral-api-env.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveReferralApiEnvConfig } from "./referral-api-env.ts";

function fakeEnv(values: Record<string, string | undefined>): (name: string) => string | undefined {
  return (name) => values[name];
}

test("resolveReferralApiEnvConfig: publishable-key-only configuration succeeds", () => {
  const result = resolveReferralApiEnvConfig(
    fakeEnv({
      SUPABASE_DB_URL: "postgresql://example",
      SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_abc" }),
    }),
  );
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(result.config.clientApiKeys, ["sb_publishable_abc"]);
  }
});

test("resolveReferralApiEnvConfig: legacy-anon-only configuration succeeds", () => {
  const result = resolveReferralApiEnvConfig(
    fakeEnv({ SUPABASE_DB_URL: "postgresql://example", SUPABASE_ANON_KEY: "anon-key-value" }),
  );
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(result.config.clientApiKeys, ["anon-key-value"]);
  }
});

test("resolveReferralApiEnvConfig: publishable + legacy anon together succeed, both present in clientApiKeys", () => {
  const result = resolveReferralApiEnvConfig(
    fakeEnv({
      SUPABASE_DB_URL: "postgresql://example",
      SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_abc" }),
      SUPABASE_ANON_KEY: "anon-key-value",
    }),
  );
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(result.config.clientApiKeys, ["sb_publishable_abc", "anon-key-value"]);
  }
});

test("resolveReferralApiEnvConfig: malformed publishable JSON + valid anon still succeeds (degrades to anon only)", () => {
  const result = resolveReferralApiEnvConfig(
    fakeEnv({
      SUPABASE_DB_URL: "postgresql://example",
      SUPABASE_PUBLISHABLE_KEYS: "{not valid json",
      SUPABASE_ANON_KEY: "anon-key-value",
    }),
  );
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(result.config.clientApiKeys, ["anon-key-value"]);
  }
});

test("resolveReferralApiEnvConfig: malformed publishable JSON + no anon fails closed", () => {
  const result = resolveReferralApiEnvConfig(
    fakeEnv({ SUPABASE_DB_URL: "postgresql://example", SUPABASE_PUBLISHABLE_KEYS: "{not valid json" }),
  );
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.deepEqual(result.missing, ["SUPABASE_PUBLISHABLE_KEYS or SUPABASE_ANON_KEY"]);
  }
});

test("resolveReferralApiEnvConfig: empty publishable object + no anon fails closed", () => {
  const result = resolveReferralApiEnvConfig(
    fakeEnv({ SUPABASE_DB_URL: "postgresql://example", SUPABASE_PUBLISHABLE_KEYS: "{}" }),
  );
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.deepEqual(result.missing, ["SUPABASE_PUBLISHABLE_KEYS or SUPABASE_ANON_KEY"]);
  }
});

test("resolveReferralApiEnvConfig: multiple publishable keys are all accepted", () => {
  const result = resolveReferralApiEnvConfig(
    fakeEnv({
      SUPABASE_DB_URL: "postgresql://example",
      SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_abc", secondary: "sb_publishable_xyz" }),
    }),
  );
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(result.config.clientApiKeys.sort(), ["sb_publishable_abc", "sb_publishable_xyz"].sort());
  }
});

test("resolveReferralApiEnvConfig: publishable JSON that is a valid array (not an object) contributes zero keys", () => {
  const result = resolveReferralApiEnvConfig(
    fakeEnv({
      SUPABASE_DB_URL: "postgresql://example",
      SUPABASE_PUBLISHABLE_KEYS: JSON.stringify(["sb_publishable_abc"]),
      SUPABASE_ANON_KEY: "anon-key-value",
    }),
  );
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(result.config.clientApiKeys, ["anon-key-value"]);
  }
});

test("resolveReferralApiEnvConfig: publishable JSON with non-string values ignores those entries only", () => {
  const result = resolveReferralApiEnvConfig(
    fakeEnv({
      SUPABASE_DB_URL: "postgresql://example",
      SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_abc", bad: 12345, alsoBad: null }),
    }),
  );
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.deepEqual(result.config.clientApiKeys, ["sb_publishable_abc"]);
  }
});

test("resolveReferralApiEnvConfig: missing SUPABASE_DB_URL is reported even with a usable key present", () => {
  const result = resolveReferralApiEnvConfig(fakeEnv({ SUPABASE_ANON_KEY: "anon-key-value" }));
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.deepEqual(result.missing, ["SUPABASE_DB_URL"]);
  }
});

test("resolveReferralApiEnvConfig: nothing configured at all reports both problems", () => {
  const result = resolveReferralApiEnvConfig(fakeEnv({}));
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.deepEqual(result.missing, ["SUPABASE_DB_URL", "SUPABASE_PUBLISHABLE_KEYS or SUPABASE_ANON_KEY"]);
  }
});

test("resolveReferralApiEnvConfig: blank/whitespace-only SUPABASE_DB_URL is treated as missing", () => {
  const result = resolveReferralApiEnvConfig(
    fakeEnv({ SUPABASE_DB_URL: "   ", SUPABASE_ANON_KEY: "anon-key-value" }),
  );
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.deepEqual(result.missing, ["SUPABASE_DB_URL"]);
  }
});

test("resolveReferralApiEnvConfig: blank/whitespace-only SUPABASE_ANON_KEY does not count as a usable key", () => {
  const result = resolveReferralApiEnvConfig(fakeEnv({ SUPABASE_DB_URL: "postgresql://example", SUPABASE_ANON_KEY: "   " }));
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.deepEqual(result.missing, ["SUPABASE_PUBLISHABLE_KEYS or SUPABASE_ANON_KEY"]);
  }
});

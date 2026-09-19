// 85Blends 2.4.0 — Tests for referral-api-env.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveReferralApiEnvConfig } from "./referral-api-env.ts";

function fakeEnv(values: Record<string, string | undefined>): (name: string) => string | undefined {
  return (name) => values[name];
}

test("resolveReferralApiEnvConfig: all present -> ok with the exact values", () => {
  const result = resolveReferralApiEnvConfig(
    fakeEnv({
      SUPABASE_DB_URL: "postgresql://example",
      SUPABASE_ANON_KEY: "anon-key-value",
    }),
  );
  assert.deepEqual(result, {
    ok: true,
    config: { supabaseDbUrl: "postgresql://example", supabaseAnonKey: "anon-key-value" },
  });
});

test("resolveReferralApiEnvConfig: missing SUPABASE_DB_URL is reported", () => {
  const result = resolveReferralApiEnvConfig(fakeEnv({ SUPABASE_ANON_KEY: "anon-key-value" }));
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.deepEqual(result.missing, ["SUPABASE_DB_URL"]);
  }
});

test("resolveReferralApiEnvConfig: missing both -> both reported", () => {
  const result = resolveReferralApiEnvConfig(fakeEnv({}));
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.deepEqual(result.missing, ["SUPABASE_DB_URL", "SUPABASE_ANON_KEY"]);
  }
});

test("resolveReferralApiEnvConfig: blank/whitespace-only values are treated as missing", () => {
  const result = resolveReferralApiEnvConfig(
    fakeEnv({ SUPABASE_DB_URL: "   ", SUPABASE_ANON_KEY: "anon-key-value" }),
  );
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.deepEqual(result.missing, ["SUPABASE_DB_URL"]);
  }
});

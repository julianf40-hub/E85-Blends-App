// 85Blends 2.3.0 — Phase B1. Tests for env.ts. Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveEnvConfig } from "./env.ts";

const FULL_VALID: Record<string, string> = {
  REVENUECAT_PROJECT_ID: "proj_123",
  REVENUECAT_V2_SECRET_API_KEY: "sk_test_not_a_real_secret",
  REVENUECAT_WEBHOOK_AUTH_HEADER: "Bearer some-header-value",
  REVENUECAT_WEBHOOK_HMAC_SECRET: "hmac-secret-value",
  SUPABASE_DB_URL: "postgres://user:pass@host:5432/db",
};

test("resolveEnvConfig: all present -> ok with mapped config", () => {
  const result = resolveEnvConfig((name) => FULL_VALID[name]);
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.config.revenueCatProjectId, "proj_123");
    assert.equal(result.config.revenueCatV2SecretApiKey, "sk_test_not_a_real_secret");
    assert.equal(result.config.webhookAuthHeaderSecret, "Bearer some-header-value");
    assert.equal(result.config.webhookHmacSecret, "hmac-secret-value");
    assert.equal(result.config.supabaseDbUrl, "postgres://user:pass@host:5432/db");
  }
});

test("resolveEnvConfig: one missing -> reports exactly that variable name", () => {
  const partial = { ...FULL_VALID };
  delete (partial as Record<string, string | undefined>).REVENUECAT_WEBHOOK_HMAC_SECRET;
  const result = resolveEnvConfig((name) => partial[name]);
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.deepEqual(result.missing, ["REVENUECAT_WEBHOOK_HMAC_SECRET"]);
  }
});

test("resolveEnvConfig: blank/whitespace-only value is treated as missing", () => {
  const partial: Record<string, string> = { ...FULL_VALID, SUPABASE_DB_URL: "   " };
  const result = resolveEnvConfig((name) => partial[name]);
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.deepEqual(result.missing, ["SUPABASE_DB_URL"]);
  }
});

test("resolveEnvConfig: all missing -> reports all five names", () => {
  const result = resolveEnvConfig(() => undefined);
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.deepEqual(result.missing, [
      "REVENUECAT_PROJECT_ID",
      "REVENUECAT_V2_SECRET_API_KEY",
      "REVENUECAT_WEBHOOK_AUTH_HEADER",
      "REVENUECAT_WEBHOOK_HMAC_SECRET",
      "SUPABASE_DB_URL",
    ]);
  }
});

test("resolveEnvConfig: never echoes a missing variable's would-be value (there isn't one to leak)", () => {
  // Documents the contract rather than testing much: the failure branch only ever carries names.
  const result = resolveEnvConfig(() => undefined);
  assert.equal(result.ok, false);
  if (!result.ok) {
    for (const name of result.missing) {
      assert.equal(typeof name, "string");
    }
    assert.equal(Object.prototype.hasOwnProperty.call(result, "config"), false);
  }
});

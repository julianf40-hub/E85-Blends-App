// 85Blends 2.3.0 — Phase B1. Tests for revenuecat-webhook-parser.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { dedupeNonEmptyStrings, parseWebhookEvent } from "./revenuecat-webhook-parser.ts";

test("parseWebhookEvent: normal purchase event", () => {
  const result = parseWebhookEvent({
    api_version: "1.0",
    event: {
      id: "evt_1",
      type: "INITIAL_PURCHASE",
      event_timestamp_ms: 1700000000000,
      app_user_id: "user_a",
      original_app_user_id: "user_a",
      aliases: ["user_a", "anon_1"],
      environment: "PRODUCTION",
    },
  });
  assert.equal(result.kind, "normal");
  if (result.kind === "normal") {
    assert.equal(result.environment, "PRODUCTION");
    assert.equal(result.appUserId, "user_a");
    assert.equal(result.originalAppUserId, "user_a");
    assert.deepEqual(result.aliasSet, ["user_a", "anon_1"]);
  }
});

test("parseWebhookEvent: normal event missing original_app_user_id -> stays null, never fabricated", () => {
  // Ledger-completeness fix regression test (requirement 2: missing values remain NULL). A normal
  // event is still classifiable from app_user_id alone; originalAppUserId must not be backfilled
  // from app_user_id or aliasSet — those are separate fields entirely, see
  // supabase/functions/revenuecat-webhook/index.ts's ledgerIdentityFields().
  const result = parseWebhookEvent({
    event: {
      id: "evt_no_original",
      type: "RENEWAL",
      event_timestamp_ms: 1700000000000,
      app_user_id: "user_only",
      environment: "PRODUCTION",
      // original_app_user_id intentionally absent
    },
  });
  assert.equal(result.kind, "normal");
  if (result.kind === "normal") {
    assert.equal(result.appUserId, "user_only");
    assert.equal(result.originalAppUserId, null);
  }
});

test("parseWebhookEvent: aliases are deduplicated across app_user_id/original_app_user_id/aliases[]", () => {
  const result = parseWebhookEvent({
    event: {
      id: "evt_2",
      type: "RENEWAL",
      event_timestamp_ms: 1700000000000,
      app_user_id: "user_a",
      original_app_user_id: "user_a",
      aliases: ["user_a", "user_a", "anon_1", "", null],
      environment: "SANDBOX",
    },
  });
  assert.equal(result.kind, "normal");
  if (result.kind === "normal") {
    assert.deepEqual(result.aliasSet, ["user_a", "anon_1"]);
  }
});

test("parseWebhookEvent: TEST event", () => {
  const result = parseWebhookEvent({
    event: { id: "evt_test", type: "TEST", event_timestamp_ms: 1700000000000, app_user_id: "sample_user" },
  });
  assert.equal(result.kind, "test");
  if (result.kind === "test") {
    assert.equal(result.core.id, "evt_test");
  }
});

test("parseWebhookEvent: TRANSFER shape", () => {
  const result = parseWebhookEvent({
    event: {
      id: "evt_transfer",
      type: "TRANSFER",
      event_timestamp_ms: 1700000000000,
      transferred_from: ["anon_old", "anon_old"],
      transferred_to: ["anon_new"],
      environment: "PRODUCTION",
    },
  });
  assert.equal(result.kind, "transfer");
  if (result.kind === "transfer") {
    assert.deepEqual(result.transferredFrom, ["anon_old"]);
    assert.deepEqual(result.transferredTo, ["anon_new"]);
    assert.equal(result.environment, "PRODUCTION");
    // Ledger-completeness fix: absent from this payload -> stays null, never fabricated from
    // transferred_from/transferred_to (a different kind of identity information).
    assert.equal(result.originalAppUserId, null);
  }
});

test("parseWebhookEvent: TRANSFER with no environment field", () => {
  const result = parseWebhookEvent({
    event: {
      id: "evt_transfer_2",
      type: "TRANSFER",
      event_timestamp_ms: 1700000000000,
      transferred_from: ["a"],
      transferred_to: ["b"],
    },
  });
  assert.equal(result.kind, "transfer");
  if (result.kind === "transfer") {
    assert.equal(result.environment, null);
    assert.equal(result.originalAppUserId, null);
  }
});

test("parseWebhookEvent: TRANSFER carrying original_app_user_id -> captured for ledger completeness", () => {
  // Ledger-completeness fix: RevenueCat's TRANSFER payload doesn't always carry a top-level
  // original_app_user_id, but when it does, the ledger should record it — see
  // supabase/functions/revenuecat-webhook/index.ts's ledgerIdentityFields().
  const result = parseWebhookEvent({
    event: {
      id: "evt_transfer_3",
      type: "TRANSFER",
      event_timestamp_ms: 1700000000000,
      transferred_from: ["anon_old"],
      transferred_to: ["anon_new"],
      environment: "SANDBOX",
      original_app_user_id: "canonical_user_z",
    },
  });
  assert.equal(result.kind, "transfer");
  if (result.kind === "transfer") {
    assert.equal(result.originalAppUserId, "canonical_user_z");
  }
});

test("parseWebhookEvent: TEMPORARY_ENTITLEMENT_GRANT missing normal fields", () => {
  const result = parseWebhookEvent({
    event: {
      id: "evt_grant",
      type: "TEMPORARY_ENTITLEMENT_GRANT",
      event_timestamp_ms: 1700000000000,
      app_user_id: "user_a",
      // original_app_user_id, aliases, environment intentionally absent
    },
  });
  assert.equal(result.kind, "temporary_entitlement_grant");
  if (result.kind === "temporary_entitlement_grant") {
    assert.equal(result.appUserId, "user_a");
    assert.equal(result.environment, null);
  }
});

test("parseWebhookEvent: unknown additional JSON fields are tolerated", () => {
  const result = parseWebhookEvent({
    event: {
      id: "evt_future",
      type: "SOME_FUTURE_EVENT_TYPE",
      event_timestamp_ms: 1700000000000,
      app_user_id: "user_a",
      environment: "PRODUCTION",
      a_field_that_does_not_exist_yet: { nested: true },
    },
  });
  // Falls through to the "normal" shape check since it has environment + an identity field —
  // classification is based on what the event carries, not a fixed allowlist of event.type.
  assert.equal(result.kind, "normal");
});

test("parseWebhookEvent: unknown event type without environment/identity -> insufficient, not rejected", () => {
  const result = parseWebhookEvent({
    event: { id: "evt_future_2", type: "SOME_FUTURE_EVENT_TYPE", event_timestamp_ms: 1700000000000 },
  });
  assert.equal(result.kind, "insufficient");
});

test("parseWebhookEvent: missing event.id is malformed", () => {
  const result = parseWebhookEvent({ event: { type: "TEST", event_timestamp_ms: 1 } });
  assert.equal(result.kind, "malformed");
});

test("parseWebhookEvent: missing event object entirely is malformed", () => {
  const result = parseWebhookEvent({ api_version: "1.0" });
  assert.equal(result.kind, "malformed");
});

test("parseWebhookEvent: non-object root is malformed", () => {
  assert.equal(parseWebhookEvent("not an object").kind, "malformed");
  assert.equal(parseWebhookEvent(null).kind, "malformed");
  assert.equal(parseWebhookEvent(42).kind, "malformed");
});

test("parseWebhookEvent: normal-shaped event with invalid environment -> insufficient", () => {
  const result = parseWebhookEvent({
    event: {
      id: "evt_3",
      type: "EXPIRATION",
      event_timestamp_ms: 1700000000000,
      app_user_id: "user_a",
      environment: "STAGING", // not a real RevenueCat environment value
    },
  });
  assert.equal(result.kind, "insufficient");
});

test("dedupeNonEmptyStrings: filters null/empty/whitespace and dedupes preserving order", () => {
  assert.deepEqual(
    dedupeNonEmptyStrings(["a", null, "", "  ", "b", "a", undefined, 42, "b"]),
    ["a", "b"],
  );
});

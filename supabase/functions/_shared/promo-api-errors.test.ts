// 85Blends 2.4.0 — Tests for promo-api-errors.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mapClaimOutcomeToError, buildSafeErrorLogMetadata } from "./promo-api-errors.ts";
import { buildSafeErrorLogMetadata as referralBuildSafeErrorLogMetadata } from "./referral-api-errors.ts";

test("mapClaimOutcomeToError: every documented private.claim_promo_campaign failure outcome maps to its exact typed code", () => {
  assert.deepEqual(mapClaimOutcomeToError("campaign_not_found"), { httpStatus: 404, code: "campaign_not_found" });
  assert.deepEqual(mapClaimOutcomeToError("campaign_not_active"), { httpStatus: 409, code: "campaign_not_active" });
  assert.deepEqual(mapClaimOutcomeToError("campaign_not_started"), { httpStatus: 409, code: "campaign_not_started" });
  assert.deepEqual(mapClaimOutcomeToError("campaign_ended"), { httpStatus: 409, code: "campaign_ended" });
  assert.deepEqual(mapClaimOutcomeToError("eligibility_unverified"), { httpStatus: 409, code: "eligibility_unverified" });
  assert.deepEqual(mapClaimOutcomeToError("product_not_eligible"), { httpStatus: 409, code: "product_not_eligible" });
  assert.deepEqual(mapClaimOutcomeToError("campaign_exhausted"), { httpStatus: 409, code: "campaign_exhausted" });
  assert.deepEqual(mapClaimOutcomeToError("offer_pool_exhausted"), { httpStatus: 409, code: "offer_pool_exhausted" });
  assert.deepEqual(mapClaimOutcomeToError("claim_plan_conflict"), { httpStatus: 409, code: "claim_plan_conflict" });
});

test("mapClaimOutcomeToError: an unrecognized outcome falls back to a generic 500 internal_error, never leaking the raw value", () => {
  const mapping = mapClaimOutcomeToError("some_future_outcome_this_map_does_not_know_about");
  assert.deepEqual(mapping, { httpStatus: 500, code: "internal_error" });
});

test("mapClaimOutcomeToError: 'claimed' and 'already_claimed' are success outcomes with no error mapping — callers must branch on them directly", () => {
  // Both fall through to the generic 500 fallback here specifically because this map is only ever
  // consulted for FAILURE outcomes in practice (see promo-api/index.ts) — this test documents that
  // contract rather than asserting a meaningful mapping exists for either.
  assert.deepEqual(mapClaimOutcomeToError("claimed"), { httpStatus: 500, code: "internal_error" });
  assert.deepEqual(mapClaimOutcomeToError("already_claimed"), { httpStatus: 500, code: "internal_error" });
});

test("buildSafeErrorLogMetadata: re-exported directly from referral-api-errors.ts, not a separate/drifting copy", () => {
  assert.equal(buildSafeErrorLogMetadata, referralBuildSafeErrorLogMetadata);
  assert.deepEqual(buildSafeErrorLogMetadata("23505"), { errorCategory: "database_error", sqlState: "23505" });
  assert.deepEqual(buildSafeErrorLogMetadata(undefined), { errorCategory: "database_error" });
});

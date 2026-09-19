// 85Blends 2.4.0 — Tests for referral-api-errors.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mapReferralFunctionError } from "./referral-api-errors.ts";

const cases: [string, { httpStatus: number; code: string }][] = [
  ["installation_id_required", { httpStatus: 400, code: "invalid_request_body" }],
  ["invalid_environment", { httpStatus: 400, code: "invalid_request_body" }],
  [
    "referral_alias_conflict: app_user_id already attached to a different referral participant",
    { httpStatus: 409, code: "revenuecat_identity_conflict" },
  ],
  ["referral_alias_missing_after_insert", { httpStatus: 500, code: "internal_error" }],
  ["referred_participant_required", { httpStatus: 500, code: "internal_error" }],
  ["invalid_referral_code", { httpStatus: 400, code: "invalid_referral_code" }],
  ["referral_code_not_found", { httpStatus: 404, code: "referral_code_not_found" }],
  ["self_referral_not_allowed", { httpStatus: 409, code: "self_referral_not_allowed" }],
  ["referral_already_attributed", { httpStatus: 409, code: "referral_already_applied" }],
];

for (const [message, expected] of cases) {
  test(`mapReferralFunctionError("${message}") maps to ${expected.httpStatus} ${expected.code}`, () => {
    assert.deepEqual(mapReferralFunctionError(message), expected);
  });
}

test("mapReferralFunctionError: unrecognized message falls back to a generic 500, never leaking detail", () => {
  const result = mapReferralFunctionError('duplicate key value violates unique constraint "some_pkey"');
  assert.deepEqual(result, { httpStatus: 500, code: "internal_error" });
});

test("mapReferralFunctionError: tolerates surrounding whitespace", () => {
  const result = mapReferralFunctionError("  self_referral_not_allowed  ");
  assert.deepEqual(result, { httpStatus: 409, code: "self_referral_not_allowed" });
});

test("mapReferralFunctionError: never matches a message that merely contains a known key as a substring elsewhere", () => {
  // Guards the matcher itself: "not_self_referral_not_allowed_at_all" must NOT match
  // "self_referral_not_allowed" just because it appears as a substring.
  const result = mapReferralFunctionError("not_self_referral_not_allowed_at_all");
  assert.deepEqual(result, { httpStatus: 500, code: "internal_error" });
});

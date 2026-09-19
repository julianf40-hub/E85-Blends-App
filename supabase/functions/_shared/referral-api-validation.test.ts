// 85Blends 2.4.0 — Tests for referral-api-validation.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  isValidUuid,
  isValidInstallationSecret,
  isValidRevenueCatAppUserId,
  isValidRevenueCatEnvironment,
  isValidReferralCodeFormat,
  normalizeReferralCode,
  parseApiRequest,
  MIN_INSTALLATION_SECRET_LENGTH,
} from "./referral-api-validation.ts";

const VALID_UUID = "0d5b1e2a-4f3c-4a1b-9e2d-6c7a8b9c0d1e";
const VALID_SECRET = "a".repeat(MIN_INSTALLATION_SECRET_LENGTH);

test("isValidUuid: accepts a well-formed UUID", () => {
  assert.equal(isValidUuid(VALID_UUID), true);
});

test("isValidUuid: rejects non-UUID strings and non-strings", () => {
  assert.equal(isValidUuid("not-a-uuid"), false);
  assert.equal(isValidUuid(""), false);
  assert.equal(isValidUuid(12345), false);
  assert.equal(isValidUuid(null), false);
  assert.equal(isValidUuid(undefined), false);
});

test("isValidInstallationSecret: enforces the minimum length", () => {
  assert.equal(isValidInstallationSecret("a".repeat(MIN_INSTALLATION_SECRET_LENGTH)), true);
  assert.equal(isValidInstallationSecret("a".repeat(MIN_INSTALLATION_SECRET_LENGTH - 1)), false);
  assert.equal(isValidInstallationSecret(""), false);
  assert.equal(isValidInstallationSecret(12345), false);
});

test("isValidRevenueCatAppUserId: rejects empty/whitespace-only and oversized values", () => {
  assert.equal(isValidRevenueCatAppUserId("user_123"), true);
  assert.equal(isValidRevenueCatAppUserId("  user_123  "), true);
  assert.equal(isValidRevenueCatAppUserId(""), false);
  assert.equal(isValidRevenueCatAppUserId("   "), false);
  assert.equal(isValidRevenueCatAppUserId("x".repeat(257)), false);
  assert.equal(isValidRevenueCatAppUserId("x".repeat(256)), true);
});

test("isValidRevenueCatEnvironment: only SANDBOX/PRODUCTION", () => {
  assert.equal(isValidRevenueCatEnvironment("SANDBOX"), true);
  assert.equal(isValidRevenueCatEnvironment("PRODUCTION"), true);
  assert.equal(isValidRevenueCatEnvironment("production"), false);
  assert.equal(isValidRevenueCatEnvironment("STAGING"), false);
  assert.equal(isValidRevenueCatEnvironment(""), false);
});

test("isValidReferralCodeFormat: matches generate_referral_code's exact alphabet/length", () => {
  assert.equal(isValidReferralCodeFormat("23456789"), true);
  assert.equal(isValidReferralCodeFormat("ABCDEFGH"), true);
  // 0/1/I/O are deliberately excluded from the alphabet.
  assert.equal(isValidReferralCodeFormat("0BCDEFGH"), false);
  assert.equal(isValidReferralCodeFormat("1BCDEFGH"), false);
  assert.equal(isValidReferralCodeFormat("IBCDEFGH"), false);
  assert.equal(isValidReferralCodeFormat("OBCDEFGH"), false);
  assert.equal(isValidReferralCodeFormat("ABCDEFG"), false); // 7 chars
  assert.equal(isValidReferralCodeFormat("ABCDEFGHI"), false); // 9 chars (and contains I anyway)
  assert.equal(isValidReferralCodeFormat("abcdefgh"), false); // lowercase never accepted
});

test("normalizeReferralCode: trims and uppercases, matching apply_referral_code's own normalization", () => {
  assert.equal(normalizeReferralCode("  abcd2345  "), "ABCD2345");
  assert.equal(normalizeReferralCode("ABCD2345"), "ABCD2345");
});

test("parseApiRequest: missing action -> unknown_action", () => {
  const result = parseApiRequest({});
  assert.deepEqual(result, { ok: false, code: "unknown_action" });
});

test("parseApiRequest: unrecognized action -> unknown_action", () => {
  const result = parseApiRequest({ action: "redeem" });
  assert.deepEqual(result, { ok: false, code: "unknown_action" });
});

test("parseApiRequest: non-object body -> invalid_request_body", () => {
  assert.deepEqual(parseApiRequest(null), { ok: false, code: "invalid_request_body" });
  assert.deepEqual(parseApiRequest("hello"), { ok: false, code: "invalid_request_body" });
  assert.deepEqual(parseApiRequest([1, 2, 3]), { ok: false, code: "invalid_request_body" });
});

test("parseApiRequest: status missing/malformed credentials -> invalid_request_body", () => {
  assert.deepEqual(parseApiRequest({ action: "status" }), { ok: false, code: "invalid_request_body" });
  assert.deepEqual(
    parseApiRequest({ action: "status", client_installation_id: "not-a-uuid", installation_secret: VALID_SECRET }),
    { ok: false, code: "invalid_request_body" },
  );
  assert.deepEqual(
    parseApiRequest({ action: "status", client_installation_id: VALID_UUID, installation_secret: "short" }),
    { ok: false, code: "invalid_request_body" },
  );
});

test("parseApiRequest: valid status request parses cleanly", () => {
  const result = parseApiRequest({
    action: "status",
    client_installation_id: VALID_UUID,
    installation_secret: VALID_SECRET,
  });
  assert.deepEqual(result, {
    ok: true,
    request: { action: "status", clientInstallationId: VALID_UUID, installationSecret: VALID_SECRET },
  });
});

test("parseApiRequest: valid bootstrap request parses and trims app_version", () => {
  const result = parseApiRequest({
    action: "bootstrap",
    client_installation_id: VALID_UUID,
    installation_secret: VALID_SECRET,
    revenuecat_app_user_id: "  user_123  ",
    revenuecat_environment: "PRODUCTION",
    app_version: "  2.4.0  ",
  });
  assert.equal(result.ok, true);
  if (result.ok && result.request.action === "bootstrap") {
    assert.equal(result.request.revenueCatAppUserId, "user_123");
    assert.equal(result.request.revenueCatEnvironment, "PRODUCTION");
    assert.equal(result.request.appVersion, "2.4.0");
  } else {
    assert.fail("expected a parsed bootstrap request");
  }
});

test("parseApiRequest: bootstrap without app_version -> appVersion is null", () => {
  const result = parseApiRequest({
    action: "bootstrap",
    client_installation_id: VALID_UUID,
    installation_secret: VALID_SECRET,
    revenuecat_app_user_id: "user_123",
    revenuecat_environment: "SANDBOX",
  });
  assert.equal(result.ok, true);
  if (result.ok && result.request.action === "bootstrap") {
    assert.equal(result.request.appVersion, null);
  } else {
    assert.fail("expected a parsed bootstrap request");
  }
});

test("parseApiRequest: bootstrap with invalid environment -> invalid_request_body", () => {
  const result = parseApiRequest({
    action: "bootstrap",
    client_installation_id: VALID_UUID,
    installation_secret: VALID_SECRET,
    revenuecat_app_user_id: "user_123",
    revenuecat_environment: "STAGING",
  });
  assert.deepEqual(result, { ok: false, code: "invalid_request_body" });
});

test("parseApiRequest: apply_code normalizes the referral code, format validated later by the caller", () => {
  const result = parseApiRequest({
    action: "apply_code",
    client_installation_id: VALID_UUID,
    installation_secret: VALID_SECRET,
    referral_code: "  abcd2345  ",
  });
  assert.equal(result.ok, true);
  if (result.ok && result.request.action === "apply_code") {
    assert.equal(result.request.referralCode, "ABCD2345");
  } else {
    assert.fail("expected a parsed apply_code request");
  }
});

test("parseApiRequest: apply_code with empty referral_code -> invalid_request_body (not the specific invalid_referral_code code)", () => {
  const result = parseApiRequest({
    action: "apply_code",
    client_installation_id: VALID_UUID,
    installation_secret: VALID_SECRET,
    referral_code: "   ",
  });
  assert.deepEqual(result, { ok: false, code: "invalid_request_body" });
});

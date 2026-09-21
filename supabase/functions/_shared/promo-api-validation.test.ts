// 85Blends 2.4.0 — Tests for promo-api-validation.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  normalizePromoCode,
  isValidPromoCodeFormat,
  isValidProductId,
  parsePromoApiRequest,
  MAX_PRODUCT_ID_LENGTH,
  MIN_INSTALLATION_SECRET_LENGTH,
} from "./promo-api-validation.ts";

const VALID_UUID = "0d5b1e2a-4f3c-4a1b-9e2d-6c7a8b9c0d1e";
const VALID_SECRET = "a".repeat(MIN_INSTALLATION_SECRET_LENGTH);
const VALID_PRODUCT_ID = "com.85blends.subscription.monthly";

test("normalizePromoCode: trims and uppercases", () => {
  assert.equal(normalizePromoCode("  85blends  "), "85BLENDS");
  assert.equal(normalizePromoCode("85BLENDS"), "85BLENDS");
});

test("normalizePromoCode: case-insensitive resolution — mixed case/whitespace variants all normalize identically", () => {
  const variants = ["85blends", "85BLENDS", " 85Blends ", "85BlEnDs"];
  const normalized = variants.map(normalizePromoCode);
  assert.deepEqual(new Set(normalized), new Set(["85BLENDS"]));
});

test("isValidPromoCodeFormat: accepts the conservative marketing-code alphabet", () => {
  assert.equal(isValidPromoCodeFormat("85BLENDS"), true);
  assert.equal(isValidPromoCodeFormat("HOLIDAY26"), true);
  assert.equal(isValidPromoCodeFormat("BLACKFRIDAY"), true);
  assert.equal(isValidPromoCodeFormat("SUMMER27"), true);
  assert.equal(isValidPromoCodeFormat("SUMMER-27"), true); // hyphen allowed
});

test("isValidPromoCodeFormat: rejects lowercase (must already be normalized), too short, too long, and disallowed characters", () => {
  assert.equal(isValidPromoCodeFormat("85blends"), false); // lowercase — caller must normalize first
  assert.equal(isValidPromoCodeFormat("AB"), false); // 2 chars, below the 3-char minimum
  assert.equal(isValidPromoCodeFormat("A".repeat(33)), false); // 33 chars, above the 32-char maximum
  assert.equal(isValidPromoCodeFormat("A".repeat(32)), true); // exactly 32 — upper boundary
  assert.equal(isValidPromoCodeFormat("ABC"), true); // exactly 3 — lower boundary
  assert.equal(isValidPromoCodeFormat("85BLENDS!"), false); // disallowed symbol
  assert.equal(isValidPromoCodeFormat("85 BLENDS"), false); // embedded space
});

test("isValidProductId: rejects empty/whitespace-only and oversized values", () => {
  assert.equal(isValidProductId(VALID_PRODUCT_ID), true);
  assert.equal(isValidProductId(""), false);
  assert.equal(isValidProductId("   "), false);
  assert.equal(isValidProductId("x".repeat(MAX_PRODUCT_ID_LENGTH + 1)), false);
  assert.equal(isValidProductId("x".repeat(MAX_PRODUCT_ID_LENGTH)), true);
  assert.equal(isValidProductId(12345), false);
  assert.equal(isValidProductId(null), false);
});

// MARK: — parsePromoApiRequest

test("parsePromoApiRequest: missing/unrecognized action -> unknown_action", () => {
  assert.deepEqual(parsePromoApiRequest({}), { ok: false, code: "unknown_action" });
  assert.deepEqual(parsePromoApiRequest({ action: "redeem" }), { ok: false, code: "unknown_action" });
});

test("parsePromoApiRequest: non-object body -> invalid_request_body", () => {
  assert.deepEqual(parsePromoApiRequest(null), { ok: false, code: "invalid_request_body" });
  assert.deepEqual(parsePromoApiRequest("hello"), { ok: false, code: "invalid_request_body" });
  assert.deepEqual(parsePromoApiRequest([1, 2, 3]), { ok: false, code: "invalid_request_body" });
});

test("parsePromoApiRequest: missing/malformed installation credentials -> invalid_request_body, for every action", () => {
  for (const action of ["validate", "claim", "status"]) {
    assert.deepEqual(parsePromoApiRequest({ action }), { ok: false, code: "invalid_request_body" });
    assert.deepEqual(
      parsePromoApiRequest({ action, installation_id: "not-a-uuid", installation_secret: VALID_SECRET, public_code: "85BLENDS" }),
      { ok: false, code: "invalid_request_body" },
    );
    assert.deepEqual(
      parsePromoApiRequest({ action, installation_id: VALID_UUID, installation_secret: "short", public_code: "85BLENDS" }),
      { ok: false, code: "invalid_request_body" },
    );
  }
});

test("parsePromoApiRequest: missing/blank public_code -> invalid_request_body, for every action", () => {
  for (const action of ["validate", "claim", "status"]) {
    assert.deepEqual(
      parsePromoApiRequest({ action, installation_id: VALID_UUID, installation_secret: VALID_SECRET }),
      { ok: false, code: "invalid_request_body" },
    );
    assert.deepEqual(
      parsePromoApiRequest({ action, installation_id: VALID_UUID, installation_secret: VALID_SECRET, public_code: "   " }),
      { ok: false, code: "invalid_request_body" },
    );
  }
});

test("parsePromoApiRequest: valid status request parses cleanly and normalizes public_code", () => {
  const result = parsePromoApiRequest({
    action: "status",
    installation_id: VALID_UUID,
    installation_secret: VALID_SECRET,
    public_code: "  85blends  ",
  });
  assert.deepEqual(result, {
    ok: true,
    request: {
      action: "status",
      clientInstallationId: VALID_UUID,
      installationSecret: VALID_SECRET,
      publicCode: "85BLENDS",
    },
  });
});

test("parsePromoApiRequest: status ignores a selected_product_id field even if present (not required for status)", () => {
  const result = parsePromoApiRequest({
    action: "status",
    installation_id: VALID_UUID,
    installation_secret: VALID_SECRET,
    public_code: "85BLENDS",
    selected_product_id: "not validated for status",
  });
  assert.equal(result.ok, true);
});

test("parsePromoApiRequest: validate/claim missing selected_product_id -> invalid_request_body", () => {
  for (const action of ["validate", "claim"]) {
    assert.deepEqual(
      parsePromoApiRequest({ action, installation_id: VALID_UUID, installation_secret: VALID_SECRET, public_code: "85BLENDS" }),
      { ok: false, code: "invalid_request_body" },
    );
  }
});

test("parsePromoApiRequest: valid validate request parses cleanly", () => {
  const result = parsePromoApiRequest({
    action: "validate",
    installation_id: VALID_UUID,
    installation_secret: VALID_SECRET,
    public_code: "85blends",
    selected_product_id: VALID_PRODUCT_ID,
  });
  assert.deepEqual(result, {
    ok: true,
    request: {
      action: "validate",
      clientInstallationId: VALID_UUID,
      installationSecret: VALID_SECRET,
      publicCode: "85BLENDS",
      selectedProductId: VALID_PRODUCT_ID,
      appVersion: null,
    },
  });
});

test("parsePromoApiRequest: valid claim request parses cleanly, with an app_version supplied", () => {
  const result = parsePromoApiRequest({
    action: "claim",
    installation_id: VALID_UUID,
    installation_secret: VALID_SECRET,
    public_code: "85BLENDS",
    selected_product_id: VALID_PRODUCT_ID,
    app_version: "2.4.0",
  });
  assert.deepEqual(result, {
    ok: true,
    request: {
      action: "claim",
      clientInstallationId: VALID_UUID,
      installationSecret: VALID_SECRET,
      publicCode: "85BLENDS",
      selectedProductId: VALID_PRODUCT_ID,
      appVersion: "2.4.0",
    },
  });
});

test("parsePromoApiRequest: an explicit null app_version parses as null, an invalid non-null one is rejected", () => {
  const withNull = parsePromoApiRequest({
    action: "claim",
    installation_id: VALID_UUID,
    installation_secret: VALID_SECRET,
    public_code: "85BLENDS",
    selected_product_id: VALID_PRODUCT_ID,
    app_version: null,
  });
  assert.equal(withNull.ok, true);
  if (withNull.ok && withNull.request.action !== "status") {
    assert.equal(withNull.request.appVersion, null);
  }

  const withEmpty = parsePromoApiRequest({
    action: "claim",
    installation_id: VALID_UUID,
    installation_secret: VALID_SECRET,
    public_code: "85BLENDS",
    selected_product_id: VALID_PRODUCT_ID,
    app_version: "",
  });
  assert.deepEqual(withEmpty, { ok: false, code: "invalid_request_body" });
});

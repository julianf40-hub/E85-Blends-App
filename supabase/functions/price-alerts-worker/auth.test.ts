// 85Blends 2.4.1 — Tests for price-alerts-worker/auth.ts.
// Run under Node — see supabase/functions/_shared/hmac.test.ts's header comment:
//   node --test supabase/functions/price-alerts-worker/auth.test.ts
// All credentials below are obviously fake fixtures, never real values.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  bearerToken,
  constantTimeEqual,
  CRON_SECRET_HEADER,
  isAuthorizedWorkerCall,
  MIN_CRON_SECRET_LENGTH,
} from "./auth.ts";

const CRON = "cron-secret-fixture-0123456789abcdefghij"; // 40 chars, >= MIN_CRON_SECRET_LENGTH
const SERVICE = "service-role-fixture-key";
const config = { serviceRoleKey: SERVICE, cronSecret: CRON };

function headers(init: Record<string, string>): Headers {
  return new Headers(init);
}

test("fixture sanity: the cron fixture meets the minimum length", () => {
  assert.ok(CRON.length >= MIN_CRON_SECRET_LENGTH);
  assert.equal(CRON_SECRET_HEADER, "x-85blends-cron-secret");
});

test("constantTimeEqual: equal, different, and different-length strings", () => {
  assert.equal(constantTimeEqual("abc", "abc"), true);
  assert.equal(constantTimeEqual("abc", "abd"), false);
  assert.equal(constantTimeEqual("abc", "abcd"), false);
  assert.equal(constantTimeEqual("", ""), true);
});

test("bearerToken: case-insensitive scheme, trims, empty for anything else", () => {
  assert.equal(bearerToken(headers({ authorization: "Bearer abc" })), "abc");
  assert.equal(bearerToken(headers({ authorization: "bearer   abc  " })), "abc");
  assert.equal(bearerToken(headers({ authorization: "Basic abc" })), "");
  assert.equal(bearerToken(headers({})), "");
});

test("accepts the dedicated scheduler secret header (the pg_cron path)", () => {
  assert.equal(isAuthorizedWorkerCall(headers({ [CRON_SECRET_HEADER]: CRON }), config), true);
});

test("accepts the service-role Bearer (the worker's original contract)", () => {
  assert.equal(isAuthorizedWorkerCall(headers({ authorization: `Bearer ${SERVICE}` }), config), true);
});

test("rejects a request with no credentials", () => {
  assert.equal(isAuthorizedWorkerCall(headers({}), config), false);
});

test("rejects a wrong scheduler secret and a wrong Bearer", () => {
  assert.equal(isAuthorizedWorkerCall(headers({ [CRON_SECRET_HEADER]: CRON + "x" }), config), false);
  assert.equal(isAuthorizedWorkerCall(headers({ authorization: "Bearer not-the-key" }), config), false);
});

test("a wrong value in one credential source never masks a valid one in the other", () => {
  assert.equal(
    isAuthorizedWorkerCall(headers({ [CRON_SECRET_HEADER]: "wrong", authorization: `Bearer ${SERVICE}` }), config),
    true,
  );
  assert.equal(
    isAuthorizedWorkerCall(headers({ [CRON_SECRET_HEADER]: CRON, authorization: "Bearer wrong" }), config),
    true,
  );
});

test("the scheduler secret is not accepted as a Bearer, nor the service key as the scheduler header", () => {
  assert.equal(isAuthorizedWorkerCall(headers({ authorization: `Bearer ${CRON}` }), config), false);
  assert.equal(isAuthorizedWorkerCall(headers({ [CRON_SECRET_HEADER]: SERVICE }), config), false);
});

test("an unset scheduler secret disables that path: an empty header can never match an empty config", () => {
  const noCron = { serviceRoleKey: SERVICE, cronSecret: "" };
  assert.equal(isAuthorizedWorkerCall(headers({ [CRON_SECRET_HEADER]: "" }), noCron), false);
  assert.equal(isAuthorizedWorkerCall(headers({}), noCron), false);
  // ...and the service-role path keeps working.
  assert.equal(isAuthorizedWorkerCall(headers({ authorization: `Bearer ${SERVICE}` }), noCron), true);
});

test("a scheduler secret shorter than the floor is never accepted, even when presented exactly", () => {
  const weak = "short-secret";
  assert.ok(weak.length < MIN_CRON_SECRET_LENGTH);
  assert.equal(isAuthorizedWorkerCall(headers({ [CRON_SECRET_HEADER]: weak }), { serviceRoleKey: SERVICE, cronSecret: weak }), false);
});

test("an unset service-role key disables the Bearer path: an empty Bearer can never match", () => {
  const noService = { serviceRoleKey: "", cronSecret: CRON };
  assert.equal(isAuthorizedWorkerCall(headers({ authorization: "Bearer " }), noService), false);
  assert.equal(isAuthorizedWorkerCall(headers({ authorization: "Bearer anything" }), noService), false);
  assert.equal(isAuthorizedWorkerCall(headers({ [CRON_SECRET_HEADER]: CRON }), noService), true);
});

test("neither secret configured: everything is rejected", () => {
  const none = { serviceRoleKey: "", cronSecret: "" };
  assert.equal(isAuthorizedWorkerCall(headers({ [CRON_SECRET_HEADER]: "x", authorization: "Bearer x" }), none), false);
  assert.equal(isAuthorizedWorkerCall(headers({}), none), false);
});

test("whitespace around presented credentials is trimmed", () => {
  assert.equal(isAuthorizedWorkerCall(headers({ [CRON_SECRET_HEADER]: `  ${CRON}  ` }), config), true);
});

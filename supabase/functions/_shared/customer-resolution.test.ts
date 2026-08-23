// 85Blends 2.3.0 — Phase B1. Tests for customer-resolution.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { planAliasUpserts, resolveCanonicalCustomer } from "./customer-resolution.ts";

test("resolveCanonicalCustomer: zero matches -> create using preferred anchor", () => {
  const result = resolveCanonicalCustomer([], "original_user_1");
  assert.deepEqual(result, { kind: "create", anchorAppUserId: "original_user_1" });
});

test("resolveCanonicalCustomer: one distinct customer matched (even via multiple alias rows) -> reuse", () => {
  const result = resolveCanonicalCustomer(
    [
      { appUserId: "user_a", customerId: "cust_1" },
      { appUserId: "anon_1", customerId: "cust_1" },
    ],
    "original_user_1",
  );
  assert.deepEqual(result, { kind: "reuse", customerId: "cust_1" });
});

test("resolveCanonicalCustomer: two distinct customers matched -> conflict, never silently merged", () => {
  const result = resolveCanonicalCustomer(
    [
      { appUserId: "user_a", customerId: "cust_1" },
      { appUserId: "user_b", customerId: "cust_2" },
    ],
    "original_user_1",
  );
  assert.equal(result.kind, "conflict");
  if (result.kind === "conflict") {
    assert.deepEqual(result.matchedCustomerIds.sort(), ["cust_1", "cust_2"]);
  }
});

test("planAliasUpserts: all-new aliases -> insert all", () => {
  const result = planAliasUpserts(["a", "b", "c"], "cust_1", []);
  assert.deepEqual(result, { kind: "plan", toInsert: ["a", "b", "c"] });
});

test("planAliasUpserts: already-correctly-mapped alias is a no-op, not re-inserted", () => {
  const result = planAliasUpserts(
    ["a", "b"],
    "cust_1",
    [{ appUserId: "a", customerId: "cust_1" }],
  );
  assert.deepEqual(result, { kind: "plan", toInsert: ["b"] });
});

test("planAliasUpserts: alias already belongs to a different customer -> conflict, never overwritten", () => {
  const result = planAliasUpserts(
    ["a", "b"],
    "cust_1",
    [{ appUserId: "a", customerId: "cust_OTHER" }],
  );
  assert.deepEqual(result, { kind: "conflict", conflictingAppUserIds: ["a"] });
});

test("planAliasUpserts: mix of no-op, insert, and conflict -> reports only the conflict", () => {
  const result = planAliasUpserts(
    ["already_mapped", "new_one", "stolen"],
    "cust_1",
    [
      { appUserId: "already_mapped", customerId: "cust_1" },
      { appUserId: "stolen", customerId: "cust_OTHER" },
    ],
  );
  assert.deepEqual(result, { kind: "conflict", conflictingAppUserIds: ["stolen"] });
});

// 85Blends 2.3.0 — Phase B1. Tests for customer-resolution.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { planAliasUpserts, resolveCanonicalCustomer, verifyAliasesAfterInsert } from "./customer-resolution.ts";

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

// Phase B1 review "Concurrency Hardening 2": after the planned ON CONFLICT DO NOTHING alias
// inserts run, database.ts re-reads every alias in the set inside the SAME transaction and hands
// the fresh rows to verifyAliasesAfterInsert. These tests exercise that decision in isolation.

test("verifyAliasesAfterInsert: every alias maps to the resolved customer -> ok", () => {
  const result = verifyAliasesAfterInsert(
    ["a", "b", "c"],
    "cust_1",
    [
      { appUserId: "a", customerId: "cust_1" },
      { appUserId: "b", customerId: "cust_1" },
      { appUserId: "c", customerId: "cust_1" },
    ],
  );
  assert.deepEqual(result, { kind: "ok" });
});

test("verifyAliasesAfterInsert: an alias missing from the post-insert re-read -> conflict", () => {
  // Simulates the row simply not existing after the insert attempt (e.g. the ON CONFLICT DO
  // NOTHING branch fired for a row this transaction never actually wrote, and the row also isn't
  // visible for some other reason) — must never be treated as "fine, it'll insert next time".
  const result = verifyAliasesAfterInsert(
    ["a", "b"],
    "cust_1",
    [{ appUserId: "a", customerId: "cust_1" }],
  );
  assert.deepEqual(result, { kind: "conflict", problemAppUserIds: ["b"] });
});

test("verifyAliasesAfterInsert: an alias now maps to a DIFFERENT customer than resolved -> conflict (race detected)", () => {
  // The scenario Concurrency Hardening 2 exists for: a concurrent transaction committed a
  // conflicting mapping for one of these aliases between our initial SELECT and our own insert.
  // The fresh re-read inside this transaction is what catches it.
  const result = verifyAliasesAfterInsert(
    ["a", "b"],
    "cust_1",
    [
      { appUserId: "a", customerId: "cust_1" },
      { appUserId: "b", customerId: "cust_RACED_IN_BY_ANOTHER_TX" },
    ],
  );
  assert.deepEqual(result, { kind: "conflict", problemAppUserIds: ["b"] });
});

test("verifyAliasesAfterInsert: multiple problem aliases are all reported, not just the first", () => {
  const result = verifyAliasesAfterInsert(["a", "b", "c"], "cust_1", [{ appUserId: "a", customerId: "cust_1" }]);
  assert.equal(result.kind, "conflict");
  if (result.kind === "conflict") {
    assert.deepEqual(result.problemAppUserIds.sort(), ["b", "c"]);
  }
});

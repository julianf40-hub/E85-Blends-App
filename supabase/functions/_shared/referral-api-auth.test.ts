// 85Blends 2.4.0 — Tests for referral-api-auth.ts.
// Run under Node — see hmac.test.ts's header comment.

import { test } from "node:test";
import assert from "node:assert/strict";
import { extractBearerToken, matchesAnyApiKey } from "./referral-api-auth.ts";

test("extractBearerToken: extracts the token from a well-formed Authorization header", () => {
  assert.equal(extractBearerToken("Bearer abc123"), "abc123");
  assert.equal(extractBearerToken("bearer abc123"), "abc123"); // case-insensitive scheme
});

test("extractBearerToken: null for missing/malformed headers", () => {
  assert.equal(extractBearerToken(null), null);
  assert.equal(extractBearerToken(""), null);
  assert.equal(extractBearerToken("Basic abc123"), null);
  assert.equal(extractBearerToken("Bearer"), null); // no token
});

test("matchesAnyApiKey: accepted when it matches any configured key", () => {
  assert.equal(matchesAnyApiKey("key-b", ["key-a", "key-b", "key-c"]), true);
});

test("matchesAnyApiKey: rejected when it matches none", () => {
  assert.equal(matchesAnyApiKey("key-z", ["key-a", "key-b", "key-c"]), false);
});

test("matchesAnyApiKey: rejected when supplied key is null", () => {
  assert.equal(matchesAnyApiKey(null, ["key-a"]), false);
});

test("matchesAnyApiKey: rejected when no keys are configured at all", () => {
  assert.equal(matchesAnyApiKey("key-a", []), false);
});

test("matchesAnyApiKey: exact match required, no partial/prefix match", () => {
  assert.equal(matchesAnyApiKey("key-a-extra", ["key-a"]), false);
  assert.equal(matchesAnyApiKey("key-a", ["key-a-extra"]), false);
});

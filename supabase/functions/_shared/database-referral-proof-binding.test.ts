// 85Blends 2.4.0 Referral Reward Redemption, fifth correctness hardening pass — static assertions
// over _shared/database.ts's own SQL text for the RENEWAL-qualify proof check in
// applyReferralAction.
//
// WHY STATIC, NOT A LIVE-DATABASE TEST: database.ts uses the Deno-idiomatic `npm:postgres`
// specifier (see that file's own header) and is therefore not importable/executable under Node in
// this environment — this is the SAME limitation the rest of this feature already documents for
// database.ts (see docs/REFERRAL_REWARD_REDEMPTION_2.4.0.md §11: "referral-api/index.ts,
// revenuecat-webhook/index.ts, database.ts ... require Deno"). The identity/environment-binding fix
// this file guards was verified against a REAL local Postgres 16 instance (a dedicated 7-scenario
// script — A: correct participant+environment+reward-code proof succeeds; B: wrong participant
// fails; C: wrong environment fails; D: correct deferred-origin proof succeeds; E: deferred-origin
// row under another participant's alias set fails; F: a SANDBOX-environment redeemed code can never
// authorize a PRODUCTION qualification; G: the public-promo free-start -> paid-renewal scenario
// still qualifies under the hardened query — see the PR's own report for the exact commands run),
// not by this file, which cannot execute SQL at all. This file exists ONLY as a cheap, permanent,
// CI-visible regression guard against someone silently reverting the binding while editing this
// function later — mirroring the exact same static-assertion pattern and the exact same honesty
// about its own limits already established by
// supabase/migrations/20260921000000_promo_campaign_foundation.test.ts (see that file's own header
// for the full rationale, including a real 42702 bug a static test alone could never have caught).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const DATABASE_TS_PATH = join(dirname(fileURLToPath(import.meta.url)), "database.ts");
const source = readFileSync(DATABASE_TS_PATH, "utf8");

// Isolates just the RENEWAL-qualify proof check's own SQL template literal, so these assertions
// can't accidentally pass by matching an unrelated part of this large file.
function extractProofQueryBlock(): string {
  const marker = "input.action === \"qualify\" && input.requiresRewardRedemptionProof";
  const markerIndex = source.indexOf(marker);
  assert.ok(markerIndex >= 0, "expected to find the requiresRewardRedemptionProof branch in database.ts");
  // The proof query's own template literal is comfortably within the next 2000 characters of this
  // branch in the current implementation; a generous slice avoids brittleness to exact formatting.
  return source.slice(markerIndex, markerIndex + 2000);
}

test("the reward-offer-code proof source joins referral_participant_aliases and binds app_user_id to the CURRENT webhook event's own alias set", () => {
  const block = extractProofQueryBlock();
  assert.ok(
    block.includes("private.referral_reward_offer_codes roc"),
    "expected the reward-offer-code proof source to be aliased as roc for the identity join",
  );
  assert.ok(
    block.includes("join private.referral_participant_aliases rpa") &&
      block.includes("rpa.participant_id = roc.referrer_participant_id"),
    "expected a join from referral_reward_offer_codes.referrer_participant_id to referral_participant_aliases",
  );
});

test("the reward-offer-code proof source requires roc.environment to match the current event's environment, not just the deferred-origin source", () => {
  const block = extractProofQueryBlock();
  // A naive regression could remove this without breaking any other test, since PRODUCTION is the
  // overwhelmingly common case in every fixture — this is the exact gap the fifth hardening pass
  // closed (source 1 previously checked no environment at all).
  assert.ok(
    /roc\.environment\s*=\s*\$\{input\.environment\}/.test(block),
    "expected the reward-offer-code proof to require roc.environment = input.environment",
  );
});

test("the deferred-paid-origin proof source joins referral_participant_aliases and binds app_user_id to the CURRENT webhook event's own alias set", () => {
  const block = extractProofQueryBlock();
  assert.ok(
    block.includes("private.referral_deferred_paid_origins rdpo"),
    "expected the deferred-origin proof source to be aliased as rdpo for the identity join",
  );
  assert.ok(
    block.includes("join private.referral_participant_aliases rpa") &&
      block.includes("rpa.participant_id = rdpo.referred_participant_id"),
    "expected a join from referral_deferred_paid_origins.referred_participant_id to referral_participant_aliases",
  );
});

test("both proof sources' identity joins require rpa.environment to match the current event's environment", () => {
  const block = extractProofQueryBlock();
  const environmentBindingCount = (block.match(/rpa\.environment\s*=\s*\$\{input\.environment\}/g) ?? []).length;
  assert.equal(
    environmentBindingCount,
    2,
    "expected exactly two rpa.environment = input.environment checks — one per proof source's identity join",
  );
});

test("both proof sources' identity joins require rpa.app_user_id to match the current event's own alias set (input.appUserIdSet), never a bare original_transaction_id match alone", () => {
  const block = extractProofQueryBlock();
  const aliasBindingCount = (block.match(/rpa\.app_user_id\s*=\s*any\(\$\{tx\.array\(input\.appUserIdSet\)\}\)/g) ?? []).length;
  assert.equal(
    aliasBindingCount,
    2,
    "expected exactly two rpa.app_user_id = any(...) checks against input.appUserIdSet — one per proof source",
  );
});

test("the deferred-paid-origin proof source still checks its own environment column directly (defense in depth beyond the alias join alone)", () => {
  const block = extractProofQueryBlock();
  assert.ok(
    /rdpo\.environment\s*=\s*\$\{input\.environment\}/.test(block),
    "expected the deferred-origin proof to also require rdpo.environment = input.environment directly",
  );
});

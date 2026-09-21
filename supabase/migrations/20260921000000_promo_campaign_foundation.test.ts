// 85Blends 2.4.0 — Static assertions over the promo campaign foundation migration's own SQL text.
// Run under Node — see supabase/functions/_shared/hmac.test.ts's header comment for why this
// works without any Deno/Postgres dependency.
//
// WHY STATIC, NOT LIVE-DATABASE TESTS: this environment has no working local Postgres/Docker
// stack — `dockerd` fails to start here (`containerd` never comes up; consistent with a
// nested-container sandbox restriction, not a configuration mistake) — so the concurrency-safety
// guarantee private.claim_promo_campaign's own header comment describes (a real row lock closing
// the "claim #101 of 100" race) could NOT be exercised against a genuinely concurrent live
// Postgres instance in this session. This file does not claim otherwise. What it DOES verify,
// honestly and mechanically: that every schema-level safety property this migration is supposed
// to establish is actually present in the SQL text that would be applied — private schema
// placement, RLS, revokes, the exact unique constraints, the product allow-list, the campaign
// status vocabulary, and that no real campaign (85BLENDS included) is seeded by this migration.
// This is deliberately NOT a substitute for running `supabase db push`/two clean replays against a
// real local stack before this migration is ever applied to production — see supabase/README.md's
// "Migrations are additive and reviewed before production apply."

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const MIGRATION_PATH = join(dirname(fileURLToPath(import.meta.url)), "20260921000000_promo_campaign_foundation.sql");
const sql = readFileSync(MIGRATION_PATH, "utf8");

function assertContains(needle: string, message: string) {
  assert.ok(sql.includes(needle), `${message}\nExpected migration text to contain: ${needle}`);
}

function assertNotContains(needle: string, message: string) {
  assert.ok(!sql.includes(needle), `${message}\nExpected migration text to NOT contain: ${needle}`);
}

// MARK: — private schema placement (every new object)

test("every new table lives in the private schema", () => {
  for (const table of ["promo_campaigns", "promo_campaign_plan_offers", "promo_offer_codes", "promo_claims", "promo_code_attempts"]) {
    assertContains(`create table private.${table}`, `${table} must be created in the private schema`);
  }
});

test("every new function lives in the private schema", () => {
  for (const fn of ["normalize_promo_code", "claim_promo_campaign", "enforce_promo_offer_code_status_transition"]) {
    assertContains(`private.${fn}`, `${fn} must be defined in the private schema`);
  }
});

// MARK: — RLS enabled on every new table

test("RLS is enabled on every new table", () => {
  for (const table of ["promo_campaigns", "promo_campaign_plan_offers", "promo_offer_codes", "promo_claims", "promo_code_attempts"]) {
    assertContains(`alter table private.${table} enable row level security`, `${table} must have RLS enabled`);
  }
});

test("no CREATE POLICY statement exists anywhere in this migration — zero client policies, matching every other private.* table", () => {
  assertNotContains("create policy", "this migration must never grant anon/authenticated access via an RLS policy");
});

// MARK: — revokes from public/anon/authenticated on every new table and function

test("every new table explicitly revokes all privileges from public, anon, and authenticated", () => {
  for (const table of ["promo_campaigns", "promo_campaign_plan_offers", "promo_offer_codes", "promo_claims", "promo_code_attempts"]) {
    assertContains(
      `revoke all on table private.${table} from public, anon, authenticated`,
      `${table} must revoke all privileges from public/anon/authenticated`,
    );
  }
});

test("every new function explicitly revokes execution from public, anon, and authenticated", () => {
  assertContains(
    "revoke all on function private.normalize_promo_code(text) from public, anon, authenticated",
    "normalize_promo_code must revoke execution from public/anon/authenticated",
  );
  assertContains(
    "revoke all on function private.claim_promo_campaign(uuid, uuid, text, text) from public, anon, authenticated",
    "claim_promo_campaign must revoke execution from public/anon/authenticated",
  );
  assertContains(
    "revoke all on function private.enforce_promo_offer_code_status_transition() from public, anon, authenticated",
    "enforce_promo_offer_code_status_transition must revoke execution from public/anon/authenticated",
  );
});

test("service_role is the only role ever granted anything on the new tables/functions", () => {
  // A loose but meaningful proxy: service_role must be mentioned in a grant, and no anon/
  // authenticated GRANT (as opposed to REVOKE) statement exists anywhere.
  assertContains("grant execute on function private.claim_promo_campaign", "claim_promo_campaign must be grantable to service_role");
  assertNotContains("grant select on table private.promo_campaigns to anon", "anon must never be granted table access");
  assertNotContains("grant select on table private.promo_campaigns to authenticated", "authenticated must never be granted table access");
});

// MARK: — the exact constraints Phase 11 requires

test("promo_claims has the exact one-claim-per-participant-per-campaign unique constraint", () => {
  assertContains(
    "constraint promo_claims_one_per_participant_per_campaign unique (campaign_id, participant_id)",
    "promo_claims must enforce one lifetime claim per participant per campaign",
  );
});

test("promo_claims also has the installation-scoped unique constraint (defense in depth)", () => {
  assertContains(
    "constraint promo_claims_one_per_installation_per_campaign unique (campaign_id, installation_id)",
    "promo_claims must also prevent one installation from holding two claims on the same campaign",
  );
});

test("promo_offer_codes.apple_code is globally unique", () => {
  assertContains(
    "constraint promo_offer_codes_apple_code_key unique (apple_code)",
    "the literal Apple one-time-use code must be unique across the whole table",
  );
});

test("promo_campaigns.normalized_public_code is unique and is a STORED GENERATED column (never independently writable)", () => {
  assertContains(
    "constraint promo_campaigns_normalized_public_code_key unique (normalized_public_code)",
    "normalized_public_code must be unique",
  );
  assertContains(
    "normalized_public_code text not null generated always as (private.normalize_promo_code(public_code)) stored",
    "normalized_public_code must be a STORED GENERATED column so it can never drift from public_code",
  );
});

test("promo_campaign_plan_offers enforces the exact current-product allow-list and excludes legacy quarterly", () => {
  const constraintMatch = sql.match(
    /constraint promo_campaign_plan_offers_product_id_check check \(\s*product_id in \(([\s\S]*?)\)\s*\)/,
  );
  assert.ok(constraintMatch, "expected to find promo_campaign_plan_offers_product_id_check's own CHECK clause");
  const allowedList = constraintMatch![1];

  assert.ok(allowedList.includes("com.85blends.subscription.monthly"), "the monthly product must be in the allow-list");
  assert.ok(allowedList.includes("com.85blends.subscription.threemonth"), "the three-month product must be in the allow-list");
  assert.ok(allowedList.includes("com.85blends.subscription.annual"), "the annual product must be in the allow-list");
  // Scoped to the CHECK constraint's own value list specifically — legacy quarterly legitimately
  // appears elsewhere in this migration's comments, explaining exactly why it's excluded here.
  assert.ok(!allowedList.includes("quarterly"), "legacy quarterly must never appear in the product_id allow-list itself");
});

test("promo_campaigns.status is constrained to exactly draft/active/paused/ended", () => {
  assertContains(
    "constraint promo_campaigns_status_check check (status in ('draft', 'active', 'paused', 'ended'))",
    "campaign status must be constrained to the exact four documented values",
  );
});

test("promo_offer_codes.status is constrained to exactly available/issued/redeemed/void", () => {
  assertContains(
    "constraint promo_offer_codes_status_check check (status in ('available', 'issued', 'redeemed', 'void'))",
    "offer code status must be constrained to the exact four documented values",
  );
});

test("promo_claims.status is constrained to exactly claimed/redeemed/void", () => {
  assertContains(
    "constraint promo_claims_status_check check (status in ('claimed', 'redeemed', 'void'))",
    "claim status must be constrained to the exact three documented values",
  );
});

test("promo_campaigns.fulfillment_mode is restricted to exactly one_time_pool — custom_code is documented but not yet accepted", () => {
  assertContains(
    "constraint promo_campaigns_fulfillment_mode_check check (fulfillment_mode = 'one_time_pool')",
    "fulfillment_mode must fail closed at the schema level for any unsupported mode",
  );
});

test("promo_campaigns.global_claim_limit must be null or strictly positive — zero is never a valid cap", () => {
  assertContains(
    "constraint promo_campaigns_global_claim_limit_check\n    check (global_claim_limit is null or global_claim_limit > 0)",
    "global_claim_limit must reject zero and negative values",
  );
});

test("a before-update trigger enforces the one-way offer-code status state machine (available -> issued -> redeemed/void)", () => {
  assertContains(
    "create trigger promo_offer_codes_enforce_status_transition\n  before update on private.promo_offer_codes",
    "the status-transition trigger must exist and fire on UPDATE",
  );
  assertContains(
    "old.status = 'issued' and new.status in ('redeemed', 'void')",
    "issued must only ever be able to move to redeemed or void",
  );
});

// MARK: — no real campaign is ever seeded by this migration

test("this migration never inserts a row into promo_campaigns — no real campaign, 85BLENDS included, is seeded", () => {
  assertNotContains("insert into private.promo_campaigns", "this migration must create the table only, never seed a campaign row");
});

test("the literal string 85BLENDS never appears as seeded data — only as illustrative comment text", () => {
  // 85BLENDS legitimately appears in header comments as the worked example — what must never
  // exist is an actual INSERT statement carrying it as a value.
  const insertStatements = sql.match(/insert into[^;]*;/gis) ?? [];
  for (const statement of insertStatements) {
    assert.ok(!statement.includes("85BLENDS"), `Found 85BLENDS inside an INSERT statement: ${statement}`);
  }
});

test("this migration contains no DROP TABLE, ALTER TABLE ... DROP, or TRUNCATE against any existing (non-promo_*) object — additive only", () => {
  assertNotContains("drop table", "this migration must never drop a table");
  assertNotContains("truncate", "this migration must never truncate a table");
  // The only DROP-shaped statement anywhere may be a DROP CONSTRAINT immediately followed by
  // re-adding one on a table THIS migration itself created — not present here at all.
  assertNotContains(" drop column", "this migration must never drop a column, including on an existing table");
});

test("this migration never touches referral_participants/referral_client_installations/referral_attributions/referral_rewards beyond a plain FOREIGN KEY reference", () => {
  assertNotContains("alter table private.referral_participants", "must not alter the existing referral_participants table");
  assertNotContains("alter table private.referral_attributions", "must not alter the existing referral_attributions table");
  assertNotContains("alter table private.referral_rewards", "must not alter the existing referral_rewards table");
  assertNotContains("alter table private.referral_client_installations", "must not alter the existing referral_client_installations table");
});

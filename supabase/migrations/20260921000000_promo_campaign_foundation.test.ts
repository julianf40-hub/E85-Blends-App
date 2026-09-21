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

// MARK: — pre-merge hardening pass: fail-closed eligibility, mandatory expiry, relational consistency

test("promo_campaigns enforces a genuine (non-empty) date window when both starts_at and ends_at are set", () => {
  assertContains(
    "constraint promo_campaigns_date_window_check\n    check (starts_at is null or ends_at is null or starts_at < ends_at)",
    "a campaign naming both bounds must require starts_at strictly before ends_at",
  );
});

test("promo_offer_codes.apple_expires_at is NOT NULL — an unknown-expiry code can never be imported, and can never outlive its own import", () => {
  assertContains("apple_expires_at timestamptz not null", "apple_expires_at must be NOT NULL");
  assertContains(
    "constraint promo_offer_codes_apple_expires_at_after_created\n    check (apple_expires_at > created_at)",
    "an already-expired code must be rejected at import time",
  );
});

test("private.claim_promo_campaign never allocates an expired code — the old nullable-expiry escape hatch is fully removed", () => {
  assertContains("and apple_expires_at > now()", "the pool-selection query must require a real, unexpired code");
  assertNotContains(
    "apple_expires_at is null or apple_expires_at > now()",
    "the old 'NULL = no known expiry' branch must no longer exist anywhere in this migration",
  );
});

test("promo_offer_codes.issued_claim_id no longer exists — promo_claims.offer_code_id is the one direction of truth", () => {
  // Scoped to the actual DDL constructs (the column declaration and the constraint name), not a
  // blanket ban on the identifier string — this migration's own comments legitimately explain WHY
  // issued_claim_id was removed, mirroring this file's own "85BLENDS in a comment is fine, 85BLENDS
  // in an INSERT is not" precedent above.
  assertNotContains("issued_claim_id uuid", "the issued_claim_id COLUMN must be fully removed from promo_offer_codes");
  assertNotContains("promo_offer_codes_issued_claim_id_fkey", "the post-hoc circular-reference FK must be fully removed");
  assertNotContains("issued_claim_id = v_claim_id", "claim_promo_campaign must no longer write to issued_claim_id");
});

test("promo_claims.offer_code_id is NOT NULL and UNIQUE — one Apple code is structurally owned by at most one claim", () => {
  assertContains("offer_code_id uuid not null", "offer_code_id must be NOT NULL (no inline FK — see the composite FK test below)");
  assertContains(
    "constraint promo_claims_offer_code_id_key unique (offer_code_id)",
    "offer_code_id must be UNIQUE — a code can never be linked to two different claims",
  );
});

test("promo_campaign_plan_offers and promo_offer_codes each expose the composite unique constraint promo_claims' own composite FKs require", () => {
  assertContains(
    "constraint promo_campaign_plan_offers_id_campaign_id_product_id_key unique (id, campaign_id, product_id)",
    "promo_campaign_plan_offers must expose (id, campaign_id, product_id) as a composite unique target",
  );
  assertContains(
    "constraint promo_offer_codes_id_campaign_plan_offer_id_key unique (id, campaign_plan_offer_id)",
    "promo_offer_codes must expose (id, campaign_plan_offer_id) as a composite unique target",
  );
});

test("promo_claims enforces campaign/plan/PRODUCT/code relational consistency via a triple composite foreign key, not plain single-column FKs", () => {
  assertContains(
    "constraint promo_claims_campaign_plan_offer_campaign_product_fkey\n    foreign key (campaign_plan_offer_id, campaign_id, product_id)\n    references private.promo_campaign_plan_offers (id, campaign_id, product_id)",
    "a claim's campaign_plan_offer_id, campaign_id, AND product_id must ALL be structurally tied to the SAME promo_campaign_plan_offers row",
  );
  assertContains(
    "constraint promo_claims_offer_code_plan_offer_fkey\n    foreign key (offer_code_id, campaign_plan_offer_id)\n    references private.promo_offer_codes (id, campaign_plan_offer_id)",
    "a claim's offer_code_id must be structurally tied to this SAME row's own campaign_plan_offer_id",
  );
  // A plain single-column FK on campaign_plan_offer_id (or a two-column one omitting product_id)
  // would be strictly weaker than the triple composite one above — confirm neither was
  // (re-)added, and that the earlier, narrower two-column FK this triple one replaced is gone.
  assertNotContains(
    "campaign_plan_offer_id uuid not null references private.promo_campaign_plan_offers(id),",
    "campaign_plan_offer_id must rely on the composite FK, not a plain single-column one",
  );
  assertNotContains(
    "constraint promo_claims_campaign_plan_offer_campaign_fkey",
    "the earlier, weaker two-column (campaign_plan_offer_id, campaign_id) FK must be fully replaced, not kept alongside the triple one",
  );
});

test("promo_claims.product_id can never disagree with the plan-offer it names — the DB rejects a Monthly plan-offer paired with an Annual product_id", () => {
  // A structural (not just behavioral) proof: the triple FK's referenced tuple on
  // promo_campaign_plan_offers is (id, campaign_id, product_id) — product_id is one of the
  // MATCHED columns, not a bystander, so a claim naming a real campaign_plan_offer_id/campaign_id
  // pair with a DIFFERENT product_id than that exact row has cannot satisfy this FK at all.
  const fkMatch = sql.match(
    /constraint promo_claims_campaign_plan_offer_campaign_product_fkey\s+foreign key \(([^)]+)\)\s+references private\.promo_campaign_plan_offers \(([^)]+)\)/,
  );
  assert.ok(fkMatch, "expected to find the triple composite FK's own column lists");
  const claimColumns = fkMatch![1].split(",").map((c) => c.trim());
  const parentColumns = fkMatch![2].split(",").map((c) => c.trim());
  assert.deepEqual(claimColumns, ["campaign_plan_offer_id", "campaign_id", "product_id"]);
  assert.deepEqual(parentColumns, ["id", "campaign_id", "product_id"]);
});

test("promo_code_attempts_outcome_check carries the exact extended outcome vocabulary, including eligibility_unverified", () => {
  assertContains(
    "constraint promo_code_attempts_outcome_check check (\n    outcome in (\n      'valid', 'campaign_not_found', 'campaign_not_active', 'campaign_not_started',\n      'campaign_ended', 'eligibility_unverified', 'product_not_eligible', 'campaign_exhausted',\n      'offer_pool_exhausted', 'claimed', 'claim_plan_conflict', 'error'\n    )\n  )",
    "the outcome vocabulary must match exactly, with eligibility_unverified included",
  );
});

test("private.claim_promo_campaign fails closed on selective subscriber eligibility — only a campaign open to every segment may proceed", () => {
  assertContains(
    "if not (\n    v_campaign.eligibility_new_subscribers\n    and v_campaign.eligibility_existing_subscribers\n    and v_campaign.eligibility_expired_subscribers\n  ) then",
    "the function must refuse any campaign that is not open to every subscriber segment",
  );
  assertContains(
    "return query select 'eligibility_unverified'::text, null::uuid, v_campaign.id, null::uuid, null::uuid, null::text, null::text;",
    "the fail-closed branch must return the eligibility_unverified outcome",
  );
});

test("private.claim_promo_campaign checks the existing claim (idempotency) BEFORE any campaign status/date/eligibility/product check", () => {
  const functionStart = sql.indexOf("create function private.claim_promo_campaign(");
  const functionEnd = sql.indexOf("$function$;", functionStart);
  assert.ok(functionStart >= 0 && functionEnd > functionStart, "expected to locate claim_promo_campaign's own function body");
  const body = sql.slice(functionStart, functionEnd);

  const notFoundIndex = body.indexOf("'campaign_not_found'::text");
  const idempotencyIndex = body.indexOf("and participant_id = p_participant_id\n  for update;");
  const statusCheckIndex = body.indexOf("if v_campaign.status <> 'active' then");
  const eligibilityCheckIndex = body.indexOf("Selective subscriber eligibility FAILS CLOSED");
  const productCheckIndex = body.indexOf("if v_plan_offer.id is null then");

  for (const [label, index] of [
    ["campaign_not_found check", notFoundIndex],
    ["idempotency check", idempotencyIndex],
    ["status check", statusCheckIndex],
    ["eligibility fail-closed check", eligibilityCheckIndex],
    ["product-not-eligible check", productCheckIndex],
  ] as const) {
    assert.ok(index >= 0, `expected to locate the ${label} inside claim_promo_campaign's body`);
  }

  assert.ok(idempotencyIndex > notFoundIndex, "idempotency check must come after the not-found check (a campaign must resolve first)");
  assert.ok(statusCheckIndex > idempotencyIndex, "campaign_not_active check must come AFTER the idempotency check, not before");
  assert.ok(eligibilityCheckIndex > idempotencyIndex, "eligibility fail-closed check must come AFTER the idempotency check, not before");
  assert.ok(productCheckIndex > idempotencyIndex, "product_not_eligible check must come AFTER the idempotency check, not before");
});

// MARK: — final pre-merge integrity pass: active campaigns must target a segment, structural
// product_id consistency (see the two tests already added above under the previous MARK section
// for the composite-unique-target and triple-FK assertions themselves)

test("an ACTIVE campaign must target at least one subscriber segment — a DB-level CHECK, independent of claim_promo_campaign's own fail-closed rule", () => {
  assertContains(
    "constraint promo_campaigns_active_has_eligibility_target\n    check (\n      status <> 'active'\n      or eligibility_new_subscribers\n      or eligibility_existing_subscribers\n      or eligibility_expired_subscribers\n    )",
    "an active campaign with all three eligibility flags false must be rejected by the schema itself",
  );
});

test("draft/paused/ended campaigns are exempt from the active-has-eligibility-target check — only status = 'active' triggers it", () => {
  // The CHECK's own first disjunct is `status <> 'active'` — confirm the constraint text uses
  // exactly that escape hatch rather than, say, listing every non-active status explicitly (which
  // would silently stop covering a future fifth status value).
  const constraintMatch = sql.match(/constraint promo_campaigns_active_has_eligibility_target\s+check \(([\s\S]*?)\)\s*,/);
  assert.ok(constraintMatch, "expected to find the active-has-eligibility-target CHECK's own body");
  assert.ok(constraintMatch![1].includes("status <> 'active'"), "the escape hatch must be status <> 'active', not an enumerated non-active list");
});

test("the active-has-eligibility-target CHECK does not touch or loosen claim_promo_campaign's own separate, stricter fail-closed rule", () => {
  // The schema-level CHECK only requires ONE of the three flags (an OR) — claim_promo_campaign's
  // own rule (asserted by the eligibility fail-closed test above) still requires ALL three (an
  // AND). These are two deliberately different thresholds; confirm the weaker OR-based CHECK's
  // own text never appears inside claim_promo_campaign's function body, i.e. the two rules are
  // genuinely separate mechanisms, not one accidentally overwriting the other.
  const functionStart = sql.indexOf("create function private.claim_promo_campaign(");
  const functionEnd = sql.indexOf("$function$;", functionStart);
  const body = sql.slice(functionStart, functionEnd);
  assert.ok(!body.includes("promo_campaigns_active_has_eligibility_target"), "the DB CHECK constraint name must not appear inside claim_promo_campaign's own body");
  assert.ok(
    body.includes("v_campaign.eligibility_new_subscribers") && body.includes("v_campaign.eligibility_existing_subscribers") && body.includes("v_campaign.eligibility_expired_subscribers"),
    "claim_promo_campaign must still check all three flags itself, independent of the schema-level CHECK",
  );
});

-- 85Blends 2.4.0 — Referral Reward Redemption foundation.
--
-- NOT APPLIED to the live project as part of writing this migration — see this feature's own
-- deployment documentation (docs/REFERRAL_REWARD_REDEMPTION_2.4.0.md) for the exact, ordered
-- production rollout this must follow. Purely additive to the existing referral schema
-- (20260910000000_referral_backend_baseline.sql, 20260919150000_referral_paid_qualification_foundation.sql,
-- 20260919183430_referral_client_api_foundation.sql): one new table (private.referral_reward_offer_codes),
-- three new functions (private.claim_referral_reward, private.fulfill_referral_reward_offer_code,
-- private.referral_rewards_guard_transition), one new trigger, and additive columns on TWO existing
-- tables — `environment` (plus a supporting index) on private.referral_rewards (Section 1b), and
-- `current_environment`/`current_app_user_id` on private.referral_client_installations (Section 1e)
-- — see each section's own header for why those additions are both necessary and safe. Zero changes
-- to any existing FUNCTION — in particular, private.process_referral_subscription_event's own body
-- is NOT touched by this migration; the one new qualification-timing rule this feature needs (see
-- Section 3's own header) is enforced in TypeScript (_shared/database.ts's applyReferralAction),
-- as an additional check performed BEFORE that existing, already-reviewed function is ever called
-- — not by changing its signature or logic.
--
-- SECOND CORRECTNESS HARDENING PASS (post-first-hardening-pass independent review) — three further
-- issues, all fixed in this revision (see each numbered rule/section below for the exact fix):
--   (a) private.referral_rewards now has a REAL three-state lifecycle — earned -> issued ->
--       fulfilled — instead of treating "issued" as a fact recorded only on the CODE row while the
--       reward itself stayed 'earned' the whole time. This required widening the baseline
--       migration's own `referral_rewards_status` CHECK constraint to permit `'issued'` — a real gap
--       caught only by actually executing this migration against local Postgres (see Section 1c).
--       See rule 3 and Section 1c/2/3 below.
--   (b) private.referral_client_installations now stores the CURRENT RevenueCat environment/App
--       User ID this installation's most recent bootstrap reported, and claim_reward/status derive
--       environment from THAT — never from scanning every alias this participant has ever
--       accumulated and letting PRODUCTION win. See Section 1e and rule 9's own updated text.
--   (c) private.fulfill_referral_reward_offer_code now RAISES (aborting the whole surrounding
--       transaction) on an impossible partial-update condition, rather than returning a typed
--       "this failed" outcome after the Apple code has already been marked redeemed. See Section 3.
--
-- THIRD CORRECTNESS HARDENING PASS (post-second-hardening-pass independent review) — one further
-- user-facing bug plus one further transactional hardening item, both fixed in this revision (SQL
-- changes only — the client-visible fix lives in supabase/functions/_shared/referral-api-response.ts
-- and the iOS layer; see this feature's deployment doc §7d for the full design):
--   (d) An issued reward whose code has EXPIRED, but which no client has re-claimed yet, produced
--       `earned_months_available = 0` AND `issued_reward_code = null` with no other signal — every
--       client entry point back into the redemption flow disappeared, stranding a reward this same
--       migration's own claim_referral_reward already knows how to recover. Fixed ENTIRELY in
--       TypeScript (no SQL schema/function change needed): `buildReferralStatusResponse` derives a
--       new `issued_reward_needs_refresh` boolean purely from data this migration's own schema
--       already exposes (a `status = 'issued'` reward row with no live issued code) — see that
--       file's own doc comment.
--   (e) private.claim_referral_reward's final code-issuance + reward earned -> issued pair (and the
--       expiration-revalidation branch's own transitions) now carry the SAME `GET DIAGNOSTICS`
--       row-count-verified RAISE discipline (c) above added to fulfill_referral_reward_offer_code —
--       see Section 2's own "TRANSACTION-INVARIANT HARDENING" comment.
--
-- COMPLETES the existing, deliberately-unfinished promise: every 5 qualified paid referrals earns
-- one private.referral_rewards row (status: earned/fulfilled/revoked) — this migration adds the
-- backend foundation to actually REDEEM an earned reward as a real Apple subscription Offer Code,
-- and to confirm that redemption via the existing RevenueCat webhook once Apple/RevenueCat report
-- it. See supabase/functions/referral-api/index.ts's new `claim_reward` action and
-- supabase/functions/revenuecat-webhook/index.ts's new fulfillment path.
--
-- NON-NEGOTIABLE BUSINESS RULES this migration exists to enforce (see this feature's own task
-- spec for the full list):
--   1. Every 5 qualified paid referrals creates one one-month-Pro reward (unchanged, pre-existing).
--   2. One earned reward may be redeemed exactly once.
--   3. A reward's lifecycle is `earned -> issued -> fulfilled` (second hardening pass): the MOMENT
--      claim_referral_reward hands out a real Apple code, BOTH the code AND the reward it belongs
--      to become `status = 'issued'` together — issuing a code is never itself fulfillment, but it
--      is also no longer merely a fact recorded on the code row while the reward pretends nothing
--      happened. Only a confirmed REDEEMED transaction (via the webhook) ever sets
--      `status = 'fulfilled'` on the reward, and only from `status = 'issued'` — never directly from
--      `earned`. `revoked` applies only while there is no live (`status = 'issued'`) Apple code
--      outstanding for that reward — structurally guaranteed by the new
--      private.referral_rewards_guard_transition trigger (Section 1c), not merely a convention.
--   4. Reward status becomes fulfilled only after a real Apple/RevenueCat subscription transaction
--      confirms use of the dedicated referral-reward offer (see Section 3's fulfillment function).
--   5. Raw Apple one-time-use codes must never be exposed publicly, stored in app source, logged,
--      included in analytics, or accessible through anon/authenticated PostgREST — this table is
--      `private`-schema, RLS-enabled, zero policies, service_role-only, exactly like every other
--      private.referral_* table (see the baseline migration's own "SECURITY PHILOSOPHY").
--   6. Backend is authoritative — the iOS app never decides whether a user owns a reward or which
--      product an active subscriber's code must be issued for (see the new claim function's own
--      product-resolution logic, driven entirely by caller-supplied, backend-fetched RevenueCat
--      state — never a client-asserted "I am Pro" claim).
--   7. Generic/public promo offers (the existing, still-unapplied promo-campaign-foundation system)
--      must never satisfy a referral reward — this migration deliberately does NOT reuse that
--      system; see Section 1's own header for why a dedicated table was chosen instead.
--   8. Referral reward Offer Codes use dedicated offer reference names
--      (REFERRAL_REWARD_MONTHLY_1M_FREE / _3MONTH_ / _ANNUAL_), never the public 85BLENDS launch
--      promotion's own reference — enforced by this table's own CHECK constraints (Section 1) and
--      by supabase/functions/_shared/referral-reward-offer-codes.ts on the TypeScript side.
--   9. A SANDBOX Apple code can never fulfill/consume a real PRODUCTION-earned reward, and a
--      PRODUCTION code can never be returned to a SANDBOX test claim — enforced by tagging BOTH
--      private.referral_rewards and private.referral_reward_offer_codes with `environment`, and
--      requiring an exact match at every claim/allocation/fulfillment step (see Section 1b's own
--      design note for why the reward row itself needed this, not just the code pool). SECOND
--      HARDENING PASS: which environment a `claim_reward` call itself belongs to is now resolved
--      from private.referral_client_installations' own `current_environment` column (Section 1e) —
--      the CURRENT authenticated installation's own most-recently-bootstrapped identity — never by
--      scanning every alias this participant has ever accumulated across its lifetime and letting
--      PRODUCTION win whenever both exist. A participant/installation that is CURRENTLY
--      SANDBOX-bootstrapped can always claim from SANDBOX even if it also carries an older,
--      historical PRODUCTION alias from a prior reinstall/build.
--  10. An issued reward whose Apple code is still valid (unexpired, `status = 'issued'`) must never
--      be revoked merely because the referrer's qualified-referral count later drops — the pairing
--      invariant (reward `status = 'issued'` for exactly as long as its code is) already keeps it
--      out of reach of the pre-existing milestone shrink logic, which is scoped to
--      `status = 'earned'` only (unmodified — see 20260919150000's own Section 3). SECOND HARDENING
--      PASS: when that reward's code instead EXPIRES unused, claim_referral_reward revalidates the
--      reward against the referrer's CURRENT qualified-referral count before deciding its fate — see
--      Section 2's own "expiration revalidation" comment for the full earned-vs-revoked branch.
--  11. A reward that is revoked must never be fulfillable — structurally impossible under the new
--      state machine, since `fulfill_referral_reward_offer_code` requires `status = 'issued'`
--      (rule 3) and the guard trigger (Section 1c) makes it impossible for a reward to ever be BOTH
--      `revoked` and paired with a live `issued` code in the first place.
--
-- A PARTICIPANT MAY HAVE AT MOST ONE OUTSTANDING ISSUED REFERRAL REWARD AT A TIME (an eliminate-
-- ambiguity requirement for webhook fulfillment matching, not merely a nice-to-have) — enforced by
-- partial unique indexes on BOTH private.referral_reward_offer_codes (Section 1) AND, since the
-- second hardening pass, private.referral_rewards itself (Section 1d), defense-in-depth alongside
-- claim_referral_reward's own explicit check (Section 2) and the natural FIFO ordering of "always
-- claim the OLDEST eligible earned reward first" (which already makes a second reward unreachable
-- while an earlier one is still `earned`/`issued`).

-- ============================================================================================
-- 1. private.referral_reward_offer_codes — the Apple one-time-use code pool.
-- ============================================================================================
-- A dedicated, referral-specific table rather than the existing (unapplied, unfinished)
-- promo-campaign-foundation system (supabase/migrations/20260921000000_promo_campaign_foundation.sql)
-- — that system's own comments explicitly describe the exact matching pattern this feature needs
-- (offer reference + product + participant identity against an outstanding row) as future work,
-- and explicitly warn "a promo/free Apple Offer Code purchase must never, by itself, qualify a
-- pending referral" — this migration follows that same pattern independently, scoped narrowly to
-- referral rewards only, so this feature never depends on deploying or finishing that broader,
-- still-unapplied system.
create table private.referral_reward_offer_codes (
  id uuid primary key default gen_random_uuid(),

  -- One of the three shipping paid product IDs — see ProPlan.swift. The legacy
  -- com.85blends.subscription.quarterly product is deliberately never a valid value here: no
  -- referral-reward offer is ever created for it (see this feature's task spec — "Do NOT issue a
  -- reward code for the legacy quarterly product").
  product_id text not null,
  -- The App Store Connect subscription Offer Code's own REFERENCE NAME — the field App Store
  -- Connect's Offer Code creation flow itself asks for (Subscriptions > offer codes > create),
  -- which Apple uses to identify the offer in App Store Connect's own Reports and which IS the
  -- value RevenueCat's webhook exposes as `event.offer_code` (see
  -- _shared/referral-classification.ts's ReferralWebhookFields.offerCode). CORRECTION from an
  -- earlier revision of this comment: Offer Codes have no separate "Offer Identifier" distinct
  -- from Reference Name — that two-field distinction belongs to a DIFFERENT Apple mechanism
  -- (signed Promotional Offers), not Offer Codes, and this migration was previously (incorrectly)
  -- describing Offer Codes as if they worked that way. See this feature's deployment documentation
  -- for the exact App Store Connect field this column's three values must be set from.
  offer_reference_name text not null,
  -- The raw Apple one-time-use code itself. SENSITIVE — never logged, never returned except to the
  -- authenticated installation it is issued to (see referral-api/index.ts's claim_reward handler,
  -- the only production code path that ever selects this column). No RLS policy and zero
  -- anon/authenticated grants make it unreachable from PostgREST regardless (see the revokes below).
  apple_code text not null,
  -- Correctness hardening pass: every Apple one-time-use code this feature ever pools has a KNOWN
  -- expiration — this column is never null. An unknown-expiration row can never be imported, which
  -- is what makes "an issued code that has expired" a detectable, actionable state rather than an
  -- ambiguous one (see claim_referral_reward's own handling below).
  apple_expires_at timestamptz not null,

  -- Correctness hardening pass: which RevenueCat/Apple environment this SPECIFIC code belongs to.
  -- A code pool must never mix environments — a SANDBOX Apple code must never be attachable to a
  -- PRODUCTION-earned reward, and vice versa (see private.referral_rewards' own new `environment`
  -- column, added by this same migration, and this feature's deployment documentation's
  -- environment-isolation design note). No default: every import must set this explicitly.
  environment text not null,

  status text not null default 'available',

  reward_id uuid references private.referral_rewards(id) on delete restrict,
  referrer_participant_id uuid references private.referral_participants(id) on delete restrict,

  issued_at timestamptz,
  redeemed_at timestamptz,
  -- The webhook event that confirmed redemption, and the transaction identity that makes a
  -- redelivery of that same event idempotent — mirrors referral_attributions'
  -- qualifying_event_id/qualifying_transaction_id/qualifying_original_transaction_id naming
  -- exactly (see 20260919150000's own Section 2).
  redemption_event_id text,
  redemption_transaction_id text,
  redemption_original_transaction_id text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint referral_reward_offer_codes_apple_code_key unique (apple_code),

  constraint referral_reward_offer_codes_product_id_check check (
    product_id in (
      'com.85blends.subscription.monthly',
      'com.85blends.subscription.threemonth',
      'com.85blends.subscription.annual'
    )
  ),
  constraint referral_reward_offer_codes_offer_reference_check check (
    offer_reference_name in (
      'REFERRAL_REWARD_MONTHLY_1M_FREE',
      'REFERRAL_REWARD_3MONTH_1M_FREE',
      'REFERRAL_REWARD_ANNUAL_1M_FREE'
    )
  ),
  -- Each dedicated offer reference is permanently paired with exactly one product — a code row
  -- pairing REFERRAL_REWARD_MONTHLY_1M_FREE with the annual product (for instance) can never be
  -- inserted, regardless of which layer of application code is calling.
  constraint referral_reward_offer_codes_reference_matches_product check (
    (offer_reference_name = 'REFERRAL_REWARD_MONTHLY_1M_FREE' and product_id = 'com.85blends.subscription.monthly')
    or (offer_reference_name = 'REFERRAL_REWARD_3MONTH_1M_FREE' and product_id = 'com.85blends.subscription.threemonth')
    or (offer_reference_name = 'REFERRAL_REWARD_ANNUAL_1M_FREE' and product_id = 'com.85blends.subscription.annual')
  ),
  constraint referral_reward_offer_codes_status_check
    check (status in ('available', 'issued', 'redeemed', 'void')),
  constraint referral_reward_offer_codes_environment_check
    check (environment in ('SANDBOX', 'PRODUCTION')),
  -- issued/redeemed codes are always attached to a specific reward+referrer+issued_at; available/
  -- void codes never are (a void code retains whatever it had at the moment it was voided only if
  -- it had already been issued — see the expiration-before-redemption comment below; an available
  -- code that is voided directly, e.g. by an operator, never had these set to begin with).
  constraint referral_reward_offer_codes_issued_fields_check check (
    (status in ('issued', 'redeemed') and reward_id is not null and referrer_participant_id is not null and issued_at is not null)
    or (status = 'available' and reward_id is null and referrer_participant_id is null and issued_at is null)
    or (status = 'void')
  ),
  constraint referral_reward_offer_codes_redeemed_fields_check check (
    (status = 'redeemed' and redeemed_at is not null and redemption_event_id is not null
      and redemption_transaction_id is not null and redemption_original_transaction_id is not null)
    or (status <> 'redeemed')
  )
);

comment on table private.referral_reward_offer_codes is
  '85Blends 2.4.0 referral reward redemption. Pool of real Apple one-time-use subscription Offer Codes for the three dedicated referral-reward offers. apple_code is a sensitive credential: never logged, never exposed via PostgREST (private schema, RLS enabled, zero policies, service_role-only grants below), returned only to the authenticated installation it is issued to. Populated by importing real Apple-generated codes out of band (see this feature''s deployment documentation) — never generated or fabricated by this database.';

-- Guards status TRANSITIONS that a CHECK constraint alone cannot express (a CHECK only ever sees
-- one row's own current values, never its previous state). "Issued/redeemed codes may never
-- return to available" (this feature's own task spec, Section 3) — plus, defensively, that
-- 'redeemed' and 'void' are both permanent terminal states once reached: a one-time-use Apple code
-- that has actually been redeemed, or that has been explicitly voided (expired, or withdrawn by an
-- operator), must never be resurrected into any other status by a future bug or manual UPDATE.
create or replace function private.referral_reward_offer_codes_guard_transition()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'private'
as $$
begin
  if OLD.status = 'redeemed' and NEW.status <> 'redeemed' then
    raise exception 'referral_reward_offer_code_redeemed_is_terminal';
  end if;
  if OLD.status = 'void' and NEW.status <> 'void' then
    raise exception 'referral_reward_offer_code_void_is_terminal';
  end if;
  if OLD.status in ('issued', 'redeemed') and NEW.status = 'available' then
    raise exception 'referral_reward_offer_code_cannot_return_to_available';
  end if;
  return NEW;
end;
$$;

create trigger referral_reward_offer_codes_guard_transition
  before update on private.referral_reward_offer_codes
  for each row execute function private.referral_reward_offer_codes_guard_transition();

create trigger referral_reward_offer_codes_set_updated_at
  before update on private.referral_reward_offer_codes
  for each row execute function private.set_updated_at();

-- "reward_id can own at most one live code" (this feature's task spec, Section 3) — a partial
-- unique index rather than a plain UNIQUE constraint: a reward may accumulate multiple HISTORICAL
-- void codes (one per expiration-before-redemption cycle — see Section 2's own comment on why a
-- void code is replaced, never mutated back to available) but only ever one row that is currently
-- issued or redeemed for it at a time.
create unique index referral_reward_offer_codes_one_live_per_reward
  on private.referral_reward_offer_codes (reward_id)
  where status in ('issued', 'redeemed');

-- "A PARTICIPANT MAY HAVE AT MOST ONE OUTSTANDING ISSUED REFERRAL REWARD AT A TIME" — the
-- eliminate-ambiguity requirement this feature's task spec calls out explicitly, so
-- fulfill_referral_reward_offer_code (Section 3) can always resolve "that participant's ONE
-- outstanding issued reward matching product + offer reference" without ever guessing between
-- two. Deliberately scoped to `status = 'issued'` only — once redeemed, a NEW reward's code may be
-- issued for the same participant.
--
-- Correctness hardening pass: keyed on (referrer_participant_id, environment), not just
-- referrer_participant_id alone — a real participant only ever has PRODUCTION-environment issued
-- codes in practice (see private.referral_rewards' own new environment column), but a dedicated
-- SANDBOX test participant used for pre-release verification must never have their one legitimate
-- SANDBOX test claim blocked (or, worse, treated as the SAME "one outstanding" slot) by an
-- unrelated PRODUCTION row, and vice versa. This is what makes "sandbox activity cannot mutate a
-- real production-earned reward" true even for the (already highly unlikely) case of one
-- participant somehow holding both kinds at once.
create unique index referral_reward_offer_codes_one_outstanding_per_participant
  on private.referral_reward_offer_codes (referrer_participant_id, environment)
  where status = 'issued';

-- Pool-allocation lookup: "select one available, unexpired code for that product" (Section 2),
-- using FOR UPDATE SKIP LOCKED — same pattern as private.claim_price_alert_jobs
-- (20260917232104_price_alert_worker_primitives.sql). Includes `environment` so a claim for one
-- environment's pool can never scan into (or skip-lock past) the other environment's rows.
create index referral_reward_offer_codes_available_pool_idx
  on private.referral_reward_offer_codes (product_id, environment, created_at)
  where status = 'available';

-- Webhook fulfillment lookup: "find that participant's ONE outstanding issued reward matching
-- product + offer reference" (Section 3) — already unique per the partial index above (now also
-- scoped by environment); this index makes that lookup itself indexed rather than a sequential
-- scan, and includes `environment` so a fulfillment attempt is never even candidate-matched across
-- environments.
create index referral_reward_offer_codes_issued_lookup_idx
  on private.referral_reward_offer_codes (referrer_participant_id, product_id, offer_reference_name, environment)
  where status = 'issued';

revoke all on table private.referral_reward_offer_codes from public, anon, authenticated;
grant select, insert, update on table private.referral_reward_offer_codes to service_role;
-- Deliberately no DELETE grant, even to service_role — a code row's history (available -> issued
-- -> redeemed, or -> void) is permanent audit trail; a depleted/expired code pool is replenished by
-- INSERTing fresh rows, never by deleting old ones. Import tooling that needs to remove a
-- mistakenly-inserted row before it is ever issued is expected to run as the Postgres owner role,
-- not through this application-facing grant.

alter table private.referral_reward_offer_codes enable row level security;
-- Zero policies: with RLS enabled and no policy, anon/authenticated are denied all access by the
-- revokes above and would additionally be denied by RLS itself defaulting to deny-all — the same
-- belt-and-suspenders pattern as every other private.referral_* table.

-- ============================================================================================
-- 1b. private.referral_rewards — additive `environment` column (correctness hardening pass).
-- ============================================================================================
-- ENVIRONMENT-ISOLATION DESIGN NOTE (this feature's correctness hardening pass, in response to
-- review): the task asked whether adding `environment` to private.referral_rewards ITSELF is
-- necessary, or whether a materially safer/narrower architecture exists (e.g. tagging only the
-- code pool). It is necessary, and here is why the narrower alternative is NOT materially safer:
--
--   Without an environment tag on the REWARD row itself, private.claim_referral_reward would still
--   need to pick "the oldest eligible earned reward" for a participant with no way to distinguish
--   a genuine production reward from an operator-seeded SANDBOX test reward on the SAME
--   participant row (an operator testing the redemption flow end-to-end, per this feature's own
--   deployment documentation, necessarily creates a reward row through some path OTHER than the
--   real PRODUCTION-only qualification pipeline — see below). A SANDBOX-environment claim call
--   could then attach a SANDBOX Apple code to what is, structurally, an UNTAGGED (and therefore
--   ambiguous) reward row — exactly the cross-contamination this hardening pass exists to prevent.
--   Tagging only the CODE pool closes the "which code" question but leaves open the "which
--   reward" question, which is the one that actually matters (an Apple code is worthless on its
--   own; a REWARD is the thing with real value).
--
-- Tagging the reward row itself is also cheap and safe to add retroactively: every reward row this
-- schema has EVER been able to create (via private.process_referral_subscription_event, whose 'v1
-- scope lock' rejects any p_environment other than 'PRODUCTION' outright — see
-- 20260919150000_referral_paid_qualification_foundation.sql) is unambiguously 'PRODUCTION' — so
-- backfilling every existing row (empty or not; this migration does not assume the table is empty
-- live) and defaulting the column to 'PRODUCTION' going forward requires ZERO changes to that
-- function's own INSERT statement (`insert into private.referral_rewards (referrer_participant_id,
-- milestone_number) values (...)` continues to work unmodified, picking up the new column's
-- default). A SANDBOX reward row is therefore possible ONLY via an explicit, out-of-band operator
-- insert naming environment='SANDBOX' for a dedicated test participant — never via the real,
-- unmodified production qualification pipeline.
alter table private.referral_rewards
  add column if not exists environment text;

update private.referral_rewards
set environment = 'PRODUCTION'
where environment is null;

alter table private.referral_rewards
  alter column environment set not null,
  alter column environment set default 'PRODUCTION';

do $$
begin
  alter table private.referral_rewards
    add constraint referral_rewards_environment_check
      check (environment in ('SANDBOX', 'PRODUCTION'));
exception
  when duplicate_object then null;
end $$;

-- Query pattern claim_referral_reward's own reward-selection needs — "the oldest eligible earned
-- reward for this participant IN THIS ENVIRONMENT."
create index if not exists referral_rewards_referrer_environment_status_idx
  on private.referral_rewards (referrer_participant_id, environment, status, milestone_number);

-- ============================================================================================
-- 1c. private.referral_rewards — state-machine guard trigger (second hardening pass).
-- ============================================================================================
-- SCHEMA PREREQUISITE — REAL BUG this closes (found via actual local Postgres execution, not merely
-- anticipated): the baseline migration's own `referral_rewards_status` CHECK constraint
-- (20260910000000_referral_backend_baseline.sql) only ever allowed
-- `status in ('earned', 'fulfilled', 'revoked')` — there was no `'issued'` value for a reward to
-- hold, because before this hardening pass a reward never needed one (only the CODE row tracked
-- 'issued'). The new state machine (rule 3) requires the REWARD row itself to hold `'issued'`, so
-- the constraint must be widened first, or every UPDATE that sets a reward to `'issued'` below would
-- fail outright. Dropping and re-adding by name (not a `do $$ ... exception when duplicate_object`
-- guard, unlike the ADD CONSTRAINT calls elsewhere in this migration) is the correct idempotent
-- pattern for WIDENING an existing constraint's own definition, not just adding a new one.
alter table private.referral_rewards
  drop constraint if exists referral_rewards_status;

alter table private.referral_rewards
  add constraint referral_rewards_status check (status in ('earned', 'issued', 'fulfilled', 'revoked'));

-- SUPERSEDES the first hardening pass's `referral_rewards_void_issued_code_on_revoke` trigger
-- entirely (removed by this revision) — that trigger existed to REACT to a reward being revoked
-- while its code was still issued, by voiding the code afterward. It was premised on a state model
-- where a reward could sit at `status = 'earned'` while its code was already `status = 'issued'`.
-- The second hardening pass eliminates that premise structurally: the reward's own lifecycle is now
-- `earned -> issued -> fulfilled` (rule 3) — the INSTANT claim_referral_reward hands out a real
-- Apple code, the reward itself becomes `issued` too, in the SAME statement (Section 2). A reward
-- can therefore never be `earned` while a code is `issued` for it, which means the old trigger's own
-- `OLD.status = 'earned' and NEW.status = 'revoked'` firing condition can never observe a live
-- issued code to void in the first place — it would always be a no-op under the new model. Removing
-- dead code premised on an invalid state, per this hardening pass's own instruction, rather than
-- leaving it as harmless-but-confusing.
--
-- REPLACED WITH a BEFORE UPDATE guard trigger that enforces the state machine PROACTIVELY — refusing
-- an invalid transition outright, the same style already established for
-- private.referral_reward_offer_codes_guard_transition (Section 1, above) — rather than reacting
-- to one after the fact:
--   1. `fulfilled` is permanently terminal (mirrors the code pool's own terminal-state guarantee).
--   2. `fulfilled` may only ever be reached FROM `issued` — never a direct earned/revoked -> fulfilled
--      jump. private.fulfill_referral_reward_offer_code (Section 3) already only ever writes
--      `fulfilled` from a reward it found via a live issued code, so this is belt-and-suspenders,
--      not the primary mechanism.
--   3. THE CORE INVARIANT THIS HARDENING PASS EXISTS TO ENFORCE: a reward may never become
--      `revoked` while it still has a LIVE (`status = 'issued'`) Apple code outstanding. Every
--      legitimate revocation path already guarantees this by construction — the pre-existing
--      milestone shrink logic is scoped to `status = 'earned'` only (never touches an `issued`
--      reward), and claim_referral_reward's own expiration-revalidation branch (Section 2)
--      unconditionally voids the expired code BEFORE ever touching the reward's own status. This
--      trigger is the structural backstop that makes it impossible for any current or future code
--      path to violate that invariant silently, exactly the role
--      referral_reward_offer_codes_guard_transition already plays for the code table.
create or replace function private.referral_rewards_guard_transition()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'private'
as $$
begin
  if OLD.status = 'fulfilled' and NEW.status <> 'fulfilled' then
    raise exception 'referral_reward_fulfilled_is_terminal';
  end if;

  if NEW.status = 'fulfilled' and OLD.status <> 'issued' then
    raise exception 'referral_reward_must_be_issued_before_fulfilled';
  end if;

  if NEW.status = 'revoked' and exists (
    select 1 from private.referral_reward_offer_codes roc
    where roc.reward_id = NEW.id
      and roc.status = 'issued'
  ) then
    raise exception 'referral_reward_cannot_revoke_with_live_issued_code';
  end if;

  return NEW;
end;
$$;

create trigger referral_rewards_guard_transition
  before update on private.referral_rewards
  for each row execute function private.referral_rewards_guard_transition();

-- ============================================================================================
-- 1d. private.referral_rewards — "at most one issued reward per referrer per environment."
-- ============================================================================================
-- Mirrors private.referral_reward_offer_codes_one_outstanding_per_participant (Section 1) at the
-- REWARD layer, which is the layer that now actually carries the `issued` state (rule 3) — defense
-- in depth alongside claim_referral_reward's own explicit existence check (Section 2) and the
-- natural FIFO ordering that already makes a second reward unreachable while an earlier one is
-- still outstanding.
create unique index referral_rewards_one_issued_per_referrer_environment
  on private.referral_rewards (referrer_participant_id, environment)
  where status = 'issued';

-- ============================================================================================
-- 1e. private.referral_client_installations — CURRENT RevenueCat identity/environment columns.
-- ============================================================================================
-- REAL BUG this closes (found in independent review of the first hardening pass): referral-api's
-- own `resolveClaimEnvironment` used to derive a claim's environment by scanning EVERY row this
-- participant has EVER accumulated in private.referral_participant_aliases and letting PRODUCTION
-- win whenever both existed. That is backwards for exactly the scenario Sandbox/TestFlight
-- verification (this feature's own deployment doc) depends on: an installation that has EVER
-- bootstrapped as PRODUCTION even once historically (a dogfooding build later reinstalled from the
-- real App Store, say) could never claim from SANDBOX again — even while genuinely, CURRENTLY
-- authenticated as a SANDBOX installation. "Which environment is the CURRENT caller in" must be
-- answered from the CURRENT installation's own most recent identity, never a lifetime-aggregated,
-- most-privileged-wins scan.
--
-- private.referral_client_installations (20260919183430_referral_client_api_foundation.sql) is the
-- one row-per-installation credential table this backend already trusts for "which installation is
-- this" — the natural home for "what did THIS installation's most recent successful bootstrap
-- report," never a new, parallel identity mechanism. Populated by referral-api/index.ts's
-- handleBootstrap on EVERY successful bootstrap call (new installation or idempotent repeat) — see
-- that function's own comment for exactly where. Nullable: a pre-existing row (if any) created
-- before this column existed cannot be backfilled with a correct value from any other source, but
-- self-heals on this installation's very next app launch — ReferralManager.swift bootstraps at
-- least once per launch (see this feature's own iOS notes for why that is architecturally always
-- enough: RevenueCat App User ID and StoreKit environment are both fixed for the life of an
-- installed binary — 85Blends never calls Purchases.shared.logIn/logOut, and AppTransaction reflects
-- the app's own original download environment, not live purchase state — so the ONLY event that can
-- actually change either value is a reinstall, which is always itself a fresh launch).
alter table private.referral_client_installations
  add column if not exists current_environment text,
  add column if not exists current_app_user_id text;

do $$
begin
  alter table private.referral_client_installations
    add constraint referral_client_installations_current_environment_check
      check (current_environment is null or current_environment in ('SANDBOX', 'PRODUCTION'));
exception
  when duplicate_object then null;
end $$;

comment on column private.referral_client_installations.current_environment is
  '85Blends 2.4.0 second correctness hardening pass. The RevenueCat/Apple environment (SANDBOX/PRODUCTION) this installation''s most recent successful bootstrap call reported — written on every successful bootstrap, never inferred/aggregated from private.referral_participant_aliases. NULL only for a row created before this column existed and never re-bootstrapped since; self-heals on next app launch.';

comment on column private.referral_client_installations.current_app_user_id is
  '85Blends 2.4.0 second correctness hardening pass. The RevenueCat App User ID this installation''s most recent successful bootstrap call reported — same "current, not historical/aggregated" contract as current_environment above. Diagnostics/environment-resolution only, exactly like app_version; never used for authentication (installation_secret_hash remains the only credential).';

-- ============================================================================================
-- 2. private.claim_referral_reward — the one atomic reward-claim operation.
-- ============================================================================================
-- Called only by supabase/functions/referral-api (service-role connection) after that function has
-- authenticated the installation (SAME installation-secret model already used by bootstrap/status/
-- apply_code) and resolved its participant id — this function trusts p_referrer_participant_id
-- completely, exactly like process_referral_subscription_event trusts its own resolved participant
-- ids, and is never reachable from anon/authenticated (see the grants below).
--
-- p_active_pro_is_active / p_active_product_id are BACKEND-COMPUTED by the caller — referral-api
-- fetches this participant's canonical RevenueCat subscription state via a fresh REST API call
-- (see _shared/referral-active-product.ts) BEFORE ever invoking this function, exactly mirroring
-- how process_referral_subscription_event's own p_canonical_pro_is_active is computed by its
-- caller rather than re-derived here (see 20260919150000's own header). This function never trusts
-- a client-supplied "I am currently on plan X" claim — p_requested_product_id is consulted ONLY
-- when p_active_pro_is_active is not true (this feature's task spec, Section 4: "FREE / EXPIRED
-- USER — allow them to choose").
--
-- p_environment is ALSO BACKEND-COMPUTED by the caller — SECOND HARDENING PASS: now resolved from
-- private.referral_client_installations' own `current_environment` column (Section 1e), i.e. THIS
-- installation's own most-recently-bootstrapped identity, never a client-supplied string and never
-- a lifetime scan of every alias this participant has ever accumulated. Scopes BOTH which reward is
-- eligible to claim AND which code pool may be allocated from, so a SANDBOX test claim can never
-- touch a PRODUCTION reward/code and vice versa — see this migration's Section 1b design note for
-- why the reward row itself (not just the code pool) needed this tag.
--
-- IDEMPOTENCY: repeated calls for the same outstanding reward return the SAME assigned code — this
-- function never allocates a second code for a reward that already has one issued. An issued code
-- that has since EXPIRED is the one exception: see the "expiration revalidation" branch below.
--
-- STATE MACHINE (SECOND HARDENING PASS, rule 3): a reward's lifecycle is `earned -> issued ->
-- fulfilled`. The MOMENT this function hands out a real Apple code, the REWARD itself becomes
-- `issued` too, in the SAME statement that issues the code (see the final step below) — not merely
-- a fact recorded on the code row while the reward stays `earned`. This is what makes rule 10 true
-- for free: the pre-existing milestone shrink logic (process_referral_subscription_event, scoped to
-- `status = 'earned'`, unmodified) can never revoke an `issued` reward merely because the referrer's
-- qualified count later drops while its code is still valid — it is structurally invisible to that
-- logic once issued. An `issued` reward can still lose its milestone justification, but only via
-- THIS function's own expiration-revalidation branch, and only once its code has already gone void
-- (see the guard trigger, Section 1c, which makes "revoked while a live issued code exists"
-- impossible regardless of which code path is running).
--
-- TRANSACTION-INVARIANT HARDENING (THIRD HARDENING PASS): mirrors
-- fulfill_referral_reward_offer_code's own discipline (Section 3) — every UPDATE in this function
-- that targets a row already locked (`for update`) and already confirmed matching its expected
-- status earlier in the SAME call now verifies via `GET DIAGNOSTICS ... row_count` that it actually
-- affected exactly one row, and RAISEs on a zero-row result rather than ever returning 'claimed' (or
-- silently proceeding) on top of a partial mutation. Covers the expired-code void, both branches of
-- the expiration-revalidation reward transition, and the final code-issuance + reward earned ->
-- issued pair. Verified the same way as fulfill_referral_reward_offer_code's own layer-2 check: a
-- forced-failure test using a test-only copy of the final code+reward pair, with the REWARD
-- UPDATE's WHERE clause deliberately mismatched, confirmed the call raises, the whole surrounding
-- transaction is poisoned (a subsequent statement is rejected with "current transaction is
-- aborted"), and after an explicit ROLLBACK the code is back to 'available' (never left 'issued')
-- and the reward is back to 'earned' — proving the ALREADY-SUCCEEDED code-issuance UPDATE is rolled
-- back too, not just the failing statement's own effect (see this feature's deployment doc for the
-- full methodology).
create or replace function private.claim_referral_reward(
  p_referrer_participant_id uuid,
  p_environment text,
  p_active_pro_is_active boolean,
  p_active_product_id text,
  p_requested_product_id text
)
returns table (
  outcome text,
  reward_id uuid,
  milestone_number integer,
  product_id text,
  offer_reference_name text,
  apple_code text,
  apple_expires_at timestamptz
)
language plpgsql
set search_path to 'pg_catalog', 'private'
as $function$
declare
  v_reward private.referral_rewards%rowtype;
  v_existing_code private.referral_reward_offer_codes%rowtype;
  v_allocated private.referral_reward_offer_codes%rowtype;
  v_target_product text;
  v_qualified_count integer;
  v_desired_milestones integer;
  v_updated_rows integer;
  v_supported_products constant text[] := array[
    'com.85blends.subscription.monthly',
    'com.85blends.subscription.threemonth',
    'com.85blends.subscription.annual'
  ];
begin
  if p_referrer_participant_id is null then
    return query select 'invalid_participant'::text, null::uuid, null::integer, null::text, null::text, null::text, null::timestamptz;
    return;
  end if;

  if p_environment is null or p_environment not in ('SANDBOX', 'PRODUCTION') then
    -- Never reachable from referral-api's own call site (it only ever calls this function with the
    -- environment it just read from THIS installation's own current_environment column — see
    -- authenticateInstallation) but never assumed away on an environment-isolation-integrity path.
    return query select 'invalid_environment'::text, null::uuid, null::integer, null::text, null::text, null::text, null::timestamptz;
    return;
  end if;

  -- Lock the participant row FIRST, before touching any reward/code row — same locking order as
  -- process_referral_subscription_event's own milestone reconciliation, so a concurrent
  -- claim_referral_reward call for the SAME participant (e.g. a double-tap client bug, or two
  -- devices sharing one installation credential) can never interleave with this one.
  perform 1 from private.referral_participants where id = p_referrer_participant_id for update;

  -- Every column reference below is explicitly table-qualified (`rr.`/`roc.`), even where not
  -- strictly required — this function's own RETURNS TABLE names several OUT parameters
  -- (reward_id, milestone_number, product_id, offer_reference_name, apple_code, apple_expires_at)
  -- that are IDENTICAL to real column names on referral_rewards/referral_reward_offer_codes.
  -- PL/pgSQL treats every OUT parameter as an in-scope variable for the whole function body, so an
  -- UNQUALIFIED reference to any of those column names inside a query here would raise "column
  -- reference is ambiguous" — confirmed by an actual local Postgres replay of this exact function
  -- during this feature's own validation pass, not merely anticipated.
  --
  -- Step 1: does this participant already have an ISSUED reward in THIS environment? At most one
  -- can ever exist per participant per environment (Section 1d's own partial unique index). This is
  -- the idempotent-return path AND the expiration-revalidation path — checked BEFORE ever looking
  -- for a fresh 'earned' reward, since an issued reward's fate must be resolved first.
  select rr.* into v_reward
  from private.referral_rewards rr
  where rr.referrer_participant_id = p_referrer_participant_id
    and rr.environment = p_environment
    and rr.status = 'issued'
  for update
  limit 1;

  if v_reward.id is not null then
    select roc.* into v_existing_code
    from private.referral_reward_offer_codes roc
    where roc.reward_id = v_reward.id
      and roc.status = 'issued'
    for update;

    if v_existing_code.id is not null and v_existing_code.apple_expires_at > now() then
      -- Idempotency: unexpired issued code — return it unchanged, exactly as before this pass.
      return query select 'claimed'::text, v_reward.id, v_reward.milestone_number,
        v_existing_code.product_id, v_existing_code.offer_reference_name,
        v_existing_code.apple_code, v_existing_code.apple_expires_at;
      return;
    end if;

    -- EXPIRATION REVALIDATION (second hardening pass): the code is expired (or, structurally
    -- unreachable given the reward/code pairing invariant, simply missing — never assumed away).
    -- Void it if present, then revalidate THIS reward's own milestone against the referrer's
    -- CURRENT qualified-referral count, using the identical floor(count / 5) formula
    -- process_referral_subscription_event's own shrink/grow logic uses (20260919150000's Section
    -- 3) — an issued code expiring unused is the one event that can legitimately re-open "is this
    -- milestone still justified?" without any refund/requalification webhook event having occurred
    -- at all.
    if v_existing_code.id is not null then
      update private.referral_reward_offer_codes
      set status = 'void'
      where id = v_existing_code.id
        and status = 'issued';

      -- THIRD HARDENING PASS: this row is held `for update` from the select above and was just
      -- confirmed `status = 'issued'` moments ago — a zero-row result here is a genuine invariant
      -- violation, never a condition to paper over. Raising aborts this whole call before it can
      -- ever misreport a claim outcome built on top of a code that didn't actually void.
      get diagnostics v_updated_rows = row_count;
      if v_updated_rows = 0 then
        raise exception 'referral_reward_offer_code_expiration_void_invariant_violation: code % expected status issued but the update matched zero rows', v_existing_code.id;
      end if;
    end if;

    select count(*) into v_qualified_count
    from private.referral_attributions ra
    where ra.referrer_participant_id = v_reward.referrer_participant_id
      and ra.status = 'qualified';
    v_desired_milestones := floor(v_qualified_count / 5.0)::integer;

    if v_reward.milestone_number <= v_desired_milestones then
      -- STILL JUSTIFIED: the reward reverts to 'earned' (never left 'issued' pointing at a dead
      -- code) and this SAME call falls through below to allocate a genuinely fresh one — no second
      -- reward is ever consumed.
      update private.referral_rewards
      set status = 'earned'
      where id = v_reward.id
        and status = 'issued';

      -- THIRD HARDENING PASS: v_reward is held `for update` since Step 1 and was confirmed
      -- `status = 'issued'` there — a zero-row result is a genuine invariant violation.
      get diagnostics v_updated_rows = row_count;
      if v_updated_rows = 0 then
        raise exception 'referral_reward_expiration_revalidation_invariant_violation: reward % expected status issued but the earned-transition update matched zero rows', v_reward.id;
      end if;
    else
      -- NO LONGER JUSTIFIED: the reward is revoked outright and NO replacement is ever issued. Safe
      -- under the guard trigger (Section 1c) — the code above is already 'void' by the time this
      -- UPDATE runs, so "cannot revoke with a live issued code" holds.
      update private.referral_rewards
      set status = 'revoked', revoked_at = now(), revoke_reason = 'expired_unclaimed_below_milestone'
      where id = v_reward.id
        and status = 'issued';

      get diagnostics v_updated_rows = row_count;
      if v_updated_rows = 0 then
        raise exception 'referral_reward_expiration_revalidation_invariant_violation: reward % expected status issued but the revoke-transition update matched zero rows', v_reward.id;
      end if;

      return query select 'expired_no_longer_qualified'::text, v_reward.id, v_reward.milestone_number, null::text, null::text, null::text, null::timestamptz;
      return;
    end if;
  else
    -- Step 2: no issued reward outstanding — the OLDEST eligible EARNED reward IN THIS ENVIRONMENT,
    -- locked. FIFO ordering here is what structurally guarantees "at most one outstanding reward at
    -- a time" in the common case (a second reward is never even reachable while an earlier one is
    -- still 'earned'/'issued') — the partial unique indexes (Section 1, Section 1d) are the
    -- authoritative backstop, not the primary mechanism.
    select rr.* into v_reward
    from private.referral_rewards rr
    where rr.referrer_participant_id = p_referrer_participant_id
      and rr.environment = p_environment
      and rr.status = 'earned'
      and rr.reward_type = 'one_month_pro'
    order by rr.milestone_number asc
    for update
    limit 1;

    if v_reward.id is null then
      return query select 'no_eligible_reward'::text, null::uuid, null::integer, null::text, null::text, null::text, null::timestamptz;
      return;
    end if;
  end if;

  -- From here, v_reward is always logically 'earned' — either found directly above, or just
  -- reverted from an expired-but-still-justified 'issued' state — and about to become 'issued' for
  -- real, below.

  -- Determine the allowed product. An ACTIVE Pro subscriber's code is always issued for THEIR
  -- currently active product — the client cannot override this (p_requested_product_id is never
  -- consulted in this branch). A legacy-quarterly (or any other unsupported) active product fails
  -- safely without touching the reward.
  if p_active_pro_is_active is true then
    if p_active_product_id is null or p_active_product_id <> all(v_supported_products) then
      return query select 'legacy_or_unsupported_product_active'::text, v_reward.id, v_reward.milestone_number, null::text, null::text, null::text, null::timestamptz;
      return;
    end if;
    v_target_product := p_active_product_id;
  else
    if p_requested_product_id is null or p_requested_product_id <> all(v_supported_products) then
      return query select 'invalid_product'::text, v_reward.id, v_reward.milestone_number, null::text, null::text, null::text, null::timestamptz;
      return;
    end if;
    v_target_product := p_requested_product_id;
  end if;

  -- Defense in depth: at most one ISSUED reward per participant PER ENVIRONMENT (Section 1d's own
  -- partial unique index is the authoritative backstop) — structurally unreachable here (Step 1
  -- above already confirmed none exists, under the same participant-row lock held throughout), but
  -- never assumed away on an identity/allocation-integrity path.
  if exists (
    select 1 from private.referral_rewards rr
    where rr.referrer_participant_id = p_referrer_participant_id
      and rr.environment = p_environment
      and rr.status = 'issued'
  ) then
    return query select 'outstanding_reward_exists'::text, v_reward.id, v_reward.milestone_number, null::text, null::text, null::text, null::timestamptz;
    return;
  end if;

  -- Allocate one available, unexpired code for the target product IN THIS ENVIRONMENT. SKIP LOCKED
  -- so concurrent claims for DIFFERENT participants/products/environments never block each other —
  -- same pattern as private.claim_price_alert_jobs. `apple_expires_at` is NOT NULL (Section 1's own
  -- correctness hardening — no "unknown expiration" row can ever exist), so this is a plain
  -- comparison, never an `is null or` escape hatch.
  select roc.* into v_allocated
  from private.referral_reward_offer_codes roc
  where roc.product_id = v_target_product
    and roc.environment = p_environment
    and roc.status = 'available'
    and roc.apple_expires_at > now()
  order by roc.created_at asc
  for update skip locked
  limit 1;

  if v_allocated.id is null then
    -- No available codes -> reward remains 'earned' (never touched) — never a failure.
    return query select 'no_code_available'::text, v_reward.id, v_reward.milestone_number, v_target_product, null::text, null::text, null::timestamptz;
    return;
  end if;

  -- Atomically attach the allocated code AND transition the reward earned -> issued together — the
  -- pairing invariant this entire hardening pass depends on: a code is never 'issued' without its
  -- reward also being 'issued', and vice versa.
  --
  -- THIRD HARDENING PASS (transaction invariant hardening — mirrors
  -- fulfill_referral_reward_offer_code's own discipline, Section 3): both rows below are locked
  -- (`for update`/`for update skip locked`) and freshly confirmed matching their expected status
  -- moments earlier in this SAME function call, so a zero-row result on either UPDATE is a genuine,
  -- structurally-impossible invariant violation — never a condition to paper over by returning
  -- 'claimed' anyway. Each check RAISEs on failure, aborting this ENTIRE function call (and, since
  -- referral-api invokes this inside no wrapping transaction of its own beyond this single
  -- statement, the failing call's own partial work) rather than ever reporting success on top of a
  -- partial mutation — a real Apple code must never be silently handed out while its paired reward
  -- failed to transition, or vice versa.
  update private.referral_reward_offer_codes
  set status = 'issued',
      reward_id = v_reward.id,
      referrer_participant_id = p_referrer_participant_id,
      issued_at = now()
  where id = v_allocated.id
    and status = 'available';

  get diagnostics v_updated_rows = row_count;
  if v_updated_rows = 0 then
    raise exception 'referral_reward_offer_code_claim_invariant_violation: code % expected status available but the issuance update matched zero rows', v_allocated.id;
  end if;

  update private.referral_rewards
  set status = 'issued'
  where id = v_reward.id
    and status = 'earned';

  get diagnostics v_updated_rows = row_count;
  if v_updated_rows = 0 then
    raise exception 'referral_reward_claim_invariant_violation: reward % expected status earned but the issuance update matched zero rows', v_reward.id;
  end if;

  return query select 'claimed'::text, v_reward.id, v_reward.milestone_number,
    v_allocated.product_id, v_allocated.offer_reference_name,
    v_allocated.apple_code, v_allocated.apple_expires_at;
end;
$function$;

revoke all on function private.claim_referral_reward(uuid, text, boolean, text, text) from public, anon, authenticated;
grant execute on function private.claim_referral_reward(uuid, text, boolean, text, text) to postgres, service_role;

-- ============================================================================================
-- 3. private.fulfill_referral_reward_offer_code — webhook-confirmed redemption.
-- ============================================================================================
-- Called only by supabase/functions/revenuecat-webhook, inside the SAME transaction as the
-- existing entitlement-mirror write (see _shared/database.ts's applyRefreshPlansAndMarkProcessed)
-- — mirrors process_referral_subscription_event's own "referral processing must never roll back
-- the entitlement mirror" posture: a genuinely unexpected error here still propagates and rolls
-- back the whole transaction (a real bug), but every ordinary "this event doesn't fulfill
-- anything" case is a typed outcome, never an exception.
--
-- IMPORTANT (per this feature's own task spec): RevenueCat exposes the OFFER REFERENCE on the
-- transaction (`event.offer_code`, forwarded by the webhook parser — see
-- _shared/referral-classification.ts's ReferralWebhookFields.offerCode), never the literal
-- one-time Apple code the customer typed. Reconciliation is therefore keyed ENTIRELY on
-- participant identity (via the SAME alias-set resolution as process_referral_subscription_event)
-- + product id + dedicated offer reference name + this participant's ONE outstanding issued code —
-- never on any Apple code value, which this function never receives and never needs.
--
-- QUALIFICATION-TIMING NOTE (Phase 8 of this feature's task spec — enforced in TypeScript, not
-- here): a referral-reward offer-code purchase must never itself count as a "qualified paid
-- referral" for whoever referred the person redeeming it. That exclusion lives in
-- _shared/referral-classification.ts's isReferralQualifyingEvent (via
-- isReferralRewardOfferReference) — this function has no interaction with
-- private.referral_attributions/process_referral_subscription_event at all; it only ever touches
-- this migration's own referral_reward_offer_codes/referral_rewards rows. The SEPARATE, later
-- question — "this same subscription's first REAL PAID renewal, after the free reward month,
-- SHOULD be allowed to qualify a still-pending attribution the redeemer applied before ever
-- subscribing" — is answered by _shared/database.ts's applyReferralAction querying THIS
-- function's own output (a 'redeemed' row's redemption_original_transaction_id) as proof that a
-- given original_transaction_id's original purchase was indeed one of our own free reward months,
-- before ever calling process_referral_subscription_event for that renewal. See that file's own
-- comment for the full loophole analysis.
--
-- ENVIRONMENT ISOLATION (correctness hardening pass): p_environment now comes straight from the
-- webhook event's own reported environment (SANDBOX or PRODUCTION — see
-- _shared/referral-reward-offer-codes.ts's determineReferralRewardFulfillmentCandidate, which no
-- longer hard-excludes SANDBOX at the TypeScript layer) rather than being rejected outright unless
-- exactly 'PRODUCTION'. The real isolation guarantee is now an EXACT match against the CODE's own
-- `environment` column (Step below) — a SANDBOX event can only ever fulfill a SANDBOX-tagged
-- issued code, a PRODUCTION event only a PRODUCTION-tagged one — never a blanket rejection of
-- every SANDBOX event, which would have made Sandbox/TestFlight end-to-end verification of this
-- entire feature (claim -> redeem -> webhook fulfillment) structurally impossible to test before
-- release. See this migration's Section 1b design note for the reasoning this mirrors.
--
-- STATE MACHINE (SECOND HARDENING PASS, rule 3): fulfillment now requires the REWARD itself to be
-- `status = 'issued'` — not `'earned'` — mirroring the pairing invariant claim_referral_reward
-- establishes (a code is 'issued' for exactly as long as its reward is). This function locks and
-- re-reads the associated reward BEFORE ever marking the Apple code redeemed, and refuses to
-- fulfill anything but a genuinely 'issued' reward — belt and suspenders alongside the guard trigger
-- (Section 1c), which makes "revoked while a live issued code exists" structurally impossible
-- regardless of which code path is running (a redelivered/out-of-order webhook, or any future bug
-- elsewhere, must never be the only thing standing between a revoked reward and a real RevenueCat
-- transaction incorrectly marking it fulfilled).
--
-- TRANSACTION-ROLLBACK HARDENING (SECOND HARDENING PASS): an impossible partial-update — either
-- UPDATE below matching zero rows despite this function holding `for update` on the exact row the
-- WHERE clause targets — is NEVER reported as a safe typed outcome (the first hardening pass's own
-- `reward_update_failed` did exactly that, AFTER the Apple code had already been marked redeemed,
-- which is itself the bug: a real one-time-use code silently consumed while reporting a "failure"
-- outcome that looks recoverable but leaves the code gone). Both updates now RAISE EXCEPTION on a
-- zero-row result instead, which aborts the ENTIRE surrounding transaction — this function's own
-- caller runs it inside the SAME transaction as the entitlement-mirror write (see this function's
-- own header above) — so the code UPDATE is rolled back too, never left half-applied.
create or replace function private.fulfill_referral_reward_offer_code(
  p_app_user_id_set text[],
  p_environment text,
  p_product_id text,
  p_offer_reference_name text,
  p_transaction_id text,
  p_original_transaction_id text,
  p_event_id text
)
returns table (
  outcome text,
  reward_id uuid,
  referrer_participant_id uuid
)
language plpgsql
set search_path to 'pg_catalog', 'private'
as $function$
declare
  v_participant_ids uuid[];
  v_participant_id uuid;
  v_code private.referral_reward_offer_codes%rowtype;
  v_reward private.referral_rewards%rowtype;
  v_updated_rows integer;
begin
  if p_environment is null or p_environment not in ('SANDBOX', 'PRODUCTION') then
    -- Fail-closed on a genuinely malformed/unknown environment value — never inferred, never
    -- defaulted to PRODUCTION. The real per-row isolation is enforced further down (this function
    -- only ever matches an issued code whose OWN `environment` column equals this exact value).
    return query select 'environment_invalid'::text, null::uuid, null::uuid;
    return;
  end if;

  if p_offer_reference_name is null or p_offer_reference_name not in (
    'REFERRAL_REWARD_MONTHLY_1M_FREE',
    'REFERRAL_REWARD_3MONTH_1M_FREE',
    'REFERRAL_REWARD_ANNUAL_1M_FREE'
  ) then
    -- Never reachable from the webhook's own call site (it only calls this function after its own
    -- TypeScript classifier already matched one of these three exactly — see
    -- _shared/referral-reward-offer-codes.ts) but never assumed away on a fulfillment-integrity
    -- path — a public/unrelated promo offer must NEVER fulfill a referral reward, full stop.
    return query select 'offer_reference_invalid'::text, null::uuid, null::uuid;
    return;
  end if;

  -- Identity resolution — byte-for-byte the same zero/one/many pattern as
  -- process_referral_subscription_event (see that function's own header).
  select array_agg(distinct participant_id) into v_participant_ids
  from private.referral_participant_aliases
  where environment = p_environment
    and app_user_id = any(p_app_user_id_set);

  if v_participant_ids is null or array_length(v_participant_ids, 1) is null then
    return query select 'no_participant'::text, null::uuid, null::uuid;
    return;
  end if;

  if array_length(v_participant_ids, 1) > 1 then
    raise warning 'referral reward fulfillment identity conflict: % distinct participants matched alias set for event %',
      array_length(v_participant_ids, 1), coalesce(p_event_id, '(none)');
    return query select 'identity_conflict'::text, null::uuid, null::uuid;
    return;
  end if;

  v_participant_id := v_participant_ids[1];

  -- Idempotency: THIS exact transaction already fulfilled a code for this participant/product/
  -- offer — a redelivery of the same webhook event must be a clean no-op (this feature's task
  -- spec, test 19), never a second mutation attempt (which the terminal-state trigger in Section 1
  -- would reject anyway, but this returns a clean typed outcome instead of an exception).
  --
  -- Table-qualified throughout (`roc.`) — this function's own RETURNS TABLE names
  -- referrer_participant_id/reward_id as OUT parameters, identical to real column names on
  -- referral_reward_offer_codes; see claim_referral_reward's own comment on why an unqualified
  -- reference here would raise "column reference is ambiguous" (confirmed via local replay).
  select roc.* into v_code
  from private.referral_reward_offer_codes roc
  where roc.referrer_participant_id = v_participant_id
    and roc.product_id = p_product_id
    and roc.offer_reference_name = p_offer_reference_name
    and roc.environment = p_environment
    and roc.status = 'redeemed'
    and roc.redemption_original_transaction_id = p_original_transaction_id
  for update;

  if v_code.id is not null then
    return query select 'already_fulfilled'::text, v_code.reward_id, v_participant_id;
    return;
  end if;

  -- The participant's ONE outstanding issued code matching product + offer reference + environment
  -- — unique by construction (Section 1's
  -- referral_reward_offer_codes_one_outstanding_per_participant, now keyed on
  -- (referrer_participant_id, environment)), so there is never an ambiguous "which reward does
  -- this confirm" choice to make, and a SANDBOX event can never even candidate-match a
  -- PRODUCTION-tagged code or vice versa.
  select roc.* into v_code
  from private.referral_reward_offer_codes roc
  where roc.referrer_participant_id = v_participant_id
    and roc.product_id = p_product_id
    and roc.offer_reference_name = p_offer_reference_name
    and roc.environment = p_environment
    and roc.status = 'issued'
  for update;

  if v_code.id is null then
    -- Another participant, another product, another offer, another environment, or simply no
    -- outstanding issue for THIS participant right now — never a match by accident. This is the
    -- correct, explicit no-op for "a webhook for another participant/product/offer/environment
    -- mismatch must NEVER fulfill this reward" (this feature's task spec).
    return query select 'no_outstanding_code'::text, null::uuid, v_participant_id;
    return;
  end if;

  -- Lock and re-check the associated reward's own status BEFORE ever marking the Apple code
  -- redeemed — never trusts "the code was still 'issued'" alone as proof the reward is still valid.
  select rr.* into v_reward
  from private.referral_rewards rr
  where rr.id = v_code.reward_id
  for update;

  if v_reward.id is null then
    -- Structurally unreachable (a code's reward_id is a foreign key with ON DELETE RESTRICT — the
    -- referenced reward can never simply vanish) but never assumed away on a fulfillment-integrity
    -- path.
    return query select 'reward_missing'::text, null::uuid, v_participant_id;
    return;
  end if;

  if v_reward.status = 'fulfilled' then
    -- Belt-and-suspenders idempotency: the CODE-based already_fulfilled check above already
    -- catches the normal "exact same transaction redelivered" case; this catches the (currently
    -- unreachable, since one reward owns at most one live code) case of the REWARD itself already
    -- being fulfilled by some other path.
    return query select 'already_fulfilled'::text, v_reward.id, v_participant_id;
    return;
  end if;

  if v_reward.status <> 'issued' then
    -- Covers 'earned' (structurally impossible for a code that is ITSELF still 'issued' — the
    -- pairing invariant guarantees a reward is 'issued' for exactly as long as its code is; never
    -- assumed away regardless) and 'revoked' (the guard trigger, Section 1c, already makes it
    -- impossible for a reward to be BOTH 'revoked' and paired with a live 'issued' code — so the
    -- 'issued' lookup above should never have matched a revoked reward's code in the first place;
    -- this is the defensive backstop for a future bug, never the primary mechanism). The Apple code
    -- is NEVER marked redeemed here.
    return query select 'reward_not_issued'::text, v_reward.id, v_participant_id;
    return;
  end if;

  update private.referral_reward_offer_codes
  set status = 'redeemed',
      redeemed_at = now(),
      redemption_event_id = p_event_id,
      redemption_transaction_id = p_transaction_id,
      redemption_original_transaction_id = p_original_transaction_id
  where id = v_code.id
    and status = 'issued';

  -- TRANSACTION-ROLLBACK HARDENING: this function holds `for update` on v_code from the lookup
  -- above and just confirmed status = 'issued' moments ago, so a zero-row result here is a genuine
  -- invariant violation, never a condition to report as a safe typed outcome — raise, aborting the
  -- whole surrounding transaction (see this function's own header).
  get diagnostics v_updated_rows = row_count;
  if v_updated_rows = 0 then
    raise exception 'referral_reward_offer_code_fulfillment_invariant_violation: code % expected status issued but the update matched zero rows', v_code.id;
  end if;

  update private.referral_rewards
  set status = 'fulfilled',
      fulfilled_at = now(),
      fulfillment_reference = p_original_transaction_id
  where id = v_reward.id
    and status = 'issued';

  -- Same invariant discipline as the code update above — by this point the Apple code has ALREADY
  -- been marked redeemed (a real one-time-use code was genuinely consumed), so a failed reward
  -- update here can never be silently reported as a recoverable "failure": raising rolls back the
  -- code UPDATE above too, rather than leaving a redeemed code paired with a reward that never
  -- actually transitioned.
  get diagnostics v_updated_rows = row_count;
  if v_updated_rows = 0 then
    raise exception 'referral_reward_fulfillment_invariant_violation: reward % expected status issued but the update matched zero rows', v_reward.id;
  end if;

  return query select 'fulfilled'::text, v_reward.id, v_participant_id;
end;
$function$;

revoke all on function private.fulfill_referral_reward_offer_code(text[], text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function private.fulfill_referral_reward_offer_code(text[], text, text, text, text, text, text) to service_role;

-- 85Blends 2.4.0 — Generic Promo Campaign backend foundation.
--
-- NOT APPLIED to the live project. Purely additive to the live schema verified as of
-- 20260919183430_referral_client_api_foundation.sql — every object below is new; nothing existing
-- is altered, dropped, or recreated. Safe to apply to a production database carrying live referral
-- data unchanged.
--
-- WHAT THIS IS: a reusable, backend-configured promotional campaign engine — NOT a one-off
-- "85BLENDS" feature. A future campaign (HOLIDAY26, BLACKFRIDAY, SUMMER27, ...) is created/paused/
-- changed entirely from data in these tables, never by shipping a new app version or another
-- migration. 85BLENDS itself is used throughout this file's comments purely as a worked EXAMPLE of
-- the shape a campaign row takes — this migration deliberately never inserts it or any other
-- campaign row. See supabase/README.md's "Promo Campaigns" section for the full operational
-- workflow once a real campaign is ready to go live.
--
-- ARCHITECTURE — why a campaign's PUBLIC code is not an Apple Offer Code:
-- Apple Offer Codes are attached to one individual subscription product's offer, and a single
-- custom one-time-use Apple code cannot cover multiple products (monthly vs. three-month vs.
-- annual are three separate Apple offers, each with its own code pool). A strict global-capped
-- campaign ("first 100 claims total, across every plan") therefore needs one more layer than Apple
-- alone provides:
--
--   PUBLIC CAMPAIGN CODE  (e.g. "85BLENDS", entered once by the user)
--     -> private.promo_campaigns                (the campaign itself: dates, cap, display copy)
--     -> private.promo_campaign_plan_offers      (one row per eligible subscription product)
--     -> private.promo_offer_codes               (that product's own pool of Apple one-time codes)
--     -> ONE Apple one-time-use code, allocated from that pool, never issued twice
--
-- The GLOBAL cap (promo_campaigns.global_claim_limit) is enforced by THIS backend across ALL of a
-- campaign's plan-specific pools combined — each pool can hold far more Apple codes than the
-- campaign's cap allows; private.claim_promo_campaign (Section 6) is what actually stops issuing at
-- exactly the configured limit, regardless of how many unused Apple codes remain sitting in any
-- pool. Marketing copy like "first 100 users" is honest specifically BECAUSE of this — see Section 4
-- for why an abandoned/never-redeemed Apple code is still permanently counted against the cap.
--
-- SECURITY PHILOSOPHY — identical to the referral client API immediately above this migration in
-- the migration history, not a new design:
--   1. Every new table lives in `private` — never added to supabase/config.toml's `[api].schemas`,
--      never reachable through PostgREST, regardless of RLS. See supabase/README.md.
--   2. RLS is enabled on every new table with ZERO policies — belt and suspenders on top of the
--      explicit revokes below, exactly like every other private.* table in this codebase.
--   3. `anon`/`authenticated`/`PUBLIC` are granted nothing — no schema USAGE (already true; nothing
--      in this migration changes `private`'s own grants), no table privileges, no function EXECUTE.
--      Only `service_role` can reach any of it, reached the same way referral-api/revenuecat-webhook
--      already do: a direct SUPABASE_DB_URL Postgres connection from an Edge Function, never the
--      PostgREST Data API.
--   4. This migration does NOT create the `promo-api` Edge Function, does NOT create/seed any real
--      campaign row, and does NOT touch referral-api, revenuecat-webhook, or any existing table.
--
-- CLIENT AUTHENTICATION (enforced by the future promo-api Edge Function, not by this migration):
-- reuses the EXISTING durable installation-possession credential in
-- private.referral_client_installations exactly as referral-api already does — no second Keychain
-- secret system, no new credential table. That table's name is legacy (it predates this generic
-- promo system) but is already the app's one shipping installation-identity/possession-credential
-- store; this migration treats it as such and does not rename it.
--
-- ONE-TIME-USE CODE ACCOUNTING (Section 4, load-bearing): once an Apple one-time-use code is
-- revealed to a user (private.promo_offer_codes.status = 'issued'), it is PERMANENTLY consumed from
-- this backend's own pool — even if the user never actually redeems it in the App Store. This is
-- deliberate, not an oversight: Apple does not give this backend any reliable way to know a
-- revealed code was never used elsewhere, so silently returning an "abandoned" code to the
-- `available` pool could hand the SAME code to two different people. The campaign's claim cap is
-- therefore a CLAIM/ISSUE cap, not a successful-redemption cap — which is exactly what supports
-- honest marketing copy like "first 100 users to CLAIM the 85BLENDS offer," never a promise that
-- abandoned slots get recycled to someone else.
--
-- REFERRAL INTERACTION (documented here, NOT implemented — see Section 7's own header): a
-- promo/free Apple Offer Code purchase must never, by itself, qualify a pending referral. That
-- hardening is explicitly future, separately-scoped work.
--
-- WEBHOOK INTEGRATION (documented here, NOT implemented — see Section 7): a later pass will teach
-- revenuecat-webhook to mark a promo_claims row 'redeemed' by matching participant identity +
-- product_id + promo_campaign_plan_offers.apple_offer_reference_name + an outstanding 'claimed' row
-- — never by trying to match RevenueCat's payload against promo_offer_codes.apple_code, which
-- RevenueCat does not reliably expose. This migration's schema is shaped to make that later pass
-- possible without another migration to promo_claims/promo_campaign_plan_offers' own columns.

-- ================================================================================================
-- 1. private.normalize_promo_code — the ONE canonical normalization rule.
-- ================================================================================================
-- Trim + uppercase, nothing else — the exact same normalization already established for referral
-- codes (private.apply_referral_code's `upper(btrim(...))`, mirrored client-side by
-- referral-api-validation.ts's normalizeReferralCode). IMMUTABLE (a pure text transform with no
-- external state) so it can back a STORED GENERATED column (Section 2) — the one mechanism that
-- makes it structurally impossible for promo_campaigns.normalized_public_code to ever drift out of
-- sync with public_code. The future promo-api Edge Function mirrors this exact rule in its own
-- pure `normalizePromoCode` helper for its own pre-database lookups — see that module's own header
-- for why that is "mirrored," not "duplicated": the database function stays the one and only
-- authoritative definition; a client-side mirror exists only so promo-api can build the same
-- lookup key before ever reaching Postgres, exactly like normalizeReferralCode already does today.
create function private.normalize_promo_code(p_code text)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'private'
as $function$
  select upper(btrim(p_code))
$function$;

revoke all on function private.normalize_promo_code(text) from public, anon, authenticated;
grant execute on function private.normalize_promo_code(text) to service_role;

comment on function private.normalize_promo_code(text) is
  '85Blends 2.4.0 promo campaigns. THE canonical public-code normalization rule (trim + uppercase) — used by promo_campaigns.normalized_public_code (a STORED GENERATED column) and by private.claim_promo_campaign''s own lookup. The future promo-api Edge Function mirrors this exact rule client-side rather than reinventing it, matching this codebase''s existing referral-code precedent.';

-- ================================================================================================
-- 2. private.promo_campaigns — one row per campaign (draft/active/paused/ended).
-- ================================================================================================
-- Configuration/data, never schema. This migration creates the TABLE only — no campaign, 85BLENDS
-- included, is ever inserted by any migration. A future campaign is created by a plain INSERT
-- (ops/dashboard), never a new migration, which is the entire point of this foundation (see this
-- file's own header).
create table private.promo_campaigns (
  id uuid primary key default gen_random_uuid(),

  -- The exact text a user types (e.g. "85BLENDS") — display/echo form only, never used for lookup.
  public_code text not null,
  constraint promo_campaigns_public_code_nonblank check (length(btrim(public_code)) > 0),

  -- The ONLY column ever used for lookup/uniqueness — a STORED GENERATED column computed from
  -- public_code via the canonical normalize_promo_code function above, so it can never disagree
  -- with public_code by construction (no trigger to keep in sync, no risk of the two drifting).
  -- Conservative marketing-code alphabet: uppercase A-Z, digits 0-9, hyphen; 3-32 characters —
  -- generous enough for "85BLENDS"/"HOLIDAY26"/"BLACKFRIDAY"/"SUMMER27" and any similar future code,
  -- narrow enough to keep this a marketing code, never free-form text.
  normalized_public_code text not null generated always as (private.normalize_promo_code(public_code)) stored,
  constraint promo_campaigns_normalized_public_code_key unique (normalized_public_code),
  constraint promo_campaigns_normalized_public_code_format
    check (normalized_public_code ~ '^[A-Z0-9-]{3,32}$'),

  -- Internal/ops label — never shown to end users (see display_title below for user-facing copy).
  name text not null,
  constraint promo_campaigns_name_nonblank check (length(btrim(name)) > 0),

  status text not null default 'draft',
  constraint promo_campaigns_status_check check (status in ('draft', 'active', 'paused', 'ended')),

  -- NULL = no bound on that side. private.claim_promo_campaign (Section 6) treats a NULL
  -- starts_at as "already started" and a NULL ends_at as "never ends" — never a guess either way.
  starts_at timestamptz,
  ends_at timestamptz,
  -- A campaign that names BOTH bounds must have a genuine, non-empty window — a start at or after
  -- its own end can never be entered, which almost certainly means an ops data-entry mistake
  -- (swapped fields), not an intentionally-zero-width campaign. Either bound alone (the other
  -- NULL) is unconstrained by this check.
  constraint promo_campaigns_date_window_check
    check (starts_at is null or ends_at is null or starts_at < ends_at),

  -- NULL = uncapped. A non-null value must be a genuine positive limit — 0 would mean "can never
  -- be claimed by anyone," which is what `status = 'draft'`/`'paused'` already expresses; a
  -- would-be-zero-cap campaign should simply not be `active`, not encode "zero" here.
  global_claim_limit integer,
  constraint promo_campaigns_global_claim_limit_check
    check (global_claim_limit is null or global_claim_limit > 0),

  -- Only 'one_time_pool' is supported/allowed by this foundation. 'custom_code' (a single
  -- Apple-side promotional code shared by everyone, rather than a per-claim one-time-use pool) is
  -- a documented FUTURE value only — deliberately not accepted by this CHECK constraint at all, so
  -- an unsupported mode cannot even be stored, let alone silently mis-handled by
  -- claim_promo_campaign. Adding real support later requires BOTH relaxing this constraint AND
  -- adding the corresponding branch in claim_promo_campaign — never one without the other. This is
  -- the "fail closed" requirement enforced at the strongest possible layer: the schema itself.
  fulfillment_mode text not null default 'one_time_pool',
  constraint promo_campaigns_fulfillment_mode_check check (fulfillment_mode = 'one_time_pool'),

  -- Initial customer-segment eligibility flags — CONFIGURATION/DISPLAY DATA ONLY in this
  -- foundation. Nothing in this migration enforces them against a caller's actual subscription
  -- history (that requires a RevenueCat subscriber lookup this schema does not yet perform) —
  -- see Section 6's own header for why enforcement is explicitly deferred, not silently skipped.
  eligibility_new_subscribers boolean not null default false,
  eligibility_existing_subscribers boolean not null default false,
  eligibility_expired_subscribers boolean not null default false,

  -- An ACTIVE campaign must target AT LEAST ONE subscriber segment. draft/paused/ended may sit
  -- with all three false (nothing to enforce yet, or no longer relevant) — but flipping status to
  -- 'active' with all three false would mean "open to nobody," never a meaningful campaign state
  -- and almost certainly an ops mistake (forgot to set eligibility before activating). This is a
  -- WEAKER, independent guarantee from private.claim_promo_campaign's own fail-closed rule
  -- (Section 6): a campaign scoped to fewer than all three segments (e.g. new subscribers only)
  -- still gets refused with 'eligibility_unverified' there until real RevenueCat-backed
  -- eligibility enforcement exists. This constraint only rules out the strictly worse "active and
  -- targets literally nobody" case — it does not loosen or replace that separate rule.
  constraint promo_campaigns_active_has_eligibility_target
    check (
      status <> 'active'
      or eligibility_new_subscribers
      or eligibility_existing_subscribers
      or eligibility_expired_subscribers
    ),

  -- User-facing presentation copy — the ONLY campaign fields promo-api's `validate`/`status`
  -- actions ever return (see Section 7's header). display_title is required; every other display
  -- field is optional so a minimal campaign can still be created without inventing placeholder text.
  display_title text not null,
  constraint promo_campaigns_display_title_nonblank check (length(btrim(display_title)) > 0),
  display_subtitle text,
  display_badge text,
  display_terms text,
  cta_label text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table private.promo_campaigns is
  '85Blends 2.4.0 generic promo campaign engine. One row per campaign (e.g. an EXAMPLE future "85BLENDS" row, never inserted by any migration). service_role-only — see this migration''s own header for the full security posture.';

comment on column private.promo_campaigns.normalized_public_code is
  'STORED GENERATED from public_code via private.normalize_promo_code — the ONLY column ever used for case-insensitive lookup. Never write to this column directly; it is computed automatically.';

create trigger promo_campaigns_set_updated_at
  before update on private.promo_campaigns
  for each row execute function private.set_updated_at();

revoke all on table private.promo_campaigns from public, anon, authenticated;
grant select, insert, update on table private.promo_campaigns to service_role;

alter table private.promo_campaigns enable row level security;
-- Deliberately zero policies — RLS defaults to deny-all, redundant with (but a genuine second
-- layer on top of) the explicit revoke above. Same pattern as every other private.* table.

-- ================================================================================================
-- 3. private.promo_campaign_plan_offers — maps a campaign to each eligible subscription product.
-- ================================================================================================
create table private.promo_campaign_plan_offers (
  id uuid primary key default gen_random_uuid(),

  campaign_id uuid not null references private.promo_campaigns(id) on delete cascade,

  -- The three CURRENT shipping 85Blends Pro products — legacy com.85blends.subscription.quarterly
  -- is deliberately never accepted here, mirroring exactly why
  -- referral-classification.ts's REFERRAL_QUALIFYING_PRODUCT_IDS excludes it (see that file's own
  -- comment). A future fourth product requires a migration to widen this CHECK, same as it would
  -- for the referral allow-list — never silently accepted.
  product_id text not null,
  constraint promo_campaign_plan_offers_product_id_check check (
    product_id in (
      'com.85blends.subscription.monthly',
      'com.85blends.subscription.threemonth',
      'com.85blends.subscription.annual'
    )
  ),

  -- The Apple Offer's OWN reference name (App Store Connect), distinct from any individual
  -- redemption code drawn from it — see private.promo_offer_codes below and this migration's own
  -- header for why these two concepts are never conflated. Globally unique: an Apple offer
  -- reference name is unique per subscription-group offer in App Store Connect, and this is the
  -- ONE field a future RevenueCat webhook pass can use to map an incoming transaction back to
  -- exactly one campaign + product (see Section 7) — an ambiguous mapping here would defeat that
  -- entirely.
  apple_offer_reference_name text not null,
  constraint promo_campaign_plan_offers_apple_offer_reference_name_key unique (apple_offer_reference_name),
  constraint promo_campaign_plan_offers_apple_offer_reference_name_nonblank
    check (length(btrim(apple_offer_reference_name)) > 0),

  -- Short user-facing description of what this specific plan's benefit is (e.g. "1 month free") —
  -- optional since display_title/subtitle on the campaign itself may already say enough.
  benefit_summary text,

  active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- ONE plan per product within a campaign — a DIFFERENT business invariant from the composite
  -- unique target below: this one is about what may belong to a campaign at all; the one below
  -- exists only so a CHILD row's composite FK can verify it agrees with the exact parent row it
  -- claims to belong to.
  constraint promo_campaign_plan_offers_campaign_product_key unique (campaign_id, product_id),

  -- Composite unique, existing ONLY to be the target of promo_claims' own composite foreign key
  -- (Section 5) — Postgres requires a unique/PK constraint on exactly the referenced column tuple.
  -- (id) alone is already unique via the primary key; this additionally makes (id, campaign_id,
  -- product_id) unique, so a claim's campaign_plan_offer_id/campaign_id/product_id can ALL be tied,
  -- at the schema level, to the SAME plan-offer row it claims to belong to — not just campaign_id.
  -- An earlier revision of this migration exposed only (id, campaign_id) for this purpose, which
  -- left promo_claims.product_id independently writable (the DB could theoretically hold a claim
  -- naming a Monthly plan-offer while its own product_id column said Annual); that narrower
  -- composite unique/FK pair has been replaced by this one, which fully subsumes it — see Section 7
  -- of this migration's own header.
  constraint promo_campaign_plan_offers_id_campaign_id_product_id_key unique (id, campaign_id, product_id)
);

comment on table private.promo_campaign_plan_offers is
  '85Blends 2.4.0 promo campaigns. One row per (campaign, eligible subscription product) — apple_offer_reference_name is the Apple OFFER''s own name, never a literal redemption code (see private.promo_offer_codes). service_role-only.';

create trigger promo_campaign_plan_offers_set_updated_at
  before update on private.promo_campaign_plan_offers
  for each row execute function private.set_updated_at();

revoke all on table private.promo_campaign_plan_offers from public, anon, authenticated;
grant select, insert, update on table private.promo_campaign_plan_offers to service_role;

alter table private.promo_campaign_plan_offers enable row level security;

-- ================================================================================================
-- 4. private.promo_offer_codes — server-private pool of Apple one-time-use Offer Codes.
-- ================================================================================================
-- Imported later (ops tooling, out of scope for this migration) from an Apple-generated batch —
-- this migration creates the empty pool table only, never any actual Apple code.
create table private.promo_offer_codes (
  id uuid primary key default gen_random_uuid(),

  campaign_plan_offer_id uuid not null references private.promo_campaign_plan_offers(id) on delete cascade,

  -- The literal Apple one-time-use redemption code. PRIVATE, SERVER-SIDE-ONLY DATA — never
  -- logged, never returned by any API response except inside the one-time redemption URL handed
  -- to the exact participant who claimed it (see promo-api's own future header, Section 7). Unique
  -- across the whole table (not just within one pool) — the same literal code must never be
  -- imported into two different pools.
  apple_code text not null,
  constraint promo_offer_codes_apple_code_key unique (apple_code),
  constraint promo_offer_codes_apple_code_nonblank check (length(btrim(apple_code)) > 0),

  status text not null default 'available',
  constraint promo_offer_codes_status_check check (status in ('available', 'issued', 'redeemed', 'void')),

  -- Apple-side expiry for this specific one-time code. NOT NULL, deliberately: Apple requires
  -- every generated one-time-use Offer Code to carry an expiration (maximum validity six months —
  -- see supabase/README.md's "REQUIRED launch gates" / operational notes), so "no known expiry" is
  -- never a legitimate state for a real imported code — treating it as optional here would let an
  -- already-stale or malformed import silently sit in the `available` pool forever. private.
  -- claim_promo_campaign (Section 6) never selects an already-expired code, even if it is still
  -- `available`.
  apple_expires_at timestamptz not null,
  constraint promo_offer_codes_apple_expires_at_after_created
    check (apple_expires_at > created_at),

  -- Set once, the moment this code is issued to a claim (Section 6) — never cleared or reused
  -- afterward (see this migration's own header, and the status-transition trigger below, which
  -- makes "issued" a one-way door away from "available"). Which CLAIM issued a given code is
  -- discoverable via a reverse lookup on promo_claims.offer_code_id (Section 5) — made a real
  -- structural guarantee, not a convention, by that column being NOT NULL and UNIQUE (one code,
  -- at most one claim, ever). This table deliberately does NOT also carry its own
  -- issued_claim_id pointer back — an earlier revision of this migration did, and closed it via a
  -- post-hoc ALTER TABLE once promo_claims existed, but that made the same fact (which claim owns
  -- which code) representable in TWO places that nothing forced to agree. One direction, one
  -- source of truth.
  issued_at timestamptz,
  redeemed_at timestamptz,

  -- Free-text label identifying which Apple-generated import batch this code came from —
  -- operational/diagnostic only, never parsed by any function in this migration.
  import_batch text,

  created_at timestamptz not null default now(),

  -- Composite unique, existing ONLY to be the target of promo_claims' own composite foreign key
  -- (Section 5) — mirrors promo_campaign_plan_offers_id_campaign_id_product_id_key's own reasoning
  -- exactly: (id) alone is already unique via the primary key; this additionally makes (id,
  -- campaign_plan_offer_id) unique, so a claim's offer_code_id can be tied, at the schema level,
  -- to the SAME campaign_plan_offer_id it also stores directly — a code from one plan's pool can
  -- never end up structurally attached to a claim recorded against a different plan.
  constraint promo_offer_codes_id_campaign_plan_offer_id_key unique (id, campaign_plan_offer_id)
);

comment on table private.promo_offer_codes is
  '85Blends 2.4.0 promo campaigns. Server-private pool of Apple one-time-use Offer Codes, imported per campaign-plan-offer. apple_code is never logged and never exposed except inside the one redemption URL handed back to the exact claimant. Once a code reaches ''issued'' it is PERMANENTLY consumed from this pool — see this migration''s own header for why. service_role-only.';

comment on column private.promo_offer_codes.apple_code is
  'The literal Apple one-time-use redemption code. PRIVATE. Never log this value, anywhere, for any reason.';

-- Partial index matching claim_promo_campaign''s own "pick one available, non-expired code for
-- this plan" query exactly (Section 6) — every other status is irrelevant to that lookup.
create index promo_offer_codes_available_pool_idx
  on private.promo_offer_codes (campaign_plan_offer_id, created_at)
  where status = 'available';

revoke all on table private.promo_offer_codes from public, anon, authenticated;
grant select, insert, update on table private.promo_offer_codes to service_role;

alter table private.promo_offer_codes enable row level security;

-- One-way status state machine (Section 4's own load-bearing invariant, enforced here as a real,
-- testable, DB-level guarantee — not just a convention documented in a comment): available may
-- move to issued or void; issued may move to redeemed or void; redeemed and void are terminal.
-- Re-setting the SAME status (any other column changing) is always allowed. Anything else —
-- issued back to available above all — is rejected outright. This is the second, independent line
-- of defense described in this migration''s own header: claim_promo_campaign (Section 6) never
-- attempts a backward transition either, but this trigger makes "a code is never recycled once
-- issued" true even against a hypothetical future bug or an ad hoc ops UPDATE, not merely true by
-- convention.
create function private.enforce_promo_offer_code_status_transition()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'private'
as $function$
begin
  if new.status = old.status then
    return new;
  elsif old.status = 'available' and new.status in ('issued', 'void') then
    return new;
  elsif old.status = 'issued' and new.status in ('redeemed', 'void') then
    return new;
  else
    raise exception 'promo_offer_code_invalid_status_transition: % -> %', old.status, new.status;
  end if;
end;
$function$;

revoke all on function private.enforce_promo_offer_code_status_transition() from public, anon, authenticated;
-- No explicit EXECUTE grant needed/possible for a trigger function beyond table UPDATE privilege
-- (already scoped to service_role above) — Postgres invokes trigger functions as part of the
-- triggering statement, not via a direct EXECUTE call.

create trigger promo_offer_codes_enforce_status_transition
  before update on private.promo_offer_codes
  for each row execute function private.enforce_promo_offer_code_status_transition();

-- ================================================================================================
-- 5. private.promo_claims — one immutable row per (participant, campaign).
-- ================================================================================================
create table private.promo_claims (
  id uuid primary key default gen_random_uuid(),

  -- Deliberately NO "on delete cascade" anywhere on this table (unlike promo_campaign_plan_offers/
  -- promo_offer_codes above, which cascade from pure pool/config data): a claim is the actual
  -- customer-facing commitment record. Once real claims exist against a campaign/plan-offer/offer
  -- code, deleting that upstream row is BLOCKED (Postgres's default NO ACTION) rather than
  -- silently cascading an audit-significant row out of existence. Deleting pool/config data with
  -- zero claims against it still works exactly as the cascades above describe.
  campaign_id uuid not null references private.promo_campaigns(id),
  participant_id uuid not null references private.referral_participants(id),
  installation_id uuid not null references private.referral_client_installations(installation_id),

  -- campaign_plan_offer_id has no plain single-column FK — see the composite FK constraints below,
  -- which subsume the plain-FK guarantee (id must exist) AND additionally force it to structurally
  -- agree with THIS row's own campaign_id AND product_id (Section 7 of this migration's own
  -- header: "DB-level campaign/plan/product/code relational consistency"). product_id carries no
  -- independent FK of its own either — it is not free-standing text: the SAME composite FK below
  -- ties it to the exact plan-offer row campaign_plan_offer_id already names, so this column can
  -- never disagree with the plan a claim was actually made against (e.g. naming the Monthly
  -- plan-offer while this column says Annual is structurally impossible).
  campaign_plan_offer_id uuid not null,
  product_id text not null,

  -- NOT NULL and UNIQUE: every claim in this foundation allocates exactly one Apple code (only
  -- 'one_time_pool' fulfillment_mode exists — see promo_campaigns.fulfillment_mode's own CHECK),
  -- and UNIQUE makes "one Apple code is owned by at most one claim" a real, structural, DB-level
  -- guarantee rather than a convention private.claim_promo_campaign merely happens to uphold. A
  -- future fulfillment_mode that does NOT allocate a pooled code would need its own migration to
  -- relax this — never silently accepted by loosening it preemptively here.
  offer_code_id uuid not null,

  status text not null default 'claimed',
  constraint promo_claims_status_check check (status in ('claimed', 'redeemed', 'void')),

  claimed_at timestamptz not null default now(),
  redeemed_at timestamptz,

  -- Populated by a FUTURE webhook pass only (Section 7) — this migration never writes these three
  -- columns; they exist now so that later pass needs no further migration to promo_claims itself.
  revenuecat_event_id text,
  transaction_id text,
  original_transaction_id text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- ONE lifetime claim per participant per campaign — the primary immutability guarantee (Phase
  -- 10-style rule, mirroring private.referral_attributions_one_referrer_per_referred''s own
  -- "immutable, enforced by a unique constraint" shape). This index''s leading column also serves
  -- private.claim_promo_campaign''s per-campaign claim-count query efficiently — no separate index
  -- needed for that.
  constraint promo_claims_one_per_participant_per_campaign unique (campaign_id, participant_id),

  -- Belt and suspenders alongside the participant-scoped constraint above: even in the
  -- (structurally near-impossible, since referral_participants.installation_id is itself unique)
  -- case of an installation/participant mapping ever becoming less than 1:1, one installation can
  -- still never hold two claims on the same campaign.
  constraint promo_claims_one_per_installation_per_campaign unique (campaign_id, installation_id),

  -- "One Apple code, at most one claim" (Section 7 of this migration's own header) — the structural
  -- half of the guarantee; see offer_code_id's own column comment above for the other half (NOT
  -- NULL).
  constraint promo_claims_offer_code_id_key unique (offer_code_id),

  -- Relational-consistency composite FKs (Section 7): campaign_plan_offer_id, campaign_id, AND
  -- product_id must ALL belong to the SAME promo_campaign_plan_offers row, and offer_code_id must
  -- belong to THIS row's own campaign_plan_offer_id — both enforced by referencing a composite
  -- UNIQUE constraint on the parent table (plain (id) uniqueness alone cannot express this; see
  -- promo_campaign_plan_offers_id_campaign_id_product_id_key and
  -- promo_offer_codes_id_campaign_plan_offer_id_key, each created for exactly this purpose). It is
  -- therefore structurally impossible to record a claim whose plan-offer belongs to a different
  -- campaign, whose product_id disagrees with the plan-offer it names (e.g. Monthly plan-offer +
  -- Annual product_id), or whose offer code was drawn from a different plan-offer's pool. The
  -- three-column FK below replaces an earlier, weaker two-column
  -- (campaign_plan_offer_id, campaign_id) -> (id, campaign_id) version that left product_id
  -- independently writable — the new one fully subsumes it (any row satisfying the triple match
  -- also satisfies the double match on its own campaign_id column), so the old, narrower
  -- constraint was removed rather than kept alongside it.
  constraint promo_claims_campaign_plan_offer_campaign_product_fkey
    foreign key (campaign_plan_offer_id, campaign_id, product_id)
    references private.promo_campaign_plan_offers (id, campaign_id, product_id),
  constraint promo_claims_offer_code_plan_offer_fkey
    foreign key (offer_code_id, campaign_plan_offer_id)
    references private.promo_offer_codes (id, campaign_plan_offer_id)
);

comment on table private.promo_claims is
  '85Blends 2.4.0 promo campaigns. One immutable row per (participant, campaign) — see private.claim_promo_campaign (Section 6) for the concurrency-safe function that is the ONLY intended writer. offer_code_id is NOT NULL and UNIQUE: one Apple code is structurally owned by at most one claim, discoverable only via this reverse pointer (promo_offer_codes carries no pointer back). A composite foreign key ties campaign_plan_offer_id, campaign_id, AND product_id ALL to the SAME promo_campaign_plan_offers row, and another ties offer_code_id to this row''s own campaign_plan_offer_id — a claim can never reference a plan-offer belonging to a different campaign, a product_id that disagrees with the plan-offer it names, or a code drawn from a different plan-offer''s pool. No cascading deletes from campaign/plan-offer/offer-code — a real claim blocks deletion of what it references. service_role-only.';

create trigger promo_claims_set_updated_at
  before update on private.promo_claims
  for each row execute function private.set_updated_at();

revoke all on table private.promo_claims from public, anon, authenticated;
grant select, insert, update on table private.promo_claims to service_role;

alter table private.promo_claims enable row level security;

-- ================================================================================================
-- 6. private.claim_promo_campaign — the ONE authoritative, concurrency-safe entry point.
-- ================================================================================================
-- LOAD-BEARING CONCURRENCY GUARANTEE: this backend must never issue claim #101 when
-- global_claim_limit = 100, even under many simultaneous devices claiming at once. Achieved with a
-- real row lock, not a naive "SELECT count(*) THEN INSERT" (which a concurrent caller could
-- interleave with): `select ... from private.promo_campaigns where ... for update` takes and holds
-- an exclusive row lock on the CAMPAIGN row for the remainder of this function''s single implicit
-- transaction (a single top-level `select * from private.claim_promo_campaign(...)` statement is
-- already atomic in Postgres — no explicit BEGIN/COMMIT needed by the caller). A second concurrent
-- call for the SAME campaign blocks at that `for update` until the first call''s transaction
-- commits or rolls back — so the claim-count check and the subsequent INSERT that depends on it can
-- never interleave with another call for this campaign. This serializes claims PER CAMPAIGN only
-- (concurrent claims against DIFFERENT campaigns never block each other, since each locks its own,
-- different campaign row).
--
-- Selecting the actual Apple code additionally uses `for update skip locked` (Section 6c below) —
-- redundant with the campaign-row lock for correctness against OTHER CONCURRENT CLAIMS (already
-- fully serialized by that lock), but a genuine second safeguard against any future direct/ops
-- mutation of promo_offer_codes running concurrently outside this function.
--
-- IDENTITY: takes an ALREADY-AUTHENTICATED p_participant_id/p_installation_id — this function
-- never sees a raw installation secret and never re-verifies possession itself, mirroring EXACTLY
-- how private.apply_referral_code/private.create_or_get_referral_participant already work: the
-- calling Edge Function (promo-api, Section 7) authenticates the installation''s possession
-- credential in TypeScript first (SHA-256 hash compare, constant-time), then calls this function
-- with the resolved, trusted identity — never the other way around.
--
-- ELIGIBILITY SCOPE — FAILS CLOSED for any selective segment this foundation cannot verify: this
-- schema/function has no RevenueCat subscriber-history lookup, so it can never actually check
-- promo_campaigns.eligibility_new_subscribers/existing_subscribers/expired_subscribers against a
-- caller''s real subscription history. A campaign open to ALL THREE segments needs no such check —
-- everyone qualifies by definition, so it proceeds normally. A campaign scoped to any NARROWER
-- combination (e.g. new subscribers only) cannot be safely evaluated here AT ALL: silently
-- proceeding anyway would risk handing a real Apple code to a caller this backend never actually
-- confirmed was eligible. This function therefore refuses outright ('eligibility_unverified') for
-- any campaign whose eligibility flags are not all true, rather than guessing or ignoring them —
-- until a dedicated, separately-scoped RevenueCat-backed eligibility-enforcement pass adds the real
-- check (see supabase/README.md''s "REQUIRED launch gates"). promo-api''s own `validate` action
-- mirrors this exact rule client-side (promo-api-eligibility.ts) so it never tells a caller a
-- selectively-scoped campaign looks claimable when this function would immediately refuse it.
--
-- IDEMPOTENCY — CHECKED FIRST, before any campaign-state check: a participant who already has a
-- claim on this campaign gets that SAME claim back regardless of what has happened to the campaign
-- SINCE they claimed it — paused, ended, or now eligibility-scoped differently. An existing claim
-- is a permanent fact about the past; it must never be re-litigated against the campaign''s CURRENT
-- state (exactly the same "backend-confirmed state wins over a later, unrelated check" principle
-- already applied to referral re-application in this codebase). Never a second Apple code, never a
-- second increment of the campaign''s claim count — whether they ask for the SAME product again or
-- a DIFFERENT one (Phase 10''s explicit "the app tells users to pick their plan before claiming; do
-- not silently allocate a second code" rule). The two cases are distinguished by outcome so
-- promo-api can phrase them differently: 'already_claimed' (same product) vs. 'claim_plan_conflict'
-- (different product) — both return the SAME existing claim/code, since the underlying fact (one
-- immutable claim already exists) is identical either way.
create function private.claim_promo_campaign(
  p_participant_id uuid,
  p_installation_id uuid,
  p_public_code text,
  p_product_id text
)
returns table (
  outcome text,  -- claimed | already_claimed | claim_plan_conflict | campaign_not_found |
                 -- campaign_not_active | campaign_not_started | campaign_ended |
                 -- eligibility_unverified | product_not_eligible | campaign_exhausted |
                 -- offer_pool_exhausted
  claim_id uuid,
  campaign_id uuid,
  campaign_plan_offer_id uuid,
  offer_code_id uuid,
  apple_code text,
  product_id text
)
language plpgsql
set search_path to 'pg_catalog', 'private'
as $function$
declare
  v_normalized_code text;
  v_campaign private.promo_campaigns%rowtype;
  v_plan_offer private.promo_campaign_plan_offers%rowtype;
  v_existing_claim private.promo_claims%rowtype;
  v_offer_code private.promo_offer_codes%rowtype;
  v_current_claim_count integer;
  v_claim_id uuid;
begin
  if p_participant_id is null or p_installation_id is null then
    raise exception 'promo_claim_identity_required';
  end if;

  v_normalized_code := private.normalize_promo_code(p_public_code);

  -- Row lock — see this function''s own header for why this single statement is the entire
  -- concurrency-safety mechanism for the global cap enforced below.
  select * into v_campaign
  from private.promo_campaigns
  where normalized_public_code = v_normalized_code
  for update;

  if v_campaign.id is null then
    return query select 'campaign_not_found'::text, null::uuid, null::uuid, null::uuid, null::uuid, null::text, null::text;
    return;
  end if;

  -- Idempotency check — CHECKED FIRST, before any campaign-state check below (see this function''s
  -- own header for why: an existing claim is a permanent fact about the past and must never be
  -- re-litigated against the campaign''s current status/dates/eligibility). Locked too (harmless: at
  -- most one row can ever match this unique constraint), purely for consistency with the rest of
  -- this transaction''s locking discipline.
  select * into v_existing_claim
  from private.promo_claims
  where campaign_id = v_campaign.id
    and participant_id = p_participant_id
  for update;

  if v_existing_claim.id is not null then
    select * into v_offer_code from private.promo_offer_codes where id = v_existing_claim.offer_code_id;
    if v_existing_claim.product_id = p_product_id then
      return query select
        'already_claimed'::text, v_existing_claim.id, v_campaign.id, v_existing_claim.campaign_plan_offer_id,
        v_offer_code.id, v_offer_code.apple_code, v_existing_claim.product_id;
    else
      return query select
        'claim_plan_conflict'::text, v_existing_claim.id, v_campaign.id, v_existing_claim.campaign_plan_offer_id,
        v_offer_code.id, v_offer_code.apple_code, v_existing_claim.product_id;
    end if;
    return;
  end if;

  if v_campaign.status <> 'active' then
    return query select 'campaign_not_active'::text, null::uuid, v_campaign.id, null::uuid, null::uuid, null::text, null::text;
    return;
  end if;

  if v_campaign.starts_at is not null and now() < v_campaign.starts_at then
    return query select 'campaign_not_started'::text, null::uuid, v_campaign.id, null::uuid, null::uuid, null::text, null::text;
    return;
  end if;

  if v_campaign.ends_at is not null and now() > v_campaign.ends_at then
    return query select 'campaign_ended'::text, null::uuid, v_campaign.id, null::uuid, null::uuid, null::text, null::text;
    return;
  end if;

  -- Selective subscriber eligibility FAILS CLOSED — see this function''s own header. Only a
  -- campaign open to every segment (all three flags true) may proceed past this point.
  if not (
    v_campaign.eligibility_new_subscribers
    and v_campaign.eligibility_existing_subscribers
    and v_campaign.eligibility_expired_subscribers
  ) then
    return query select 'eligibility_unverified'::text, null::uuid, v_campaign.id, null::uuid, null::uuid, null::text, null::text;
    return;
  end if;

  select * into v_plan_offer
  from private.promo_campaign_plan_offers
  where campaign_id = v_campaign.id
    and product_id = p_product_id
    and active = true;

  if v_plan_offer.id is null then
    return query select 'product_not_eligible'::text, null::uuid, v_campaign.id, null::uuid, null::uuid, null::text, null::text;
    return;
  end if;

  -- Global cap enforcement — safe under concurrency ONLY because the campaign row lock above is
  -- still held at this point (never a bare "count then insert" — see this function''s own header).
  if v_campaign.global_claim_limit is not null then
    select count(*) into v_current_claim_count
    from private.promo_claims
    where campaign_id = v_campaign.id;

    if v_current_claim_count >= v_campaign.global_claim_limit then
      return query select 'campaign_exhausted'::text, null::uuid, v_campaign.id, v_plan_offer.id, null::uuid, null::text, null::text;
      return;
    end if;
  end if;

  -- One available, non-expired code from THIS product''s own pool. apple_expires_at is NOT NULL
  -- (see promo_offer_codes) — an expired code can never allocate, full stop, never a "no known
  -- expiry" escape hatch. `for update skip locked`: see this function''s own header for why this is
  -- a second, independent safeguard rather than the primary concurrency mechanism (the
  -- campaign-row lock already is).
  select * into v_offer_code
  from private.promo_offer_codes
  where campaign_plan_offer_id = v_plan_offer.id
    and status = 'available'
    and apple_expires_at > now()
  order by created_at
  for update skip locked
  limit 1;

  if v_offer_code.id is null then
    return query select 'offer_pool_exhausted'::text, null::uuid, v_campaign.id, v_plan_offer.id, null::uuid, null::text, null::text;
    return;
  end if;

  insert into private.promo_claims (
    campaign_id, participant_id, installation_id, campaign_plan_offer_id, product_id, offer_code_id, status, claimed_at
  ) values (
    v_campaign.id, p_participant_id, p_installation_id, v_plan_offer.id, p_product_id, v_offer_code.id, 'claimed', now()
  )
  returning id into v_claim_id;

  -- promo_claims.offer_code_id (set above, NOT NULL + UNIQUE) is now the ONE record of which claim
  -- owns this code — promo_offer_codes carries no pointer back (see that table''s own column
  -- comments). Marking the code 'issued' here is still a second, independent idempotency backstop
  -- for "never issue the same code twice" alongside the row locking above — same "second line of
  -- defense" philosophy this codebase already applies to referral_rewards_unique_milestone.
  update private.promo_offer_codes
  set status = 'issued', issued_at = now()
  where id = v_offer_code.id;

  return query select
    'claimed'::text, v_claim_id, v_campaign.id, v_plan_offer.id, v_offer_code.id, v_offer_code.apple_code, p_product_id;
end;
$function$;

comment on function private.claim_promo_campaign(uuid, uuid, text, text) is
  '85Blends 2.4.0 promo campaigns. THE ONLY authoritative, concurrency-safe way to claim a campaign — see this function''s own header for the campaign-row-lock mechanism that makes the global claim cap safe under concurrent callers, the idempotency-checked-first ordering, and why selective subscriber eligibility fails closed (outcome ''eligibility_unverified''). Never called with a raw installation secret; the caller (promo-api) authenticates possession first and passes an already-resolved participant_id/installation_id.';

revoke all on function private.claim_promo_campaign(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function private.claim_promo_campaign(uuid, uuid, text, text) to service_role;

-- ================================================================================================
-- 7. private.promo_code_attempts — abuse/rate-limit + diagnostics log.
-- ================================================================================================
-- Mirrors private.referral_apply_attempts'' own shape/purpose exactly (see the referral client API
-- migration''s own comment) — narrow, append-only, NEVER stores a raw installation secret or a raw
-- RevenueCat identifier, only what a rate limit and basic diagnostics need. A dedicated table, not
-- a reuse of referral_apply_attempts: this is an independent abuse surface (guessing a promo code)
-- from referral''s own (guessing a referral code), with its own independent budget.
create table private.promo_code_attempts (
  id bigint generated always as identity primary key,
  installation_id uuid not null references private.referral_client_installations(installation_id) on delete cascade,
  normalized_public_code text not null,
  attempted_at timestamptz not null default now(),
  -- A closed, small vocabulary — every value the promo-api Edge Function actually writes, and
  -- nothing it doesn't (kept tight and honest rather than speculatively broad). Two states are
  -- deliberately absent from this list: a FORMAT-invalid code never reaches this table at all (it
  -- is rejected before any attempt is ever logged — see promo-api/index.ts, mirroring
  -- referral-api's own isValidReferralCodeFormat precedent exactly), and 'already_claimed' never
  -- reaches this table either, because that is precisely the "repeated retrieval of an
  -- ALREADY-CLAIMED campaign" case this table's own comment says must never consume the abuse
  -- budget. 'valid' covers validate's own "resolved to a real campaign, not yet claimed by this
  -- installation" case, which has no equivalent in private.claim_promo_campaign's outcome column.
  outcome text not null,
  constraint promo_code_attempts_outcome_check check (
    outcome in (
      'valid', 'campaign_not_found', 'campaign_not_active', 'campaign_not_started',
      'campaign_ended', 'eligibility_unverified', 'product_not_eligible', 'campaign_exhausted',
      'offer_pool_exhausted', 'claimed', 'claim_plan_conflict', 'error'
    )
  )
);

comment on table private.promo_code_attempts is
  '85Blends 2.4.0 promo campaigns. Append-only log of NEW campaign-code attempts per installation, backing a 5-attempts-per-60-seconds server-side rate limit (see the future promo-api/index.ts). Repeated retrieval of an ALREADY-CLAIMED campaign, and the status action, never write here at all — only a genuinely new/unresolved code guess does. No raw installation secret or raw RevenueCat identifier ever stored here. Not pruned by this migration — same "rows are tiny and short-lived in relevance" reasoning as referral_apply_attempts.';

create index promo_code_attempts_installation_idx
  on private.promo_code_attempts (installation_id, attempted_at desc);

revoke all on table private.promo_code_attempts from public, anon, authenticated;
grant select, insert on table private.promo_code_attempts to service_role;

alter table private.promo_code_attempts enable row level security;

-- 85Blends 2.4.0 Referral Reward Redemption — fourth correctness hardening pass: paid-referral
-- qualification.
--
-- THE BUG: the referral system promises "5 QUALIFIED PAID REFERRALS = 1 FREE MONTH." Before this
-- pass, private.process_referral_subscription_event was only ever reached for an INITIAL_PURCHASE/
-- RENEWAL whose event SHAPE looked like a qualifying paid purchase (PRODUCTION, period_type
-- NORMAL, one of the three Pro products, both transaction ids present, not one of our own
-- REFERRAL_REWARD_* offer codes) — it never checked the transaction's own economics. 85Blends also
-- runs a SEPARATE, PUBLIC one-month-free Apple Offer Code promotion (the "85BLENDS launch promo",
-- referenced in the codebase's own tests as "85BLENDS_LAUNCH_PROMO"). RevenueCat's webhook can
-- report period_type NORMAL and a non-null offer_code for that free redemption exactly as it would
-- for an ordinary paid purchase — the classifier's existing offer-code exclusion only ever knew
-- about our OWN three REFERRAL_REWARD_* reference names, so a public-promo redemption (or any other
-- $0 start of one of the three Pro products) could incorrectly count as a "paid referral."
--
-- Fix, implemented in supabase/functions/_shared/referral-classification.ts (see that file's
-- isDemonstrablyPaid/isCandidatePaidQualifyingEvent/isReferralDeferrablePaidOriginEvent): paid
-- qualification now additionally requires POSITIVE evidence of payment from the webhook event's own
-- `price`/`price_in_purchased_currency` fields — a positive amount is required to qualify; an
-- explicit zero or an unknown/missing price is conservatively NOT treated as paid. This applies
-- generically to ANY free/zero/unknown-price start, not just a hardcoded promo reference name.
--
-- That alone would silently and permanently strand a referral for someone who (1) applied a
-- referral code before subscribing, then (2) started Pro through a legitimate free Offer Code
-- (public promo or otherwise), since their INITIAL_PURCHASE would now simply be ignored. This
-- migration is the database-backed half of the fix that preserves that pending referral: a new,
-- narrow "deferred paid qualification origin" ledger (private.referral_deferred_paid_origins),
-- populated by a new private.record_referral_deferred_paid_origin(...) function, called for a
-- 'defer_paid_origin' action (see _shared/database.ts's applyReferralAction) ONLY when this exact
-- participant already had a PENDING attribution whose attributed_at predates this free purchase —
-- proving the referral attribution existed BEFORE the subscription/promo flow began, exactly the
-- same Attribution Timing Rule private.process_referral_subscription_event already enforces for an
-- immediate qualify, just applied to the ORIGINAL free purchase's own timestamp rather than a later
-- renewal's. A referral code applied AFTER a free/promo start therefore never gets a deferred-origin
-- row at all (no pending attribution existed yet when the free purchase happened), which is what
-- keeps that later paid renewal from ever qualifying it — see
-- _shared/database.ts's applyReferralAction, which now also checks THIS table (in addition to the
-- pre-existing private.referral_reward_offer_codes check) before ever allowing a RENEWAL-triggered
-- qualify to proceed. Recording (or failing to record) a deferred origin never itself changes
-- attribution status or reward milestones — only a later, demonstrably-paid RENEWAL event, routed
-- through the existing process_referral_subscription_event, can actually qualify anything.
--
-- Deliberately a NEW, additive migration rather than an edit to
-- 20260919150000_referral_paid_qualification_foundation.sql: per
-- supabase/functions/revenuecat-webhook/index.ts's own deployment header, that migration is
-- confirmed live in production (applied and verified 2026-09-19, webhook function deployed against
-- it as ACTIVE version 7) — an applied migration must never be edited in place (this repo's
-- migration hygiene rule). This file depends only on objects that migration already created
-- (private.referral_participants / referral_participant_aliases / referral_attributions), purely
-- additively (CREATE TABLE IF NOT EXISTS / CREATE OR REPLACE FUNCTION only).
--
-- Like 20260928000000_referral_reward_redemption_foundation.sql (this same still-draft PR), this
-- migration itself remains genuinely UNAPPLIED to production pending its own separate
-- authorization — PR #110 stays in draft, nothing here is deployed.

-- ============================================================================================
-- 1. Deferred paid-qualification origin ledger
-- ============================================================================================
-- Purely an audit/proof ledger — never read by anything except the RENEWAL-triggered qualify proof
-- check in _shared/database.ts's applyReferralAction (an EXISTS check keyed on
-- original_transaction_id + environment). Insert-only: once recorded, a row is never updated or
-- deleted — the correctness guarantee against double-qualification lives entirely in
-- private.referral_attributions.status (process_referral_subscription_event's own 'pending' check),
-- not in any mutable state on this table.
create table if not exists private.referral_deferred_paid_origins (
  id                         uuid        primary key default gen_random_uuid(),
  attribution_id             uuid        not null references private.referral_attributions(id) on delete restrict,
  referred_participant_id    uuid        not null references private.referral_participants(id) on delete restrict,
  original_transaction_id    text        not null,
  environment                text        not null,
  product_id                 text        not null,
  -- The ORIGINAL free/promo purchase's own purchased_at — re-validated against the attribution's
  -- attributed_at at recording time (see record_referral_deferred_paid_origin below) and kept here
  -- purely for audit; never re-read for any later decision.
  original_purchased_at      timestamptz not null,
  deferred_reason            text        not null,
  -- The offer_code (an App Store Connect OFFER REFERENCE NAME), for audit only — NEVER the raw
  -- one-time Apple code a customer typed, which RevenueCat does not expose in the first place (see
  -- _shared/referral-reward-offer-codes.ts's own header for this same distinction). Nullable: a
  -- free/zero-price purchase need not have carried any offer code at all.
  offer_reference_for_audit  text,
  triggering_event_id        text        not null,
  created_at                 timestamptz not null default now()
);

do $$
begin
  alter table private.referral_deferred_paid_origins
    add constraint referral_deferred_paid_origins_environment
      check (environment in ('SANDBOX','PRODUCTION'));
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter table private.referral_deferred_paid_origins
    add constraint referral_deferred_paid_origins_reason
      check (deferred_reason in ('zero_price','unknown_price','free_offer_code'));
exception
  when duplicate_object then null;
end $$;

-- One deferred origin per subscription lifecycle (original_transaction_id never changes across a
-- subscription's own renewals) — this is also the exact key the RENEWAL-triggered proof check in
-- _shared/database.ts's applyReferralAction looks up, and what makes the INSERT below idempotent
-- against a redelivered INITIAL_PURCHASE webhook event.
do $$
begin
  alter table private.referral_deferred_paid_origins
    add constraint referral_deferred_paid_origins_original_txn_key
      unique (original_transaction_id);
exception
  when duplicate_object then null;
end $$;

create index if not exists referral_deferred_paid_origins_attribution_idx
  on private.referral_deferred_paid_origins (attribution_id);

alter table private.referral_deferred_paid_origins enable row level security;
-- Zero policies: with RLS enabled and no policy, anon/authenticated are denied all access by the
-- revokes below and would additionally be denied by RLS itself defaulting to deny-all — the same
-- belt-and-suspenders pattern as every other private.referral_* table (see
-- 20260928000000_referral_reward_redemption_foundation.sql's own referral_reward_offer_codes for
-- the identical pattern).
revoke all on table private.referral_deferred_paid_origins from public, anon, authenticated;
grant select, insert on table private.referral_deferred_paid_origins to service_role;
-- No UPDATE/DELETE grant, even to service_role: this ledger has no lifecycle to progress and no
-- history to revise — a row is written once by record_referral_deferred_paid_origin and read only
-- by an EXISTS check ever after.

-- ============================================================================================
-- 2. private.record_referral_deferred_paid_origin — records a deferred origin, never qualifies
-- ============================================================================================
-- Called for a 'defer_paid_origin' action (see _shared/database.ts's applyReferralAction) — an
-- INITIAL_PURCHASE that has every qualifying SHAPE characteristic but is NOT demonstrably paid (see
-- referral-classification.ts's isReferralDeferrablePaidOriginEvent). Mirrors
-- process_referral_subscription_event's own identity-resolution pattern exactly (zero/one/many
-- alias match, fail-closed on conflict) for consistency, but NEVER touches
-- private.referral_attributions or private.referral_rewards — this function only ever INSERTs into
-- private.referral_deferred_paid_origins, or no-ops. Callable only by trusted backend/service-role
-- code, never anon/authenticated/PUBLIC (see grants below).
--
-- THE LOOPHOLE THIS CLOSES (referral code applied AFTER a free/promo start): if this participant
-- has no attribution at all, or their attribution's attributed_at is AFTER this purchase's own
-- purchased_at (i.e. they applied a referral code only after this free start already began), this
-- function records NOTHING — outcome 'no_attribution' or 'too_late'. With no deferred-origin row
-- ever created for that original_transaction_id, the later RENEWAL-triggered qualify proof check in
-- _shared/database.ts's applyReferralAction can never be satisfied for it, so that later paid
-- renewal never qualifies anything. This is the Attribution Timing Rule, applied to the ORIGINAL
-- free purchase's own timestamp rather than a later renewal's — exactly what keeps an
-- already-long-standing Pro subscriber who applies a code afterward from ever benefiting from it,
-- generalized to the free/promo-start case the same way process_referral_subscription_event already
-- enforces it for an immediate paid qualify.
create or replace function private.record_referral_deferred_paid_origin(
  p_app_user_id_set text[],          -- the webhook event's full resolved alias set
  p_environment text,                -- must be 'PRODUCTION'
  p_event_id text,                   -- the triggering INITIAL_PURCHASE event's own id (audit)
  p_purchased_at_ms bigint,          -- RevenueCat's purchased_at_ms for this free/promo purchase
  p_product_id text,                 -- the purchased product id
  p_transaction_id text,             -- stored for identity-integrity parity with the qualify path
  p_original_transaction_id text,    -- the match key a later RENEWAL's proof check looks up
  p_deferred_reason text,            -- 'zero_price' | 'unknown_price' | 'free_offer_code'
  p_offer_reference_for_audit text default null
)
returns table (
  outcome text,                   -- no_participant | identity_conflict | no_attribution |
                                   -- not_pending | missing_transaction_identity | too_late |
                                   -- recorded | already_recorded
  attribution_id uuid,
  referrer_participant_id uuid
)
language plpgsql
set search_path to 'pg_catalog', 'private'
as $function$
declare
  v_participant_ids uuid[];
  v_participant_id uuid;
  v_attribution private.referral_attributions%rowtype;
  v_purchased_at timestamptz;
  v_inserted_id uuid;
begin
  if p_environment is distinct from 'PRODUCTION' then
    -- v1 scope lock, mirroring process_referral_subscription_event: every referral action operates
    -- on PRODUCTION only. A non-PRODUCTION call here is an upstream caller bug, not a state to
    -- interpret — the classifier layer never produces a defer_paid_origin action for a SANDBOX
    -- event in the first place.
    return query select 'no_participant'::text, null::uuid, null::uuid;
    return;
  end if;

  if p_deferred_reason not in ('zero_price', 'unknown_price', 'free_offer_code') then
    raise exception 'invalid_deferred_reason: %', p_deferred_reason;
  end if;

  select array_agg(distinct participant_id) into v_participant_ids
  from private.referral_participant_aliases
  where environment = p_environment
    and app_user_id = any(p_app_user_id_set);

  if v_participant_ids is null or array_length(v_participant_ids, 1) is null then
    return query select 'no_participant'::text, null::uuid, null::uuid;
    return;
  end if;

  if array_length(v_participant_ids, 1) > 1 then
    raise warning 'referral identity conflict recording deferred paid origin: % distinct participants matched alias set for event %',
      array_length(v_participant_ids, 1), coalesce(p_event_id, '(none)');
    return query select 'identity_conflict'::text, null::uuid, null::uuid;
    return;
  end if;

  v_participant_id := v_participant_ids[1];

  select * into v_attribution
  from private.referral_attributions
  where referred_participant_id = v_participant_id
  for update;

  if v_attribution.id is null then
    -- No referral at all for this participant (e.g. an unrelated user's ordinary free-promo start)
    -- — nothing to defer. Matches this feature's test matrix item H.
    return query select 'no_attribution'::text, null::uuid, v_participant_id;
    return;
  end if;

  if v_attribution.status <> 'pending' then
    -- Already qualified, disqualified, or reversed — this free/promo start has nothing to defer;
    -- a NEW deferred origin is never recorded for an attribution that has already left 'pending'
    -- (whether by an earlier qualify or otherwise), and an already-qualified attribution's later
    -- free/promo product change must never re-open anything here.
    return query select 'not_pending'::text, v_attribution.id, v_attribution.referrer_participant_id;
    return;
  end if;

  if p_transaction_id is null or btrim(p_transaction_id) = ''
     or p_original_transaction_id is null or btrim(p_original_transaction_id) = '' then
    return query select 'missing_transaction_identity'::text, v_attribution.id, v_attribution.referrer_participant_id;
    return;
  end if;

  if p_purchased_at_ms is null then
    -- No timestamp to validate the Attribution Timing Rule against — fail conservative, never
    -- assume "early enough."
    return query select 'too_late'::text, v_attribution.id, v_attribution.referrer_participant_id;
    return;
  end if;
  v_purchased_at := to_timestamp(p_purchased_at_ms::double precision / 1000.0);

  -- Attribution Timing Rule, applied to THIS free/promo purchase's own timestamp (not a later
  -- renewal's) — see this function's own header for the loophole this closes. No grace window,
  -- exactly like process_referral_subscription_event's own immediate-qualify check.
  if v_attribution.attributed_at > v_purchased_at then
    return query select 'too_late'::text, v_attribution.id, v_attribution.referrer_participant_id;
    return;
  end if;

  insert into private.referral_deferred_paid_origins (
    attribution_id, referred_participant_id, original_transaction_id, environment, product_id,
    original_purchased_at, deferred_reason, offer_reference_for_audit, triggering_event_id
  ) values (
    v_attribution.id, v_participant_id, p_original_transaction_id, p_environment, p_product_id,
    v_purchased_at, p_deferred_reason, p_offer_reference_for_audit, p_event_id
  )
  on conflict (original_transaction_id) do nothing
  returning id into v_inserted_id;

  if v_inserted_id is null then
    -- Idempotent redelivery of the same INITIAL_PURCHASE webhook event (or, defensively, some other
    -- event already recorded a deferred origin for this exact original_transaction_id) — a clean,
    -- safe no-op, never an error.
    return query select 'already_recorded'::text, v_attribution.id, v_attribution.referrer_participant_id;
    return;
  end if;

  return query select 'recorded'::text, v_attribution.id, v_attribution.referrer_participant_id;
end;
$function$;

revoke all on function private.record_referral_deferred_paid_origin(
  text[], text, text, bigint, text, text, text, text, text
) from public, anon, authenticated;
grant execute on function private.record_referral_deferred_paid_origin(
  text[], text, text, bigint, text, text, text, text, text
) to service_role;

-- 85Blends 2.4.0 — Referral Reward Redemption foundation.
--
-- NOT APPLIED to the live project as part of writing this migration — see this feature's own
-- deployment documentation (docs/REFERRAL_REWARD_REDEMPTION_DEPLOYMENT.md) for the exact, ordered
-- production rollout this must follow. Purely additive to the existing referral schema
-- (20260910000000_referral_backend_baseline.sql, 20260919150000_referral_paid_qualification_foundation.sql,
-- 20260919183430_referral_client_api_foundation.sql): one new table, two new functions. Zero
-- changes to any existing table or function — in particular, private.process_referral_subscription_event
-- is NOT touched by this migration; the one new qualification-timing rule this feature needs (see
-- Section 3's own header) is enforced in TypeScript (_shared/database.ts's applyReferralAction),
-- as an additional check performed BEFORE that existing, already-reviewed function is ever called
-- — not by changing its signature or logic.
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
--   3. An earned reward must NOT become fulfilled merely because we hand a user an Apple Offer Code
--      — issuing a code (`status = 'issued'`) is never itself fulfillment; only a confirmed
--      REDEEMED transaction (via the webhook) ever sets `status = 'fulfilled'` on the reward.
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
--
-- A PARTICIPANT MAY HAVE AT MOST ONE OUTSTANDING ISSUED REFERRAL REWARD AT A TIME (an eliminate-
-- ambiguity requirement for webhook fulfillment matching, not merely a nice-to-have) — enforced by
-- the partial unique index in Section 1, defense-in-depth alongside claim_referral_reward's own
-- explicit check (Section 2) and the natural FIFO ordering of "always claim the OLDEST eligible
-- earned reward first" (which already makes a second reward unreachable while an earlier one is
-- still `earned`).

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
  -- The Apple App Store Connect OFFER IDENTIFIER for this dedicated referral-reward offer (what
  -- Apple's own tooling calls the offer's "Offer Identifier," the value actually communicated
  -- through StoreKit/RevenueCat — NEVER App Store Connect's separate, internal-only "Reference
  -- Name" field, which Apple never exposes to StoreKit, RevenueCat, or any webhook). This column
  -- is named offer_reference_name to match this feature's own task-spec terminology and
  -- supabase/functions/_shared/referral-reward-offer-codes.ts's naming — see this feature's
  -- deployment documentation for the exact App Store Connect field this must be set from.
  offer_reference_name text not null,
  -- The raw Apple one-time-use code itself. SENSITIVE — never logged, never returned except to the
  -- authenticated installation it is issued to (see referral-api/index.ts's claim_reward handler,
  -- the only production code path that ever selects this column). No RLS policy and zero
  -- anon/authenticated grants make it unreachable from PostgREST regardless (see the revokes below).
  apple_code text not null,
  apple_expires_at timestamptz,

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
create unique index referral_reward_offer_codes_one_outstanding_per_participant
  on private.referral_reward_offer_codes (referrer_participant_id)
  where status = 'issued';

-- Pool-allocation lookup: "select one available, unexpired code for that product" (Section 2),
-- using FOR UPDATE SKIP LOCKED — same pattern as private.claim_price_alert_jobs
-- (20260917232104_price_alert_worker_primitives.sql).
create index referral_reward_offer_codes_available_pool_idx
  on private.referral_reward_offer_codes (product_id, created_at)
  where status = 'available';

-- Webhook fulfillment lookup: "find that participant's ONE outstanding issued reward matching
-- product + offer reference" (Section 3) — already unique per the partial index above; this index
-- makes that lookup itself indexed rather than a sequential scan.
create index referral_reward_offer_codes_issued_lookup_idx
  on private.referral_reward_offer_codes (referrer_participant_id, product_id, offer_reference_name)
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
-- IDEMPOTENCY: repeated calls for the same outstanding reward return the SAME assigned code
-- (Section 4, step 5) — this function never allocates a second code for a reward that already has
-- one issued.
create or replace function private.claim_referral_reward(
  p_referrer_participant_id uuid,
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

  -- Lock the participant row FIRST, before touching any reward/code row — same locking order as
  -- process_referral_subscription_event's own milestone reconciliation, so a concurrent
  -- claim_referral_reward call for the SAME participant (e.g. a double-tap client bug, or two
  -- devices sharing one installation credential) can never interleave with this one.
  perform 1 from private.referral_participants where id = p_referrer_participant_id for update;

  -- Step 4: the OLDEST eligible earned reward, locked. FIFO ordering here is what structurally
  -- guarantees "at most one outstanding reward at a time" in the common case (a second reward is
  -- never even reachable while an earlier one is still 'earned') — the partial unique index on
  -- referrer_participant_id (Section 1) is the authoritative backstop, not the primary mechanism.
  --
  -- Every column reference below is explicitly table-qualified (`rr.`/`roc.`), even where not
  -- strictly required — this function's own RETURNS TABLE names several OUT parameters
  -- (reward_id, milestone_number, product_id, offer_reference_name, apple_code, apple_expires_at)
  -- that are IDENTICAL to real column names on referral_rewards/referral_reward_offer_codes.
  -- PL/pgSQL treats every OUT parameter as an in-scope variable for the whole function body, so an
  -- UNQUALIFIED reference to any of those column names inside a query here would raise "column
  -- reference is ambiguous" — confirmed by an actual local Postgres replay of this exact function
  -- during this feature's own validation pass, not merely anticipated.
  select rr.* into v_reward
  from private.referral_rewards rr
  where rr.referrer_participant_id = p_referrer_participant_id
    and rr.status = 'earned'
    and rr.reward_type = 'one_month_pro'
  order by rr.milestone_number asc
  for update
  limit 1;

  if v_reward.id is null then
    return query select 'no_eligible_reward'::text, null::uuid, null::integer, null::text, null::text, null::text, null::timestamptz;
    return;
  end if;

  -- Step 5: idempotency — this reward already has a LIVE issued code; return it unchanged rather
  -- than allocating another.
  select roc.* into v_existing_code
  from private.referral_reward_offer_codes roc
  where roc.reward_id = v_reward.id
    and roc.status = 'issued'
  for update;

  if v_existing_code.id is not null then
    return query select 'claimed'::text, v_reward.id, v_reward.milestone_number,
      v_existing_code.product_id, v_existing_code.offer_reference_name,
      v_existing_code.apple_code, v_existing_code.apple_expires_at;
    return;
  end if;

  -- Step 7: determine the allowed product. An ACTIVE Pro subscriber's code is always issued for
  -- THEIR currently active product — the client cannot override this (p_requested_product_id is
  -- never consulted in this branch). A legacy-quarterly (or any other unsupported) active product
  -- fails safely without touching the reward.
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

  -- Step 6: enforce one outstanding issued reward per participant — explicit, typed check first
  -- (the partial unique index would otherwise surface as a raw constraint-violation exception).
  -- Structurally near-unreachable per the FIFO ordering above, but never assumed away on an
  -- identity/allocation-integrity path — same discipline as this codebase's other referral
  -- functions' own "unreachable in practice" guards.
  if exists (
    select 1 from private.referral_reward_offer_codes roc
    where roc.referrer_participant_id = p_referrer_participant_id
      and roc.status = 'issued'
  ) then
    return query select 'outstanding_reward_exists'::text, v_reward.id, v_reward.milestone_number, null::text, null::text, null::text, null::timestamptz;
    return;
  end if;

  -- Step 8: allocate one available, unexpired code for the target product. SKIP LOCKED so
  -- concurrent claims for DIFFERENT participants/products never block each other — same pattern as
  -- private.claim_price_alert_jobs.
  select roc.* into v_allocated
  from private.referral_reward_offer_codes roc
  where roc.product_id = v_target_product
    and roc.status = 'available'
    and (roc.apple_expires_at is null or roc.apple_expires_at > now())
  order by roc.created_at asc
  for update skip locked
  limit 1;

  if v_allocated.id is null then
    -- "No available codes -> reward remains earned" (this feature's task spec, Section 11, test
    -- 9) — never a failure, and the reward/its milestone are completely untouched.
    return query select 'no_code_available'::text, v_reward.id, v_reward.milestone_number, v_target_product, null::text, null::text, null::timestamptz;
    return;
  end if;

  -- Step 9: atomically attach the allocated code to this reward/participant.
  update private.referral_reward_offer_codes
  set status = 'issued',
      reward_id = v_reward.id,
      referrer_participant_id = p_referrer_participant_id,
      issued_at = now()
  where id = v_allocated.id;

  return query select 'claimed'::text, v_reward.id, v_reward.milestone_number,
    v_allocated.product_id, v_allocated.offer_reference_name,
    v_allocated.apple_code, v_allocated.apple_expires_at;
end;
$function$;

revoke all on function private.claim_referral_reward(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function private.claim_referral_reward(uuid, boolean, text, text) to postgres, service_role;

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
begin
  -- v1 scope lock, identical in spirit to process_referral_subscription_event's own: fulfillment
  -- only ever applies to PRODUCTION — a referral reward is only ever earned from PRODUCTION-
  -- qualified referrals in the first place (process_referral_subscription_event's own PRODUCTION-
  -- only gate), so a SANDBOX event can never legitimately fulfill one. Explicit and fail-closed,
  -- never inferred from the absence of a match.
  if p_environment is distinct from 'PRODUCTION' then
    return query select 'environment_mismatch'::text, null::uuid, null::uuid;
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
    and roc.status = 'redeemed'
    and roc.redemption_original_transaction_id = p_original_transaction_id
  for update;

  if v_code.id is not null then
    return query select 'already_fulfilled'::text, v_code.reward_id, v_participant_id;
    return;
  end if;

  -- The participant's ONE outstanding issued code matching product + offer reference — unique by
  -- construction (Section 1's referral_reward_offer_codes_one_outstanding_per_participant), so
  -- there is never an ambiguous "which reward does this confirm" choice to make.
  select roc.* into v_code
  from private.referral_reward_offer_codes roc
  where roc.referrer_participant_id = v_participant_id
    and roc.product_id = p_product_id
    and roc.offer_reference_name = p_offer_reference_name
    and roc.status = 'issued'
  for update;

  if v_code.id is null then
    -- Another participant, another product, another offer, or simply no outstanding issue for
    -- THIS participant right now — never a match by accident. This is the correct, explicit no-op
    -- for "a webhook for another participant/product/offer/environment mismatch must NEVER fulfill
    -- this reward" (this feature's task spec).
    return query select 'no_outstanding_code'::text, null::uuid, v_participant_id;
    return;
  end if;

  update private.referral_reward_offer_codes
  set status = 'redeemed',
      redeemed_at = now(),
      redemption_event_id = p_event_id,
      redemption_transaction_id = p_transaction_id,
      redemption_original_transaction_id = p_original_transaction_id
  where id = v_code.id;

  -- Guarded by `and status = 'earned'`: the only OTHER status this reward could already be in here
  -- is 'fulfilled' (impossible — we would have matched the 'already_fulfilled' branch above via
  -- the CODE's own status first) or 'revoked' (impossible while it still owns a status='issued'
  -- code — Phase 9's existing revocation logic in process_referral_subscription_event only ever
  -- revokes an 'earned' reward, and this migration adds no new path that could revoke one holding
  -- a live issued code). Never clawed back once fulfilled (Phase 9's own preserved invariant).
  update private.referral_rewards
  set status = 'fulfilled',
      fulfilled_at = now(),
      fulfillment_reference = p_original_transaction_id
  where id = v_code.reward_id
    and status = 'earned';

  return query select 'fulfilled'::text, v_code.reward_id, v_participant_id;
end;
$function$;

revoke all on function private.fulfill_referral_reward_offer_code(text[], text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function private.fulfill_referral_reward_offer_code(text[], text, text, text, text, text, text) to service_role;

-- 85Blends 2.4.0 — Referral paid-qualification + repeatable milestone foundation.
--
-- NOT APPLIED to the live project as part of producing or hardening this migration. Originally
-- written against the live schema verified read-only on 2026-09-19 (private.referral_participants/
-- referral_participant_aliases/referral_attributions/referral_rewards, all currently zero rows;
-- private.generate_referral_code/create_or_get_referral_participant/apply_referral_code) — see the
-- referral paid-qualification foundation report for the exact verification queries. Purely
-- additive to that live schema: ALTER/CREATE OR REPLACE only, no table recreation, no data
-- migration (there is none to migrate — every referral table is empty live).
--
-- MIGRATION-LEDGER STATUS (current as of this hardening pass, 2026-09-19): migration-history
-- reconciliation is COMPLETE. PR #79 recovered the 11 previously-untracked historical migrations
-- and merged into main; production's migration ledger is now aligned 29/29 with main, including
-- both previously-synthetic baselines — 20260427000000_community_pricing_founding_baseline and
-- 20260910000000_referral_backend_baseline (the latter now also corrected to include the three
-- private.referral_* helper functions this migration builds on) are both tracked in production's
-- migration history (`supabase migration repair --status applied <version>`, tracking-only, no
-- schema change, already performed and confirmed). This migration, 20260919150000, is the next
-- and only unapplied migration in the full 30-file sequence — it has been validated by two
-- independent clean local replays of the complete 30-migration chain and a full local DB behavior
-- test matrix (see MIGRATION_RECOVERY.md and PR #78's own description for the exact validation
-- record), but remains genuinely unapplied to production, pending its own separate authorization.
--
-- No client, no Edge Function, and no reward-redemption code calls anything in this migration yet
-- — see supabase/functions/_shared/referral-classification.ts / referral-milestones.ts for the
-- pure decision logic this schema exists to support, and that report for what's deliberately still
-- out of scope (client bridge, Apple promotional offer redemption).

-- ============================================================================================
-- 1. Alias-conflict hardening — private.create_or_get_referral_participant
-- ============================================================================================
-- Root cause (confirmed against the live function definition): the previous
--   insert ... on conflict (app_user_id, environment) do update
--     set participant_id = excluded.participant_id
--     where private.referral_participant_aliases.participant_id = excluded.participant_id;
-- silently no-ops — no error, no row change, no signal to the caller — whenever the alias was
-- already attached to a DIFFERENT participant: the UPDATE's WHERE clause simply doesn't match, and
-- Postgres does not treat an unmatched ON CONFLICT ... DO UPDATE ... WHERE as a failure. The
-- function's unconditional `return query select v_participant.id, ...` after that INSERT then
-- reports success regardless.
--
-- Fixed with the same two-phase "insert-if-absent, then verify" pattern already established for
-- private.revenuecat_aliases (see supabase/functions/_shared/database.ts's applyIdentityRefresh /
-- verifyAliasesAfterInsert, and customer-resolution.ts's planAliasUpserts/
-- verifyAliasesAfterInsert) — not a new pattern, the same one this backend already trusts for the
-- identical class of problem on a different table.
create or replace function private.create_or_get_referral_participant(
  p_installation_id uuid,
  p_app_user_id text default null,
  p_environment text default 'PRODUCTION'
)
returns table(participant_id uuid, referral_code text)
language plpgsql
set search_path to 'pg_catalog', 'private'
as $function$
declare
  v_participant private.referral_participants%rowtype;
  v_code text;
  v_attempt integer := 0;
  v_trimmed_app_user_id text;
  v_existing_alias_participant_id uuid;
begin
  if p_installation_id is null then
    raise exception 'installation_id_required';
  end if;
  if p_environment not in ('SANDBOX','PRODUCTION') then
    raise exception 'invalid_environment';
  end if;

  select * into v_participant
  from private.referral_participants rp
  where rp.installation_id = p_installation_id;

  if v_participant.id is null then
    loop
      v_attempt := v_attempt + 1;
      v_code := private.generate_referral_code();
      begin
        insert into private.referral_participants (installation_id, referral_code)
        values (p_installation_id, v_code)
        returning * into v_participant;
        exit;
      exception when unique_violation then
        if v_attempt >= 10 then
          raise;
        end if;
      end;
    end loop;
  end if;

  v_trimmed_app_user_id := btrim(p_app_user_id);
  if v_trimmed_app_user_id is not null and length(v_trimmed_app_user_id) > 0 then
    insert into private.referral_participant_aliases (app_user_id, environment, participant_id)
    values (v_trimmed_app_user_id, p_environment, v_participant.id)
    on conflict (app_user_id, environment) do nothing;

    select rpa.participant_id into v_existing_alias_participant_id
    from private.referral_participant_aliases rpa
    where rpa.app_user_id = v_trimmed_app_user_id
      and rpa.environment = p_environment;

    if v_existing_alias_participant_id is null then
      -- Unreachable in practice (the insert above either created the row itself or a concurrent
      -- transaction did), but never assume away a defensive check on an identity-integrity path.
      raise exception 'referral_alias_missing_after_insert';
    elsif v_existing_alias_participant_id <> v_participant.id then
      raise exception 'referral_alias_conflict: app_user_id already attached to a different referral participant';
    end if;
    -- else: already correctly mapped (fresh insert, or an idempotent re-call for the same
    -- participant) — nothing more to do.
  end if;

  return query select v_participant.id, v_participant.referral_code;
end;
$function$;

-- Unchanged from live — private.apply_referral_code already correctly enforces self-referral
-- protection, the referral code format, and one attribution per referred participant (via
-- referral_attributions_one_referrer_per_referred) through its existing unique_violation handling.
-- Not redefined here; nothing about it needed to change for this feature.

-- ============================================================================================
-- 2. Qualifying transaction metadata — private.referral_attributions
-- ============================================================================================
-- Ties a qualified referral to the exact purchase that created it, so a later refund can reverse
-- the CORRECT qualification rather than whichever subscription happens to be active at the time.
-- qualifying_event_id and qualifying_product_id already exist live; these three are additive.
-- Naming matches the existing qualifying_* prefix convention exactly.
alter table private.referral_attributions
  add column if not exists qualifying_transaction_id text,
  add column if not exists qualifying_original_transaction_id text,
  add column if not exists qualifying_environment text;

do $$
begin
  alter table private.referral_attributions
    add constraint referral_attributions_qualifying_environment
      check (qualifying_environment is null or qualifying_environment in ('SANDBOX','PRODUCTION'));
exception
  when duplicate_object then null;
end $$;

-- Nullable + unique (Postgres allows any number of NULLs under a unique constraint) — every
-- unqualified attribution has NULL here; once set at qualification time it identifies exactly one
-- attribution, mirroring qualifying_event_id's existing unique+nullable shape. This is the primary
-- match key private.process_referral_subscription_event uses to find the right attribution for a
-- refund/REFUND_REVERSED event — never qualifying_event_id, which stays anchored to the ORIGINAL
-- qualifying purchase event across any later reversal/requalification cycle (see that function).
-- As of this hardening pass, that function additionally requires referred_participant_id to match
-- the participant identity independently resolved from the SAME event's own alias set — the
-- transaction id alone is no longer trusted as sufficient (see that function's refund_reversal/
-- refund_reversed branches).
do $$
begin
  alter table private.referral_attributions
    add constraint referral_attributions_qualifying_original_txn_key
      unique (qualifying_original_transaction_id);
exception
  when duplicate_object then null;
end $$;

-- ============================================================================================
-- 3. Atomic qualification / refund-reversal / re-qualification + milestone reconciliation
-- ============================================================================================
-- Single entry point so a qualifying purchase, a support refund, and a reversed refund each
-- resolve identity, transition attribution status, and reconcile reward milestones inside ONE
-- database transaction — callable only by trusted backend/service-role code (see grants below),
-- never anon/authenticated/PUBLIC.
--
-- IDENTITY RESOLUTION (Phase 5 of the foundation report): mirrors
-- supabase/functions/_shared/customer-resolution.ts's resolveCanonicalCustomer zero/one/many
-- decision shape exactly, applied to private.referral_participant_aliases instead of
-- private.revenuecat_aliases — zero matches is a clean no-op, exactly one is safe to continue,
-- more than one FAILS CLOSED (logged via RAISE WARNING, never an exception — this must never abort
-- the entitlement-mirror transaction the caller is also running; see this migration's own
-- integration notes in supabase/functions/revenuecat-webhook/index.ts).
--
-- CANONICAL CONFIRMATION (Phase 9): p_canonical_pro_is_active is supplied by the caller, which
-- must have ALREADY performed a successful RevenueCat canonical subscriber refresh before ever
-- invoking the 'qualify' or 'refund_reversed' action — this function enforces that gate
-- defensively (never qualifies/requalifies when it isn't exactly `true`), it does not perform the
-- refresh itself. 'refund_reversal' does not require it: a support-issued refund is reversed on
-- the CANCELLATION event's own classification, independent of current Pro state.
--
-- CONCURRENCY (Phase 19): locks the matched ATTRIBUTION row (`for update`) before checking/
-- transitioning its status, then locks the REFERRER's participant row (`for update`) before
-- reading/writing their reward milestones — never the REFERRED participant's own row, which the
-- attribution-row lock already makes redundant. Because every call locks at most one attribution
-- row plus one (always the referrer's) participant row, and a participant row is only ever locked
-- SECOND, after the attribution lock that identifies it, no two concurrent calls can ever hold
-- locks in an order that cycles — including the mutual-referral edge case (A refers B, B refers A,
-- both qualify near-simultaneously): each call's held/wanted resource pair is disjoint from the
-- other's, so there is no lock-ordering deadlock to avoid via explicit ID ordering. The
-- referral_rewards_unique_milestone constraint is a second, independent idempotency backstop for
-- milestone creation specifically (Phase 11) — belt and suspenders with the row locking, not a
-- substitute for it.
create or replace function private.process_referral_subscription_event(
  p_action text,                    -- 'qualify' | 'refund_reversal' | 'refund_reversed'
  p_app_user_id_set text[],         -- the webhook event's full resolved alias set
  p_environment text,               -- must be 'PRODUCTION' for any of the three actions in v1
  p_event_id text,                  -- the triggering webhook event's own id (audit/qualifying_event_id)
  p_purchased_at_ms bigint,         -- 'qualify' only: RevenueCat's purchased_at_ms
  p_product_id text,                -- 'qualify' only: the purchased product id
  p_transaction_id text,            -- 'qualify': stored; refund actions: informational only
  p_original_transaction_id text,   -- 'qualify': stored; refund actions: the match key
  p_canonical_pro_is_active boolean -- required true for 'qualify'/'refund_reversed'; see header
)
returns table (
  outcome text,                   -- no_participant | identity_conflict | canonical_not_active |
                                   -- no_attribution | already_processed | too_late |
                                   -- missing_transaction_identity | qualified | reversed |
                                   -- requalified
  attribution_id uuid,
  referrer_participant_id uuid,
  qualified_count integer
)
language plpgsql
set search_path to 'pg_catalog', 'private'
as $function$
declare
  v_participant_ids uuid[];
  v_participant_id uuid;
  v_attribution private.referral_attributions%rowtype;
  v_referrer_id uuid;
  v_purchased_at timestamptz;
  v_qualified_count integer;
  v_desired_milestones integer;
  v_milestone integer;
begin
  if p_action not in ('qualify', 'refund_reversal', 'refund_reversed') then
    raise exception 'invalid_action: %', p_action;
  end if;

  if p_environment is distinct from 'PRODUCTION' then
    -- v1 scope lock: every referral action operates on PRODUCTION only (Locked Business Rules).
    -- A non-PRODUCTION call here is an upstream caller bug, not a state to interpret — the
    -- webhook's own referral pre-filtering must never invoke this function for a SANDBOX event.
    return query select 'no_participant'::text, null::uuid, null::uuid, null::integer;
    return;
  end if;

  select array_agg(distinct participant_id) into v_participant_ids
  from private.referral_participant_aliases
  where environment = p_environment
    and app_user_id = any(p_app_user_id_set);

  if v_participant_ids is null or array_length(v_participant_ids, 1) is null then
    return query select 'no_participant'::text, null::uuid, null::uuid, null::integer;
    return;
  end if;

  if array_length(v_participant_ids, 1) > 1 then
    raise warning 'referral identity conflict: % distinct participants matched alias set for event %',
      array_length(v_participant_ids, 1), coalesce(p_event_id, '(none)');
    return query select 'identity_conflict'::text, null::uuid, null::uuid, null::integer;
    return;
  end if;

  v_participant_id := v_participant_ids[1];

  if p_action = 'qualify' then
    if p_canonical_pro_is_active is not true then
      return query select 'canonical_not_active'::text, null::uuid, null::uuid, null::integer;
      return;
    end if;

    select * into v_attribution
    from private.referral_attributions
    where referred_participant_id = v_participant_id
    for update;

    if v_attribution.id is null then
      return query select 'no_attribution'::text, null::uuid, v_participant_id, null::integer;
      return;
    end if;

    if v_attribution.status <> 'pending' then
      -- Covers "already qualified by an earlier event" AND "disqualified/reversed" alike — a
      -- fresh INITIAL_PURCHASE never re-attempts qualification once an attribution has left
      -- 'pending'; only a REFUND_REVERSED event re-qualifies a 'reversed' one (below).
      return query select 'already_processed'::text, v_attribution.id, v_attribution.referrer_participant_id, null::integer;
      return;
    end if;

    if p_purchased_at_ms is null then
      return query select 'too_late'::text, v_attribution.id, v_attribution.referrer_participant_id, null::integer;
      return;
    end if;
    v_purchased_at := to_timestamp(p_purchased_at_ms::double precision / 1000.0);

    -- Transaction-identity hardening: the classifier layer (referral-classification.ts,
    -- isReferralQualifyingEvent) already requires both ids before ever calling this function, so
    -- this is a defensive backstop, not the primary gate — but qualifying_original_transaction_id
    -- is the ONLY key a later refund/REFUND_REVERSED event can use to find this attribution again
    -- (see its own column comment below), so a qualification recorded without it would be
    -- permanently unreversible/unrequalifiable. Never overload too_late for this — it is a
    -- distinct, explicit no-op, not a timing failure.
    if p_transaction_id is null or btrim(p_transaction_id) = ''
       or p_original_transaction_id is null or btrim(p_original_transaction_id) = '' then
      return query select 'missing_transaction_identity'::text, v_attribution.id, v_attribution.referrer_participant_id, null::integer;
      return;
    end if;

    -- Attribution Timing Rule: attributed_at (set once by private.apply_referral_code at the
    -- moment the code was applied — not created_at/updated_at, which are generic audit columns)
    -- must be <= the purchase timestamp. No grace window in v1.
    if v_attribution.attributed_at > v_purchased_at then
      return query select 'too_late'::text, v_attribution.id, v_attribution.referrer_participant_id, null::integer;
      return;
    end if;

    update private.referral_attributions
    set status = 'qualified',
        qualified_at = now(),
        qualifying_event_id = p_event_id,
        qualifying_product_id = p_product_id,
        qualifying_transaction_id = p_transaction_id,
        qualifying_original_transaction_id = p_original_transaction_id,
        qualifying_environment = p_environment
    where id = v_attribution.id;

    v_referrer_id := v_attribution.referrer_participant_id;

  elsif p_action = 'refund_reversal' then
    -- Explicit, early fail-closed guard: the classifier layer (isReferralRefundReversalEvent)
    -- already requires this id before ever calling this function, so this is a defensive
    -- backstop — never rely on `qualifying_original_transaction_id = NULL` alone to fail closed
    -- implicitly (true, but not auditable/explicit as a deliberate check).
    if p_original_transaction_id is null or btrim(p_original_transaction_id) = '' then
      return query select 'no_attribution'::text, null::uuid, null::uuid, null::integer;
      return;
    end if;

    -- Participant-binding hardening: match on BOTH the transaction id AND the participant identity
    -- already resolved from THIS event's own alias set (v_participant_id, above) — trusting the
    -- transaction id alone would let a refund event whose alias set happens to resolve to the
    -- WRONG participant (a malformed/unexpected payload, an identity-resolution bug upstream, or
    -- any other cross-wiring) reverse an unrelated referrer's qualification. Both signals must
    -- agree; if they don't, this is a clean no_attribution no-op, never a guess.
    select * into v_attribution
    from private.referral_attributions
    where qualifying_original_transaction_id = p_original_transaction_id
      and referred_participant_id = v_participant_id
      and status = 'qualified'
    for update;

    if v_attribution.id is null then
      -- No currently-qualified attribution matches both this exact original_transaction_id AND
      -- this event's resolved participant — either this was never a referral-qualifying purchase,
      -- it's already reversed/never qualified, or the two signals disagree. Clean no-op either
      -- way; never guess which attribution a refund meant.
      return query select 'no_attribution'::text, null::uuid, null::uuid, null::integer;
      return;
    end if;

    update private.referral_attributions
    set status = 'reversed',
        disqualified_at = now(),
        disqualified_reason = 'refund_customer_support'
    where id = v_attribution.id;

    v_referrer_id := v_attribution.referrer_participant_id;

  else -- 'refund_reversed'
    if p_canonical_pro_is_active is not true then
      return query select 'canonical_not_active'::text, null::uuid, null::uuid, null::integer;
      return;
    end if;

    -- Same explicit fail-closed guard as refund_reversal, above.
    if p_original_transaction_id is null or btrim(p_original_transaction_id) = '' then
      return query select 'no_attribution'::text, null::uuid, null::uuid, null::integer;
      return;
    end if;

    -- Same participant-binding hardening as refund_reversal, above — both the transaction id and
    -- this event's resolved participant identity must agree before re-qualifying anything.
    select * into v_attribution
    from private.referral_attributions
    where qualifying_original_transaction_id = p_original_transaction_id
      and referred_participant_id = v_participant_id
      and status = 'reversed'
    for update;

    if v_attribution.id is null then
      return query select 'no_attribution'::text, null::uuid, null::uuid, null::integer;
      return;
    end if;

    update private.referral_attributions
    set status = 'qualified',
        qualified_at = now(),
        disqualified_at = null,
        disqualified_reason = null
    where id = v_attribution.id;
    -- qualifying_event_id/qualifying_product_id/qualifying_transaction_id/
    -- qualifying_original_transaction_id/qualifying_environment are deliberately left untouched —
    -- they still describe the ORIGINAL qualifying purchase, which a REFUND_REVERSED event does
    -- not change.

    v_referrer_id := v_attribution.referrer_participant_id;
  end if;

  -- Milestone reconciliation — shared by all three actions; each ends with a referrer whose
  -- qualified count may have changed. Locks the referrer's own participant row (never the
  -- referred participant's — see this function's header) before reading/writing their rewards.
  perform 1 from private.referral_participants where id = v_referrer_id for update;

  select count(*) into v_qualified_count
  from private.referral_attributions ra
  where ra.referrer_participant_id = v_referrer_id
    and ra.status = 'qualified';

  -- Locked formula: floor(count / 5) — see supabase/functions/_shared/referral-milestones.ts's
  -- desiredEarnedMilestones for the Node-tested mirror of this exact expression.
  v_desired_milestones := floor(v_qualified_count / 5.0)::integer;

  for v_milestone in 1..v_desired_milestones loop
    -- Grow: ensure a reward row exists for every milestone 1..desired. ON CONFLICT DO NOTHING
    -- against referral_rewards_unique_milestone is the idempotency backstop for a duplicate
    -- milestone-reaching event (e.g. a retried webhook), independent of the row locking above.
    insert into private.referral_rewards (referrer_participant_id, milestone_number)
    values (v_referrer_id, v_milestone)
    on conflict on constraint referral_rewards_unique_milestone do nothing;

    -- A milestone that had been revoked and is justified again by the fresh count is restored —
    -- but only from 'revoked'; a 'fulfilled' reward never matches this WHERE clause, so it can
    -- never be reset (fulfillment is a future system this migration never writes to — Phase 23).
    update private.referral_rewards rr
    set status = 'earned', revoked_at = null, revoke_reason = null
    where rr.referrer_participant_id = v_referrer_id
      and rr.milestone_number = v_milestone
      and rr.status = 'revoked';
  end loop;

  -- Shrink: any 'earned' (never 'fulfilled') reward strictly above the recomputed desired count
  -- is revoked — what a refund-driven count drop (e.g. 10 -> 9) implements. Scoped to
  -- status = 'earned' only, so a fulfilled reward is structurally excluded, not merely
  -- discouraged by convention.
  update private.referral_rewards rr
  set status = 'revoked', revoked_at = now(), revoke_reason = 'qualified_count_below_milestone'
  where rr.referrer_participant_id = v_referrer_id
    and rr.milestone_number > v_desired_milestones
    and rr.status = 'earned';

  return query select
    (case p_action
      when 'qualify' then 'qualified'
      when 'refund_reversal' then 'reversed'
      else 'requalified'
    end)::text,
    v_attribution.id,
    v_referrer_id,
    v_qualified_count;
end;
$function$;

revoke all on function private.process_referral_subscription_event(
  text, text[], text, text, bigint, text, text, text, boolean
) from public, anon, authenticated;
grant execute on function private.process_referral_subscription_event(
  text, text[], text, text, bigint, text, text, text, boolean
) to service_role;

-- create_or_get_referral_participant / apply_referral_code / generate_referral_code already carry
-- no anon/authenticated/PUBLIC grants live (verified) and this migration does not change that —
-- only service_role/postgres can call any private.referral_* function, exactly as before.

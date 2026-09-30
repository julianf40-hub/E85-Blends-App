-- 85Blends 2.4.0 — Referral reward active-product fallback: final hardening.
-- Follow-up to 20260929230218_referral_reward_active_product_webhook_fallback.sql (which is left
-- untouched: it is already applied to production and its version/body must stay as recorded).
--
-- This migration replaces ONLY the body of the private.claim_referral_reward wrapper. The public
-- signature, the return shape, private.claim_referral_reward_core (the reviewed claim/state-machine
-- implementation), grants, search_path and the non-SECURITY-DEFINER posture are all unchanged.
--
-- THREE CORRECTNESS GAPS CLOSED (found in the final PR #113 review):
--
--   1. GATING — the webhook-history fallback now runs ONLY when p_active_pro_is_active = true AND
--      p_active_product_id IS NULL, i.e. when referral-api's fresh RevenueCat lookup could not
--      resolve the active Apple product at all. A confidently resolved product is passed to the core
--      untouched — supported or not — so a known legacy/unsupported product (e.g.
--      com.85blends.subscription.quarterly) still ends in `legacy_or_unsupported_product_active` and
--      historical evidence can never turn it into an eligible supported product. (Previously the
--      fallback also ran for a resolved-but-unsupported product.)
--
--   2. STATE REDUCTION — evidence is reduced to the LATEST lifecycle event PER SUBSCRIPTION before
--      any expiration is compared. The subscription identity is event.original_transaction_id: the
--      same key private.process_referral_subscription_event already uses to match a refund back to
--      the purchase it reverses. Lifecycle events considered for ordering are INITIAL_PURCHASE,
--      RENEWAL, CANCELLATION, UNCANCELLATION and EXPIRATION, ordered by event_timestamp, then
--      received_at, then event_id (deterministic). A subscription contributes evidence only when its
--      latest lifecycle event is `processed` and is INITIAL_PURCHASE, RENEWAL, UNCANCELLATION, or a
--      CANCELLATION whose cancel_reason is NOT 'CUSTOMER_SUPPORT' (auto-renew turned off: access
--      continues until expiration). A latest EXPIRATION, or a latest CUSTOMER_SUPPORT CANCELLATION
--      (a support-issued refund — exactly the signal isReferralRefundReversalEvent treats as a
--      refund), invalidates that subscription entirely, whatever expiration its earlier
--      purchase/renewal rows advertised. A latest lifecycle row in any non-`processed` status also
--      contributes nothing (fail closed until the next processed event). Events with no
--      original_transaction_id never count. Every other event type (PRODUCT_CHANGE, BILLING_ISSUE,
--      TRANSFER, TEST, ...) is neither evidence nor invalidation — unchanged from 20260929230218,
--      which ignored them as well; a pending product change therefore keeps resolving the product
--      that is actually still in effect until RevenueCat records the renewal on the new product.
--
--   3. IDENTITY — an event belongs to the claiming participant when ANY of its identities (the
--      ledger's app_user_id, its original_app_user_id, or the payload's event.aliases[]) is one of
--      that participant's own private.referral_participant_aliases rows in the SAME environment as
--      the claim. An event whose identities ALSO map to a different participant in that environment
--      has ambiguous ownership and is excluded — the same zero/one/many fail-closed rule
--      process_referral_subscription_event applies to its alias set. Cross-environment aliases never
--      match (alias rows and events are both bound to p_environment).
--
-- UNCHANGED: the three-product allowlist, unexpired evidence only, greatest expiration wins ACROSS
-- subscriptions, a tie at the greatest expiration across distinct products fails closed (NULL is
-- passed to the core), the fresh RevenueCat lookup remains the only source of "Pro is active".
--
-- REPLAY SAFETY: a single `create or replace function` on the existing signature, guarded by an
-- existence check on the core function; re-running is a no-op. No table data is read or written
-- by this migration itself. No dynamic SQL, no logging of identities, codes or payloads.

do $$
begin
  if to_regprocedure('private.claim_referral_reward_core(uuid, text, boolean, text, text)') is null then
    raise exception
      'private.claim_referral_reward_core(uuid, text, boolean, text, text) is missing — apply 20260929230218_referral_reward_active_product_webhook_fallback.sql first';
  end if;
end $$;

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
  v_effective_active_product_id text := p_active_product_id;
  v_fallback_product_id text;
  v_participant_aliases text[];
  v_supported_products constant text[] := array[
    'com.85blends.subscription.monthly',
    'com.85blends.subscription.threemonth',
    'com.85blends.subscription.annual'
  ];
begin
  -- (1) Fallback ONLY for an unresolved product. A resolved product — supported or not — goes to
  -- the core untouched, where an unsupported one fails closed.
  if p_active_pro_is_active is true and p_active_product_id is null then
    -- (3) Every identity bound to THIS participant in THIS environment.
    select array_agg(a.app_user_id)
      into v_participant_aliases
    from private.referral_participant_aliases a
    where a.participant_id = p_referrer_participant_id
      and a.environment = p_environment;

    if v_participant_aliases is not null then
      with candidate as (
        select
          e.event_id,
          e.event_type,
          e.event_timestamp,
          e.received_at,
          e.processing_status,
          nullif(btrim(e.raw_payload #>> '{event,original_transaction_id}'), '') as original_transaction_id,
          e.raw_payload #>> '{event,product_id}' as evidence_product_id,
          e.raw_payload #>> '{event,expiration_at_ms}' as evidence_expiration_at_ms,
          e.raw_payload #>> '{event,cancel_reason}' as cancel_reason,
          ids.identity_set
        from private.revenuecat_webhook_events e
        cross join lateral (
          -- The event's full identity set: ledger primary id, original id, payload aliases.
          select array_agg(distinct i.identity) as identity_set
          from (
            select e.app_user_id as identity
            union all
            select e.original_app_user_id
            union all
            select x.value #>> '{}'
            from jsonb_array_elements(
              case when jsonb_typeof(e.raw_payload #> '{event,aliases}') = 'array'
                   then e.raw_payload #> '{event,aliases}'
                   else '[]'::jsonb
              end
            ) as x
            where jsonb_typeof(x.value) = 'string'
          ) as i
          where i.identity is not null
            and btrim(i.identity) <> ''
        ) as ids
        where e.environment = p_environment
          and e.event_type in ('INITIAL_PURCHASE', 'RENEWAL', 'CANCELLATION', 'UNCANCELLATION', 'EXPIRATION')
          and (
            e.app_user_id = any(v_participant_aliases)
            or e.original_app_user_id = any(v_participant_aliases)
            or (
              jsonb_typeof(e.raw_payload #> '{event,aliases}') = 'array'
              and (e.raw_payload #> '{event,aliases}') ?| v_participant_aliases
            )
          )
      ),
      owned as (
        -- Subscription identity is mandatory; ambiguous ownership (any identity bound to a
        -- DIFFERENT participant in this environment) is excluded.
        select c.*
        from candidate c
        where c.original_transaction_id is not null
          and not exists (
            select 1
            from private.referral_participant_aliases o
            where o.environment = p_environment
              and o.participant_id <> p_referrer_participant_id
              and o.app_user_id = any(c.identity_set)
          )
      ),
      latest as (
        -- (2) The most recent lifecycle event per subscription is its current state.
        select distinct on (o.original_transaction_id) o.*
        from owned o
        order by o.original_transaction_id, o.event_timestamp desc, o.received_at desc, o.event_id desc
      ),
      evidence as (
        select
          l.evidence_product_id,
          (l.evidence_expiration_at_ms)::numeric as evidence_expiration_at_ms
        from latest l
        where l.processing_status = 'processed'
          and l.event_type in ('INITIAL_PURCHASE', 'RENEWAL', 'CANCELLATION', 'UNCANCELLATION')
          and (l.event_type <> 'CANCELLATION' or l.cancel_reason is distinct from 'CUSTOMER_SUPPORT')
          and l.evidence_product_id = any(v_supported_products)
          and l.evidence_expiration_at_ms ~ '^[0-9]+$'
          and to_timestamp((l.evidence_expiration_at_ms)::numeric / 1000.0) > now()
      ),
      max_evidence as (
        select max(ev.evidence_expiration_at_ms) as max_expiration_at_ms from evidence ev
      ),
      top_products as (
        select distinct ev.evidence_product_id
        from evidence ev
        join max_evidence mx on mx.max_expiration_at_ms = ev.evidence_expiration_at_ms
      )
      select case when count(*) = 1 then min(tp.evidence_product_id) else null end
        into v_fallback_product_id
      from top_products tp;

      if v_fallback_product_id is not null then
        v_effective_active_product_id := v_fallback_product_id;
      end if;
    end if;
  end if;

  return query
  select * from private.claim_referral_reward_core(
    p_referrer_participant_id,
    p_environment,
    p_active_pro_is_active,
    v_effective_active_product_id,
    p_requested_product_id
  );
end;
$function$;

comment on function private.claim_referral_reward(uuid, text, boolean, text, text) is
  '85Blends 2.4.0 referral reward claim entry point (service-role only). Wraps claim_referral_reward_core; '
  'when Pro is active and the caller could not resolve the Apple product (NULL), resolves it from this '
  'participant''s own same-environment RevenueCat webhook history reduced to the latest lifecycle state per '
  'subscription (original_transaction_id), matching any identity bound to the participant, failing closed on '
  'refund/expiration, missing identity, ambiguous ownership, unsupported products or cross-product ties. '
  'See 20260930090000_referral_reward_active_product_fallback_hardening.sql.';

revoke all on function private.claim_referral_reward(uuid, text, boolean, text, text) from public, anon, authenticated;
grant execute on function private.claim_referral_reward(uuid, text, boolean, text, text) to postgres, service_role;

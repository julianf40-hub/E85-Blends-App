-- 85Blends 2.4.0 referral reward hotfix.
--
-- Live Build 217 Sandbox testing exposed one remaining active-Pro claim failure: RevenueCat API v2
-- could authoritatively confirm that Pro is active, while resolving the active RevenueCat-internal
-- product id to an Apple store product id could still fail. The existing core claim function then
-- correctly returned legacy_or_unsupported_product_active rather than guessing.
--
-- This migration keeps that fail-closed behavior, but adds one narrow server-authoritative fallback:
-- ONLY when the fresh RevenueCat API has already said Pro is active AND the active product id is
-- missing/unsupported, use already-authenticated, already-processed RevenueCat webhook history for
-- this SAME referral participant and SAME environment to identify the current supported Apple
-- product. Evidence must have an unexpired expiration_at_ms and one of the three shipping product
-- ids. The product with the greatest expiration wins, mirroring the active-subscription resolver;
-- if that greatest expiration is ambiguous across multiple products, the fallback remains null and
-- the original core still fails closed.
--
-- Existing claim logic is preserved byte-for-byte under claim_referral_reward_core. The public
-- private.claim_referral_reward signature remains unchanged, so referral-api requires no client or
-- Edge Function contract change.

do $$
begin
  if to_regprocedure('private.claim_referral_reward_core(uuid,text,boolean,text,text)') is null then
    alter function private.claim_referral_reward(uuid, text, boolean, text, text)
      rename to claim_referral_reward_core;
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
  v_supported_products constant text[] := array[
    'com.85blends.subscription.monthly',
    'com.85blends.subscription.threemonth',
    'com.85blends.subscription.annual'
  ];
begin
  if p_active_pro_is_active is true
     and (v_effective_active_product_id is null or v_effective_active_product_id <> all(v_supported_products)) then
    with evidence as (
      select
        e.raw_payload #>> '{event,product_id}' as evidence_product_id,
        (e.raw_payload #>> '{event,expiration_at_ms}')::bigint as evidence_expiration_at_ms
      from private.revenuecat_webhook_events e
      join private.referral_participant_aliases a
        on a.app_user_id = e.app_user_id
       and a.environment = e.environment
      where a.participant_id = p_referrer_participant_id
        and e.environment = p_environment
        and e.processing_status = 'processed'
        and e.event_type in ('INITIAL_PURCHASE', 'RENEWAL', 'CANCELLATION', 'UNCANCELLATION')
        and (e.raw_payload #>> '{event,product_id}') = any(v_supported_products)
        and (e.raw_payload #>> '{event,expiration_at_ms}') ~ '^[0-9]+$'
        and to_timestamp(((e.raw_payload #>> '{event,expiration_at_ms}')::numeric) / 1000.0) > now()
    ),
    max_evidence as (
      select max(evidence_expiration_at_ms) as max_expiration_at_ms from evidence
    ),
    top_products as (
      select distinct ev.evidence_product_id
      from evidence ev
      join max_evidence mx on mx.max_expiration_at_ms = ev.evidence_expiration_at_ms
    )
    select case when count(*) = 1 then min(evidence_product_id) else null end
      into v_fallback_product_id
    from top_products;

    if v_fallback_product_id is not null then
      v_effective_active_product_id := v_fallback_product_id;
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

revoke all on function private.claim_referral_reward(uuid, text, boolean, text, text) from public, anon, authenticated;
grant execute on function private.claim_referral_reward(uuid, text, boolean, text, text) to postgres, service_role;
revoke all on function private.claim_referral_reward_core(uuid, text, boolean, text, text) from public, anon, authenticated;
grant execute on function private.claim_referral_reward_core(uuid, text, boolean, text, text) to postgres, service_role;

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
--      RENEWAL, CANCELLATION, UNCANCELLATION and EXPIRATION, ordered by event_timestamp, then (on an
--      identical event timestamp) an invalidating event before an evidence event, then received_at,
--      then event_id (deterministic; RevenueCat event ids are not chronological, so they are only
--      the final tie-break). The reduction runs over EVERY same-environment lifecycle row of a
--      subscription the participant has touched — whoever the individual rows belong to — so an
--      invalidating row can never be skipped because of its own identity shape. A subscription
--      contributes evidence only when its latest lifecycle row (a) belongs to this participant and
--      is unambiguous (see 3), (b) is `processed`, (c) is INITIAL_PURCHASE, RENEWAL, UNCANCELLATION,
--      or a CANCELLATION whose cancel_reason is NOT 'CUSTOMER_SUPPORT' (auto-renew turned off:
--      access continues until expiration), (d) names a shipping product and (e) has an unexpired
--      expiration_at_ms. A latest EXPIRATION, or a latest CUSTOMER_SUPPORT CANCELLATION (a
--      support-issued refund — exactly the signal isReferralRefundReversalEvent treats as a refund),
--      invalidates that subscription entirely, whatever expiration its earlier rows advertised. A
--      latest row that is not `processed`, or that belongs to someone else, or that is ambiguous,
--      contributes nothing (fail closed until the next processed event).
--      UNKNOWN STATE: two kinds of row owned by the participant carry no subscription identity and
--      are treated as "something changed that this history cannot attribute": a lifecycle row
--      whose original_transaction_id cannot be read (absent, or a nulled raw_payload), and a
--      TRANSFER row whose payload transferred_from[] names one of the participant's identities
--      (RevenueCat moved that user's subscriptions to another App User ID). Any subscription whose
--      latest row is not strictly newer than the newest such row contributes nothing. Every other
--      event type (PRODUCT_CHANGE, BILLING_ISSUE, TEST, REFUND_REVERSED, a TRANSFER the participant
--      is not the source of, ...) is neither evidence nor invalidation — unchanged from
--      20260929230218, which ignored them as well; a product change therefore keeps resolving the
--      product RevenueCat last recorded a purchase/renewal for.
--      Retention precondition: this fallback reads original_transaction_id, product_id,
--      expiration_at_ms, cancel_reason and aliases[] from raw_payload. If a raw_payload retention
--      job is ever introduced (the ledger's own column comment anticipates one), those fields must
--      first be persisted in normalized columns, otherwise a nulled invalidating row that was
--      attributable only through aliases[] becomes invisible to this reduction.
--
--   3. IDENTITY — an event belongs to the claiming participant when ANY of its identities (the
--      ledger's app_user_id, its original_app_user_id, or the payload's event.aliases[], compared
--      after ASCII-space trimming with btrim, the same normalization the alias table stores) is one
--      of that participant's own private.referral_participant_aliases rows in the SAME environment
--      as the claim. A row whose identities ALSO map to a different participant in that environment
--      has ambiguous ownership and never yields evidence — the same zero/one/many fail-closed rule
--      process_referral_subscription_event applies to its alias set. Cross-environment aliases never
--      match (alias rows and events are both bound to p_environment). Note: the webhook parser's
--      JavaScript trim() also strips non-ASCII whitespace; an identity padded that way is simply not
--      recognised here (never a grant to someone else — the row would still be judged only against
--      the identities that do normalize).
--
-- UNCHANGED: the three-product allowlist, unexpired evidence only, greatest expiration wins ACROSS
-- subscriptions, a tie at the greatest expiration across distinct products fails closed (NULL is
-- passed to the core), the fresh RevenueCat lookup remains the only source of "Pro is active".
-- Also hardened in passing: expiration_at_ms must be 1-15 digits and is compared numerically (never
-- through to_timestamp), so a malformed or absurdly large value fails closed instead of raising or
-- reading as far-future evidence.
--
-- COST: two passes over this environment's lifecycle rows (one cheap identity pre-filter, one
-- subscription-id filter); the per-row identity-set aggregation runs only for the winning rows.
-- Linear in ledger size; adequate for the current ledger, and a follow-up may add expression
-- indexes on original_app_user_id / the payload aliases without changing this function.
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
  v_now_ms constant numeric := extract(epoch from now()) * 1000;
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
    select array_agg(btrim(a.app_user_id))
      into v_participant_aliases
    from private.referral_participant_aliases a
    where a.participant_id = p_referrer_participant_id
      and a.environment = p_environment;

    if v_participant_aliases is not null then
      with owned_rows as (
        -- Pass 1 (cheap): rows carrying one of the participant's identities — lifecycle rows via
        -- app_user_id / original_app_user_id / payload aliases[], TRANSFER rows via payload
        -- transferred_from[]. Only the subscription identity (or its absence) is kept here.
        select
          e.event_timestamp,
          e.received_at,
          case
            when e.event_type = 'TRANSFER' then null
            else nullif(btrim(e.raw_payload #>> '{event,original_transaction_id}'), '')
          end as original_transaction_id
        from private.revenuecat_webhook_events e
        where e.environment = p_environment
          and (
            (
              e.event_type in ('INITIAL_PURCHASE', 'RENEWAL', 'CANCELLATION', 'UNCANCELLATION', 'EXPIRATION')
              and (
                btrim(e.app_user_id) = any(v_participant_aliases)
                or btrim(e.original_app_user_id) = any(v_participant_aliases)
                or exists (
                  select 1
                  from jsonb_array_elements(
                    case when jsonb_typeof(e.raw_payload #> '{event,aliases}') = 'array'
                         then e.raw_payload #> '{event,aliases}'
                         else '[]'::jsonb
                    end
                  ) as x
                  where jsonb_typeof(x.value) = 'string'
                    and btrim(x.value #>> '{}') = any(v_participant_aliases)
                )
              )
            )
            or (
              e.event_type = 'TRANSFER'
              and exists (
                select 1
                from jsonb_array_elements(
                  case when jsonb_typeof(e.raw_payload #> '{event,transferred_from}') = 'array'
                       then e.raw_payload #> '{event,transferred_from}'
                       else '[]'::jsonb
                  end
                ) as x
                where jsonb_typeof(x.value) = 'string'
                  and btrim(x.value #>> '{}') = any(v_participant_aliases)
              )
            )
          )
      ),
      -- Subscriptions this participant has touched at least once.
      touched as (
        select distinct o.original_transaction_id
        from owned_rows o
        where o.original_transaction_id is not null
      ),
      -- The newest owned row in UNKNOWN state (unreadable subscription identity, or a transfer away).
      unknown_newest as (
        select o.event_timestamp, o.received_at
        from owned_rows o
        where o.original_transaction_id is null
        order by o.event_timestamp desc, o.received_at desc
        limit 1
      ),
      -- Pass 2: EVERY lifecycle row of a touched subscription, whoever it belongs to.
      lifecycle as (
        select
          e.event_id,
          e.event_type,
          e.event_timestamp,
          e.received_at,
          e.processing_status,
          e.app_user_id,
          e.original_app_user_id,
          e.raw_payload,
          k.original_transaction_id,
          case
            when e.event_type = 'EXPIRATION' then true
            when e.event_type = 'CANCELLATION'
             and btrim(e.raw_payload #>> '{event,cancel_reason}') = 'CUSTOMER_SUPPORT' then true
            else false
          end as invalidating
        from private.revenuecat_webhook_events e
        cross join lateral (
          select nullif(btrim(e.raw_payload #>> '{event,original_transaction_id}'), '') as original_transaction_id
        ) as k
        where e.environment = p_environment
          and e.event_type in ('INITIAL_PURCHASE', 'RENEWAL', 'CANCELLATION', 'UNCANCELLATION', 'EXPIRATION')
          and k.original_transaction_id in (select t.original_transaction_id from touched t)
      ),
      -- (2) The most recent lifecycle row per touched subscription is its current state.
      latest as (
        select distinct on (l.original_transaction_id) l.*
        from lifecycle l
        order by
          l.original_transaction_id,
          l.event_timestamp desc,
          case when l.invalidating then 0 else 1 end,
          l.received_at desc,
          l.event_id desc
      ),
      -- Ownership and ambiguity are judged on the winning row only (identity set built here, for
      -- these few rows, exactly as pass 1 matched them).
      latest_identified as (
        select
          l.*,
          ids.identity_set
        from latest l
        cross join lateral (
          select array_agg(distinct btrim(i.identity)) as identity_set
          from (
            select l.app_user_id as identity
            union all
            select l.original_app_user_id
            union all
            select x.value #>> '{}'
            from jsonb_array_elements(
              case when jsonb_typeof(l.raw_payload #> '{event,aliases}') = 'array'
                   then l.raw_payload #> '{event,aliases}'
                   else '[]'::jsonb
              end
            ) as x
            where jsonb_typeof(x.value) = 'string'
          ) as i
          where nullif(btrim(i.identity), '') is not null
        ) as ids
      ),
      evidence as (
        select
          l.raw_payload #>> '{event,product_id}' as evidence_product_id,
          -- Epoch milliseconds are 13 digits today (14 from the year 2286); anything wider is
          -- malformed and must fail closed rather than read as "far future" evidence.
          case when btrim(l.raw_payload #>> '{event,expiration_at_ms}') ~ '^[0-9]{1,15}$'
               then (btrim(l.raw_payload #>> '{event,expiration_at_ms}'))::numeric
          end as evidence_expiration_at_ms
        from latest_identified l
        where l.identity_set && v_participant_aliases
          and not exists (
            select 1
            from private.referral_participant_aliases o
            where o.environment = p_environment
              and o.participant_id <> p_referrer_participant_id
              and btrim(o.app_user_id) = any(l.identity_set)
          )
          and not exists (
            select 1
            from unknown_newest u
            where (u.event_timestamp, u.received_at) >= (l.event_timestamp, l.received_at)
          )
          and l.processing_status = 'processed'
          and not l.invalidating
          and l.event_type in ('INITIAL_PURCHASE', 'RENEWAL', 'CANCELLATION', 'UNCANCELLATION')
          and (l.raw_payload #>> '{event,product_id}') = any(v_supported_products)
      ),
      live_evidence as (
        select ev.evidence_product_id, ev.evidence_expiration_at_ms
        from evidence ev
        where ev.evidence_expiration_at_ms is not null
          and ev.evidence_expiration_at_ms > v_now_ms
      ),
      max_evidence as (
        select max(le.evidence_expiration_at_ms) as max_expiration_at_ms from live_evidence le
      ),
      top_products as (
        select distinct le.evidence_product_id
        from live_evidence le
        join max_evidence mx on mx.max_expiration_at_ms = le.evidence_expiration_at_ms
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
  'refund/expiration, transfer-away, unreadable identity, ambiguous ownership, unsupported products or '
  'cross-product ties. See 20260930090000_referral_reward_active_product_fallback_hardening.sql.';

revoke all on function private.claim_referral_reward(uuid, text, boolean, text, text) from public, anon, authenticated;
grant execute on function private.claim_referral_reward(uuid, text, boolean, text, text) to postgres, service_role;

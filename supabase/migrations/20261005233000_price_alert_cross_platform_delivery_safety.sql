-- 85Blends 2.4.1 — Price Alerts: port the delivery-safety hardening to the cross-platform claim path.
--
-- NOT APPLIED TO PRODUCTION. Applying it is a separate, explicitly authorized step (see
-- supabase/functions/PRICE_ALERTS_SCHEDULER.md, "Cross-platform deployment plan").
--
-- WHY THIS EXISTS
--   Production already contains migration 20261005211547_price_alerts_cross_platform_push, which
--   added Android/FCM support and private.claim_price_alert_deliveries_v2(p_limit, p_platform).
--   The live price-alerts-worker (v4) no longer calls private.claim_price_alert_deliveries(integer);
--   it calls the v2 function once per platform ('ios', then 'android'). The delivery-safety
--   behavior designed and reviewed in 20261005120000_price_alert_worker_scheduler_and_freshness
--   (PR #120) was written against the v1 function, so on its own it would NOT protect the path
--   the worker really uses. This migration ports it to v2 and keeps v1 from drifting again.
--
-- ORDER (strictly after both): 20261005120000, then 20261005211547, then this file. Production
--   already has 20261005211547; 20261005120000 is still pending there and must be applied before
--   this migration (the preconditions below enforce it).
--
-- WHAT CHANGES (all CREATE OR REPLACE: idempotent, safe to re-run, no schema/data change)
--   1. private.claim_price_alert_deliveries_v2(integer, text): same signature, same return shape
--      (including `platform`), same ACL as production (postgres only), plus:
--        * 2-hour report freshness: a delivery whose report `reported_at` is older than 2 hours is
--          never claimed, by the claim predicate itself (independent of the sweep);
--        * a bounded expiry sweep (<= 500 rows per call, FOR UPDATE ... SKIP LOCKED) that marks such
--          deliveries `skipped` / `stale_report`, and deliveries whose device is disabled or
--          invalidated `skipped` / `device_unusable` (stale wins when both apply), then finalizes the
--          owning job (job row taken with SKIP LOCKED);
--        * the sweep and the claim are both restricted to the requested platform, so an 'ios' call
--          never changes or returns Android rows and vice versa;
--        * retries are unchanged: `failed` rows are re-claimed when due, `processing` rows after the
--          15-minute lock lapse, up to the worker's 5-attempt cap.
--   2. private.claim_price_alert_deliveries(integer) (v1, kept for compatibility, same signature,
--      same return shape, same ACL) becomes a thin wrapper over v2(p_limit, 'ios'). Before this it
--      was platform-blind: after the cross-platform migration it could claim Android deliveries and
--      hand a null apns_environment to an APNs-only caller. Single source of truth: the safety logic
--      lives only in v2.
--
-- NOT CHANGED: the scheduler (private.invoke_price_alerts_worker and the INACTIVE
--   85blends-price-alerts-worker-invoke cron job from 20261005120000 are neither touched nor
--   activated here), authentication, claim_price_alert_jobs, the index, tables, grants on any other
--   object.

do $precondition$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'private' and table_name = 'price_alert_installations' and column_name = 'client_platform'
  ) then
    raise exception 'requires migration 20261005211547_price_alerts_cross_platform_push (client_platform missing)';
  end if;

  if to_regprocedure('private.claim_price_alert_deliveries_v2(integer,text)') is null then
    raise exception 'requires migration 20261005211547_price_alerts_cross_platform_push (claim v2 missing)';
  end if;

  if to_regprocedure('private.invoke_price_alerts_worker()') is null
     or to_regclass('private.price_alert_jobs_stuck_processing_idx') is null then
    raise exception 'requires migration 20261005120000_price_alert_worker_scheduler_and_freshness (apply it first)';
  end if;
end
$precondition$;

-- ------------------------------------------------------------------------------------------------
-- 1. Cross-platform claim with the PR #120 safeguards
-- ------------------------------------------------------------------------------------------------

create or replace function private.claim_price_alert_deliveries_v2(
  p_limit integer default 50,
  p_platform text default 'ios'
)
returns table(
  delivery_id uuid,
  alert_id uuid,
  price_report_id uuid,
  push_device_id uuid,
  platform text,
  station_id uuid,
  station_name text,
  device_token text,
  apns_environment text,
  bundle_id text,
  observed_price numeric,
  previous_price numeric,
  reason_code text,
  attempt_count integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_freshness constant interval := interval '2 hours';
  v_expire_batch constant integer := 500;
  v_expired_report_id uuid;
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'p_limit must be between 1 and 100';
  end if;

  if p_platform is null or p_platform not in ('ios','android') then
    raise exception 'p_platform must be ios or android';
  end if;

  -- (a) Bounded sweep for THIS platform only. `skipped` is terminal, so the owning job can
  -- finalize. A row another session holds locked is skipped, not waited for, and is picked up by a
  -- later call. A fresh-locked in-flight send is never touched: only `processing` rows whose
  -- 15-minute lock has lapsed are eligible. Stale wins over unusable-device.
  for v_expired_report_id in
    with doomed as (
      select d.id,
             case when r.reported_at < now() - v_freshness
                  then 'stale_report' else 'device_unusable' end as reason
      from private.price_alert_deliveries d
      join public.e85_price_reports r on r.id = d.price_report_id
      join private.price_alert_push_devices pd on pd.id = d.push_device_id
      where pd.platform = p_platform
        and (
              d.status in ('pending', 'failed')
              or (d.status = 'processing' and d.locked_at < now() - interval '15 minutes')
            )
        and (
              r.reported_at < now() - v_freshness
              or not pd.enabled
              or pd.invalidated_at is not null
            )
      limit v_expire_batch
      for update of d skip locked
    ), expired as (
      update private.price_alert_deliveries d
      set status = 'skipped',
          last_error_code = doomed.reason,
          locked_at = null
      from doomed
      where d.id = doomed.id
      returning d.price_report_id
    )
    select distinct e.price_report_id from expired e
  loop
    -- Take the job row without waiting; finalize_price_alert_job then re-locks it in this same
    -- transaction. A job locked elsewhere is left for its holder or the stale-job reclaim.
    perform 1
    from private.price_alert_jobs j
    where j.price_report_id = v_expired_report_id
    for update skip locked;

    if found then
      perform private.finalize_price_alert_job(v_expired_report_id);
    end if;
  end loop;

  -- (b) Claim. Independently excludes stale reports and unusable devices, and is platform-scoped.
  return query
  with candidates as (
    select d.id
    from private.price_alert_deliveries d
    join public.e85_price_reports fr on fr.id = d.price_report_id
    join private.price_alert_push_devices fd on fd.id = d.push_device_id
    where fd.platform = p_platform
      and fr.reported_at >= now() - v_freshness
      and fd.enabled
      and fd.invalidated_at is null
      and (
        (
          d.status in ('pending','failed')
          and d.available_at <= now()
        ) or (
          d.status = 'processing'
          and d.locked_at < now() - interval '15 minutes'
        )
      )
    order by d.available_at asc, d.created_at asc
    for update of d skip locked
    limit p_limit
  ), claimed as (
    update private.price_alert_deliveries d
    set status = 'processing',
        attempt_count = d.attempt_count + 1,
        attempted_at = now(),
        locked_at = now(),
        last_error_code = null
    from candidates c
    where d.id = c.id
    returning d.*
  )
  select
    c.id,
    c.alert_id,
    c.price_report_id,
    c.push_device_id,
    pd.platform,
    r.station_id,
    s.name,
    pd.device_token,
    pd.apns_environment,
    pd.bundle_id,
    c.observed_price,
    c.previous_price,
    c.reason_code,
    c.attempt_count
  from claimed c
  join private.price_alert_push_devices pd on pd.id = c.push_device_id
  join public.e85_price_reports r on r.id = c.price_report_id
  join public.community_stations s on s.id = r.station_id
  where pd.enabled = true
    and pd.invalidated_at is null
    and pd.platform = p_platform;
end;
$$;

-- Same ACL as production for v2 (owner postgres only; the worker connects as postgres).
revoke all on function private.claim_price_alert_deliveries_v2(integer,text) from public;
revoke all on function private.claim_price_alert_deliveries_v2(integer,text) from anon;
revoke all on function private.claim_price_alert_deliveries_v2(integer,text) from authenticated;
grant execute on function private.claim_price_alert_deliveries_v2(integer,text) to postgres;

-- ------------------------------------------------------------------------------------------------
-- 2. v1 becomes an iOS-only wrapper over v2 (same signature, return shape and ACL)
-- ------------------------------------------------------------------------------------------------

create or replace function private.claim_price_alert_deliveries(p_limit integer default 50)
returns table(
  delivery_id uuid,
  alert_id uuid,
  price_report_id uuid,
  push_device_id uuid,
  station_id uuid,
  station_name text,
  device_token text,
  apns_environment text,
  bundle_id text,
  observed_price numeric,
  previous_price numeric,
  reason_code text,
  attempt_count integer
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  select v.delivery_id, v.alert_id, v.price_report_id, v.push_device_id,
         v.station_id, v.station_name, v.device_token, v.apns_environment, v.bundle_id,
         v.observed_price, v.previous_price, v.reason_code, v.attempt_count
  from private.claim_price_alert_deliveries_v2(p_limit, 'ios') v;
end;
$$;

revoke execute on function private.claim_price_alert_deliveries(integer) from public, anon, authenticated;
grant execute on function private.claim_price_alert_deliveries(integer) to postgres, service_role;

-- 85Blends 2.4.1 — Price Alerts backend readiness: worker scheduler + stale-work safety.
--
-- NOT APPLIED TO PRODUCTION. This file only prepares the change; applying it is a separate,
-- explicitly authorized step (see supabase/functions/PRICE_ALERTS_SCHEDULER.md for the exact
-- order: provision secrets -> deploy the worker -> apply this migration -> verify -> activate).
--
-- Why this exists (verified read-only against the live project on 2026-10-05):
--   * `price-alerts-worker` (the only code that talks to APNs) has never been invoked: no cron job,
--     function, trigger, webhook or platform scheduler calls it. The existing every-minute job
--     (`85blends-price-alert-job-prepare`) only runs private.process_price_alert_jobs(50), which
--     prepares delivery rows and never sends anything.
--   * private.claim_price_alert_jobs had no stale-`processing` recovery (deliveries already
--     reclaim after 15 minutes).
--   * Nothing stopped an old queued delivery from being sent long after the report it describes.
--
-- Three independent changes, all idempotent (safe to re-run):
--   1. private.invoke_price_alerts_worker(): the pg_net/Vault caller, modeled on
--      private.invoke_app_store_growth_sync(). Reads Vault secret NAMES only; no value lives here.
--   2. cron job `85blends-price-alerts-worker-invoke`, every minute, created INACTIVE and only if
--      absent, so applying this migration changes no runtime behavior until it is deliberately
--      activated after the worker has been deployed with its new secret.
--   3. private.claim_price_alert_jobs / private.claim_price_alert_deliveries: stale-job recovery
--      and a report-freshness guard. Signatures, return shapes, ownership and grants are
--      unchanged (CREATE OR REPLACE), so the worker and the existing cron job keep working as-is.
--
-- Thresholds (chosen from the current architecture, see the runbook for the reasoning):
--   * Stuck `processing` jobs are reclaimed after 15 minutes (same as deliveries), at most while
--     attempt_count < 5 (the worker/cron already use 5 as the dead-letter limit), and ONLY when the
--     job has no pending/processing/failed deliveries. finalize_price_alert_job deliberately keeps
--     a job in `processing` while any of its deliveries is still waiting or retrying (about 81
--     minutes at most: retry delays 1m/5m/15m/1h, and with the worker's 5-attempt cap the 4h step
--     is never reached), so lock age alone must never trigger a reclaim.
--   * A delivery is only sent while its report's `reported_at` is within 2 hours (comfortably
--     longer than that ~81-minute retry horizon, so no legitimate retry is cut off). Anything older
--     is marked `skipped` (last_error_code = 'stale_report'), which is terminal and lets the job
--     finalize. `reported_at` is the observation time (it can be back-dated up to 7 days by a
--     reporter, never more than 10 minutes into the future), so it also stops a back-dated report
--     from producing an alert that claims to be current.

-- ------------------------------------------------------------------------------------------------
-- 1. Worker invoker (pg_net + Vault). Secret NAMES only.
--    Vault secrets read:  project_url (already present, shared with the App Store sync job) and
--                         price_alerts_worker_cron_token (new; must be provisioned out-of-band and
--                         must equal the worker's PRICE_ALERTS_WORKER_CRON_SECRET).
-- ------------------------------------------------------------------------------------------------

create or replace function private.invoke_price_alerts_worker()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project_url text;
  v_cron_token text;
  v_request_id bigint;
begin
  select decrypted_secret
    into v_project_url
  from vault.decrypted_secrets
  where name = 'project_url'
  limit 1;

  select decrypted_secret
    into v_cron_token
  from vault.decrypted_secrets
  where name = 'price_alerts_worker_cron_token'
  limit 1;

  -- Observable failure: this raises inside the cron job, which pg_cron records as `failed` in
  -- cron.job_run_details, rather than silently sending nothing. The length floor mirrors the
  -- worker's own minimum so a weak/placeholder token is rejected here too.
  if v_project_url is null or length(btrim(v_project_url)) = 0
     or v_cron_token is null or length(v_cron_token) < 32 then
    raise exception 'price_alerts_worker_scheduler_not_configured';
  end if;

  -- POST only. job_limit / delivery_limit are the worker's own defaults, spelled out so the
  -- throughput ceiling (50 deliveries per run, one run per minute) is visible in one place.
  select net.http_post(
    url := rtrim(v_project_url, '/') || '/functions/v1/price-alerts-worker',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-85blends-cron-secret', v_cron_token
    ),
    body := jsonb_build_object('job_limit', 20, 'delivery_limit', 50),
    timeout_milliseconds := 30000
  ) into v_request_id;

  return v_request_id;
end;
$$;

revoke execute on function private.invoke_price_alerts_worker() from public, anon, authenticated;
grant execute on function private.invoke_price_alerts_worker() to postgres;

comment on function private.invoke_price_alerts_worker() is
  '85Blends 2.4.1 pg_net caller for the price-alerts-worker Edge Function. Reads Vault secrets project_url and price_alerts_worker_cron_token by name; raises price_alerts_worker_scheduler_not_configured when either is missing. Returns the pg_net request id.';

-- ------------------------------------------------------------------------------------------------
-- 2. Cron schedule: created once, INACTIVE. Never re-created (so a re-run cannot re-activate a job
--    that an operator deliberately paused, nor duplicate it). Activation is a separate manual step:
--      select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke'), active := true);
-- ------------------------------------------------------------------------------------------------

do $schedule$
begin
  if not exists (
    select 1 from cron.job where jobname = '85blends-price-alerts-worker-invoke'
  ) then
    perform cron.schedule(
      '85blends-price-alerts-worker-invoke',
      '* * * * *',
      $cron$select private.invoke_price_alerts_worker();$cron$
    );
    perform cron.alter_job(
      (select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke'),
      active := false
    );
  end if;
end;
$schedule$;

-- ------------------------------------------------------------------------------------------------
-- 3a. Stale-job recovery. Same body as the live definition plus one reclaim branch.
-- ------------------------------------------------------------------------------------------------

create or replace function private.claim_price_alert_jobs(p_limit integer default 20)
returns table(job_id uuid, price_report_id uuid, attempt_count integer)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'p_limit must be between 1 and 100';
  end if;

  return query
  with candidates as (
    select j.id
    from private.price_alert_jobs j
    where (
      j.status in ('pending', 'failed')
      and j.available_at <= now()
    ) or (
      -- Stuck-job recovery. Only a job that is NOT legitimately waiting on its deliveries:
      -- finalize_price_alert_job keeps a job in 'processing' while any delivery is pending,
      -- processing or failed (retrying), so those jobs must never be reclaimed here.
      j.status = 'processing'
      and j.locked_at < now() - interval '15 minutes'
      and j.attempt_count < 5
      and not exists (
        select 1
        from private.price_alert_deliveries d
        where d.price_report_id = j.price_report_id
          and d.status in ('pending', 'processing', 'failed')
      )
    )
    order by j.available_at asc, j.created_at asc
    for update skip locked
    limit p_limit
  )
  update private.price_alert_jobs j
  set status = 'processing',
      attempt_count = j.attempt_count + 1,
      locked_at = now(),
      last_error = null
  from candidates c
  where j.id = c.id
  returning j.id, j.price_report_id, j.attempt_count;
end;
$$;

-- ------------------------------------------------------------------------------------------------
-- 3b. Freshness guard + stale expiry for deliveries. Same payload and claim semantics as the live
--     definition (20260918001525); it additionally (a) expires deliveries whose report is older
--     than the freshness window and finalizes their jobs, and (b) never claims one.
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
declare
  v_freshness constant interval := interval '2 hours';
  v_expired_report_id uuid;
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'p_limit must be between 1 and 100';
  end if;

  -- Expire anything that is no longer worth sending (after a scheduler/APNs outage, or a retry
  -- that landed past the window). `skipped` is terminal, so the owning job can finalize. A row
  -- another worker is actively sending (fresh `processing` lock) is never touched.
  for v_expired_report_id in
    with expired as (
      update private.price_alert_deliveries d
      set status = 'skipped',
          last_error_code = 'stale_report',
          locked_at = null
      from public.e85_price_reports r
      where r.id = d.price_report_id
        and r.reported_at < now() - v_freshness
        and (
          d.status in ('pending', 'failed')
          or (d.status = 'processing' and d.locked_at < now() - interval '15 minutes')
        )
      returning d.price_report_id
    )
    select distinct e.price_report_id from expired e
  loop
    perform private.finalize_price_alert_job(v_expired_report_id);
  end loop;

  return query
  with candidates as (
    select d.id
    from private.price_alert_deliveries d
    join public.e85_price_reports fr on fr.id = d.price_report_id
    where fr.reported_at >= now() - v_freshness
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
  where pd.enabled = true and pd.invalidated_at is null;
end;
$$;

-- CREATE OR REPLACE keeps the existing owner, ACL and comments; re-assert the ACL anyway so this
-- migration is self-describing and the grants cannot silently drift.
revoke execute on function private.claim_price_alert_jobs(integer) from public, anon, authenticated;
grant execute on function private.claim_price_alert_jobs(integer) to postgres;

revoke execute on function private.claim_price_alert_deliveries(integer) from public, anon, authenticated;
grant execute on function private.claim_price_alert_deliveries(integer) to postgres, service_role;

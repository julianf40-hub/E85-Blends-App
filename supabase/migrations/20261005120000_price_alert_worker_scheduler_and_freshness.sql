-- 85Blends 2.4.1 — Price Alerts backend readiness: worker scheduler + stale-work safety.
--
-- NOT APPLIED TO PRODUCTION. This file only prepares the change; applying it is a separate,
-- explicitly authorized step (see supabase/functions/PRICE_ALERTS_SCHEDULER.md for the exact
-- order: provision secrets -> deploy the worker -> apply this migration -> verify -> activate).
--
-- WHAT TAKES EFFECT WHEN THIS MIGRATION IS APPLIED (read this before applying):
--   * INACTIVE until deliberately activated: only the NEW worker-invocation cron job
--     (`85blends-price-alerts-worker-invoke`) is created inactive. Nothing calls the worker until
--     an operator activates it.
--   * IMMEDIATE: everything else is live the moment the migration runs. In particular
--     private.claim_price_alert_jobs is called every minute by the ALREADY ACTIVE job-preparation
--     cron (`85blends-price-alert-job-prepare`, via private.process_price_alert_jobs), so the
--     stale-job reclaim and the new index take effect on that existing job immediately.
--     private.claim_price_alert_deliveries only runs when the worker runs, so its changes take
--     effect when the worker is first invoked.
--
-- Why this exists (verified read-only against the live project on 2026-10-05):
--   * `price-alerts-worker` (the only code that talks to APNs) has never been invoked: no cron job,
--     function, trigger, webhook or platform scheduler calls it. The existing every-minute job only
--     runs private.process_price_alert_jobs(50), which prepares delivery rows and never sends.
--   * private.claim_price_alert_jobs had no stale-`processing` recovery (deliveries already
--     reclaim after 15 minutes).
--   * Nothing stopped an old queued delivery from being sent long after the report it describes,
--     and a delivery for a device that was disabled after it was prepared was "claimed" every 15
--     minutes without ever being handed to the worker (attempt_count inflating, parent job stuck).
--
-- Changes, all idempotent (safe to re-run):
--   1. private.invoke_price_alerts_worker(): the pg_net/Vault caller, modeled on
--      private.invoke_app_store_growth_sync(). Reads Vault secret NAMES only; no value lives here.
--      It validates its configuration before sending anything (HTTPS origin only, trimmed
--      header-safe token) and raises fixed, value-free error messages.
--   2. cron job `85blends-price-alerts-worker-invoke`, every minute, created INACTIVE and only if
--      absent, so a re-run never duplicates it and never changes an operator's active/inactive choice.
--   3. Partial index price_alert_jobs_stuck_processing_idx so the stale-job branch of the claim
--      does not turn the every-minute claim into a sequential scan of the whole jobs table.
--   4. private.claim_price_alert_jobs: stale-job recovery.
--   5. private.claim_price_alert_deliveries: a bounded, non-blocking sweep that expires deliveries
--      that are stale or addressed to an unusable device, and a claim predicate that independently
--      excludes both. Signatures, return shapes, ownership and grants are unchanged (CREATE OR
--      REPLACE).
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
--   * A delivery whose push device is disabled or invalidated can never be sent. It is marked
--     `skipped` with last_error_code = 'device_unusable': terminal, never retried, never counted as
--     sent, no APNs verdict implied (so it is not `invalid_device`), and the job can finalize.
--   * The expiry sweep handles at most 500 deliveries per claim call and locks rows with
--     FOR UPDATE SKIP LOCKED, so one call is a short transaction, never waits behind a row (or a
--     job) another session holds, and a large backlog drains incrementally over successive calls.
--     The claim predicate excludes stale and unusable-device rows on its own, so a partially
--     drained backlog can never result in a stale or undeliverable send. No lock_timeout is set:
--     every lock this function takes is SKIP LOCKED, so there is no remaining wait for a timeout
--     to bound, and a timeout error would only roll back otherwise-good work.

-- ------------------------------------------------------------------------------------------------
-- 1. Worker invoker (pg_net + Vault). Secret NAMES only.
--    Vault secrets read:  project_url (already present, shared with the App Store sync job) and
--                         price_alerts_worker_cron_token (new; must be provisioned out-of-band and
--                         must equal the worker's PRICE_ALERTS_WORKER_CRON_SECRET).
--    TRUST ASSUMPTION: Vault content is operator-controlled infrastructure configuration (only
--    postgres/service_role/admin roles can read or write it). It is nevertheless validated, because
--    a typo or a bad copy/paste must not make this function send the scheduler secret to a cleartext
--    or unintended endpoint.
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

  -- The token is trimmed (surrounding whitespace incl. the newline that copy/paste adds) and ONLY
  -- the trimmed value is ever used. The URL is deliberately NOT trimmed: a padded URL is rejected.
  v_cron_token := regexp_replace(coalesce(v_cron_token, ''), '^[[:space:]]+|[[:space:]]+$', '', 'g');

  -- Observable failures: each raises inside the cron job, which pg_cron records as `failed` in
  -- cron.job_run_details, rather than silently sending nothing. Messages are fixed strings and
  -- never contain a configured value.
  if v_project_url is null or v_project_url = '' or v_cron_token = '' then
    raise exception 'price_alerts_worker_scheduler_not_configured';
  end if;

  -- A simple HTTPS origin only: no other scheme, no userinfo, port, path, query, fragment or
  -- whitespace. (Stricter than ^https://[^/?#[:space:]]+/?$, which would still admit user@host
  -- and host:port forms.) At most one trailing slash is allowed.
  if v_project_url !~ '^https://[A-Za-z0-9][A-Za-z0-9.-]*/?$' then
    raise exception 'price_alerts_worker_scheduler_invalid_project_url';
  end if;

  -- Printable, non-space ASCII only (header-safe: no CR/LF/space), at least the worker's own
  -- 32-character minimum so a weak/placeholder value is rejected on both sides.
  if v_cron_token !~ '^[!-~]{32,}$' then
    raise exception 'price_alerts_worker_scheduler_invalid_token';
  end if;

  -- POST only. job_limit / delivery_limit are the worker's own defaults, spelled out so the
  -- throughput ceiling (50 deliveries per run, one run per minute) is visible in one place.
  select net.http_post(
    url := regexp_replace(v_project_url, '/$', '') || '/functions/v1/price-alerts-worker',
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
  '85Blends 2.4.1 pg_net caller for the price-alerts-worker Edge Function. Reads Vault secrets project_url and price_alerts_worker_cron_token by name; validates an HTTPS-origin project_url and a trimmed header-safe token of at least 32 characters; raises fixed value-free errors price_alerts_worker_scheduler_not_configured / _invalid_project_url / _invalid_token. Returns the pg_net request id.';

-- ------------------------------------------------------------------------------------------------
-- 2. Cron schedule: created once, INACTIVE. Never re-created (so a re-run cannot re-activate a job
--    that an operator deliberately paused, nor duplicate it, nor pause one an operator activated).
--    Activation is a separate manual step:
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
-- 3. Supporting index for the stale-job branch of claim_price_alert_jobs. Without it the OR in the
--    claim predicate defeats price_alert_jobs_ready_idx and every claim scans the whole jobs table
--    (measured: 0.2 ms -> 158 ms per call at 200k historical jobs; jobs are never pruned). Plain
--    CREATE INDEX (not CONCURRENTLY) is safe inside a migration: the table is tiny/empty.
-- ------------------------------------------------------------------------------------------------

create index if not exists price_alert_jobs_stuck_processing_idx
  on private.price_alert_jobs (locked_at)
  where status = 'processing';

-- ------------------------------------------------------------------------------------------------
-- 4. Stale-job recovery. Same body as the live definition plus one reclaim branch.
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
      -- Served by price_alert_jobs_stuck_processing_idx.
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
-- 5. Bounded, non-blocking expiry + independent claim exclusion for deliveries. Same payload and
--    claim semantics as the live definition (20260918001525), plus:
--      (a) a sweep of at most 500 rows per call (FOR UPDATE SKIP LOCKED) that marks deliveries
--          `skipped` when their report is older than the freshness window ('stale_report') or their
--          push device is disabled/invalidated ('device_unusable'), then finalizes their jobs;
--      (b) a claim predicate that excludes BOTH conditions on its own (it does not rely on the sweep
--          having reached a row), so a partially drained backlog can never produce a stale or
--          undeliverable send.
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
  v_expire_batch constant integer := 500;
  v_expired_report_id uuid;
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'p_limit must be between 1 and 100';
  end if;

  -- (a) Bounded sweep. `skipped` is terminal, so the owning job can finalize. A row another
  -- session holds locked (a worker mid-send, a manual transaction) is skipped, not waited for, and
  -- is picked up by a later call. A fresh-locked in-flight send is never touched: only `processing`
  -- rows whose 15-minute lock has lapsed are eligible.
  for v_expired_report_id in
    with doomed as (
      select d.id,
             case when r.reported_at < now() - v_freshness
                  then 'stale_report' else 'device_unusable' end as reason
      from private.price_alert_deliveries d
      join public.e85_price_reports r on r.id = d.price_report_id
      join private.price_alert_push_devices pd on pd.id = d.push_device_id
      where (
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
    -- transaction. A job that is locked elsewhere is left for its holder or, failing that, for the
    -- stale-job reclaim (processing, no non-terminal deliveries, 15 minutes).
    perform 1
    from private.price_alert_jobs j
    where j.price_report_id = v_expired_report_id
    for update skip locked;

    if found then
      perform private.finalize_price_alert_job(v_expired_report_id);
    end if;
  end loop;

  -- (b) Claim. Independently excludes stale reports and unusable devices.
  return query
  with candidates as (
    select d.id
    from private.price_alert_deliveries d
    join public.e85_price_reports fr on fr.id = d.price_report_id
    join private.price_alert_push_devices fd on fd.id = d.push_device_id
    where fr.reported_at >= now() - v_freshness
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

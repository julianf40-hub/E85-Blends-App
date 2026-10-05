-- 85Blends 2.4.1 — Price Alerts worker scheduler + stale-work safety regression matrix.
-- Covers supabase/migrations/20261005120000_price_alert_worker_scheduler_and_freshness.sql.
--
-- LOCAL-REPLAY ONLY (see README.md in this directory): run it from the repository root against a
-- scratch database that already has the full migration chain applied. It runs in ONE transaction
-- that is rolled back at the end and RAISEs on any unexpected outcome; reaching the final \echo
-- line is a full pass and leaves the database unchanged.
--
-- The scenarios that execute private.invoke_price_alerts_worker() only run when the scratch
-- database provides a recording stand-in for pg_net (a table net.sent_requests); on a database
-- with the real pg_net they are skipped, so this file can never send a real HTTP request.
--
-- WHAT THIS COVERS
--   W1-W5   invoker: not configured / weak token raise; configured call builds the exact URL,
--           POST headers (scheduler secret header, no Authorization), body and timeout; one request.
--   C1-C3   cron job: exactly one job, correct schedule/command, created INACTIVE; the pre-existing
--           job-prepare job is untouched and active; re-applying the migration neither duplicates
--           the job nor re-activates one an operator activated/paused.
--   J1-J7   claim_price_alert_jobs: pending claims still work; a stale `processing` job with no
--           deliveries and a stale job whose deliveries are all terminal are reclaimed; a job
--           still waiting on pending/processing/failed deliveries is NEVER reclaimed however old
--           its lock; a recently-locked job and a job at the attempt limit are not reclaimed.
--   F1-F9   claim_price_alert_deliveries: fresh pending/failed claimed with the unchanged payload;
--           stale reports (incl. exactly-around-the-window and back-dated) are expired to terminal
--           `skipped` / `stale_report`, never claimed, and their jobs finalize; a fresh-locked
--           in-flight send is untouched; a not-yet-due retry is untouched; idempotent re-claim.
--   B1      burst after downtime: many stale deliveries + a few fresh ones -> only the fresh ones
--           are returned and every stale one is expired.
--   G1      grants: none of the new/changed functions is executable by anon/authenticated.

begin;

-- Test helper -----------------------------------------------------------------------------------
create function pg_temp.expect(p_ok boolean, p_label text) returns void language plpgsql as $$
begin
  if p_ok is distinct from true then
    raise exception 'FAILED: %', p_label;
  end if;
end;
$$;

-- Fixtures --------------------------------------------------------------------------------------
-- Station A has an enabled alert (reports on it enqueue jobs through the real trigger); station N
-- has none (so the job scenarios insert their jobs by hand, one report each).
create temp table t_ids (k text primary key, v uuid);

insert into public.community_stations (name, normalized_key) values ('Readiness Test A', 'readiness-test-a');
insert into public.community_stations (name, normalized_key) values ('Readiness Test N', 'readiness-test-n');
insert into t_ids select 'station_a', id from public.community_stations where normalized_key = 'readiness-test-a';
insert into t_ids select 'station_n', id from public.community_stations where normalized_key = 'readiness-test-n';

insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active)
values ('$RCAnonymousID:readiness-test', 'SANDBOX', 'pro', true);

insert into private.price_alert_installations
  (client_installation_id, installation_secret_hash, revenuecat_app_user_id, revenuecat_environment, revenuecat_customer_id)
select gen_random_uuid(), repeat('a', 64), '$RCAnonymousID:readiness-test', 'SANDBOX', c.id
from private.revenuecat_customers c where c.original_app_user_id = '$RCAnonymousID:readiness-test';

insert into private.price_alert_push_devices
  (installation_id, bundle_id, apns_environment, device_token, device_token_hash)
select i.id, 'com.e85blends.app.ios.internal', 'sandbox', repeat('b', 64), repeat('c', 64)
from private.price_alert_installations i limit 1;

insert into private.price_alerts (installation_id, station_id)
select i.id, (select v from t_ids where k = 'station_a') from private.price_alert_installations i limit 1;

-- Report factory: returns the new report id. p_station key is 'station_a' or 'station_n'.
create function pg_temp.mk_report(p_station text, p_age interval, p_price numeric default 3.49)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id)
  values ((select v from t_ids where k = p_station), p_price, now() - p_age, 'readiness-reporter')
  returning id into v_id;
  return v_id;
end;
$$;

-- Delivery factory against the single fixture alert/device.
create function pg_temp.mk_delivery(p_report uuid, p_status text, p_available interval default interval '0',
                                    p_lock_age interval default null, p_attempts int default 0)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into private.price_alert_deliveries
    (alert_id, price_report_id, push_device_id, observed_price, status, available_at, locked_at, attempt_count, reason_code)
  select a.id, p_report, d.id, 3.49, p_status, now() + p_available,
         case when p_lock_age is null then null else now() - p_lock_age end, p_attempts, 'price_changed'
  from private.price_alerts a join private.price_alert_push_devices d on d.installation_id = a.installation_id
  limit 1
  returning id into v_id;
  return v_id;
end;
$$;

-- ==================================================================================================
-- W1-W5: invoker
-- ==================================================================================================
do $$
declare
  v_id bigint;
  v_row record;
  v_token constant text := 'readiness-fixture-token-0123456789abcdef';
begin
  if to_regclass('net.sent_requests') is null then
    raise notice 'W1-W5 skipped: real pg_net detected (no recording stand-in); never sending a real request';
    return;
  end if;

  -- W1: nothing in the vault -> observable failure
  begin
    perform private.invoke_price_alerts_worker();
    raise exception 'FAILED: W1 expected price_alerts_worker_scheduler_not_configured';
  exception when others then
    if sqlerrm <> 'price_alerts_worker_scheduler_not_configured' then raise; end if;
  end;

  -- W2: URL present, token missing -> still fails
  insert into vault.secrets (name, secret) values ('project_url', 'https://example.invalid/');
  begin
    perform private.invoke_price_alerts_worker();
    raise exception 'FAILED: W2 expected failure without a token';
  exception when others then
    if sqlerrm <> 'price_alerts_worker_scheduler_not_configured' then raise; end if;
  end;

  -- W3: weak (short) token is rejected on the database side too
  insert into vault.secrets (name, secret) values ('price_alerts_worker_cron_token', 'too-short');
  begin
    perform private.invoke_price_alerts_worker();
    raise exception 'FAILED: W3 expected failure for a short token';
  exception when others then
    if sqlerrm <> 'price_alerts_worker_scheduler_not_configured' then raise; end if;
  end;
  perform pg_temp.expect((select count(*) from net.sent_requests) = 0, 'W3 no request recorded for any failed attempt');

  -- W4: properly configured -> exactly one POST with the exact shape
  update vault.secrets set secret = v_token where name = 'price_alerts_worker_cron_token';
  v_id := private.invoke_price_alerts_worker();
  perform pg_temp.expect(v_id is not null, 'W4 returns the pg_net request id');
  select * into v_row from net.sent_requests where id = v_id;
  perform pg_temp.expect(v_row.url = 'https://example.invalid/functions/v1/price-alerts-worker',
                         'W4 URL is project_url (trailing slash trimmed) + /functions/v1/price-alerts-worker');
  perform pg_temp.expect(v_row.headers ->> 'x-85blends-cron-secret' = v_token, 'W4 sends the scheduler secret header');
  perform pg_temp.expect(v_row.headers ->> 'Content-Type' = 'application/json', 'W4 JSON content type');
  perform pg_temp.expect(not (v_row.headers ? 'Authorization') and not (v_row.headers ? 'authorization'),
                         'W4 sends no Authorization header (no service-role key involved)');
  perform pg_temp.expect(v_row.body = '{"job_limit": 20, "delivery_limit": 50}'::jsonb, 'W4 body');
  perform pg_temp.expect(v_row.timeout_milliseconds = 30000, 'W4 timeout');

  -- W5: repeated invocation is just another independent request (no state to corrupt)
  perform private.invoke_price_alerts_worker();
  perform pg_temp.expect((select count(*) from net.sent_requests) = 2, 'W5 repeated invocation records one request each');
end;
$$;

-- ==================================================================================================
-- C1-C3: cron job
-- ==================================================================================================
do $$
declare
  v_active_before boolean;
begin
  perform pg_temp.expect((select count(*) from cron.job where jobname = '85blends-price-alerts-worker-invoke') = 1,
                         'C1 exactly one worker-invoke job');
  perform pg_temp.expect((select schedule from cron.job where jobname = '85blends-price-alerts-worker-invoke') = '* * * * *',
                         'C1 every-minute schedule');
  perform pg_temp.expect((select command from cron.job where jobname = '85blends-price-alerts-worker-invoke')
                         = 'select private.invoke_price_alerts_worker();', 'C1 command');
  perform pg_temp.expect((select active from cron.job where jobname = '85blends-price-alerts-worker-invoke') = false,
                         'C2 created INACTIVE (nothing runs until deliberately activated)');
  perform pg_temp.expect((select count(*) from cron.job where jobname = '85blends-price-alert-job-prepare' and active) = 1,
                         'C2 the pre-existing job-prepare job is untouched and active');
  perform pg_temp.expect((select count(*) from cron.job) = 2, 'C2 no other cron jobs were created');

  -- C3: an operator activates it; re-applying the migration must neither duplicate nor reset it
  update cron.job set active = true where jobname = '85blends-price-alerts-worker-invoke';
end;
$$;

\ir ../migrations/20261005120000_price_alert_worker_scheduler_and_freshness.sql

do $$
begin
  perform pg_temp.expect((select count(*) from cron.job where jobname = '85blends-price-alerts-worker-invoke') = 1,
                         'C3 re-applying the migration does not duplicate the job');
  perform pg_temp.expect((select active from cron.job where jobname = '85blends-price-alerts-worker-invoke') = true,
                         'C3 re-applying the migration does not reset an operator-activated job');
  update cron.job set active = false where jobname = '85blends-price-alerts-worker-invoke';
end;
$$;

-- ==================================================================================================
-- J1-J7: stale-job recovery (station N has no alert, so no trigger-created jobs interfere)
-- ==================================================================================================
create temp table t_jobs (label text primary key, job_id uuid, report_id uuid, attempts_before int);

do $$
declare
  v_report uuid;
  v_job uuid;
  r record;
  v_label text;
begin
  -- label, status, lock age, attempts, delivery-status-to-attach
  for r in
    select * from (values
      ('J1_pending',          'pending',    null::interval,           0, null::text),
      ('J2_stale_nodeliv',    'processing', interval '20 minutes',    1, null),
      ('J3_stale_pendingdel', 'processing', interval '20 minutes',    1, 'pending'),
      ('J4_stale_faileddel',  'processing', interval '20 minutes',    2, 'failed'),
      ('J5_stale_procdel',    'processing', interval '20 minutes',    1, 'processing'),
      ('J6_stale_allterminal','processing', interval '20 minutes',    1, 'sent'),
      ('J7_recent_lock',      'processing', interval '5 minutes',     1, null),
      ('J8_attempt_limit',    'processing', interval '20 minutes',    5, null)
    ) as x(label, status, lock_age, attempts, del_status)
  loop
    v_report := pg_temp.mk_report('station_n', interval '10 minutes');
    insert into private.price_alert_jobs (price_report_id, status, attempt_count, locked_at)
    values (v_report, r.status, r.attempts, case when r.lock_age is null then null else now() - r.lock_age end)
    returning id into v_job;
    insert into t_jobs values (r.label, v_job, v_report, r.attempts);

    if r.del_status is not null then
      -- the delivery needs an alert on THIS report's station; reuse the fixture alert by pointing
      -- the delivery's report at the job's report (the FK only needs the report to exist).
      perform pg_temp.mk_delivery(v_report, r.del_status,
        case when r.del_status = 'failed' then interval '30 minutes' else interval '0' end,
        case when r.del_status = 'processing' then interval '1 minute' else null end,
        1);
    end if;
  end loop;
end;
$$;

do $$
declare
  v_claimed uuid[];
begin
  select array_agg(c.job_id) into v_claimed from private.claim_price_alert_jobs(100) c;

  perform pg_temp.expect((select job_id from t_jobs where label = 'J1_pending') = any (v_claimed),
                         'J1 a due pending job is still claimed');
  perform pg_temp.expect((select job_id from t_jobs where label = 'J2_stale_nodeliv') = any (v_claimed),
                         'J2 a stale processing job with no deliveries is reclaimed');
  perform pg_temp.expect((select job_id from t_jobs where label = 'J6_stale_allterminal') = any (v_claimed),
                         'J6 a stale processing job whose deliveries are all terminal is reclaimed (so it can finalize)');

  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J3_stale_pendingdel') = any (v_claimed)),
                         'J3 a job waiting on a PENDING delivery is never reclaimed');
  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J4_stale_faileddel') = any (v_claimed)),
                         'J4 a job waiting on a FAILED (retrying) delivery is never reclaimed');
  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J5_stale_procdel') = any (v_claimed)),
                         'J5 a job with a PROCESSING delivery is never reclaimed');
  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J7_recent_lock') = any (v_claimed)),
                         'J7 a job locked only 5 minutes ago is not stale yet');
  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J8_attempt_limit') = any (v_claimed)),
                         'J8 a stale job already at the attempt limit (5) is not reclaimed again');

  perform pg_temp.expect((select attempt_count from private.price_alert_jobs j join t_jobs t on t.job_id = j.id where t.label = 'J2_stale_nodeliv') = 2,
                         'J2 reclaim increments attempt_count');
  perform pg_temp.expect((select count(*) from private.price_alert_jobs j join t_jobs t on t.job_id = j.id
                          where t.label in ('J3_stale_pendingdel','J4_stale_faileddel','J5_stale_procdel','J7_recent_lock','J8_attempt_limit')
                            and j.attempt_count = t.attempts_before and j.status = 'processing') = 5,
                         'J3-J8 untouched rows keep status and attempt_count');
end;
$$;

-- End to end through the real cron entry point: the reclaimed stale jobs finish.
do $$
begin
  -- Make J2 / J6 stale again (their reclaim just refreshed locked_at), then let the real processor
  -- (the function the existing cron job runs) pick them up.
  update private.price_alert_jobs j set locked_at = now() - interval '20 minutes'
  from t_jobs t where t.job_id = j.id and t.label in ('J2_stale_nodeliv', 'J6_stale_allterminal');

  perform * from private.process_price_alert_jobs(50);

  perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_jobs t on t.job_id = j.id where t.label = 'J2_stale_nodeliv') = 'completed',
                         'J2 completes via process_price_alert_jobs after stale reclaim');
  perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_jobs t on t.job_id = j.id where t.label = 'J6_stale_allterminal') = 'completed',
                         'J6 completes via process_price_alert_jobs after stale reclaim');
  perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_jobs t on t.job_id = j.id where t.label = 'J3_stale_pendingdel') = 'processing',
                         'J3 still legitimately waiting after a full processor run');
end;
$$;

-- ==================================================================================================
-- F1-F9: freshness guard + stale expiry (station A: a real trigger-created job exists per report)
-- ==================================================================================================
create temp table t_del (label text primary key, delivery_id uuid, report_id uuid);

-- The J-section fixtures are finished with; drop their deliveries so they cannot be claimed by the
-- delivery scenarios below and skew the exact counts.
delete from private.price_alert_deliveries where price_report_id in (select report_id from t_jobs);

do $$
declare
  r record;
  v_report uuid;
  v_del uuid;
begin
  for r in
    select * from (values
      ('F1_fresh_pending',      interval '10 minutes',  'pending',    interval '0',        null::interval,        0),
      ('F2_stale_pending',      interval '3 hours',     'pending',    interval '0',        null,                  0),
      ('F3_stale_failed_due',   interval '3 hours',     'failed',     interval '-5 minutes', null,                1),
      ('F4_stale_inflight',     interval '3 hours',     'processing', interval '0',        interval '2 minutes',  1),
      ('F5_stale_deadlock',     interval '3 hours',     'processing', interval '0',        interval '20 minutes', 1),
      ('F6_fresh_retry_future', interval '10 minutes',  'failed',     interval '1 hour',   null,                  1),
      ('F7_fresh_failed_due',   interval '10 minutes',  'failed',     interval '-1 minute', null,                 1),
      ('F8a_inside_window',     interval '119 minutes', 'pending',    interval '0',        null,                  0),
      ('F8b_outside_window',    interval '121 minutes', 'pending',    interval '0',        null,                  0),
      ('F9_backdated_3d',       interval '3 days',      'pending',    interval '0',        null,                  0),
      ('F10_stale_sent',        interval '3 hours',     'sent',       interval '0',        null,                  1)
    ) as x(label, age, status, available, lock_age, attempts)
  loop
    v_report := pg_temp.mk_report('station_a', r.age);
    v_del := pg_temp.mk_delivery(v_report, r.status, r.available, r.lock_age, r.attempts);
    insert into t_del values (r.label, v_del, v_report);
    -- the real enqueue trigger created a job for this report; model "job already picked up".
    update private.price_alert_jobs set status = 'processing', locked_at = now() - interval '1 minute'
    where price_report_id = v_report;
  end loop;
end;
$$;

do $$
declare
  v_claimed uuid[];
  v_row record;
begin
  select array_agg(c.delivery_id) into v_claimed from private.claim_price_alert_deliveries(100) c;

  -- claimed set
  perform pg_temp.expect((select delivery_id from t_del where label = 'F1_fresh_pending') = any (v_claimed), 'F1 fresh pending claimed');
  perform pg_temp.expect((select delivery_id from t_del where label = 'F7_fresh_failed_due') = any (v_claimed), 'F7 fresh failed retry (due) claimed');
  perform pg_temp.expect((select delivery_id from t_del where label = 'F8a_inside_window') = any (v_claimed), 'F8a 119-minute-old report is still fresh');
  perform pg_temp.expect(array_length(v_claimed, 1) = 3, 'F claim returns exactly the three fresh, due deliveries');

  -- unchanged payload shape on a claimed row
  select * into v_row from private.price_alert_deliveries d where d.id = (select delivery_id from t_del where label = 'F1_fresh_pending');
  perform pg_temp.expect(v_row.status = 'processing' and v_row.attempt_count = 1 and v_row.locked_at is not null and v_row.attempted_at is not null,
                         'F1 claim marks processing, increments attempt, stamps lock/attempt time');

  -- expired set: terminal, never claimed
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries d join t_del t on t.delivery_id = d.id
                          where t.label in ('F2_stale_pending','F3_stale_failed_due','F5_stale_deadlock','F8b_outside_window','F9_backdated_3d')
                            and d.status = 'skipped' and d.last_error_code = 'stale_report' and d.locked_at is null) = 5,
                         'F2/F3/F5/F8b/F9 stale deliveries are expired to skipped / stale_report');
  perform pg_temp.expect((select status from private.price_alert_deliveries d join t_del t on t.delivery_id = d.id where t.label = 'F4_stale_inflight') = 'processing',
                         'F4 a fresh-locked in-flight send is never touched, even for an old report');
  perform pg_temp.expect((select status from private.price_alert_deliveries d join t_del t on t.delivery_id = d.id where t.label = 'F6_fresh_retry_future') = 'failed',
                         'F6 a not-yet-due retry is untouched');
  perform pg_temp.expect((select status from private.price_alert_deliveries d join t_del t on t.delivery_id = d.id where t.label = 'F10_stale_sent') = 'sent',
                         'F10 terminal rows are never rewritten');

  -- the job of an expired-only report finalizes; a job with a live delivery does not
  perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_del t on t.report_id = j.price_report_id where t.label = 'F2_stale_pending') = 'completed',
                         'F2 job finalizes once its only delivery is expired');
  perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_del t on t.report_id = j.price_report_id where t.label = 'F9_backdated_3d') = 'completed',
                         'F9 back-dated report: no alert sent, job finalizes');
  perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_del t on t.report_id = j.price_report_id where t.label = 'F1_fresh_pending') = 'processing',
                         'F1 job stays processing while its delivery is being sent');
  perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_del t on t.report_id = j.price_report_id where t.label = 'F4_stale_inflight') = 'processing',
                         'F4 job stays processing while its delivery is in flight');

  -- idempotency: an immediate second claim returns nothing new and changes nothing
  perform pg_temp.expect((select count(*) from private.claim_price_alert_deliveries(100)) = 0, 'F idempotent: second claim returns no rows');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries d join t_del t on t.delivery_id = d.id where d.status = 'skipped') = 5,
                         'F idempotent: expiry did not touch anything twice');
end;
$$;

-- ==================================================================================================
-- B1: burst after downtime
-- ==================================================================================================
do $$
declare
  i int;
  v_report uuid;
  v_claimed int;
begin
  for i in 1..40 loop
    v_report := pg_temp.mk_report('station_a', make_interval(hours => 3, mins => i));
    perform pg_temp.mk_delivery(v_report, 'pending');
  end loop;
  for i in 1..3 loop
    v_report := pg_temp.mk_report('station_a', make_interval(mins => i));
    perform pg_temp.mk_delivery(v_report, 'pending');
  end loop;

  select count(*) into v_claimed from private.claim_price_alert_deliveries(100);
  perform pg_temp.expect(v_claimed = 3, 'B1 only the 3 fresh deliveries are returned after a long outage');
  -- 5 expired by the F-section + exactly the 40 stale ones created here.
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where last_error_code = 'stale_report') = 45,
                         'B1 all 40 stale deliveries were expired, not sent');
end;
$$;

-- ==================================================================================================
-- G1: grants
-- ==================================================================================================
do $$
declare
  f text;
begin
  foreach f in array array[
    'private.invoke_price_alerts_worker()',
    'private.claim_price_alert_jobs(integer)',
    'private.claim_price_alert_deliveries(integer)'
  ] loop
    perform pg_temp.expect(not has_function_privilege('anon', f, 'execute'), 'G1 anon cannot execute ' || f);
    perform pg_temp.expect(not has_function_privilege('authenticated', f, 'execute'), 'G1 authenticated cannot execute ' || f);
  end loop;
  perform pg_temp.expect(has_function_privilege('service_role', 'private.claim_price_alert_deliveries(integer)', 'execute'),
                         'G1 service_role keeps execute on claim_price_alert_deliveries (unchanged)');
  perform pg_temp.expect(not has_function_privilege('service_role', 'private.claim_price_alert_jobs(integer)', 'execute'),
                         'G1 claim_price_alert_jobs stays postgres-only (unchanged)');
end;
$$;

rollback;

\echo ALL PRICE ALERT WORKER READINESS SCENARIOS PASSED

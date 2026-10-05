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
-- Scenarios that need TWO database sessions (a locked row must not block a claim, two workers must
-- not double-claim, no deadlocks) cannot run inside one transaction; they live in
-- price_alert_worker_concurrency.test.sh.
--
-- WHAT THIS COVERS
--   W1-W37  invoker configuration matrix: accepted HTTPS origin (+ one trailing slash); rejected
--           http/ftp/other schemes, paths, queries, fragments, userinfo, ports, whitespace (leading,
--           trailing, embedded, newline), double slash, empty/missing URL; empty/blank/missing/short/
--           whitespace-containing/non-ASCII tokens; token trimming; exactly the 32-character floor;
--           every failure raises one of three FIXED value-free messages and records no request; the
--           exact URL, POST headers (scheduler secret header, no Authorization), body, timeout.
--   C1-C6   cron job: exactly one job, correct schedule/command, created INACTIVE; the pre-existing
--           job-prepare job is untouched; re-applying the migration neither duplicates it, nor
--           re-activates an inactive one, nor pauses an operator-activated one, nor rewrites a
--           customized schedule.
--   J1-J13  claim_price_alert_jobs: normal claims; stale reclaim (no deliveries / all terminal);
--           exactly 15 minutes is NOT stale, 15 minutes + 1 s is; attempt_count 4 reclaims, 5 does
--           not; a job waiting on pending/processing/failed deliveries is NEVER reclaimed; dead jobs
--           and recently-locked jobs are not reclaimed.
--   F1-F12  freshness: exactly 2 h and 2 h - 1 s are sendable, 2 h + 1 s is expired; future-dated
--           reports are sendable; expired rows are terminal `skipped` / `stale_report`, never
--           returned, cannot be resurrected by a re-prepare, and their jobs finalize; fresh-locked
--           in-flight sends and not-yet-due retries are untouched; idempotent re-claim.
--   B1-B6   bounded expiry: at most 500 rows per call, a partially drained backlog is NEVER sent
--           (the claim predicate excludes stale rows on its own), fresh deliveries keep flowing, the
--           backlog drains over successive calls, mixed stale + unusable-device backlogs share the
--           same 500 budget.
--   D1-D12  devices: an enabled device claims normally; disabled and invalidated devices are never
--           claimed or returned; their deliveries (pending, failed, stale-locked processing) end in
--           terminal `skipped` / `device_unusable` with attempt_count untouched, never counted as
--           sent, and the parent job finalizes; a fresh in-flight send is left alone; a job still
--           waiting on a usable device's delivery does not finalize; repeated claim cycles never
--           inflate attempts (the 15-minute loop is gone); stale + unusable reports `stale_report`.
--   P1-P2   the supporting partial index exists with the intended definition and the job-claim
--           predicate is served by it (no sequential scan) at volume.
--   G1      grants: none of the new/changed functions is executable by anon/authenticated.

begin;

-- Test helpers ----------------------------------------------------------------------------------
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

-- Three devices on the one installation: a usable one, a user-disabled one, an invalidated one.
insert into private.price_alert_push_devices
  (installation_id, bundle_id, apns_environment, device_token, device_token_hash, enabled, invalidated_at)
select i.id, 'com.e85blends.app.ios.internal', 'sandbox', repeat('b', 64), repeat('c', 64), true, null
from private.price_alert_installations i limit 1;
insert into private.price_alert_push_devices
  (installation_id, bundle_id, apns_environment, device_token, device_token_hash, enabled, invalidated_at)
select i.id, 'com.e85blends.app.ios.internal', 'sandbox', repeat('d', 64), repeat('e', 64), false, null
from private.price_alert_installations i limit 1;
insert into private.price_alert_push_devices
  (installation_id, bundle_id, apns_environment, device_token, device_token_hash, enabled, invalidated_at)
select i.id, 'com.e85blends.app.ios.internal', 'sandbox', repeat('f', 64), repeat('1', 64), true, now() - interval '1 hour'
from private.price_alert_installations i limit 1;
insert into t_ids select 'dev_ok', id from private.price_alert_push_devices where device_token_hash = repeat('c', 64);
insert into t_ids select 'dev_disabled', id from private.price_alert_push_devices where device_token_hash = repeat('e', 64);
insert into t_ids select 'dev_invalidated', id from private.price_alert_push_devices where device_token_hash = repeat('1', 64);

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

-- Delivery factory against the fixture alert; p_device_key picks which device ('dev_ok' default).
create function pg_temp.mk_delivery(p_report uuid, p_status text, p_available interval default interval '0',
                                    p_lock_age interval default null, p_attempts int default 0,
                                    p_device_key text default 'dev_ok')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into private.price_alert_deliveries
    (alert_id, price_report_id, push_device_id, observed_price, status, available_at, locked_at, attempt_count, reason_code)
  select a.id, p_report, (select v from t_ids where k = p_device_key), 3.49, p_status, now() + p_available,
         case when p_lock_age is null then null else now() - p_lock_age end, p_attempts, 'price_changed'
  from private.price_alerts a
  limit 1
  returning id into v_id;
  return v_id;
end;
$$;

-- ==================================================================================================
-- W: invoker configuration matrix
-- ==================================================================================================
do $$
declare
  v_tok constant text := 'readiness-fixture-token-0123456789abcdef';   -- 40 printable chars
  v_tok32 constant text := 'abcdefghijklmnopqrstuvwxyz012345';          -- exactly 32
  c record;
  v_id bigint;
  v_before int;
  v_after int;
  v_row record;
  v_got text;
  v_hdr text;
  v_n int := 0;
  nc constant text := 'price_alerts_worker_scheduler_not_configured';
  bu constant text := 'price_alerts_worker_scheduler_invalid_project_url';
  bt constant text := 'price_alerts_worker_scheduler_invalid_token';
  ok constant text := 'https://abcd.supabase.co/functions/v1/price-alerts-worker';
begin
  if to_regclass('net.sent_requests') is null then
    raise notice 'W skipped: real pg_net detected (no recording stand-in); never sending a real request';
    return;
  end if;

  for c in select * from (values
    -- label                         project_url                                   token                                  expected                       header sent (when sent)
    ('W01 https origin',             'https://abcd.supabase.co',                    v_tok,                                 'SENT:' || ok,                 v_tok),
    ('W02 one trailing slash',       'https://abcd.supabase.co/',                   v_tok,                                 'SENT:' || ok,                 v_tok),
    ('W03 mixed-case host',          'https://AbCd.supabase.co',                    v_tok,                                 'SENT:https://AbCd.supabase.co/functions/v1/price-alerts-worker', v_tok),
    ('W04 http rejected',            'http://abcd.supabase.co',                     v_tok,                                 bu,                            null),
    ('W05 ftp rejected',             'ftp://abcd.supabase.co',                      v_tok,                                 bu,                            null),
    ('W06 no scheme',                'abcd.supabase.co',                            v_tok,                                 bu,                            null),
    ('W07 path rejected',            'https://abcd.supabase.co/rest/v1',            v_tok,                                 bu,                            null),
    ('W08 path + trailing slash',    'https://abcd.supabase.co/x/',                 v_tok,                                 bu,                            null),
    ('W09 query rejected',           'https://abcd.supabase.co?x=1',                v_tok,                                 bu,                            null),
    ('W10 slash + query rejected',   'https://abcd.supabase.co/?x=1',               v_tok,                                 bu,                            null),
    ('W11 fragment rejected',        'https://abcd.supabase.co#f',                  v_tok,                                 bu,                            null),
    ('W12 userinfo rejected',        'https://user@abcd.supabase.co',               v_tok,                                 bu,                            null),
    ('W13 port rejected',            'https://abcd.supabase.co:8443',               v_tok,                                 bu,                            null),
    ('W14 double slash rejected',    'https://abcd.supabase.co//',                  v_tok,                                 bu,                            null),
    ('W15 leading space rejected',   ' https://abcd.supabase.co',                   v_tok,                                 bu,                            null),
    ('W16 trailing space rejected',  'https://abcd.supabase.co ',                   v_tok,                                 bu,                            null),
    ('W17 trailing newline rejected','https://abcd.supabase.co' || chr(10),         v_tok,                                 bu,                            null),
    ('W18 embedded space rejected',  'https://abcd .supabase.co',                   v_tok,                                 bu,                            null),
    ('W19 whitespace-only URL',      '   ',                                         v_tok,                                 bu,                            null),
    ('W20 empty URL',                '',                                            v_tok,                                 nc,                            null),
    ('W21 missing URL secret',       null::text,                                    v_tok,                                 nc,                            null),
    ('W22 missing token secret',     'https://abcd.supabase.co',                    null::text,                            nc,                            null),
    ('W23 empty token',              'https://abcd.supabase.co',                    '',                                    nc,                            null),
    ('W24 blank (40 spaces) token',  'https://abcd.supabase.co',                    repeat(' ', 40),                       nc,                            null),
    ('W25 whitespace/newline token', 'https://abcd.supabase.co',                    ' ' || chr(9) || chr(13) || chr(10),   nc,                            null),
    ('W26 31-char token rejected',   'https://abcd.supabase.co',                    left(v_tok32, 31),                     bt,                            null),
    ('W27 32-char token accepted',   'https://abcd.supabase.co',                    v_tok32,                               'SENT:' || ok,                 v_tok32),
    ('W28 token trimmed (space+LF)', 'https://abcd.supabase.co',                    '  ' || v_tok || chr(10),              'SENT:' || ok,                 v_tok),
    ('W29 token trimmed (CRLF)',     'https://abcd.supabase.co',                    v_tok || chr(13) || chr(10),           'SENT:' || ok,                 v_tok),
    ('W30 trim leaves <32 chars',    'https://abcd.supabase.co',                    '  ' || left(v_tok32, 31) || '  ',     bt,                            null),
    ('W31 internal space rejected',  'https://abcd.supabase.co',                    left(v_tok, 20) || ' ' || right(v_tok, 19), bt,                       null),
    ('W32 internal newline rejected','https://abcd.supabase.co',                    left(v_tok, 20) || chr(10) || right(v_tok, 19), bt,                   null),
    ('W33 internal tab rejected',    'https://abcd.supabase.co',                    left(v_tok, 20) || chr(9) || right(v_tok, 19), bt,                    null),
    ('W34 non-ASCII token rejected', 'https://abcd.supabase.co',                    repeat('é', 40),                       bt,                            null),
    ('W35 control char rejected',    'https://abcd.supabase.co',                    left(v_tok, 20) || chr(1) || right(v_tok, 19), bt,                    null),
    ('W36 http + bad token',         'http://abcd.supabase.co',                     'short',                               bu,                            null),
    ('W37 both missing',             null::text,                                    null::text,                            nc,                            null)
  ) as t(label, project_url, tok, expected, expected_header)
  loop
    delete from vault.secrets;
    if c.project_url is not null then insert into vault.secrets (name, secret) values ('project_url', c.project_url); end if;
    if c.tok is not null then insert into vault.secrets (name, secret) values ('price_alerts_worker_cron_token', c.tok); end if;
    select count(*) into v_before from net.sent_requests;

    begin
      v_id := private.invoke_price_alerts_worker();
      v_got := 'SENT';
    exception when others then
      v_got := sqlerrm;
    end;

    select count(*) into v_after from net.sent_requests;
    if v_got = 'SENT' then
      select * into v_row from net.sent_requests where id = v_id;
      v_got := 'SENT:' || v_row.url;
    end if;
    -- the outcome itself is checked FIRST so a regression names the real cause
    perform pg_temp.expect(v_got = c.expected, c.label || ': expected [' || c.expected || '] got [' || v_got || ']');

    if v_got like 'SENT:%' then
      v_hdr := v_row.headers ->> 'x-85blends-cron-secret';
      perform pg_temp.expect(v_after = v_before + 1, c.label || ': exactly one request recorded');
      perform pg_temp.expect(v_hdr is not distinct from c.expected_header, c.label || ': header carries the TRIMMED token only');
      perform pg_temp.expect(v_row.headers ->> 'Content-Type' = 'application/json', c.label || ': JSON content type');
      perform pg_temp.expect(not (v_row.headers ? 'Authorization') and not (v_row.headers ? 'authorization'),
                             c.label || ': no Authorization header (no service-role key involved)');
      perform pg_temp.expect(v_row.body = '{"job_limit": 20, "delivery_limit": 50}'::jsonb, c.label || ': body');
      perform pg_temp.expect(v_row.timeout_milliseconds = 30000, c.label || ': timeout');
      perform pg_temp.expect(v_row.url !~ '[?#@]' and position(c.tok in v_row.url) = 0, c.label || ': secret never in the URL');
    else
      perform pg_temp.expect(v_after = v_before, c.label || ': a rejected configuration records NO request');
    end if;
    v_n := v_n + 1;
  end loop;

  -- repeated invocation is just another independent request (no state to corrupt)
  delete from vault.secrets;
  insert into vault.secrets (name, secret) values ('project_url', 'https://abcd.supabase.co'), ('price_alerts_worker_cron_token', v_tok);
  select count(*) into v_before from net.sent_requests;
  perform private.invoke_price_alerts_worker();
  perform private.invoke_price_alerts_worker();
  perform pg_temp.expect((select count(*) from net.sent_requests) = v_before + 2, 'W repeated invocation records one request each');
  raise notice 'W: % configuration cases passed', v_n;
  delete from vault.secrets;
end;
$$;

-- ==================================================================================================
-- C1-C6: cron job
-- ==================================================================================================
do $$
begin
  perform pg_temp.expect((select count(*) from cron.job where jobname = '85blends-price-alerts-worker-invoke') = 1,
                         'C1 exactly one worker-invoke job');
  perform pg_temp.expect((select schedule from cron.job where jobname = '85blends-price-alerts-worker-invoke') = '* * * * *',
                         'C1 every-minute schedule');
  perform pg_temp.expect((select command from cron.job where jobname = '85blends-price-alerts-worker-invoke')
                         = 'select private.invoke_price_alerts_worker();', 'C1 command is only the invoker call (no secret, no URL)');
  perform pg_temp.expect((select active from cron.job where jobname = '85blends-price-alerts-worker-invoke') = false,
                         'C2 created INACTIVE (nothing calls the worker until deliberately activated)');
  perform pg_temp.expect((select count(*) from cron.job where jobname = '85blends-price-alert-job-prepare' and active) = 1,
                         'C2 the pre-existing job-prepare job is untouched and active');
  perform pg_temp.expect((select count(*) from cron.job) = 2, 'C2 no other cron jobs were created');

  -- an operator activates it and customizes its schedule; re-applying must change neither
  update cron.job set active = true, schedule = '*/2 * * * *' where jobname = '85blends-price-alerts-worker-invoke';
end;
$$;

\ir ../migrations/20261005120000_price_alert_worker_scheduler_and_freshness.sql

do $$
begin
  perform pg_temp.expect((select count(*) from cron.job where jobname = '85blends-price-alerts-worker-invoke') = 1,
                         'C3 re-applying the migration does not duplicate the job');
  perform pg_temp.expect((select active from cron.job where jobname = '85blends-price-alerts-worker-invoke') = true,
                         'C4 an operator-activated job stays ACTIVE after the migration is replayed');
  perform pg_temp.expect((select schedule from cron.job where jobname = '85blends-price-alerts-worker-invoke') = '*/2 * * * *',
                         'C5 a customized schedule is not rewritten by a replay');
  -- now the operator pauses it; a replay must not re-activate it
  update cron.job set active = false where jobname = '85blends-price-alerts-worker-invoke';
end;
$$;

\ir ../migrations/20261005120000_price_alert_worker_scheduler_and_freshness.sql

do $$
begin
  perform pg_temp.expect((select active from cron.job where jobname = '85blends-price-alerts-worker-invoke') = false,
                         'C6 an inactive job stays INACTIVE after the migration is replayed');
  perform pg_temp.expect((select count(*) from cron.job where jobname = '85blends-price-alerts-worker-invoke') = 1,
                         'C6 still exactly one job after two replays');
  perform pg_temp.expect((select count(*) from cron.job) = 2, 'C6 no other cron jobs appeared');
  update cron.job set schedule = '* * * * *' where jobname = '85blends-price-alerts-worker-invoke';
end;
$$;

-- ==================================================================================================
-- J1-J13: stale-job recovery (station N has no alert, so no trigger-created jobs interfere)
-- ==================================================================================================
create temp table t_jobs (label text primary key, job_id uuid, report_id uuid, attempts_before int);

do $$
declare
  v_report uuid;
  v_job uuid;
  r record;
begin
  -- label, status, lock age, attempts, delivery-status-to-attach
  for r in
    select * from (values
      ('J1_pending',           'pending',    null::interval,                              0, null::text),
      ('J2_stale_nodeliv',     'processing', interval '20 minutes',                       1, null),
      ('J3_stale_pendingdel',  'processing', interval '20 minutes',                       1, 'pending'),
      ('J4_stale_faileddel',   'processing', interval '20 minutes',                       2, 'failed'),
      ('J5_stale_procdel',     'processing', interval '20 minutes',                       1, 'processing'),
      ('J6_stale_allterminal', 'processing', interval '20 minutes',                       1, 'sent'),
      ('J7_recent_lock',       'processing', interval '5 minutes',                        1, null),
      ('J8_attempt_limit',     'processing', interval '20 minutes',                       5, null),
      ('J9_exactly_15m',       'processing', interval '15 minutes',                       1, null),
      ('J10_15m_plus_1s',      'processing', interval '15 minutes' + interval '1 second', 1, null),
      ('J11_attempt_4',        'processing', interval '20 minutes',                       4, null),
      ('J12_dead',             'dead',       interval '20 minutes',                       5, null),
      ('J13_failed_not_due',   'failed',     null::interval,                              1, null)
    ) as x(label, status, lock_age, attempts, del_status)
  loop
    v_report := pg_temp.mk_report('station_n', interval '10 minutes');
    insert into private.price_alert_jobs (price_report_id, status, attempt_count, locked_at, available_at)
    values (v_report, r.status, r.attempts, case when r.lock_age is null then null else now() - r.lock_age end,
            case when r.label = 'J13_failed_not_due' then now() + interval '1 hour' else now() end)
    returning id into v_job;
    insert into t_jobs values (r.label, v_job, v_report, r.attempts);

    if r.del_status is not null then
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

  perform pg_temp.expect((select job_id from t_jobs where label = 'J1_pending') = any (v_claimed), 'J1 a due pending job is still claimed');
  perform pg_temp.expect((select job_id from t_jobs where label = 'J2_stale_nodeliv') = any (v_claimed), 'J2 a stale processing job with no deliveries is reclaimed');
  perform pg_temp.expect((select job_id from t_jobs where label = 'J6_stale_allterminal') = any (v_claimed), 'J6 a stale job whose deliveries are all terminal is reclaimed (so it can finalize)');
  perform pg_temp.expect((select job_id from t_jobs where label = 'J10_15m_plus_1s') = any (v_claimed), 'J10 locked 15 minutes + 1 second ago IS stale');
  perform pg_temp.expect((select job_id from t_jobs where label = 'J11_attempt_4') = any (v_claimed), 'J11 attempt_count 4 (< 5) is reclaimed');

  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J3_stale_pendingdel') = any (v_claimed)), 'J3 a job waiting on a PENDING delivery is never reclaimed');
  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J4_stale_faileddel') = any (v_claimed)), 'J4 a job waiting on a FAILED (retrying) delivery is never reclaimed');
  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J5_stale_procdel') = any (v_claimed)), 'J5 a job with a PROCESSING delivery is never reclaimed');
  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J7_recent_lock') = any (v_claimed)), 'J7 a job locked only 5 minutes ago is not stale yet');
  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J8_attempt_limit') = any (v_claimed)), 'J8 a stale job already at attempt_count 5 is not reclaimed again');
  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J9_exactly_15m') = any (v_claimed)), 'J9 locked EXACTLY 15 minutes ago is not yet stale (strict boundary)');
  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J12_dead') = any (v_claimed)), 'J12 a dead job is never reclaimed');
  perform pg_temp.expect(not ((select job_id from t_jobs where label = 'J13_failed_not_due') = any (v_claimed)), 'J13 a failed job that is not yet due is not claimed');

  perform pg_temp.expect((select attempt_count from private.price_alert_jobs j join t_jobs t on t.job_id = j.id where t.label = 'J2_stale_nodeliv') = 2,
                         'J2 reclaim increments attempt_count');
  perform pg_temp.expect((select count(*) from private.price_alert_jobs j join t_jobs t on t.job_id = j.id
                          where t.label in ('J3_stale_pendingdel','J4_stale_faileddel','J5_stale_procdel','J7_recent_lock','J8_attempt_limit','J9_exactly_15m')
                            and j.attempt_count = t.attempts_before and j.status = 'processing') = 6,
                         'J3-J9 untouched rows keep status and attempt_count');
  perform pg_temp.expect((select status from private.price_alert_jobs j join t_jobs t on t.job_id = j.id where t.label = 'J12_dead') = 'dead',
                         'J12 a dead job stays dead');
end;
$$;

-- End to end through the real cron entry point: the reclaimed stale jobs finish.
do $$
begin
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
-- F1-F12: freshness guard + stale expiry (station A: a real trigger-created job exists per report)
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
      ('F1_fresh_pending',      interval '10 minutes',                        'pending',    interval '0',          null::interval,        0),
      ('F2_stale_pending',      interval '3 hours',                           'pending',    interval '0',          null,                  0),
      ('F3_stale_failed_due',   interval '3 hours',                           'failed',     interval '-5 minutes', null,                  1),
      ('F4_stale_inflight',     interval '3 hours',                           'processing', interval '0',          interval '2 minutes',  1),
      ('F5_stale_deadlock',     interval '3 hours',                           'processing', interval '0',          interval '20 minutes', 1),
      ('F6_fresh_retry_future', interval '10 minutes',                        'failed',     interval '1 hour',     null,                  1),
      ('F7_fresh_failed_due',   interval '10 minutes',                        'failed',     interval '-1 minute',  null,                  1),
      ('F8a_exactly_2h',        interval '2 hours',                           'pending',    interval '0',          null,                  0),
      ('F8b_2h_minus_1s',       interval '2 hours' - interval '1 second',     'pending',    interval '0',          null,                  0),
      ('F8c_2h_plus_1s',        interval '2 hours' + interval '1 second',     'pending',    interval '0',          null,                  0),
      ('F9_backdated_3d',       interval '3 days',                            'pending',    interval '0',          null,                  0),
      ('F10_stale_sent',        interval '3 hours',                           'sent',       interval '0',          null,                  1),
      ('F11_future_dated',      interval '-10 minutes',                       'pending',    interval '0',          null,                  0)
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

  perform pg_temp.expect((select delivery_id from t_del where label = 'F1_fresh_pending') = any (v_claimed), 'F1 fresh pending claimed');
  perform pg_temp.expect((select delivery_id from t_del where label = 'F7_fresh_failed_due') = any (v_claimed), 'F7 fresh failed retry (due) claimed');
  perform pg_temp.expect((select delivery_id from t_del where label = 'F8a_exactly_2h') = any (v_claimed), 'F8a a report EXACTLY 2 hours old is still sendable (inclusive boundary)');
  perform pg_temp.expect((select delivery_id from t_del where label = 'F8b_2h_minus_1s') = any (v_claimed), 'F8b 2 hours minus 1 second is sendable');
  perform pg_temp.expect((select delivery_id from t_del where label = 'F11_future_dated') = any (v_claimed), 'F11 a future-dated report is sendable');
  perform pg_temp.expect(array_length(v_claimed, 1) = 5, 'F claim returns exactly the five fresh, due deliveries');

  -- unchanged payload shape on a claimed row
  select * into v_row from private.price_alert_deliveries d where d.id = (select delivery_id from t_del where label = 'F1_fresh_pending');
  perform pg_temp.expect(v_row.status = 'processing' and v_row.attempt_count = 1 and v_row.locked_at is not null and v_row.attempted_at is not null,
                         'F1 claim marks processing, increments attempt, stamps lock/attempt time');

  -- expired set: terminal, never claimed
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries d join t_del t on t.delivery_id = d.id
                          where t.label in ('F2_stale_pending','F3_stale_failed_due','F5_stale_deadlock','F8c_2h_plus_1s','F9_backdated_3d')
                            and d.status = 'skipped' and d.last_error_code = 'stale_report' and d.locked_at is null) = 5,
                         'F2/F3/F5/F8c/F9 stale deliveries (incl. 2 h + 1 s) are expired to skipped / stale_report');
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

  -- terminal means terminal: a re-prepare of an expired report must not resurrect its delivery
  perform * from private.prepare_price_alert_deliveries((select report_id from t_del where label = 'F2_stale_pending'));
  perform pg_temp.expect((select status from private.price_alert_deliveries d join t_del t on t.delivery_id = d.id where t.label = 'F2_stale_pending') = 'skipped',
                         'F12 a re-prepare cannot make an expired delivery sendable again');
  perform pg_temp.expect((select count(*) from private.claim_price_alert_deliveries(100) c where c.delivery_id = (select delivery_id from t_del where label = 'F2_stale_pending')) = 0,
                         'F12 an expired delivery is never claimed afterwards');
end;
$$;

-- ==================================================================================================
-- D1-D12: unusable devices (disabled / invalidated)
-- ==================================================================================================
create temp table t_dev (label text primary key, delivery_id uuid, report_id uuid);

do $$
declare
  r record;
  v_report uuid;
  v_del uuid;
begin
  for r in
    select * from (values
      ('D1_ok_device',            'dev_ok',          'pending',    interval '0',          null::interval,        interval '10 minutes'),
      ('D2_disabled_pending',     'dev_disabled',    'pending',    interval '0',          null,                  interval '10 minutes'),
      ('D3_invalidated_pending',  'dev_invalidated', 'pending',    interval '0',          null,                  interval '10 minutes'),
      ('D4_disabled_failed_due',  'dev_disabled',    'failed',     interval '-1 minute',  null,                  interval '10 minutes'),
      ('D5_disabled_inflight',    'dev_disabled',    'processing', interval '0',          interval '1 minute',   interval '10 minutes'),
      ('D6_disabled_stale_lock',  'dev_disabled',    'processing', interval '0',          interval '20 minutes', interval '10 minutes'),
      ('D7_disabled_and_stale',   'dev_disabled',    'pending',    interval '0',          null,                  interval '3 hours'),
      ('D8_invalid_stale_lock',   'dev_invalidated', 'processing', interval '0',          interval '20 minutes', interval '10 minutes')
    ) as x(label, dev, status, available, lock_age, age)
  loop
    v_report := pg_temp.mk_report('station_a', r.age);
    v_del := pg_temp.mk_delivery(v_report, r.status, r.available, r.lock_age, case when r.status = 'pending' then 0 else 1 end, r.dev);
    insert into t_dev values (r.label, v_del, v_report);
    update private.price_alert_jobs set status = 'processing', locked_at = now() - interval '1 minute' where price_report_id = v_report;
  end loop;
end;
$$;

do $$
declare
  v_claimed uuid[];
  v_n int;
begin
  select array_agg(c.delivery_id) into v_claimed from private.claim_price_alert_deliveries(100) c;

  perform pg_temp.expect((select delivery_id from t_dev where label = 'D1_ok_device') = any (v_claimed), 'D1 a delivery to an enabled, valid device is claimed normally');
  perform pg_temp.expect(array_length(v_claimed, 1) = 1, 'D no delivery to a disabled or invalidated device is ever returned to the worker');

  -- D2/D3/D4/D6/D8: terminal skip with a specific reason, attempts NOT inflated, never "sent"
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries d join t_dev t on t.delivery_id = d.id
                          where t.label in ('D2_disabled_pending','D3_invalidated_pending','D4_disabled_failed_due','D6_disabled_stale_lock','D8_invalid_stale_lock')
                            and d.status = 'skipped' and d.last_error_code = 'device_unusable' and d.locked_at is null and d.sent_at is null) = 5,
                         'D2/D3/D4/D6/D8 unusable-device deliveries end in terminal skipped / device_unusable (never sent)');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries d join t_dev t on t.delivery_id = d.id
                          where t.label in ('D2_disabled_pending','D3_invalidated_pending') and d.attempt_count = 0) = 2,
                         'D2/D3 an unusable-device delivery is never counted as an attempt');
  perform pg_temp.expect((select status from private.price_alert_deliveries d join t_dev t on t.delivery_id = d.id where t.label = 'D5_disabled_inflight') = 'processing',
                         'D5 a fresh in-flight send to a since-disabled device is left to its worker');
  perform pg_temp.expect((select last_error_code from private.price_alert_deliveries d join t_dev t on t.delivery_id = d.id where t.label = 'D7_disabled_and_stale') = 'stale_report',
                         'D7 stale AND unusable reports stale_report (staleness takes precedence)');

  -- parent job finalization
  perform pg_temp.expect((select count(*) from private.price_alert_jobs j join t_dev t on t.report_id = j.price_report_id
                          where t.label in ('D2_disabled_pending','D3_invalidated_pending','D4_disabled_failed_due','D6_disabled_stale_lock','D7_disabled_and_stale','D8_invalid_stale_lock')
                            and j.status = 'completed') = 6,
                         'D parent jobs of unusable-device deliveries finalize');
  perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_dev t on t.report_id = j.price_report_id where t.label = 'D5_disabled_inflight') = 'processing',
                         'D5 the job stays processing while its in-flight delivery is unresolved');
  perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_dev t on t.report_id = j.price_report_id where t.label = 'D1_ok_device') = 'processing',
                         'D1 the job of a delivery being sent stays processing');

  -- The old 15-minute loop: lapse the lock repeatedly; an unusable delivery must never be re-claimed
  -- or have its attempts inflated, and there is nothing left to claim.
  for v_n in 1..4 loop
    update private.price_alert_deliveries set locked_at = now() - interval '20 minutes'
    where id = (select delivery_id from t_dev where label = 'D5_disabled_inflight');
    perform count(*) from private.claim_price_alert_deliveries(100);
  end loop;
  perform pg_temp.expect((select status || ':' || attempt_count from private.price_alert_deliveries d join t_dev t on t.delivery_id = d.id where t.label = 'D5_disabled_inflight') = 'skipped:1',
                         'D9 after its lock lapses the in-flight-to-disabled-device row is skipped once (attempt_count stays 1) and never re-claimed');
  perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_dev t on t.report_id = j.price_report_id where t.label = 'D5_disabled_inflight') = 'completed',
                         'D9 ...and its job finalizes');
end;
$$;

-- D10-D12: a job with one usable and one unusable delivery completes only when the usable one is done
do $$
declare
  v_report uuid;
  v_ok uuid;
  v_bad uuid;
  v_job_status text;
begin
  v_report := pg_temp.mk_report('station_a', interval '5 minutes');
  v_ok := pg_temp.mk_delivery(v_report, 'pending', interval '0', null, 0, 'dev_ok');
  v_bad := pg_temp.mk_delivery(v_report, 'pending', interval '0', null, 0, 'dev_disabled');
  update private.price_alert_jobs set status = 'processing', locked_at = now() - interval '1 minute' where price_report_id = v_report;

  perform pg_temp.expect((select count(*) from private.claim_price_alert_deliveries(100) c where c.delivery_id = v_ok) = 1, 'D10 the usable delivery is claimed');
  perform pg_temp.expect((select status from private.price_alert_deliveries where id = v_bad) = 'skipped', 'D10 the unusable sibling is skipped');
  select status into v_job_status from private.price_alert_jobs where price_report_id = v_report;
  perform pg_temp.expect(v_job_status = 'processing', 'D11 the job does NOT finalize while its usable delivery is still being sent');

  perform private.mark_price_alert_delivery_sent(v_ok, 200);
  select status into v_job_status from private.price_alert_jobs where price_report_id = v_report;
  perform pg_temp.expect(v_job_status = 'completed', 'D12 the job finalizes once the usable delivery is sent');
  perform pg_temp.expect((select status from private.price_alert_deliveries where id = v_bad) = 'skipped'
                         and (select sent_at from private.price_alert_deliveries where id = v_bad) is null,
                         'D12 the unusable delivery is still not counted as sent');
end;
$$;

-- ==================================================================================================
-- B1-B6: bounded expiry; a partially drained backlog is never sent
-- ==================================================================================================
create temp table t_returned (delivery_id uuid);
create temp table t_stale (delivery_id uuid primary key);

do $$
declare
  i int;
  v_report uuid;
  v_del uuid;
begin
  -- 1200 stale deliveries to a usable device, 3 fresh ones
  for i in 1..1200 loop
    v_report := pg_temp.mk_report('station_n', make_interval(hours => 3, mins => i % 50));
    v_del := pg_temp.mk_delivery(v_report, 'pending');
    insert into t_stale values (v_del);
  end loop;
  for i in 1..3 loop
    v_report := pg_temp.mk_report('station_n', make_interval(mins => i));
    perform pg_temp.mk_delivery(v_report, 'pending');
  end loop;
end;
$$;

do $$
declare
  v_expired_before int;
  v_expired int;
begin
  select count(*) into v_expired_before from private.price_alert_deliveries where last_error_code in ('stale_report','device_unusable');

  -- call 1
  insert into t_returned select delivery_id from private.claim_price_alert_deliveries(100);
  select count(*) into v_expired from private.price_alert_deliveries where last_error_code in ('stale_report','device_unusable');
  perform pg_temp.expect(v_expired - v_expired_before = 500, 'B1 the first call expires EXACTLY 500 rows, not the whole 1200-row backlog (got ' || (v_expired - v_expired_before) || ')');
  perform pg_temp.expect((select count(*) from t_returned) = 3, 'B2 fresh deliveries keep flowing while a stale backlog exists (3 fresh returned)');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries d join t_stale s on s.delivery_id = d.id
                          where d.status = 'pending' and d.attempt_count = 0) = 700,
                         'B3 the 700 not-yet-swept stale rows are untouched (still pending, never attempted)');
  perform pg_temp.expect(not exists (select 1 from t_returned r join t_stale s on s.delivery_id = r.delivery_id),
                         'B3 NO stale delivery was returned to the worker while the backlog was only partially drained');

  -- call 2 and 3 drain the rest incrementally
  insert into t_returned select delivery_id from private.claim_price_alert_deliveries(100);
  select count(*) into v_expired from private.price_alert_deliveries where last_error_code in ('stale_report','device_unusable');
  perform pg_temp.expect(v_expired - v_expired_before = 1000, 'B4 the second call continues the drain (1000 total)');
  perform pg_temp.expect(not exists (select 1 from t_returned r join t_stale s on s.delivery_id = r.delivery_id), 'B4 still no stale send');

  insert into t_returned select delivery_id from private.claim_price_alert_deliveries(100);
  select count(*) into v_expired from private.price_alert_deliveries where last_error_code in ('stale_report','device_unusable');
  perform pg_temp.expect(v_expired - v_expired_before = 1200, 'B4 the third call finishes the backlog (500 + 500 + 200)');

  insert into t_returned select delivery_id from private.claim_price_alert_deliveries(100);
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries d join t_stale s on s.delivery_id = d.id where d.status = 'skipped' and d.last_error_code = 'stale_report') = 1200,
                         'B5 all 1200 stale rows are terminal skipped / stale_report');
  perform pg_temp.expect(not exists (select 1 from t_returned r join t_stale s on s.delivery_id = r.delivery_id),
                         'B5 across every call, no stale delivery was ever sendable');
  perform pg_temp.expect((select count(*) from t_returned) = 3, 'B5 and nothing but the 3 fresh deliveries was ever returned');
end;
$$;

-- B6: stale + unusable-device backlogs share the same 500-row budget per call, and a partially
-- drained backlog of EITHER kind is never handed to the worker
create temp table t_b6 (delivery_id uuid primary key, kind text);
create temp table t_b6_returned (delivery_id uuid);

do $$
declare
  i int;
  v_before int;
  v_after int;
  v_id uuid;
begin
  for i in 1..400 loop
    v_id := pg_temp.mk_delivery(pg_temp.mk_report('station_n', interval '3 hours'), 'pending');
    insert into t_b6 values (v_id, 'stale');
  end loop;
  for i in 1..400 loop
    v_id := pg_temp.mk_delivery(pg_temp.mk_report('station_n', interval '10 minutes'), 'pending', interval '0', null, 0, 'dev_disabled');
    insert into t_b6 values (v_id, 'unusable');
  end loop;
  select count(*) into v_before from private.price_alert_deliveries where last_error_code in ('stale_report','device_unusable');

  insert into t_b6_returned select delivery_id from private.claim_price_alert_deliveries(100);
  select count(*) into v_after from private.price_alert_deliveries where last_error_code in ('stale_report','device_unusable');
  perform pg_temp.expect(v_after - v_before = 500, 'B6 a mixed stale + unusable-device backlog is bounded by the same 500 rows per call (got ' || (v_after - v_before) || ')');
  perform pg_temp.expect(not exists (select 1 from t_b6_returned r join t_b6 b on b.delivery_id = r.delivery_id and b.kind = 'stale'),
                         'B6 no STALE delivery is returned while the backlog is only partially drained');
  perform pg_temp.expect(not exists (select 1 from t_b6_returned r join t_b6 b on b.delivery_id = r.delivery_id and b.kind = 'unusable'),
                         'B6 no UNUSABLE-DEVICE delivery is returned while the backlog is only partially drained (the claim predicate excludes them on its own)');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries d join t_b6 b on b.delivery_id = d.id where d.status = 'processing') = 0,
                         'B6 nothing in the backlog was flipped to processing (no attempt burned) by the claim');

  insert into t_b6_returned select delivery_id from private.claim_price_alert_deliveries(100);
  select count(*) into v_after from private.price_alert_deliveries where last_error_code in ('stale_report','device_unusable');
  perform pg_temp.expect(v_after - v_before = 800, 'B6 the next call drains the remaining 300');
  perform pg_temp.expect(not exists (select 1 from t_b6_returned r join t_b6 b on b.delivery_id = r.delivery_id),
                         'B6 and still no backlog row was ever returned');
end;
$$;

-- ==================================================================================================
-- P1-P2: the supporting index exists and serves the stale-job branch at volume
-- ==================================================================================================
do $$
declare
  v_def text;
  v_plan text := '';
  rec record;
begin
  select indexdef into v_def from pg_indexes where schemaname = 'private' and indexname = 'price_alert_jobs_stuck_processing_idx';
  perform pg_temp.expect(v_def is not null, 'P1 price_alert_jobs_stuck_processing_idx exists');
  perform pg_temp.expect(v_def ~ '\(locked_at\)' and v_def ~ 'WHERE \(status = ''processing''::text\)',
                         'P1 the index is on (locked_at) WHERE status = ''processing'' (got: ' || v_def || ')');
end;
$$;

-- volume: 30k completed jobs (one report each, on station N so no alert trigger fires)
insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id)
select (select v from t_ids where k = 'station_n'), 3.49, now() - interval '40 days', 'volume'
from generate_series(1, 30000);
insert into private.price_alert_jobs (price_report_id, status, attempt_count, processed_at)
select id, 'completed', 1, now() from public.e85_price_reports where anonymous_reporter_id = 'volume';
analyze private.price_alert_jobs;

do $$
declare
  v_plan text := '';
  rec record;
begin
  -- Same predicate as the claim's candidate query (keep in sync with claim_price_alert_jobs).
  -- enable_seqscan = off makes the assertion deterministic: with the index the planner serves the
  -- OR from two partial indexes (BitmapOr); without it the only plan left is a sequential scan.
  perform set_config('enable_seqscan', 'off', true);
  for rec in execute $q$ explain
    select j.id from private.price_alert_jobs j
    where ( j.status in ('pending','failed') and j.available_at <= now() )
       or ( j.status = 'processing' and j.locked_at < now() - interval '15 minutes' and j.attempt_count < 5
            and not exists (select 1 from private.price_alert_deliveries d
                            where d.price_report_id = j.price_report_id and d.status in ('pending','processing','failed')) )
    order by j.available_at asc, j.created_at asc limit 50 $q$
  loop
    v_plan := v_plan || rec."QUERY PLAN" || E'\n';
  end loop;
  perform set_config('enable_seqscan', 'on', true);
  perform pg_temp.expect(v_plan like '%price_alert_jobs_stuck_processing_idx%',
                         'P2 the stale-job branch is served by price_alert_jobs_stuck_processing_idx. Plan was:' || E'\n' || v_plan);
  perform pg_temp.expect(v_plan not like '%Seq Scan on price_alert_jobs%',
                         'P2 the job claim does not sequentially scan price_alert_jobs. Plan was:' || E'\n' || v_plan);
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
  perform pg_temp.expect(not has_function_privilege('service_role', 'private.invoke_price_alerts_worker()', 'execute'),
                         'G1 invoke_price_alerts_worker is postgres-only');
end;
$$;

rollback;

\echo ALL PRICE ALERT WORKER READINESS SCENARIOS PASSED

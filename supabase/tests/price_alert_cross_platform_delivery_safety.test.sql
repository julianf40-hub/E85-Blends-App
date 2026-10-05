-- 85Blends 2.4.1 — Price Alerts cross-platform delivery-safety regression matrix.
-- Covers supabase/migrations/20261005233000_price_alert_cross_platform_delivery_safety.sql on top of
-- 20261005120000 (scheduler + freshness, v1 claim) and 20261005211547 (cross-platform push, v2 claim).
--
-- LOCAL-REPLAY ONLY (see README.md in this directory): run it with psql from any directory against a
-- scratch database that already has the FULL migration chain applied (the same file passes on a
-- database built in chronological order and on one built in the production order, where
-- 20261005211547 was applied first and 20261005120000 afterwards). One transaction, rolled back at the
-- end; it RAISEs on any unexpected outcome, and reaching the final \echo line is a full pass.
--
-- Scenarios that need TWO sessions (locked rows, two concurrent workers) live in
-- price_alert_cross_platform_concurrency.test.sh.
--
-- WHAT THIS COVERS
--   X1  v2 claim shape and platform isolation: an 'ios' call returns only iOS rows (platform, APNs
--       environment, bundle id, token) and leaves Android rows untouched; an 'android' call returns
--       only Android rows (platform 'android', NULL apns_environment, package name, FCM token).
--   X2  per platform (iOS and Android alike): fresh claimed; EXACTLY 2 h old claimed, 2 h + 1 s
--       expired to stale_report; stale failed/lapsed-processing expired; fresh-locked in-flight and
--       not-yet-due retries untouched; due retries and lapsed processing rows reclaimed with a new
--       attempt; disabled / invalidated devices expired to device_unusable WITHOUT burning an attempt;
--       stale + unusable reports stale_report; terminal rows never rewritten; the sweep of one
--       platform never touches the other platform's rows.
--   X3  expiring a delivery finalizes its job (both platforms).
--   X4  v2 argument validation.
--   X5  v1 compatibility wrapper: iOS-only, unchanged 13-column shape, never returns or touches
--       Android rows, expires stale iOS rows.
--   X6  bounded sweep per platform (500 per call, per platform), fresh deliveries keep flowing behind
--       a large stale backlog, a partially drained backlog is never returned, and the backlog of one
--       platform does not consume the other platform's budget.
--   X7  retry ladder inputs are untouched (a failed row due again is claimed and re-attempted).
--   X8  chain state: scheduler function, stuck-processing index and stale-job reclaim exist exactly
--       once, the worker cron job exists exactly once and is INACTIVE, the job-prepare job is
--       untouched, signatures/ACLs are as production, and re-applying the migration is a no-op.

begin;

create function pg_temp.expect(p_ok boolean, p_label text) returns void language plpgsql as $$
begin
  if p_ok is distinct from true then
    raise exception 'FAILED: %', p_label;
  end if;
end;
$$;

create function pg_temp.raises(p_sql text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return true;
end;
$$;

-- Fixtures --------------------------------------------------------------------------------------
-- Station A has an enabled alert for each installation (reports on it enqueue jobs through the real
-- trigger); station N has none.
create temp table t_ids (k text primary key, v uuid);

insert into public.community_stations (name, normalized_key) values ('XPlatform Test A', 'xplatform-test-a');
insert into public.community_stations (name, normalized_key) values ('XPlatform Test N', 'xplatform-test-n');
insert into t_ids select 'station_a', id from public.community_stations where normalized_key = 'xplatform-test-a';
insert into t_ids select 'station_n', id from public.community_stations where normalized_key = 'xplatform-test-n';

insert into private.price_alert_installations (client_installation_id, installation_secret_hash, client_platform)
values (gen_random_uuid(), repeat('a', 64), 'ios'), (gen_random_uuid(), repeat('b', 64), 'android');
insert into t_ids select 'inst_ios', id from private.price_alert_installations where client_platform = 'ios' and installation_secret_hash = repeat('a', 64);
insert into t_ids select 'inst_android', id from private.price_alert_installations where client_platform = 'android' and installation_secret_hash = repeat('b', 64);

-- iOS devices: usable / user-disabled / invalidated.
insert into private.price_alert_push_devices
  (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash, enabled, invalidated_at)
select (select v from t_ids where k = 'inst_ios'), 'ios', 'com.e85blends.app.ios.internal', 'sandbox', repeat('1', 64), repeat('1', 64), true, null::timestamptz
union all
select (select v from t_ids where k = 'inst_ios'), 'ios', 'com.e85blends.app.ios.internal', 'sandbox', repeat('2', 64), repeat('2', 64), false, null
union all
select (select v from t_ids where k = 'inst_ios'), 'ios', 'com.e85blends.app.ios.internal', 'sandbox', repeat('3', 64), repeat('3', 64), true, now() - interval '1 hour';
-- Android devices: usable / user-disabled / invalidated (apns_environment is NULL on Android).
insert into private.price_alert_push_devices
  (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash, enabled, invalidated_at)
select (select v from t_ids where k = 'inst_android'), 'android', 'com.e85blends.android', null::text, 'fcm-token-' || repeat('4', 40), repeat('4', 64), true, null::timestamptz
union all
select (select v from t_ids where k = 'inst_android'), 'android', 'com.e85blends.android', null, 'fcm-token-' || repeat('5', 40), repeat('5', 64), false, null
union all
select (select v from t_ids where k = 'inst_android'), 'android', 'com.e85blends.android', null, 'fcm-token-' || repeat('6', 40), repeat('6', 64), true, now() - interval '1 hour';
insert into t_ids select 'ios_ok', id from private.price_alert_push_devices where device_token_hash = repeat('1', 64);
insert into t_ids select 'ios_dis', id from private.price_alert_push_devices where device_token_hash = repeat('2', 64);
insert into t_ids select 'ios_inv', id from private.price_alert_push_devices where device_token_hash = repeat('3', 64);
insert into t_ids select 'android_ok', id from private.price_alert_push_devices where device_token_hash = repeat('4', 64);
insert into t_ids select 'android_dis', id from private.price_alert_push_devices where device_token_hash = repeat('5', 64);
insert into t_ids select 'android_inv', id from private.price_alert_push_devices where device_token_hash = repeat('6', 64);

insert into private.price_alerts (installation_id, station_id)
select (select v from t_ids where k = 'inst_ios'), (select v from t_ids where k = 'station_a')
union all
select (select v from t_ids where k = 'inst_android'), (select v from t_ids where k = 'station_a');

create function pg_temp.mk_report(p_station text, p_age interval) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id)
  values ((select v from t_ids where k = p_station), 3.49, now() - p_age, 'xplatform-reporter')
  returning id into v_id;
  return v_id;
end;
$$;

-- Delivery factory: the alert is the one of the device's own installation.
create function pg_temp.mk_delivery(p_report uuid, p_status text, p_device_key text,
                                    p_available interval default interval '0',
                                    p_lock_age interval default null, p_attempts int default 0)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into private.price_alert_deliveries
    (alert_id, price_report_id, push_device_id, observed_price, status, available_at, locked_at, attempt_count, reason_code)
  select a.id, p_report, d.id, 3.49, p_status, now() + p_available,
         case when p_lock_age is null then null else now() - p_lock_age end, p_attempts, 'price_changed'
  from private.price_alert_push_devices d
  join private.price_alerts a on a.installation_id = d.installation_id
  where d.id = (select v from t_ids where k = p_device_key)
    and a.station_id = (select v from t_ids where k = 'station_a')
  returning id into v_id;
  if v_id is null then raise exception 'mk_delivery: no alert/device for %', p_device_key; end if;
  return v_id;
end;
$$;

-- ==================================================================================================
-- X1: v2 claim shape + platform isolation
-- ==================================================================================================
create temp table t_x1 (label text primary key, delivery_id uuid);
do $$
declare
  v_ios uuid := pg_temp.mk_delivery(pg_temp.mk_report('station_n', interval '5 minutes'), 'pending', 'ios_ok');
  v_and uuid := pg_temp.mk_delivery(pg_temp.mk_report('station_n', interval '5 minutes'), 'pending', 'android_ok');
  r record;
  n int;
begin
  insert into t_x1 values ('ios', v_ios), ('android', v_and);

  perform pg_temp.expect(pg_get_function_result('private.claim_price_alert_deliveries_v2(integer,text)'::regprocedure) =
    'TABLE(delivery_id uuid, alert_id uuid, price_report_id uuid, push_device_id uuid, platform text, station_id uuid, station_name text, device_token text, apns_environment text, bundle_id text, observed_price numeric, previous_price numeric, reason_code text, attempt_count integer)',
    'X1 v2 return shape is exactly the one worker v4 expects');

  select count(*) into n from private.claim_price_alert_deliveries_v2(100, 'ios');
  perform pg_temp.expect(n = 1, 'X1 an ios call returns exactly the one iOS delivery (got ' || n || ')');
  perform pg_temp.expect((select status from private.price_alert_deliveries where id = v_and) = 'pending'
                         and (select attempt_count from private.price_alert_deliveries where id = v_and) = 0,
                         'X1 the Android delivery was not touched by the ios call');

  select * into r from private.price_alert_deliveries d where d.id = v_ios;
  perform pg_temp.expect(r.status = 'processing' and r.attempt_count = 1 and r.locked_at is not null and r.attempted_at is not null,
                         'X1 an ios claim marks processing, increments the attempt, stamps lock/attempt time');
  perform pg_temp.expect(r.last_error_code is null, 'X1 a claim clears last_error_code');

  -- the Android call (the call's own row is verified through the returned columns)
  select c.* into r from private.claim_price_alert_deliveries_v2(100, 'android') c;
  perform pg_temp.expect(r.delivery_id = v_and, 'X1 an android call returns the Android delivery');
  perform pg_temp.expect(r.platform = 'android' and r.apns_environment is null and r.bundle_id = 'com.e85blends.android'
                         and r.device_token = 'fcm-token-' || repeat('4', 40) and r.station_name = 'XPlatform Test N'
                         and r.attempt_count = 1 and r.observed_price = 3.49 and r.reason_code = 'price_changed',
                         'X1 Android row: platform=android, NULL apns_environment, package name, FCM token, station name, price, reason');
  perform pg_temp.expect((select status from private.price_alert_deliveries where id = v_ios) = 'processing'
                         and (select attempt_count from private.price_alert_deliveries where id = v_ios) = 1,
                         'X1 the android call did not re-claim or touch the iOS delivery');

  -- the iOS row's returned columns (re-claim by lapsing its lock)
  update private.price_alert_deliveries set locked_at = now() - interval '16 minutes' where id = v_ios;
  select c.* into r from private.claim_price_alert_deliveries_v2(100, 'ios') c;
  perform pg_temp.expect(r.delivery_id = v_ios and r.platform = 'ios' and r.apns_environment = 'sandbox'
                         and r.bundle_id = 'com.e85blends.app.ios.internal' and r.device_token = repeat('1', 64) and r.attempt_count = 2,
                         'X1 iOS row: platform=ios, APNs environment, bundle id, token; a lapsed processing row is re-claimed (attempt 2)');
end;
$$;
delete from private.price_alert_deliveries;

-- ==================================================================================================
-- X2/X3: the full per-platform matrix. Everything is created for BOTH platforms first, then the ios
-- call is made and the Android rows are asserted untouched, then the android call is made.
-- ==================================================================================================
create temp table t_del (label text primary key, platform text, delivery_id uuid, report_id uuid);

do $$
declare
  p text;
  r record;
  v_report uuid;
  v_del uuid;
  v_ok text;
  v_dis text;
  v_inv text;
begin
  foreach p in array array['ios','android'] loop
    v_ok := p || '_ok'; v_dis := p || '_dis'; v_inv := p || '_inv';
    for r in
      select * from (values
        ('fresh_pending',        interval '10 minutes',                    'pending',    interval '0',          null::interval,        0, 'ok'),
        ('stale_pending',        interval '3 hours',                       'pending',    interval '0',          null,                  0, 'ok'),
        ('stale_failed_due',     interval '3 hours',                       'failed',     interval '-5 minutes', null,                  1, 'ok'),
        ('stale_inflight',       interval '3 hours',                       'processing', interval '0',          interval '2 minutes',  1, 'ok'),
        ('stale_deadlock',       interval '3 hours',                       'processing', interval '0',          interval '20 minutes', 1, 'ok'),
        ('fresh_retry_future',   interval '10 minutes',                    'failed',     interval '1 hour',     null,                  1, 'ok'),
        ('fresh_failed_due',     interval '10 minutes',                    'failed',     interval '-1 minute',  null,                  1, 'ok'),
        ('fresh_lapsed_proc',    interval '10 minutes',                    'processing', interval '0',          interval '20 minutes', 1, 'ok'),
        ('fresh_inflight',       interval '10 minutes',                    'processing', interval '0',          interval '2 minutes',  1, 'ok'),
        ('exactly_2h',           interval '2 hours',                       'pending',    interval '0',          null,                  0, 'ok'),
        ('two_h_minus_1s',       interval '2 hours' - interval '1 second', 'pending',    interval '0',          null,                  0, 'ok'),
        ('two_h_plus_1s',        interval '2 hours' + interval '1 second', 'pending',    interval '0',          null,                  0, 'ok'),
        ('backdated_3d',         interval '3 days',                        'pending',    interval '0',          null,                  0, 'ok'),
        ('stale_sent',           interval '3 hours',                       'sent',       interval '0',          null,                  1, 'ok'),
        ('future_dated',         interval '-10 minutes',                   'pending',    interval '0',          null,                  0, 'ok'),
        ('fresh_dev_disabled',   interval '10 minutes',                    'pending',    interval '0',          null,                  0, 'dis'),
        ('fresh_dev_invalid',    interval '10 minutes',                    'pending',    interval '0',          null,                  0, 'inv'),
        ('fresh_dis_failed',     interval '10 minutes',                    'failed',     interval '-1 minute',  null,                  2, 'dis'),
        ('fresh_inv_deadlock',   interval '10 minutes',                    'processing', interval '0',          interval '20 minutes', 1, 'inv'),
        ('stale_and_disabled',   interval '3 hours',                       'pending',    interval '0',          null,                  0, 'dis'),
        ('stale_and_invalid',    interval '3 hours',                       'pending',    interval '0',          null,                  0, 'inv')
      ) as x(label, age, status, available, lock_age, attempts, dev)
    loop
      v_report := pg_temp.mk_report('station_a', r.age);
      v_del := pg_temp.mk_delivery(v_report, r.status,
                 case r.dev when 'ok' then v_ok when 'dis' then v_dis else v_inv end,
                 r.available, r.lock_age, r.attempts);
      insert into t_del values (p || ':' || r.label, p, v_del, v_report);
      -- the real enqueue trigger created a job for this report; model "job already picked up".
      update private.price_alert_jobs set status = 'processing', locked_at = now() - interval '1 minute'
      where price_report_id = v_report;
    end loop;
  end loop;
end;
$$;

create function pg_temp.st(p_label text) returns text language sql as $$
  select d.status || coalesce(':' || d.last_error_code, '') from private.price_alert_deliveries d
  join t_del t on t.delivery_id = d.id where t.label = p_label
$$;
create function pg_temp.att(p_label text) returns int language sql as $$
  select d.attempt_count from private.price_alert_deliveries d join t_del t on t.delivery_id = d.id where t.label = p_label
$$;
create function pg_temp.did(p_label text) returns uuid language sql as $$ select delivery_id from t_del where label = p_label $$;

-- snapshot of every Android row (status, error, attempts, lock) before the ios call
create temp table t_android_before as
select t.label, d.status, d.last_error_code, d.attempt_count, d.locked_at
from private.price_alert_deliveries d join t_del t on t.delivery_id = d.id where t.platform = 'android';

do $$
declare
  p text;
  v_claimed uuid[];
  v_n int;
begin
  foreach p in array array['ios','android'] loop
    select array_agg(c.delivery_id) into v_claimed from private.claim_price_alert_deliveries_v2(100, p) c;

    if p = 'ios' then
      -- the ios call must not have touched ANY Android row (sweep and claim are platform-scoped)
      perform pg_temp.expect(not exists (
        select 1 from t_android_before b
        join t_del t on t.label = b.label join private.price_alert_deliveries d on d.id = t.delivery_id
        where (d.status, d.last_error_code, d.attempt_count, d.locked_at) is distinct from (b.status, b.last_error_code, b.attempt_count, b.locked_at)),
        'X2 the ios call neither swept, expired, claimed nor otherwise modified any Android delivery');
    end if;

    -- claimed set: the sendable ones, exactly
    perform pg_temp.expect(pg_temp.did(p||':fresh_pending') = any (v_claimed), 'X2 ['||p||'] fresh pending claimed');
    perform pg_temp.expect(pg_temp.did(p||':fresh_failed_due') = any (v_claimed), 'X2 ['||p||'] fresh failed retry (due) claimed');
    perform pg_temp.expect(pg_temp.did(p||':fresh_lapsed_proc') = any (v_claimed), 'X2 ['||p||'] fresh processing row with a lapsed 15-minute lock re-claimed');
    perform pg_temp.expect(pg_temp.did(p||':exactly_2h') = any (v_claimed), 'X2 ['||p||'] a report EXACTLY 2 hours old is still sendable (inclusive boundary)');
    perform pg_temp.expect(pg_temp.did(p||':two_h_minus_1s') = any (v_claimed), 'X2 ['||p||'] 2 hours minus 1 second is sendable');
    perform pg_temp.expect(pg_temp.did(p||':future_dated') = any (v_claimed), 'X2 ['||p||'] a future-dated report is sendable');
    perform pg_temp.expect(coalesce(array_length(v_claimed, 1), 0) = 6, 'X2 ['||p||'] the call returns exactly the six sendable deliveries (got ' || coalesce(array_length(v_claimed, 1), 0) || ')');
    perform pg_temp.expect(pg_temp.att(p||':fresh_failed_due') = 2 and pg_temp.att(p||':fresh_lapsed_proc') = 2 and pg_temp.att(p||':fresh_pending') = 1,
                           'X7 ['||p||'] retries are re-attempted: failed-due and lapsed-processing rows get attempt+1, a new one gets attempt 1');

    -- stale -> terminal
    perform pg_temp.expect(pg_temp.st(p||':stale_pending') = 'skipped:stale_report', 'X2 ['||p||'] stale pending -> skipped/stale_report');
    perform pg_temp.expect(pg_temp.st(p||':stale_failed_due') = 'skipped:stale_report', 'X2 ['||p||'] stale failed -> skipped/stale_report');
    perform pg_temp.expect(pg_temp.st(p||':stale_deadlock') = 'skipped:stale_report', 'X2 ['||p||'] stale lapsed-processing -> skipped/stale_report');
    perform pg_temp.expect(pg_temp.st(p||':two_h_plus_1s') = 'skipped:stale_report', 'X2 ['||p||'] 2 hours + 1 second -> skipped/stale_report');
    perform pg_temp.expect(pg_temp.st(p||':backdated_3d') = 'skipped:stale_report', 'X2 ['||p||'] back-dated 3-day report -> skipped/stale_report');
    -- unusable device -> terminal, attempt not burned
    perform pg_temp.expect(pg_temp.st(p||':fresh_dev_disabled') = 'skipped:device_unusable', 'X2 ['||p||'] disabled device -> skipped/device_unusable');
    perform pg_temp.expect(pg_temp.st(p||':fresh_dev_invalid') = 'skipped:device_unusable', 'X2 ['||p||'] invalidated device -> skipped/device_unusable');
    perform pg_temp.expect(pg_temp.st(p||':fresh_dis_failed') = 'skipped:device_unusable' and pg_temp.att(p||':fresh_dis_failed') = 2,
                           'X2 ['||p||'] a retrying delivery whose device was later disabled is terminal, attempts NOT inflated');
    perform pg_temp.expect(pg_temp.st(p||':fresh_inv_deadlock') = 'skipped:device_unusable' and pg_temp.att(p||':fresh_inv_deadlock') = 1,
                           'X2 ['||p||'] a lapsed-processing delivery on an invalidated device is terminal, not re-claimed forever');
    perform pg_temp.expect(pg_temp.att(p||':fresh_dev_disabled') = 0 and pg_temp.att(p||':fresh_dev_invalid') = 0,
                           'X2 ['||p||'] unusable-device rows were never attempted');
    perform pg_temp.expect((select count(*) from private.price_alert_deliveries d join t_del t on t.delivery_id = d.id
                            where t.label in (p||':stale_deadlock', p||':fresh_inv_deadlock', p||':stale_pending') and d.locked_at is null) = 3,
                           'X2 ['||p||'] an expired delivery releases its lock (locked_at cleared) so it is plainly terminal');
    -- stale wins over unusable
    perform pg_temp.expect(pg_temp.st(p||':stale_and_disabled') = 'skipped:stale_report' and pg_temp.st(p||':stale_and_invalid') = 'skipped:stale_report',
                           'X2 ['||p||'] stale AND unusable-device -> stale_report (staleness wins)');
    -- untouched
    perform pg_temp.expect(pg_temp.st(p||':stale_inflight') = 'processing' and pg_temp.att(p||':stale_inflight') = 1,
                           'X2 ['||p||'] a fresh-locked in-flight send is never touched, even for an old report');
    perform pg_temp.expect(pg_temp.st(p||':fresh_inflight') = 'processing' and pg_temp.att(p||':fresh_inflight') = 1,
                           'X2 ['||p||'] a fresh-locked in-flight send is not re-claimed');
    perform pg_temp.expect(pg_temp.st(p||':fresh_retry_future') = 'failed', 'X2 ['||p||'] a not-yet-due retry is untouched');
    perform pg_temp.expect(pg_temp.st(p||':stale_sent') = 'sent', 'X2 ['||p||'] terminal rows are never rewritten');

    -- X3 jobs
    perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_del t on t.report_id = j.price_report_id where t.label = p||':stale_pending') = 'completed',
                           'X3 ['||p||'] the job finalizes once its only delivery is expired (stale)');
    perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_del t on t.report_id = j.price_report_id where t.label = p||':fresh_dev_disabled') = 'completed',
                           'X3 ['||p||'] the job finalizes once its only delivery is expired (device_unusable)');
    perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_del t on t.report_id = j.price_report_id where t.label = p||':fresh_pending') = 'processing',
                           'X3 ['||p||'] a job stays processing while its delivery is being sent');
    perform pg_temp.expect((select j.status from private.price_alert_jobs j join t_del t on t.report_id = j.price_report_id where t.label = p||':stale_inflight') = 'processing',
                           'X3 ['||p||'] a job stays processing while its delivery is in flight');

    -- idempotency
    select count(*) into v_n from private.claim_price_alert_deliveries_v2(100, p);
    perform pg_temp.expect(v_n = 0, 'X2 ['||p||'] an immediate second call returns nothing new');
  end loop;

  -- every row of both platforms accounted for: nothing is left pending/failed-due that should have moved
  perform pg_temp.expect(not exists (
    select 1 from private.price_alert_deliveries d join t_del t on t.delivery_id = d.id
    where d.status in ('pending') and t.label not like '%:fresh_retry_future'),
    'X2 no pending delivery is left behind on either platform');
end;
$$;

-- ==================================================================================================
-- X4: argument validation
-- ==================================================================================================
do $$
begin
  perform pg_temp.expect(pg_temp.raises($q$select * from private.claim_price_alert_deliveries_v2(0, 'ios')$q$), 'X4 p_limit 0 rejected');
  perform pg_temp.expect(pg_temp.raises($q$select * from private.claim_price_alert_deliveries_v2(101, 'ios')$q$), 'X4 p_limit 101 rejected');
  perform pg_temp.expect(pg_temp.raises($q$select * from private.claim_price_alert_deliveries_v2(null, 'ios')$q$), 'X4 NULL p_limit rejected');
  perform pg_temp.expect(pg_temp.raises($q$select * from private.claim_price_alert_deliveries_v2(10, 'web')$q$), 'X4 unknown platform rejected');
  perform pg_temp.expect(pg_temp.raises($q$select * from private.claim_price_alert_deliveries_v2(10, null)$q$), 'X4 NULL platform rejected');
  perform pg_temp.expect(not pg_temp.raises($q$select * from private.claim_price_alert_deliveries_v2()$q$), 'X4 the defaults (50, ios) still work');
  perform pg_temp.expect(pg_temp.raises($q$select * from private.claim_price_alert_deliveries(0)$q$), 'X4 v1 p_limit 0 rejected');
end;
$$;

-- ==================================================================================================
-- X5: v1 compatibility wrapper
-- ==================================================================================================
delete from private.price_alert_deliveries;
create temp table t_x5 (label text primary key, delivery_id uuid);
do $$
declare
  v_ios uuid := pg_temp.mk_delivery(pg_temp.mk_report('station_n', interval '5 minutes'), 'pending', 'ios_ok');
  v_ios_stale uuid := pg_temp.mk_delivery(pg_temp.mk_report('station_n', interval '3 hours'), 'pending', 'ios_ok');
  v_and uuid := pg_temp.mk_delivery(pg_temp.mk_report('station_n', interval '5 minutes'), 'pending', 'android_ok');
  v_and_stale uuid := pg_temp.mk_delivery(pg_temp.mk_report('station_n', interval '3 hours'), 'pending', 'android_ok');
  v_ids uuid[];
  r record;
begin
  perform pg_temp.expect(pg_get_function_result('private.claim_price_alert_deliveries(integer)'::regprocedure) =
    'TABLE(delivery_id uuid, alert_id uuid, price_report_id uuid, push_device_id uuid, station_id uuid, station_name text, device_token text, apns_environment text, bundle_id text, observed_price numeric, previous_price numeric, reason_code text, attempt_count integer)',
    'X5 v1 keeps its original 13-column return shape');
  select array_agg(c.delivery_id) into v_ids from private.claim_price_alert_deliveries(100) c;
  perform pg_temp.expect(v_ids = array[v_ios], 'X5 v1 returns only the fresh iOS delivery (got ' || coalesce(v_ids::text, 'none') || ')');
  perform pg_temp.expect((select status from private.price_alert_deliveries where id = v_and) = 'pending'
                         and (select attempt_count from private.price_alert_deliveries where id = v_and) = 0
                         and (select status from private.price_alert_deliveries where id = v_and_stale) = 'pending',
                         'X5 v1 never returns or touches Android deliveries (fresh or stale)');
  perform pg_temp.expect((select status || ':' || last_error_code from private.price_alert_deliveries where id = v_ios_stale) = 'skipped:stale_report',
                         'X5 v1 expires stale iOS deliveries (safety logic is shared with v2)');
  select * into r from private.claim_price_alert_deliveries(100) limit 1;
  perform pg_temp.expect(r is null, 'X5 v1 second call returns nothing');
  -- the android rows are still claimable by v2
  select array_agg(c.delivery_id) into v_ids from private.claim_price_alert_deliveries_v2(100, 'android') c;
  perform pg_temp.expect(v_ids = array[v_and], 'X5 the Android delivery is claimed by v2(android) afterwards; the stale Android one is not');
end;
$$;

-- ==================================================================================================
-- X6: bounded sweep per platform, fresh rows behind a stale backlog, platform budgets independent
-- ==================================================================================================
delete from private.price_alert_deliveries;
create temp table t_stale (delivery_id uuid primary key, platform text);
create temp table t_returned (platform text, delivery_id uuid);
create temp table t_fresh (delivery_id uuid primary key, platform text);

do $$
declare
  i int;
  v_id uuid;
begin
  for i in 1..1200 loop
    v_id := pg_temp.mk_delivery(pg_temp.mk_report('station_n', make_interval(hours => 3, mins => i % 50)), 'pending', 'ios_ok');
    insert into t_stale values (v_id, 'ios');
  end loop;
  for i in 1..700 loop
    v_id := pg_temp.mk_delivery(pg_temp.mk_report('station_n', make_interval(hours => 3, mins => i % 50)), 'pending', 'android_ok');
    insert into t_stale values (v_id, 'android');
  end loop;
  for i in 1..3 loop
    v_id := pg_temp.mk_delivery(pg_temp.mk_report('station_n', make_interval(mins => i)), 'pending', 'ios_ok');
    insert into t_fresh values (v_id, 'ios');
    v_id := pg_temp.mk_delivery(pg_temp.mk_report('station_n', make_interval(mins => i)), 'pending', 'android_ok');
    insert into t_fresh values (v_id, 'android');
  end loop;
end;
$$;

do $$
declare
  n int;
begin
  insert into t_returned select 'ios', delivery_id from private.claim_price_alert_deliveries_v2(100, 'ios');
  select count(*) into n from private.price_alert_deliveries d join t_stale s on s.delivery_id = d.id where s.platform = 'ios' and d.status = 'skipped';
  perform pg_temp.expect(n = 500, 'X6 the first ios call expires EXACTLY 500 of 1200 stale iOS rows (got ' || n || ')');
  select count(*) into n from private.price_alert_deliveries d join t_stale s on s.delivery_id = d.id where s.platform = 'android' and d.status <> 'pending';
  perform pg_temp.expect(n = 0, 'X6 the ios call did not spend any of its budget on (or touch) the 700 stale Android rows');
  perform pg_temp.expect((select count(*) from t_returned r join t_fresh f on f.delivery_id = r.delivery_id and f.platform = 'ios') = 3
                         and (select count(*) from t_returned) = 3,
                         'X6 the 3 fresh iOS deliveries flow while a stale backlog exists, and nothing else is returned');
  select count(*) into n from private.price_alert_deliveries d join t_stale s on s.delivery_id = d.id where s.platform = 'ios' and d.status = 'pending' and d.attempt_count = 0;
  perform pg_temp.expect(n = 700, 'X6 the 700 not-yet-swept stale iOS rows are untouched (pending, never attempted)');

  insert into t_returned select 'android', delivery_id from private.claim_price_alert_deliveries_v2(100, 'android');
  select count(*) into n from private.price_alert_deliveries d join t_stale s on s.delivery_id = d.id where s.platform = 'android' and d.status = 'skipped';
  perform pg_temp.expect(n = 500, 'X6 the first android call expires EXACTLY 500 of 700 stale Android rows (got ' || n || ')');
  select count(*) into n from private.price_alert_deliveries d join t_stale s on s.delivery_id = d.id where s.platform = 'ios' and d.status = 'skipped';
  perform pg_temp.expect(n = 500, 'X6 the android call did not touch the iOS backlog (still 500 expired)');
  perform pg_temp.expect((select count(*) from t_returned r join t_fresh f on f.delivery_id = r.delivery_id and f.platform = 'android') = 3,
                         'X6 the 3 fresh Android deliveries flow while an Android stale backlog exists');
  perform pg_temp.expect(not exists (select 1 from t_returned r join t_stale s on s.delivery_id = r.delivery_id),
                         'X6 NO stale delivery was returned on either platform while the backlogs were only partially drained');

  -- drain: iOS 500 + 200, Android 200
  insert into t_returned select 'ios', delivery_id from private.claim_price_alert_deliveries_v2(100, 'ios');
  insert into t_returned select 'ios', delivery_id from private.claim_price_alert_deliveries_v2(100, 'ios');
  insert into t_returned select 'android', delivery_id from private.claim_price_alert_deliveries_v2(100, 'android');
  select count(*) into n from private.price_alert_deliveries d join t_stale s on s.delivery_id = d.id where d.status = 'skipped' and d.last_error_code = 'stale_report';
  perform pg_temp.expect(n = 1900, 'X6 both backlogs drain incrementally to 1200 + 700 stale_report rows (got ' || n || ')');
  perform pg_temp.expect(not exists (select 1 from t_returned r join t_stale s on s.delivery_id = r.delivery_id),
                         'X6 across every call, no stale delivery was ever sendable');
  perform pg_temp.expect((select count(*) from t_returned) = 6, 'X6 and nothing but the 6 fresh deliveries was ever returned');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries d join t_fresh f on f.delivery_id = d.id where d.status = 'processing' and d.attempt_count = 1) = 6,
                         'X6 each fresh delivery was claimed exactly once');
end;
$$;

-- X6b: a partially drained backlog of UNUSABLE-DEVICE deliveries (fresh reports) is never returned and
-- never burns an attempt, per platform: the claim predicate excludes unusable devices on its own.
delete from private.price_alert_deliveries;
create temp table t_unusable (delivery_id uuid primary key, platform text, usable boolean);
create temp table t_u_returned (platform text, delivery_id uuid);
do $$
declare
  i int;
  p text;
  v_id uuid;
  n int;
begin
  foreach p in array array['ios','android'] loop
    for i in 1..1200 loop
      v_id := pg_temp.mk_delivery(pg_temp.mk_report('station_n', interval '10 minutes'), 'pending', p || case when i % 2 = 0 then '_dis' else '_inv' end);
      insert into t_unusable values (v_id, p, false);
    end loop;
    v_id := pg_temp.mk_delivery(pg_temp.mk_report('station_n', interval '10 minutes'), 'pending', p || '_ok');
    insert into t_unusable values (v_id, p, true);
  end loop;

  foreach p in array array['ios','android'] loop
    insert into t_u_returned select p, delivery_id from private.claim_price_alert_deliveries_v2(100, p);
    select count(*) into n from private.price_alert_deliveries d join t_unusable u on u.delivery_id = d.id
      where u.platform = p and d.status = 'skipped' and d.last_error_code = 'device_unusable';
    perform pg_temp.expect(n = 500, 'X6b [' || p || '] one call expires EXACTLY 500 of 1200 unusable-device rows (600 disabled + 600 invalidated) (got ' || n || ')');
    perform pg_temp.expect(not exists (select 1 from t_u_returned r join t_unusable u on u.delivery_id = r.delivery_id where not u.usable),
                           'X6b [' || p || '] no unusable-device delivery is returned while the backlog is only partially drained');
    perform pg_temp.expect((select count(*) from t_u_returned r where r.platform = p) = 1,
                           'X6b [' || p || '] only the one usable delivery is returned');
    perform pg_temp.expect((select count(*) from private.price_alert_deliveries d join t_unusable u on u.delivery_id = d.id
                            where u.platform = p and not u.usable and (d.status = 'processing' or d.attempt_count > 0)) = 0,
                           'X6b [' || p || '] nothing in the unusable backlog was flipped to processing / had an attempt burned');
  end loop;

  -- the next calls finish the drain (500 + 200 per platform); still only the two usable deliveries were ever returned
  for i in 1..2 loop
    insert into t_u_returned select 'ios', delivery_id from private.claim_price_alert_deliveries_v2(100, 'ios');
    insert into t_u_returned select 'android', delivery_id from private.claim_price_alert_deliveries_v2(100, 'android');
  end loop;
  select count(*) into n from private.price_alert_deliveries d join t_unusable u on u.delivery_id = d.id
    where not u.usable and d.status = 'skipped' and d.last_error_code = 'device_unusable';
  perform pg_temp.expect(n = 2400, 'X6b both unusable backlogs fully drained to terminal device_unusable (got ' || n || ')');
  perform pg_temp.expect((select count(*) from t_u_returned) = 2 and not exists (select 1 from t_u_returned r join t_unusable u on u.delivery_id = r.delivery_id where not u.usable),
                         'X6b exactly the two usable deliveries (one per platform) were ever returned');
end;
$$;

-- ==================================================================================================
-- X8: chain state, grants, idempotent re-apply
-- ==================================================================================================
do $$
declare
  f text;
begin
  perform pg_temp.expect(to_regprocedure('private.invoke_price_alerts_worker()') is not null, 'X8 the scheduler function exists');
  perform pg_temp.expect(to_regclass('private.price_alert_jobs_stuck_processing_idx') is not null, 'X8 the stuck-processing index exists');
  perform pg_temp.expect((select count(*) from pg_indexes where schemaname = 'private' and tablename = 'price_alert_jobs'
                           and indexdef ~ '\(locked_at\)' and indexdef ~ 'processing') = 1,
                         'X8 exactly one partial index on price_alert_jobs(locked_at) WHERE processing (no duplicate/incompatible index)');
  perform pg_temp.expect((select count(*) from cron.job where jobname = '85blends-price-alerts-worker-invoke') = 1, 'X8 the worker cron job exists exactly once');
  perform pg_temp.expect((select active from cron.job where jobname = '85blends-price-alerts-worker-invoke') = false, 'X8 the worker cron job is INACTIVE');
  perform pg_temp.expect((select schedule || '|' || command from cron.job where jobname = '85blends-price-alerts-worker-invoke') = '* * * * *|select private.invoke_price_alerts_worker();',
                         'X8 the worker cron job schedule/command are as reviewed (no secret in the command)');
  perform pg_temp.expect((select count(*) from cron.job where jobname = '85blends-price-alert-job-prepare' and active) = 1, 'X8 the job-prepare cron job is untouched and active');

  foreach f in array array[
    'private.claim_price_alert_deliveries_v2(integer,text)', 'private.claim_price_alert_deliveries(integer)',
    'private.claim_price_alert_jobs(integer)', 'private.invoke_price_alerts_worker()'
  ] loop
    perform pg_temp.expect(not has_function_privilege('anon', f, 'execute'), 'X8 anon cannot execute ' || f);
    perform pg_temp.expect(not has_function_privilege('authenticated', f, 'execute'), 'X8 authenticated cannot execute ' || f);
    perform pg_temp.expect((select not exists (select 1 from aclexplode(coalesce(proacl, acldefault('f', proowner))) a where a.grantee = 0)
                            from pg_proc where oid = f::regprocedure), 'X8 PUBLIC cannot execute ' || f);
  end loop;
  perform pg_temp.expect(not has_function_privilege('service_role', 'private.claim_price_alert_deliveries_v2(integer,text)', 'execute'),
                         'X8 v2 stays postgres-only (as in production: the worker connects as postgres)');
  perform pg_temp.expect(has_function_privilege('service_role', 'private.claim_price_alert_deliveries(integer)', 'execute'),
                         'X8 v1 keeps its service_role execute (unchanged)');

  foreach f in array array[
    'private.claim_price_alert_deliveries_v2(integer,text)', 'private.claim_price_alert_deliveries(integer)',
    'private.claim_price_alert_jobs(integer)', 'private.invoke_price_alerts_worker()'
  ] loop
    perform pg_temp.expect((select p.prosecdef and coalesce(p.proconfig, '{}') @> array['search_path=""'] from pg_proc p where p.oid = f::regprocedure),
                           'X8 ' || f || ' is SECURITY DEFINER with search_path pinned to the empty path');
  end loop;

  -- a stale processing job with no deliveries is still reclaimed; one waiting on a delivery is not
  perform pg_temp.expect((select prosrc from pg_proc where oid = 'private.claim_price_alert_jobs(integer)'::regprocedure) ~ 'attempt_count < 5',
                         'X8 claim_price_alert_jobs carries the stale-job reclaim (attempt_count < 5)');
end;
$$;

-- stale-job reclaim behavior on the final chain
do $$
declare
  v_a uuid := pg_temp.mk_report('station_n', interval '1 minute');
  v_b uuid := pg_temp.mk_report('station_n', interval '1 minute');
  v_ids uuid[];
begin
  insert into private.price_alert_jobs (price_report_id, status, attempt_count, locked_at) values (v_a, 'processing', 1, now() - interval '16 minutes');
  insert into private.price_alert_jobs (price_report_id, status, attempt_count, locked_at) values (v_b, 'processing', 1, now() - interval '16 minutes');
  perform pg_temp.mk_delivery(v_b, 'pending', 'ios_ok');   -- waiting on a live delivery: must never be reclaimed
  select array_agg(c.price_report_id) into v_ids from private.claim_price_alert_jobs(100) c;
  perform pg_temp.expect(v_a = any (v_ids) and not (v_b = any (v_ids)),
                         'X8 final chain: a stuck processing job is reclaimed, one waiting on a pending delivery is not');
end;
$$;

-- idempotent re-apply of this migration changes nothing
create temp table t_before as
select p.oid::regprocedure::text as fn, md5(pg_get_functiondef(p.oid)) as h, p.proacl::text as acl
from pg_proc p where p.oid in ('private.claim_price_alert_deliveries_v2(integer,text)'::regprocedure, 'private.claim_price_alert_deliveries(integer)'::regprocedure);
\ir ../migrations/20261005233000_price_alert_cross_platform_delivery_safety.sql
do $$
begin
  perform pg_temp.expect(not exists (
    select 1 from t_before b join pg_proc p on p.oid = b.fn::regprocedure
    where md5(pg_get_functiondef(p.oid)) <> b.h or p.proacl::text is distinct from b.acl),
    'X8 re-applying the migration leaves both claim functions and their ACLs byte-identical');
  perform pg_temp.expect((select count(*) from cron.job where jobname = '85blends-price-alerts-worker-invoke') = 1
                         and (select active from cron.job where jobname = '85blends-price-alerts-worker-invoke') = false,
                         'X8 re-applying the migration neither duplicates nor activates the worker cron job');
end;
$$;

rollback;

\echo ALL PRICE ALERT CROSS-PLATFORM DELIVERY-SAFETY SCENARIOS PASSED

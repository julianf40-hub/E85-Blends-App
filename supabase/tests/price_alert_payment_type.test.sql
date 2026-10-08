-- 85Blends 2.4.1 — Phase 3C payment-aware Price Alerts regression matrix.
-- Covers supabase/migrations/20261007120000_community_price_payment_type.sql (migration A) and
-- 20261007130000_price_alert_payment_aware_evaluation.sql (migration B).
--
-- LOCAL-REPLAY ONLY (see README.md in this directory): run it with psql from any directory against a
-- scratch database that already has the FULL migration chain applied. One transaction, rolled back at
-- the end; it RAISEs on any unexpected outcome, and reaching the final \echo line is a full pass.
-- It never connects anywhere else and sends nothing (pg_net is a recording stand-in locally).
--
-- Scenarios that need MORE THAN ONE session live in price_alert_payment_type_concurrency.test.sh; the
-- before/after-migration data-preservation checks live in price_alert_payment_type_migration.test.sh.
--
-- WHAT THIS COVERS
--   R1  reports: legacy shape (column omitted) stores 'unknown'; cash / credit / same_for_both store as
--       sent; an unrecognised value is refused by the CHECK; anon AND authenticated may name the column
--       (column-scoped grant extended) and still cannot name id/created_at, update or delete; the INSERT
--       policy still bounds price, reporter and reported_at for typed reports; the rate limiter still counts.
--   C1  comparability: cash<-{cash,same_for_both}, credit<-{credit,same_for_both}, unknown<-{unknown},
--       anything else (incl. NULL, bogus values) is NOT comparable.
--   E1  the pure decision function, mode by mode: price drop presets (5c/10c/20c/custom bounds 0.01 and
--       2.00), exact boundaries, no precision loss, cumulative drops, rises moving the reference, cooldown
--       keeping the alert armed, stale reports, stale/absent baseline, at_or_below crossing/met/changed/
--       unchanged/equal-to-threshold, any_change, invalid inputs.
--   D1  the user's headline example: Credit 3.19 baseline, Cash 2.99 -> NO credit alert; Credit 3.14 -> none;
--       Credit 3.09 -> alert (cumulative 10c).  D2 at_or_below uses the selected method; same_for_both
--       qualifies for either; unknown never reaches a payment-specific alert.  D3 type switching never
--       manufactures a drop (rapid alternating cash/credit).  D4 legacy (unknown) alerts only see unknown.
--   D5  out-of-order / late / backlog: only the newest comparable report decides; older ones are 'superseded'
--       and move nothing.  D6 repeated and unchanged prices never re-alert.  D7 cooldown: suppression keeps the
--       alert armed, expiry re-fires, and two reports prepared before the first is SENT cannot both notify.
--   D8  rearm after firing, rises, falls from a new high.  D9 missing baseline is established, never invented;
--       stale baseline re-anchors without notifying; stale report never notifies.  D10 Pro gate preserved
--       (no rows, no state change, alerts not deleted).  D11 devices: one row per ACTIVE device, none for
--       disabled/invalidated.  D12 idempotence: re-preparing a report decides nothing twice.  D13 fail closed
--       on an unrecognised report value.  D14 anchor trigger rules.  D15 deliveries record the alert's method.
--   D16 the exact set_alert upsert (incl. an older client).  D17 list_alerts: legacy latest vs comparable latest.
--   D18 a same_for_both report drives a PRICE DROP alert of either method (cumulatively) and never reaches a
--       legacy (unknown) alert.
--   D19 the documented fail-closed PAUSE (rollout doc, "Rollback / fail-closed"): a no-op prepare decides nothing and
--       queues nothing, keeps its ACL, and re-applying migration B puts the real engine back.
--   D20 a queued notification that ends UNSENT (dead) does not hold the cooldown, for price_drop and for at_or_below.
--   D21 a notification delivered after the person switched the alert's payment method does not write its price into the
--       alert.  D22 a notification queued BEFORE migration B (no payment_type) still holds a legacy alert's cooldown.
--   D23 a notification queued under the OTHER payment method does not hold the new method's cooldown.
--   D24 prepare takes the station-level advisory lock (the lock-order guard; the race itself is PC5 in the concurrency script).
--   D25 (Phase 3C.1) an OLDER client's save keeps a drop size the newer app chose and the engine keeps using it, while a client
--       that declared the contract can still deliberately choose 5 cents; a payment-only edit leaves the drop size alone.
--   D26 (Phase 3C.1) repeated identical saves are safe; harmless edits leave the reference, the notification memory and the
--       cooldown alone; a change of mode or method keeps the notification TIME and forgets the old notified price.
--   D27 (Phase 3C.1) moving a LEGACY alert to Cash / Credit through the real upsert: only the method changes, the reference is
--       re-anchored to the new method's own stream (or left empty), an unclassified report no longer reaches it.
--   G1  grants/ACL of the new internals and index/plan sanity; migration re-apply is a no-op.

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

-- ==================================================================================================
-- Fixtures
-- ==================================================================================================
-- A "world" is one station + one Pro installation + N devices; alerts and reports are added per scenario.
-- Every scenario uses its own station, so reports never leak between scenarios.
create temp table t_world (
  label text primary key,
  station_id uuid not null,
  installation_id uuid not null,
  device_ids uuid[] not null default '{}'
);

insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active)
values ('$RCAnonymousID:payment-type-test', 'SANDBOX', 'pro', true),
       ('$RCAnonymousID:payment-type-test-free', 'SANDBOX', 'pro', false);

create function pg_temp.mk_world(p_label text, p_devices int default 1, p_pro boolean default true)
returns void language plpgsql as $$
declare
  v_station uuid;
  v_inst uuid;
  v_devices uuid[] := '{}';
  v_dev uuid;
  i int;
begin
  insert into public.community_stations (name, normalized_key)
  values ('Payment Test ' || p_label, 'payment-test-' || p_label) returning id into v_station;

  insert into private.price_alert_installations
    (client_installation_id, installation_secret_hash, revenuecat_app_user_id, revenuecat_environment, revenuecat_customer_id)
  select gen_random_uuid(), repeat('a', 64),
         c.original_app_user_id, 'SANDBOX', c.id
  from private.revenuecat_customers c
  where c.original_app_user_id = case when p_pro then '$RCAnonymousID:payment-type-test'
                                      else '$RCAnonymousID:payment-type-test-free' end
  returning id into v_inst;

  for i in 1 .. p_devices loop
    insert into private.price_alert_push_devices
      (installation_id, bundle_id, apns_environment, device_token, device_token_hash, enabled, invalidated_at)
    values (v_inst, 'com.e85blends.app.ios.internal.' || i::text, 'sandbox',
            md5(p_label || i::text) || md5(p_label || i::text), md5(p_label || i::text) || md5(p_label || i::text), true, null)
    returning id into v_dev;
    v_devices := v_devices || v_dev;
  end loop;

  insert into t_world values (p_label, v_station, v_inst, v_devices);
end;
$$;

create function pg_temp.report(p_world text, p_payment text, p_price numeric, p_age interval default interval '1 minute',
                               p_reporter text default 'payment-test-reporter')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
  values ((select station_id from t_world where label = p_world), p_price, now() - p_age, p_reporter, p_payment)
  returning id into v_id;
  return v_id;
end;
$$;

create function pg_temp.mk_alert(p_world text, p_payment text, p_mode text default 'price_drop',
                                 p_threshold numeric default null, p_min numeric default 0.100,
                                 p_cooldown int default 360)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into private.price_alerts (installation_id, station_id, alert_mode, threshold_price, minimum_change,
                                    cooldown_minutes, payment_type)
  values ((select installation_id from t_world where label = p_world),
          (select station_id from t_world where label = p_world),
          p_mode, p_threshold, p_min, p_cooldown, p_payment)
  returning id into v_id;
  return v_id;
end;
$$;

-- Prepare one report; returns "pending/skipped".
create function pg_temp.prep(p_report uuid) returns text language plpgsql as $$
declare v_p int; v_s int;
begin
  select pending_count, skipped_count into v_p, v_s from private.prepare_price_alert_deliveries(p_report);
  return v_p || '/' || v_s;
end;
$$;

-- Reason and status recorded for (alert, report) on its first device row.
create function pg_temp.verdict(p_alert uuid, p_report uuid) returns text language sql as $$
  select d.status || ':' || coalesce(d.reason_code, '')
  from private.price_alert_deliveries d
  where d.alert_id = p_alert and d.price_report_id = p_report
  order by d.push_device_id limit 1
$$;

create function pg_temp.baseline(p_alert uuid) returns numeric language sql as $$
  select baseline_price from private.price_alerts where id = p_alert
$$;

-- The worker delivers every notification queued for an alert (claim -> processing -> the real mark_sent, which stamps the
-- alert's notification memory), and then the clock moves p_ago past the send (the stamp is back-dated). This is how a
-- scenario lets a cooldown run out: a queued, not-yet-sent delivery holds the cooldown, a sent one is measured from its send.
create function pg_temp.deliver(p_alert uuid, p_ago interval) returns void language plpgsql as $$
declare d record;
begin
  for d in select id from private.price_alert_deliveries where alert_id = p_alert and status = 'pending' loop
    update private.price_alert_deliveries set status = 'processing', attempt_count = attempt_count + 1, locked_at = now() where id = d.id;
    perform private.mark_price_alert_delivery_sent(d.id, 200);
  end loop;
  update private.price_alerts set last_notified_at = now() - p_ago where id = p_alert and last_notified_at is not null;
end;
$$;

-- The worker gives up on every notification queued for an alert: the fifth attempt is in flight and fails, so the
-- delivery ends 'dead' and nothing is ever sent (an APNs / FCM outage, a provider that is not configured, ...).
create function pg_temp.give_up(p_alert uuid) returns void language plpgsql as $$
declare d record;
begin
  for d in select id from private.price_alert_deliveries where alert_id = p_alert and status = 'pending' loop
    update private.price_alert_deliveries set status = 'processing', attempt_count = 5, locked_at = now() where id = d.id;
    perform private.mark_price_alert_delivery_failed(d.id, 503, 'ServiceUnavailable', true, false, 5);
  end loop;
end;
$$;

-- Decision-function shorthand: (mode, threshold, min, cooldown, observed, baseline, age, last_price, last_at, can_notify)
create function pg_temp.ev(p_mode text, p_thr numeric, p_min numeric, p_cool int, p_obs numeric,
                           p_base numeric, p_age interval, p_lastp numeric, p_lasta timestamptz,
                           p_can boolean default true)
returns text language sql as $$
  select e.should_notify::text || ':' || e.reason_code || ':' || coalesce(e.new_baseline_price::text, 'null')
  from private.evaluate_price_alert_v2(p_mode, p_thr, p_min, p_cool, p_obs, p_base, p_age, p_lastp, p_lasta, now(), p_can) e
$$;

-- ==================================================================================================
-- R1: reports table - legacy shape, typed shape, grants, RLS
-- ==================================================================================================
select pg_temp.mk_world('r1');
do $$
declare
  v_station uuid := (select station_id from t_world where label = 'r1');
  v_id uuid;
  v_before int;
  i int;
begin
  -- column present, NOT NULL, default 'unknown', CHECK present and validated
  perform pg_temp.expect((select is_nullable = 'NO' and column_default like '%unknown%'
                          from information_schema.columns
                          where table_schema = 'public' and table_name = 'e85_price_reports' and column_name = 'payment_type'),
                         'R1a payment_type is NOT NULL default unknown');
  perform pg_temp.expect((select convalidated from pg_constraint
                          where conname = 'e85_price_reports_payment_type_check'), 'R1b CHECK exists and is validated');

  -- every value, as the Data API roles (anon, authenticated) would write it
  perform set_config('request.jwt.claim.role', 'anon', true);
  set local role anon;
  insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, app_version)
  values (v_station, 3.10, now(), 'r1-old-client', '2.4.0') returning id into v_id;       -- legacy: column omitted
  reset role;
  perform pg_temp.expect((select payment_type from public.e85_price_reports where id = v_id) = 'unknown',
                         'R1c an older client (column omitted) stores unknown, nothing guessed');

  set local role anon;
  insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
  values (v_station, 2.99, now(), 'r1-anon', 'cash');
  insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
  values (v_station, 3.09, now(), 'r1-anon', 'credit');
  insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
  values (v_station, 3.05, now(), 'r1-anon', 'same_for_both');
  reset role;
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  set local role authenticated;
  insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
  values (v_station, 3.15, now(), 'r1-auth', 'credit');
  reset role;
  perform pg_temp.expect((select count(*) from public.e85_price_reports where station_id = v_station
                          and payment_type in ('cash', 'credit', 'same_for_both')) = 4,
                         'R1d anon and authenticated can write cash / credit / same_for_both');

  -- unrecognised and sloppy values are refused, as anon (CHECK applies to every writer)
  perform set_config('request.jwt.claim.role', 'anon', true);
  set local role anon;
  perform pg_temp.expect(pg_temp.raises($q$ insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
    values ('$q$ || v_station || $q$', 3.00, now(), 'r1-bad', 'debit') $q$), 'R1e an unrecognised value is refused');
  perform pg_temp.expect(pg_temp.raises($q$ insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
    values ('$q$ || v_station || $q$', 3.00, now(), 'r1-bad', 'Cash') $q$), 'R1f case matters: Cash is refused');
  perform pg_temp.expect(pg_temp.raises($q$ insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
    values ('$q$ || v_station || $q$', 3.00, now(), 'r1-bad', NULL) $q$), 'R1g an explicit NULL is refused (NOT NULL)');

  -- the hardening that was already there is intact
  perform pg_temp.expect(pg_temp.raises($q$ insert into public.e85_price_reports (id, station_id, price, reported_at, anonymous_reporter_id)
    values (gen_random_uuid(), '$q$ || v_station || $q$', 3.00, now(), 'r1-bad') $q$), 'R1h clients still cannot name id');
  perform pg_temp.expect(pg_temp.raises($q$ insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, created_at)
    values ('$q$ || v_station || $q$', 3.00, now(), 'r1-bad', now()) $q$), 'R1i clients still cannot name created_at');
  perform pg_temp.expect(pg_temp.raises($q$ update public.e85_price_reports set payment_type = 'cash' where anonymous_reporter_id = 'r1-anon' $q$),
                         'R1j reports stay immutable: no UPDATE');
  perform pg_temp.expect(pg_temp.raises($q$ delete from public.e85_price_reports where anonymous_reporter_id = 'r1-anon' $q$),
                         'R1k reports stay immutable: no DELETE');
  -- RLS policy still bounds a typed report
  perform pg_temp.expect(pg_temp.raises($q$ insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
    values ('$q$ || v_station || $q$', 9.99, now(), 'r1-bad', 'cash') $q$), 'R1l price bound still enforced for typed reports');
  perform pg_temp.expect(pg_temp.raises($q$ insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
    values ('$q$ || v_station || $q$', 3.00, now() - interval '8 days', 'r1-bad', 'cash') $q$), 'R1m reported_at window still enforced');
  perform pg_temp.expect(pg_temp.raises($q$ insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
    values ('$q$ || v_station || $q$', 3.00, now(), '   ', 'cash') $q$), 'R1n blank reporter still refused');
  -- and the typed rows are readable by clients (SELECT is table-wide)
  perform pg_temp.expect((select count(*) from public.e85_price_reports where station_id = v_station and payment_type = 'cash') = 1,
                         'R1o clients can read payment_type');
  reset role;

  -- the rate limiter still counts typed rows (30 per hour per reporter, 12 per station)
  perform set_config('request.jwt.claim.role', 'anon', true);
  set local role anon;
  for i in 1 .. 12 loop
    insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
    values (v_station, 3.00, now(), 'r1-rate', 'credit');
  end loop;
  perform pg_temp.expect(pg_temp.raises($q$ insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
    values ('$q$ || v_station || $q$', 3.00, now(), 'r1-rate', 'cash') $q$), 'R1p the 12-per-station-per-hour limit still applies to typed reports');
  reset role;
  perform set_config('request.jwt.claim.role', '', true);
end;
$$;

-- ==================================================================================================
-- C1: comparability
-- ==================================================================================================
do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('cash',    'cash',          true),  ('cash',    'same_for_both', true),  ('cash',    'credit',  false),
      ('cash',    'unknown',       false), ('cash',    'debit',         false), ('cash',    null,      false),
      ('credit',  'credit',        true),  ('credit',  'same_for_both', true),  ('credit',  'cash',    false),
      ('credit',  'unknown',       false), ('credit',  'Credit',        false),
      ('unknown', 'unknown',       true),  ('unknown', 'same_for_both', false), ('unknown', 'cash',    false),
      ('unknown', 'credit',        false),
      ('bogus',   'cash',          false), ('bogus',   'unknown',       false), (null,      'cash',    false),
      (null,      null,            false)
    ) v(alert_pt, report_pt, expected)
  loop
    perform pg_temp.expect(private.payment_type_is_comparable(r.alert_pt, r.report_pt) = r.expected,
      format('C1 comparable(%L, %L) = %s', r.alert_pt, r.report_pt, r.expected));
  end loop;
  perform pg_temp.expect(private.comparable_report_types('cash') = array['cash', 'same_for_both'], 'C1 cash types');
  perform pg_temp.expect(private.comparable_report_types('credit') = array['credit', 'same_for_both'], 'C1 credit types');
  perform pg_temp.expect(private.comparable_report_types('unknown') = array['unknown'], 'C1 unknown types');
  perform pg_temp.expect(cardinality(private.comparable_report_types('anything else')) = 0, 'C1 fail closed: no types');
end;
$$;

-- ==================================================================================================
-- E1: the pure decision function
-- ==================================================================================================
do $$
declare
  v_old interval := interval '2 hours';
  v_h interval := interval '1 hour';
begin
  -- price_drop: presets and exact boundaries -------------------------------------------------------
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.09, 3.19, v_old, null, null) = 'true:price_dropped:3.09', 'E1 10c: exactly 10c qualifies');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.091, 3.19, v_old, null, null) = 'false:no_meaningful_drop:3.19', 'E1 10c: 9.9c does not (no precision loss)');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.050, 360, 3.14, 3.19, v_old, null, null) = 'true:price_dropped:3.14', 'E1 5c preset: exactly 5c qualifies');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.050, 360, 3.15, 3.19, v_old, null, null) = 'false:no_meaningful_drop:3.19', 'E1 5c preset: 4c does not');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.200, 360, 2.99, 3.19, v_old, null, null) = 'true:price_dropped:2.99', 'E1 20c preset: exactly 20c qualifies');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.200, 360, 3.00, 3.19, v_old, null, null) = 'false:no_meaningful_drop:3.19', 'E1 20c preset: 19c does not');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.010, 360, 3.18, 3.19, v_old, null, null) = 'true:price_dropped:3.18', 'E1 custom lower bound 0.01');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 2.000, 360, 1.19, 3.19, v_old, null, null) = 'true:price_dropped:1.19', 'E1 custom upper bound 2.00 (exact)');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 2.000, 360, 1.20, 3.19, v_old, null, null) = 'false:no_meaningful_drop:3.19', 'E1 custom upper bound 2.00 (just short)');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.123, 360, 3.067, 3.19, v_old, null, null) = 'true:price_dropped:3.067', 'E1 three-decimal custom value is exact');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, null, 360, 3.14, 3.19, v_old, null, null) = 'true:price_dropped:3.14', 'E1 missing minimum falls back to the legacy 5c...');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, null, 360, 3.15, 3.19, v_old, null, null) = 'false:no_meaningful_drop:3.19', 'E1 ...so a 4c drop does not qualify (the fallback is never 0)');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0, 360, 3.19, 3.19, v_old, null, null) = 'false:no_meaningful_drop:3.19', 'E1 a zero minimum is floored to 1c: an unchanged price never alerts');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0, 360, 3.18, 3.19, v_old, null, null) = 'true:price_dropped:3.18', 'E1 ...and a 1c drop then qualifies');

  -- cumulative drops, rises and equal prices -----------------------------------------------------
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.14, 3.19, v_old, null, null) = 'false:no_meaningful_drop:3.19', 'E1 first 5c drop keeps the reference (3.19)');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.09, 3.19, v_old, null, null) = 'true:price_dropped:3.09', 'E1 second 5c drop completes the 10c');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.29, 3.19, v_old, null, null) = 'false:no_meaningful_drop:3.29', 'E1 a rise moves the reference up to the new high');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.19, 3.29, v_old, null, null) = 'true:price_dropped:3.19', 'E1 a fall of 10c from the new high qualifies');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.19, 3.19, v_old, null, null) = 'false:no_meaningful_drop:3.19', 'E1 an unchanged price never alerts');

  -- baseline: absent, stale, unknown age -------------------------------------------------------
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.00, null, null, null, null) = 'false:baseline_established:3.00', 'E1 no baseline: established from this report, no alert');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.00, 3.50, interval '7 days', null, null) = 'true:price_dropped:3.00', 'E1 a reference exactly 7 days old is still valid');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.00, 3.50, interval '7 days 1 second', null, null) = 'false:baseline_stale:3.00', 'E1 a reference older than 7 days is discarded');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.00, 3.50, null, null, null) = 'false:baseline_stale:3.00', 'E1 a reference of unknown age is not trusted');

  -- cooldown: suppression keeps the alert armed -------------------------------------------------
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.00, 3.19, v_old, 3.19, now() - v_h) = 'false:cooldown:3.19', 'E1 cooldown suppresses AND keeps the reference');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.00, 3.19, v_old, 3.19, now() - interval '359 minutes') = 'false:cooldown:3.19', 'E1 cooldown still active at 359 min');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.00, 3.19, v_old, 3.19, now() - interval '360 minutes') = 'true:price_dropped:3.00', 'E1 cooldown over at exactly 360 min');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.19, 3.19, v_old, 3.19, now() - v_h) = 'false:no_meaningful_drop:3.19', 'E1 cooldown does not stop the reference following prices');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 60, 3.00, 3.19, v_old, 3.19, now() - interval '59 minutes') = 'false:cooldown:3.19', 'E1 shortest cooldown (60) honoured');

  -- stale report: never notifies; the reference follows the report ---------------------------------
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.00, 3.19, v_old, null, null, false) = 'false:stale_report:3.00', 'E1 a stale report never notifies and is consumed');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 3.18, 3.19, v_old, null, null, false) = 'false:no_meaningful_drop:3.19', 'E1 a stale report with no qualifying drop behaves normally');

  -- at_or_below ------------------------------------------------------------------------------------
  perform pg_temp.expect(pg_temp.ev('at_or_below', 2.89, 0.100, 360, 2.90, 3.00, v_old, null, null) = 'false:above_threshold:2.90', 'E1 above the target: nothing');
  perform pg_temp.expect(pg_temp.ev('at_or_below', 2.89, 0.100, 360, 2.89, 3.00, v_old, null, null) = 'true:threshold_crossed:2.89', 'E1 exactly the target, coming from above: crossed');
  perform pg_temp.expect(pg_temp.ev('at_or_below', 2.89, 0.100, 360, 2.80, 2.85, v_old, null, null) = 'true:threshold_met:2.80', 'E1 first time at/below with no history: met');
  perform pg_temp.expect(pg_temp.ev('at_or_below', 2.89, 0.100, 360, 2.80, null, null, null, null) = 'true:threshold_met:2.80', 'E1 no baseline at all: still met (first meeting)');
  perform pg_temp.expect(pg_temp.ev('at_or_below', 2.89, 0.100, 360, 2.85, 2.85, v_old, 2.85, now() - interval '1 day') = 'false:threshold_unchanged:2.85', 'E1 unchanged price after a notification: no repeat');
  perform pg_temp.expect(pg_temp.ev('at_or_below', 2.89, 0.100, 360, 2.75, 2.85, v_old, 2.85, now() - interval '1 day') = 'true:threshold_price_changed:2.75', 'E1 a further 10c drop below the target re-notifies');
  perform pg_temp.expect(pg_temp.ev('at_or_below', 2.89, 0.100, 360, 2.80, 3.00, v_old, 2.85, now() - interval '1 hour') = 'false:cooldown:3.00', 'E1 at_or_below cooldown keeps the crossing armed (reference stays above)');
  perform pg_temp.expect(pg_temp.ev('at_or_below', 2.89, 0.100, 360, 2.80, 3.00, v_old, 2.85, now() - interval '1 day') = 'true:threshold_crossed:2.80', 'E1 ...and fires after the cooldown');
  perform pg_temp.expect(pg_temp.ev('at_or_below', 2.89, 0.100, 360, 2.80, 3.00, v_old, null, null, false) = 'false:stale_report:2.80', 'E1 a stale report never notifies');
  perform pg_temp.expect(pg_temp.ev('at_or_below', null, 0.100, 360, 2.80, 3.00, v_old, null, null) = 'false:invalid_threshold:3.00', 'E1 at_or_below without a threshold is refused');
  perform pg_temp.expect(pg_temp.ev('at_or_below', 0.50, 0.100, 360, 2.80, 3.00, v_old, null, null) = 'false:invalid_threshold:3.00', 'E1 threshold below the backend bound is refused');
  perform pg_temp.expect(pg_temp.ev('at_or_below', 8.00, 0.100, 360, 8.00, 8.00, v_old, null, null) = 'true:threshold_met:8.00', 'E1 upper bound 8.000 usable');
  perform pg_temp.expect(pg_temp.ev('at_or_below', 2.89, 0.100, 360, 2.80, 3.00, interval '8 days', null, null) = 'true:threshold_met:2.80', 'E1 a stale previous price is ignored, not trusted as a crossing');

  -- any_change (not offered by the app; kept consistent) ------------------------------------------
  perform pg_temp.expect(pg_temp.ev('any_change', null, 0.100, 360, 3.30, 3.19, v_old, null, null) = 'true:price_changed:3.30', 'E1 any_change up');
  perform pg_temp.expect(pg_temp.ev('any_change', null, 0.100, 360, 3.15, 3.19, v_old, null, null) = 'false:change_below_minimum:3.15', 'E1 any_change below minimum');
  perform pg_temp.expect(pg_temp.ev('any_change', null, 0.100, 360, 3.00, null, null, null, null) = 'false:baseline_established:3.00', 'E1 any_change establishes a baseline');

  -- invalid inputs --------------------------------------------------------------------------------
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 0.99, 3.19, v_old, null, null) = 'false:invalid_observed_price:3.19', 'E1 observed below 1.00 refused, reference untouched');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, 360, 8.01, 3.19, v_old, null, null) = 'false:invalid_observed_price:3.19', 'E1 observed above 8.00 refused');
  perform pg_temp.expect(pg_temp.ev('price_drop', null, 0.100, -1, 3.00, 3.19, v_old, null, null) = 'false:invalid_cooldown:3.19', 'E1 negative cooldown refused');
  perform pg_temp.expect(pg_temp.ev('weird_mode', null, 0.100, 360, 3.00, 3.19, v_old, null, null) = 'false:invalid_mode:3.19', 'E1 unknown mode never notifies');
  perform pg_temp.expect(pg_temp.ev(null, null, 0.100, 360, 3.00, 3.19, v_old, null, null) = 'false:invalid_mode:3.19', 'E1 NULL mode never notifies');
end;
$$;

-- ==================================================================================================
-- D1: the headline example. Credit baseline 3.19; Cash 2.99; Credit 3.14; Credit 3.09.
-- ==================================================================================================
select pg_temp.mk_world('d1');
do $$
declare
  v_base uuid := pg_temp.report('d1', 'credit', 3.19, interval '60 minutes');
  v_alert uuid := pg_temp.mk_alert('d1', 'credit', 'price_drop', null, 0.100);
  v_cash uuid;
  v_c314 uuid;
  v_c309 uuid;
begin
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.19, 'D1a the alert is anchored to the latest comparable (credit) price');

  v_cash := pg_temp.report('d1', 'cash', 2.99, interval '50 minutes');
  perform pg_temp.expect(pg_temp.prep(v_cash) = '0/1', 'D1b a Cash 2.99 report decides one skipped row, queues nothing');
  perform pg_temp.expect(pg_temp.verdict(v_alert, v_cash) = 'skipped:payment_type_mismatch', 'D1c ...because it is not a credit price');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.19, 'D1d ...and it does not move the credit reference');
  perform pg_temp.expect((select last_notified_at is null from private.price_alerts where id = v_alert), 'D1e ...nor stamp a notification');

  v_c314 := pg_temp.report('d1', 'credit', 3.14, interval '40 minutes');
  perform pg_temp.expect(pg_temp.prep(v_c314) = '0/1', 'D1f Credit 3.14 (5c below 3.19): no alert');
  perform pg_temp.expect(pg_temp.verdict(v_alert, v_c314) = 'skipped:no_meaningful_drop', 'D1g ...a normal non-qualifying drop');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.19, 'D1h ...and the reference stays at 3.19 so drops accumulate');

  v_c309 := pg_temp.report('d1', 'credit', 3.09, interval '30 minutes');
  perform pg_temp.expect(pg_temp.prep(v_c309) = '1/0', 'D1i Credit 3.09 (10c below the 3.19 reference): ONE pending delivery');
  perform pg_temp.expect(pg_temp.verdict(v_alert, v_c309) = 'pending:price_dropped', 'D1j ...price_dropped');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.09, 'D1k ...and the reference rearms at the notified price');
  perform pg_temp.expect((select payment_type from private.price_alert_deliveries where alert_id = v_alert and price_report_id = v_c309) = 'credit',
                         'D1l the delivery records the alert''s method for the notification text');
  perform pg_temp.expect((select last_notified_price is null and last_notified_at is null from private.price_alerts where id = v_alert),
                         'D1m the alert row is NOT stamped at prepare time: only a SENT notification stamps it (the queued delivery is the reservation)');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert and status = 'pending') = 1,
                         'D1n exactly one pending delivery in total');
end;
$$;

-- ==================================================================================================
-- D2: at_or_below uses the selected method; same_for_both qualifies for either; unknown never does
-- ==================================================================================================
select pg_temp.mk_world('d2');
do $$
declare
  v_base uuid := pg_temp.report('d2', 'credit', 3.05, interval '90 minutes');
  v_credit uuid := pg_temp.mk_alert('d2', 'credit', 'at_or_below', 2.89, 0.100);
  v_cash_rep uuid;
  v_unknown_rep uuid;
  v_credit_rep uuid;
begin
  v_cash_rep := pg_temp.report('d2', 'cash', 2.79, interval '80 minutes');
  perform pg_temp.expect(pg_temp.prep(v_cash_rep) = '0/1' and pg_temp.verdict(v_credit, v_cash_rep) = 'skipped:payment_type_mismatch',
                         'D2a Credit alert at/below 2.89: a Cash 2.79 report does NOT qualify');
  v_unknown_rep := pg_temp.report('d2', 'unknown', 2.50, interval '70 minutes');
  perform pg_temp.expect(pg_temp.prep(v_unknown_rep) = '0/1' and pg_temp.verdict(v_credit, v_unknown_rep) = 'skipped:payment_type_mismatch',
                         'D2b ...nor does an unspecified-type report');
  v_credit_rep := pg_temp.report('d2', 'credit', 2.89, interval '60 minutes');
  perform pg_temp.expect(pg_temp.prep(v_credit_rep) = '1/0' and pg_temp.verdict(v_credit, v_credit_rep) = 'pending:threshold_crossed',
                         'D2c a Credit 2.89 report (exactly the target, from 3.05 above) qualifies');
  perform pg_temp.expect((select threshold_price from private.price_alerts where id = v_credit) = 2.89,
                         'D2d the target is never changed by a new price');
end;
$$;

select pg_temp.mk_world('d2b');
do $$
declare
  v_c uuid;
  v_k uuid;
  v_both_rep uuid;
  v_cash_alert uuid;
begin
  -- both alerts watch their own method; a same_for_both report qualifies for each (two installations are
  -- not needed: the unique key is (installation, station), so use two stations' worth of worlds)
  perform pg_temp.report('d2b', 'credit', 3.10, interval '90 minutes');
  v_c := pg_temp.mk_alert('d2b', 'credit', 'at_or_below', 2.89, 0.100);
  v_both_rep := pg_temp.report('d2b', 'same_for_both', 2.89, interval '60 minutes');
  perform pg_temp.expect(pg_temp.prep(v_both_rep) = '1/0' and pg_temp.verdict(v_c, v_both_rep) = 'pending:threshold_crossed',
                         'D2e same_for_both 2.89 qualifies for a CREDIT alert');
end;
$$;

select pg_temp.mk_world('d2c');
do $$
declare
  v_a uuid;
  v_both_rep uuid;
begin
  perform pg_temp.report('d2c', 'cash', 3.10, interval '90 minutes');
  v_a := pg_temp.mk_alert('d2c', 'cash', 'at_or_below', 2.89, 0.100);
  v_both_rep := pg_temp.report('d2c', 'same_for_both', 2.89, interval '60 minutes');
  perform pg_temp.expect(pg_temp.prep(v_both_rep) = '1/0' and pg_temp.verdict(v_a, v_both_rep) = 'pending:threshold_crossed',
                         'D2f same_for_both 2.89 qualifies for a CASH alert too');
end;
$$;

-- ==================================================================================================
-- D3: switching report type never manufactures a drop (rapid alternation)
-- ==================================================================================================
select pg_temp.mk_world('d3');
do $$
declare
  v_alert uuid;
  v_ids uuid[] := '{}';
  v_r uuid;
  i int;
begin
  perform pg_temp.report('d3', 'credit', 3.19, interval '110 minutes');
  v_alert := pg_temp.mk_alert('d3', 'credit', 'price_drop', null, 0.050);   -- even the most sensitive preset
  -- cash is 20c cheaper than credit, alternating every minute for eight reports
  for i in 1 .. 8 loop
    if i % 2 = 1 then
      v_r := pg_temp.report('d3', 'cash', 2.99, (110 - i * 2) * interval '1 minute');
    else
      v_r := pg_temp.report('d3', 'credit', 3.19, (110 - i * 2) * interval '1 minute');
    end if;
    perform pg_temp.prep(v_r);
  end loop;
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert and status = 'pending') = 0,
                         'D3a alternating cash/credit never notifies a credit alert');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.19, 'D3b the credit reference is untouched by the cash reports');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert and reason_code = 'payment_type_mismatch') = 4,
                         'D3c the four cash reports were recorded as mismatches');
end;
$$;

-- ==================================================================================================
-- D4: a legacy (unknown) alert only ever sees unknown reports and still works
-- ==================================================================================================
select pg_temp.mk_world('d4');
do $$
declare
  v_alert uuid;
  v_typed uuid;
  v_legacy uuid;
begin
  perform pg_temp.report('d4', 'unknown', 3.19, interval '90 minutes');
  v_alert := pg_temp.mk_alert('d4', 'unknown', 'price_drop', null, 0.050);
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.19, 'D4a a legacy alert anchors to the latest unknown report');

  v_typed := pg_temp.report('d4', 'credit', 2.50, interval '80 minutes');
  perform pg_temp.expect(pg_temp.prep(v_typed) = '0/1' and pg_temp.verdict(v_alert, v_typed) = 'skipped:payment_type_mismatch',
                         'D4b a credit report never reaches a legacy alert');
  v_typed := pg_temp.report('d4', 'same_for_both', 2.50, interval '70 minutes');
  perform pg_temp.expect(pg_temp.prep(v_typed) = '0/1' and pg_temp.verdict(v_alert, v_typed) = 'skipped:payment_type_mismatch',
                         'D4c ...and neither does same_for_both (it is not mixed into the unknown stream)');
  v_legacy := pg_temp.report('d4', 'unknown', 3.13, interval '60 minutes');
  perform pg_temp.expect(pg_temp.prep(v_legacy) = '1/0' and pg_temp.verdict(v_alert, v_legacy) = 'pending:price_dropped',
                         'D4d an unknown report drops the legacy alert exactly as before (6c >= 5c)');
end;
$$;

-- ==================================================================================================
-- D5: out-of-order, late and backlog: only the newest comparable report decides
-- ==================================================================================================
select pg_temp.mk_world('d5a');
do $$
declare
  v_alert uuid;
  v_new uuid;
  v_late uuid;
begin
  perform pg_temp.report('d5a', 'credit', 3.19, interval '100 minutes');
  v_alert := pg_temp.mk_alert('d5a', 'credit', 'price_drop', null, 0.100);
  v_new := pg_temp.report('d5a', 'credit', 3.18, interval '20 minutes');      -- the newest credit price
  v_late := pg_temp.report('d5a', 'credit', 2.90, interval '40 minutes');     -- inserted LATER, but observed earlier
  perform pg_temp.expect(pg_temp.prep(v_late) = '0/1' and pg_temp.verdict(v_alert, v_late) = 'skipped:superseded',
                         'D5a a late, older report is superseded: no alert');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.19, 'D5b ...and it does not move the reference');
  perform pg_temp.expect(pg_temp.prep(v_new) = '0/1' and pg_temp.verdict(v_alert, v_new) = 'skipped:no_meaningful_drop',
                         'D5c the newest report is judged on its own (3.18 is 1c below 3.19)');
end;
$$;

select pg_temp.mk_world('d5b');
do $$
declare
  v_alert uuid;
  r1 uuid; r2 uuid; r3 uuid;
begin
  perform pg_temp.report('d5b', 'credit', 3.19, interval '110 minutes');
  v_alert := pg_temp.mk_alert('d5b', 'credit', 'price_drop', null, 0.100);
  r1 := pg_temp.report('d5b', 'credit', 3.15, interval '60 minutes');
  r2 := pg_temp.report('d5b', 'credit', 3.12, interval '50 minutes');
  r3 := pg_temp.report('d5b', 'credit', 3.05, interval '40 minutes');
  -- a backlog: the oldest two are processed first and are superseded; only the newest decides
  perform pg_temp.prep(r1); perform pg_temp.prep(r2);
  perform pg_temp.expect(pg_temp.verdict(v_alert, r1) = 'skipped:superseded' and pg_temp.verdict(v_alert, r2) = 'skipped:superseded',
                         'D5d backlog: older reports are superseded');
  perform pg_temp.expect(pg_temp.prep(r3) = '1/0' and pg_temp.verdict(v_alert, r3) = 'pending:price_dropped',
                         'D5e backlog: the newest (14c below 3.19) alerts once');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert and status = 'pending') = 1,
                         'D5f exactly one notification for the whole backlog');
end;
$$;

-- a same_for_both report is part of BOTH streams for the supersede check
select pg_temp.mk_world('d5c');
do $$
declare
  v_alert uuid;
  v_credit_old uuid;
begin
  perform pg_temp.report('d5c', 'credit', 3.19, interval '100 minutes');
  v_alert := pg_temp.mk_alert('d5c', 'credit', 'price_drop', null, 0.100);
  v_credit_old := pg_temp.report('d5c', 'credit', 2.95, interval '40 minutes');
  perform pg_temp.report('d5c', 'same_for_both', 3.18, interval '20 minutes');     -- newer, comparable to credit
  perform pg_temp.expect(pg_temp.prep(v_credit_old) = '0/1' and pg_temp.verdict(v_alert, v_credit_old) = 'skipped:superseded',
                         'D5g a newer same_for_both report supersedes an older credit report');
end;
$$;

-- a newer report of a DIFFERENT method does not supersede
select pg_temp.mk_world('d5d');
do $$
declare
  v_alert uuid;
  v_credit uuid;
begin
  perform pg_temp.report('d5d', 'credit', 3.19, interval '100 minutes');
  v_alert := pg_temp.mk_alert('d5d', 'credit', 'price_drop', null, 0.100);
  v_credit := pg_temp.report('d5d', 'credit', 3.05, interval '40 minutes');
  perform pg_temp.report('d5d', 'cash', 2.50, interval '10 minutes');             -- newer, different method
  perform pg_temp.expect(pg_temp.prep(v_credit) = '1/0' and pg_temp.verdict(v_alert, v_credit) = 'pending:price_dropped',
                         'D5h a newer CASH report does not supersede the credit report');
end;
$$;

-- ==================================================================================================
-- D6: repeated and unchanged prices never re-alert (several reporters)
-- ==================================================================================================
select pg_temp.mk_world('d6');
do $$
declare
  v_alert uuid;
  r1 uuid; r2 uuid; r3 uuid;
begin
  perform pg_temp.report('d6', 'credit', 3.19, interval '110 minutes');
  v_alert := pg_temp.mk_alert('d6', 'credit', 'price_drop', null, 0.100);
  r1 := pg_temp.report('d6', 'credit', 3.05, interval '60 minutes', 'reporter-one');
  perform pg_temp.expect(pg_temp.prep(r1) = '1/0', 'D6a the drop alerts once');
  r2 := pg_temp.report('d6', 'credit', 3.05, interval '50 minutes', 'reporter-two');
  perform pg_temp.expect(pg_temp.prep(r2) = '0/1' and pg_temp.verdict(v_alert, r2) = 'skipped:no_meaningful_drop',
                         'D6b another person reporting the same price does not alert again');
  r3 := pg_temp.report('d6', 'credit', 3.05, interval '40 minutes', 'reporter-one');
  perform pg_temp.expect(pg_temp.prep(r3) = '0/1', 'D6c a duplicate submission does not alert again');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert and status = 'pending') = 1,
                         'D6d still exactly one pending delivery');
end;
$$;

-- at_or_below: the same price after a notification does not repeat
select pg_temp.mk_world('d6b');
do $$
declare
  v_alert uuid;
  r1 uuid; r2 uuid;
begin
  perform pg_temp.report('d6b', 'cash', 3.10, interval '110 minutes');
  v_alert := pg_temp.mk_alert('d6b', 'cash', 'at_or_below', 2.89, 0.100);
  r1 := pg_temp.report('d6b', 'cash', 2.85, interval '60 minutes');
  perform pg_temp.expect(pg_temp.prep(r1) = '1/0', 'D6e at_or_below alerts when the target is reached');
  r2 := pg_temp.report('d6b', 'cash', 2.85, interval '50 minutes');
  perform pg_temp.expect(pg_temp.prep(r2) = '0/1' and pg_temp.verdict(v_alert, r2) = 'skipped:cooldown' or pg_temp.verdict(v_alert, r2) = 'skipped:threshold_unchanged',
                         'D6f the same price again does not re-alert (unchanged / cooldown)');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert and status = 'pending') = 1,
                         'D6g still exactly one pending delivery');
end;
$$;

-- ==================================================================================================
-- D7: cooldown - reservation at prepare, suppression keeps the alert armed, expiry re-fires
-- ==================================================================================================
select pg_temp.mk_world('d7');
do $$
declare
  v_alert uuid;
  r1 uuid; r2 uuid; r3 uuid;
begin
  perform pg_temp.report('d7', 'credit', 3.40, interval '115 minutes');
  v_alert := pg_temp.mk_alert('d7', 'credit', 'price_drop', null, 0.100, 360);
  r1 := pg_temp.report('d7', 'credit', 3.25, interval '100 minutes');            -- 15c drop
  perform pg_temp.expect(pg_temp.prep(r1) = '1/0', 'D7a first drop notifies');
  -- the worker has NOT sent r1 yet (no mark_sent): a second qualifying drop must still meet the cooldown
  r2 := pg_temp.report('d7', 'credit', 3.10, interval '90 minutes');             -- another 15c drop from 3.25
  perform pg_temp.expect(pg_temp.prep(r2) = '0/1' and pg_temp.verdict(v_alert, r2) = 'skipped:cooldown',
                         'D7b a second drop prepared before the first is SENT is held by the cooldown (race closed)');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.25, 'D7c the suppressed drop leaves the alert armed at the notified price');
  -- the worker sends r1, and the cooldown then runs out (simulated); the next qualifying comparable report fires from the armed reference
  perform pg_temp.deliver(v_alert, interval '361 minutes');
  perform pg_temp.expect((select last_notified_price = 3.25 from private.price_alerts where id = v_alert), 'D7c2 sending r1 stamps the alert with the notified price');
  r3 := pg_temp.report('d7', 'credit', 3.09, interval '30 minutes');
  perform pg_temp.expect(pg_temp.prep(r3) = '1/0' and pg_temp.verdict(v_alert, r3) = 'pending:price_dropped',
                         'D7d after the cooldown the next qualifying report fires (16c below the armed 3.25)');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.09, 'D7e ...and the reference rearms at 3.09');
end;
$$;

-- ==================================================================================================
-- D8: rearm - rises move the reference up, a fall from the new high counts
-- ==================================================================================================
select pg_temp.mk_world('d8');
do $$
declare
  v_alert uuid;
  r1 uuid; r2 uuid; r3 uuid; r4 uuid;
begin
  perform pg_temp.report('d8', 'cash', 3.19, interval '115 minutes');
  v_alert := pg_temp.mk_alert('d8', 'cash', 'price_drop', null, 0.100, 60);
  r1 := pg_temp.report('d8', 'cash', 3.29, interval '100 minutes');             -- price rises
  perform pg_temp.expect(pg_temp.prep(r1) = '0/1' and pg_temp.baseline(v_alert) = 3.29, 'D8a a rise moves the reference to the new high');
  r2 := pg_temp.report('d8', 'cash', 3.24, interval '90 minutes');              -- 5c below the new high
  perform pg_temp.expect(pg_temp.prep(r2) = '0/1' and pg_temp.baseline(v_alert) = 3.29, 'D8b a 5c fall keeps the high');
  r3 := pg_temp.report('d8', 'cash', 3.19, interval '80 minutes');              -- 10c below the high: alert
  perform pg_temp.expect(pg_temp.prep(r3) = '1/0' and pg_temp.verdict(v_alert, r3) = 'pending:price_dropped',
                         'D8c the cumulative fall from the new high alerts');
  perform pg_temp.deliver(v_alert, interval '2 hours');
  r4 := pg_temp.report('d8', 'cash', 3.10, interval '70 minutes');              -- only 9c below the rearmed 3.19
  perform pg_temp.expect(pg_temp.prep(r4) = '0/1' and pg_temp.baseline(v_alert) = 3.19, 'D8d after firing, 9c is not enough from the rearmed reference');
end;
$$;

-- ==================================================================================================
-- D9: missing / stale baseline and stale reports
-- ==================================================================================================
select pg_temp.mk_world('d9a');
do $$
declare
  v_alert uuid;
  r1 uuid; r2 uuid;
begin
  perform pg_temp.report('d9a', 'cash', 2.50, interval '115 minutes');          -- only a CASH price exists
  v_alert := pg_temp.mk_alert('d9a', 'credit', 'price_drop', null, 0.100);
  perform pg_temp.expect(pg_temp.baseline(v_alert) is null, 'D9a no comparable price at configuration: no reference is invented');
  r1 := pg_temp.report('d9a', 'credit', 3.19, interval '60 minutes');
  perform pg_temp.expect(pg_temp.prep(r1) = '0/1' and pg_temp.verdict(v_alert, r1) = 'skipped:baseline_established' and pg_temp.baseline(v_alert) = 3.19,
                         'D9b the first comparable report establishes the reference without alerting');
  r2 := pg_temp.report('d9a', 'credit', 3.09, interval '50 minutes');
  perform pg_temp.expect(pg_temp.prep(r2) = '1/0', 'D9c later reports are judged against it');
end;
$$;

select pg_temp.mk_world('d9b');
do $$
declare
  v_alert uuid;
  r1 uuid;
begin
  perform pg_temp.report('d9b', 'credit', 3.50, interval '110 minutes');
  v_alert := pg_temp.mk_alert('d9b', 'credit', 'price_drop', null, 0.100);
  update private.price_alerts set baseline_at = now() - interval '8 days' where id = v_alert;   -- an old reference
  r1 := pg_temp.report('d9b', 'credit', 3.00, interval '30 minutes');
  perform pg_temp.expect(pg_temp.prep(r1) = '0/1' and pg_temp.verdict(v_alert, r1) = 'skipped:baseline_stale' and pg_temp.baseline(v_alert) = 3.00,
                         'D9d a reference older than 7 days is re-established without alerting');
end;
$$;

select pg_temp.mk_world('d9c');
do $$
declare
  v_alert uuid;
  r1 uuid;
begin
  perform pg_temp.report('d9c', 'credit', 3.50, interval '5 hours');
  v_alert := pg_temp.mk_alert('d9c', 'credit', 'price_drop', null, 0.100);
  r1 := pg_temp.report('d9c', 'credit', 3.00, interval '3 hours');               -- 50c drop, but 3 h old
  perform pg_temp.expect(pg_temp.prep(r1) = '0/1' and pg_temp.verdict(v_alert, r1) = 'skipped:stale_report',
                         'D9e a report older than the 2 h send window never notifies');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.00 and (select last_notified_at is null from private.price_alerts where id = v_alert),
                         'D9f ...the reference follows it and no notification is reserved');
end;
$$;

select pg_temp.mk_world('d9d');
do $$
declare
  v_alert uuid;
begin
  perform pg_temp.report('d9d', 'credit', 3.50, interval '8 days' + interval '1 hour');   -- outside the 7-day horizon
  v_alert := pg_temp.mk_alert('d9d', 'credit', 'price_drop', null, 0.100);
  perform pg_temp.expect(pg_temp.baseline(v_alert) is null, 'D9g a latest comparable price older than the horizon is not used as the anchor');
end;
$$;

-- ==================================================================================================
-- D10: Pro gate preserved
-- ==================================================================================================
select pg_temp.mk_world('d10', 1, false);
do $$
declare
  v_alert uuid;
  r1 uuid;
begin
  perform pg_temp.report('d10', 'credit', 3.50, interval '110 minutes');
  v_alert := pg_temp.mk_alert('d10', 'credit', 'price_drop', null, 0.100);
  r1 := pg_temp.report('d10', 'credit', 3.00, interval '30 minutes');
  perform pg_temp.expect(pg_temp.prep(r1) = '0/0', 'D10a a non-Pro installation gets no rows');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert) = 0, 'D10b ...none at all');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.50, 'D10c ...and its state is untouched');
  perform pg_temp.expect(exists (select 1 from private.price_alerts where id = v_alert and enabled), 'D10d ...and the alert is not deleted or disabled');
end;
$$;

-- ==================================================================================================
-- D11: one row per ACTIVE device; none for disabled / invalidated devices
-- ==================================================================================================
select pg_temp.mk_world('d11', 3);
do $$
declare
  v_alert uuid;
  v_devs uuid[] := (select device_ids from t_world where label = 'd11');
  r1 uuid;
begin
  update private.price_alert_push_devices set enabled = false where id = v_devs[2];
  update private.price_alert_push_devices set invalidated_at = now() where id = v_devs[3];
  perform pg_temp.report('d11', 'credit', 3.50, interval '110 minutes');
  v_alert := pg_temp.mk_alert('d11', 'credit', 'price_drop', null, 0.100);
  r1 := pg_temp.report('d11', 'credit', 3.00, interval '30 minutes');
  perform pg_temp.expect(pg_temp.prep(r1) = '1/0', 'D11a one pending row for the one active device');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert) = 1, 'D11b nothing for the disabled / invalidated devices');
end;
$$;

select pg_temp.mk_world('d11b', 2);
do $$
declare
  v_alert uuid;
  r1 uuid;
begin
  perform pg_temp.report('d11b', 'credit', 3.50, interval '110 minutes');
  v_alert := pg_temp.mk_alert('d11b', 'credit', 'price_drop', null, 0.100);
  r1 := pg_temp.report('d11b', 'credit', 3.00, interval '30 minutes');
  perform pg_temp.expect(pg_temp.prep(r1) = '2/0', 'D11c two active devices: two pending rows from ONE decision');
  perform pg_temp.expect((select count(distinct price_report_id) from private.price_alert_deliveries where alert_id = v_alert and status = 'pending') = 1,
                         'D11d ...both rows belong to that one decision (one reservation: the queued rows hold the cooldown)');
end;
$$;

-- an alert whose installation has no active device still tracks the reference but queues nothing
select pg_temp.mk_world('d11c', 0);
do $$
declare
  v_alert uuid;
  r1 uuid;
begin
  perform pg_temp.report('d11c', 'credit', 3.50, interval '110 minutes');
  v_alert := pg_temp.mk_alert('d11c', 'credit', 'price_drop', null, 0.100);
  r1 := pg_temp.report('d11c', 'credit', 3.00, interval '30 minutes');
  perform pg_temp.expect(pg_temp.prep(r1) = '0/0' and pg_temp.baseline(v_alert) = 3.00, 'D11e no device: nothing queued, reference consumed');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert) = 0
                         and (select last_notified_at is null from private.price_alerts where id = v_alert), 'D11f ...and no notification is queued, so nothing holds the cooldown');
end;
$$;

-- ==================================================================================================
-- D12: idempotence - a report is decided once
-- ==================================================================================================
select pg_temp.mk_world('d12');
do $$
declare
  v_alert uuid;
  r1 uuid;
  v_stamp timestamptz;
begin
  perform pg_temp.report('d12', 'credit', 3.50, interval '110 minutes');
  v_alert := pg_temp.mk_alert('d12', 'credit', 'price_drop', null, 0.100);
  r1 := pg_temp.report('d12', 'credit', 3.00, interval '30 minutes');
  perform pg_temp.expect(pg_temp.prep(r1) = '1/0', 'D12a first run queues');
  select last_notified_at into v_stamp from private.price_alerts where id = v_alert;
  perform pg_temp.expect(pg_temp.prep(r1) = '0/0', 'D12b a second run decides nothing');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert) = 1, 'D12c ...and adds no rows');
  perform pg_temp.expect((select baseline_price = 3.00 and last_notified_at is not distinct from v_stamp from private.price_alerts where id = v_alert),
                         'D12d ...and moves no state');
end;
$$;

select pg_temp.mk_world('d12b', 0);       -- a device-less alert converges instead of firing twice
do $$
declare
  v_alert uuid;
  r1 uuid;
begin
  perform pg_temp.report('d12b', 'credit', 3.50, interval '110 minutes');
  v_alert := pg_temp.mk_alert('d12b', 'credit', 'price_drop', null, 0.100);
  r1 := pg_temp.report('d12b', 'credit', 3.00, interval '30 minutes');
  perform pg_temp.prep(r1);
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.00, 'D12e reference consumed');
  perform pg_temp.prep(r1);
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.00 and (select count(*) from private.price_alert_deliveries where alert_id = v_alert) = 0,
                         'D12f re-running the same report converges (no state drift, no rows)');
end;
$$;

-- a report suppressed by the cooldown is not re-decided once the cooldown has passed (it would consume the
-- armed reference without queuing anything)
select pg_temp.mk_world('d12c');
do $$
declare
  v_alert uuid;
  r1 uuid;
  r2 uuid;
begin
  perform pg_temp.report('d12c', 'credit', 3.50, interval '115 minutes');
  v_alert := pg_temp.mk_alert('d12c', 'credit', 'price_drop', null, 0.100, 60);
  r1 := pg_temp.report('d12c', 'credit', 3.30, interval '100 minutes');
  perform pg_temp.expect(pg_temp.prep(r1) = '1/0', 'D12g first drop notifies');
  r2 := pg_temp.report('d12c', 'credit', 3.10, interval '30 minutes');
  perform pg_temp.expect(pg_temp.prep(r2) = '0/1' and pg_temp.verdict(v_alert, r2) = 'skipped:cooldown', 'D12h the second drop is held by the cooldown');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.30, 'D12i ...leaving the alert armed at 3.30');
  perform pg_temp.deliver(v_alert, interval '2 hours');   -- r1 is sent and the cooldown (60 min) has passed
  perform pg_temp.expect(pg_temp.prep(r2) = '0/0', 'D12j re-preparing that report later decides nothing');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.30, 'D12k ...and does not consume the armed reference');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert) = 2
                         and (select count(*) from private.price_alert_deliveries where alert_id = v_alert and status = 'pending') = 0,
                         'D12l ...and queues nothing new (r1 sent, r2 skipped: still exactly two rows)');
end;
$$;

-- ==================================================================================================
-- D13: fail closed on a value this code has never heard of
-- ==================================================================================================
select pg_temp.mk_world('d13');
do $$
declare
  v_a_cash uuid;
  r1 uuid;
begin
  perform pg_temp.report('d13', 'cash', 3.50, interval '110 minutes');
  v_a_cash := pg_temp.mk_alert('d13', 'cash', 'price_drop', null, 0.100);
  -- simulate a future/foreign value that bypassed the CHECK (superuser, inside this rolled-back test)
  alter table public.e85_price_reports drop constraint e85_price_reports_payment_type_check;
  r1 := pg_temp.report('d13', 'barter', 1.50, interval '30 minutes');
  perform pg_temp.expect(pg_temp.prep(r1) = '0/1' and pg_temp.verdict(v_a_cash, r1) = 'skipped:payment_type_mismatch',
                         'D13a an unrecognised report value is not comparable to a cash alert');
  perform pg_temp.expect(pg_temp.baseline(v_a_cash) = 3.50, 'D13b ...and moves nothing');
  -- the bogus row is removed again; migration A re-adds the CHECK below (and would refuse to VALIDATE it
  -- while such a row existed, which is the point of validating)
  delete from public.e85_price_reports where payment_type = 'barter';
end;
$$;

-- ==================================================================================================
-- D14: anchor trigger rules
-- ==================================================================================================
select pg_temp.mk_world('d14');
do $$
declare
  v_alert uuid;
begin
  perform pg_temp.report('d14', 'credit', 3.19, interval '3 days');
  perform pg_temp.report('d14', 'cash',   2.99, interval '2 days');
  perform pg_temp.report('d14', 'same_for_both', 3.09, interval '1 day');     -- newest comparable to both
  v_alert := pg_temp.mk_alert('d14', 'credit', 'price_drop', null, 0.100);
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.09, 'D14a the anchor is the latest COMPARABLE price (same_for_both counts)');
  perform pg_temp.expect((select baseline_at is not null from private.price_alerts where id = v_alert), 'D14b ...with its reported time');

  -- edit only the sensitivity: the reference is kept
  update private.price_alerts set minimum_change = 0.200, baseline_price = 3.30 where id = v_alert;
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.30, 'D14c editing sensitivity or cooldown keeps the reference');
  update private.price_alerts set threshold_price = null, cooldown_minutes = 120, alert_mode = 'price_drop', payment_type = 'credit' where id = v_alert;
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.30, 'D14d ...even when the unchanged mode/method columns are written (an upsert does that)');

  -- change the method: re-anchor to the cash stream, forget the credit notification price
  update private.price_alerts set last_notified_price = 3.09, last_notified_at = now() - interval '1 hour' where id = v_alert;
  update private.price_alerts set payment_type = 'cash' where id = v_alert;
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.09, 'D14e changing the method re-anchors (the same_for_both 3.09 is also the newest cash-comparable)');
  perform pg_temp.expect((select last_notified_price is null and last_notified_at is not null from private.price_alerts where id = v_alert),
                         'D14f ...clears the old notified price but keeps the cooldown clock');

  -- change the mode to at_or_below: re-anchor again
  update private.price_alerts set alert_mode = 'at_or_below', threshold_price = 2.80 where id = v_alert;
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.09, 'D14g changing the mode re-anchors');
end;
$$;

-- ==================================================================================================
-- D15: deliveries stay readable by the unchanged claim function; the worker's lookup works
-- ==================================================================================================
select pg_temp.mk_world('d15');
do $$
declare
  v_alert uuid;
  r1 uuid;
  v_claimed record;
  v_delivery uuid;
begin
  perform pg_temp.report('d15', 'cash', 3.50, interval '110 minutes');
  v_alert := pg_temp.mk_alert('d15', 'cash', 'price_drop', null, 0.100);
  r1 := pg_temp.report('d15', 'cash', 3.00, interval '30 minutes');
  perform pg_temp.prep(r1);
  select c.* into v_claimed from private.claim_price_alert_deliveries_v2(100, 'ios') c where c.alert_id = v_alert;
  perform pg_temp.expect(v_claimed.delivery_id is not null and v_claimed.reason_code = 'price_dropped' and v_claimed.observed_price = 3.00,
                         'D15a the unchanged v2 claim returns the new delivery with its existing columns');
  perform pg_temp.expect((select payment_type from private.price_alert_deliveries where id = v_claimed.delivery_id) = 'cash',
                         'D15b the worker can read the alert method by delivery id');
end;
$$;

-- ==================================================================================================
-- D16: the exact upsert price-alerts-api runs for set_alert (kept in sync with index.ts by
--      price-alerts-api/alert-input.test.ts, which pins its clauses). p_updates_min is what alert-input.ts decides
--      (the sensitivity contract): true = this request replaces an EXISTING alert's minimum_change (a client that
--      declared alert_contract_version >= 2, or any explicit value other than the fixed legacy 0.05); false = it keeps
--      the stored one (an older client re-saving, or a request that does not name a value). The real function is
--      exercised end to end, over HTTP, by price_alert_api_payment_type.test.sh.
-- ==================================================================================================
create function pg_temp.api_set_alert(p_inst uuid, p_station uuid, p_mode text, p_threshold numeric,
                                      p_min numeric, p_cooldown int, p_payment text,
                                      p_updates_min boolean default true)
returns table (id uuid, alert_mode text, threshold_price numeric, minimum_change numeric,
               cooldown_minutes int, enabled boolean, payment_type text)
language sql as $$
  insert into private.price_alerts (
    installation_id, station_id, alert_mode, threshold_price, minimum_change, cooldown_minutes, payment_type, enabled
  ) values (
    p_inst, p_station, p_mode, p_threshold, p_min, p_cooldown, coalesce(p_payment::text, 'unknown'), true
  )
  on conflict (installation_id, station_id) do update
  set alert_mode = excluded.alert_mode,
      threshold_price = excluded.threshold_price,
      minimum_change = case when p_updates_min::boolean then excluded.minimum_change
                            else private.price_alerts.minimum_change end,
      cooldown_minutes = excluded.cooldown_minutes,
      payment_type = coalesce(p_payment::text, private.price_alerts.payment_type),
      enabled = true
  returning private.price_alerts.id, private.price_alerts.alert_mode, private.price_alerts.threshold_price,
            private.price_alerts.minimum_change, private.price_alerts.cooldown_minutes, private.price_alerts.enabled,
            private.price_alerts.payment_type
$$;

select pg_temp.mk_world('d16');
do $$
declare
  v_inst uuid := (select installation_id from t_world where label = 'd16');
  v_station uuid := (select station_id from t_world where label = 'd16');
  r record;
  v_alert uuid;
begin
  perform pg_temp.report('d16', 'unknown', 3.40, interval '5 hours');
  perform pg_temp.report('d16', 'credit', 3.19, interval '4 hours');
  perform pg_temp.report('d16', 'cash', 2.99, interval '3 hours');       -- the NEWEST report overall is cash

  -- (a) an older client creates an alert with no payment_type, no minimum_change: legacy 5c, method 'unknown'
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.050, 360, null);
  v_alert := r.id;
  perform pg_temp.expect(r.payment_type = 'unknown' and r.minimum_change = 0.050 and r.enabled, 'D16a an older client creates a legacy alert (method unknown, 5c)');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.40, 'D16b ...anchored to the latest UNKNOWN report, not to the newer typed ones');

  -- (b) the newer app chooses credit and 10c: stored as sent, re-anchored to the credit stream
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.100, 360, 'credit');
  perform pg_temp.expect(r.id = v_alert and r.payment_type = 'credit' and r.minimum_change = 0.100, 'D16c choosing credit + 10c updates the same alert');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.19, 'D16d ...and re-anchors to the latest credit report (not the newer cash one)');

  -- remember a notification, then edit without naming a method (an older app) or changing the mode
  update private.price_alerts set last_notified_price = 3.19, last_notified_at = now() - interval '1 hour', baseline_price = 3.25 where id = v_alert;
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.100, 360, null);
  perform pg_temp.expect(r.payment_type = 'credit', 'D16e an edit that does not name a method KEEPS the current one');
  perform pg_temp.expect((select baseline_price = 3.25 and last_notified_price = 3.19 and last_notified_at is not null from private.price_alerts where id = v_alert),
                         'D16f ...and does not reset the reference or the notification history');

  -- (c) the sensitivity presets round-trip exactly and change nothing else
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.050, 360, 'credit');
  perform pg_temp.expect(r.minimum_change = 0.050 and r.payment_type = 'credit' and pg_temp.baseline(v_alert) = 3.25, 'D16g 5c preset');
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.200, 360, 'credit');
  perform pg_temp.expect(r.minimum_change = 0.200 and pg_temp.baseline(v_alert) = 3.25, 'D16h 20c preset');
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.137, 360, 'credit');
  perform pg_temp.expect(r.minimum_change = 0.137, 'D16i a custom three-decimal value is stored exactly');
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 2.000, 360, 'credit');
  perform pg_temp.expect(r.minimum_change = 2.000, 'D16j the 2.00 upper bound is stored');
  perform pg_temp.expect(pg_temp.raises(format($q$ select * from pg_temp.api_set_alert(%L, %L, 'price_drop', null, 2.001, 360, 'credit') $q$, v_inst, v_station)),
                         'D16k 2.001 is refused by the table CHECK even if the API were bypassed');
  perform pg_temp.expect(pg_temp.raises(format($q$ select * from pg_temp.api_set_alert(%L, %L, 'price_drop', null, 0.009, 360, 'credit') $q$, v_inst, v_station)),
                         'D16l 0.009 is refused by the table CHECK');

  -- (d) editing the target alone preserves every other setting
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'at_or_below', 2.89, 0.100, 180, 'credit');
  perform pg_temp.expect(r.alert_mode = 'at_or_below' and r.threshold_price = 2.890 and r.cooldown_minutes = 180 and r.payment_type = 'credit',
                         'D16m switching to at_or_below with a target');
  update private.price_alerts set last_notified_price = 2.85, last_notified_at = now() - interval '2 hours' where id = v_alert;
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'at_or_below', 2.79, 0.100, 180, 'credit');
  perform pg_temp.expect(r.threshold_price = 2.790 and r.minimum_change = 0.100 and r.cooldown_minutes = 180 and r.payment_type = 'credit',
                         'D16n editing the target alone keeps method, sensitivity and cooldown');
  perform pg_temp.expect((select last_notified_price = 2.85 from private.price_alerts where id = v_alert), 'D16o ...and the notification history');

  -- (e) switching method re-anchors and forgets the other method's notified price
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'at_or_below', 2.79, 0.100, 180, 'cash');
  perform pg_temp.expect(r.payment_type = 'cash' and pg_temp.baseline(v_alert) = 2.99, 'D16p switching to cash re-anchors to the latest cash report');
  perform pg_temp.expect((select last_notified_price is null from private.price_alerts where id = v_alert), 'D16q ...and clears the credit-era notified price');

  -- there is exactly one alert per (installation, station); it is never disabled by an edit
  perform pg_temp.expect((select count(*) from private.price_alerts where installation_id = v_inst and station_id = v_station) = 1, 'D16r one alert per station');
  perform pg_temp.expect((select enabled from private.price_alerts where id = v_alert), 'D16s an edit leaves the alert enabled');
end;
$$;

-- ==================================================================================================
-- D17: list_alerts - the legacy "latest" is the newest of ANY kind; the comparable one is the alert's own
-- ==================================================================================================
select pg_temp.mk_world('d17');
do $$
declare
  v_alert uuid;
  r record;
begin
  perform pg_temp.report('d17', 'credit', 3.19, interval '4 hours');
  perform pg_temp.report('d17', 'cash', 2.99, interval '1 hour');                 -- newest overall
  v_alert := pg_temp.mk_alert('d17', 'credit', 'price_drop', null, 0.100);
  select a.payment_type,
         latest.price as latest_price,
         comparable.price as latest_comparable_price,
         comparable.payment_type as latest_comparable_payment_type
  into r
  from private.price_alerts a
  left join lateral (
    select x.price, x.reported_at from public.e85_price_reports x
    where x.station_id = a.station_id order by x.reported_at desc, x.created_at desc limit 1
  ) latest on true
  left join lateral private.latest_comparable_price_report(a.station_id, a.payment_type) comparable on true
  where a.id = v_alert;
  perform pg_temp.expect(r.payment_type = 'credit', 'D17a list_alerts returns the alert''s method');
  perform pg_temp.expect(r.latest_price = 2.99, 'D17b the legacy latest_price is still the newest of any kind (older clients unchanged)');
  perform pg_temp.expect(r.latest_comparable_price = 3.19 and r.latest_comparable_payment_type = 'credit',
                         'D17c ...while the comparable one is the credit price: a cash price is never presented as the latest credit price');
end;
$$;

-- ==================================================================================================
-- D18: a same_for_both report is a price for BOTH methods. It drives a Price Drop alert of either method
--      (cumulatively), and a legacy (unknown) alert never sees it.
-- ==================================================================================================
select pg_temp.mk_world('d18c');
do $$
declare
  v_alert uuid;
  v_small uuid;
  v_drop uuid;
begin
  perform pg_temp.report('d18c', 'credit', 3.19, interval '90 minutes', 'd18c-reporter');
  v_alert := pg_temp.mk_alert('d18c', 'credit', 'price_drop', null, 0.100);
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.19, 'D18a the credit alert is anchored to the credit price');

  v_small := pg_temp.report('d18c', 'same_for_both', 3.14, interval '60 minutes', 'd18c-reporter');
  perform pg_temp.expect(pg_temp.prep(v_small) = '0/1' and pg_temp.verdict(v_alert, v_small) = 'skipped:no_meaningful_drop',
                         'D18b same_for_both 3.14 is a 5c fall for a 10c credit alert: no alert');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.19, 'D18c ...and the reference stays at 3.19, so the drops accumulate');

  v_drop := pg_temp.report('d18c', 'same_for_both', 3.09, interval '30 minutes', 'd18c-reporter');
  perform pg_temp.expect(pg_temp.prep(v_drop) = '1/0' and pg_temp.verdict(v_alert, v_drop) = 'pending:price_dropped',
                         'D18d same_for_both 3.09 is 10c below the credit reference: the credit alert fires');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.09, 'D18e ...and the reference rearms at the notified price');
  perform pg_temp.expect((select payment_type from private.price_alert_deliveries
                          where alert_id = v_alert and price_report_id = v_drop) = 'credit',
                         'D18f ...recording the alert''s method (credit), not the report''s');
end;
$$;

select pg_temp.mk_world('d18k');
do $$
declare
  v_alert uuid;
  v_drop uuid;
begin
  perform pg_temp.report('d18k', 'cash', 3.19, interval '90 minutes', 'd18k-reporter');
  v_alert := pg_temp.mk_alert('d18k', 'cash', 'price_drop', null, 0.100);
  v_drop := pg_temp.report('d18k', 'same_for_both', 3.09, interval '30 minutes', 'd18k-reporter');
  perform pg_temp.expect(pg_temp.prep(v_drop) = '1/0' and pg_temp.verdict(v_alert, v_drop) = 'pending:price_dropped',
                         'D18g the same same_for_both 3.09 report fires a CASH price-drop alert too');
  perform pg_temp.expect((select payment_type from private.price_alert_deliveries
                          where alert_id = v_alert and price_report_id = v_drop) = 'cash',
                         'D18h ...recording the alert''s method (cash)');
end;
$$;

select pg_temp.mk_world('d18u');
do $$
declare
  v_alert uuid;
  v_rep uuid;
begin
  perform pg_temp.report('d18u', 'unknown', 3.19, interval '90 minutes', 'd18u-reporter');
  v_alert := pg_temp.mk_alert('d18u', 'unknown', 'price_drop', null, 0.050);
  v_rep := pg_temp.report('d18u', 'same_for_both', 2.90, interval '30 minutes', 'd18u-reporter');
  perform pg_temp.expect(pg_temp.prep(v_rep) = '0/1' and pg_temp.verdict(v_alert, v_rep) = 'skipped:payment_type_mismatch',
                         'D18i a legacy (unknown) alert never sees a same_for_both report, however large the fall');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.19, 'D18j ...and its reference does not move');
end;
$$;

-- ==================================================================================================
-- D20: a queued notification that ends UNSENT does not hold the cooldown (price_drop and at_or_below)
-- ==================================================================================================
select pg_temp.mk_world('d20');
do $$
declare
  v_alert uuid;
  r1 uuid; r2 uuid;
begin
  perform pg_temp.report('d20', 'credit', 3.50, interval '110 minutes', 'd20-reporter');
  v_alert := pg_temp.mk_alert('d20', 'credit', 'price_drop', null, 0.100, 360);
  r1 := pg_temp.report('d20', 'credit', 3.30, interval '30 minutes', 'd20-reporter');
  perform pg_temp.expect(pg_temp.prep(r1) = '1/0', 'D20a the first drop queues a notification');
  perform pg_temp.give_up(v_alert);
  perform pg_temp.expect((select status from private.price_alert_deliveries where alert_id = v_alert and price_report_id = r1) = 'dead',
                         'D20b ...the worker gives up on it: it ends dead and nothing was sent');
  perform pg_temp.expect((select last_notified_at is null and last_notified_price is null from private.price_alerts where id = v_alert),
                         'D20c ...so nothing is stamped on the alert');
  r2 := pg_temp.report('d20', 'credit', 3.10, interval '5 minutes', 'd20-reporter');
  perform pg_temp.expect(pg_temp.prep(r2) = '1/0' and pg_temp.verdict(v_alert, r2) = 'pending:price_dropped',
                         'D20d the next qualifying drop fires: a notification that never went out does not mute the alert for 6 hours');
end;
$$;

select pg_temp.mk_world('d20b');
do $$
declare
  v_alert uuid;
  q1 uuid; q2 uuid;
begin
  perform pg_temp.report('d20b', 'cash', 3.10, interval '110 minutes', 'd20b-reporter');
  v_alert := pg_temp.mk_alert('d20b', 'cash', 'at_or_below', 2.89, 0.100, 60);
  q1 := pg_temp.report('d20b', 'cash', 2.85, interval '90 minutes', 'd20b-reporter');
  perform pg_temp.expect(pg_temp.prep(q1) = '1/0' and pg_temp.verdict(v_alert, q1) = 'pending:threshold_crossed', 'D20e target reached: queued');
  perform pg_temp.give_up(v_alert);
  q2 := pg_temp.report('d20b', 'cash', 2.85, interval '1 minute', 'd20b-reporter');          -- the same price, long after the 60 minute cooldown
  perform pg_temp.expect(pg_temp.prep(q2) = '1/0' and pg_temp.verdict(v_alert, q2) = 'pending:threshold_met',
                         'D20f ...the lost notification does not pin "already notified at 2.85": the same price notifies');
end;
$$;

-- ==================================================================================================
-- D21: a notification delivered after the alert's payment method was switched must not write its price into the alert
-- ==================================================================================================
select pg_temp.mk_world('d21');
do $$
declare
  v_alert uuid;
  k1 uuid; c1 uuid;
begin
  perform pg_temp.report('d21', 'cash', 2.80, interval '115 minutes', 'd21-reporter');
  perform pg_temp.report('d21', 'credit', 3.10, interval '110 minutes', 'd21-reporter');
  v_alert := pg_temp.mk_alert('d21', 'credit', 'at_or_below', 2.89, 0.100, 60);
  k1 := pg_temp.report('d21', 'credit', 2.85, interval '30 minutes', 'd21-reporter');
  perform pg_temp.expect(pg_temp.prep(k1) = '1/0' and pg_temp.verdict(v_alert, k1) = 'pending:threshold_crossed', 'D21a a Credit notification is queued');
  update private.price_alerts set payment_type = 'cash' where id = v_alert;                -- the person switches the alert to CASH
  perform pg_temp.expect((select last_notified_price is null and payment_type = 'cash' from private.price_alerts where id = v_alert),
                         'D21b ...which clears the notification memory');
  perform pg_temp.deliver(v_alert, interval '2 hours');                                    -- the in-flight Credit notification is delivered now
  perform pg_temp.expect((select status from private.price_alert_deliveries where alert_id = v_alert and price_report_id = k1) = 'sent',
                         'D21c ...and it is still sent (it was decided under Credit)');
  perform pg_temp.expect((select last_notified_price is null from private.price_alerts where id = v_alert),
                         'D21d ...but its Credit price is NOT written into the Cash alert');
  c1 := pg_temp.report('d21', 'cash', 2.84, interval '1 minute', 'd21-reporter');
  perform pg_temp.expect(pg_temp.prep(c1) = '1/0' and pg_temp.verdict(v_alert, c1) = 'pending:threshold_met',
                         'D21e the first Cash report is judged like a never-notified Cash alert, not against a Credit price');
end;
$$;

-- ==================================================================================================
-- D22: a notification queued BEFORE migration B (no payment_type) still holds a legacy alert's cooldown
-- ==================================================================================================
select pg_temp.mk_world('d22');
do $$
declare
  v_alert uuid;
  r0 uuid; r1 uuid;
begin
  perform pg_temp.report('d22', 'unknown', 3.50, interval '110 minutes', 'd22-reporter');
  v_alert := pg_temp.mk_alert('d22', 'unknown', 'price_drop', null, 0.100, 360);
  r0 := pg_temp.report('d22', 'unknown', 3.30, interval '20 minutes', 'd22-reporter');
  -- what the previous engine left behind: a pending delivery with no payment_type
  insert into private.price_alert_deliveries (alert_id, price_report_id, push_device_id, observed_price, previous_price, status, reason_code, payment_type)
  select v_alert, r0, d.id, 3.30, 3.50, 'pending', 'price_dropped', null
  from private.price_alert_push_devices d join private.price_alerts a on a.installation_id = d.installation_id where a.id = v_alert;
  r1 := pg_temp.report('d22', 'unknown', 3.10, interval '5 minutes', 'd22-reporter');
  perform pg_temp.expect(pg_temp.prep(r1) = '0/1' and pg_temp.verdict(v_alert, r1) = 'skipped:cooldown',
                         'D22 the unsent notification queued by the previous engine holds the legacy alert''s cooldown (no duplicate right after the migration)');
end;
$$;

-- ==================================================================================================
-- D23: a notification queued under the OTHER payment method does not hold the new method's cooldown
-- ==================================================================================================
select pg_temp.mk_world('d23');
do $$
declare
  v_alert uuid;
  r1 uuid; r2 uuid;
begin
  perform pg_temp.report('d23', 'credit', 3.50, interval '115 minutes', 'd23-reporter');
  perform pg_temp.report('d23', 'cash', 3.40, interval '114 minutes', 'd23-reporter');
  v_alert := pg_temp.mk_alert('d23', 'credit', 'price_drop', null, 0.100, 360);
  r1 := pg_temp.report('d23', 'credit', 3.30, interval '100 minutes', 'd23-reporter');
  perform pg_temp.expect(pg_temp.prep(r1) = '1/0', 'D23a a Credit notification is queued and not yet sent');
  update private.price_alerts set payment_type = 'cash' where id = v_alert;                -- the person switches to Cash
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.40, 'D23b ...the reference moves to the Cash price');
  r2 := pg_temp.report('d23', 'cash', 3.25, interval '30 minutes', 'd23-reporter');         -- 15c below the Cash reference
  perform pg_temp.expect(pg_temp.prep(r2) = '1/0' and pg_temp.verdict(v_alert, r2) = 'pending:price_dropped',
                         'D23c the queued Credit notification does not hold the Cash alert''s cooldown');
end;
$$;

-- ==================================================================================================
-- D24: prepare takes the station-level advisory lock (the guard against the lock-order deadlock; PC5 races it)
-- ==================================================================================================
select pg_temp.mk_world('d24');
do $$
declare
  v_alert uuid;
  r1 uuid;
  v_key bigint;
begin
  perform pg_temp.report('d24', 'credit', 3.50, interval '110 minutes', 'd24-reporter');
  v_alert := pg_temp.mk_alert('d24', 'credit', 'price_drop', null, 0.100);
  r1 := pg_temp.report('d24', 'credit', 3.40, interval '30 minutes', 'd24-reporter');
  v_key := hashtextextended('price-alert-station:' || (select station_id::text from t_world where label = 'd24'), 0);
  perform pg_temp.expect(not exists (select 1 from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()
                                     and classid::bigint = ((v_key >> 32) & 4294967295) and objid::bigint = (v_key & 4294967295)),
                         'D24a before the call, this session holds no lock on the station');
  perform pg_temp.prep(r1);
  perform pg_temp.expect(exists (select 1 from pg_locks where locktype = 'advisory' and pid = pg_backend_pid() and objsubid = 1
                                 and classid::bigint = ((v_key >> 32) & 4294967295) and objid::bigint = (v_key & 4294967295)),
                         'D24b ...and prepare holds it (transaction level) until commit');
end;
$$;

-- ==================================================================================================
-- D25 (Phase 3C.1): an OLDER client's save keeps a drop size the newer app chose, and the engine keeps using it;
--      a client that declared the contract can still deliberately choose 5 cents.
-- ==================================================================================================
select pg_temp.mk_world('d25');
do $$
declare
  v_inst uuid := (select installation_id from t_world where label = 'd25');
  v_station uuid := (select station_id from t_world where label = 'd25');
  v_alert uuid;
  r record;
  q1 uuid; q2 uuid; q3 uuid;
  v_before record;
begin
  perform pg_temp.report('d25', 'credit', 3.30, interval '110 minutes', 'd25-reporter');

  -- the 2.4.1 app creates a Credit alert with a 20 cent drop
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.200, 360, 'credit', true);
  v_alert := r.id;
  perform pg_temp.expect(r.minimum_change = 0.200 and r.payment_type = 'credit' and pg_temp.baseline(v_alert) = 3.30,
                         'D25a the 2.4.1 app creates a credit alert at 20c, anchored to the credit price');
  update private.price_alerts set last_notified_price = 3.50, last_notified_at = now() - interval '7 hours' where id = v_alert;
  select baseline_price, baseline_at, last_notified_price, last_notified_at, cooldown_minutes, alert_mode, threshold_price
    into v_before from private.price_alerts where id = v_alert;

  -- an older client re-saves the alert: the fixed 0.05, no payment method. alert-input.ts decides "keep" (p_updates_min = false)
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.050, 360, null, false);
  perform pg_temp.expect(r.id = v_alert and r.minimum_change = 0.200 and r.payment_type = 'credit',
                         'D25b ...the older client''s save keeps the same alert, its 20c drop size and its credit method');
  perform pg_temp.expect((select baseline_price is not distinct from v_before.baseline_price and baseline_at is not distinct from v_before.baseline_at
                                 and last_notified_price is not distinct from v_before.last_notified_price
                                 and last_notified_at is not distinct from v_before.last_notified_at
                                 and cooldown_minutes = v_before.cooldown_minutes and alert_mode = v_before.alert_mode
                          from private.price_alerts where id = v_alert),
                         'D25c ...and neither the reference nor the notification history moved');

  -- the engine really judges with 20c: a 12c fall is not enough, the cumulative 25c fall is
  q1 := pg_temp.report('d25', 'credit', 3.18, interval '60 minutes', 'd25-reporter');
  perform pg_temp.expect(pg_temp.prep(q1) = '0/1' and pg_temp.verdict(v_alert, q1) = 'skipped:no_meaningful_drop',
                         'D25d a 12c fall does not alert a 20c alert (the older client did not reset it to 5c)');
  q2 := pg_temp.report('d25', 'credit', 3.05, interval '30 minutes', 'd25-reporter');
  perform pg_temp.expect(pg_temp.prep(q2) = '1/0' and pg_temp.verdict(v_alert, q2) = 'pending:price_dropped',
                         'D25e ...and the cumulative 25c fall alerts');
  perform pg_temp.deliver(v_alert, interval '7 hours');

  -- the same older client, again, with a stray non-default value: that is a value it meant, so it is stored
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.120, 360, null, true);
  perform pg_temp.expect(r.minimum_change = 0.120 and r.payment_type = 'credit', 'D25f an explicit non-default value from a pre-contract client is taken as meant');

  -- a client that declared the contract deliberately chooses 5 cents: that is applied, and the engine follows
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.050, 360, 'credit', true);
  perform pg_temp.expect(r.minimum_change = 0.050 and r.id = v_alert, 'D25g a deliberate 5c from a client that declared the contract is stored');
  q3 := pg_temp.report('d25', 'credit', 2.99, interval '5 minutes', 'd25-reporter');          -- 6c below the 3.05 reference
  perform pg_temp.expect(pg_temp.prep(q3) = '1/0' and pg_temp.verdict(v_alert, q3) = 'pending:price_dropped',
                         'D25h ...and a 6c fall now alerts');

  -- a request that does not name a drop size at all (a payment-only edit) leaves it alone
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.050, 360, 'cash', false);
  perform pg_temp.expect(r.minimum_change = 0.050 and r.payment_type = 'cash', 'D25i a payment-only edit changes the method and nothing else');
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.200, 360, 'cash', true);
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.050, 360, 'credit', false);
  perform pg_temp.expect(r.minimum_change = 0.200 and r.payment_type = 'credit', 'D25j ...and a payment-only edit leaves a 20c drop size at 20c');
  perform pg_temp.expect((select count(*) from private.price_alerts where installation_id = v_inst and station_id = v_station) = 1, 'D25k still exactly one alert');
end;
$$;

-- ==================================================================================================
-- D26 (Phase 3C.1): repeated identical saves are safe; harmless edits do not touch the notification memory
--      or the cooldown; a change of mode or method keeps the notification TIME (so the cooldown continues).
-- ==================================================================================================
select pg_temp.mk_world('d26');
do $$
declare
  v_inst uuid := (select installation_id from t_world where label = 'd26');
  v_station uuid := (select station_id from t_world where label = 'd26');
  v_alert uuid;
  r record;
  v_notified_at timestamptz;
  v_baseline_at timestamptz;
  q uuid; q2 uuid;
  i int;
begin
  perform pg_temp.report('d26', 'credit', 3.30, interval '110 minutes', 'd26-reporter');
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.100, 360, 'credit', true);
  v_alert := r.id;
  update private.price_alerts set last_notified_price = 3.20, last_notified_at = now() - interval '2 hours', baseline_price = 3.25 where id = v_alert;
  select last_notified_at, baseline_at into v_notified_at, v_baseline_at from private.price_alerts where id = v_alert;

  for i in 1 .. 3 loop
    select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.100, 360, 'credit', true);
  end loop;
  perform pg_temp.expect(r.id = v_alert and (select count(*) from private.price_alerts where installation_id = v_inst and station_id = v_station) = 1,
                         'D26a three identical saves leave one alert with the same id');
  perform pg_temp.expect((select baseline_price = 3.25 and baseline_at is not distinct from v_baseline_at
                                 and last_notified_price = 3.20 and last_notified_at is not distinct from v_notified_at
                                 and minimum_change = 0.100 and payment_type = 'credit' and enabled
                          from private.price_alerts where id = v_alert),
                         'D26b ...and the reference and the notification memory are exactly as they were');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert) = 0, 'D26c ...and saving queued nothing');

  -- harmless edits: another drop size and another cooldown, then back
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.200, 720, 'credit', true);
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.100, 360, 'credit', true);
  perform pg_temp.expect((select baseline_price = 3.25 and last_notified_price = 3.20 and last_notified_at is not distinct from v_notified_at
                          from private.price_alerts where id = v_alert),
                         'D26d editing the drop size and the cooldown does not touch the reference or the notification memory');

  -- the cooldown (notified 2 hours ago, 6 hour cooldown) still holds after all those saves: a qualifying fall is suppressed
  q := pg_temp.report('d26', 'credit', 3.05, interval '10 minutes', 'd26-reporter');           -- 20c below the 3.25 reference
  perform pg_temp.expect(pg_temp.prep(q) = '0/1' and pg_temp.verdict(v_alert, q) = 'skipped:cooldown',
                         'D26e repeated saves and edits did not clear the cooldown');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.25, 'D26f ...and a suppressed qualifying fall keeps the alert armed (reference unchanged)');

  -- a change of mode keeps the notification TIME (the cooldown continues) but forgets the old notified price
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'at_or_below', 2.89, 0.100, 360, 'credit', true);
  perform pg_temp.expect((select last_notified_price is null and last_notified_at is not distinct from v_notified_at from private.price_alerts where id = v_alert),
                         'D26g changing the mode clears the notified PRICE and keeps the notified TIME');
  -- a change of method does the same
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'at_or_below', 2.89, 0.100, 360, 'cash', true);
  perform pg_temp.expect((select last_notified_price is null and last_notified_at is not distinct from v_notified_at and payment_type = 'cash'
                          from private.price_alerts where id = v_alert),
                         'D26h changing the method does the same');
end;
$$;

-- ==================================================================================================
-- D27 (Phase 3C.1): moving a LEGACY alert to Cash or Credit through the real upsert. Only the method changes; the rule,
--      target, drop size and cooldown the alert had are exactly as they were; the reference is re-anchored to the new
--      method's own stream (or left empty when there is none); an unclassified report no longer reaches it.
-- ==================================================================================================
select pg_temp.mk_world('d27');
do $$
declare
  v_inst uuid := (select installation_id from t_world where label = 'd27');
  v_station uuid := (select station_id from t_world where label = 'd27');
  v_alert uuid;
  r record;
  v_notified_at timestamptz;
begin
  perform pg_temp.report('d27', 'unknown', 3.40, interval '3 hours', 'd27-reporter');
  perform pg_temp.report('d27', 'cash', 2.99, interval '2 hours', 'd27-reporter');
  perform pg_temp.report('d27', 'credit', 3.19, interval '90 minutes', 'd27-reporter');
  perform pg_temp.report('d27', 'same_for_both', 3.05, interval '60 minutes', 'd27-reporter');

  -- a legacy At or Below alert with a target, an odd drop size and a long cooldown, as an older client made it
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'at_or_below', 3.25, 0.070, 720, null, true);
  v_alert := r.id;
  perform pg_temp.expect(r.payment_type = 'unknown' and pg_temp.baseline(v_alert) = 3.40, 'D27a the legacy alert is anchored to the latest UNCLASSIFIED report');
  update private.price_alerts set last_notified_price = 3.60, last_notified_at = now() - interval '3 hours' where id = v_alert;
  select last_notified_at into v_notified_at from private.price_alerts where id = v_alert;

  -- the 2.4.1 app moves it to Cash: it sends the alert's own settings back unchanged, plus the choice
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'at_or_below', 3.25, 0.070, 720, 'cash', true);
  perform pg_temp.expect(r.id = v_alert and r.payment_type = 'cash' and r.alert_mode = 'at_or_below' and r.threshold_price = 3.250
                         and r.minimum_change = 0.070 and r.cooldown_minutes = 720,
                         'D27b only the payment type changed: same alert, mode, target, drop size and cooldown');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.05, 'D27c ...and the reference is the newest CASH-comparable report (a same_for_both 3.05 beats cash 2.99)');
  perform pg_temp.expect((select last_notified_price is null and last_notified_at is not distinct from v_notified_at from private.price_alerts where id = v_alert),
                         'D27d ...the notification time is kept (the cooldown continues), the old notified price is forgotten');

  -- an unclassified report after the move never reaches the typed alert
  declare v_late uuid;
  begin
    v_late := pg_temp.report('d27', 'unknown', 2.50, interval '5 minutes', 'd27-reporter');
    perform pg_temp.expect(pg_temp.prep(v_late) = '0/1' and pg_temp.verdict(v_alert, v_late) = 'skipped:payment_type_mismatch',
                           'D27e an unclassified report no longer reaches the alert that now watches Cash');
  end;
end;
$$;

select pg_temp.mk_world('d27b');
do $$
declare
  v_inst uuid := (select installation_id from t_world where label = 'd27b');
  v_station uuid := (select station_id from t_world where label = 'd27b');
  v_alert uuid;
  r record;
  q1 uuid; q2 uuid;
begin
  -- a legacy Price Drop alert at a station whose only reports are unclassified
  perform pg_temp.report('d27b', 'unknown', 3.40, interval '5 hours', 'd27b-reporter');
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.050, 360, null, true);
  v_alert := r.id;
  select * into r from pg_temp.api_set_alert(v_inst, v_station, 'price_drop', null, 0.050, 360, 'credit', true);
  perform pg_temp.expect(r.id = v_alert and r.payment_type = 'credit' and r.minimum_change = 0.050, 'D27f the legacy alert moves to Credit and keeps its 5c');
  perform pg_temp.expect(pg_temp.baseline(v_alert) is null, 'D27g ...with NO reference: there is no Credit price to anchor on, and none is invented from the unclassified one');
  q1 := pg_temp.report('d27b', 'credit', 3.00, interval '40 minutes', 'd27b-reporter');
  perform pg_temp.expect(pg_temp.prep(q1) = '0/1' and pg_temp.verdict(v_alert, q1) = 'skipped:baseline_established' and pg_temp.baseline(v_alert) = 3.00,
                         'D27h the next Credit report establishes the reference and notifies nobody');
  q2 := pg_temp.report('d27b', 'credit', 2.94, interval '20 minutes', 'd27b-reporter');
  perform pg_temp.expect(pg_temp.prep(q2) = '1/0' and pg_temp.verdict(v_alert, q2) = 'pending:price_dropped',
                         'D27i ...and a later 6c fall notifies (never the establishing report itself)');
end;
$$;

-- ==================================================================================================
-- G1: grants / ACL of the new internals, the index, re-apply
-- ==================================================================================================
do $$
declare
  f text;
begin
  foreach f in array array[
    'private.price_alert_reference_horizon()',
    'private.comparable_report_types(text)',
    'private.payment_type_is_comparable(text,text)',
    'private.latest_comparable_price_report(uuid,text)',
    'private.has_newer_comparable_price_report(uuid,text,timestamptz,timestamptz,uuid)',
    'private.evaluate_price_alert_v2(text,numeric,numeric,integer,numeric,numeric,interval,numeric,timestamptz,timestamptz,boolean)',
    'private.anchor_price_alert_baseline()',
    'private.prepare_price_alert_deliveries(uuid)'
  ] loop
    perform pg_temp.expect(not has_function_privilege('anon', f, 'execute') and not has_function_privilege('authenticated', f, 'execute')
                           and not has_function_privilege('public', f, 'execute'), 'G1 no public/anon/authenticated EXECUTE on ' || f);
    perform pg_temp.expect(has_function_privilege('postgres', f, 'execute'), 'G1 postgres can execute ' || f);
  end loop;
  perform pg_temp.expect(has_function_privilege('service_role', 'private.prepare_price_alert_deliveries(uuid)', 'execute'),
                         'G1 prepare keeps its service_role grant');
  perform pg_temp.expect(not has_function_privilege('anon', 'private.mark_price_alert_delivery_sent(uuid,integer)', 'execute')
                         and not has_function_privilege('authenticated', 'private.mark_price_alert_delivery_sent(uuid,integer)', 'execute')
                         and not has_function_privilege('public', 'private.mark_price_alert_delivery_sent(uuid,integer)', 'execute')
                         and has_function_privilege('service_role', 'private.mark_price_alert_delivery_sent(uuid,integer)', 'execute')
                         and has_function_privilege('postgres', 'private.mark_price_alert_delivery_sent(uuid,integer)', 'execute'),
                         'G1 mark_sent keeps exactly its ACL (postgres + service_role) after being replaced');
  perform pg_temp.expect((select prosecdef and coalesce(proconfig, '{}') @> array['search_path=""'] from pg_proc
                          where oid = 'private.mark_price_alert_delivery_sent(uuid,integer)'::regprocedure),
                         'G1 ...and stays SECURITY DEFINER with an empty search_path');
  perform pg_temp.expect(exists (select 1 from pg_indexes where schemaname = 'private' and tablename = 'price_alert_deliveries'
                                 and indexname = 'price_alert_deliveries_alert_queued_idx'
                                 and indexdef like '%(alert_id, created_at DESC)%' and indexdef like '%pending%processing%failed%'),
                         'G1 the queued-deliveries partial index exists');
  perform pg_temp.expect((select prosecdef from pg_proc where oid = 'private.prepare_price_alert_deliveries(uuid)'::regprocedure),
                         'G1 prepare stays SECURITY DEFINER');
  perform pg_temp.expect((select coalesce(p.proconfig, '{}') @> array['search_path=""'] from pg_proc p
                          where p.oid = 'private.prepare_price_alert_deliveries(uuid)'::regprocedure),
                         'G1 prepare pins an empty search_path');
  perform pg_temp.expect((select coalesce(p.proconfig, '{}') @> array['search_path=""'] from pg_proc p
                          where p.oid = 'private.anchor_price_alert_baseline()'::regprocedure and p.prosecdef),
                         'G1 the anchor trigger function is SECURITY DEFINER with an empty search_path');
  perform pg_temp.expect((select coalesce(p.proconfig, '{}') @> array['search_path=""'] from pg_proc p
                          where p.oid = 'private.evaluate_price_alert_v2(text,numeric,numeric,integer,numeric,numeric,interval,numeric,timestamptz,timestamptz,boolean)'::regprocedure),
                         'G1 the pure decision function pins an empty search_path');
  perform pg_temp.expect(exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'e85_price_reports'
                                 and indexname = 'e85_price_reports_station_payment_latest_idx'
                                 and indexdef like '%(station_id, payment_type, reported_at DESC, created_at DESC)%'),
                         'G1 the payment/latest index exists with the intended columns');
  perform pg_temp.expect(exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'e85_price_reports'
                                 and indexname = 'e85_price_reports_station_latest_idx'), 'G1 the legacy latest index is untouched');
  perform pg_temp.expect(has_column_privilege('anon', 'public.e85_price_reports', 'payment_type', 'insert')
                         and has_column_privilege('authenticated', 'public.e85_price_reports', 'payment_type', 'insert'),
                         'G1 clients may INSERT the column');
  perform pg_temp.expect(not has_column_privilege('anon', 'public.e85_price_reports', 'payment_type', 'update')
                         and not has_column_privilege('anon', 'public.e85_price_reports', 'id', 'insert'),
                         'G1 ...and nothing else widened');
  perform pg_temp.expect(not has_table_privilege('anon', 'private.price_alerts', 'select')
                         and not has_table_privilege('authenticated', 'private.price_alerts', 'insert'),
                         'G1 private alert tables stay closed to clients');
end;
$$;

\ir ../migrations/20261007120000_community_price_payment_type.sql
\ir ../migrations/20261007130000_price_alert_payment_aware_evaluation.sql

do $$
begin
  perform pg_temp.expect((select count(*) from pg_trigger where tgrelid = 'private.price_alerts'::regclass and tgname = 'price_alerts_anchor_baseline') = 1,
                         'G1 re-applying B leaves exactly one anchor trigger');
  perform pg_temp.expect((select count(*) from pg_constraint where conname = 'e85_price_reports_payment_type_check' and convalidated) = 1,
                         'G1 re-applying A leaves exactly one validated CHECK (D13 had dropped it; A restores it)');
end;
$$;

-- ==================================================================================================
-- D19: the documented fail-closed PAUSE. Replacing prepare_price_alert_deliveries with a no-op decides nothing and
--      queues nothing (an alert is never evaluated by the OLD engine, which compares across payment methods),
--      keeps the function's ACL, and re-applying migration B puts the real engine back. The statement below is
--      the one in docs/PRICE_ALERTS_PAYMENT_TYPES_2.4.1.md (section 10); keep the two identical.
-- ==================================================================================================
select pg_temp.mk_world('d19');
do $$
declare
  v_alert uuid;
begin
  perform pg_temp.report('d19', 'credit', 3.19, interval '120 minutes', 'd19-reporter');
  v_alert := pg_temp.mk_alert('d19', 'credit', 'price_drop', null, 0.100);
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.19, 'D19a the alert is armed at the credit price');
end;
$$;

create or replace function private.prepare_price_alert_deliveries(p_price_report_id uuid)
returns table(pending_count integer, skipped_count integer)
language sql
security definer
set search_path = ''
as $$ select 0, 0 $$;

do $$
declare
  v_alert uuid := (select a.id from private.price_alerts a join t_world w on w.station_id = a.station_id where w.label = 'd19');
  v_drop uuid;
begin
  v_drop := pg_temp.report('d19', 'credit', 3.00, interval '30 minutes', 'd19-reporter');   -- a 19c fall: would fire
  perform pg_temp.expect(pg_temp.prep(v_drop) = '0/0', 'D19b paused: the report is "decided" as nothing');
  perform pg_temp.expect((select count(*) from private.price_alert_deliveries where alert_id = v_alert) = 0,
                         'D19c ...no delivery of any status exists (nothing queued, nothing skipped)');
  perform pg_temp.expect(pg_temp.baseline(v_alert) = 3.19 and (select last_notified_at is null from private.price_alerts where id = v_alert),
                         'D19d ...and no alert state moved');
  perform pg_temp.expect(not has_function_privilege('anon', 'private.prepare_price_alert_deliveries(uuid)', 'execute')
                         and not has_function_privilege('authenticated', 'private.prepare_price_alert_deliveries(uuid)', 'execute')
                         and has_function_privilege('service_role', 'private.prepare_price_alert_deliveries(uuid)', 'execute'),
                         'D19e ...and the ACL is unchanged by the replacement');
end;
$$;

\ir ../migrations/20261007130000_price_alert_payment_aware_evaluation.sql

do $$
declare
  v_alert uuid := (select a.id from private.price_alerts a join t_world w on w.station_id = a.station_id where w.label = 'd19');
  v_next uuid;
begin
  v_next := pg_temp.report('d19', 'credit', 2.95, interval '10 minutes', 'd19-reporter');
  perform pg_temp.expect(pg_temp.prep(v_next) = '1/0' and pg_temp.verdict(v_alert, v_next) = 'pending:price_dropped',
                         'D19f re-applying migration B restores the real engine: the next qualifying report fires');
end;
$$;

rollback;

\echo ALL PRICE ALERT PAYMENT-TYPE SCENARIOS PASSED (R1, C1, E1, D1-D27, G1)

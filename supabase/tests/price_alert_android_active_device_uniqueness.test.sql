-- 85Blends 2.4.1 — Price Alerts: the Android active-device invariant.
-- Covers supabase/migrations/20261006000000_price_alert_android_active_device_uniqueness.sql.
--
-- LOCAL-REPLAY ONLY (see README.md): run with psql against a scratch database that already has the FULL
-- migration chain applied. One transaction, rolled back; it RAISEs on any unexpected outcome and
-- reaching the final \echo line is a full pass. Multi-session behavior (the real price-alerts-api under
-- concurrent registrations) lives in price_alert_api_android_registration.test.sh.
--
-- WHAT THIS COVERS
--   U1   the index exists, is UNIQUE and partial: (installation_id, bundle_id) WHERE android AND enabled AND
--        invalidated_at IS NULL.
--   U2   a second active Android device for the same installation + package is rejected by the database
--        (unique_violation), while different packages, different installations, disabled and invalidated
--        rows are unrestricted.
--   U3   re-enabling a disabled row is rejected while another is active and works after the other is
--        deactivated.
--   U4   the exact statements price-alerts-api's registerDevice runs (deactivate the others, upsert on
--        (bundle_id, device_token_hash) for Android) leave exactly ONE active token across sequential
--        registrations; the replacement is active and the previous token is disabled + invalidated.
--   U5   registrations of different installations are independent.
--   U6   iOS is unchanged: the pre-existing iOS one-active index still applies per (installation, bundle,
--        environment); an iOS and an Android active device may coexist for one installation, even when
--        the bundle/package string is identical; the Android index never matches iOS rows.
--   U7   re-applying the migration is a no-op.

begin;

create function pg_temp.expect(p_ok boolean, p_label text) returns void language plpgsql as $$
begin
  if p_ok is distinct from true then
    raise exception 'FAILED: %', p_label;
  end if;
end;
$$;

-- true when the statement raises the given SQLSTATE
create function pg_temp.raises_state(p_sql text, p_state text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return sqlstate = p_state;
end;
$$;

create temp table t_ids (k text primary key, v uuid);
insert into private.price_alert_installations (client_installation_id, installation_secret_hash, client_platform)
values (gen_random_uuid(), repeat('a', 64), 'android'),
       (gen_random_uuid(), repeat('b', 64), 'android'),
       (gen_random_uuid(), repeat('c', 64), 'ios');
insert into t_ids select 'i1', id from private.price_alert_installations where installation_secret_hash = repeat('a', 64);
insert into t_ids select 'i2', id from private.price_alert_installations where installation_secret_hash = repeat('b', 64);
insert into t_ids select 'i3', id from private.price_alert_installations where installation_secret_hash = repeat('c', 64);

-- Android device factory: p_inst key, package, a unique token tag, state.
create function pg_temp.android(p_inst text, p_pkg text, p_tag text, p_enabled boolean default true, p_invalidated boolean default false)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into private.price_alert_push_devices
    (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash, enabled, invalidated_at)
  values ((select v from t_ids where k = p_inst), 'android', p_pkg, null, 'fcm-token-' || p_tag || repeat('x', 30),
          md5(p_tag) || md5(p_tag || '2'), p_enabled, case when p_invalidated then now() else null end)
  returning id into v_id;
  return v_id;
end;
$$;

-- U1 ------------------------------------------------------------------------------------------------
do $$
declare v_def text;
begin
  select indexdef into v_def from pg_indexes where schemaname = 'private' and indexname = 'price_alert_push_devices_one_active_android_per_install_idx';
  perform pg_temp.expect(v_def is not null, 'U1 the Android active-device index exists');
  perform pg_temp.expect(v_def ~ '^CREATE UNIQUE INDEX', 'U1 it is UNIQUE (got: ' || v_def || ')');
  perform pg_temp.expect(v_def ~ '\(installation_id, bundle_id\)', 'U1 it is on (installation_id, bundle_id)');
  perform pg_temp.expect(v_def ~ 'platform = ''android''::text' and v_def ~ 'enabled = true' and v_def ~ 'invalidated_at IS NULL',
                         'U1 it is partial: android AND enabled AND invalidated_at IS NULL');
  perform pg_temp.expect((select count(*) from pg_indexes where schemaname = 'private' and tablename = 'price_alert_push_devices'
                          and indexdef ~ 'one_active') = 2, 'U1 exactly two one-active indexes: the original (iOS) and the Android one');
end;
$$;

-- U2 ------------------------------------------------------------------------------------------------
do $$
declare v_first uuid;
begin
  v_first := pg_temp.android('i1', 'com.e85blends.android', 'first');
  perform pg_temp.expect(pg_temp.raises_state($q$select pg_temp.android('i1', 'com.e85blends.android', 'second')$q$, '23505'),
                         'U2 a second ACTIVE Android device for the same installation + package violates the unique index');
  perform pg_temp.expect((select count(*) from private.price_alert_push_devices
                          where installation_id = (select v from t_ids where k = 'i1') and platform = 'android' and enabled and invalidated_at is null) = 1,
                         'U2 only one active row exists after the rejected insert');
  perform pg_temp.android('i1', 'com.e85blends.android.debug', 'otherpkg');
  perform pg_temp.android('i2', 'com.e85blends.android', 'otherinst');
  perform pg_temp.android('i1', 'com.e85blends.android', 'dis1', false, false);
  perform pg_temp.android('i1', 'com.e85blends.android', 'dis2', false, false);
  perform pg_temp.android('i1', 'com.e85blends.android', 'inv1', true, true);
  perform pg_temp.android('i1', 'com.e85blends.android', 'inv2', false, true);
  perform pg_temp.expect(true, 'U2 different package, different installation, disabled and invalidated rows are all unrestricted');
end;
$$;

-- U3: re-enabling ---------------------------------------------------------------------------------------
do $$
declare v_dis uuid; v_active uuid;
begin
  select id into v_dis from private.price_alert_push_devices where device_token_hash = md5('dis1') || md5('dis12');
  select id into v_active from private.price_alert_push_devices
    where installation_id = (select v from t_ids where k = 'i1') and bundle_id = 'com.e85blends.android' and platform = 'android' and enabled and invalidated_at is null;
  perform pg_temp.expect(pg_temp.raises_state(format('update private.price_alert_push_devices set enabled = true where id = %L', v_dis), '23505'),
                         'U3 re-enabling a disabled row while another is active is rejected');
  update private.price_alert_push_devices set enabled = false, invalidated_at = now() where id = v_active;
  update private.price_alert_push_devices set enabled = true where id = v_dis;
  perform pg_temp.expect((select enabled from private.price_alert_push_devices where id = v_dis), 'U3 after deactivating the other, the re-enable succeeds');
  update private.price_alert_push_devices set enabled = false where id = v_dis;
end;
$$;

-- U4/U5: the exact statements registerDevice(android) runs --------------------------------------------------
create function pg_temp.register_android(p_inst text, p_pkg text, p_token text) returns uuid language plpgsql as $$
declare
  v_inst uuid := (select v from t_ids where k = p_inst);
  v_hash text := encode(extensions.digest(p_token, 'sha256'), 'hex');
  v_id uuid;
begin
  -- the registration transaction body (lock + deactivate the others + upsert), as in price-alerts-api
  perform 1 from private.price_alert_installations where id = v_inst for no key update;
  update private.price_alert_push_devices
  set enabled = false, invalidated_at = coalesce(invalidated_at, now())
  where installation_id = v_inst and platform = 'android' and bundle_id = p_pkg
    and device_token_hash <> v_hash and enabled = true and invalidated_at is null;
  insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash, enabled, invalidated_at, last_registered_at)
  values (v_inst, 'android', p_pkg, null, p_token, v_hash, true, null, now())
  on conflict (bundle_id, device_token_hash) where platform = 'android' do update
  set installation_id = excluded.installation_id, platform = 'android', apns_environment = null, device_token = excluded.device_token,
      enabled = true, invalidated_at = null, last_registered_at = now(), failure_count = 0, last_failure_at = null
  returning id into v_id;
  return v_id;
end;
$$;

do $$
declare t1 uuid; t2 uuid; t3 uuid; r1 uuid; r2 uuid;
begin
  -- fresh package on installation i2 so the earlier fixture rows do not interfere
  t1 := pg_temp.register_android('i2', 'com.e85blends.reg', 'fcm-token-registration-one-0000000000');
  perform pg_temp.expect((select count(*) from private.price_alert_push_devices where installation_id = (select v from t_ids where k = 'i2')
                          and bundle_id = 'com.e85blends.reg' and enabled and invalidated_at is null) = 1, 'U4 first registration: one active token');
  t2 := pg_temp.register_android('i2', 'com.e85blends.reg', 'fcm-token-registration-two-0000000000');
  perform pg_temp.expect((select count(*) from private.price_alert_push_devices where installation_id = (select v from t_ids where k = 'i2')
                          and bundle_id = 'com.e85blends.reg' and enabled and invalidated_at is null) = 1, 'U4 second registration: still exactly one active token');
  perform pg_temp.expect((select enabled and invalidated_at is null from private.price_alert_push_devices where id = t2), 'U4 the replacement token is active');
  perform pg_temp.expect((select not enabled and invalidated_at is not null from private.price_alert_push_devices where id = t1), 'U4 the previous token is disabled and invalidated');
  t3 := pg_temp.register_android('i2', 'com.e85blends.reg', 'fcm-token-registration-three-00000000');
  perform pg_temp.expect((select count(*) from private.price_alert_push_devices where installation_id = (select v from t_ids where k = 'i2')
                          and bundle_id = 'com.e85blends.reg' and enabled and invalidated_at is null) = 1
                         and (select enabled from private.price_alert_push_devices where id = t3), 'U4 third registration: still one active token (the newest)');
  -- re-registering an old token revives it and retires the newest
  r1 := pg_temp.register_android('i2', 'com.e85blends.reg', 'fcm-token-registration-one-0000000000');
  perform pg_temp.expect(r1 = t1 and (select enabled and invalidated_at is null from private.price_alert_push_devices where id = t1)
                         and (select not enabled from private.price_alert_push_devices where id = t3)
                         and (select count(*) from private.price_alert_push_devices where installation_id = (select v from t_ids where k = 'i2')
                              and bundle_id = 'com.e85blends.reg' and enabled and invalidated_at is null) = 1,
                         'U4 re-registering an earlier token revives that row and retires the newest; still one active');

  -- U5: another installation, same package: independent
  r2 := pg_temp.register_android('i1', 'com.e85blends.reg', 'fcm-token-other-installation-00000000');
  perform pg_temp.expect((select count(*) from private.price_alert_push_devices where bundle_id = 'com.e85blends.reg' and enabled and invalidated_at is null) = 2,
                         'U5 two installations each keep their own active token for the same package');
  perform pg_temp.expect((select enabled from private.price_alert_push_devices where id = t1), 'U5 registering for installation i1 did not touch installation i2''s token');
end;
$$;

-- U6: iOS unchanged ------------------------------------------------------------------------------------
do $$
declare v_inst uuid := (select v from t_ids where k = 'i3');
begin
  insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash, enabled)
  values (v_inst, 'ios', 'com.e85blends.shared', 'sandbox', repeat('a', 64), repeat('1', 64), true);
  perform pg_temp.expect(pg_temp.raises_state($q$insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash, enabled)
      select installation_id, 'ios', 'com.e85blends.shared', 'sandbox', repeat('b', 64), repeat('2', 64), true from private.price_alert_push_devices where device_token_hash = repeat('1', 64)$q$, '23505'),
    'U6 the original iOS one-active index still rejects a second active iOS device for (installation, bundle, environment)');
  insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash, enabled)
  values (v_inst, 'ios', 'com.e85blends.shared', 'production', repeat('c', 64), repeat('3', 64), true);
  perform pg_temp.expect(true, 'U6 iOS sandbox and production devices coexist (unchanged)');
  -- an Android device whose package string equals the iOS bundle id, same installation: allowed
  insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash, enabled)
  values (v_inst, 'android', 'com.e85blends.shared', null, 'fcm-token-coexist-' || repeat('z', 30), repeat('4', 64), true);
  perform pg_temp.expect((select count(*) from private.price_alert_push_devices where installation_id = v_inst and enabled and invalidated_at is null) = 3,
                         'U6 iOS (two environments) and Android devices coexist on one installation');
  perform pg_temp.expect(not exists (select 1 from pg_indexes where indexname = 'price_alert_push_devices_one_active_android_per_install_idx' and indexdef !~ 'android'),
                         'U6 the Android index predicate is android-only');
end;
$$;

-- U7: idempotent re-apply ----------------------------------------------------------------------------------
create temp table t_before as select md5(indexdef) as h from pg_indexes where indexname = 'price_alert_push_devices_one_active_android_per_install_idx';
-- (the re-apply runs the migration's precondition too: only one active Android row per pair exists above)
\ir ../migrations/20261006000000_price_alert_android_active_device_uniqueness.sql
do $$
begin
  perform pg_temp.expect((select count(*) from pg_indexes where indexname = 'price_alert_push_devices_one_active_android_per_install_idx') = 1
                         and (select h from t_before) = (select md5(indexdef) from pg_indexes where indexname = 'price_alert_push_devices_one_active_android_per_install_idx'),
                         'U7 re-applying the migration leaves exactly the same single index');
end;
$$;

rollback;

\echo ALL PRICE ALERT ANDROID ACTIVE-DEVICE UNIQUENESS SCENARIOS PASSED

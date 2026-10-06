#!/usr/bin/env bash
# 85Blends 2.4.1 — Price Alerts cross-platform (claim_price_alert_deliveries_v2) multi-session checks
# for supabase/migrations/20261005233000_price_alert_cross_platform_delivery_safety.sql.
#
# LOCAL-REPLAY ONLY. Needs a SCRATCH database that already has the full migration chain applied
# (see README.md in this directory) and standard libpq environment variables (PGHOST, PGPORT,
# PGUSER, PGDATABASE). Unlike the single-transaction .sql matrices this script COMMITS its fixtures
# (several sessions have to see them) under a unique marker and removes them again on exit — never
# point it at a hosted project.
#
# What it proves (each needs more than one session):
#   T1   a stale delivery row locked by ANOTHER transaction does not block a v2 claim (SKIP LOCKED) on
#        either platform: the call returns promptly, still returns the fresh deliveries, leaves the
#        locked row alone, and a later call expires it once the lock is released.
#   T1c  a FRESH (claimable) row locked by another transaction does not block the claim either.
#   T1b  a JOB row locked by another transaction does not block the sweep either.
#   T2   one v2 call expires AT MOST 500 rows of a 20,000-row stale iOS backlog and does so quickly,
#        and does not touch the Android rows.
#   T3   concurrent workers (two iOS and two Android, as the live worker alternates them) never
#        double-claim, never deadlock or error, never receive a stale delivery, never receive a row
#        of the other platform, and together drain the fresh deliveries of both platforms.
set -euo pipefail

M="xconc$$"                       # unique marker for every row this script creates
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1)
TMP="$(mktemp -d)"

sql() { "${PSQL[@]}" -c "$1"; }

cleanup() {
  "${PSQL[@]}" -c "
    delete from public.e85_price_reports where anonymous_reporter_id like '$M-%';
    delete from private.price_alert_installations where installation_secret_hash in (md5('$M-i') || md5('$M-i2'), md5('$M-a') || md5('$M-a2'));
    delete from public.community_stations where normalized_key like '$M-%';
    drop table if exists public.${M}_log;" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAILED: $*" >&2; exit 1; }
now_ms() { date +%s%3N; }

# ---- fixtures (committed): one station with an alert for an iOS and an Android installation ---------
sql "
insert into public.community_stations (name, normalized_key) values ('XConcurrency N', '$M-n');
insert into private.price_alert_installations (client_installation_id, installation_secret_hash, client_platform) values
  (gen_random_uuid(), md5('$M-i') || md5('$M-i2'), 'ios'),
  (gen_random_uuid(), md5('$M-a') || md5('$M-a2'), 'android');
insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash)
  select id, 'ios', 'com.e85blends.app.ios.internal', 'sandbox', repeat('b', 64), md5('$M-ios') || md5('$M-ios2')
  from private.price_alert_installations where installation_secret_hash = md5('$M-i') || md5('$M-i2');
insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash)
  select id, 'android', 'com.e85blends.android', null, 'fcm-' || repeat('c', 60), md5('$M-and') || md5('$M-and2')
  from private.price_alert_installations where installation_secret_hash = md5('$M-a') || md5('$M-a2');
insert into private.price_alerts (installation_id, station_id)
  select i.id, (select id from public.community_stations where normalized_key = '$M-n')
  from private.price_alert_installations i where i.installation_secret_hash in (md5('$M-i') || md5('$M-i2'), md5('$M-a') || md5('$M-a2'));
create unlogged table public.${M}_log (sess text, delivery_id uuid);"

# mk_bulk <platform ios|android> <count> <report age e.g. '3 hours'> <tag>  -> that many PENDING deliveries
mk_bulk() {
  sql "
  with r as (
    insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id)
    select (select id from public.community_stations where normalized_key = '$M-n'), 3.49, now() - interval '$3', '$M-$4'
    from generate_series(1, $2) returning id)
  insert into private.price_alert_deliveries (alert_id, price_report_id, push_device_id, observed_price, status)
  select a.id, r.id, d.id, 3.49, 'pending'
  from r, private.price_alerts a
  join private.price_alert_installations i on i.id = a.installation_id
  join private.price_alert_push_devices d on d.installation_id = i.id and d.platform = '$1'
  where i.installation_secret_hash like case '$1' when 'ios' then md5('$M-i') else md5('$M-a') end || '%';"
}

count_by() { sql "select count(*) from private.price_alert_deliveries d join public.e85_price_reports r on r.id = d.price_report_id
                  where r.anonymous_reporter_id = '$M-$1' and $2"; }

# ======================================================================================================
echo "== T1: a stale row locked by another transaction must not block the claim (iOS and Android)"
for P in ios android; do
  mk_bulk "$P" 50 '3 hours' "stale1$P"
  mk_bulk "$P" 3 '5 minutes' "fresh1$P"
  LOCKED_ID="$(sql "select d.id from private.price_alert_deliveries d join public.e85_price_reports r on r.id = d.price_report_id
                    where r.anonymous_reporter_id = '$M-stale1$P' order by d.id limit 1")"
  ( "${PSQL[@]}" -c "begin; select id from private.price_alert_deliveries where id = '$LOCKED_ID' for update; select pg_sleep(8); commit;" >"$TMP/a$P.out" 2>&1 ) &
  A_PID=$!
  sleep 1.5
  START=$(now_ms)
  RETURNED="$(sql "select count(*) from private.claim_price_alert_deliveries_v2(100, '$P')")"
  ELAPSED=$(( $(now_ms) - START ))
  echo "   [$P] claim while a stale row is locked elsewhere: returned=$RETURNED in ${ELAPSED} ms"
  [ "$ELAPSED" -lt 4000 ] || fail "T1 [$P] the claim BLOCKED behind a locked stale row (${ELAPSED} ms; the lock is held for 8000 ms)"
  [ "$RETURNED" = "3" ] || fail "T1 [$P] expected the 3 fresh deliveries while a stale row is locked, got $RETURNED"
  [ "$(sql "select status from private.price_alert_deliveries where id = '$LOCKED_ID'")" = "pending" ] \
    || fail "T1 [$P] the locked stale row must be left alone (skipped, not waited for)"
  [ "$(count_by "stale1$P" "d.status = 'skipped' and d.last_error_code = 'stale_report'")" = "49" ] \
    || fail "T1 [$P] the 49 unlocked stale rows should have been expired"
  wait "$A_PID"
  grep -qi error "$TMP/a$P.out" && fail "T1 [$P] lock-holder session errored: $(cat "$TMP/a$P.out")"
  sql "select count(*) from private.claim_price_alert_deliveries_v2(100, '$P')" >/dev/null
  [ "$(sql "select status || ':' || last_error_code from private.price_alert_deliveries where id = '$LOCKED_ID'")" = "skipped:stale_report" ] \
    || fail "T1 [$P] once the lock was released a later call must expire the row"
done
# a lock on an ANDROID stale row must not delay an iOS call either
mk_bulk android 20 '3 hours' stale1x
mk_bulk ios 3 '5 minutes' fresh1x
XL_ID="$(sql "select d.id from private.price_alert_deliveries d join public.e85_price_reports r on r.id = d.price_report_id
              where r.anonymous_reporter_id = '$M-stale1x' order by d.id limit 1")"
( "${PSQL[@]}" -c "begin; select id from private.price_alert_deliveries where id = '$XL_ID' for update; select pg_sleep(6); commit;" >"$TMP/ax.out" 2>&1 ) &
AX_PID=$!
sleep 1.5
START=$(now_ms)
RETURNED="$(sql "select count(*) from private.claim_price_alert_deliveries_v2(100, 'ios')")"
ELAPSED=$(( $(now_ms) - START ))
echo "   [ios] claim while an ANDROID stale row is locked elsewhere: returned=$RETURNED in ${ELAPSED} ms"
[ "$ELAPSED" -lt 4000 ] || fail "T1 the ios claim was delayed by a locked Android row (${ELAPSED} ms)"
[ "$RETURNED" = "3" ] || fail "T1 expected the 3 fresh iOS deliveries, got $RETURNED"
[ "$(count_by stale1x "d.status = 'pending'")" = "20" ] || fail "T1 the ios call must not have touched any Android row"
wait "$AX_PID"
sql "select count(*) from private.claim_price_alert_deliveries_v2(100, 'android')" >/dev/null
echo "   ok"

# ======================================================================================================
echo "== T1c: a FRESH (claimable) row locked by another transaction must not block the claim (SKIP LOCKED in the claim itself)"
for P in ios android; do
  mk_bulk "$P" 5 '5 minutes' "fresh1c$P"
  FL_ID="$(sql "select d.id from private.price_alert_deliveries d join public.e85_price_reports r on r.id = d.price_report_id
                where r.anonymous_reporter_id = '$M-fresh1c$P' order by d.id limit 1")"
  ( "${PSQL[@]}" -c "begin; select id from private.price_alert_deliveries where id = '$FL_ID' for update; select pg_sleep(8); commit;" >"$TMP/c$P.out" 2>&1 ) &
  C_PID=$!
  sleep 1.5
  START=$(now_ms)
  RETURNED="$(sql "select count(*) from private.claim_price_alert_deliveries_v2(100, '$P')")"
  ELAPSED=$(( $(now_ms) - START ))
  echo "   [$P] claim while a fresh row is locked elsewhere: returned=$RETURNED in ${ELAPSED} ms"
  [ "$ELAPSED" -lt 4000 ] || fail "T1c [$P] the claim BLOCKED behind a locked fresh row (${ELAPSED} ms; the lock is held for 8000 ms)"
  [ "$RETURNED" = "4" ] || fail "T1c [$P] expected the 4 unlocked fresh deliveries, got $RETURNED"
  [ "$(sql "select status from private.price_alert_deliveries where id = '$FL_ID'")" = "pending" ] \
    || fail "T1c [$P] the locked fresh row must be left alone"
  wait "$C_PID"
  grep -qi error "$TMP/c$P.out" && fail "T1c [$P] lock-holder session errored: $(cat "$TMP/c$P.out")"
  [ "$(sql "select count(*) from private.claim_price_alert_deliveries_v2(100, '$P')")" = "1" ] \
    || fail "T1c [$P] once the lock was released a later call must claim the row"
done
echo "   ok"

# ======================================================================================================
echo "== T1b: a JOB row locked by another transaction must not block the claim either"
mk_bulk ios 20 '3 hours' stale1b
JOB_REPORT="$(sql "select id from public.e85_price_reports where anonymous_reporter_id = '$M-stale1b' order by id limit 1")"
( "${PSQL[@]}" -c "begin; select id from private.price_alert_jobs where price_report_id = '$JOB_REPORT' for update; select pg_sleep(8); commit;" >"$TMP/b.out" 2>&1 ) &
B_PID=$!
sleep 1.5
START=$(now_ms)
sql "select count(*) from private.claim_price_alert_deliveries_v2(100, 'ios')" >/dev/null
ELAPSED=$(( $(now_ms) - START ))
echo "   claim while a job row is locked elsewhere: ${ELAPSED} ms"
[ "$ELAPSED" -lt 4000 ] || fail "T1b the claim BLOCKED behind a locked job row (${ELAPSED} ms; the lock is held for 8000 ms)"
[ "$(count_by stale1b "d.status = 'skipped' and d.last_error_code = 'stale_report'")" = "20" ] \
  || fail "T1b all 20 stale deliveries should be expired even though one job row was locked"
wait "$B_PID"
grep -qi error "$TMP/b.out" && fail "T1b lock-holder session errored: $(cat "$TMP/b.out")"
echo "   ok"

# ======================================================================================================
echo "== T2: one v2 call expires at most 500 of a 20,000-row stale iOS backlog and leaves Android alone"
mk_bulk ios 20000 '4 hours' stale2
mk_bulk android 100 '4 hours' stale2a
START=$(now_ms)
sql "select count(*) from private.claim_price_alert_deliveries_v2(100, 'ios')" >/dev/null
ELAPSED=$(( $(now_ms) - START ))
EXPIRED="$(count_by stale2 "d.status = 'skipped'")"
echo "   expired in ONE ios call: $EXPIRED of 20000 in ${ELAPSED} ms"
[ "$EXPIRED" = "500" ] || fail "T2 a single call must expire exactly 500 rows, expired $EXPIRED"
[ "$ELAPSED" -lt 5000 ] || fail "T2 a bounded sweep should be quick, took ${ELAPSED} ms"
[ "$(count_by stale2 "d.status = 'pending' and d.attempt_count = 0")" = "19500" ] || fail "T2 the un-swept stale rows must be untouched"
[ "$(count_by stale2a "d.status = 'pending' and d.attempt_count = 0")" = "100" ] || fail "T2 the ios call must not touch Android rows"
echo "   ok"

# ======================================================================================================
echo "== T3: concurrent workers (2 iOS + 2 Android): no double-claim, no stale send, no cross-platform, no deadlock"
mk_bulk ios 1500 '5 minutes' fresh3i
mk_bulk android 1500 '5 minutes' fresh3a
WORKER="do \$\$ declare i int; begin for i in 1..25 loop
          insert into public.${M}_log select 'SESS', delivery_id from private.claim_price_alert_deliveries_v2(100, 'PLAT'); end loop; end \$\$;"
run_worker() { local sess=$1 plat=$2 out=$3; local w="${WORKER//SESS/$sess}"; "${PSQL[@]}" -c "${w//PLAT/$plat}" >"$out" 2>&1; }
run_worker A ios "$TMP/w1.out" & W1=$!
run_worker B ios "$TMP/w2.out" & W2=$!
run_worker C android "$TMP/w3.out" & W3=$!
run_worker D android "$TMP/w4.out" & W4=$!
wait "$W1"; wait "$W2"; wait "$W3"; wait "$W4"
if grep -qiE 'error|deadlock' "$TMP"/w[1-4].out; then fail "T3 a worker errored: $(cat "$TMP"/w[1-4].out)"; fi

DUPES="$(sql "select count(*) from (select delivery_id from public.${M}_log group by delivery_id having count(*) > 1) x")"
STALE_SENT="$(sql "select count(*) from public.${M}_log l join private.price_alert_deliveries d on d.id = l.delivery_id
                   join public.e85_price_reports r on r.id = d.price_report_id
                   where r.anonymous_reporter_id in ('$M-stale1ios','$M-stale1android','$M-stale1x','$M-stale1b','$M-stale2','$M-stale2a')")"
CROSS="$(sql "select count(*) from public.${M}_log l join private.price_alert_deliveries d on d.id = l.delivery_id
              join private.price_alert_push_devices pd on pd.id = d.push_device_id
              where (l.sess in ('A','B') and pd.platform <> 'ios') or (l.sess in ('C','D') and pd.platform <> 'android')")"
FRESH_I="$(sql "select count(*) from public.${M}_log l join private.price_alert_deliveries d on d.id = l.delivery_id
                join public.e85_price_reports r on r.id = d.price_report_id where r.anonymous_reporter_id = '$M-fresh3i'")"
FRESH_A="$(sql "select count(*) from public.${M}_log l join private.price_alert_deliveries d on d.id = l.delivery_id
                join public.e85_price_reports r on r.id = d.price_report_id where r.anonymous_reporter_id = '$M-fresh3a'")"
echo "   returned: duplicates=$DUPES stale=$STALE_SENT cross_platform=$CROSS fresh_ios(of 1500)=$FRESH_I fresh_android(of 1500)=$FRESH_A"
[ "$DUPES" = "0" ] || fail "T3 $DUPES delivery(ies) were handed to two workers"
[ "$STALE_SENT" = "0" ] || fail "T3 $STALE_SENT stale deliveries were returned to a worker"
[ "$CROSS" = "0" ] || fail "T3 $CROSS deliveries were returned to a worker of the OTHER platform"
[ "$FRESH_I" = "1500" ] || fail "T3 expected all 1500 fresh iOS deliveries claimed exactly once, got $FRESH_I"
[ "$FRESH_A" = "1500" ] || fail "T3 expected all 1500 fresh Android deliveries claimed exactly once, got $FRESH_A"
[ "$(count_by stale2 "d.status = 'skipped'")" -gt 500 ] || fail "T3 the stale iOS backlog did not keep draining (still ~500 expired)"
echo "   ok"

echo "ALL PRICE ALERT CROSS-PLATFORM CONCURRENCY SCENARIOS PASSED"

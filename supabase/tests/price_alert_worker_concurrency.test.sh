#!/usr/bin/env bash
# 85Blends 2.4.1 — Price Alerts multi-session concurrency checks for
# supabase/migrations/20261005120000_price_alert_worker_scheduler_and_freshness.sql.
#
# LOCAL-REPLAY ONLY. Needs a SCRATCH database that already has the full migration chain applied
# (see README.md in this directory) and standard libpq environment variables (PGHOST, PGPORT,
# PGUSER, PGDATABASE). Unlike the single-transaction .sql matrices this script COMMITS its fixtures
# (several sessions have to see them) under a unique marker and removes them again on exit.
#
# What it proves (each needs more than one session, so it cannot live in the SQL matrix):
#   T1  a stale delivery row locked by ANOTHER transaction does not block a claim call (SKIP LOCKED):
#       the call returns promptly, still returns the fresh deliveries, leaves the locked row alone,
#       and a later call expires it once the lock is released.
#   T2  one claim call expires AT MOST 500 rows out of a 20,000-row stale backlog (bounded
#       transaction) and does so quickly.
#   T3  two workers claiming at once never double-claim, never deadlock or error, never receive a
#       stale delivery (the claim predicate excludes stale rows on its own while the backlog is only
#       partially drained), and together drain the fresh deliveries.
set -euo pipefail

M="conc$$"                       # unique marker for every row this script creates
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1)
TMP="$(mktemp -d)"
FAILED=0

sql() { "${PSQL[@]}" -c "$1"; }

cleanup() {
  "${PSQL[@]}" -c "
    delete from public.e85_price_reports where anonymous_reporter_id like '$M-%';
    delete from private.price_alert_installations where revenuecat_app_user_id = '$M';
    delete from private.revenuecat_customers where original_app_user_id = '$M';
    delete from public.community_stations where normalized_key like '$M-%';
    drop table if exists public.${M}_log;" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAILED: $*" >&2; FAILED=1; exit 1; }
now_ms() { date +%s%3N; }

# ---- fixtures (committed): one station without alerts, one usable installation/device/alert -------
sql "
insert into public.community_stations (name, normalized_key) values ('Concurrency N', '$M-n');
insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active)
  values ('$M', 'SANDBOX', 'pro', true);
insert into private.price_alert_installations
  (client_installation_id, installation_secret_hash, revenuecat_app_user_id, revenuecat_environment, revenuecat_customer_id)
  select gen_random_uuid(), repeat('a', 64), '$M', 'SANDBOX', c.id from private.revenuecat_customers c where c.original_app_user_id = '$M';
insert into private.price_alert_push_devices (installation_id, bundle_id, apns_environment, device_token, device_token_hash)
  select i.id, 'com.e85blends.app.ios.internal', 'sandbox', repeat('b', 64), md5('$M') || md5('$M-2')
  from private.price_alert_installations i where i.revenuecat_app_user_id = '$M';
insert into private.price_alerts (installation_id, station_id)
  select i.id, (select id from public.community_stations where normalized_key = '$M-n')
  from private.price_alert_installations i where i.revenuecat_app_user_id = '$M';
create unlogged table public.${M}_log (sess text, delivery_id uuid);"

# mk_bulk <count> <report age e.g. '3 hours'> <tag>   -> that many PENDING deliveries, one report each
mk_bulk() {
  sql "
  with r as (
    insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id)
    select (select id from public.community_stations where normalized_key = '$M-n'), 3.49, now() - interval '$2', '$M-$3'
    from generate_series(1, $1) returning id)
  insert into private.price_alert_deliveries (alert_id, price_report_id, push_device_id, observed_price, status)
  select a.id, r.id, d.id, 3.49, 'pending'
  from r, private.price_alerts a
  join private.price_alert_installations i on i.id = a.installation_id and i.revenuecat_app_user_id = '$M'
  join private.price_alert_push_devices d on d.installation_id = i.id;"
}

count_by() { sql "select count(*) from private.price_alert_deliveries d join public.e85_price_reports r on r.id = d.price_report_id
                  where r.anonymous_reporter_id = '$M-$1' and $2"; }

# ======================================================================================================
echo "== T1: a stale row locked by another transaction must not block the claim"
mk_bulk 50 '3 hours' stale1
mk_bulk 3 '5 minutes' fresh1
LOCKED_ID="$(sql "select d.id from private.price_alert_deliveries d join public.e85_price_reports r on r.id = d.price_report_id
                  where r.anonymous_reporter_id = '$M-stale1' order by d.id limit 1")"

# Session A: lock one stale delivery row and hold the lock for 8 seconds.
( "${PSQL[@]}" -c "begin; select id from private.price_alert_deliveries where id = '$LOCKED_ID' for update; select pg_sleep(8); commit;" >"$TMP/a.out" 2>&1 ) &
A_PID=$!
sleep 1.5

START=$(now_ms)
RETURNED="$(sql "select count(*) from private.claim_price_alert_deliveries(100)")"
ELAPSED=$(( $(now_ms) - START ))
echo "   claim while a stale row is locked elsewhere: returned=$RETURNED in ${ELAPSED} ms"
[ "$ELAPSED" -lt 4000 ] || fail "T1 the claim BLOCKED behind a locked stale row (${ELAPSED} ms; the lock is held for 8000 ms)"
[ "$RETURNED" = "3" ] || fail "T1 expected the 3 fresh deliveries to be returned while a stale row is locked, got $RETURNED"
[ "$(sql "select status from private.price_alert_deliveries where id = '$LOCKED_ID'")" = "pending" ] \
  || fail "T1 the locked stale row must be left alone (skipped, not waited for)"
[ "$(count_by stale1 "d.status = 'skipped' and d.last_error_code = 'stale_report'")" = "49" ] \
  || fail "T1 the 49 unlocked stale rows should have been expired"

wait "$A_PID"
grep -qi error "$TMP/a.out" && fail "T1 lock-holder session errored: $(cat "$TMP/a.out")"
sql "select count(*) from private.claim_price_alert_deliveries(100)" >/dev/null
[ "$(sql "select status || ':' || last_error_code from private.price_alert_deliveries where id = '$LOCKED_ID'")" = "skipped:stale_report" ] \
  || fail "T1 once the lock was released a later call must expire the row"
echo "   ok"

# ======================================================================================================
echo "== T1b: a JOB row locked by another transaction must not block the claim either"
# The alert fixture sits on the same station as the reports, so the real enqueue trigger creates a
# job per report. The sweep finalizes the jobs of the deliveries it expires; it must take each job
# row with SKIP LOCKED too and leave a locked one for its holder / the stale-job reclaim.
mk_bulk 20 '3 hours' stale1b
JOB_REPORT="$(sql "select id from public.e85_price_reports where anonymous_reporter_id = '$M-stale1b' order by id limit 1")"
( "${PSQL[@]}" -c "begin; select id from private.price_alert_jobs where price_report_id = '$JOB_REPORT' for update; select pg_sleep(8); commit;" >"$TMP/b.out" 2>&1 ) &
B_PID=$!
sleep 1.5
START=$(now_ms)
sql "select count(*) from private.claim_price_alert_deliveries(100)" >/dev/null
ELAPSED=$(( $(now_ms) - START ))
echo "   claim while a job row is locked elsewhere: ${ELAPSED} ms"
[ "$ELAPSED" -lt 4000 ] || fail "T1b the claim BLOCKED behind a locked job row (${ELAPSED} ms; the lock is held for 8000 ms)"
[ "$(count_by stale1b "d.status = 'skipped' and d.last_error_code = 'stale_report'")" = "20" ] \
  || fail "T1b all 20 stale deliveries should be expired even though one job row was locked"
wait "$B_PID"
grep -qi error "$TMP/b.out" && fail "T1b lock-holder session errored: $(cat "$TMP/b.out")"
echo "   ok"

# ======================================================================================================
echo "== T2: one claim call expires at most 500 of a 20,000-row stale backlog"
mk_bulk 20000 '4 hours' stale2
START=$(now_ms)
sql "select count(*) from private.claim_price_alert_deliveries(100)" >/dev/null
ELAPSED=$(( $(now_ms) - START ))
EXPIRED="$(count_by stale2 "d.status = 'skipped'")"
echo "   expired in ONE call: $EXPIRED of 20000 in ${ELAPSED} ms"
[ "$EXPIRED" = "500" ] || fail "T2 a single call must expire exactly 500 rows, expired $EXPIRED"
[ "$ELAPSED" -lt 5000 ] || fail "T2 a bounded sweep should be quick, took ${ELAPSED} ms"
[ "$(count_by stale2 "d.status = 'pending' and d.attempt_count = 0")" = "19500" ] \
  || fail "T2 the un-swept stale rows must be untouched"
echo "   ok"

# ======================================================================================================
echo "== T3: two concurrent workers: no double-claim, no stale send, no deadlock"
mk_bulk 2000 '5 minutes' fresh3
WORKER="do \$\$ declare i int; begin for i in 1..25 loop
          insert into public.${M}_log select 'SESS', delivery_id from private.claim_price_alert_deliveries(100); end loop; end \$\$;"
( "${PSQL[@]}" -c "${WORKER//SESS/A}" >"$TMP/w1.out" 2>&1 ) & W1=$!
( "${PSQL[@]}" -c "${WORKER//SESS/B}" >"$TMP/w2.out" 2>&1 ) & W2=$!
wait "$W1"; wait "$W2"
if grep -qiE 'error|deadlock' "$TMP/w1.out" "$TMP/w2.out"; then fail "T3 a worker errored: $(cat "$TMP/w1.out" "$TMP/w2.out")"; fi

DUPES="$(sql "select count(*) from (select delivery_id from public.${M}_log group by delivery_id having count(*) > 1) x")"
STALE_SENT="$(sql "select count(*) from public.${M}_log l join private.price_alert_deliveries d on d.id = l.delivery_id
                   join public.e85_price_reports r on r.id = d.price_report_id where r.anonymous_reporter_id in ('$M-stale1','$M-stale2')")"
FRESH_CLAIMED="$(sql "select count(*) from public.${M}_log l join private.price_alert_deliveries d on d.id = l.delivery_id
                      join public.e85_price_reports r on r.id = d.price_report_id where r.anonymous_reporter_id = '$M-fresh3'")"
echo "   returned: duplicates=$DUPES stale=$STALE_SENT fresh(of 2000)=$FRESH_CLAIMED"
[ "$DUPES" = "0" ] || fail "T3 $DUPES delivery(ies) were handed to two workers"
[ "$STALE_SENT" = "0" ] || fail "T3 $STALE_SENT stale deliveries were returned to a worker"
[ "$FRESH_CLAIMED" = "2000" ] || fail "T3 expected all 2000 fresh deliveries to be claimed exactly once, got $FRESH_CLAIMED"
[ "$(count_by stale2 "d.status = 'skipped'")" -gt 500 ] || fail "T3 the stale backlog did not keep draining (still ~500 expired)"
echo "   ok"

echo "ALL PRICE ALERT WORKER CONCURRENCY SCENARIOS PASSED"

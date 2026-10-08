#!/usr/bin/env bash
# 85Blends 2.4.1 — Phase 3C payment-aware Price Alerts: multi-session checks for
#   20261007130000_price_alert_payment_aware_evaluation.sql (prepare_price_alert_deliveries).
#
# LOCAL-REPLAY ONLY. Needs a SCRATCH database that already has the full migration chain applied (see
# README.md in this directory) and the libpq environment variables PGHOST, PGPORT, PGUSER, PGDATABASE of a
# LOCAL Postgres. Like the other concurrency scripts it COMMITS its fixtures (several sessions have to see
# them) under a unique marker and removes them on exit - never point it at a hosted project. It sends
# nothing: pg_net is a recording stand-in locally and the worker is never started.
#
# What it proves (each needs more than one session):
#   PC1  the cooldown race is closed. Report R1 is prepared (its notification queued) by one session that
#        has NOT committed yet; a newer qualifying report R2 is then prepared by a second session. The
#        second session WAITS for the first (station lock, then the alert row), sees the queued delivery,
#        and meets the cooldown: exactly ONE pending delivery results, never two.
#   PC2  the same report prepared by two sessions at once (the cron job and the worker can both do it)
#        decides once: one set of rows, one reservation.
#   PC3  a burst of typed reports from many concurrent clients (through the real RLS/grant path) while the
#        real job processor runs repeatedly: no error, no deadlock, no failed or dead job, every report
#        stored, and at most ONE pending delivery for the alert inside its cooldown.
#   PC4  the set_alert upsert (exactly as price-alerts-api runs it) racing a prepare on the same alert:
#        the upsert waits, neither deadlocks, and the final state is coherent (new sensitivity, same method,
#        the queued delivery intact).
#   PC5  the lock-order deadlock found in review: the every-minute job processor prepares several reports in
#        ONE transaction, so it holds a station's alert rows between two prepares; if a person saves a new
#        alert (a lower id) in that gap and the worker prepares a report of the same station, the two used to
#        lock the alert rows in opposite orders and deadlock. The station-level advisory lock taken first by
#        prepare_price_alert_deliveries serializes them: nothing fails, nothing is lost.
#   PC6  (Phase 3C.1) two saves of the same alert racing each other - one that changes only the payment method, one that
#        changes only the drop size, and an older client re-saving the fixed 0.05 - are serialized by the alert row and BOTH
#        changes survive, in either order (the upsert reads the row it is updating after the other commit, not a stale copy).
set -euo pipefail

M="ptc$$"                          # unique marker for every row this script creates
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1)
TMP="$(mktemp -d)"

case "${PGHOST:-/var/run/postgresql}" in
  /*|localhost|127.0.0.1|::1) ;;
  *) echo "REFUSING: PGHOST=${PGHOST} is not a local socket or loopback address" >&2; exit 2 ;;
esac

sql() { "${PSQL[@]}" -c "$1"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
now_ms() { date +%s%3N; }

cleanup() {
  "${PSQL[@]}" -c "
    delete from public.e85_price_reports where anonymous_reporter_id like '$M-%';
    drop trigger if exists ${M}_slow on private.price_alert_deliveries;
    drop function if exists public.${M}_slow();
    drop sequence if exists public.${M}_seq;
    delete from private.price_alert_installations where installation_secret_hash in (md5('$M-i') || md5('$M-i2'), md5('$M-i3') || md5('$M-i4'));
    delete from private.revenuecat_customers where original_app_user_id = '\$RCAnonymousID:$M';
    delete from public.community_stations where normalized_key like '$M-%';" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---- fixtures (committed) ----------------------------------------------------------------------------------
sql "
insert into public.community_stations (name, normalized_key) values ('PT Concurrency', '$M-s');
insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active)
  values ('\$RCAnonymousID:$M', 'SANDBOX', 'pro', true);
insert into private.price_alert_installations (client_installation_id, installation_secret_hash, revenuecat_app_user_id, revenuecat_environment, revenuecat_customer_id)
  select gen_random_uuid(), md5('$M-i') || md5('$M-i2'), c.original_app_user_id, 'SANDBOX', c.id
  from private.revenuecat_customers c where c.original_app_user_id = '\$RCAnonymousID:$M';
insert into private.price_alert_push_devices (installation_id, bundle_id, apns_environment, device_token, device_token_hash)
  select id, 'com.e85blends.app.ios.internal', 'sandbox', repeat('b', 64), md5('$M-d') || md5('$M-d2')
  from private.price_alert_installations where installation_secret_hash = md5('$M-i') || md5('$M-i2');
insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
  values ((select id from public.community_stations where normalized_key = '$M-s'), 3.50, now() - interval '110 minutes', '$M-base', 'credit');
insert into private.price_alerts (installation_id, station_id, alert_mode, minimum_change, cooldown_minutes, payment_type)
  select i.id, s.id, 'price_drop', 0.100, 360, 'credit'
  from private.price_alert_installations i, public.community_stations s
  where i.installation_secret_hash = md5('$M-i') || md5('$M-i2') and s.normalized_key = '$M-s';"

STATION="$(sql "select id from public.community_stations where normalized_key = '$M-s'")"
ALERT="$(sql "select a.id from private.price_alerts a where a.station_id = '$STATION'")"
INST="$(sql "select installation_id from private.price_alerts where id = '$ALERT'")"

[ "$(sql "select baseline_price from private.price_alerts where id = '$ALERT'")" = "3.500" ] || fail "fixture: the alert should be anchored at 3.50"

mk_report() { # <price> <age e.g. '20 minutes'> <tag>  -> report id
  sql "insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
       values ('$STATION', $1, now() - interval '$2', '$M-$3', 'credit') returning id"
}
upsert_sql() { # <minimum_change> <replaces an existing drop size: true|false> <payment_type|null>  -> exactly the statement price-alerts-api runs
  local pay="null::text"
  [ "$3" = "null" ] || pay="'$3'::text"
  echo "insert into private.price_alerts (installation_id, station_id, alert_mode, threshold_price, minimum_change, cooldown_minutes, payment_type, enabled)
        values ('$INST', '$STATION', 'price_drop', null, $1, 360, coalesce($pay, 'unknown'), true)
        on conflict (installation_id, station_id) do update
        set alert_mode = excluded.alert_mode, threshold_price = excluded.threshold_price,
            minimum_change = case when $2::boolean then excluded.minimum_change else private.price_alerts.minimum_change end,
            cooldown_minutes = excluded.cooldown_minutes, payment_type = coalesce($pay, private.price_alerts.payment_type), enabled = true
        returning minimum_change || ':' || payment_type"
}
reset_alert() { # back to a quiet, armed state
  sql "update private.price_alerts set baseline_price = 3.50, baseline_at = now() - interval '100 minutes',
         last_notified_price = null, last_notified_at = null where id = '$ALERT';
       delete from private.price_alert_deliveries where alert_id = '$ALERT';" >/dev/null
}
pending_count() { sql "select count(*) from private.price_alert_deliveries where alert_id = '$ALERT' and status = 'pending'"; }

# ======================================================================================================
echo "== PC1: the cooldown race is closed (the queued delivery holds the cooldown; the station lock serializes the two)"
R1="$(mk_report 3.30 '30 minutes' r1)"            # 20c below the 3.50 reference: qualifies
( "${PSQL[@]}" -c "begin; select pending_count from private.prepare_price_alert_deliveries('$R1'); select pg_sleep(4); commit;" >"$TMP/pc1a.out" 2>&1 ) &
A_PID=$!
sleep 1
R2="$(mk_report 3.10 '20 minutes' r2)"            # a NEWER report, a further 20c lower: also qualifies on its own
sleep 0.5
START=$(now_ms)
B_OUT="$(sql "select pending_count || '/' || skipped_count from private.prepare_price_alert_deliveries('$R2')")"
ELAPSED=$(( $(now_ms) - START ))
wait "$A_PID"
grep -qi error "$TMP/pc1a.out" && fail "PC1 first session errored: $(cat "$TMP/pc1a.out")"
echo "   second session waited ${ELAPSED} ms and decided $B_OUT"
[ "$ELAPSED" -ge 1500 ] || fail "PC1 the second session did not wait for the first (${ELAPSED} ms): the alert row is not being locked"
[ "$ELAPSED" -lt 20000 ] || fail "PC1 the second session took far too long (${ELAPSED} ms)"
[ "$B_OUT" = "0/1" ] || fail "PC1 the second report should be suppressed (got pending/skipped = $B_OUT)"
[ "$(pending_count)" = "1" ] || fail "PC1 exactly ONE pending delivery expected, got $(pending_count)"
[ "$(sql "select status || ':' || reason_code from private.price_alert_deliveries where alert_id = '$ALERT' and price_report_id = '$R2'")" = "skipped:cooldown" ] \
  || fail "PC1 the second report must be recorded as skipped:cooldown"
[ "$(sql "select baseline_price from private.price_alerts where id = '$ALERT'")" = "3.300" ] \
  || fail "PC1 the suppressed drop must leave the alert armed at the notified price 3.30"

# ======================================================================================================
echo "== PC2: one report prepared by two sessions at once is decided once"
reset_alert
R3="$(mk_report 3.20 '15 minutes' r3)"
( "${PSQL[@]}" -c "begin; select pending_count from private.prepare_price_alert_deliveries('$R3'); select pg_sleep(3); commit;" >"$TMP/pc2a.out" 2>&1 ) &
A_PID=$!
sleep 1
START=$(now_ms)
B_OUT="$(sql "select pending_count || '/' || skipped_count from private.prepare_price_alert_deliveries('$R3')")"
ELAPSED=$(( $(now_ms) - START ))
wait "$A_PID"
grep -qi error "$TMP/pc2a.out" && fail "PC2 first session errored: $(cat "$TMP/pc2a.out")"
echo "   second session waited ${ELAPSED} ms and decided $B_OUT"
[ "$ELAPSED" -ge 1000 ] || fail "PC2 the second session did not wait (${ELAPSED} ms)"
[ "$B_OUT" = "0/0" ] || fail "PC2 the second run must decide nothing (got $B_OUT)"
[ "$(sql "select count(*) from private.price_alert_deliveries where alert_id = '$ALERT' and price_report_id = '$R3'")" = "1" ] \
  || fail "PC2 exactly one delivery row for the report"
[ "$(pending_count)" = "1" ] || fail "PC2 exactly one pending delivery"

# ======================================================================================================
echo "== PC3: a burst of typed reports from concurrent clients while the real job processor runs"
reset_alert
sql "delete from private.price_alert_jobs where price_report_id in (select id from public.e85_price_reports where anonymous_reporter_id like '$M-%');" >/dev/null
BEFORE_REPORTS="$(sql "select count(*) from public.e85_price_reports where station_id = '$STATION'")"
for client in $(seq 1 12); do
  (
    "${PSQL[@]}" -c "
      begin;
      select set_config('request.jwt.claim.role', 'anon', true);
      set local role anon;
      insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
      select '$STATION', round((3.45 - (random() * 0.40))::numeric, 2), now() - (random() * interval '5 minutes'), '$M-burst$client', 'credit'
      from generate_series(1, 5);
      commit;" >"$TMP/burst$client.out" 2>&1
  ) &
done
( for round in $(seq 1 8); do
    "${PSQL[@]}" -c "select claimed_count || '/' || prepared_count || '/' || failed_count from private.process_price_alert_jobs(50)" >>"$TMP/processor.out" 2>&1
    sleep 0.4
  done ) &
PROC_PID=$!
wait
for client in $(seq 1 12); do
  grep -qi error "$TMP/burst$client.out" && fail "PC3 client $client errored: $(cat "$TMP/burst$client.out")"
done
grep -qi error "$TMP/processor.out" && fail "PC3 the job processor errored: $(cat "$TMP/processor.out")"
# drain whatever is left
for round in 1 2 3; do sql "select * from private.process_price_alert_jobs(50)" >/dev/null; done
AFTER_REPORTS="$(sql "select count(*) from public.e85_price_reports where station_id = '$STATION'")"
[ $(( AFTER_REPORTS - BEFORE_REPORTS )) -eq 60 ] || fail "PC3 expected 60 new reports, saw $(( AFTER_REPORTS - BEFORE_REPORTS ))"
[ "$(sql "select count(*) from private.price_alert_jobs j join public.e85_price_reports r on r.id = j.price_report_id where r.anonymous_reporter_id like '$M-burst%' and j.status in ('failed','dead')")" = "0" ] \
  || fail "PC3 a job failed or died under concurrency"
[ "$(sql "select count(*) from private.price_alert_jobs j join public.e85_price_reports r on r.id = j.price_report_id where r.anonymous_reporter_id like '$M-burst%' and j.status = 'pending'")" = "0" ] \
  || fail "PC3 jobs were left unprocessed after draining"
PENDING="$(pending_count)"
echo "   60 typed reports stored, no job failed, pending deliveries for the alert: $PENDING"
[ "$PENDING" -le 1 ] || fail "PC3 more than one pending delivery inside the cooldown ($PENDING)"
[ "$(sql "select count(*) from (select alert_id, price_report_id, push_device_id from private.price_alert_deliveries group by 1,2,3 having count(*) > 1) d")" = "0" ] \
  || fail "PC3 a (alert, report, device) pair was decided twice"

# ======================================================================================================
echo "== PC4: the set_alert upsert racing a prepare on the same alert"
reset_alert
R4="$(mk_report 3.25 '0 seconds' r4)"       # observed 'now': newer than every report the burst stored
( "${PSQL[@]}" -c "begin; select pending_count from private.prepare_price_alert_deliveries('$R4'); select pg_sleep(3); commit;" >"$TMP/pc4a.out" 2>&1 ) &
A_PID=$!
sleep 1
START=$(now_ms)
UP="$(sql "$(upsert_sql 0.200 true null)")"
ELAPSED=$(( $(now_ms) - START ))
wait "$A_PID"
grep -qi error "$TMP/pc4a.out" && fail "PC4 the prepare session errored: $(cat "$TMP/pc4a.out")"
echo "   upsert waited ${ELAPSED} ms and returned $UP"
[ "$ELAPSED" -ge 1000 ] || fail "PC4 the upsert did not wait for the prepare's row lock (${ELAPSED} ms)"
[ "$UP" = "0.200:credit" ] || fail "PC4 the upsert must keep the method and set the sensitivity (got $UP)"
[ "$(sql "select observed_price from private.price_alert_deliveries where alert_id = '$ALERT' and status = 'pending'")" = "3.250" ] \
  || fail "PC4 the prepare's queued delivery must survive the upsert"
[ "$(pending_count)" = "1" ] || fail "PC4 the prepared delivery must still be pending"

# ======================================================================================================
echo "== PC5: a multi-job transaction, a new lower-id alert and a single prepare do not deadlock"
reset_alert
sql "update private.price_alert_jobs set status = 'completed' where status in ('pending', 'failed', 'processing');" >/dev/null   # a quiet queue: only this test's jobs
mk_report 3.46 '100 minutes' p5a >/dev/null
mk_report 3.45 '30 minutes' p5b >/dev/null
mk_report 3.44 '20 minutes' p5c >/dev/null
R5="$(mk_report 3.43 '10 minutes' p5d)"
[ "$(sql "select count(*) from private.price_alert_jobs where status = 'pending'")" = "4" ] || fail "PC5 expected exactly four pending jobs"
# Test-only stand-in for "other jobs in the same 50-job batch run between two prepares of this station": the job
# processor's session (application_name ${M}cron) sleeps 4 s once, inside its first prepare, while holding the alert rows.
sql "create sequence public.${M}_seq;
     create function public.${M}_slow() returns trigger language plpgsql as \$f\$
     begin
       if current_setting('application_name') = '${M}cron' and nextval('public.${M}_seq') = 1 then perform pg_sleep(4); end if;
       return new;
     end \$f\$;
     create trigger ${M}_slow before insert on private.price_alert_deliveries for each row execute function public.${M}_slow();" >/dev/null
sql "insert into private.price_alert_installations (client_installation_id, installation_secret_hash)
       values (gen_random_uuid(), md5('$M-i3') || md5('$M-i4'))" >/dev/null
INST3="$(sql "select id from private.price_alert_installations where installation_secret_hash = md5('$M-i3') || md5('$M-i4')")"
( PGAPPNAME="${M}cron" "${PSQL[@]}" -c "select claimed_count || '/' || prepared_count || '/' || failed_count from private.process_price_alert_jobs(50)" >"$TMP/pc5cron.out" 2>&1 ) &
CRON_PID=$!
sleep 1.5
# during the pause a person saves an alert whose id sorts BEFORE the existing one, then the worker prepares a report of the station
sql "insert into private.price_alerts (id, installation_id, station_id, alert_mode, minimum_change, cooldown_minutes, payment_type)
       values ('00000000-0000-4000-8000-0000000000c5', '$INST3', '$STATION', 'price_drop', 0.100, 360, 'credit')" >/dev/null
START=$(now_ms)
W_OUT="$("${PSQL[@]}" -c "select pending_count || '/' || skipped_count from private.prepare_price_alert_deliveries('$R5')" 2>&1 || true)"
ELAPSED=$(( $(now_ms) - START ))
wait "$CRON_PID"
echo "   worker prepare waited ${ELAPSED} ms and returned: $W_OUT; job processor returned: $(cat "$TMP/pc5cron.out")"
! grep -qi "deadlock" "$TMP/pc5cron.out" || fail "PC5 the job processor hit a deadlock: $(cat "$TMP/pc5cron.out")"
! echo "$W_OUT" | grep -qi "error\|deadlock" || fail "PC5 the worker's prepare failed: $W_OUT"
[ "$ELAPSED" -ge 1000 ] || fail "PC5 the worker's prepare did not wait for the job processor's transaction (${ELAPSED} ms): the station lock is not taken"
[ "$(cat "$TMP/pc5cron.out")" = "4/4/0" ] || fail "PC5 the job processor should claim, prepare and fail 4/4/0, got $(cat "$TMP/pc5cron.out")"
[ "$(sql "select count(*) from private.price_alert_jobs where status = 'failed'")" = "0" ] || fail "PC5 a job was marked failed"

# ======================================================================================================
echo "== PC6: two saves racing each other both survive (payment-only vs sensitivity-only, and an older client)"
race() { # <label> <holder statement> <waiter statement> <expected final min:payment>
  local label="$1" holder="$2" waiter="$3" expected="$4"
  ( "${PSQL[@]}" -c "begin; $holder; select pg_sleep(2.5); commit;" >"$TMP/pc6a.out" 2>&1 ) &
  local a_pid=$!
  sleep 1
  local start; start=$(now_ms)
  local out; out="$(sql "$waiter")"
  local elapsed=$(( $(now_ms) - start ))
  wait "$a_pid"
  grep -qi error "$TMP/pc6a.out" && fail "PC6 $label: the holder errored: $(cat "$TMP/pc6a.out")"
  echo "   $label: the second save waited ${elapsed} ms; it returned $out; the stored alert is $(sql "select minimum_change || ':' || payment_type from private.price_alerts where id = '$ALERT'")"
  [ "$elapsed" -ge 1000 ] || fail "PC6 $label: the second save did not wait for the first (${elapsed} ms)"
  [ "$(sql "select minimum_change || ':' || payment_type from private.price_alerts where id = '$ALERT'")" = "$expected" ] \
    || fail "PC6 $label: expected $expected, got $(sql "select minimum_change || ':' || payment_type from private.price_alerts where id = '$ALERT'")"
}
sql "update private.price_alerts set payment_type = 'cash', minimum_change = 0.100 where id = '$ALERT'" >/dev/null
# the holder changes only the method (a payment-only save); the waiter changes only the drop size
race "payment-only first, sensitivity-only second" "$(upsert_sql 0.050 false credit)" "$(upsert_sql 0.200 true null)" "0.200:credit"
# the holder changes only the drop size; the waiter changes only the method
sql "update private.price_alerts set payment_type = 'cash', minimum_change = 0.100 where id = '$ALERT'" >/dev/null
race "sensitivity-only first, payment-only second" "$(upsert_sql 0.300 true null)" "$(upsert_sql 0.050 false credit)" "0.300:credit"
# an older client re-saving the fixed 0.05 while a deliberate 15c is being saved
sql "update private.price_alerts set payment_type = 'credit', minimum_change = 0.100 where id = '$ALERT'" >/dev/null
race "a deliberate 15c first, an older client's fixed 0.05 second" "$(upsert_sql 0.150 true null)" "$(upsert_sql 0.050 false null)" "0.150:credit"
# the reverse: the older client holds the row, the deliberate 15c waits - the same outcome
sql "update private.price_alerts set payment_type = 'credit', minimum_change = 0.100 where id = '$ALERT'" >/dev/null
race "an older client's fixed 0.05 first, a deliberate 15c second" "$(upsert_sql 0.050 false null)" "$(upsert_sql 0.150 true null)" "0.150:credit"

echo "ALL PAYMENT-TYPE CONCURRENCY SCENARIOS PASSED (PC1-PC6)"

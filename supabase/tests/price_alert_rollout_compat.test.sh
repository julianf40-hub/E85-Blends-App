#!/usr/bin/env bash
# 85Blends 2.4.1 — Phase 3C.1: ROLLOUT COMPATIBILITY MATRIX for the two unapplied Phase 3C migrations
#   20261007120000_community_price_payment_type.sql   (A)
#   20261007130000_price_alert_payment_aware_evaluation.sql   (B)
# and the two Edge Functions, price-alerts-api and price-alerts-worker.
#
# WHY THIS EXISTS. Production runs the PREVIOUS Edge Functions against the PREVIOUS schema. Rolling the change out means
# moving four things (A, B, the API, the worker) one at a time, and any of the steps can be the one that fails or is
# paused. This script does not reason about the intermediate states, it BUILDS them on throwaway local databases and runs
# the real code in them: the previous functions are exported from git (OLD_REV, the Phase 3B tip: its function code is
# byte-identical to main's, which is what the owner reports is deployed - the hash step of the readiness document proves that
# against production before anything is changed), the new ones are this working tree, and every database state is a real
# replay of the migration chain.
#
# LOCAL-REPLAY ONLY. It builds its own scratch databases (names start with $DB_PREFIX, dropped first and last) on a LOCAL
# Postgres, starts Deno servers on loopback ports, and replaces fetch() in the worker with a recorder: nothing reaches a
# hosted project, Apple or Google. It refuses a non-local PGHOST. Needs: deno, curl, jq, openssl, psql, git, tar.
#
# WHAT IT PROVES (every line below is an assertion):
#   M1  API x database state. For each of {before A, A only, A+B}: the PREVIOUS API works in all three; the NEW API works only
#       once B is applied (before that set_alert and list_alerts fail with a 500 - it needs B's column and function), so the
#       order is A, B, THEN the API. Delete and status work either way.
#   M2  Worker x database state, with an ordinary legacy alert: the previous worker and the new worker both send exactly
#       the old wording in all three states; the new worker on a database without B degrades softly (a warning, no failure).
#   M3  A+B with a CASH/CREDIT alert and the PREVIOUS worker (the "B succeeded but the worker deploy did not" case): the
#       notification is still sent, for the right price, in the old wording without the price type; the new worker names it.
#   T1  Between A and B (A only): a typed report CAN make the previous engine alert a legacy alert (Credit 3.19 -> Cash 2.99
#       reads as a 20c drop). After B the same reports queue nothing. => apply B right after A; ship no typed-report client first.
#   T2  A notification queued by the previous engine before B is left alone by B and is delivered by the new worker in the
#       old wording; the next report inside the cooldown does not queue a duplicate.
#   T3  A report whose job is still QUEUED when B is applied is judged against itself and its drop is lost; the same report
#       processed first (the drained-queue procedure) alerts. => drain the queue before B.
#   T4  B that fails (a lock it cannot get, or an error at its very end) leaves NOTHING behind: no column, the same function
#       bodies, and the previous API still works. A second attempt then succeeds.
#   T5  A report submitted while B is running WAITS for B and then succeeds; its job is queued and decided by the new engine.
#   T6  The INCIDENT DRILL: the exact statements of docs/PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md section 9, run in order on an
#       A+B database with live-looking data - pause new decisions (the no-op engine), cancel what is queued but unsent, pause the
#       two Price Alerts cron jobs, resume (re-apply B, re-activate the jobs) - proving that every alert row keeps its
#       configuration, only the two Price Alerts jobs are touched, nothing queued is lost or re-sent, and the real engine is
#       back byte for byte.
#   T7  How long A holds its lock on the reports table as the table grows (informational; set ROLLOUT_MEASURE_A_ROWS=0 to skip).
#
# Usage: price_alert_rollout_compat.test.sh        Environment: PGHOST/PGPORT/PGUSER (a LOCAL Postgres), DENO, OLD_REV,
#        DB_PREFIX (default e85_rollout), API_PORT (8795), WORKER_PORT (8796), ROLLOUT_MEASURE_A_ROWS (default 300000).
set -euo pipefail

DENO="${DENO:-deno}"
OLD_REV="${OLD_REV:-1f88df0f2174f28e2c34fec0545d791eda3ae4c4}"
DB_PREFIX="${DB_PREFIX:-e85_rollout}"
API_PORT="${API_PORT:-8795}"
WORKER_PORT="${WORKER_PORT:-8796}"
MEASURE_ROWS="${ROLLOUT_MEASURE_A_ROWS:-300000}"
export PGHOST="${PGHOST:-/var/run/postgresql}" PGPORT="${PGPORT:-55432}" PGUSER="${PGUSER:-postgres}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
A="$REPO/supabase/migrations/20261007120000_community_price_payment_type.sql"
B="$REPO/supabase/migrations/20261007130000_price_alert_payment_aware_evaluation.sql"
WRAPPER="$HERE/support/worker_with_recorded_fetch.ts"
TMP="$(mktemp -d)"
KEY="synthetic-publishable-key-for-local-tests"
SERVICE_ROLE_KEY="local-test-service-role-key-rollout"
SERVER_PID=""

case "$PGHOST" in
  /*|localhost|127.0.0.1|::1) ;;
  *) echo "REFUSING: PGHOST=${PGHOST} is not a local socket or loopback address" >&2; exit 2 ;;
esac
for tool in "$DENO" curl jq openssl psql git tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAILED: '$tool' is required (set DENO=/path/to/deno if needed)" >&2; exit 1; }
done
git -C "$REPO" cat-file -e "${OLD_REV}^{commit}" 2>/dev/null \
  || { echo "FAILED: OLD_REV=$OLD_REV is not in this clone; set OLD_REV to the commit whose supabase/functions are deployed" >&2; exit 1; }

fail() { echo "FAILED: $*" >&2; exit 1; }
expect() { [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"; }
now_ms() { date +%s%3N; }
q() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }       # q <db> <sql>

stop_server() { if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""; fi; }
cleanup() {
  stop_server
  for db in pre a ab t1 t2 t3 t3c t4 t5 t7 big; do dropdb --if-exists "${DB_PREFIX}_$db" >/dev/null 2>&1 || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---- the previous functions, exactly as committed before Phase 3C --------------------------------------------------
mkdir -p "$TMP/old"
git -C "$REPO" archive "$OLD_REV" supabase/functions | tar -x -C "$TMP/old"
OLD_FN="$TMP/old/supabase/functions"
NEW_FN="$REPO/supabase/functions"
[ -f "$OLD_FN/price-alerts-api/index.ts" ] && [ -f "$OLD_FN/price-alerts-worker/index.ts" ] || fail "OLD_REV has no price-alerts functions"
! grep -q "payment_type" "$OLD_FN/price-alerts-api/index.ts" || fail "OLD_REV already knows payment_type: it is not the pre-Phase-3C backend"

# ---- throwaway signing keys ------------------------------------------------------------------------------------------
openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkcs8 -topk8 -nocrypt -out "$TMP/apns.p8" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/fcm.pem" 2>/dev/null
FCM_JSON="$(jq -cn --arg key "$(cat "$TMP/fcm.pem")" '{project_id:"local-test",client_email:"worker@local.invalid",private_key:$key}')"

# ---- database states ------------------------------------------------------------------------------------------------
db() { echo "${DB_PREFIX}_$1"; }
build() { # <label> pre|a|ab        pre = before A, a = A only, ab = A and B
  local name; name="$(db "$1")"
  case "$2" in
    pre) bash "$HERE/support/replay_migrations.sh" "$name" --before 20261007120000 >/dev/null ;;
    a)   bash "$HERE/support/replay_migrations.sh" "$name" --before 20261007130000 >/dev/null ;;
    ab)  bash "$HERE/support/replay_migrations.sh" "$name" >/dev/null ;;
  esac
}
apply_a() { PGOPTIONS="-c client_min_messages=warning" psql -X -q -v ON_ERROR_STOP=1 --single-transaction -d "$(db "$1")" -f "$A" >/dev/null; }
apply_b() { PGOPTIONS="-c client_min_messages=warning" psql -X -q -v ON_ERROR_STOP=1 --single-transaction -d "$(db "$1")" -f "$B" >/dev/null; }
db_url() { echo "postgresql://${PGUSER}@127.0.0.1:${PGPORT}/$(db "$1")"; }
has_column() { q "$(db "$1")" "select count(*) from information_schema.columns where table_schema = '$2' and table_name = '$3' and column_name = '$4'"; }
body_md5() { q "$(db "$1")" "select md5(prosrc) from pg_proc where oid = '$2'::regprocedure"; }

# ---- API servers ----------------------------------------------------------------------------------------------------
API_STARTS=0
start_api() { # <db label> <old|new>
  local dir="$NEW_FN/price-alerts-api"; [ "$2" = old ] && dir="$OLD_FN/price-alerts-api"
  stop_server
  API_STARTS=$((API_STARTS + 1)); local log="$TMP/api-$API_STARTS.log"     # one log per start: a shared one could still hold the previous "Listening"
  : > "$log"
  ( cd "$dir" && SUPABASE_DB_URL="$(db_url "$1")" SUPABASE_PUBLISHABLE_KEYS="{\"default\":\"$KEY\"}" \
      DENO_SERVE_ADDRESS="tcp:127.0.0.1:${API_PORT}" exec "$DENO" run --no-lock --config deno.json -A index.ts >"$log" 2>&1 ) &
  SERVER_PID=$!
  for _ in $(seq 1 120); do grep -q "Listening on" "$log" 2>/dev/null && break; sleep 0.5; done
  grep -q "Listening on" "$log" || fail "the $2 API did not start: $(cat "$log")"
}
CODE=""; BODY=""
call() { # <json>
  local out; out="$(curl -s -m 60 -X POST "http://127.0.0.1:${API_PORT}" -H 'content-type: application/json' -H "apikey: $KEY" -d "$1" -w '\n%{http_code}')"
  CODE="${out##*$'\n'}"; BODY="${out%$'\n'*}"
}

# A Pro installation and a station in <db label>; echoes nothing, sets ID/SECRET/STATION
pro_fixture() { # <db label> <tag>
  ID="$(cat /proc/sys/kernel/random/uuid)"; SECRET="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  q "$(db "$1")" "
    insert into public.community_stations (name, normalized_key) values ('Rollout $2', 'rollout-$2');
    insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active)
      values ('\$RCAnonymousID:rollout-$2', 'SANDBOX', 'pro', true);
    insert into private.revenuecat_aliases (app_user_id, environment, customer_id)
      select original_app_user_id, 'SANDBOX', id from private.revenuecat_customers where original_app_user_id = '\$RCAnonymousID:rollout-$2'
      on conflict do nothing;" >/dev/null
  STATION="$(q "$(db "$1")" "select id from public.community_stations where normalized_key = 'rollout-$2'")"
  PRO_USER="\$RCAnonymousID:rollout-$2"
}

echo "== building the database states (before A / A only / A+B)"
build pre pre; build a a; build ab ab
expect "the 'before A' database has neither new column" "$(has_column pre public e85_price_reports payment_type)$(has_column pre private price_alerts payment_type)" "00"
expect "the 'A only' database has the report column and not the alert column" "$(has_column a public e85_price_reports payment_type)$(has_column a private price_alerts payment_type)" "10"
expect "the 'A+B' database has both" "$(has_column ab public e85_price_reports payment_type)$(has_column ab private price_alerts payment_type)" "11"

# ======================================================================================================================
echo "== M1: API x database state"
# Five codes per run, in this order: bootstrap, set_alert (an OLDER client's request), list_alerts,
# set_alert (the 2.4.1 app's request: payment_type + alert_contract_version), delete_alert. status is checked separately.
declare -A API_EXPECT
API_EXPECT[old,pre]="200 200 200 200 200";  API_EXPECT[new,pre]="200 500 500 500 200"
API_EXPECT[old,a]="200 200 200 200 200";    API_EXPECT[new,a]="200 500 500 500 200"
API_EXPECT[old,ab]="200 200 200 200 200";   API_EXPECT[new,ab]="200 200 200 200 200"
for state in pre a ab; do
  for code in old new; do
    start_api "$state" "$code"
    pro_fixture "$state" "api-$code"
    HDR="\"client_installation_id\":\"$ID\",\"installation_secret\":\"$SECRET\""
    call "{\"action\":\"bootstrap\",$HDR,\"platform\":\"ios\",\"revenuecat_app_user_id\":\"$PRO_USER\",\"revenuecat_environment\":\"SANDBOX\"}"; c1=$CODE
    expect "M1 $code API on '$state': bootstrap is Pro" "$(jq -r '.pro_is_active' <<<"$BODY")" "true"
    call "{\"action\":\"set_alert\",$HDR,\"station_id\":\"$STATION\",\"alert_mode\":\"price_drop\",\"minimum_change\":0.05,\"cooldown_minutes\":360}"; c2=$CODE
    call "{\"action\":\"list_alerts\",$HDR}"; c3=$CODE
    call "{\"action\":\"set_alert\",$HDR,\"alert_contract_version\":2,\"station_id\":\"$STATION\",\"alert_mode\":\"price_drop\",\"payment_type\":\"credit\",\"minimum_change\":0.1,\"cooldown_minutes\":360}"; c4=$CODE
    stored_min="$(q "$(db "$state")" "select minimum_change from private.price_alerts where station_id = '$STATION'")"
    stored_pay="-"
    [ "$(has_column "$state" private price_alerts payment_type)" = "1" ] \
      && stored_pay="$(q "$(db "$state")" "select coalesce(payment_type, '-') from private.price_alerts where station_id = '$STATION'")"
    call "{\"action\":\"delete_alert\",$HDR,\"station_id\":\"$STATION\"}"; c5=$CODE
    call "{\"action\":\"status\",$HDR}"; c6=$CODE
    [ "$c6" = "200" ] || fail "M1 $code API on '$state': status answered $c6"
    got="$c1 $c2 $c3 $c4 $c5"
    expect "M1 $code API on '$state' (bootstrap, set_alert, list_alerts, set_alert from the 2.4.1 app, delete_alert)" "$got" "${API_EXPECT[$code,$state]}"
    case "$code,$state" in
      old,pre|old,a) expect "M1 previous API on '$state': the 2.4.1 app's request is accepted, its drop size applied, its extra fields ignored" "$stored_min $stored_pay" "0.100 -" ;;
      old,ab)        expect "M1 previous API on A+B: the 2.4.1 app's request is accepted; the alert stays a legacy one" "$stored_min $stored_pay" "0.100 unknown" ;;
      new,ab)        expect "M1 new API on A+B: the 2.4.1 app's request is applied in full" "$stored_min $stored_pay" "0.100 credit" ;;
      new,pre|new,a) expect "M1 new API on '$state': nothing was stored by the failed set_alert" "$stored_min" "" ;;
    esac
    echo "   $code API, database '$state': $got (status $c6)"
  done
done
stop_server
echo "   ok"

# ======================================================================================================================
# Worker fixtures: one iOS installation with one device and ONE alert at its own station; a baseline report, the alert, then
# a firing report (so a job is queued). <alert kind> is legacy or credit (credit needs B).
worker_fixture() { # <db label> <tag> <kind> <firing price>
  local name; name="$(db "$1")"; local m="wrk-$2"
  q "$name" "
    insert into public.community_stations (name, normalized_key) values ('Rollout $2', '$m-s');
    insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active)
      values ('\$RCAnonymousID:$m', 'SANDBOX', 'pro', true);
    insert into private.price_alert_installations (client_installation_id, installation_secret_hash, client_platform, revenuecat_app_user_id, revenuecat_environment, revenuecat_customer_id)
      select gen_random_uuid(), md5('$m') || md5('$m-h'), 'ios', c.original_app_user_id, 'SANDBOX', c.id from private.revenuecat_customers c where c.original_app_user_id = '\$RCAnonymousID:$m';
    insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash)
      select id, 'ios', 'com.e85blends.app.ios.internal', 'sandbox', repeat('a', 64), md5('$m-d') || md5('$m-d2') from private.price_alert_installations where installation_secret_hash = md5('$m') || md5('$m-h');" >/dev/null
  local st; st="$(q "$name" "select id from public.community_stations where normalized_key = '$m-s'")"
  if [ "$3" = legacy ]; then
    q "$name" "insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id) values ('$st', 3.19, now() - interval '3 hours', '$m-base')" >/dev/null
    q "$name" "insert into private.price_alerts (installation_id, station_id, alert_mode, minimum_change, cooldown_minutes)
               select id, '$st', 'price_drop', 0.050, 360 from private.price_alert_installations where installation_secret_hash = md5('$m') || md5('$m-h')" >/dev/null
    q "$name" "insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id) values ('$st', $4, now() - interval '1 minute', '$m-fire')" >/dev/null
  else
    q "$name" "insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type) values ('$st', 3.19, now() - interval '3 hours', '$m-base', 'credit')" >/dev/null
    q "$name" "insert into private.price_alerts (installation_id, station_id, alert_mode, minimum_change, cooldown_minutes, payment_type)
               select id, '$st', 'price_drop', 0.100, 360, 'credit' from private.price_alert_installations where installation_secret_hash = md5('$m') || md5('$m-h')" >/dev/null
    q "$name" "insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type) values ('$st', $4, now() - interval '1 minute', '$m-fire', 'credit')" >/dev/null
  fi
  WSTATION="$st"
}

run_worker() { # <db label> <old|new> <tag>   -> RECORD file, W_CODE, W_BODY, worker log
  local entry="$NEW_FN/price-alerts-worker/index.ts"; [ "$2" = old ] && entry="$OLD_FN/price-alerts-worker/index.ts"
  RECORD="$TMP/record-$3.jsonl"; : > "$RECORD"; WLOG="$TMP/worker-$3.log"
  stop_server
  ( cd "$TMP" && SUPABASE_DB_URL="$(db_url "$1")" SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" \
      APNS_TEAM_ID="LOCALTEAM1" APNS_KEY_ID="LOCALKEY12" APNS_PRIVATE_KEY_P8="$(cat "$TMP/apns.p8")" \
      FIREBASE_SERVICE_ACCOUNT_JSON="$FCM_JSON" RECORD_FILE="$RECORD" WORKER_ENTRY="$entry" \
      DENO_SERVE_ADDRESS="tcp:127.0.0.1:${WORKER_PORT}" exec "$DENO" run --no-lock -A "$WRAPPER" >"$WLOG" 2>&1 ) &
  SERVER_PID=$!
  for _ in $(seq 1 120); do grep -q "Listening on" "$WLOG" 2>/dev/null && break; sleep 0.5; done
  grep -q "Listening on" "$WLOG" || fail "the $2 worker did not start: $(cat "$WLOG")"
  local out; out="$(curl -s -m 120 -X POST "http://127.0.0.1:${WORKER_PORT}" -H "authorization: Bearer $SERVICE_ROLE_KEY" \
    -H 'content-type: application/json' -d '{"job_limit":100,"delivery_limit":100}' -w '\n%{http_code}')"
  W_CODE="${out##*$'\n'}"; W_BODY="${out%$'\n'*}"
  stop_server
}
sent_for() { # <station id> -> "title | body | payload keys" of the single APNs request for that station
  jq -r --arg s "$1" 'select(.provider == "apns") | .body = (.body | fromjson) | select(.body.station_id == $s)
                      | [.body.aps.alert.title, .body.aps.alert.body, (.body | keys | join(","))] | join(" | ")' "$RECORD"
}

echo "== M2: worker x database state, with an ordinary legacy alert (the old wording must not change)"
for state in pre a ab; do
  for code in old new; do
    tag="m2-$state-$code"
    worker_fixture "$state" "$tag" legacy 3.10
    run_worker "$state" "$code" "$tag"
    expect "M2 $code worker on '$state': HTTP status" "$W_CODE" "200"
    expect "M2 $code worker on '$state': one notification sent" "$(jq -r '.ios_deliveries.sent' <<<"$W_BODY")" "1"
    expect "M2 $code worker on '$state': the old wording and the old payload keys" "$(sent_for "$WSTATION")" \
      'E85 price dropped | Rollout '"$tag"' dropped to $3.10/gal. | aps,observed_price,station_id,type'
    if [ "$code,$state" = "new,pre" ] || [ "$code,$state" = "new,a" ]; then
      grep -q "payment_type lookup failed" "$WLOG" || fail "M2 the new worker on '$state' should log that it degraded"
      echo "   new worker, database '$state': sent in the old wording and logged a warning (it cannot read deliveries.payment_type yet)"
    else
      ! grep -q "payment_type lookup failed" "$WLOG" || fail "M2 $code worker on '$state' logged a payment_type warning: $(grep 'payment_type lookup failed' "$WLOG")"
      echo "   $code worker, database '$state': sent in the old wording"
    fi
  done
done
echo "   ok"

echo "== M3: A+B with a CREDIT alert - the previous worker still delivers (without the price type), the new worker names it"
worker_fixture ab m3-old credit 3.09
run_worker ab old m3-old
expect "M3 previous worker: HTTP / sent" "$W_CODE $(jq -r '.ios_deliveries.sent' <<<"$W_BODY")" "200 1"
expect "M3 previous worker: right price, old wording, no payment_type key" "$(sent_for "$WSTATION")" \
  'E85 price dropped | Rollout m3-old dropped to $3.09/gal. | aps,observed_price,station_id,type'
worker_fixture ab m3-new credit 3.09
run_worker ab new m3-new
expect "M3 new worker: HTTP / sent" "$W_CODE $(jq -r '.ios_deliveries.sent' <<<"$W_BODY")" "200 1"
expect "M3 new worker: names the price type" "$(sent_for "$WSTATION")" \
  'E85 price dropped! | Credit price is now $3.09 at Rollout m3-new. | aps,observed_price,payment_type,station_id,type'
echo "   ok"

# ======================================================================================================================
echo "== T1: between A and B a typed report can alert a legacy alert; after B it cannot"
t1_sequence() { # <db label> <tag>  -> pending deliveries created by the sequence "credit 3.19, then cash 2.99"
  local name; name="$(db "$1")"; local m="t1-$2"
  q "$name" "
    insert into public.community_stations (name, normalized_key) values ('T1 $2', '$m-s');
    insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active) values ('\$RCAnonymousID:$m', 'SANDBOX', 'pro', true);
    insert into private.price_alert_installations (client_installation_id, installation_secret_hash, client_platform, revenuecat_app_user_id, revenuecat_environment, revenuecat_customer_id)
      select gen_random_uuid(), md5('$m') || md5('$m-h'), 'ios', c.original_app_user_id, 'SANDBOX', c.id from private.revenuecat_customers c where c.original_app_user_id = '\$RCAnonymousID:$m';
    insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash)
      select id, 'ios', 'com.e85blends.app.ios.internal', 'sandbox', repeat('a', 64), md5('$m-d') || md5('$m-d2') from private.price_alert_installations where installation_secret_hash = md5('$m') || md5('$m-h');
    insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
      select id, 3.19, now() - interval '90 minutes', '$m-credit', 'credit' from public.community_stations where normalized_key = '$m-s';
    insert into private.price_alerts (installation_id, station_id, alert_mode, minimum_change, cooldown_minutes)
      select i.id, s.id, 'price_drop', 0.050, 360 from private.price_alert_installations i, public.community_stations s where i.installation_secret_hash = md5('$m') || md5('$m-h') and s.normalized_key = '$m-s';" >/dev/null
  local rid; rid="$(q "$name" "insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
                               select id, 2.99, now() - interval '1 minute', '$m-cash', 'cash' from public.community_stations where normalized_key = '$m-s' returning id")"
  q "$name" "select pending_count from private.prepare_price_alert_deliveries('$rid')"
}
build t1 a
expect "T1 A only: the previous engine queues a notification for the credit->cash 'drop' (the false alert)" "$(t1_sequence t1 a-only)" "1"
dropdb --if-exists "$(db t1)"; build t1 ab
expect "T1 A+B: the same reports queue nothing for a legacy alert" "$(t1_sequence t1 ab)" "0"
echo "   ok"

# ======================================================================================================================
echo "== T2: a notification queued by the previous engine survives B and is delivered by the new worker in the old wording"
build t2 a
worker_fixture t2 t2 legacy 3.10                      # the baseline + alert + firing report; nothing has prepared the job yet
RID="$(q "$(db t2)" "select id from public.e85_price_reports where anonymous_reporter_id = 'wrk-t2-fire'")"
expect "T2 the previous engine queues the notification" "$(q "$(db t2)" "select pending_count from private.prepare_price_alert_deliveries('$RID')")" "1"
q "$(db t2)" "update private.price_alert_jobs set status = 'completed' where price_report_id = '$RID'" >/dev/null   # as the processor would have
BEFORE="$(q "$(db t2)" "select status || '|' || observed_price || '|' || coalesce(previous_price::text, '-') || '|' || coalesce(reason_code, '-') from private.price_alert_deliveries where price_report_id = '$RID'")"
expect "T2 the delivery as the previous engine left it" "$BEFORE" "pending|3.100|3.190|price_dropped"
apply_b t2
expect "T2 B did not touch the queued delivery" "$(q "$(db t2)" "select status || '|' || observed_price || '|' || coalesce(previous_price::text, '-') || '|' || coalesce(reason_code, '-') from private.price_alert_deliveries where price_report_id = '$RID'")" "$BEFORE"
expect "T2 ...it carries no payment type (it predates them), which the new worker reads as 'legacy wording'" \
  "$(q "$(db t2)" "select payment_type is null from private.price_alert_deliveries where price_report_id = '$RID'")" "t"
# a second report inside the cooldown, judged by the NEW engine: no duplicate
q "$(db t2)" "insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id)
              select station_id, 3.00, now() - interval '30 seconds', 'wrk-t2-dup' from public.e85_price_reports where id = '$RID'" >/dev/null
DUP="$(q "$(db t2)" "select id from public.e85_price_reports where anonymous_reporter_id = 'wrk-t2-dup'")"
expect "T2 the next report inside the cooldown queues no second notification" "$(q "$(db t2)" "select pending_count from private.prepare_price_alert_deliveries('$DUP')")" "0"
run_worker t2 new t2
expect "T2 the new worker delivers the old delivery" "$W_CODE $(jq -r '.ios_deliveries.sent' <<<"$W_BODY")" "200 1"
expect "T2 ...in the old wording, with the old payload" "$(jq -r 'select(.provider == "apns") | .body | fromjson | [.aps.alert.title, .aps.alert.body, (keys | join(","))] | join(" | ")' "$RECORD")" \
  'E85 price dropped | Rollout t2 dropped to $3.10/gal. | aps,observed_price,station_id,type'
expect "T2 exactly one notification left the process" "$(jq -s 'length' "$RECORD")" "1"
echo "   ok"

# ======================================================================================================================
echo "== T3: a report whose job is still queued when B is applied is judged against itself; draining the queue first avoids that"
t3_fixture() { # <db label> <tag>
  local name; name="$(db "$1")"; local m="t3-$2"
  q "$name" "
    insert into public.community_stations (name, normalized_key) values ('T3 $2', '$m-s');
    insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active) values ('\$RCAnonymousID:$m', 'SANDBOX', 'pro', true);
    insert into private.price_alert_installations (client_installation_id, installation_secret_hash, client_platform, revenuecat_app_user_id, revenuecat_environment, revenuecat_customer_id)
      select gen_random_uuid(), md5('$m') || md5('$m-h'), 'ios', c.original_app_user_id, 'SANDBOX', c.id from private.revenuecat_customers c where c.original_app_user_id = '\$RCAnonymousID:$m';
    insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash)
      select id, 'ios', 'com.e85blends.app.ios.internal', 'sandbox', repeat('a', 64), md5('$m-d') || md5('$m-d2') from private.price_alert_installations where installation_secret_hash = md5('$m') || md5('$m-h');
    insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id)
      select id, 3.40, now() - interval '3 hours', '$m-base' from public.community_stations where normalized_key = '$m-s';
    insert into private.price_alerts (installation_id, station_id, alert_mode, minimum_change, cooldown_minutes)
      select i.id, s.id, 'price_drop', 0.050, 360 from private.price_alert_installations i, public.community_stations s where i.installation_secret_hash = md5('$m') || md5('$m-h') and s.normalized_key = '$m-s';
    insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id)
      select id, 3.10, now() - interval '2 minutes', '$m-drop' from public.community_stations where normalized_key = '$m-s';" >/dev/null
  expect "T3 ($2) the drop's job is queued and unprocessed" "$(q "$name" "select count(*) from private.price_alert_jobs where status = 'pending'")" "1"
}
build t3 a
t3_fixture t3 undrained
apply_b t3
q "$(db t3)" "select claimed_count from private.process_price_alert_jobs(10)" >/dev/null
expect "T3 B applied with the job still queued: the 30c drop is NOT notified (the reference was filled from the report itself)" \
  "$(q "$(db t3)" "select count(*) from private.price_alert_deliveries where status = 'pending'")" "0"
build t3c a
t3_fixture t3c drained
q "$(db t3c)" "select claimed_count from private.process_price_alert_jobs(10)" >/dev/null
expect "T3 the queue drained BEFORE B: the previous engine notifies the drop" "$(q "$(db t3c)" "select count(*) from private.price_alert_deliveries where status = 'pending'")" "1"
apply_b t3c
expect "T3 ...and B leaves that notification queued" "$(q "$(db t3c)" "select count(*) from private.price_alert_deliveries where status = 'pending'")" "1"
echo "   ok"

# ======================================================================================================================
echo "== T4: a B that fails leaves nothing behind"
build t4 a
pro_fixture t4 t4
PREP_BEFORE="$(body_md5 t4 'private.prepare_price_alert_deliveries(uuid)')"
MARK_BEFORE="$(body_md5 t4 'private.mark_price_alert_delivery_sent(uuid,integer)')"
snapshot() { echo "$(has_column t4 private price_alerts payment_type)$(has_column t4 private price_alerts baseline_price)$(has_column t4 private price_alert_deliveries payment_type)|$(body_md5 t4 'private.prepare_price_alert_deliveries(uuid)')|$(body_md5 t4 'private.mark_price_alert_delivery_sent(uuid,integer)')|$(q "$(db t4)" "select count(*) from pg_trigger where tgname = 'price_alerts_anchor_baseline'")"; }
EXPECTED_SNAPSHOT="000|$PREP_BEFORE|$MARK_BEFORE|0"
expect "T4 before: A only" "$(snapshot)" "$EXPECTED_SNAPSHOT"

# (a) B cannot get its lock: another session holds one on the alerts table
( psql -X -q -At -d "$(db t4)" -c "begin; lock table private.price_alerts in access exclusive mode; select pg_sleep(7); commit;" >"$TMP/t4-holder.out" 2>&1 ) &
HOLDER=$!
sleep 1
START=$(now_ms)
set +e
psql -X -q -v ON_ERROR_STOP=1 --single-transaction -d "$(db t4)" -f "$B" >"$TMP/t4-b1.out" 2>&1
RC=$?
set -e
ELAPSED=$(( $(now_ms) - START ))
[ "$RC" -ne 0 ] || fail "T4 B should have failed while another session held a lock on private.price_alerts"
grep -qi "lock timeout" "$TMP/t4-b1.out" || fail "T4 B should fail on its lock_timeout: $(cat "$TMP/t4-b1.out")"
[ "$ELAPSED" -lt 6000 ] || fail "T4 B should give up after about 3 seconds, not wait for the other session (${ELAPSED} ms)"
echo "   B gave up after ${ELAPSED} ms: $(grep -i -m1 'lock timeout' "$TMP/t4-b1.out" | sed 's/^psql:[^ ]* //')"
expect "T4 after the lock timeout: nothing changed" "$(snapshot)" "$EXPECTED_SNAPSHOT"
wait "$HOLDER"

# (b) B fails at its very end, after every change: the single transaction takes it all back
set +e
( cat "$B"; echo "select 1/0;" ) | psql -X -q -v ON_ERROR_STOP=1 --single-transaction -d "$(db t4)" -f - >"$TMP/t4-b2.out" 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "T4 the injected error should have failed B"
grep -qi "division by zero" "$TMP/t4-b2.out" || fail "T4 unexpected failure: $(cat "$TMP/t4-b2.out")"
expect "T4 after an error at the very end of B: nothing changed" "$(snapshot)" "$EXPECTED_SNAPSHOT"

# (c) the previous API still works against the database B failed on, the previous engine still decides
start_api t4 old
HDR="\"client_installation_id\":\"$ID\",\"installation_secret\":\"$SECRET\""
call "{\"action\":\"bootstrap\",$HDR,\"platform\":\"ios\",\"revenuecat_app_user_id\":\"$PRO_USER\",\"revenuecat_environment\":\"SANDBOX\"}"
call "{\"action\":\"set_alert\",$HDR,\"station_id\":\"$STATION\",\"alert_mode\":\"price_drop\"}"
expect "T4 the previous API still saves an alert on the database B failed on" "$CODE" "200"
stop_server

# (d) a clean second attempt succeeds, and the result is the A+B state
apply_b t4
expect "T4 a second attempt applies B" "$(has_column t4 private price_alerts payment_type)$(has_column t4 private price_alerts baseline_price)$(has_column t4 private price_alert_deliveries payment_type)" "111"
expect "T4 ...and the saved alert stayed a legacy one" "$(q "$(db t4)" "select payment_type from private.price_alerts where station_id = '$STATION'")" "unknown"
echo "   ok"

# ======================================================================================================================
echo "== T5: a report submitted while B is running waits for B, then succeeds and is decided by the new engine"
build t5 a
pro_fixture t5 t5
q "$(db t5)" "
  insert into private.price_alert_installations (client_installation_id, installation_secret_hash, client_platform, revenuecat_app_user_id, revenuecat_environment, revenuecat_customer_id)
    select gen_random_uuid(), md5('t5') || md5('t5-h'), 'ios', c.original_app_user_id, 'SANDBOX', c.id from private.revenuecat_customers c where c.original_app_user_id = '$PRO_USER';
  insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash)
    select id, 'ios', 'com.e85blends.app.ios.internal', 'sandbox', repeat('a', 64), md5('t5-d') || md5('t5-d2') from private.price_alert_installations where installation_secret_hash = md5('t5') || md5('t5-h');
  insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id) values ('$STATION', 3.40, now() - interval '3 hours', 't5-base');
  insert into private.price_alerts (installation_id, station_id, alert_mode, minimum_change, cooldown_minutes)
    select id, '$STATION', 'price_drop', 0.050, 360 from private.price_alert_installations where installation_secret_hash = md5('t5') || md5('t5-h');" >/dev/null
# B runs inside a transaction that then stays open for 3 more seconds (its locks held)
( psql -X -q -At -v ON_ERROR_STOP=1 -d "$(db t5)" <<SQL >"$TMP/t5-b.out" 2>&1
begin;
\i $B
select pg_sleep(3);
commit;
SQL
) &
BPID=$!
sleep 1
START=$(now_ms)
psql -X -q -At -v ON_ERROR_STOP=1 -d "$(db t5)" -c "
  begin;
  select set_config('request.jwt.claim.role', 'anon', true);
  set local role anon;
  insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id)
  values ('$STATION', 3.10, now() - interval '1 minute', 't5-report');
  commit;" >"$TMP/t5-insert.out" 2>&1 || fail "T5 the report insert failed: $(cat "$TMP/t5-insert.out")"
ELAPSED=$(( $(now_ms) - START ))
wait "$BPID"
! grep -qi "error" "$TMP/t5-b.out" || fail "T5 B errored: $(cat "$TMP/t5-b.out")"
[ "$ELAPSED" -ge 1200 ] || fail "T5 the report should have waited for B (${ELAPSED} ms)"
echo "   the report waited ${ELAPSED} ms for B to commit, then was stored"
expect "T5 the report was stored" "$(q "$(db t5)" "select count(*) from public.e85_price_reports where anonymous_reporter_id = 't5-report'")" "1"
expect "T5 ...and its job was queued exactly once" "$(q "$(db t5)" "select count(*) from private.price_alert_jobs j join public.e85_price_reports r on r.id = j.price_report_id where r.anonymous_reporter_id = 't5-report'")" "1"
q "$(db t5)" "select claimed_count from private.process_price_alert_jobs(10)" >/dev/null
expect "T5 the new engine decided it (a legacy alert: the drop from the unclassified 3.40 reference notifies)" \
  "$(q "$(db t5)" "select d.status || ':' || d.reason_code || ':' || coalesce(d.payment_type, '-') from private.price_alert_deliveries d join public.e85_price_reports r on r.id = d.price_report_id where r.anonymous_reporter_id = 't5-report'")" "pending:price_dropped:unknown"
echo "   ok"

# ======================================================================================================================
echo "== T6: the incident drill (pause decisions, cancel the queue, pause the two jobs, resume) on an A+B database"
build t7 ab
D="$(db t7)"
m=t7
q "$D" "
  insert into public.community_stations (name, normalized_key) values ('T6 Station', '$m-s');
  insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active) values ('\$RCAnonymousID:$m', 'SANDBOX', 'pro', true);
  insert into private.price_alert_installations (client_installation_id, installation_secret_hash, client_platform, revenuecat_app_user_id, revenuecat_environment, revenuecat_customer_id)
    select gen_random_uuid(), md5('$m') || md5('$m-h'), 'ios', c.original_app_user_id, 'SANDBOX', c.id from private.revenuecat_customers c where c.original_app_user_id = '\$RCAnonymousID:$m';
  insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash)
    select id, 'ios', 'com.e85blends.app.ios.internal', 'sandbox', repeat('a', 64), md5('$m-d') || md5('$m-d2') from private.price_alert_installations where installation_secret_hash = md5('$m') || md5('$m-h');
  insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
    select id, 3.19, now() - interval '3 hours', '$m-base', 'credit' from public.community_stations where normalized_key = '$m-s';
  insert into private.price_alerts (installation_id, station_id, alert_mode, minimum_change, cooldown_minutes, payment_type)
    select i.id, s.id, 'price_drop', 0.100, 60, 'credit' from private.price_alert_installations i, public.community_stations s
    where i.installation_secret_hash = md5('$m') || md5('$m-h') and s.normalized_key = '$m-s';" >/dev/null
t7_report() { # <price> <age>
  q "$D" "insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
          select id, $1, now() - interval '$2', '$m-r', 'credit' from public.community_stations where normalized_key = '$m-s'" >/dev/null
}
t7_process() { q "$D" "select claimed_count || '/' || prepared_count || '/' || failed_count from private.process_price_alert_jobs(50)"; }
alert_config() { q "$D" "select md5(string_agg(concat_ws('|', id, installation_id, station_id, alert_mode, threshold_price, minimum_change, cooldown_minutes, payment_type, enabled), ';' order by id)) from private.price_alerts"; }
other_jobs() { q "$D" "select string_agg(jobname || ':' || active::text, ',' order by jobname) from cron.job where jobname not in ('85blends-price-alert-job-prepare', '85blends-price-alerts-worker-invoke')"; }
price_jobs() { q "$D" "select string_agg(jobname || ':' || active::text, ',' order by jobname) from cron.job where jobname in ('85blends-price-alert-job-prepare', '85blends-price-alerts-worker-invoke')"; }

# the worker's invoke job is created inactive locally (the owner activated it in production): make the drill start from "both active"
q "$D" "select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke'), active := true)" >/dev/null
expect "T6 start: both Price Alerts jobs are active" "$(price_jobs)" "85blends-price-alert-job-prepare:true,85blends-price-alerts-worker-invoke:true"
OTHERS_BEFORE="$(other_jobs)"
CONFIG_BEFORE="$(alert_config)"
ENGINE_REAL="$(body_md5 t7 'private.prepare_price_alert_deliveries(uuid)')"

t7_report 3.08 '30 minutes'
t7_process >/dev/null
expect "T6 normal operation: the engine queues the notification" "$(q "$D" "select count(*) from private.price_alert_deliveries where status = 'pending'")" "1"

# ---- C1: pause new decisions (the documented no-op engine) ---------------------------------------------------------------
q "$D" "create or replace function private.prepare_price_alert_deliveries(p_price_report_id uuid)
        returns table(pending_count integer, skipped_count integer)
        language sql
        security definer
        set search_path = ''
        as \$\$ select 0, 0 \$\$;" >/dev/null
expect "T6 C1: the engine is now the no-op" "$([ "$(body_md5 t7 'private.prepare_price_alert_deliveries(uuid)')" != "$ENGINE_REAL" ] && echo different || echo SAME)" "different"
t7_report 2.90 '20 minutes'
expect "T6 C1: a qualifying report arrives: processed without error, nothing decided" "$(t7_process)" "1/1/0"
expect "T6 C1: ...no new delivery was queued" "$(q "$D" "select count(*) from private.price_alert_deliveries")" "1"
expect "T6 C1: ...the queued one is untouched, still pending" "$(q "$D" "select status from private.price_alert_deliveries")" "pending"
expect "T6 C1: every alert keeps its configuration" "$(alert_config)" "$CONFIG_BEFORE"

# ---- C4: cancel what is queued but not yet sent (the rows are kept as the audit trail) -------------------------------------
q "$D" "update private.price_alert_deliveries
        set status = 'skipped', reason_code = 'paused_by_operator'
        where status in ('pending', 'failed')
          and created_at >= now() - interval '1 hour';" >/dev/null
expect "T6 C4: the queued delivery is cancelled, not deleted" "$(q "$D" "select status || ':' || reason_code from private.price_alert_deliveries")" "skipped:paused_by_operator"
expect "T6 C4: the worker's claim finds nothing to send" "$(q "$D" "select count(*) from private.claim_price_alert_deliveries_v2(10, 'ios')")" "0"
q "$D" "select private.mark_price_alert_delivery_sent(id, 200) from private.price_alert_deliveries" >/dev/null
expect "T6 C4: a late completion of an in-flight send cannot resurrect it (the delivery is still skipped)" "$(q "$D" "select status from private.price_alert_deliveries")" "skipped"

# ---- C2 + C3: pause the two Price Alerts jobs, and ONLY those -------------------------------------------------------------
q "$D" "select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke'), active := false);
        select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alert-job-prepare'), active := false);" >/dev/null
expect "T6 C2/C3: the two Price Alerts jobs are paused" "$(price_jobs)" "85blends-price-alert-job-prepare:false,85blends-price-alerts-worker-invoke:false"
expect "T6 C2/C3: no other cron job was touched" "$(other_jobs)" "$OTHERS_BEFORE"

# ---- resume: re-apply B (the real engine returns), re-activate the two jobs ------------------------------------------------
apply_b t7
expect "T6 resume: the real engine is back, byte for byte" "$(body_md5 t7 'private.prepare_price_alert_deliveries(uuid)')" "$ENGINE_REAL"
q "$D" "select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alert-job-prepare'), active := true);
        select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke'), active := true);" >/dev/null
expect "T6 resume: both Price Alerts jobs are active again" "$(price_jobs)" "85blends-price-alert-job-prepare:true,85blends-price-alerts-worker-invoke:true"
expect "T6 resume: no other cron job was touched" "$(other_jobs)" "$OTHERS_BEFORE"
expect "T6 resume: every alert still has the configuration it had" "$(alert_config)" "$CONFIG_BEFORE"
expect "T6 resume: the cancelled notification is still cancelled (nothing is re-sent after recovery)" \
  "$(q "$D" "select count(*) from private.price_alert_deliveries where status = 'skipped' and reason_code = 'paused_by_operator'")" "1"
t7_report 2.80 '5 minutes'
expect "T6 resume: the next qualifying report is processed normally" "$(t7_process)" "1/1/0"
expect "T6 resume: ...and queues exactly one new notification (for that report only)" \
  "$(q "$D" "select count(*) from private.price_alert_deliveries where status = 'pending'")" "1"
expect "T6 resume: ...no (alert, report, device) was decided twice" \
  "$(q "$D" "select count(*) from (select alert_id, price_report_id, push_device_id from private.price_alert_deliveries group by 1,2,3 having count(*) > 1) d")" "0"
echo "   ok"

# ======================================================================================================================
if [ "$MEASURE_ROWS" -gt 0 ]; then
  echo "== T7 (informational): how long A holds its lock on public.e85_price_reports (${MEASURE_ROWS} rows)"
  build big pre
  q "$(db big)" "
    insert into public.community_stations (name, normalized_key) select 'Big ' || g, 'big-' || g from generate_series(1, 2000) g;
    set session_replication_role = replica;
    insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id)
      select (select id from public.community_stations where normalized_key = 'big-' || (1 + (g % 2000))),
             round((2.5 + (g % 150) / 100.0)::numeric, 2), now() - (g % 100000) * interval '1 minute', 'big-' || (g % 5000)
      from generate_series(1, $MEASURE_ROWS) g;
    analyze public.e85_price_reports;" >/dev/null
  START=$(now_ms); apply_a big; A_MS=$(( $(now_ms) - START ))
  START=$(now_ms); apply_b big; B_MS=$(( $(now_ms) - START ))
  echo "   A took ${A_MS} ms and B took ${B_MS} ms to apply on ${MEASURE_ROWS} reports (each a single transaction; every statement on the reports table, reads included, waits for A's duration)"
  [ "$A_MS" -lt 120000 ] || fail "T7 A took far too long (${A_MS} ms) on ${MEASURE_ROWS} rows"
fi

echo "ALL PRICE ALERT ROLLOUT COMPATIBILITY SCENARIOS PASSED (M1-M3, T1-T7)"

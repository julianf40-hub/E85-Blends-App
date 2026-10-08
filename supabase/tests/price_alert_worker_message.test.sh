#!/usr/bin/env bash
# 85Blends 2.4.1 — Phase 3C: what the price-alerts-worker actually sends, end to end, with the push providers stubbed.
#
# LOCAL-REPLAY ONLY. Runs the REAL supabase/functions/price-alerts-worker/index.ts under Deno (through
# support/worker_with_recorded_fetch.ts, which replaces fetch() with a recorder: NOTHING is sent to Apple or Google and
# any other URL is refused), against a SCRATCH database that already has the full migration chain applied (including both
# Phase 3C migrations). Reports are inserted, the worker prepares the jobs, claims the deliveries and "sends" them, and
# this script reads back exactly what it would have sent. That proves the pieces fit: the engine's decision, the
# delivery row's payment_type, the worker's separate payment_type lookup (postgres.js array binding), the copy in
# message.ts, and the additive payload key on both APNs and FCM.
#
# Needs: deno, curl, jq, openssl, psql and the standard libpq environment (PGHOST/PGPORT/PGUSER/PGDATABASE). The worker
# connects over TCP: set WORKER_DB_URL if the scratch server is not reachable at 127.0.0.1:$PGPORT (default:
# postgresql://$PGUSER@127.0.0.1:$PGPORT/$PGDATABASE). Optional: DENO, WORKER_PORT (default 8793), DENO_CERT / HOME.
# Use a database with no other pending deliveries (a fresh replay): the worker claims EVERY pending delivery it finds.
# It COMMITS its fixtures under a marker and deletes them on exit. NEVER point it at a hosted project (it refuses a
# non-local PGHOST). The signing keys are generated into a temp directory and never leave it.
#
# Five alerts fire, one report each:
#   iOS  Credit price drop   -> "E85 price dropped!" / "Credit price is now $3.09 at <station>."  + payment_type "credit"
#   iOS  Legacy price drop   -> "E85 price dropped"  / "<station> dropped to $3.10/gal."           and NO payment_type key
#   iOS  Cash at-or-below    -> "Your E85 target was reached." / "Cash price is now $2.79 at <station>." + "cash"
#   Android Credit price drop (same station as the first) -> same copy, FCM data.payment_type "credit"
#   Android Legacy price drop (same station as the second) -> legacy copy, no FCM data.payment_type
set -euo pipefail

DENO="${DENO:-deno}"
WORKER_PORT="${WORKER_PORT:-8793}"
WORKER_DB_URL="${WORKER_DB_URL:-postgresql://${PGUSER:-postgres}@127.0.0.1:${PGPORT:-5432}/${PGDATABASE:?PGDATABASE required}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/support/worker_with_recorded_fetch.ts"
M="wmsg$$"
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1)
TMP="$(mktemp -d)"
RECORD="$TMP/record.jsonl"
WORKER_PID=""

case "${PGHOST:-/var/run/postgresql}" in
  /*|localhost|127.0.0.1|::1) ;;
  *) echo "REFUSING: PGHOST=${PGHOST} is not a local socket or loopback address" >&2; exit 2 ;;
esac
for tool in "$DENO" curl jq openssl psql; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAILED: '$tool' is required (set DENO=/path/to/deno if needed)" >&2; exit 1; }
done

sql() { "${PSQL[@]}" -c "$1"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
expect() { [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"; }

cleanup() {
  [ -n "$WORKER_PID" ] && kill "$WORKER_PID" 2>/dev/null || true
  "${PSQL[@]}" -c "
    delete from public.e85_price_reports where anonymous_reporter_id like '$M-%';
    delete from private.price_alert_installations where installation_secret_hash like md5('$M') || '%';
    delete from private.revenuecat_customers where original_app_user_id = '\$RCAnonymousID:$M';
    delete from public.community_stations where normalized_key like '$M-%';" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---- throwaway signing keys (generated here, deleted with $TMP) ----------------------------------------------------
openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkcs8 -topk8 -nocrypt -out "$TMP/apns.p8" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/fcm.pem" 2>/dev/null
FCM_JSON="$(jq -cn --arg key "$(cat "$TMP/fcm.pem")" '{project_id:"local-test",client_email:"worker@local.invalid",private_key:$key}')"
SERVICE_ROLE_KEY="local-test-service-role-key-$M"

# ---- fixtures (committed): three stations, one Pro identity, five installations each with ONE device and ONE alert ----
sql "
insert into public.community_stations (name, normalized_key) values
  ('Msg Credit Station', '$M-s1'), ('Msg Legacy Station', '$M-s2'), ('Msg Cash Station', '$M-s3');
insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active)
  values ('\$RCAnonymousID:$M', 'SANDBOX', 'pro', true);"
S1="$(sql "select id from public.community_stations where normalized_key = '$M-s1'")"
S2="$(sql "select id from public.community_stations where normalized_key = '$M-s2'")"
S3="$(sql "select id from public.community_stations where normalized_key = '$M-s3'")"

mk_installation() { # <tag> <platform>
  sql "insert into private.price_alert_installations
         (client_installation_id, installation_secret_hash, client_platform, revenuecat_app_user_id, revenuecat_environment, revenuecat_customer_id)
       select gen_random_uuid(), md5('$M') || md5('$M-$1'), '$2', c.original_app_user_id, 'SANDBOX', c.id
       from private.revenuecat_customers c where c.original_app_user_id = '\$RCAnonymousID:$M'" >/dev/null
}
mk_ios_device() { # <tag>
  sql "insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash)
       select id, 'ios', 'com.e85blends.app.ios.internal', 'sandbox', repeat('a', 64), md5('$M-$1-d') || md5('$M-$1-d2')
       from private.price_alert_installations where installation_secret_hash = md5('$M') || md5('$M-$1')" >/dev/null
}
mk_android_device() { # <tag>
  sql "insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash)
       select id, 'android', 'com.e85blends.android', null, 'fcm-' || repeat('c', 60), md5('$M-$1-d') || md5('$M-$1-d2')
       from private.price_alert_installations where installation_secret_hash = md5('$M') || md5('$M-$1')" >/dev/null
}
mk_report() { # <station> <payment_type> <price> <age> <tag>
  sql "insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
       values ('$1', $3, now() - interval '$4', '$M-$5', '$2')" >/dev/null
}
mk_alert() { # <tag> <station> <mode> <threshold|null> <min> <payment_type>
  sql "insert into private.price_alerts (installation_id, station_id, alert_mode, threshold_price, minimum_change, cooldown_minutes, payment_type)
       select id, '$2', '$3', $4, $5, 360, '$6' from private.price_alert_installations
       where installation_secret_hash = md5('$M') || md5('$M-$1')" >/dev/null
}

for spec in "ia ios" "ib ios" "ic ios" "id android" "ie android"; do
  set -- $spec; mk_installation "$1" "$2"
  case "$2" in ios) mk_ios_device "$1" ;; android) mk_android_device "$1" ;; esac
done

# baselines first (no alert exists yet, so these enqueue no jobs), then the alerts anchor to them
mk_report "$S1" credit  3.19 '3 hours' base1
mk_report "$S2" unknown 3.19 '3 hours' base2
mk_report "$S3" cash    3.10 '3 hours' base3
mk_alert ia "$S1" price_drop  null 0.100 credit
mk_alert id "$S1" price_drop  null 0.100 credit
mk_alert ib "$S2" price_drop  null 0.050 unknown
mk_alert ie "$S2" price_drop  null 0.050 unknown
mk_alert ic "$S3" at_or_below 2.89 0.100 cash
expect "fixture: the credit alert is anchored to the credit price" \
  "$(sql "select baseline_price from private.price_alerts a join private.price_alert_installations i on i.id = a.installation_id
          where i.installation_secret_hash = md5('$M') || md5('$M-ia')")" "3.190"

# the three reports that make alerts fire (each enqueues a job because an enabled alert now exists for its station)
mk_report "$S1" credit  3.09 '1 minute' fire1
mk_report "$S2" unknown 3.10 '1 minute' fire2
mk_report "$S3" cash    2.79 '1 minute' fire3

# ---- run the real worker with the providers stubbed ----------------------------------------------------------------
: > "$RECORD"
( cd "$TMP" && SUPABASE_DB_URL="$WORKER_DB_URL" SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" \
    APNS_TEAM_ID="LOCALTEAM1" APNS_KEY_ID="LOCALKEY12" APNS_PRIVATE_KEY_P8="$(cat "$TMP/apns.p8")" \
    FIREBASE_SERVICE_ACCOUNT_JSON="$FCM_JSON" RECORD_FILE="$RECORD" \
    DENO_SERVE_ADDRESS="tcp:127.0.0.1:${WORKER_PORT}" exec "$DENO" run --no-lock -A "$WRAPPER" >"$TMP/worker.log" 2>&1 ) &
WORKER_PID=$!
for _ in $(seq 1 120); do grep -q "Listening on" "$TMP/worker.log" 2>/dev/null && break; sleep 0.5; done
grep -q "Listening on" "$TMP/worker.log" || fail "the worker did not start: $(cat "$TMP/worker.log")"

RESPONSE="$(curl -s -m 120 -X POST "http://127.0.0.1:${WORKER_PORT}" -H "authorization: Bearer $SERVICE_ROLE_KEY" \
  -H 'content-type: application/json' -d '{"job_limit":100,"delivery_limit":100}' -w '\n%{http_code}')"
CODE="${RESPONSE##*$'\n'}"; BODY="${RESPONSE%$'\n'*}"
expect "worker HTTP status" "$CODE" "200"
echo "== the worker ran: $(jq -c '{status, jobs, ios: .ios_deliveries, android: .android_deliveries}' <<<"$BODY")"
expect "jobs prepared" "$(jq -r '.jobs.prepared' <<<"$BODY")" "3"
expect "iOS sent" "$(jq -r '.ios_deliveries.sent' <<<"$BODY")" "3"
expect "Android sent" "$(jq -r '.android_deliveries.sent' <<<"$BODY")" "2"
expect "no delivery retried, invalidated or dead" \
  "$(jq -r '[.ios_deliveries, .android_deliveries | .retrying + .invalid + .dead] | add' <<<"$BODY")" "0"
! grep -q "payment_type lookup failed" "$TMP/worker.log" || fail "the payment_type lookup failed: $(grep 'payment_type lookup failed' "$TMP/worker.log")"

apns() { jq -c --arg s "$1" 'select(.provider == "apns") | .body = (.body | fromjson) | select(.body.station_id == $s)' "$RECORD"; }
fcm()  { jq -c --arg s "$1" 'select(.provider == "fcm")  | .body = (.body | fromjson) | select(.body.message.data.station_id == $s)' "$RECORD"; }

# ======================================================================================================================
echo "== iOS, Credit alert: the copy names the price and the payload carries payment_type"
R="$(apns "$S1")"
expect "APNs requests for the credit station" "$(echo "$R" | jq -s 'length')" "1"
expect "title / body" "$(jq -r '.body.aps.alert | [.title, .body] | join(" | ")' <<<"$R")" 'E85 price dropped! | Credit price is now $3.09 at Msg Credit Station.'
expect "payload keys" "$(jq -r '.body | keys | join(",")' <<<"$R")" "aps,observed_price,payment_type,station_id,type"
expect "payment_type / type / price" "$(jq -r '.body | [.payment_type, .type, (.observed_price|tostring)] | join(" ")' <<<"$R")" "credit price_alert 3.09"
expect "deep link target and collapse id" "$(jq -r '[.body.station_id, .headers["apns-collapse-id"], .headers["apns-topic"], .headers["apns-push-type"]] | join(" ")' <<<"$R")" \
  "$S1 station-$S1 com.e85blends.app.ios.internal alert"
echo "   ok"

echo "== iOS, LEGACY alert: exactly the old wording and the old payload (no payment_type key)"
R="$(apns "$S2")"
expect "APNs requests for the legacy station" "$(echo "$R" | jq -s 'length')" "1"
expect "title / body" "$(jq -r '.body.aps.alert | [.title, .body] | join(" | ")' <<<"$R")" 'E85 price dropped | Msg Legacy Station dropped to $3.10/gal.'
expect "payload keys" "$(jq -r '.body | keys | join(",")' <<<"$R")" "aps,observed_price,station_id,type"
echo "   ok"

echo "== iOS, Cash at-or-below alert"
R="$(apns "$S3")"
expect "APNs requests for the cash station" "$(echo "$R" | jq -s 'length')" "1"
expect "title / body" "$(jq -r '.body.aps.alert | [.title, .body] | join(" | ")' <<<"$R")" 'Your E85 target was reached. | Cash price is now $2.79 at Msg Cash Station.'
expect "payment_type" "$(jq -r '.body.payment_type' <<<"$R")" "cash"
echo "   ok"

echo "== Android (FCM), Credit alert: same copy, data.payment_type present"
R="$(fcm "$S1")"
expect "FCM requests for the credit station" "$(echo "$R" | jq -s 'length')" "1"
expect "title / body" "$(jq -r '.body.message.notification | [.title, .body] | join(" | ")' <<<"$R")" 'E85 price dropped! | Credit price is now $3.09 at Msg Credit Station.'
expect "data keys" "$(jq -r '.body.message.data | keys | join(",")' <<<"$R")" "observed_price,payment_type,station_id,type"
expect "data values are strings" "$(jq -r '.body.message.data | [.payment_type, .observed_price, .type] | join(" ")' <<<"$R")" "credit 3.09 price_alert"
echo "   ok"

echo "== Android (FCM), LEGACY alert: old wording, no data.payment_type"
R="$(fcm "$S2")"
expect "FCM requests for the legacy station" "$(echo "$R" | jq -s 'length')" "1"
expect "title / body" "$(jq -r '.body.message.notification | [.title, .body] | join(" | ")' <<<"$R")" 'E85 price dropped | Msg Legacy Station dropped to $3.10/gal.'
expect "data keys" "$(jq -r '.body.message.data | keys | join(",")' <<<"$R")" "observed_price,station_id,type"
echo "   ok"

echo "== database state after sending"
expect "five deliveries, all sent, each recording the alert's method" \
  "$(sql "select string_agg(d.payment_type || ':' || d.status, ',' order by d.payment_type, d.status)
          from private.price_alert_deliveries d join private.price_alerts a on a.id = d.alert_id
          join private.price_alert_installations i on i.id = a.installation_id
          where i.installation_secret_hash like md5('$M') || '%' and d.reason_code in ('price_dropped', 'threshold_crossed')")" \
  "cash:sent,credit:sent,credit:sent,unknown:sent,unknown:sent"
expect "every recorded request was a provider call (nothing else left the process)" "$(jq -s 'length' "$RECORD")" "5"
echo "   ok"

echo "ALL PRICE ALERT WORKER MESSAGE SCENARIOS PASSED (5 notifications: 3 APNs, 2 FCM)"

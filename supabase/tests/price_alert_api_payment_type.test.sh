#!/usr/bin/env bash
# 85Blends 2.4.1 — Phase 3C: price-alerts-api payment types and drop sizes, driven over HTTP.
#
# LOCAL-REPLAY ONLY. Starts the REAL supabase/functions/price-alerts-api/index.ts under Deno on a local port, pointed
# (SUPABASE_DB_URL) at a SCRATCH database that already has the full migration chain applied (including both Phase 3C
# migrations), and drives set_alert / list_alerts / delete_alert with the JSON the 2.4.1 app sends and the JSON an older
# client sends. This is the only test that runs the Edge Function itself against a real database: the pure input rules
# are covered by alert-input.test.ts, the SQL it relies on by price_alert_payment_type.test.sql, and this script proves
# that the two fit together (parameter binding, numeric round trips, coalesce on edit, the anchor trigger firing from an
# API call).
#
# Needs: deno, curl, jq, psql and the standard libpq environment (PGHOST/PGPORT/PGUSER/PGDATABASE). The API itself
# connects over TCP: set API_DB_URL if the scratch server is not reachable at 127.0.0.1:$PGPORT (default:
# postgresql://$PGUSER@127.0.0.1:$PGPORT/$PGDATABASE). Optional: DENO (path to deno), API_PORT (default 8792), DENO_CERT /
# HOME when the environment needs them. It COMMITS its fixtures under a marker and deletes them on exit.
# NEVER point it at a hosted project (it refuses a non-local PGHOST).
#
# What it proves:
#   A1  an OLDER client (no payment_type, no minimum_change) stores a legacy 'unknown' alert with the legacy 0.05 / 360 defaults
#   A2  the 2.4.1 app (payment_type credit, minimum_change 0.10) updates that alert as sent, and the anchor trigger
#       re-anchors the reference to the latest CREDIT price
#   A3  an edit that names no payment_type keeps credit and changes only what it names
#   A4  invalid_payment_type: 'unknown', 'same_for_both', 'Credit', '', 7, true, {} are refused (400) and change nothing;
#       null is "not specified"
#   A5  bounds: minimum_change 0.01 and 2 accepted, 0.009 / 2.01 / "x" refused; at_or_below 1 and 8 accepted, 0.99 / 8.01
#       refused; a threshold on a price_drop alert refused
#   A6  list_alerts: payment_type, minimum_change, the legacy latest_price (newest of ANY kind), and latest_comparable_*
#       (the alert's own kind, with that report's payment type)
#   A7  switching the method re-anchors the reference to the new method's price and clears the last notification
#   A8  a non-Pro installation gets 403 pro_required and nothing is stored
#   A9  delete_alert is unchanged
set -euo pipefail

DENO="${DENO:-deno}"
API_PORT="${API_PORT:-8792}"
API_DB_URL="${API_DB_URL:-postgresql://${PGUSER:-postgres}@127.0.0.1:${PGPORT:-5432}/${PGDATABASE:?PGDATABASE required}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$HERE/../functions/price-alerts-api"
M="apipt$$"
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1)
TMP="$(mktemp -d)"
KEY="synthetic-publishable-key-for-local-tests"
URL="http://127.0.0.1:${API_PORT}"
APIPID=""
BODY=""
CODE=""

case "${PGHOST:-/var/run/postgresql}" in
  /*|localhost|127.0.0.1|::1) ;;
  *) echo "REFUSING: PGHOST=${PGHOST} is not a local socket or loopback address" >&2; exit 2 ;;
esac
for tool in "$DENO" curl jq psql; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAILED: '$tool' is required (set DENO=/path/to/deno if needed)" >&2; exit 1; }
done

sql() { "${PSQL[@]}" -c "$1"; }
fail() { echo "FAILED: $*" >&2; exit 1; }

cleanup() {
  [ -n "$APIPID" ] && kill "$APIPID" 2>/dev/null || true
  "${PSQL[@]}" -c "
    delete from public.e85_price_reports where anonymous_reporter_id like '$M-%';
    delete from private.price_alert_installations where client_installation_id::text in ('$ID_PRO', '$ID_FREE');
    delete from private.revenuecat_customers where original_app_user_id = '\$RCAnonymousID:$M';
    delete from public.community_stations where normalized_key like '$M-%';" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
ID_PRO="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr 'A-Z' 'a-z')"
ID_FREE="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr 'A-Z' 'a-z')"
SECRET_PRO="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SECRET_FREE="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
trap cleanup EXIT

# ---- fixtures (committed): a station, a Pro RevenueCat identity, no reports yet ------------------------------------
sql "
insert into public.community_stations (name, normalized_key) values ('API Payment Test', '$M-s');
insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active)
  values ('\$RCAnonymousID:$M', 'SANDBOX', 'pro', true);
insert into private.revenuecat_aliases (app_user_id, environment, customer_id)
  select original_app_user_id, 'SANDBOX', id from private.revenuecat_customers where original_app_user_id = '\$RCAnonymousID:$M'
  on conflict do nothing;" >/dev/null
STATION="$(sql "select id from public.community_stations where normalized_key = '$M-s'")"

# ---- start the real API -------------------------------------------------------------------------------------------
( cd "$API_DIR" && SUPABASE_DB_URL="$API_DB_URL" SUPABASE_PUBLISHABLE_KEYS="{\"default\":\"$KEY\"}" \
    DENO_SERVE_ADDRESS="tcp:127.0.0.1:${API_PORT}" exec "$DENO" run --no-lock --config deno.json -A index.ts >"$TMP/api.log" 2>&1 ) &
APIPID=$!
for _ in $(seq 1 120); do grep -q "Listening on" "$TMP/api.log" 2>/dev/null && break; sleep 0.5; done
grep -q "Listening on" "$TMP/api.log" || fail "the API did not start: $(cat "$TMP/api.log")"

# ---- helpers ------------------------------------------------------------------------------------------------------
post() { # <json object> -> sets BODY and CODE
  local out
  out="$(curl -s -m 60 -X POST "$URL" -H 'content-type: application/json' -H "apikey: $KEY" -d "$1" -w '\n%{http_code}')"
  CODE="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}
expect() { # <label> <actual> <expected>
  [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2' (HTTP $CODE, body: $BODY)"
}
field() { jq -r "$1" <<<"$BODY"; }
set_alert() { # <extra fields, each starting with a comma>  (Pro installation, the test station)
  post "{\"action\":\"set_alert\",\"client_installation_id\":\"$ID_PRO\",\"installation_secret\":\"$SECRET_PRO\",\"station_id\":\"$STATION\"$1}"
}
list_alerts() { post "{\"action\":\"list_alerts\",\"client_installation_id\":\"$ID_PRO\",\"installation_secret\":\"$SECRET_PRO\"}"; }
alert_row() { # payment_type|minimum_change|cooldown|mode|threshold|baseline|last_notified_price for the Pro installation's alert
  sql "select payment_type || '|' || minimum_change || '|' || cooldown_minutes || '|' || alert_mode || '|' || coalesce(threshold_price::text, '-')
              || '|' || coalesce(baseline_price::text, '-') || '|' || coalesce(last_notified_price::text, '-')
       from private.price_alerts where station_id = '$STATION'
         and installation_id = (select id from private.price_alert_installations where client_installation_id = '$ID_PRO')"
}
mk_report() { # <payment_type> <price> <age e.g. '3 hours'> <tag>
  sql "insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
       values ('$STATION', $2, now() - interval '$3', '$M-$4', '$1')" >/dev/null
}

# bootstrap the Pro installation (linked to the Pro RevenueCat identity) and a Free one (no identity)
post "{\"action\":\"bootstrap\",\"client_installation_id\":\"$ID_PRO\",\"installation_secret\":\"$SECRET_PRO\",\"platform\":\"ios\",\"revenuecat_app_user_id\":\"\$RCAnonymousID:$M\",\"revenuecat_environment\":\"SANDBOX\"}"
expect "bootstrap (Pro)" "$CODE $(field .pro_is_active)" "200 true"
post "{\"action\":\"bootstrap\",\"client_installation_id\":\"$ID_FREE\",\"installation_secret\":\"$SECRET_FREE\",\"platform\":\"ios\"}"
expect "bootstrap (Free)" "$CODE $(field .pro_is_active)" "200 false"

# ======================================================================================================================
echo "== A1: an OLDER client (no payment_type, no minimum_change) stores a legacy alert with the legacy defaults"
set_alert ',"alert_mode":"price_drop"'
expect "A1 status" "$CODE $(field .status)" "200 saved"
expect "A1 response payment_type" "$(field .alert.payment_type)" "unknown"
expect "A1 stored row (payment|min|cooldown|mode|threshold|baseline|notified)" "$(alert_row)" "unknown|0.050|360|price_drop|-|-|-"
echo "   ok"

# ======================================================================================================================
echo "== A2: the 2.4.1 app names credit and a 10 cent drop; the reference is anchored to the latest CREDIT price"
mk_report credit 3.19 '3 hours' credit
mk_report cash 2.99 '2 hours' cash
mk_report unknown 3.30 '4 hours' unknown
set_alert ',"alert_mode":"price_drop","payment_type":"credit","minimum_change":0.1,"cooldown_minutes":360'
expect "A2 status" "$CODE $(field .status)" "200 saved"
expect "A2 response" "$(field .alert.payment_type) $(field '.alert.minimum_change|tonumber|.*1')" "credit 0.1"
expect "A2 stored row" "$(alert_row)" "credit|0.100|360|price_drop|-|3.190|-"
echo "   ok"

# ======================================================================================================================
echo "== A3: an edit that names no payment_type keeps credit and changes only what it names"
set_alert ',"alert_mode":"price_drop","minimum_change":0.2'
expect "A3 status" "$CODE $(field .alert.payment_type) $(field '.alert.minimum_change|tonumber|.*1')" "200 credit 0.2"
expect "A3 stored row" "$(alert_row)" "credit|0.200|360|price_drop|-|3.190|-"
set_alert ',"alert_mode":"price_drop","payment_type":null,"minimum_change":0.1'
expect "A3 explicit null payment_type is 'not specified'" "$CODE $(field .alert.payment_type)" "200 credit"
echo "   ok"

# ======================================================================================================================
echo "== A4: invalid_payment_type, and nothing changes"
BEFORE="$(alert_row)"
for bad in '"unknown"' '"same_for_both"' '"Credit"' '"CASH"' '""' '"debit"' '7' 'true' '{}' '["cash"]'; do
  set_alert ",\"alert_mode\":\"price_drop\",\"payment_type\":$bad,\"minimum_change\":0.5"
  expect "A4 payment_type=$bad" "$CODE $(field .error)" "400 invalid_payment_type"
done
expect "A4 the stored alert is untouched by every refused request" "$(alert_row)" "$BEFORE"
echo "   ok"

# ======================================================================================================================
echo "== A5: bounds"
for good in 0.01 2 0.015 0.05 0.1 0.2; do
  set_alert ",\"alert_mode\":\"price_drop\",\"payment_type\":\"credit\",\"minimum_change\":$good"
  expect "A5 minimum_change=$good" "$CODE $(field '.alert.minimum_change|tonumber|.*1')" "200 $good"
done
for bad in 0.009 0 -1 2.01 100 '"x"'; do
  set_alert ",\"alert_mode\":\"price_drop\",\"payment_type\":\"credit\",\"minimum_change\":$bad"
  expect "A5 minimum_change=$bad" "$CODE $(field .error)" "400 invalid_alert_preferences"
done
for good in 1 8 2.89; do
  set_alert ",\"alert_mode\":\"at_or_below\",\"payment_type\":\"cash\",\"threshold_price\":$good,\"minimum_change\":0.1"
  expect "A5 at_or_below threshold=$good" "$CODE $(field .alert.alert_mode) $(field .alert.payment_type)" "200 at_or_below cash"
done
for bad in 0.99 8.01 '"x"'; do
  set_alert ",\"alert_mode\":\"at_or_below\",\"payment_type\":\"cash\",\"threshold_price\":$bad"
  expect "A5 at_or_below threshold=$bad" "$CODE $(field .error)" "400 invalid_threshold_price"
done
set_alert ',"alert_mode":"price_drop","payment_type":"cash","threshold_price":2.89'
expect "A5 a threshold on a price_drop alert" "$CODE $(field .error)" "400 threshold_only_valid_for_at_or_below"
# leave the alert as a credit price drop for the next scenarios
set_alert ',"alert_mode":"price_drop","payment_type":"credit","minimum_change":0.1'
expect "A5 back to a credit price drop" "$CODE $(field .alert.payment_type)" "200 credit"
echo "   ok"

# ======================================================================================================================
echo "== A6: list_alerts - the legacy latest is the newest of ANY kind; the comparable latest is the alert's own"
list_alerts
expect "A6 status" "$CODE $(field '.alerts|length')" "200 1"
expect "A6 payment_type / minimum_change" "$(field '.alerts[0].payment_type') $(field '.alerts[0].minimum_change|tonumber|.*1')" "credit 0.1"
expect "A6 legacy latest_price is the newest report of any kind (cash 2.99)" "$(field '.alerts[0].latest_price|tonumber|.*1')" "2.99"
expect "A6 latest_comparable_* is the credit price" \
  "$(field '.alerts[0].latest_comparable_price|tonumber|.*1') $(field '.alerts[0].latest_comparable_payment_type')" "3.19 credit"
mk_report same_for_both 3.05 '1 hour' both
list_alerts
expect "A6 a same_for_both report is comparable for a credit alert" \
  "$(field '.alerts[0].latest_comparable_price|tonumber|.*1') $(field '.alerts[0].latest_comparable_payment_type')" "3.05 same_for_both"
expect "A6 every field an older client reads is still present" \
  "$(jq -r '.alerts[0] | [has("id"),has("station_id"),has("alert_mode"),has("threshold_price"),has("minimum_change"),has("cooldown_minutes"),has("enabled"),has("last_notified_price"),has("last_notified_at"),has("station_name"),has("latest_price"),has("latest_reported_at")] | all' <<<"$BODY")" "true"
echo "   ok"

# ======================================================================================================================
echo "== A7: switching the method re-anchors the reference to the new method's price and clears the last notification"
sql "update private.price_alerts set last_notified_price = 3.00, last_notified_at = now() - interval '10 minutes' where station_id = '$STATION'
       and installation_id = (select id from private.price_alert_installations where client_installation_id = '$ID_PRO')" >/dev/null
set_alert ',"alert_mode":"price_drop","payment_type":"cash","minimum_change":0.1'
expect "A7 status" "$CODE $(field .alert.payment_type)" "200 cash"
# newest comparable for cash within 7 days is the same_for_both 3.05 (1 hour ago), newer than cash 2.99 (2 hours ago)
expect "A7 stored row: re-anchored to the latest cash-comparable price, last notification cleared" "$(alert_row)" "cash|0.100|360|price_drop|-|3.050|-"
list_alerts
expect "A7 list: comparable follows the new method" "$(field '.alerts[0].payment_type') $(field '.alerts[0].latest_comparable_price|tonumber|.*1')" "cash 3.05"
echo "   ok"

# ======================================================================================================================
echo "== A8: a non-Pro installation gets 403 and nothing is stored"
post "{\"action\":\"set_alert\",\"client_installation_id\":\"$ID_FREE\",\"installation_secret\":\"$SECRET_FREE\",\"station_id\":\"$STATION\",\"alert_mode\":\"price_drop\",\"payment_type\":\"credit\",\"minimum_change\":0.1}"
expect "A8 status" "$CODE $(field .error)" "403 pro_required"
expect "A8 nothing stored for the free installation" \
  "$(sql "select count(*) from private.price_alerts where installation_id = (select id from private.price_alert_installations where client_installation_id = '$ID_FREE')")" "0"
echo "   ok"

# ======================================================================================================================
echo "== A9: delete_alert is unchanged"
post "{\"action\":\"delete_alert\",\"client_installation_id\":\"$ID_PRO\",\"installation_secret\":\"$SECRET_PRO\",\"station_id\":\"$STATION\"}"
expect "A9 first delete" "$CODE $(field .status) $(field .changed)" "200 deleted true"
post "{\"action\":\"delete_alert\",\"client_installation_id\":\"$ID_PRO\",\"installation_secret\":\"$SECRET_PRO\",\"station_id\":\"$STATION\"}"
expect "A9 second delete" "$CODE $(field .changed)" "200 false"
list_alerts
expect "A9 list is empty" "$CODE $(field '.alerts|length')" "200 0"
echo "   ok"

echo "ALL PRICE ALERT API PAYMENT-TYPE SCENARIOS PASSED (A1-A9)"

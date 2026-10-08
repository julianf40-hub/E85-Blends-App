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
# NEVER point it at a hosted project (it refuses a non-local PGHOST or API_DB_URL host).
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
#   Phase 3C.1 (the sensitivity contract, alert_contract_version):
#   A10 an OLDER client re-saving an alert (minimum_change omitted, the fixed legacy 0.05, float noise) does not reset a drop
#       size the 2.4.1 app chose; the 2.4.1 app can still choose 5c / 10c / 20c / a custom value, and they round-trip exactly;
#       a new alert from an older client still gets the legacy 0.05
#   A11 a payment-only edit keeps the drop size; a target-only edit keeps the method and the drop size; a sensitivity-only
#       edit keeps the method and the target
#   A12 malformed alert_contract_version is refused (400 invalid_alert_contract_version) and changes nothing; null and any
#       whole number from 1 to 1000 are accepted
#   A13 repeated identical saves are safe (one alert, same id, reference and notification memory untouched)
#   A14 concurrent saves do not lose configuration (a payment-only save racing a sensitivity-only save, and an older client)
#   A15 the Pro gate is unchanged by the version (a non-Pro installation is refused whatever it sends)
#   A16 moving a LEGACY alert to Cash / Credit over HTTP: only the method changes; a missing comparable price leaves the
#       reference empty
set -euo pipefail

DENO="${DENO:-deno}"
API_PORT="${API_PORT:-8792}"
API_DB_URL="${API_DB_URL:-postgresql://${PGUSER:-postgres}@127.0.0.1:${PGPORT:-5432}/${PGDATABASE:?PGDATABASE required}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="${API_DIR:-$HERE/../functions/price-alerts-api}"     # override only to run the same scenarios against a modified COPY (mutation checks)
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
# The API under test connects with API_DB_URL, not with PGHOST: it writes installation rows, so its host must be loopback too.
if [[ "$API_DB_URL" =~ ^postgres(ql)?://([^@/]*@)?(\[[^]]+\]|[^:/?]+)(:[0-9]+)?(/|\?|$) ]]; then
  case "${BASH_REMATCH[3]}" in
    localhost|127.0.0.1|'[::1]') ;;
    *) echo "REFUSING: the host of API_DB_URL (${BASH_REMATCH[3]}) is not a loopback address" >&2; exit 2 ;;
  esac
else
  echo "REFUSING: cannot read the host of API_DB_URL" >&2; exit 2
fi
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
insert into public.community_stations (name, normalized_key) values ('API Payment Test', '$M-s'), ('API Payment Test 2', '$M-s2'), ('API Payment Test 3', '$M-s3');
insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active)
  values ('\$RCAnonymousID:$M', 'SANDBOX', 'pro', true);
insert into private.revenuecat_aliases (app_user_id, environment, customer_id)
  select original_app_user_id, 'SANDBOX', id from private.revenuecat_customers where original_app_user_id = '\$RCAnonymousID:$M'
  on conflict do nothing;" >/dev/null
STATION="$(sql "select id from public.community_stations where normalized_key = '$M-s'")"
STATION2="$(sql "select id from public.community_stations where normalized_key = '$M-s2'")"
STATION3="$(sql "select id from public.community_stations where normalized_key = '$M-s3'")"

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
# What the 2.4.1 app adds to every set_alert (PriceAlertsWireRequest.alertContractVersion): it declares that its minimum_change is a
# deliberate choice. Requests that model an OLDER client simply do not carry it.
V2=',"alert_contract_version":2'
set_alert() { # <extra fields, each starting with a comma>  (Pro installation, the test station)
  post "{\"action\":\"set_alert\",\"client_installation_id\":\"$ID_PRO\",\"installation_secret\":\"$SECRET_PRO\",\"station_id\":\"$STATION\"$1}"
}
set_alert_at() { # <station id> <extra fields, each starting with a comma>
  post "{\"action\":\"set_alert\",\"client_installation_id\":\"$ID_PRO\",\"installation_secret\":\"$SECRET_PRO\",\"station_id\":\"$1\"$2}"
}
list_alerts() { post "{\"action\":\"list_alerts\",\"client_installation_id\":\"$ID_PRO\",\"installation_secret\":\"$SECRET_PRO\"}"; }
alert_row() { # payment_type|minimum_change|cooldown|mode|threshold|baseline|last_notified_price for the Pro installation's alert
  sql "select payment_type || '|' || minimum_change || '|' || cooldown_minutes || '|' || alert_mode || '|' || coalesce(threshold_price::text, '-')
              || '|' || coalesce(baseline_price::text, '-') || '|' || coalesce(last_notified_price::text, '-')
       from private.price_alerts where station_id = '$STATION'
         and installation_id = (select id from private.price_alert_installations where client_installation_id = '$ID_PRO')"
}
prefs_row() { # payment|minimum_change|cooldown|mode|threshold of the Pro installation's alert at <station> (default: the test station)
  sql "select payment_type || '|' || minimum_change || '|' || cooldown_minutes || '|' || alert_mode || '|' || coalesce(threshold_price::text, '-')
       from private.price_alerts where station_id = '${1:-$STATION}'
         and installation_id = (select id from private.price_alert_installations where client_installation_id = '$ID_PRO')"
}
mk_report() { # <payment_type> <price> <age e.g. '3 hours'> <tag> [station id]
  sql "insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type)
       values ('${5:-$STATION}', $2, now() - interval '$3', '$M-$4', '$1')" >/dev/null
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
set_alert "$V2"',"alert_mode":"price_drop","payment_type":"credit","minimum_change":0.1,"cooldown_minutes":360'
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
  set_alert "$V2,\"alert_mode\":\"price_drop\",\"payment_type\":\"credit\",\"minimum_change\":$good"
  expect "A5 minimum_change=$good" "$CODE $(field '.alert.minimum_change|tonumber|.*1')" "200 $good"
done
for bad in 0.009 0 -1 2.01 100 '"x"'; do
  set_alert "$V2,\"alert_mode\":\"price_drop\",\"payment_type\":\"credit\",\"minimum_change\":$bad"
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
set_alert "$V2"',"alert_mode":"price_drop","payment_type":"credit","minimum_change":0.1'
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
set_alert "$V2"',"alert_mode":"price_drop","payment_type":"cash","minimum_change":0.1'
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

# ======================================================================================================================
# Phase 3C.1 - the sensitivity contract. An OLDER client never chose a drop size (it sends the fixed 0.05, or nothing); the
# 2.4.1 app does choose, and declares it with alert_contract_version 2 ($V2). The regression these scenarios pin: an older
# client re-saving an alert must not reset a drop size the 2.4.1 app chose - and the 2.4.1 app must still be able to choose 5c.
# ======================================================================================================================
echo "== A10: an OLDER client's save does not reset the drop size; the 2.4.1 app can still choose any size, 5 cents included"
set_alert "$V2"',"alert_mode":"price_drop","payment_type":"credit","minimum_change":0.2,"cooldown_minutes":360'
expect "A10 setup: the 2.4.1 app saves Credit + 20c" "$CODE $(field .alert.payment_type) $(field '.alert.minimum_change|tonumber|.*1')" "200 credit 0.2"
expect "A10 setup row" "$(prefs_row)" "credit|0.200|360|price_drop|-"
SETUP_ID="$(field .alert.id)"

set_alert ',"alert_mode":"price_drop"'
expect "A10a older client, no minimum_change and no method: status / method / the drop size in the reply" \
  "$CODE $(field .alert.payment_type) $(field '.alert.minimum_change|tonumber|.*1')" "200 credit 0.2"
expect "A10a ...the same alert, the drop size kept" "$(field .alert.id) $(prefs_row)" "$SETUP_ID credit|0.200|360|price_drop|-"
set_alert ',"alert_mode":"price_drop","minimum_change":0.05,"cooldown_minutes":360'
expect "A10b older client, the fixed legacy 0.05: the 20c is kept" "$CODE $(field '.alert.minimum_change|tonumber|.*1') $(prefs_row)" "200 0.2 credit|0.200|360|price_drop|-"
set_alert ',"alert_mode":"price_drop","minimum_change":0.050,"cooldown_minutes":360,"payment_type":null'
expect "A10b' ...written as 0.050 with a null method" "$(prefs_row)" "credit|0.200|360|price_drop|-"
set_alert ',"alert_mode":"price_drop","minimum_change":0.04999999999999999'
expect "A10c older client, 0.05 with float noise: still the legacy value, the 20c is kept" "$(prefs_row)" "credit|0.200|360|price_drop|-"
set_alert ',"alert_mode":"at_or_below","threshold_price":2.89,"minimum_change":0.05'
expect "A10d older client switches to a target and sends the fixed 0.05: the mode and target change, the 20c is kept" "$(prefs_row)" "credit|0.200|360|at_or_below|2.890"
set_alert ',"alert_mode":"price_drop","minimum_change":0.05'
expect "A10e ...and back to a price drop" "$(prefs_row)" "credit|0.200|360|price_drop|-"
set_alert ',"alert_mode":"price_drop","minimum_change":0.15'
expect "A10f older client with a value that is NOT the fixed 0.05 (it cannot be an artifact): taken as meant" "$(prefs_row)" "credit|0.150|360|price_drop|-"

# the 2.4.1 app chooses; every choice round-trips exactly
for choice in 0.05 0.1 0.2 0.137 0.015 2 0.01; do
  set_alert "$V2"",\"alert_mode\":\"price_drop\",\"payment_type\":\"credit\",\"minimum_change\":$choice"
  expect "A10g the 2.4.1 app chooses $choice" "$CODE $(field '.alert.minimum_change|tonumber|.*1')" "200 $choice"
  expect "A10g ...stored exactly (numeric(6,3))" "$(sql "select minimum_change = $choice::numeric from private.price_alerts where id = '$SETUP_ID'")" "t"
done
set_alert "$V2"',"alert_mode":"price_drop","payment_type":"credit","minimum_change":0.05'
expect "A10h a deliberate 5 cents from a client that declared the contract IS applied (the fix does not swallow 5c)" "$(prefs_row)" "credit|0.050|360|price_drop|-"
set_alert "$V2"',"alert_mode":"price_drop","payment_type":"credit","minimum_change":0.137'
set_alert "$V2"',"alert_mode":"price_drop"'
expect "A10i a declared client that names no minimum_change keeps the stored one" "$(prefs_row)" "credit|0.137|360|price_drop|-"
set_alert "$V2"',"alert_mode":"price_drop","minimum_change":null'
expect "A10i' ...a null minimum_change is 'not named' too" "$(prefs_row)" "credit|0.137|360|price_drop|-"

# a NEW alert always takes what the request says (or the legacy default), whoever sends it
delete_at() { post "{\"action\":\"delete_alert\",\"client_installation_id\":\"$ID_PRO\",\"installation_secret\":\"$SECRET_PRO\",\"station_id\":\"$1\"}"; }
set_alert_at "$STATION2" ',"alert_mode":"price_drop"'
expect "A10j a NEW alert from an older client with no minimum_change: the legacy 0.05" "$CODE $(field .alert.payment_type) $(prefs_row "$STATION2")" "200 unknown unknown|0.050|360|price_drop|-"
delete_at "$STATION2"
set_alert_at "$STATION2" ',"alert_mode":"price_drop","minimum_change":0.2'
expect "A10k a NEW alert from an older client with an explicit 20c: 20c" "$(prefs_row "$STATION2")" "unknown|0.200|360|price_drop|-"
delete_at "$STATION2"
set_alert_at "$STATION2" "$V2"',"alert_mode":"price_drop"'
expect "A10l a NEW alert from a declared client that names no minimum_change: the legacy 0.05 default" "$(prefs_row "$STATION2")" "unknown|0.050|360|price_drop|-"
delete_at "$STATION2"
set_alert_at "$STATION2" "$V2"',"alert_mode":"price_drop","payment_type":"cash","minimum_change":0.05'
expect "A10m a NEW alert from a declared client choosing 5c: 5c" "$(prefs_row "$STATION2")" "cash|0.050|360|price_drop|-"
delete_at "$STATION2"
echo "   ok"

# ======================================================================================================================
echo "== A11: single-field edits keep everything else (payment-only, target-only, sensitivity-only)"
set_alert "$V2"',"alert_mode":"at_or_below","threshold_price":2.89,"payment_type":"cash","minimum_change":0.15,"cooldown_minutes":720'
expect "A11 setup" "$(prefs_row)" "cash|0.150|720|at_or_below|2.890"
set_alert "$V2"',"alert_mode":"at_or_below","threshold_price":2.89,"payment_type":"credit","cooldown_minutes":720'
expect "A11a payment-only edit (no minimum_change): the method changes, the drop size and target stay" "$(prefs_row)" "credit|0.150|720|at_or_below|2.890"
set_alert "$V2"',"alert_mode":"at_or_below","threshold_price":2.79,"cooldown_minutes":720'
expect "A11b target-only edit (no method, no minimum_change): the target changes, method and drop size stay" "$(prefs_row)" "credit|0.150|720|at_or_below|2.790"
set_alert "$V2"',"alert_mode":"at_or_below","threshold_price":2.79,"minimum_change":0.2,"cooldown_minutes":720'
expect "A11c sensitivity-only edit (no method): the drop size changes, method and target stay" "$(prefs_row)" "credit|0.200|720|at_or_below|2.790"
set_alert "$V2"',"alert_mode":"at_or_below","threshold_price":2.79,"payment_type":"cash","minimum_change":0.2,"cooldown_minutes":720'
expect "A11d the shape the app really sends (everything carried, one thing changed): only the method changes" "$(prefs_row)" "cash|0.200|720|at_or_below|2.790"
set_alert ',"alert_mode":"at_or_below","threshold_price":2.79'
expect "A11e (unchanged behavior) cooldown_minutes is still replaced by every save, 360 when omitted; the contract covers the drop size only" "$(prefs_row)" "cash|0.200|360|at_or_below|2.790"
echo "   ok"

# ======================================================================================================================
echo "== A12: malformed capability metadata fails safely, and well-formed metadata is accepted"
set_alert "$V2"',"alert_mode":"price_drop","payment_type":"credit","minimum_change":0.2,"cooldown_minutes":360'
BEFORE="$(alert_row)"
for bad in '"2"' '"two"' '""' '" 2"' '0' '-1' '1.5' '2.5' '1001' '100000' 'true' 'false' '[]' '[2]' '{}' '{"v":2}'; do
  set_alert ",\"alert_contract_version\":$bad,\"alert_mode\":\"price_drop\",\"payment_type\":\"cash\",\"minimum_change\":0.05"
  expect "A12 alert_contract_version=$bad" "$CODE $(field .error)" "400 invalid_alert_contract_version"
done
expect "A12 every refused request changed nothing" "$(alert_row)" "$BEFORE"
for versioned in null 1; do
  set_alert "$V2"',"alert_mode":"price_drop","payment_type":"credit","minimum_change":0.2'
  set_alert ",\"alert_contract_version\":$versioned,\"alert_mode\":\"price_drop\",\"minimum_change\":0.05"
  expect "A12 alert_contract_version=$versioned is a pre-contract client: the 20c is kept" "$CODE $(prefs_row)" "200 credit|0.200|360|price_drop|-"
done
for versioned in 2 3 1000; do
  set_alert "$V2"',"alert_mode":"price_drop","payment_type":"credit","minimum_change":0.2'
  set_alert ",\"alert_contract_version\":$versioned,\"alert_mode\":\"price_drop\",\"minimum_change\":0.05"
  expect "A12 alert_contract_version=$versioned is a declared client: its 5c is applied" "$CODE $(prefs_row)" "200 credit|0.050|360|price_drop|-"
done
set_alert "$V2"',"alert_mode":"price_drop","payment_type":"credit","minimum_change":5'
expect "A12 the version never rescues an out-of-range value" "$CODE $(field .error)" "400 invalid_alert_preferences"
echo "   ok"

# ======================================================================================================================
echo "== A13: repeated identical saves are safe"
set_alert "$V2"',"alert_mode":"price_drop","payment_type":"credit","minimum_change":0.1,"cooldown_minutes":360'
ID13="$(field .alert.id)"
sql "update private.price_alerts set last_notified_price = 3.20, last_notified_at = now() - interval '2 hours',
       baseline_price = 3.25, baseline_at = now() - interval '30 minutes' where id = '$ID13'" >/dev/null
SNAP13="$(sql "select alert_mode, payment_type, minimum_change, cooldown_minutes, baseline_price, baseline_at::text, last_notified_price, last_notified_at::text, enabled
               from private.price_alerts where id = '$ID13'")"
for i in 1 2 3 4 5; do
  set_alert "$V2"',"alert_mode":"price_drop","payment_type":"credit","minimum_change":0.1,"cooldown_minutes":360'
  expect "A13 save $i answers with the same alert" "$CODE $(field .alert.id)" "200 $ID13"
done
expect "A13 the alert row is byte-for-byte what it was (reference, notification memory, everything)" \
  "$(sql "select alert_mode, payment_type, minimum_change, cooldown_minutes, baseline_price, baseline_at::text, last_notified_price, last_notified_at::text, enabled
          from private.price_alerts where id = '$ID13'")" "$SNAP13"
expect "A13 still one alert for the station" \
  "$(sql "select count(*) from private.price_alerts where station_id = '$STATION' and installation_id = (select id from private.price_alert_installations where client_installation_id = '$ID_PRO')")" "1"
expect "A13 saving queued nothing" "$(sql "select count(*) from private.price_alert_deliveries where alert_id = '$ID13'")" "0"
echo "   ok"

# ======================================================================================================================
echo "== A14: concurrent saves do not lose configuration"
# X changes only the payment method, Y only the drop size, Z is an older client re-saving the fixed 0.05. Whatever the order,
# the outcome must hold both X and Y: credit + 20c. Each round starts from cash + 10c.
BG_PIDS=()
post_bg() { # <json> <out file>   (collects the PID: a bare `wait` would also wait for the API server this script started)
  curl -s -m 60 -X POST "$URL" -H 'content-type: application/json' -H "apikey: $KEY" -d "$1" -o "$2" -w '%{http_code}' >"$2.code" &
  BG_PIDS+=("$!")
}
BASE14="{\"action\":\"set_alert\",\"client_installation_id\":\"$ID_PRO\",\"installation_secret\":\"$SECRET_PRO\",\"station_id\":\"$STATION\",\"alert_mode\":\"price_drop\""
ROUNDS=15
for round in $(seq 1 $ROUNDS); do
  set_alert "$V2"',"alert_mode":"price_drop","payment_type":"cash","minimum_change":0.1'
  post_bg "$BASE14$V2,\"payment_type\":\"credit\"}" "$TMP/x$round"
  post_bg "$BASE14$V2,\"minimum_change\":0.2}" "$TMP/y$round"
  post_bg "$BASE14,\"minimum_change\":0.05}" "$TMP/z$round"
  wait "${BG_PIDS[@]}"
  BG_PIDS=()
  codes="$(cat "$TMP/x$round.code" "$TMP/y$round.code" "$TMP/z$round.code")"      # curl -w writes no newline: "200200200"
  expect "A14 round $round: all three saves answered 200" "$codes" "200200200"
  expect "A14 round $round: both changes survive (credit + 20c), in whatever order they ran" "$(prefs_row)" "credit|0.200|360|price_drop|-"
done
echo "   ok ($ROUNDS rounds of three concurrent saves)"

# ======================================================================================================================
echo "== A15: the Pro gate is unchanged by the version"
for v in '"alert_contract_version":2' '"alert_contract_version":"x"' '"alert_contract_version":null'; do
  post "{\"action\":\"set_alert\",\"client_installation_id\":\"$ID_FREE\",\"installation_secret\":\"$SECRET_FREE\",\"station_id\":\"$STATION\",\"alert_mode\":\"price_drop\",\"payment_type\":\"credit\",$v,\"minimum_change\":0.2}"
  expect "A15 a non-Pro installation sending $v" "$CODE $(field .error)" "403 pro_required"
done
expect "A15 nothing was stored for the free installation" \
  "$(sql "select count(*) from private.price_alerts where installation_id = (select id from private.price_alert_installations where client_installation_id = '$ID_FREE')")" "0"
echo "   ok"

# ======================================================================================================================
echo "== A16: moving a LEGACY alert to Cash / Credit over HTTP"
# Station 3: an unclassified price and a credit price, no cash price at all.
mk_report unknown 3.40 '3 hours' l16u "$STATION3"
mk_report credit 3.19 '90 minutes' l16c "$STATION3"
set_alert_at "$STATION3" ',"alert_mode":"at_or_below","threshold_price":3.25,"minimum_change":0.07,"cooldown_minutes":720'
LEGACY_ID="$(field .alert.id)"
expect "A16a an older client's alert is legacy (method unknown) with the settings it chose" "$CODE $(field .alert.payment_type) $(prefs_row "$STATION3")" "200 unknown unknown|0.070|720|at_or_below|3.250"
sql "update private.price_alerts set last_notified_price = 3.60, last_notified_at = now() - interval '3 hours' where id = '$LEGACY_ID'" >/dev/null
NOTIFIED_AT="$(sql "select last_notified_at::text from private.price_alerts where id = '$LEGACY_ID'")"
list_alerts
expect "A16b list_alerts reports the legacy method" "$(jq -r '.alerts[] | select(.station_id=="'"$STATION3"'") | .payment_type' <<<"$BODY")" "unknown"
set_alert_at "$STATION3" "$V2"',"alert_mode":"at_or_below","threshold_price":3.25,"payment_type":"cash","minimum_change":0.07,"cooldown_minutes":720'
expect "A16c choosing Cash: the same alert, only the method changed" "$CODE $(field .alert.id) $(prefs_row "$STATION3")" "200 $LEGACY_ID cash|0.070|720|at_or_below|3.250"
expect "A16d ...no cash price exists, so the reference is EMPTY (nothing is borrowed from the credit or unclassified prices); the notification time is kept, the old notified price forgotten" \
  "$(sql "select coalesce(baseline_price::text, '-') || '|' || coalesce(last_notified_price::text, '-') || '|' || (last_notified_at::text = '$NOTIFIED_AT') from private.price_alerts where id = '$LEGACY_ID'")" "-|-|true"
list_alerts
expect "A16e list_alerts: method cash, no comparable price yet, the newest report of any kind is still the credit one" \
  "$(jq -r '.alerts[] | select(.station_id=="'"$STATION3"'") | [.payment_type, (.latest_comparable_price == null), (.latest_price|tonumber|.*1)] | join(" ")' <<<"$BODY")" "cash true 3.19"
set_alert_at "$STATION3" "$V2"',"alert_mode":"at_or_below","threshold_price":3.25,"payment_type":"credit","minimum_change":0.07,"cooldown_minutes":720'
expect "A16f choosing Credit instead anchors to the credit price" \
  "$(prefs_row "$STATION3") $(sql "select baseline_price from private.price_alerts where id = '$LEGACY_ID'")" "credit|0.070|720|at_or_below|3.250 3.190"
echo "   ok"

echo "ALL PRICE ALERT API PAYMENT-TYPE SCENARIOS PASSED (A1-A16)"

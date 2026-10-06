#!/usr/bin/env bash
# 85Blends 2.4.1 — price-alerts-api registerDevice: concurrent Android (and iOS) registration safety.
#
# LOCAL-REPLAY ONLY. Starts the REAL supabase/functions/price-alerts-api/index.ts under Deno on a local
# port, pointed (SUPABASE_DB_URL) at a SCRATCH database that already has the full migration chain applied,
# and drives it over HTTP with concurrent requests. Needs: deno, curl, psql, and the standard libpq
# environment (PGHOST/PGPORT/PGUSER/PGDATABASE). The API itself connects over TCP, so set API_DB_URL if the
# scratch server is not reachable at 127.0.0.1:$PGPORT (default: postgresql://$PGUSER@127.0.0.1:$PGPORT/$PGDATABASE).
# Optional: DENO (path to deno), API_PORT (default 8791), DENO_CERT / HOME when the environment needs them.
# It COMMITS its fixtures (installations/devices under a marker, via the API) and deletes them on exit.
# NEVER point it at a hosted project.
#
# What it proves (the invariant: at most ONE active Android device per installation + package, and a race
# between registrations must neither leave two active tokens nor surface an error):
#   R1  sequential Android registrations: one active token, the replacement active, the previous one
#       disabled + invalidated.
#   R2  12 concurrent Android registrations (different tokens) for ONE installation + package, 5 rounds:
#       every request is HTTP 200 (no unique-violation 500), exactly one active token afterwards.
#   R3  concurrent registrations across 6 DIFFERENT installations: all 200, each ends with exactly one
#       active token (independent).
#   R4  iOS is unchanged: sequential registrations leave one active iOS token; iOS + Android concurrently on
#       one installation both succeed and coexist.
#   R5  the lock is per installation: while installation A's row is locked by another session, a
#       registration for installation B returns immediately and one for A waits for the release, then succeeds.
#   R6  the migration refuses to run (without modifying data) when duplicate active Android rows already exist.
set -euo pipefail

DENO="${DENO:-deno}"
API_PORT="${API_PORT:-8791}"
API_DB_URL="${API_DB_URL:-postgresql://${PGUSER:-postgres}@127.0.0.1:${PGPORT:-5432}/${PGDATABASE:?PGDATABASE required}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$HERE/../functions/price-alerts-api"
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1)
TMP="$(mktemp -d)"
IDS="$TMP/installation_ids"; : > "$IDS"
KEY="synthetic-publishable-key-for-local-tests"
URL="http://127.0.0.1:${API_PORT}"
APIPID=""

sql() { "${PSQL[@]}" -c "$1"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
now_ms() { date +%s%3N; }
# wait for the background request jobs only (a bare `wait` would also wait for the API server forever)
wait_requests() { local p; for p in $(jobs -p); do [ "$p" = "$APIPID" ] || wait "$p" || true; done; }

cleanup() {
  [ -n "$APIPID" ] && kill "$APIPID" 2>/dev/null || true
  if [ -s "$IDS" ]; then
    "${PSQL[@]}" -c "delete from private.price_alert_installations where client_installation_id::text in ($(sed "s/.*/'&'/" "$IDS" | paste -sd, -));" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---- start the real API ------------------------------------------------------------------------------
( cd "$API_DIR" && SUPABASE_DB_URL="$API_DB_URL" SUPABASE_PUBLISHABLE_KEYS="{\"default\":\"$KEY\"}" \
    DENO_SERVE_ADDRESS="tcp:127.0.0.1:${API_PORT}" exec "$DENO" run --config deno.json -A index.ts >"$TMP/api.log" 2>&1 ) &
APIPID=$!
for _ in $(seq 1 60); do grep -q "Listening on" "$TMP/api.log" 2>/dev/null && break; sleep 0.5; done
grep -q "Listening on" "$TMP/api.log" || fail "the API did not start: $(cat "$TMP/api.log")"

# call <json> -> prints "<http code> <body>"
call() { curl -s -m 60 -X POST "$URL" -H 'content-type: application/json' -H "apikey: $KEY" -d "$1" -w ' %{http_code}'; }
code_of() { echo "${1##* }"; }

new_installation() { # prints "<id> <secret>"; bootstrap as <platform>
  local id secret
  id="$(cat /proc/sys/kernel/random/uuid)"; secret="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  echo "$id" >> "$IDS"
  local out; out="$(call "{\"action\":\"bootstrap\",\"client_installation_id\":\"$id\",\"installation_secret\":\"$secret\",\"platform\":\"$1\"}")"
  [ "$(code_of "$out")" = "200" ] || fail "bootstrap failed: $out"
  echo "$id $secret"
}
reg_android() { # id secret package token -> "<body> <code>"
  call "{\"action\":\"register_device\",\"client_installation_id\":\"$1\",\"installation_secret\":\"$2\",\"platform\":\"android\",\"package_name\":\"$3\",\"fcm_token\":\"$4\"}"
}
reg_ios() { # id secret bundle env token
  call "{\"action\":\"register_device\",\"client_installation_id\":\"$1\",\"installation_secret\":\"$2\",\"platform\":\"ios\",\"bundle_id\":\"$3\",\"apns_environment\":\"$4\",\"device_token\":\"$5\"}"
}
active_android() { sql "select count(*) from private.price_alert_push_devices d join private.price_alert_installations i on i.id = d.installation_id
                        where i.client_installation_id = '$1' and d.platform = 'android' and d.bundle_id = '$2' and d.enabled and d.invalidated_at is null"; }
active_ios() { sql "select count(*) from private.price_alert_push_devices d join private.price_alert_installations i on i.id = d.installation_id
                    where i.client_installation_id = '$1' and d.platform = 'ios' and d.enabled and d.invalidated_at is null"; }
tok() { printf 'fcm-token-%s-%s' "$1" "$(head -c 20 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }

PKG="com.e85blends.android.test"

# ======================================================================================================
echo "== R1: sequential Android registrations leave one active token"
read -r ID SEC < <(new_installation android)
T1="$(tok r1a)"; T2="$(tok r1b)"; T3="$(tok r1c)"
[ "$(code_of "$(reg_android "$ID" "$SEC" "$PKG" "$T1")")" = "200" ] || fail "R1 first registration"
[ "$(active_android "$ID" "$PKG")" = "1" ] || fail "R1 one active after the first registration"
[ "$(code_of "$(reg_android "$ID" "$SEC" "$PKG" "$T2")")" = "200" ] || fail "R1 second registration"
[ "$(active_android "$ID" "$PKG")" = "1" ] || fail "R1 one active after the second registration"
[ "$(sql "select d.device_token from private.price_alert_push_devices d join private.price_alert_installations i on i.id = d.installation_id
          where i.client_installation_id = '$ID' and d.enabled and d.invalidated_at is null")" = "$T2" ] || fail "R1 the replacement token is the active one"
[ "$(sql "select (not d.enabled and d.invalidated_at is not null)::int from private.price_alert_push_devices d join private.price_alert_installations i on i.id = d.installation_id
          where i.client_installation_id = '$ID' and d.device_token = '$T1'")" = "1" ] || fail "R1 the previous token is disabled and invalidated"
[ "$(code_of "$(reg_android "$ID" "$SEC" "$PKG" "$T3")")" = "200" ] || fail "R1 third registration"
[ "$(active_android "$ID" "$PKG")" = "1" ] || fail "R1 one active after the third registration"
echo "   ok"

# ======================================================================================================
echo "== R2: 12 concurrent Android registrations for one installation + package (5 rounds)"
read -r ID SEC < <(new_installation android)
TOTAL_NON200=0
for ROUND in 1 2 3 4 5; do
  rm -f "$TMP"/r2.*
  for N in $(seq 1 12); do
    ( reg_android "$ID" "$SEC" "$PKG" "$(tok "r2-$ROUND-$N")" > "$TMP/r2.$N" ) &
  done
  wait_requests
  for N in $(seq 1 12); do
    C="$(code_of "$(cat "$TMP/r2.$N")")"
    [ "$C" = "200" ] || { TOTAL_NON200=$((TOTAL_NON200 + 1)); echo "   round $ROUND request $N -> $(cat "$TMP/r2.$N")"; }
  done
  A="$(active_android "$ID" "$PKG")"
  [ "$A" = "1" ] || fail "R2 round $ROUND: $A active Android tokens after 12 concurrent registrations (expected exactly 1)"
done
[ "$TOTAL_NON200" = "0" ] || fail "R2 $TOTAL_NON200 concurrent registration(s) did not return HTTP 200 (an unhandled uniqueness failure surfaced)"
echo "   ok (60 concurrent registrations, all 200, exactly one active token after every round)"

# ======================================================================================================
echo "== R3: 6 independent installations registering concurrently (3 tokens each)"
declare -a IDS_R3=() SECS_R3=()
for K in 1 2 3 4 5 6; do read -r I S < <(new_installation android); IDS_R3+=("$I"); SECS_R3+=("$S"); done
rm -f "$TMP"/r3.*
for K in 0 1 2 3 4 5; do for N in 1 2 3; do
  ( reg_android "${IDS_R3[$K]}" "${SECS_R3[$K]}" "$PKG" "$(tok "r3-$K-$N")" > "$TMP/r3.$K.$N" ) &
done; done
wait_requests
for K in 0 1 2 3 4 5; do
  for N in 1 2 3; do [ "$(code_of "$(cat "$TMP/r3.$K.$N")")" = "200" ] || fail "R3 installation $K request $N: $(cat "$TMP/r3.$K.$N")"; done
  [ "$(active_android "${IDS_R3[$K]}" "$PKG")" = "1" ] || fail "R3 installation $K does not have exactly one active token"
done
echo "   ok"

# ======================================================================================================
echo "== R4: iOS unchanged; iOS + Android concurrently on one installation"
read -r ID SEC < <(new_installation ios)
IOS_B="com.e85blends.app.ios.internal"
[ "$(code_of "$(reg_ios "$ID" "$SEC" "$IOS_B" sandbox "$(printf 'a%.0s' {1..64})")")" = "200" ] || fail "R4 first iOS registration"
[ "$(code_of "$(reg_ios "$ID" "$SEC" "$IOS_B" sandbox "$(printf 'b%.0s' {1..64})")")" = "200" ] || fail "R4 second iOS registration"
[ "$(active_ios "$ID")" = "1" ] || fail "R4 sequential iOS registrations in one environment leave one active iOS token (unchanged semantics)"
[ "$(sql "select d.device_token from private.price_alert_push_devices d join private.price_alert_installations i on i.id = d.installation_id
          where i.client_installation_id = '$ID' and d.platform = 'ios' and d.enabled and d.invalidated_at is null")" = "$(printf 'b%.0s' {1..64})" ] || fail "R4 the newer iOS token is the active one"
rm -f "$TMP"/r4.*
for N in 1 2 3 4; do
  ( reg_ios "$ID" "$SEC" "$IOS_B" sandbox "$(printf '%064d' "$N")" > "$TMP/r4.i.$N" ) &
  ( reg_android "$ID" "$SEC" "$PKG" "$(tok "r4-$N")" > "$TMP/r4.a.$N" ) &
done
wait_requests
for N in 1 2 3 4; do
  [ "$(code_of "$(cat "$TMP/r4.i.$N")")" = "200" ] || fail "R4 iOS request $N: $(cat "$TMP/r4.i.$N")"
  [ "$(code_of "$(cat "$TMP/r4.a.$N")")" = "200" ] || fail "R4 Android request $N: $(cat "$TMP/r4.a.$N")"
done
[ "$(active_ios "$ID")" = "1" ] && [ "$(active_android "$ID" "$PKG")" = "1" ] || fail "R4 one active iOS and one active Android token coexist (ios=$(active_ios "$ID") android=$(active_android "$ID" "$PKG"))"
echo "   ok"

# ======================================================================================================
echo "== R5: the lock is per installation (only competing registrations wait)"
read -r IDA SECA < <(new_installation android)
read -r IDB SECB < <(new_installation android)
( "${PSQL[@]}" -c "begin; select id from private.price_alert_installations where client_installation_id = '$IDA' for no key update; select pg_sleep(4); commit;" >"$TMP/lock.out" 2>&1 ) &
LOCK_PID=$!
sleep 1
START=$(now_ms); OUT_B="$(reg_android "$IDB" "$SECB" "$PKG" "$(tok r5b)")"; MS_B=$(( $(now_ms) - START ))
echo "   registration for the OTHER installation while A is locked: $MS_B ms"
[ "$(code_of "$OUT_B")" = "200" ] || fail "R5 registration for installation B: $OUT_B"
[ "$MS_B" -lt 2000 ] || fail "R5 an unrelated installation's registration waited ${MS_B} ms behind installation A's lock"
START=$(now_ms); OUT_A="$(reg_android "$IDA" "$SECA" "$PKG" "$(tok r5a)")"; MS_A=$(( $(now_ms) - START ))
echo "   registration for the LOCKED installation: $MS_A ms (waited for the release), result $(code_of "$OUT_A")"
[ "$(code_of "$OUT_A")" = "200" ] || fail "R5 registration for installation A after the release: $OUT_A"
[ "$MS_A" -ge 1500 ] || fail "R5 the locked installation's registration did not wait for the lock (${MS_A} ms): the serialization lock is missing"
wait "$LOCK_PID"
[ "$(active_android "$IDA" "$PKG")" = "1" ] || fail "R5 installation A has exactly one active token"
echo "   ok"

# ======================================================================================================
echo "== R6: the migration refuses to run when duplicate active Android rows exist (and changes no data)"
kill "$APIPID" 2>/dev/null || true; APIPID=""
for _ in $(seq 1 20); do [ "$(sql "select count(*) from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid()")" = "0" ] && break; sleep 0.5; done
GUARD_DB="${PGDATABASE}_guard$$"
"${PSQL[@]}" -d postgres -c "create database \"$GUARD_DB\" template \"$PGDATABASE\"" >/dev/null || fail "R6 could not clone the scratch database"
guard_cleanup() { "${PSQL[@]}" -d postgres -c "drop database if exists \"$GUARD_DB\"" >/dev/null 2>&1 || true; }
trap 'guard_cleanup; cleanup' EXIT
"${PSQL[@]}" -d "$GUARD_DB" -c "
  drop index private.price_alert_push_devices_one_active_android_per_install_idx;
  insert into private.price_alert_installations (client_installation_id, installation_secret_hash, client_platform) values (gen_random_uuid(), repeat('9', 64), 'android');
  insert into private.price_alert_push_devices (installation_id, platform, bundle_id, apns_environment, device_token, device_token_hash)
    select id, 'android', 'com.dup.test', null, 'fcm-dup-token-' || g || repeat('x', 20), md5('dup' || g) || md5('dup2' || g)
    from private.price_alert_installations, generate_series(1, 2) g where installation_secret_hash = repeat('9', 64);" >/dev/null
BEFORE="$("${PSQL[@]}" -d "$GUARD_DB" -c "select count(*) || ':' || count(*) filter (where enabled and invalidated_at is null) from private.price_alert_push_devices where bundle_id = 'com.dup.test'")"
if "${PSQL[@]}" -d "$GUARD_DB" -f "$HERE/../migrations/20261006000000_price_alert_android_active_device_uniqueness.sql" >"$TMP/guard.out" 2>&1; then
  fail "R6 the migration ran although duplicate active Android devices exist"
fi
grep -q "more than one active Android device" "$TMP/guard.out" || fail "R6 unexpected guard message: $(cat "$TMP/guard.out")"
grep -qE 'fcm-dup-token' "$TMP/guard.out" && fail "R6 the guard message leaked a device token"
AFTER="$("${PSQL[@]}" -d "$GUARD_DB" -c "select count(*) || ':' || count(*) filter (where enabled and invalidated_at is null) from private.price_alert_push_devices where bundle_id = 'com.dup.test'")"
[ "$BEFORE" = "$AFTER" ] && [ "$BEFORE" = "2:2" ] || fail "R6 the guard must not change data (before=$BEFORE after=$AFTER)"
[ "$("${PSQL[@]}" -d "$GUARD_DB" -c "select count(*) from pg_indexes where indexname = 'price_alert_push_devices_one_active_android_per_install_idx'")" = "0" ] || fail "R6 the index must not exist after a refused apply"
echo "   ok"

echo "ALL PRICE ALERT API ANDROID REGISTRATION SCENARIOS PASSED"

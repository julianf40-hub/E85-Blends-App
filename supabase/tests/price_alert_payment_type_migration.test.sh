#!/usr/bin/env bash
# 85Blends 2.4.1 — Phase 3C data-preservation test for migrations A and B
#   20261007120000_community_price_payment_type.sql
#   20261007130000_price_alert_payment_aware_evaluation.sql
#
# LOCAL-REPLAY ONLY. Builds a FRESH scratch database (dropped first) on a LOCAL Postgres, replays every
# migration up to but not including A, seeds "production-shaped" legacy data in the OLD schema, applies A
# and then B, and proves that applying them:
#   M1  keeps every report row exactly (ids, prices, timestamps, reporter, note, app version), rewrites
#       no table, backfills nothing, and reads every legacy report as 'unknown';
#   M2  keeps every alert's configuration and notification history; gives each the payment type 'unknown'
#       (never a guessed cash/credit) and fills its reference price only from a real recent 'unknown' report;
#   M3  does not touch, re-evaluate, re-queue or re-send a single delivery or job that already exists, and
#       creates no new ones (no retroactive send);
#   M4  does not touch the cron jobs, the Vault or send any request (pg_net stand-in log unchanged);
#   M5  leaves older clients working (a report with no payment_type is stored as 'unknown') and new
#       clients working (a typed report) under the real column-scoped grant;
#   M6  is idempotent: applying A and B again changes nothing;
#   M7  leaves a delivery that was pending before B claimable, unchanged, by the existing claim function.
#
# Usage: price_alert_payment_type_migration.test.sh [database-name]      (default e85_payment_migration_test)
# Environment: PGHOST/PGPORT/PGUSER of a LOCAL Postgres (see README.md). Never point it at a hosted project.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DB="${1:-e85_payment_migration_test}"
export PGHOST="${PGHOST:-/var/run/postgresql}" PGPORT="${PGPORT:-55432}" PGUSER="${PGUSER:-postgres}"
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB")
A="$REPO/supabase/migrations/20261007120000_community_price_payment_type.sql"
B="$REPO/supabase/migrations/20261007130000_price_alert_payment_aware_evaluation.sql"

fail() { echo "FAILED: $*" >&2; exit 1; }
sql() { "${PSQL[@]}" -c "$1"; }
expect() { [ "$(sql "$1")" = "$2" ] || fail "$3 (got '$(sql "$1")', wanted '$2')"; }

bash "$HERE/support/replay_migrations.sh" "$DB" --before 20261007120000

# ---- legacy data, in the OLD schema (no payment_type anywhere) -----------------------------------------------
"${PSQL[@]}" <<'SQL'
insert into public.community_stations (id, name, normalized_key) values
  ('a0000000-0000-4000-8000-000000000001', 'Legacy Fresh',  'legacy-fresh'),
  ('a0000000-0000-4000-8000-000000000002', 'Legacy Old',    'legacy-old'),
  ('a0000000-0000-4000-8000-000000000003', 'Legacy No Rpt', 'legacy-no-reports');

-- reports: fixed ids, prices, timestamps, reporters, note, app version
insert into public.e85_price_reports (id, station_id, price, reported_at, anonymous_reporter_id, app_version, note, created_at) values
  ('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', 3.49, now() - interval '3 days',    'rep-a', '2.3.2', null,           now() - interval '3 days'),
  ('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001', 3.29, now() - interval '1 day',     'rep-b', '2.4.0', 'cheap today',  now() - interval '1 day'),
  ('b0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000001', 3.19, now() - interval '10 minutes', 'rep-a', '2.4.0', null,           now() - interval '10 minutes'),
  ('b0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000002', 3.99, now() - interval '30 days',   'rep-c', null,    null,           now() - interval '30 days');

-- installations / devices / alerts with non-default settings and notification history
insert into private.revenuecat_customers (original_app_user_id, environment, entitlement_id, pro_is_active)
values ('$RCAnonymousID:migration-test', 'SANDBOX', 'pro', true);
insert into private.price_alert_installations (id, client_installation_id, installation_secret_hash, revenuecat_app_user_id, revenuecat_environment, revenuecat_customer_id)
select 'c0000000-0000-4000-8000-000000000001', gen_random_uuid(), repeat('a', 64), '$RCAnonymousID:migration-test', 'SANDBOX', c.id
from private.revenuecat_customers c where c.original_app_user_id = '$RCAnonymousID:migration-test';
insert into private.price_alert_push_devices (id, installation_id, bundle_id, apns_environment, device_token, device_token_hash)
values ('d0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'com.e85blends.app.ios.internal', 'sandbox', repeat('b', 64), repeat('c', 64));

insert into private.price_alerts (id, installation_id, station_id, alert_mode, threshold_price, minimum_change, cooldown_minutes, enabled, last_notified_price, last_notified_at) values
  ('e0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', 'price_drop',  null, 0.050, 360, true,  3.29, now() - interval '1 day'),
  ('e0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000002', 'at_or_below', 3.500, 0.100, 120, true,  null, null),
  ('e0000000-0000-4000-8000-000000000003', 'c0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000003', 'any_change',  null, 0.250, 1440, true, null, null);

-- jobs and deliveries in every state the pipeline can hold them
insert into private.price_alert_jobs (id, price_report_id, status, attempt_count) values
  ('f0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000003', 'processing', 1),
  ('f0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000002', 'completed', 1);
insert into private.price_alert_deliveries (id, alert_id, price_report_id, push_device_id, observed_price, previous_price, status, reason_code) values
  ('01000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000001', 3.19, 3.29, 'pending', 'price_dropped'),
  ('01000000-0000-4000-8000-000000000002', 'e0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002', 'd0000000-0000-4000-8000-000000000001', 3.29, 3.49, 'sent',    'price_dropped'),
  ('01000000-0000-4000-8000-000000000003', 'e0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000004', 'd0000000-0000-4000-8000-000000000001', 3.99, null, 'skipped', 'above_threshold');

-- snapshots of everything the migrations must not disturb
create schema snap;
create table snap.reports    as select * from public.e85_price_reports;
create table snap.alerts     as select * from private.price_alerts;
create table snap.deliveries as select * from private.price_alert_deliveries;
create table snap.jobs       as select * from private.price_alert_jobs;
create table snap.cron       as select jobid, jobname, schedule, command, active from cron.job;
create table snap.vault      as select name, secret from vault.secrets;
create table snap.net        as select id, url from net.sent_requests;
create table snap.meta       as select (select relfilenode from pg_class where oid = 'public.e85_price_reports'::regclass) as reports_relfilenode;
SQL

# ---- apply A, then B (as the Supabase CLI would: each file in order) -----------------------------------------
"${PSQL[@]}" -f "$A" >/dev/null
"${PSQL[@]}" -f "$B" >/dev/null

# ---- M1 reports ------------------------------------------------------------------------------------------------
expect "select count(*) from public.e85_price_reports" "$(sql 'select count(*) from snap.reports')" "M1a no report added or removed"
expect "select count(*) from (select id, station_id, price, reported_at, anonymous_reporter_id, app_version, note, created_at from snap.reports
        except select id, station_id, price, reported_at, anonymous_reporter_id, app_version, note, created_at from public.e85_price_reports) x" "0" "M1b every report is byte-identical (ids, prices, timestamps, reporter, note, app version)"
expect "select count(*) from public.e85_price_reports where payment_type = 'unknown'" "$(sql 'select count(*) from snap.reports')" "M1c every legacy report reads 'unknown' (nothing guessed)"
expect "select count(*) from public.e85_price_reports where payment_type <> 'unknown'" "0" "M1d no legacy report was assigned cash, credit or same_for_both"
expect "select (relfilenode = (select reports_relfilenode from snap.meta))::text from pg_class where oid = 'public.e85_price_reports'::regclass" "true" "M1e the reports table was not rewritten"

# ---- M2 alerts -------------------------------------------------------------------------------------------------
expect "select count(*) from (select id, installation_id, station_id, alert_mode, threshold_price, minimum_change, cooldown_minutes, enabled, last_notified_price, last_notified_at, created_at from snap.alerts
        except select id, installation_id, station_id, alert_mode, threshold_price, minimum_change, cooldown_minutes, enabled, last_notified_price, last_notified_at, created_at from private.price_alerts) x" "0" "M2a every alert keeps its mode, threshold, sensitivity, cooldown, enabled flag and notification history"
expect "select count(*) from private.price_alerts where payment_type = 'unknown'" "3" "M2b every existing alert is 'unknown' - no method is invented"
expect "select baseline_price::text from private.price_alerts where id = 'e0000000-0000-4000-8000-000000000001'" "3.190" "M2c an alert on a station with a recent report gets the latest report price as its reference (what the old engine would have compared with)"
expect "select baseline_price is null from private.price_alerts where id = 'e0000000-0000-4000-8000-000000000002'" "t" "M2d a station whose only report is 30 days old gets NO reference (not trusted, not invented)"
expect "select baseline_price is null from private.price_alerts where id = 'e0000000-0000-4000-8000-000000000003'" "t" "M2e a station with no report at all gets none"

# ---- M3 deliveries and jobs ------------------------------------------------------------------------------------
expect "select count(*) from private.price_alert_deliveries" "$(sql 'select count(*) from snap.deliveries')" "M3a no delivery was created or removed"
expect "select count(*) from (select id, alert_id, price_report_id, push_device_id, observed_price, previous_price, status, reason_code, attempt_count, available_at, locked_at, sent_at from snap.deliveries
        except select id, alert_id, price_report_id, push_device_id, observed_price, previous_price, status, reason_code, attempt_count, available_at, locked_at, sent_at from private.price_alert_deliveries) x" "0" "M3b every existing delivery is unchanged (nothing re-evaluated, nothing re-sent)"
expect "select count(*) from private.price_alert_deliveries where payment_type is not null" "0" "M3c old deliveries carry no payment type (they are never reinterpreted)"
expect "select count(*) from (select id, price_report_id, status, attempt_count from snap.jobs except select id, price_report_id, status, attempt_count from private.price_alert_jobs) x" "0" "M3d every existing job is unchanged"
expect "select count(*) from private.price_alert_jobs" "$(sql 'select count(*) from snap.jobs')" "M3e no job was created"

# ---- M4 scheduler, secrets, network ----------------------------------------------------------------------------
expect "select count(*) from (select jobid, jobname, schedule, command, active from snap.cron except select jobid, jobname, schedule, command, active from cron.job) x" "0" "M4a the cron jobs are untouched (schedule, command and active flag)"
expect "select count(*) from cron.job" "$(sql 'select count(*) from snap.cron')" "M4b no cron job added or removed"
expect "select count(*) from (select name, secret from snap.vault except select name, secret from vault.secrets) x" "0" "M4c no Vault secret changed"
expect "select count(*) from net.sent_requests" "$(sql 'select count(*) from snap.net')" "M4d no request was sent"

# ---- M5 older and newer clients under the real column-scoped grant ----------------------------------------------
sql "begin;
     select set_config('request.jwt.claim.role', 'anon', true);
     set local role anon;
     insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, app_version) values ('a0000000-0000-4000-8000-000000000003', 3.10, now(), 'older-client', '2.4.0');
     insert into public.e85_price_reports (station_id, price, reported_at, anonymous_reporter_id, payment_type) values ('a0000000-0000-4000-8000-000000000003', 2.99, now(), 'newer-client', 'cash');
     commit;" >/dev/null
expect "select payment_type from public.e85_price_reports where anonymous_reporter_id = 'older-client'" "unknown" "M5a an older app's report (no payment_type) is accepted and stored as unknown"
expect "select payment_type from public.e85_price_reports where anonymous_reporter_id = 'newer-client'" "cash" "M5b a newer app's typed report is accepted"

# ---- M6 idempotent re-apply ------------------------------------------------------------------------------------
BEFORE_HASH="$(sql "select md5(string_agg(x::text, '|' order by x::text)) from (
                      select id, payment_type, baseline_price, baseline_at, last_notified_price, minimum_change from private.price_alerts) x")"
"${PSQL[@]}" -f "$A" >/dev/null 2>&1
"${PSQL[@]}" -f "$B" >/dev/null 2>&1
AFTER_HASH="$(sql "select md5(string_agg(x::text, '|' order by x::text)) from (
                     select id, payment_type, baseline_price, baseline_at, last_notified_price, minimum_change from private.price_alerts) x")"
[ "$BEFORE_HASH" = "$AFTER_HASH" ] || fail "M6a re-applying A and B changed alert state"
expect "select count(*) from pg_trigger where tgrelid = 'private.price_alerts'::regclass and tgname = 'price_alerts_anchor_baseline'" "1" "M6b exactly one anchor trigger after re-apply"
expect "select count(*) from pg_constraint where conname in ('e85_price_reports_payment_type_check', 'price_alerts_payment_type_check', 'price_alerts_baseline_check', 'price_alert_deliveries_payment_type_check')" "4" "M6c each new constraint exists exactly once"
expect "select count(*) from private.price_alert_deliveries" "$(sql 'select count(*) from snap.deliveries')" "M6d re-applying created no delivery"

# ---- M7 a delivery that was pending before B is still claimable, unchanged -----------------------------------------
expect "select count(*) from private.claim_price_alert_deliveries_v2(10, 'ios') c where c.delivery_id = '01000000-0000-4000-8000-000000000001' and c.observed_price = 3.19 and c.reason_code = 'price_dropped'" "1" "M7 the pre-existing pending delivery is claimed exactly as prepared"

"${PSQL[@]}" -c "select 1" >/dev/null
dropdb --if-exists "$DB" >/dev/null 2>&1 || true
echo "ALL PAYMENT-TYPE MIGRATION DATA-PRESERVATION SCENARIOS PASSED (M1-M7)"

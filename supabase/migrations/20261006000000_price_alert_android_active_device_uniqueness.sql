-- 85Blends 2.4.1 — Price Alerts: at most ONE active Android device per installation and package.
--
-- NOT APPLIED TO PRODUCTION. Applying it is a separate, explicitly authorized step (see
-- supabase/functions/PRICE_ALERTS_SCHEDULER.md, "Cross-platform reconciliation and deployment plan").
--
-- WHY
--   Production has price_alert_push_devices_one_active_per_install_idx on
--   (installation_id, bundle_id, apns_environment) WHERE enabled AND invalidated_at IS NULL. Android rows
--   have apns_environment = NULL and PostgreSQL treats NULLs as distinct in a unique index, so that index
--   does not constrain Android at all: two concurrent registrations of different FCM tokens for the same
--   installation and package could both leave an active row (price-alerts-api only deactivates the previous
--   token inside its own transaction and cannot see another in-flight registration).
--
-- WHAT
--   A partial unique index on (installation_id, bundle_id) for platform = 'android' rows that are enabled and
--   not invalidated. For Android, bundle_id is the application package name. Disabled/invalidated rows are
--   unrestricted (history is kept), different packages and different installations are independent, and iOS
--   rows are outside the predicate, so iOS behavior and its existing index are untouched.
--
--   price-alerts-api is changed in the same PR to take a row lock on the authenticated installation inside
--   registerDevice's transaction (FOR NO KEY UPDATE), so concurrent registrations for one installation run one
--   after the other and the loser deactivates the winner's token instead of failing on this index. The index is
--   the database-level backstop; the lock makes the race not surface as a unique violation.
--
-- SAFETY
--   * Data is never modified. If any installation already has two active Android rows for one package the
--     migration RAISES (a fixed message with a count, never a token) instead of choosing one to disable.
--     Production has no Price Alert devices today, so the check passes trivially.
--   * Plain CREATE UNIQUE INDEX: a brief lock on a table that is empty in production. IF NOT EXISTS makes a
--     re-run a no-op.
--   * Requires 20261005211547 (the platform columns and constraints).

do $precondition$
declare
  v_duplicates bigint;
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'private' and table_name = 'price_alert_push_devices' and column_name = 'platform'
  ) or not exists (
    select 1 from pg_constraint
    where conrelid = 'private.price_alert_push_devices'::regclass
      and conname = 'price_alert_push_devices_platform_environment_check'
  ) then
    raise exception 'requires migration 20261005211547_price_alerts_cross_platform_push';
  end if;

  select count(*) into v_duplicates
  from (
    select installation_id, bundle_id
    from private.price_alert_push_devices
    where platform = 'android' and enabled and invalidated_at is null
    group by installation_id, bundle_id
    having count(*) > 1
  ) d;

  if v_duplicates > 0 then
    raise exception 'price_alert_android_active_device_uniqueness: % installation/package pair(s) already have more than one active Android device; resolve them explicitly before applying', v_duplicates;
  end if;
end
$precondition$;

create unique index if not exists price_alert_push_devices_one_active_android_per_install_idx
  on private.price_alert_push_devices (installation_id, bundle_id)
  where platform = 'android' and enabled = true and invalidated_at is null;

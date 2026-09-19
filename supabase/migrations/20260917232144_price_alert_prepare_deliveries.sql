-- RECOVERED HISTORICAL MIGRATION
-- Source: retrieved verbatim from supabase_migrations.schema_migrations.statements on the live
-- project (zefkbtscieokkdenvnkg), version 20260917232144, name price_alert_prepare_deliveries, via
-- read-only SQL on 2026-09-19, as part of the 85Blends 2.4.0 migration-history reconciliation
-- audit. Exact SQL text Supabase recorded as applied for this version — not a reconstruction.
-- Confidence: exact. Absent from this repository's git history on every branch before this file.
--
-- Not applied by this recovery — already live; this file only makes local history match remote.

-- 85Blends 2.4.0 — prepare idempotent alert deliveries from one queued price report.
-- This migration does not send APNs notifications and does not schedule any worker.

create or replace function private.prepare_price_alert_deliveries(
  p_price_report_id uuid
)
returns table (
  pending_count integer,
  skipped_count integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_station_id uuid;
  v_observed_price numeric;
  v_reported_at timestamptz;
  v_created_at timestamptz;
  v_previous_price numeric;
  v_pending integer := 0;
  v_skipped integer := 0;
begin
  select r.station_id, r.price, r.reported_at, r.created_at
  into v_station_id, v_observed_price, v_reported_at, v_created_at
  from public.e85_price_reports r
  where r.id = p_price_report_id;

  if v_station_id is null then
    raise exception 'price report not found';
  end if;

  select r.price
  into v_previous_price
  from public.e85_price_reports r
  where r.station_id = v_station_id
    and r.id <> p_price_report_id
    and (
      r.reported_at < v_reported_at
      or (r.reported_at = v_reported_at and r.created_at < v_created_at)
      or (r.reported_at = v_reported_at and r.created_at = v_created_at and r.id < p_price_report_id)
    )
  order by r.reported_at desc, r.created_at desc, r.id desc
  limit 1;

  with candidate_rows as (
    select
      a.id as alert_id,
      d.id as push_device_id,
      e.should_notify,
      e.reason_code
    from private.price_alerts a
    join private.price_alert_installations i
      on i.id = a.installation_id
    join private.revenuecat_customers rc
      on rc.id = i.revenuecat_customer_id
     and rc.pro_is_active = true
     and rc.entitlement_id = 'pro'
    join private.price_alert_push_devices d
      on d.installation_id = a.installation_id
     and d.enabled = true
     and d.invalidated_at is null
    cross join lateral private.evaluate_price_alert(
      a.alert_mode,
      a.threshold_price,
      a.minimum_change,
      a.cooldown_minutes,
      v_observed_price,
      v_previous_price,
      a.last_notified_price,
      a.last_notified_at,
      now()
    ) e
    where a.station_id = v_station_id
      and a.enabled = true
  ), inserted as (
    insert into private.price_alert_deliveries (
      alert_id,
      price_report_id,
      push_device_id,
      observed_price,
      previous_price,
      status,
      reason_code
    )
    select
      c.alert_id,
      p_price_report_id,
      c.push_device_id,
      v_observed_price,
      v_previous_price,
      case when c.should_notify then 'pending' else 'skipped' end,
      c.reason_code
    from candidate_rows c
    on conflict (alert_id, price_report_id, push_device_id) do nothing
    returning status
  )
  select
    count(*) filter (where status = 'pending')::int,
    count(*) filter (where status = 'skipped')::int
  into v_pending, v_skipped
  from inserted;

  return query select coalesce(v_pending, 0), coalesce(v_skipped, 0);
end;
$$;

revoke execute on function private.prepare_price_alert_deliveries(uuid) from public, anon, authenticated;
grant execute on function private.prepare_price_alert_deliveries(uuid) to postgres;

comment on function private.prepare_price_alert_deliveries(uuid) is
  '85Blends 2.4.0 delivery preparation step. Converts one price report into idempotent pending/skipped per-device ledger rows for currently active Pro installations; performs no network I/O.';

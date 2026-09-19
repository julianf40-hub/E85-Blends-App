-- RECOVERED HISTORICAL MIGRATION
-- Source: retrieved verbatim from supabase_migrations.schema_migrations.statements on the live
-- project (zefkbtscieokkdenvnkg), version 20260918001318, name
-- simplify_price_alert_delivery_candidates, via read-only SQL on 2026-09-19, as part of the
-- 85Blends 2.4.0 migration-history reconciliation audit. Exact SQL text Supabase recorded as
-- applied for this version — not a reconstruction. Confidence: exact. Absent from this
-- repository's git history on every branch before this file.
--
-- Supersedes 20260918001235's private.prepare_price_alert_deliveries(uuid): the candidate query
-- drops the join to private.revenuecat_customers (a Pro filter applied per-row inside the loop
-- instead, via an EXISTS check keyed on installation_id) — see this migration's own name.
--
-- Not applied by this recovery — already live; this file only makes local history match remote.

create or replace function private.prepare_price_alert_deliveries(p_price_report_id uuid)
returns table(pending_count integer, skipped_count integer)
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
  v_should_notify boolean;
  v_reason_code text;
  v_inserted_status text;
  v_is_pro boolean;
  v_candidate record;
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

  for v_candidate in
    select
      a.id as alert_id,
      a.installation_id,
      d.id as push_device_id,
      a.alert_mode,
      a.threshold_price,
      a.minimum_change,
      a.cooldown_minutes,
      a.last_notified_price,
      a.last_notified_at
    from private.price_alerts a
    join private.price_alert_push_devices d
      on d.installation_id = a.installation_id
     and d.enabled = true
     and d.invalidated_at is null
    where a.station_id = v_station_id
      and a.enabled = true
  loop
    select exists (
      select 1
      from private.price_alert_installations i
      join private.revenuecat_customers rc on rc.id = i.revenuecat_customer_id
      where i.id = v_candidate.installation_id
        and rc.pro_is_active = true
        and rc.entitlement_id = 'pro'
    ) into v_is_pro;

    if not coalesce(v_is_pro, false) then
      continue;
    end if;

    select e.should_notify, e.reason_code
    into v_should_notify, v_reason_code
    from private.evaluate_price_alert(
      v_candidate.alert_mode,
      v_candidate.threshold_price,
      v_candidate.minimum_change,
      v_candidate.cooldown_minutes,
      v_observed_price,
      v_previous_price,
      v_candidate.last_notified_price,
      v_candidate.last_notified_at,
      now()
    ) e;

    v_inserted_status := null;

    insert into private.price_alert_deliveries (
      alert_id, price_report_id, push_device_id, observed_price, previous_price, status, reason_code
    ) values (
      v_candidate.alert_id,
      p_price_report_id,
      v_candidate.push_device_id,
      v_observed_price,
      v_previous_price,
      case when v_should_notify then 'pending' else 'skipped' end,
      v_reason_code
    )
    on conflict (alert_id, price_report_id, push_device_id) do nothing
    returning status into v_inserted_status;

    if v_inserted_status = 'pending' then
      v_pending := v_pending + 1;
    elsif v_inserted_status = 'skipped' then
      v_skipped := v_skipped + 1;
    end if;
  end loop;

  return query select v_pending, v_skipped;
end;
$$;

revoke execute on function private.prepare_price_alert_deliveries(uuid) from public, anon, authenticated;
grant execute on function private.prepare_price_alert_deliveries(uuid) to postgres, service_role;

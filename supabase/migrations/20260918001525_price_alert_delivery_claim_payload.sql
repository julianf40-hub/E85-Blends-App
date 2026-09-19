-- RECOVERED HISTORICAL MIGRATION
-- Source: retrieved verbatim from supabase_migrations.schema_migrations.statements on the live
-- project (zefkbtscieokkdenvnkg), version 20260918001525, name price_alert_delivery_claim_payload,
-- via read-only SQL on 2026-09-19, as part of the 85Blends 2.4.0 migration-history reconciliation
-- audit. Exact SQL text Supabase recorded as applied for this version — not a reconstruction.
-- Confidence: exact. Absent from this repository's git history on every branch before this file.
--
-- Drops and recreates private.claim_price_alert_deliveries(integer) (previously defined by
-- 20260918000854) to add station_id/station_name to its returned payload, joining
-- public.e85_price_reports/public.community_stations.
--
-- Not applied by this recovery — already live; this file only makes local history match remote.

drop function if exists private.claim_price_alert_deliveries(integer);

create function private.claim_price_alert_deliveries(p_limit integer default 50)
returns table(
  delivery_id uuid,
  alert_id uuid,
  price_report_id uuid,
  push_device_id uuid,
  station_id uuid,
  station_name text,
  device_token text,
  apns_environment text,
  bundle_id text,
  observed_price numeric,
  previous_price numeric,
  reason_code text,
  attempt_count integer
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'p_limit must be between 1 and 100';
  end if;

  return query
  with candidates as (
    select d.id
    from private.price_alert_deliveries d
    where (
      d.status in ('pending','failed')
      and d.available_at <= now()
    ) or (
      d.status = 'processing'
      and d.locked_at < now() - interval '15 minutes'
    )
    order by d.available_at asc, d.created_at asc
    for update skip locked
    limit p_limit
  ), claimed as (
    update private.price_alert_deliveries d
    set status = 'processing',
        attempt_count = d.attempt_count + 1,
        attempted_at = now(),
        locked_at = now(),
        last_error_code = null
    from candidates c
    where d.id = c.id
    returning d.*
  )
  select
    c.id,
    c.alert_id,
    c.price_report_id,
    c.push_device_id,
    r.station_id,
    s.name,
    pd.device_token,
    pd.apns_environment,
    pd.bundle_id,
    c.observed_price,
    c.previous_price,
    c.reason_code,
    c.attempt_count
  from claimed c
  join private.price_alert_push_devices pd on pd.id = c.push_device_id
  join public.e85_price_reports r on r.id = c.price_report_id
  join public.community_stations s on s.id = r.station_id
  where pd.enabled = true and pd.invalidated_at is null;
end;
$$;

revoke execute on function private.claim_price_alert_deliveries(integer) from public, anon, authenticated;
grant execute on function private.claim_price_alert_deliveries(integer) to postgres, service_role;

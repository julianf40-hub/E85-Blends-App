alter table private.price_alert_installations
  add column client_platform text not null default 'ios';

alter table private.price_alert_installations
  add constraint price_alert_installations_client_platform_check
  check (client_platform in ('ios','android'));

alter table private.price_alert_push_devices
  alter column apns_environment drop not null;

alter table private.price_alert_push_devices
  drop constraint price_alert_push_devices_platform_check;

alter table private.price_alert_push_devices
  add constraint price_alert_push_devices_platform_check
  check (platform in ('ios','android'));

alter table private.price_alert_push_devices
  drop constraint price_alert_push_devices_apns_environment_check;

alter table private.price_alert_push_devices
  add constraint price_alert_push_devices_platform_environment_check
  check (
    (platform = 'ios' and apns_environment in ('sandbox','production'))
    or
    (platform = 'android' and apns_environment is null)
  );

create unique index price_alert_push_devices_android_token_key
  on private.price_alert_push_devices (bundle_id, device_token_hash)
  where platform = 'android';

create or replace function private.claim_price_alert_deliveries_v2(
  p_limit integer default 50,
  p_platform text default 'ios'
)
returns table(
  delivery_id uuid,
  alert_id uuid,
  price_report_id uuid,
  push_device_id uuid,
  platform text,
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

  if p_platform not in ('ios','android') then
    raise exception 'p_platform must be ios or android';
  end if;

  return query
  with candidates as (
    select d.id
    from private.price_alert_deliveries d
    join private.price_alert_push_devices pd on pd.id = d.push_device_id
    where pd.platform = p_platform
      and pd.enabled = true
      and pd.invalidated_at is null
      and (
        (d.status in ('pending','failed') and d.available_at <= now())
        or
        (d.status = 'processing' and d.locked_at < now() - interval '15 minutes')
      )
    order by d.available_at asc, d.created_at asc
    for update of d skip locked
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
    pd.platform,
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
  where pd.enabled = true
    and pd.invalidated_at is null
    and pd.platform = p_platform;
end;
$$;

revoke all on function private.claim_price_alert_deliveries_v2(integer,text) from public;
revoke all on function private.claim_price_alert_deliveries_v2(integer,text) from anon;
revoke all on function private.claim_price_alert_deliveries_v2(integer,text) from authenticated;

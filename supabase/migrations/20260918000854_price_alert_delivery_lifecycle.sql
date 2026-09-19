-- RECOVERED HISTORICAL MIGRATION
-- Source: retrieved verbatim from supabase_migrations.schema_migrations.statements on the live
-- project (zefkbtscieokkdenvnkg), version 20260918000854, name price_alert_delivery_lifecycle, via
-- read-only SQL on 2026-09-19, as part of the 85Blends 2.4.0 migration-history reconciliation
-- audit. Exact SQL text Supabase recorded as applied for this version — not a reconstruction.
-- Confidence: exact. Absent from this repository's git history on every branch before this file.
--
-- Not applied by this recovery — already live; this file only makes local history match remote.

alter table private.price_alert_deliveries
  add column if not exists available_at timestamptz not null default now(),
  add column if not exists locked_at timestamptz,
  add column if not exists last_error_code text;

alter table private.price_alert_deliveries
  drop constraint if exists price_alert_deliveries_status_check;

alter table private.price_alert_deliveries
  add constraint price_alert_deliveries_status_check
  check (status in ('pending','processing','sent','skipped','failed','invalid_device','dead'));

alter table private.price_alert_deliveries
  drop constraint if exists price_alert_deliveries_last_error_code_check;

alter table private.price_alert_deliveries
  add constraint price_alert_deliveries_last_error_code_check
  check (last_error_code is null or char_length(last_error_code) between 1 and 128);

drop index if exists private.price_alert_deliveries_retry_idx;
create index price_alert_deliveries_retry_idx
  on private.price_alert_deliveries (available_at, created_at)
  where status in ('pending','failed');

create or replace function private.finalize_price_alert_job(p_price_report_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job_id uuid;
  v_has_active boolean;
begin
  select j.id into v_job_id
  from private.price_alert_jobs j
  where j.price_report_id = p_price_report_id
  for update;

  if v_job_id is null then
    return false;
  end if;

  select exists (
    select 1
    from private.price_alert_deliveries d
    where d.price_report_id = p_price_report_id
      and d.status in ('pending','processing','failed')
  ) into v_has_active;

  if v_has_active then
    return false;
  end if;

  update private.price_alert_jobs
  set status = 'completed',
      processed_at = coalesce(processed_at, now()),
      locked_at = null,
      last_error = null
  where id = v_job_id;

  return true;
end;
$$;

create or replace function private.claim_price_alert_deliveries(p_limit integer default 50)
returns table(
  delivery_id uuid,
  alert_id uuid,
  price_report_id uuid,
  push_device_id uuid,
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
    pd.device_token,
    pd.apns_environment,
    pd.bundle_id,
    c.observed_price,
    c.previous_price,
    c.reason_code,
    c.attempt_count
  from claimed c
  join private.price_alert_push_devices pd on pd.id = c.push_device_id
  where pd.enabled = true and pd.invalidated_at is null;
end;
$$;

create or replace function private.mark_price_alert_delivery_sent(
  p_delivery_id uuid,
  p_provider_status integer default 200
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_delivery private.price_alert_deliveries%rowtype;
begin
  select * into v_delivery
  from private.price_alert_deliveries
  where id = p_delivery_id
  for update;

  if v_delivery.id is null then
    return false;
  end if;

  if v_delivery.status = 'sent' then
    return true;
  end if;

  if v_delivery.status <> 'processing' then
    return false;
  end if;

  update private.price_alert_deliveries
  set status = 'sent',
      provider_status = p_provider_status,
      sent_at = now(),
      locked_at = null,
      last_error_code = null
  where id = p_delivery_id;

  update private.price_alert_push_devices
  set last_success_at = now(),
      last_failure_at = null,
      failure_count = 0
  where id = v_delivery.push_device_id;

  update private.price_alerts
  set last_notified_price = v_delivery.observed_price,
      last_notified_at = now()
  where id = v_delivery.alert_id;

  perform private.finalize_price_alert_job(v_delivery.price_report_id);
  return true;
end;
$$;

create or replace function private.mark_price_alert_delivery_failed(
  p_delivery_id uuid,
  p_provider_status integer default null,
  p_error_code text default 'delivery_failed',
  p_retryable boolean default true,
  p_invalidate_device boolean default false,
  p_max_attempts integer default 5
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_delivery private.price_alert_deliveries%rowtype;
  v_status text;
  v_delay interval;
  v_error text := left(coalesce(nullif(btrim(p_error_code), ''), 'delivery_failed'), 128);
begin
  if p_max_attempts < 1 or p_max_attempts > 20 then
    raise exception 'p_max_attempts must be between 1 and 20';
  end if;

  select * into v_delivery
  from private.price_alert_deliveries
  where id = p_delivery_id
  for update;

  if v_delivery.id is null then
    return 'not_found';
  end if;

  if v_delivery.status in ('sent','skipped','invalid_device','dead') then
    return v_delivery.status;
  end if;

  if p_invalidate_device then
    v_status := 'invalid_device';
  elsif p_retryable and v_delivery.attempt_count < p_max_attempts then
    v_status := 'failed';
  else
    v_status := 'dead';
  end if;

  v_delay := case
    when v_delivery.attempt_count <= 1 then interval '1 minute'
    when v_delivery.attempt_count = 2 then interval '5 minutes'
    when v_delivery.attempt_count = 3 then interval '15 minutes'
    when v_delivery.attempt_count = 4 then interval '1 hour'
    else interval '4 hours'
  end;

  update private.price_alert_deliveries
  set status = v_status,
      provider_status = p_provider_status,
      last_error_code = v_error,
      locked_at = null,
      available_at = case when v_status = 'failed' then now() + v_delay else available_at end
  where id = p_delivery_id;

  update private.price_alert_push_devices
  set last_failure_at = now(),
      failure_count = failure_count + 1,
      enabled = case when p_invalidate_device then false else enabled end,
      invalidated_at = case when p_invalidate_device then coalesce(invalidated_at, now()) else invalidated_at end
  where id = v_delivery.push_device_id;

  perform private.finalize_price_alert_job(v_delivery.price_report_id);
  return v_status;
end;
$$;

create or replace function private.mark_price_alert_job_failed(
  p_job_id uuid,
  p_error text,
  p_retryable boolean default true,
  p_max_attempts integer default 5
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job private.price_alert_jobs%rowtype;
  v_status text;
  v_delay interval;
begin
  if p_max_attempts < 1 or p_max_attempts > 20 then
    raise exception 'p_max_attempts must be between 1 and 20';
  end if;

  select * into v_job
  from private.price_alert_jobs
  where id = p_job_id
  for update;

  if v_job.id is null then
    return 'not_found';
  end if;

  if v_job.status in ('completed','dead') then
    return v_job.status;
  end if;

  if p_retryable and v_job.attempt_count < p_max_attempts then
    v_status := 'failed';
  else
    v_status := 'dead';
  end if;

  v_delay := case
    when v_job.attempt_count <= 1 then interval '1 minute'
    when v_job.attempt_count = 2 then interval '5 minutes'
    when v_job.attempt_count = 3 then interval '15 minutes'
    when v_job.attempt_count = 4 then interval '1 hour'
    else interval '4 hours'
  end;

  update private.price_alert_jobs
  set status = v_status,
      available_at = case when v_status = 'failed' then now() + v_delay else available_at end,
      locked_at = null,
      last_error = left(coalesce(nullif(btrim(p_error), ''), 'job_failed'), 500),
      processed_at = case when v_status = 'dead' then now() else processed_at end
  where id = p_job_id;

  return v_status;
end;
$$;

revoke execute on function private.finalize_price_alert_job(uuid) from public, anon, authenticated;
revoke execute on function private.claim_price_alert_deliveries(integer) from public, anon, authenticated;
revoke execute on function private.mark_price_alert_delivery_sent(uuid, integer) from public, anon, authenticated;
revoke execute on function private.mark_price_alert_delivery_failed(uuid, integer, text, boolean, boolean, integer) from public, anon, authenticated;
revoke execute on function private.mark_price_alert_job_failed(uuid, text, boolean, integer) from public, anon, authenticated;

grant execute on function private.finalize_price_alert_job(uuid) to postgres, service_role;
grant execute on function private.claim_price_alert_deliveries(integer) to postgres, service_role;
grant execute on function private.mark_price_alert_delivery_sent(uuid, integer) to postgres, service_role;
grant execute on function private.mark_price_alert_delivery_failed(uuid, integer, text, boolean, boolean, integer) to postgres, service_role;
grant execute on function private.mark_price_alert_job_failed(uuid, text, boolean, integer) to postgres, service_role;

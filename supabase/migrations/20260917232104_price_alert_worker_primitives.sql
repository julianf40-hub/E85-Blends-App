-- RECOVERED HISTORICAL MIGRATION
-- Source: retrieved verbatim from supabase_migrations.schema_migrations.statements on the live
-- project (zefkbtscieokkdenvnkg), version 20260917232104, name price_alert_worker_primitives, via
-- read-only SQL on 2026-09-19, as part of the 85Blends 2.4.0 migration-history reconciliation
-- audit. Exact SQL text Supabase recorded as applied for this version — not a reconstruction.
-- Confidence: exact. Absent from this repository's git history on every branch before this file.
--
-- Not applied by this recovery — already live; this file only makes local history match remote.

-- 85Blends 2.4.0 — server-side price-alert worker primitives.
-- No network I/O, no scheduling, and no APNs delivery is enabled by this migration.

create or replace function private.evaluate_price_alert(
  p_alert_mode text,
  p_threshold_price numeric,
  p_minimum_change numeric,
  p_cooldown_minutes integer,
  p_observed_price numeric,
  p_previous_price numeric,
  p_last_notified_price numeric,
  p_last_notified_at timestamptz,
  p_now timestamptz default now()
)
returns table (
  should_notify boolean,
  reason_code text
)
language plpgsql
set search_path = ''
as $$
declare
  v_should_notify boolean := false;
  v_reason text := 'not_eligible';
  v_min_change numeric := greatest(coalesce(p_minimum_change, 0.05), 0.01);
  v_cooldown_active boolean := false;
begin
  if p_observed_price is null or p_observed_price < 1.00 or p_observed_price > 8.00 then
    return query select false, 'invalid_observed_price'::text;
    return;
  end if;

  if p_cooldown_minutes is null or p_cooldown_minutes < 0 then
    return query select false, 'invalid_cooldown'::text;
    return;
  end if;

  v_cooldown_active := p_last_notified_at is not null
    and p_now < p_last_notified_at + make_interval(mins => p_cooldown_minutes);

  case p_alert_mode
    when 'any_change' then
      if p_previous_price is null then
        v_reason := 'no_baseline';
      elsif abs(p_observed_price - p_previous_price) < v_min_change then
        v_reason := 'change_below_minimum';
      else
        v_should_notify := true;
        v_reason := 'price_changed';
      end if;

    when 'price_drop' then
      if p_previous_price is null then
        v_reason := 'no_baseline';
      elsif (p_previous_price - p_observed_price) < v_min_change then
        v_reason := 'no_meaningful_drop';
      else
        v_should_notify := true;
        v_reason := 'price_dropped';
      end if;

    when 'at_or_below' then
      if p_threshold_price is null or p_threshold_price < 1.00 or p_threshold_price > 8.00 then
        v_reason := 'invalid_threshold';
      elsif p_observed_price > p_threshold_price then
        v_reason := 'above_threshold';
      elsif p_previous_price is not null and p_previous_price > p_threshold_price then
        v_should_notify := true;
        v_reason := 'threshold_crossed';
      elsif p_last_notified_price is null then
        v_should_notify := true;
        v_reason := 'threshold_met';
      elsif abs(p_observed_price - p_last_notified_price) >= v_min_change then
        v_should_notify := true;
        v_reason := 'threshold_price_changed';
      else
        v_reason := 'threshold_unchanged';
      end if;

    else
      v_reason := 'invalid_mode';
  end case;

  if v_should_notify and v_cooldown_active then
    return query select false, 'cooldown'::text;
    return;
  end if;

  return query select v_should_notify, v_reason;
end;
$$;

revoke execute on function private.evaluate_price_alert(
  text, numeric, numeric, integer, numeric, numeric, numeric, timestamptz, timestamptz
) from public, anon, authenticated;
grant execute on function private.evaluate_price_alert(
  text, numeric, numeric, integer, numeric, numeric, numeric, timestamptz, timestamptz
) to postgres;

create or replace function private.claim_price_alert_jobs(
  p_limit integer default 20
)
returns table (
  job_id uuid,
  price_report_id uuid,
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
    select j.id
    from private.price_alert_jobs j
    where j.status in ('pending', 'failed')
      and j.available_at <= now()
    order by j.available_at asc, j.created_at asc
    for update skip locked
    limit p_limit
  )
  update private.price_alert_jobs j
  set status = 'processing',
      attempt_count = j.attempt_count + 1,
      locked_at = now(),
      last_error = null
  from candidates c
  where j.id = c.id
  returning j.id, j.price_report_id, j.attempt_count;
end;
$$;

revoke execute on function private.claim_price_alert_jobs(integer) from public, anon, authenticated;
grant execute on function private.claim_price_alert_jobs(integer) to postgres;

comment on function private.evaluate_price_alert(
  text, numeric, numeric, integer, numeric, numeric, numeric, timestamptz, timestamptz
) is '85Blends 2.4.0 deterministic price-alert decision engine. Applies mode semantics, minimum change, threshold crossing, and cooldown without network I/O.';
comment on function private.claim_price_alert_jobs(integer) is '85Blends 2.4.0 atomic outbox claim helper for a future APNs worker. Uses FOR UPDATE SKIP LOCKED and increments attempt_count when claimed.';

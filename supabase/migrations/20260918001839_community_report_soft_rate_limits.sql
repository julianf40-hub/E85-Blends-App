-- RECOVERED HISTORICAL MIGRATION
-- Source: retrieved verbatim from supabase_migrations.schema_migrations.statements on the live
-- project (zefkbtscieokkdenvnkg), version 20260918001839, name community_report_soft_rate_limits,
-- via read-only SQL on 2026-09-19, as part of the 85Blends 2.4.0 migration-history reconciliation
-- audit. Exact SQL text Supabase recorded as applied for this version — not a reconstruction.
-- Confidence: exact. Absent from this repository's git history on every branch before this file.
--
-- Not applied by this recovery — already live; this file only makes local history match remote.
-- See 20260918001857 immediately after this one — it replaces this migration's session_user/role
-- bypass check for both trigger functions.

create index if not exists e85_price_reports_reporter_created_idx
  on public.e85_price_reports (anonymous_reporter_id, created_at desc);
create index if not exists e85_price_reports_reporter_station_created_idx
  on public.e85_price_reports (anonymous_reporter_id, station_id, created_at desc);
create index if not exists e85_ethanol_reports_reporter_created_idx
  on public.e85_ethanol_reports (anonymous_reporter_id, created_at desc);
create index if not exists e85_ethanol_reports_reporter_station_created_idx
  on public.e85_ethanol_reports (anonymous_reporter_id, station_id, created_at desc);

create or replace function private.enforce_price_report_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text := current_setting('request.jwt.claim.role', true);
  v_total integer;
  v_station integer;
begin
  if session_user = 'postgres' or v_role = 'service_role' then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtext('price:' || new.anonymous_reporter_id));

  select count(*)::int into v_total
  from public.e85_price_reports
  where anonymous_reporter_id = new.anonymous_reporter_id
    and created_at >= now() - interval '1 hour';

  if v_total >= 30 then
    raise exception 'community price report rate limit exceeded';
  end if;

  select count(*)::int into v_station
  from public.e85_price_reports
  where anonymous_reporter_id = new.anonymous_reporter_id
    and station_id = new.station_id
    and created_at >= now() - interval '1 hour';

  if v_station >= 12 then
    raise exception 'community price station rate limit exceeded';
  end if;

  return new;
end;
$$;

create or replace function private.enforce_ethanol_report_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text := current_setting('request.jwt.claim.role', true);
  v_total integer;
  v_station integer;
begin
  if session_user = 'postgres' or v_role = 'service_role' then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtext('ethanol:' || new.anonymous_reporter_id));

  select count(*)::int into v_total
  from public.e85_ethanol_reports
  where anonymous_reporter_id = new.anonymous_reporter_id
    and created_at >= now() - interval '1 hour';

  if v_total >= 30 then
    raise exception 'community ethanol report rate limit exceeded';
  end if;

  select count(*)::int into v_station
  from public.e85_ethanol_reports
  where anonymous_reporter_id = new.anonymous_reporter_id
    and station_id = new.station_id
    and created_at >= now() - interval '1 hour';

  if v_station >= 12 then
    raise exception 'community ethanol station rate limit exceeded';
  end if;

  return new;
end;
$$;

drop trigger if exists e85_price_reports_rate_limit on public.e85_price_reports;
create trigger e85_price_reports_rate_limit
  before insert on public.e85_price_reports
  for each row execute function private.enforce_price_report_rate_limit();

drop trigger if exists e85_ethanol_reports_rate_limit on public.e85_ethanol_reports;
create trigger e85_ethanol_reports_rate_limit
  before insert on public.e85_ethanol_reports
  for each row execute function private.enforce_ethanol_report_rate_limit();

revoke execute on function private.enforce_price_report_rate_limit() from public, anon, authenticated;
revoke execute on function private.enforce_ethanol_report_rate_limit() from public, anon, authenticated;
grant execute on function private.enforce_price_report_rate_limit() to postgres, service_role;
grant execute on function private.enforce_ethanol_report_rate_limit() to postgres, service_role;

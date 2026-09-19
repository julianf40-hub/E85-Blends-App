-- RECOVERED HISTORICAL MIGRATION
-- Source: retrieved verbatim from supabase_migrations.schema_migrations.statements on the live
-- project (zefkbtscieokkdenvnkg), version 20260918001857, name
-- community_report_rate_limit_role_fix, via read-only SQL on 2026-09-19, as part of the 85Blends
-- 2.4.0 migration-history reconciliation audit. Exact SQL text Supabase recorded as applied for
-- this version — not a reconstruction. Confidence: exact. Absent from this repository's git
-- history on every branch before this file.
--
-- Fixes 20260918001839's bypass condition on both rate-limit trigger functions: the previous
-- `session_user = 'postgres' or v_role = 'service_role'` could bypass the rate limit for the
-- `postgres` role regardless of the request's actual JWT role claim. Tightened to
-- `v_role = 'service_role' or (session_user = 'postgres' and coalesce(v_role, '') = '')` — the
-- postgres-role bypass now only applies when there is no JWT role claim at all (a direct
-- superuser/SQL-console session), not merely whenever session_user happens to be postgres under a
-- PostgREST/Data-API connection that does carry a caller role claim.
--
-- Not applied by this recovery — already live; this file only makes local history match remote.

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
  if v_role = 'service_role' or (session_user = 'postgres' and coalesce(v_role, '') = '') then
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
  if v_role = 'service_role' or (session_user = 'postgres' and coalesce(v_role, '') = '') then
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

revoke execute on function private.enforce_price_report_rate_limit() from public, anon, authenticated;
revoke execute on function private.enforce_ethanol_report_rate_limit() from public, anon, authenticated;
grant execute on function private.enforce_price_report_rate_limit() to postgres, service_role;
grant execute on function private.enforce_ethanol_report_rate_limit() to postgres, service_role;

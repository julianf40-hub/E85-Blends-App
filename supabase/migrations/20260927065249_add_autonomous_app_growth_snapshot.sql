create schema if not exists private;

create table if not exists public.app_growth_snapshot (
  snapshot_key text primary key,
  metric_source text not null,
  current_value bigint not null,
  target_value bigint not null,
  headline text not null,
  detail text,
  enabled boolean not null default true,
  source_updated_at timestamptz,
  computed_at timestamptz not null default now(),
  constraint app_growth_snapshot_singleton check (snapshot_key = 'primary'),
  constraint app_growth_snapshot_source check (metric_source in ('community_reports', 'app_store_downloads')),
  constraint app_growth_snapshot_current_nonnegative check (current_value >= 0),
  constraint app_growth_snapshot_target_positive check (target_value > 0),
  constraint app_growth_snapshot_target_ahead check (target_value > current_value)
);

alter table public.app_growth_snapshot enable row level security;

revoke all on table public.app_growth_snapshot from public, anon, authenticated;
grant select on table public.app_growth_snapshot to anon, authenticated;
grant select, insert, update, delete on table public.app_growth_snapshot to service_role;

drop policy if exists "Growth snapshot is publicly readable when enabled" on public.app_growth_snapshot;
create policy "Growth snapshot is publicly readable when enabled"
on public.app_growth_snapshot
for select
to anon, authenticated
using (enabled = true);

create or replace function private.next_growth_target(p_value bigint)
returns bigint
language sql
immutable
set search_path = ''
as $function$
  select case
    when p_value < 25 then 25
    when p_value < 50 then 50
    when p_value < 100 then 100
    when p_value < 250 then 250
    when p_value < 500 then 500
    when p_value < 1000 then 1000
    when p_value < 2500 then 2500
    when p_value < 5000 then 5000
    else ((p_value / 5000) + 1) * 5000
  end;
$function$;

revoke all on function private.next_growth_target(bigint) from public, anon, authenticated;
grant execute on function private.next_growth_target(bigint) to service_role;

create or replace function private.refresh_growth_snapshot_from_community()
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  report_count bigint;
  latest_report timestamptz;
  next_target bigint;
  existing_source text;
begin
  select metric_source
    into existing_source
  from public.app_growth_snapshot
  where snapshot_key = 'primary';

  -- Once the Apple download source has taken ownership, the temporary community
  -- fallback must never overwrite it.
  if existing_source = 'app_store_downloads' then
    return;
  end if;

  select count(*)::bigint, max(reported_at)
    into report_count, latest_report
  from (
    select reported_at from public.e85_price_reports
    union all
    select reported_at from public.e85_ethanol_reports
  ) reports;

  next_target := private.next_growth_target(report_count);

  insert into public.app_growth_snapshot (
    snapshot_key,
    metric_source,
    current_value,
    target_value,
    headline,
    detail,
    enabled,
    source_updated_at,
    computed_at
  ) values (
    'primary',
    'community_reports',
    report_count,
    next_target,
    case
      when report_count = 1 then '1 community report'
      else report_count::text || ' community reports'
    end,
    'Help us reach ' || next_target::text,
    report_count > 0,
    latest_report,
    now()
  )
  on conflict (snapshot_key) do update
  set metric_source = excluded.metric_source,
      current_value = excluded.current_value,
      target_value = excluded.target_value,
      headline = excluded.headline,
      detail = excluded.detail,
      enabled = excluded.enabled,
      source_updated_at = excluded.source_updated_at,
      computed_at = excluded.computed_at
  where public.app_growth_snapshot.metric_source <> 'app_store_downloads';
end;
$function$;

revoke all on function private.refresh_growth_snapshot_from_community() from public, anon, authenticated;
grant execute on function private.refresh_growth_snapshot_from_community() to service_role;

select private.refresh_growth_snapshot_from_community();

select cron.schedule(
  'refresh-85blends-growth-snapshot',
  '*/5 * * * *',
  'select private.refresh_growth_snapshot_from_community();'
);

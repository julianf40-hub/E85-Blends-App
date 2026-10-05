create or replace function private.refresh_growth_snapshot_after_community_report()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  perform private.refresh_growth_snapshot_from_community();
  return null;
end;
$function$;

revoke all on function private.refresh_growth_snapshot_after_community_report() from public, anon, authenticated;
grant execute on function private.refresh_growth_snapshot_after_community_report() to service_role;

drop trigger if exists refresh_growth_snapshot_after_price_report on public.e85_price_reports;
create trigger refresh_growth_snapshot_after_price_report
after insert on public.e85_price_reports
for each statement
execute function private.refresh_growth_snapshot_after_community_report();

drop trigger if exists refresh_growth_snapshot_after_ethanol_report on public.e85_ethanol_reports;
create trigger refresh_growth_snapshot_after_ethanol_report
after insert on public.e85_ethanol_reports
for each statement
execute function private.refresh_growth_snapshot_after_community_report();

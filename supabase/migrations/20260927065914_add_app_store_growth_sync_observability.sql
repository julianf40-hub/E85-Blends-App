create or replace function private.mark_app_store_growth_sync_state(
  p_status text,
  p_error text default null,
  p_total_downloads bigint default null,
  p_success boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  insert into private.app_store_growth_sync_state (
    sync_key,
    last_status,
    last_attempt_at,
    last_success_at,
    last_error,
    last_total_downloads,
    updated_at
  ) values (
    'primary',
    left(coalesce(p_status, 'unknown'), 64),
    now(),
    case when p_success then now() else null end,
    case when p_error is null then null else left(p_error, 1000) end,
    p_total_downloads,
    now()
  )
  on conflict (sync_key) do update
  set last_status = excluded.last_status,
      last_attempt_at = excluded.last_attempt_at,
      last_success_at = case
        when p_success then excluded.last_attempt_at
        else private.app_store_growth_sync_state.last_success_at
      end,
      last_error = excluded.last_error,
      last_total_downloads = coalesce(excluded.last_total_downloads, private.app_store_growth_sync_state.last_total_downloads),
      updated_at = excluded.updated_at;
end;
$function$;

revoke all on function private.mark_app_store_growth_sync_state(text, text, bigint, boolean) from public, anon, authenticated;
grant execute on function private.mark_app_store_growth_sync_state(text, text, bigint, boolean) to service_role;

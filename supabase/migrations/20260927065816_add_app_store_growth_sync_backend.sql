create extension if not exists pg_net with schema extensions;

create table if not exists private.app_store_download_daily (
  download_date date primary key,
  processing_date date not null,
  download_count bigint not null check (download_count >= 0),
  updated_at timestamptz not null default now()
);

revoke all on table private.app_store_download_daily from public, anon, authenticated;
grant select, insert, update, delete on table private.app_store_download_daily to service_role;

create table if not exists private.app_store_growth_sync_state (
  sync_key text primary key,
  last_status text not null default 'not_configured',
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  last_error text,
  last_total_downloads bigint,
  updated_at timestamptz not null default now(),
  constraint app_store_growth_sync_state_singleton check (sync_key = 'primary'),
  constraint app_store_growth_sync_state_total_nonnegative check (last_total_downloads is null or last_total_downloads >= 0)
);

revoke all on table private.app_store_growth_sync_state from public, anon, authenticated;
grant select, insert, update, delete on table private.app_store_growth_sync_state to service_role;

insert into private.app_store_growth_sync_state (sync_key)
values ('primary')
on conflict (sync_key) do nothing;

create or replace function private.refresh_growth_snapshot_from_app_store()
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  total_downloads bigint;
  latest_download_date date;
  next_target bigint;
begin
  select coalesce(sum(download_count), 0)::bigint, max(download_date)
    into total_downloads, latest_download_date
  from private.app_store_download_daily;

  if total_downloads <= 0 then
    return total_downloads;
  end if;

  next_target := private.next_growth_target(total_downloads);

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
    'app_store_downloads',
    total_downloads,
    next_target,
    total_downloads::text || ' downloads',
    'Road to ' || next_target::text,
    true,
    latest_download_date::timestamptz,
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
      computed_at = excluded.computed_at;

  return total_downloads;
end;
$function$;

revoke all on function private.refresh_growth_snapshot_from_app_store() from public, anon, authenticated;
grant execute on function private.refresh_growth_snapshot_from_app_store() to service_role;

do $block$
begin
  if not exists (select 1 from vault.secrets where name = 'project_url') then
    perform vault.create_secret(
      'https://zefkbtscieokkdenvnkg.supabase.co',
      'project_url',
      '85Blends production Supabase project URL for scheduled Edge Function invocation'
    );
  end if;

  if not exists (select 1 from vault.secrets where name = 'app_store_growth_sync_cron_token') then
    perform vault.create_secret(
      gen_random_uuid()::text || gen_random_uuid()::text,
      'app_store_growth_sync_cron_token',
      'Private authentication token for the scheduled 85Blends App Store growth sync'
    );
  end if;
end;
$block$;

create or replace function private.invoke_app_store_growth_sync()
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  project_url text;
  cron_token text;
  request_id bigint;
begin
  select decrypted_secret
    into project_url
  from vault.decrypted_secrets
  where name = 'project_url'
  limit 1;

  select decrypted_secret
    into cron_token
  from vault.decrypted_secrets
  where name = 'app_store_growth_sync_cron_token'
  limit 1;

  if project_url is null or cron_token is null then
    raise exception 'app_store_growth_sync_scheduler_not_configured';
  end if;

  select net.http_post(
    url := project_url || '/functions/v1/app-store-growth-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-85blends-cron-secret', cron_token
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  ) into request_id;

  return request_id;
end;
$function$;

revoke all on function private.invoke_app_store_growth_sync() from public, anon, authenticated;
grant execute on function private.invoke_app_store_growth_sync() to service_role;

select cron.schedule(
  'sync-85blends-app-store-growth',
  '15 12 * * *',
  'select private.invoke_app_store_growth_sync();'
);

select cron.alter_job(
  job_id := (select jobid from cron.job where jobname = 'sync-85blends-app-store-growth'),
  active := false
);

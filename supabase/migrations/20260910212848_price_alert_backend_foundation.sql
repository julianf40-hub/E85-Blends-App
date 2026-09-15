-- 85Blends 2.4.0 — Station Price Alert backend foundation.
-- Internal state stays in the private schema and is only intended to be reached
-- through server-side Edge Functions / direct Postgres connections.

create table private.price_alert_installations (
  id uuid primary key default gen_random_uuid(),
  client_installation_id uuid not null unique,
  installation_secret_hash text not null,
  contributor_id uuid,
  revenuecat_app_user_id text,
  revenuecat_environment text,
  revenuecat_customer_id uuid references private.revenuecat_customers(id) on delete set null,
  app_version text,
  last_seen_at timestamptz not null default now(),
  last_pro_check_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint price_alert_installations_secret_hash_check
    check (installation_secret_hash ~ '^[0-9a-f]{64}$'),
  constraint price_alert_installations_rc_environment_check
    check (revenuecat_environment is null or revenuecat_environment in ('SANDBOX','PRODUCTION')),
  constraint price_alert_installations_rc_identity_pair_check
    check (
      (revenuecat_app_user_id is null and revenuecat_environment is null)
      or
      (revenuecat_app_user_id is not null and length(btrim(revenuecat_app_user_id)) > 0 and revenuecat_environment is not null)
    )
);

create index price_alert_installations_contributor_idx
  on private.price_alert_installations (contributor_id)
  where contributor_id is not null;

create index price_alert_installations_revenuecat_customer_idx
  on private.price_alert_installations (revenuecat_customer_id)
  where revenuecat_customer_id is not null;

create index price_alert_installations_revenuecat_identity_idx
  on private.price_alert_installations (revenuecat_app_user_id, revenuecat_environment)
  where revenuecat_app_user_id is not null;

create table private.price_alert_push_devices (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null references private.price_alert_installations(id) on delete cascade,
  platform text not null default 'ios',
  bundle_id text not null,
  apns_environment text not null,
  device_token text not null,
  device_token_hash text not null,
  enabled boolean not null default true,
  last_registered_at timestamptz not null default now(),
  last_success_at timestamptz,
  last_failure_at timestamptz,
  failure_count integer not null default 0,
  invalidated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint price_alert_push_devices_platform_check
    check (platform = 'ios'),
  constraint price_alert_push_devices_bundle_id_check
    check (length(btrim(bundle_id)) between 3 and 255),
  constraint price_alert_push_devices_apns_environment_check
    check (apns_environment in ('sandbox','production')),
  constraint price_alert_push_devices_token_check
    check (length(btrim(device_token)) between 16 and 1024),
  constraint price_alert_push_devices_token_hash_check
    check (device_token_hash ~ '^[0-9a-f]{64}$'),
  constraint price_alert_push_devices_failure_count_check
    check (failure_count >= 0),
  unique (bundle_id, apns_environment, device_token_hash)
);

create unique index price_alert_push_devices_one_active_per_install_idx
  on private.price_alert_push_devices (installation_id, bundle_id, apns_environment)
  where enabled = true and invalidated_at is null;

create index price_alert_push_devices_installation_idx
  on private.price_alert_push_devices (installation_id, enabled, invalidated_at);

create table private.price_alerts (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null references private.price_alert_installations(id) on delete cascade,
  station_id uuid not null references public.community_stations(id) on delete cascade,
  alert_mode text not null default 'price_drop',
  threshold_price numeric(6,3),
  minimum_change numeric(6,3) not null default 0.050,
  cooldown_minutes integer not null default 360,
  enabled boolean not null default true,
  last_notified_price numeric(6,3),
  last_notified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint price_alerts_mode_check
    check (alert_mode in ('any_change','price_drop','at_or_below')),
  constraint price_alerts_threshold_check
    check (
      (alert_mode = 'at_or_below' and threshold_price between 1.000 and 8.000)
      or
      (alert_mode <> 'at_or_below' and threshold_price is null)
    ),
  constraint price_alerts_minimum_change_check
    check (minimum_change between 0.010 and 2.000),
  constraint price_alerts_cooldown_check
    check (cooldown_minutes between 60 and 10080),
  constraint price_alerts_last_notified_price_check
    check (last_notified_price is null or last_notified_price between 1.000 and 8.000),
  unique (installation_id, station_id)
);

create index price_alerts_station_enabled_idx
  on private.price_alerts (station_id, enabled);

create index price_alerts_installation_enabled_idx
  on private.price_alerts (installation_id, enabled);

create table private.price_alert_jobs (
  id uuid primary key default gen_random_uuid(),
  price_report_id uuid not null unique references public.e85_price_reports(id) on delete cascade,
  status text not null default 'pending',
  attempt_count integer not null default 0,
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  constraint price_alert_jobs_status_check
    check (status in ('pending','processing','completed','failed','dead')),
  constraint price_alert_jobs_attempt_count_check
    check (attempt_count >= 0)
);

create index price_alert_jobs_ready_idx
  on private.price_alert_jobs (available_at, created_at)
  where status in ('pending','failed');

create table private.price_alert_deliveries (
  id uuid primary key default gen_random_uuid(),
  alert_id uuid not null references private.price_alerts(id) on delete cascade,
  price_report_id uuid not null references public.e85_price_reports(id) on delete cascade,
  push_device_id uuid not null references private.price_alert_push_devices(id) on delete cascade,
  observed_price numeric(6,3) not null,
  previous_price numeric(6,3),
  status text not null default 'pending',
  reason_code text,
  attempt_count integer not null default 0,
  provider_status integer,
  attempted_at timestamptz,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  constraint price_alert_deliveries_observed_price_check
    check (observed_price between 1.000 and 8.000),
  constraint price_alert_deliveries_previous_price_check
    check (previous_price is null or previous_price between 1.000 and 8.000),
  constraint price_alert_deliveries_status_check
    check (status in ('pending','sent','skipped','failed','invalid_device')),
  constraint price_alert_deliveries_attempt_count_check
    check (attempt_count >= 0),
  unique (alert_id, price_report_id, push_device_id)
);

create index price_alert_deliveries_report_idx
  on private.price_alert_deliveries (price_report_id);

create index price_alert_deliveries_retry_idx
  on private.price_alert_deliveries (created_at)
  where status in ('pending','failed');

-- Reuse the existing private.set_updated_at() trigger helper used by the
-- RevenueCat/referral backend.
create trigger price_alert_installations_set_updated_at
  before update on private.price_alert_installations
  for each row execute function private.set_updated_at();

create trigger price_alert_push_devices_set_updated_at
  before update on private.price_alert_push_devices
  for each row execute function private.set_updated_at();

create trigger price_alerts_set_updated_at
  before update on private.price_alerts
  for each row execute function private.set_updated_at();

-- A tiny transactional outbox hook. It never performs network I/O. New reports
-- are queued only when at least one enabled alert exists for that station.
create function private.enqueue_price_alert_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from private.price_alerts a
    where a.station_id = new.station_id
      and a.enabled = true
  ) then
    insert into private.price_alert_jobs (price_report_id)
    values (new.id)
    on conflict (price_report_id) do nothing;
  end if;

  return new;
end;
$$;

revoke execute on function private.enqueue_price_alert_job() from public, anon, authenticated;

grant execute on function private.enqueue_price_alert_job() to postgres;

create trigger e85_price_reports_enqueue_price_alert_job
  after insert on public.e85_price_reports
  for each row execute function private.enqueue_price_alert_job();

-- Defense in depth even though private is not exposed through the Data API.
alter table private.price_alert_installations enable row level security;
alter table private.price_alert_push_devices enable row level security;
alter table private.price_alerts enable row level security;
alter table private.price_alert_jobs enable row level security;
alter table private.price_alert_deliveries enable row level security;

revoke all on table private.price_alert_installations from public, anon, authenticated;
revoke all on table private.price_alert_push_devices from public, anon, authenticated;
revoke all on table private.price_alerts from public, anon, authenticated;
revoke all on table private.price_alert_jobs from public, anon, authenticated;
revoke all on table private.price_alert_deliveries from public, anon, authenticated;

comment on table private.price_alert_installations is
  '85Blends 2.4.0 private installation principals for station price alerts. Stores only a SHA-256 hash of the per-installation secret.';
comment on table private.price_alert_push_devices is
  '85Blends 2.4.0 private APNs device registrations for station price alerts.';
comment on table private.price_alerts is
  '85Blends 2.4.0 private station-specific Pro price alert preferences.';
comment on table private.price_alert_jobs is
  '85Blends 2.4.0 durable outbox for price report alert processing; no network calls occur in the insert trigger.';
comment on table private.price_alert_deliveries is
  '85Blends 2.4.0 idempotent per-device price alert delivery ledger.';
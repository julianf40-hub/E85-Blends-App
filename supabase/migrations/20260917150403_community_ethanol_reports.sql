-- Community ethanol reports are independent, immutable observations tied to the same canonical
-- station identity used by community price reports. The database enforces the full physical
-- percentage range; the narrower 51...83 expected-E85 range remains a client confirmation rule,
-- not a server rejection rule.

create table public.e85_ethanol_reports (
  id                     uuid         primary key default gen_random_uuid(),
  station_id             uuid         not null references public.community_stations(id) on delete cascade,
  ethanol_percentage     numeric(5,2) not null,
  reported_at            timestamptz  not null default now(),
  anonymous_reporter_id  text         not null,
  app_version            text,
  note                   text,
  created_at             timestamptz  not null default now(),

  constraint e85_ethanol_reports_percentage_check
    check (ethanol_percentage >= 0 and ethanol_percentage <= 100),
  constraint e85_ethanol_reports_reporter_id_not_blank
    check (btrim(anonymous_reporter_id) <> '')
);

create index e85_ethanol_reports_station_latest_idx
  on public.e85_ethanol_reports (station_id, reported_at desc, created_at desc);

alter table public.e85_ethanol_reports enable row level security;

-- Existing Supabase projects can still apply default public-schema privileges automatically.
-- Start from an explicit deny state, then grant only what the public clients need.
revoke all on table public.e85_ethanol_reports from public, anon, authenticated;

grant select on table public.e85_ethanol_reports to anon, authenticated;
grant insert (station_id, ethanol_percentage, reported_at, anonymous_reporter_id, app_version, note)
  on public.e85_ethanol_reports
  to anon, authenticated;

grant delete, insert, references, select, trigger, truncate, update
  on table public.e85_ethanol_reports
  to service_role;

create policy "Public can insert ethanol reports"
  on public.e85_ethanol_reports
  for insert
  to anon, authenticated
  with check (
    ethanol_percentage >= 0
    and ethanol_percentage <= 100
    and btrim(anonymous_reporter_id) <> ''
  );

create policy "Public can read ethanol reports"
  on public.e85_ethanol_reports
  for select
  to anon, authenticated
  using (true);

-- No UPDATE or DELETE grants or policies are intentional: submitted reports are immutable.

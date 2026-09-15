create table public.e85_analytics_events (
  id uuid primary key default gen_random_uuid(),
  event_name text not null check (event_name in ('station_viewed','community_price_state_seen','price_report_prompt_shown','price_report_opened','price_report_submitted','price_report_failed')),
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  app_version text not null check (char_length(app_version) between 1 and 32),
  contributor_id uuid not null,
  properties jsonb not null default '{}'::jsonb check (jsonb_typeof(properties) = 'object' and octet_length(properties::text) <= 4096)
);
create index idx_e85_analytics_events_event_time on public.e85_analytics_events (event_name, occurred_at desc);
create index idx_e85_analytics_events_contributor_time on public.e85_analytics_events (contributor_id, occurred_at desc);
alter table public.e85_analytics_events enable row level security;
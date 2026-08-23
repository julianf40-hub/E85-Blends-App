-- 85Blends 2.3.0 — Supabase backend foundation, Phase A0/A.
--
-- Adds the private, server-only schema that will mirror RevenueCat Pro entitlement state so a
-- future webhook (Phase B — NOT part of this migration) has somewhere safe to write. This
-- migration is purely additive: it creates a brand-new `private` schema and three new tables in
-- it. It does not touch, reference, alter, or depend on anything in `public` — in particular it
-- does not touch `public.community_stations` or `public.e85_price_reports`, their RLS policies,
-- their grants, or their data. See supabase/README.md for why those two tables are NOT captured
-- in a baseline migration here, and for the live-project reconciliation strategy.
--
-- Scope, deliberately narrow (see the Phase A task spec):
--   - Schema + 3 tables + their constraints/indexes + RLS enabled + explicit grant hardening.
--   - One small, non-privileged `updated_at` trigger helper.
--   - NO webhook processing logic, NO event-type transition logic, NO RPC beyond the timestamp
--     helper. Phase B will design the actual write path once the RevenueCat webhook + server API
--     refresh contract is finalized — this migration only has to give it a safe place to land.
--
-- Nothing in this file is executed against the live project by this task. It is a reviewed,
-- committed migration file only — see the Phase A final report for confirmation.


-- =============================================================================================
-- SECTION: private schema
-- =============================================================================================
-- RevenueCat entitlement data is never exposed through Supabase's Data API (PostgREST only
-- serves schemas listed in `api.schemas`, which stays `public, graphql_public` — see
-- supabase/config.toml and supabase/README.md). Keeping this data in a schema that was never
-- part of that exposure list, on top of RLS, is a second independent boundary: even a
-- misconfigured RLS policy on one of these tables would still not make the table reachable over
-- the REST API, because PostgREST never routes requests into `private` at all.

-- No IF NOT EXISTS: this migration must fail loudly, not silently adopt an unexpected existing
-- `private` schema with unknown contents/ownership/grants (see Phase A task spec on migration
-- reviewability). If this statement ever fails because `private` already exists, stop and
-- investigate rather than relaxing this to IF NOT EXISTS.
create schema private;

comment on schema private is
  '85Blends server-only backend state (RevenueCat entitlement mirror). Never exposed via the '
  'Supabase Data API. No table in this schema grants anon/authenticated any privilege.';

-- Defense in depth, not reliance on "a brand-new schema starts with no grants" — explicit per
-- Phase 8 of the task spec. `postgres` (migrations / SQL editor) and `service_role` (future
-- server-side access — see supabase/README.md for how a Phase B Edge Function will actually
-- reach this schema) are the only roles that can even reference objects here.
revoke all on schema private from public;
revoke all on schema private from anon, authenticated;
grant usage on schema private to postgres, service_role;


-- =============================================================================================
-- SECTION: updated_at helper
-- =============================================================================================
-- Plain trigger function — does not need SECURITY DEFINER (it only ever runs as part of a DML
-- statement the caller was already privileged to issue on the row it's firing for; it needs no
-- privileges beyond that). Schema-qualified, safe search_path, not owned by/callable as anything
-- more privileged than the migration role that creates it.

create function private.set_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog, private
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function private.set_updated_at() is
  'Trigger helper: stamps updated_at = now() on UPDATE. Used only by private.revenuecat_customers.';

-- Postgres grants EXECUTE on new functions to PUBLIC by default — revoke it explicitly. Trigger
-- firing does not require a direct EXECUTE grant, so this does not affect the trigger below; it
-- only prevents anyone from calling the function directly via SQL.
revoke execute on function private.set_updated_at() from public;
revoke execute on function private.set_updated_at() from anon, authenticated;


-- =============================================================================================
-- SECTION: private.revenuecat_customers
-- =============================================================================================
-- One canonical, normalized entitlement row per (RevenueCat canonical customer, environment).
-- `original_app_user_id` — not whichever alias happened to appear on the most recent event — is
-- the identity anchor, because RevenueCat's own aliasing means the "current" app_user_id for a
-- subscriber can change (anonymous ID churn, restores, transfers) while original_app_user_id
-- stays stable. `environment` is part of the identity itself (not just a label) so a SANDBOX and
-- a PRODUCTION subscriber can never collide into the same row even though Internal and
-- Production currently share this one Supabase project — see supabase/README.md.
--
-- Deliberately does NOT store: name, email, Apple ID, payment method data, or raw receipts.
-- RevenueCat App User IDs are pseudonymous identifiers, not account data.
--
-- Deliberately does NOT encode a full event-type transition state machine (no per-event-type
-- columns, no cancel_reason, no billing-retry-specific fields) — per the current Phase B design
-- direction, the future webhook treats RevenueCat's push as "something changed, go fetch the
-- canonical state," so this table only needs to hold the NORMALIZED RESULT of that fetch:
-- whether `pro` is active, when it expires, and when/from-what-event it was last synced.

create table private.revenuecat_customers (
  id                    uuid        primary key default gen_random_uuid(),
  original_app_user_id  text        not null,
  environment           text        not null,
  entitlement_id        text        not null default 'pro',
  pro_is_active         boolean     not null default false,
  pro_expires_at        timestamptz null,
  last_synced_at        timestamptz null,
  last_trigger_event_id text        null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint revenuecat_customers_environment_check
    check (environment in ('SANDBOX', 'PRODUCTION')),
  constraint revenuecat_customers_entitlement_id_not_blank
    check (entitlement_id <> ''),
  constraint revenuecat_customers_original_app_user_id_not_blank
    check (original_app_user_id <> ''),

  -- The canonical-customer identity: one row per (subscriber, environment, entitlement).
  constraint revenuecat_customers_identity_unique
    unique (original_app_user_id, environment, entitlement_id)
);

comment on table private.revenuecat_customers is
  'Server-only normalized RevenueCat Pro entitlement state, one row per canonical customer + '
  'environment + entitlement. Written only by a future trusted server process (Phase B) — never '
  'by the iOS app. anon/authenticated have zero privileges on this table (see grants below).';
comment on column private.revenuecat_customers.original_app_user_id is
  'RevenueCat''s durable canonical App User ID for this subscriber — the identity anchor across '
  'alias/anonymous-ID churn. See private.revenuecat_aliases for the full alias set.';
comment on column private.revenuecat_customers.environment is
  'SANDBOX or PRODUCTION, as reported by RevenueCat. Part of this row''s identity, not just a '
  'label — see this table''s own comment.';
comment on column private.revenuecat_customers.pro_is_active is
  'Mirrors CustomerInfo.entitlements["pro"]?.isActive from RevenueCat''s canonical state. Never '
  'written by the iOS app.';

create trigger revenuecat_customers_set_updated_at
  before update on private.revenuecat_customers
  for each row
  execute function private.set_updated_at();

revoke all on table private.revenuecat_customers from public;
revoke all on table private.revenuecat_customers from anon, authenticated;
grant select, insert, update on table private.revenuecat_customers to service_role;

alter table private.revenuecat_customers enable row level security;
-- Intentionally zero policies: RLS with no policy means no role subject to RLS (anon,
-- authenticated) can see or touch any row. service_role bypasses RLS by design (Supabase's
-- standard BYPASSRLS role) and reaches this table through the explicit grants above instead.


-- =============================================================================================
-- SECTION: private.revenuecat_aliases
-- =============================================================================================
-- Maps every RevenueCat App User ID RevenueCat has ever reported for a subscriber — including
-- the original ID and any anonymous/aliased IDs picked up via restores or transfers — to the one
-- canonical customer row above. Required because a webhook or a future "sync my identity" call
-- may arrive carrying a non-original app_user_id, and it must resolve to the same customer.

create table private.revenuecat_aliases (
  app_user_id  text        not null,
  environment  text        not null,
  customer_id  uuid        not null references private.revenuecat_customers (id) on delete cascade,
  created_at   timestamptz not null default now(),

  constraint revenuecat_aliases_environment_check
    check (environment in ('SANDBOX', 'PRODUCTION')),
  constraint revenuecat_aliases_app_user_id_not_blank
    check (app_user_id <> ''),

  primary key (app_user_id, environment)
);

comment on table private.revenuecat_aliases is
  'Every RevenueCat App User ID (original or aliased) known for a subscriber, mapped to its '
  'canonical private.revenuecat_customers row. Server-only — see grants below.';

create index revenuecat_aliases_customer_id_idx
  on private.revenuecat_aliases (customer_id);

revoke all on table private.revenuecat_aliases from public;
revoke all on table private.revenuecat_aliases from anon, authenticated;
grant select, insert, update on table private.revenuecat_aliases to service_role;

alter table private.revenuecat_aliases enable row level security;
-- Intentionally zero policies — see private.revenuecat_customers' RLS comment above; the same
-- reasoning applies identically here.


-- =============================================================================================
-- SECTION: private.revenuecat_webhook_events
-- =============================================================================================
-- Idempotency + minimal operational audit ledger for inbound RevenueCat webhook deliveries.
-- `event_id` as the PRIMARY KEY is the entire idempotency mechanism a future Phase B webhook
-- handler needs: `insert ... on conflict (event_id) do nothing` makes duplicate/replayed
-- delivery a harmless no-op without any additional locking logic.
--
-- No event-type transition/business logic lives here or anywhere else in this migration — this
-- table only records that an event was received and, eventually, what happened to it.

create table private.revenuecat_webhook_events (
  event_id            text        primary key,
  event_type          text        not null,
  app_user_id         text        not null,
  original_app_user_id text       null,
  environment         text        not null,
  event_timestamp     timestamptz not null,
  received_at         timestamptz not null default now(),
  processing_status   text        not null default 'received',
  processed_at        timestamptz null,
  payload_hash        text        not null,
  error_message       text        null,
  raw_payload         jsonb       null,

  constraint revenuecat_webhook_events_environment_check
    check (environment in ('SANDBOX', 'PRODUCTION')),
  constraint revenuecat_webhook_events_processing_status_check
    check (processing_status in (
      'received',
      'processed',
      'ignored_duplicate',
      'ignored_stale',
      'error'
    )),
  constraint revenuecat_webhook_events_event_id_not_blank
    check (event_id <> ''),
  constraint revenuecat_webhook_events_payload_hash_not_blank
    check (payload_hash <> '')
);

comment on table private.revenuecat_webhook_events is
  'Idempotent ledger of inbound RevenueCat webhook deliveries. event_id is RevenueCat''s own '
  'event identifier and is the PRIMARY KEY specifically so duplicate/replayed delivery is a '
  'no-op at the database level. Server-only — see grants below. No processing/transition logic '
  'is implemented by this migration; that is Phase B''s scope.';
comment on column private.revenuecat_webhook_events.raw_payload is
  'Full webhook JSON, retained for a bounded window during this integration''s early life for '
  'debugging. A future retention/cleanup job (not part of this migration) should null this out '
  'after a fixed window while keeping the normalized columns indefinitely — see '
  'supabase/README.md.';

create index revenuecat_webhook_events_app_user_environment_idx
  on private.revenuecat_webhook_events (app_user_id, environment);
create index revenuecat_webhook_events_received_at_idx
  on private.revenuecat_webhook_events (received_at);

revoke all on table private.revenuecat_webhook_events from public;
revoke all on table private.revenuecat_webhook_events from anon, authenticated;
grant select, insert, update on table private.revenuecat_webhook_events to service_role;

alter table private.revenuecat_webhook_events enable row level security;
-- Intentionally zero policies — see private.revenuecat_customers' RLS comment above; the same
-- reasoning applies identically here.

-- 85Blends 2.4.0 — Referral client API foundation.
--
-- Client-safe credential layer for supabase/functions/referral-api — the ONLY path the iOS app is
-- ever allowed to use to reach the private.referral_* foundation already established by
-- 20260910000000_referral_backend_baseline.sql and
-- 20260919150000_referral_paid_qualification_foundation.sql. Purely additive: two new private
-- tables, no change to any existing referral table/function/grant.
--
-- SECURITY PHILOSOPHY — mirrors the exact pattern already live for Station Price Alerts
-- (private.price_alert_installations, 20260910212848_price_alert_backend_foundation.sql), not a
-- new design:
--   1. verify_jwt = false on the Edge Function (see supabase/config.toml) — RevenueCat-style
--      webhooks aside, 85Blends does not use Supabase Auth sessions, so the platform JWT gate is
--      replaced with this function's own authentication.
--   2. every request must present a valid client-safe Supabase API key (a publishable key, or the
--      legacy anon key) — a PUBLIC, project-scoped credential, not app attestation and not proof
--      of a human/user. It is a first-gate routing/project-identity check only.
--   3. every request must ALSO present a per-installation secret, generated client-side and never
--      transmitted anywhere except this one authentication check — THIS is the actual possession
--      credential that identifies a specific installation; the API key from (2) never substitutes
--      for it.
--   4. only SHA-256(secret) is ever stored — the raw secret is never persisted, logged, or
--      returned by any endpoint.
--   5. stored hashes are compared using a constant-time comparison (see
--      supabase/functions/_shared/hmac.ts's constantTimeEqual, already used by revenuecat-webhook).
--   6. both new tables stay private/service-role-only: RLS enabled, zero policies, explicit
--      revoke from public/anon/authenticated — the `private` schema is never exposed to PostgREST
--      (see supabase/README.md), and referral-api itself reaches Postgres directly via
--      SUPABASE_DB_URL (see supabase/functions/_shared/database.ts's createDatabaseClient, reused
--      as-is — not reimplemented here), exactly like revenuecat-webhook already does.

-- ============================================================================================
-- 1. private.referral_client_installations — one credential row per authenticated installation.
-- ============================================================================================
-- installation_id is the SAME identifier as private.referral_participants.installation_id (that
-- column already carries a UNIQUE constraint — referral_participants_installation_id_key — from
-- the original baseline migration), so this table can safely foreign-key straight to it: a
-- credential row only ever exists for an installation that already has (or, in the same
-- transaction, is about to have) a referral participant. ON DELETE CASCADE: if a participant row
-- is ever removed, its orphaned credential should never silently keep authenticating requests for
-- a participant that no longer exists.
create table private.referral_client_installations (
  installation_id uuid primary key references private.referral_participants(installation_id) on delete cascade,
  installation_secret_hash text not null,
  -- Client-reported app version at last bootstrap, for diagnostics only — never part of
  -- authentication, never returned by any endpoint (see referral-api/index.ts's status response,
  -- which deliberately never includes it). Nullable: a client may omit it, and an existing
  -- installation's previously-stored value is preserved (never cleared) when a later bootstrap
  -- call doesn't supply one.
  app_version text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  constraint referral_client_installations_secret_hash_check
    check (installation_secret_hash ~ '^[0-9a-f]{64}$'),
  constraint referral_client_installations_app_version_check
    check (app_version is null or length(app_version) between 1 and 64)
);

comment on table private.referral_client_installations is
  '85Blends 2.4.0 client-safe referral API authentication. Stores only a SHA-256 hash of the per-installation secret — the raw secret is never persisted. Reached only by supabase/functions/referral-api via a direct service-role Postgres connection; never exposed through PostgREST.';

revoke all on table private.referral_client_installations from public, anon, authenticated;
grant select, insert, update on table private.referral_client_installations to service_role;

alter table private.referral_client_installations enable row level security;
-- Deliberately zero policies: with RLS enabled and no policy, `anon`/`authenticated` are already
-- denied all access by the revokes above and would additionally be denied by RLS defaulting to
-- deny-all — belt and suspenders, matching the identical pattern this migration's header comment
-- describes for private.price_alert_installations and the original private.referral_* tables.

-- ============================================================================================
-- 2. private.referral_apply_attempts — narrow, append-only log backing a per-installation
--    rate limit on NEW referral-code attempts (Phase 12 abuse hardening).
-- ============================================================================================
-- Referral codes are high-entropy (8 characters from a 33-symbol alphabet — see
-- private.generate_referral_code), so brute-forcing one is already impractical. This exists so
-- referral-api never becomes an UNLIMITED code-probing oracle regardless. Scoped narrowly: only
-- an attempt to attach a NEW code (one this installation has no existing attribution for yet) is
-- ever logged here — see referral-api/index.ts's applyCode handler. An idempotent re-submission of
-- an already-applied code, and ordinary bootstrap/status traffic, never touch this table at all.
create table private.referral_apply_attempts (
  installation_id uuid not null references private.referral_client_installations(installation_id) on delete cascade,
  attempted_at timestamptz not null default now()
);

create index referral_apply_attempts_installation_idx
  on private.referral_apply_attempts (installation_id, attempted_at desc);

comment on table private.referral_apply_attempts is
  '85Blends 2.4.0 referral-api abuse hardening. Append-only log of NEW referral-code attempts per installation, backing a 5-attempts-per-60-seconds server-side limit (see referral-api/index.ts). Not pruned by this migration — rows are tiny and short-lived in relevance; a future retention job is a separate, independent concern.';

revoke all on table private.referral_apply_attempts from public, anon, authenticated;
grant select, insert on table private.referral_apply_attempts to service_role;

alter table private.referral_apply_attempts enable row level security;
-- Same "zero policies, deny-all" reasoning as referral_client_installations above.

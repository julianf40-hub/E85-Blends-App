-- 85Blends 2.4.0 — Referral client API foundation.
--
-- Client-safe credential layer for supabase/functions/referral-api — the ONLY path the iOS app is
-- ever allowed to use to reach the private.referral_* foundation already established by
-- 20260910000000_referral_backend_baseline.sql and
-- 20260919150000_referral_paid_qualification_foundation.sql. Two new private tables, plus a
-- concurrency fix (Section 3, below) for the existing private.create_or_get_referral_participant
-- — a genuine, reproduced bug this migration's own referral-api client necessarily exposes to
-- concurrent callers for the first time (two near-simultaneous bootstrap requests for the same
-- brand-new installation), where the earlier migrations' own callers never raced each other this
-- way. Grants/security posture for every existing object are otherwise fully preserved — see
-- Section 3's own comment for exactly what changed and why.
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

-- ============================================================================================
-- 3. Concurrency hardening — private.create_or_get_referral_participant
-- ============================================================================================
-- REPRODUCED BUG (genuinely concurrent local test, two real Postgres connections, not merely
-- sequential statements — see the referral-api hardening task's own Phase 2): the live function's
-- participant-creation step is
--   select * into v_participant from private.referral_participants where installation_id = ...;
--   if v_participant.id is null then
--     loop  -- generate a fresh referral_code, then INSERT, retrying on unique_violation
--   end if;
-- When two concurrent bootstrap requests race for the SAME brand-new installation_id, BOTH can
-- see "no row" from that initial SELECT before either INSERTs. One INSERT wins. The LOSER's
-- INSERT then fails with unique_violation on referral_participants_installation_id_key — but the
-- retry loop's exception handler catches unique_violation UNCONDITIONALLY (assuming it can only
-- mean "the freshly-generated referral_code collided," never "the installation_id itself already
-- exists"), so it retries with a NEW code against the SAME already-taken installation_id, which
-- collides again, every time, for all 10 attempts — then re-raises. Confirmed exactly this way:
-- two real concurrent connections calling the unmodified function for the same new
-- installation_id, one succeeds, the other's call fails outright with a raw
-- "duplicate key value violates unique constraint referral_participants_installation_id_key"
-- (SQLSTATE 23505) escaping the function entirely — never a graceful "here's the participant the
-- other request just created." Before this migration's own referral-api, nothing in this codebase
-- ever called this function from two genuinely concurrent requests for a brand-new installation
-- (RevenueCat webhook events reach it, if at all, one already-existing installation at a time),
-- so this race window existed but was never actually reachable until now.
--
-- FIX: `insert ... on conflict (installation_id) do nothing returning ...` absorbs the
-- installation_id race itself (the actual conflict target), so it can never raise
-- unique_violation for that reason at all — only a genuine referral_code collision (the
-- 33^8-keyspace, independently-astronomically-unlikely case the retry loop was originally meant
-- for) can still reach the exception handler now. When the conflict-absorbing insert returns no
-- row, that means a concurrent transaction already committed a participant for this SAME
-- installation_id — Postgres's own row-level locking for INSERT ... ON CONFLICT guarantees that
-- transaction has already durably committed (or, if it instead rolled back, our own insert would
-- have proceeded and returned a row instead) by the time this statement resolves, so their row is
-- guaranteed visible to an immediate follow-up SELECT — never a further wait or retry needed.
--
-- UNCHANGED: signature, return shape, language, search_path, the alias-conflict-hardening block
-- (byte-for-byte identical to the live 20260919150000 version), and grants — CREATE OR REPLACE
-- FUNCTION preserves existing privileges for an unchanged signature automatically (the exact same
-- reasoning 20260919150000's own header comment already documents for this identical function);
-- reverified directly against this migration's own local replay, not assumed.
create or replace function private.create_or_get_referral_participant(
  p_installation_id uuid,
  p_app_user_id text default null,
  p_environment text default 'PRODUCTION'
)
returns table(participant_id uuid, referral_code text)
language plpgsql
set search_path to 'pg_catalog', 'private'
as $function$
declare
  v_participant private.referral_participants%rowtype;
  v_code text;
  v_attempt integer := 0;
  v_trimmed_app_user_id text;
  v_existing_alias_participant_id uuid;
begin
  if p_installation_id is null then
    raise exception 'installation_id_required';
  end if;
  if p_environment not in ('SANDBOX','PRODUCTION') then
    raise exception 'invalid_environment';
  end if;

  select * into v_participant
  from private.referral_participants rp
  where rp.installation_id = p_installation_id;

  if v_participant.id is null then
    loop
      v_attempt := v_attempt + 1;
      v_code := private.generate_referral_code();

      begin
        insert into private.referral_participants (installation_id, referral_code)
        values (p_installation_id, v_code)
        on conflict (installation_id) do nothing
        returning * into v_participant;
      exception when unique_violation then
        -- Only a genuine referral_code collision can still land here — the installation_id
        -- conflict itself is fully absorbed by ON CONFLICT (installation_id) above.
        if v_attempt >= 10 then
          raise;
        end if;
        continue;
      end;

      if v_participant.id is not null then
        -- Our own insert won outright: this installation_id was genuinely new.
        exit;
      end if;

      -- ON CONFLICT (installation_id) DO NOTHING fired: a concurrent transaction already
      -- created a participant for this SAME installation_id — see this section's header
      -- comment for why their committed row is guaranteed visible here. Adopt it and continue
      -- idempotently; never retry an insert that would only collide again.
      select * into v_participant
      from private.referral_participants rp
      where rp.installation_id = p_installation_id;

      if v_participant.id is null then
        -- Unreachable per the guarantee above — never assume away a defensive check on an
        -- identity-integrity path (same discipline as the alias-conflict guard below).
        raise exception 'referral_participant_missing_after_conflict';
      end if;
      exit;
    end loop;
  end if;

  v_trimmed_app_user_id := btrim(p_app_user_id);
  if v_trimmed_app_user_id is not null and length(v_trimmed_app_user_id) > 0 then
    insert into private.referral_participant_aliases (app_user_id, environment, participant_id)
    values (v_trimmed_app_user_id, p_environment, v_participant.id)
    on conflict (app_user_id, environment) do nothing;

    select rpa.participant_id into v_existing_alias_participant_id
    from private.referral_participant_aliases rpa
    where rpa.app_user_id = v_trimmed_app_user_id
      and rpa.environment = p_environment;

    if v_existing_alias_participant_id is null then
      -- Unreachable in practice (the insert above either created the row itself or a concurrent
      -- transaction did), but never assume away a defensive check on an identity-integrity path.
      raise exception 'referral_alias_missing_after_insert';
    elsif v_existing_alias_participant_id <> v_participant.id then
      raise exception 'referral_alias_conflict: app_user_id already attached to a different referral participant';
    end if;
    -- else: already correctly mapped (fresh insert, or an idempotent re-call for the same
    -- participant) — nothing more to do.
  end if;

  return query select v_participant.id, v_participant.referral_code;
end;
$function$;

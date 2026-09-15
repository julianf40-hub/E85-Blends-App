
-- TEMPORARY compatibility bridge for currently-distributed 85Blends clients (every released
-- version through at least v2.3.1, and everything on main up to 49062ac -- confirmed via git
-- history) that still send "Prefer: resolution=merge-duplicates" to community_stations. That
-- header makes PostgREST generate INSERT ... ON CONFLICT (normalized_key) DO UPDATE ..., which
-- Postgres statically requires UPDATE privilege for -- checked once for the whole statement,
-- regardless of whether a conflict actually occurs. After community_stations_revoke_anon_update
-- removed that privilege (correctly, for the *new* 2.3.2 client, which no longer needs it),
-- every currently-installed client became unable to create a genuinely brand-new community
-- station: confirmed empirically (permission denied) against production before this migration.
--
-- This grants back ONLY the column-scoped UPDATE privilege needed to satisfy Postgres's static
-- check -- deliberately WITHOUT restoring any RLS UPDATE policy. Empirically verified before
-- being applied here (via a self-contained, rolled-back transaction that included the GRANT
-- itself, so nothing persisted during testing):
--   * A brand-new (non-conflicting) key: INSERT succeeds normally (xmax=0, genuine insert) --
--     old clients can create new stations again.
--   * An existing (conflicting) key, via the old client's own ON CONFLICT DO UPDATE statement:
--     FAILS with "new row violates row-level security policy" -- RLS's default-deny (no
--     permissive UPDATE policy exists) blocks the mutation outright, it is not silently allowed.
--     The old client's own pre-existing error handling (upsertCommunityStation's catch block)
--     already falls back to re-fetching the row by normalized_key on ANY thrown error -- so this
--     resolves exactly like today's already-shipped network-failure fallback, with zero client
--     changes needed (none are possible for already-installed clients anyway).
--   * A direct/raw UPDATE attempt (not via the upsert): silently affects zero rows -- also not a
--     mutation path, RLS filters it out before any row is touched.
--   * normalized_key remains fully protected (not in this grant, so any attempt to change it
--     fails at the column-ACL level, before RLS is even evaluated).
--   * DELETE remains fully prohibited (never touched by this or any related migration).
--   * The NEW 2.3.2 client (ignore-duplicates / ON CONFLICT DO NOTHING) is completely unaffected
--     by this grant either way, since DO NOTHING never invokes the UPDATE privilege check at all.
--
-- REMOVAL: this grant should be revoked once merge-duplicates clients are no longer considered
-- necessary to support (see docs/PRE_RELEASE_SUPABASE_CHECKLIST.md for the exact removal
-- statement and condition). It is intentionally NOT paired with any UPDATE policy, so there is
-- no policy to also drop at removal time -- just this grant.

grant update (name, address, city, state, zip, latitude, longitude, updated_at)
  on public.community_stations
  to anon, authenticated;

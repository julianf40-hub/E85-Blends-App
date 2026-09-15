# Supabase Migration History Recovery

**This branch is migration-history recovery only.** It reconstructs `supabase/migrations/` so
this repository's checked-in history matches what has actually been applied to the live project.
It contains no application code, no feature work, and no changes outside `supabase/migrations/`
and this file.

## Status

- **Has not passed a real `supabase db reset`.** Every file here was validated only by static,
  non-executing analysis (structural dependency tracking, hash verification against the live
  migration ledger) — never by actually running the SQL against a database, empty or otherwise.
- **Must not be merged or applied to production until an empty-database replay succeeds** on a
  machine with Docker and the Supabase CLI (`supabase start` + `supabase db reset` against this
  exact file set, in this exact order).
- No `supabase db push`, no `supabase migration repair`, and no other live database mutation has
  occurred as part of producing this branch. Nothing here has touched the live project.

## What's in `supabase/migrations/` (17 files, in replay order)

**2 synthetic baselines** — reconstructed from live catalog metadata plus the text of the 13
recovered migrations below, not copied from any existing migration record:

- `20260427000000_community_pricing_founding_baseline.sql` — founding definitions for
  `public.community_stations` and `public.e85_price_reports`. Neither table has a creation
  migration anywhere in the live ledger or in this repository's git history.
- `20260910000000_referral_backend_baseline.sql` — the four `private.referral_*` tables
  (`referral_participants`, `referral_participant_aliases`, `referral_attributions`,
  `referral_rewards`) and their supporting constraints/indexes/grants/triggers. No migration
  anywhere creates these either.

Both use placeholder version numbers chosen only to preserve dependency order without colliding
with any real live version — not authoritative timestamps.

**13 migrations recovered byte-for-byte from the live migration ledger**
(`supabase_migrations.schema_migrations.statements`), under their exact live version numbers and
names, verified via SHA-256 digest match against a freshly re-queried live digest for every file:

- `20260903215649_community_stations_allow_public_upsert_update.sql`
- `20260903221221_community_stations_revoke_anon_update.sql`
- `20260903222357_community_stations_temporary_legacy_client_bridge.sql`
- `20260909101257_enable_community_price_inserts.sql`
- `20260909101339_create_e85_analytics_events_table.sql`
- `20260909101353_secure_e85_analytics_events.sql`
- `20260909101412_limit_e85_analytics_property_keys.sql`
- `20260909101422_limit_e85_analytics_entry_points.sql`
- `20260909101427_limit_e85_analytics_price_states.sql`
- `20260909101434_limit_e85_analytics_station_source.sql`
- `20260909101440_limit_e85_analytics_failure_category.sql`
- `20260910212848_price_alert_backend_foundation.sql`
- `20260910213128_price_alert_performance_indexes.sql`

**2 RevenueCat migrations, renamed to their authoritative live versions** — previously checked in
under different local timestamps (`20260823055527`, `20260823062025`) that do not exist anywhere
in the live ledger:

- `20260823060735_revenuecat_entitlement_foundation.sql` (was `20260823055527_...`) — content
  confirmed semantically identical to the live-applied statement (every executable statement
  matches once comments are stripped; the live-applied version has its comments removed, this
  file keeps them).
- `20260823073614_revenuecat_webhook_ledger_nullable_identity.sql` (was `20260823062025_...`) —
  content confirmed byte-for-byte identical to the live-applied statement.

## Live-ledger reconciliation (not performed on this branch)

- **Only the two synthetic baseline versions** (`20260427000000`, `20260910000000`) are absent
  from the live ledger and may eventually need `supabase migration repair --status applied
  <version>` — and only after a successful empty-database replay and explicit authorization.
- **The 13 recovered migrations and the 2 RevenueCat migrations under their live versions must
  not be repaired** — they already exist in the live ledger under these exact version numbers.
  Adding these files here only makes the local repository match what the remote already records;
  it requires no ledger change at all.

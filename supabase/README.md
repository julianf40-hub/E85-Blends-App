# 85Blends Supabase Project

## Live project

- **Project ref:** `zefkbtscieokkdenvnkg` (region `us-east-1`, Postgres 17)
- No credentials, access tokens, database passwords, or connection strings live in this
  directory or anywhere else in this repository. `EightyFiveBlends/Info.plist` carries only the
  project's public `SUPABASE_URL` and `SUPABASE_ANON_KEY` — both are the client-safe anon JWT,
  never the service role key. See `EightyFiveBlends/SupabaseConfig.swift` and
  `docs/PRE_RELEASE_SUPABASE_CHECKLIST.md`.

## Schema is now version-controlled going forward

Starting with this directory, new Supabase schema changes are written as reviewed SQL migrations
in `supabase/migrations/` rather than made directly in the dashboard. This does not retroactively
capture everything already in the live project — see the next section.

## Production predates migration tracking — baseline strategy

Before this directory existed, the live project already contained two dashboard-created tables
that back Community Pricing:

- `public.community_stations`
- `public.e85_price_reports`

**This repository does not (yet) contain a migration that creates those two tables**, and
deliberately so: a migration that runs `CREATE TABLE community_stations (...)` / `CREATE TABLE
e85_price_reports (...)` against a database where those tables already exist would either fail
outright or (with `IF NOT EXISTS`) silently paper over any drift between what's actually live and
what the fabricated "baseline" claims — neither is safe, and both risk this repo quietly lying
about the true schema.

Before this repo's migration history is treated as a complete, reconstructable source of truth,
someone with access to the live project must run `supabase link` + `supabase db pull` (or the
current CLI-equivalent baselining procedure) against the **live** project to generate a real,
verified baseline migration reflecting the two tables' actual live schema, indexes, and
constraints — then commit that as an explicit, clearly-labeled baseline migration. That step is
**not** part of this task and has not been done here.

Until that baseline exists:

- Treat every migration in this directory as **additive only** relative to the live project's
  actual current state — never assume this repo's migration history, replayed from empty, would
  reproduce the live database.
- Migration history between this repo and the live project must be **deliberately reconciled**
  (via `supabase migration repair` or equivalent) before anyone runs a normal `supabase db push`
  against production for the first time — otherwise the CLI may try to re-apply history the live
  database doesn't know about, or vice versa.

## Community Pricing must not be recreated or altered by entitlement work

`public.community_stations` and `public.e85_price_reports` — their schema, RLS policies, table
grants, and data — are explicitly **out of scope** for every migration in this directory unless a
future task is deliberately, narrowly scoped to touch them. In particular, the current live
`INSERT` RLS-policy-vs-table-privilege discrepancy on both tables (RLS INSERT policies exist for
`anon`/`authenticated`, but the underlying table `INSERT` privilege is currently `false` for
`anon`) is a **known, deliberately untouched** finding from the prior audit — see
`docs/PRE_RELEASE_SUPABASE_CHECKLIST.md`. Reconciling it is a separate, explicitly-scoped
follow-up, not something any RevenueCat-entitlement migration should incidentally fix.

## RevenueCat entitlement tables are private and server-only

`20260823055527_revenuecat_entitlement_foundation.sql` adds a **new, non-exposed `private`
schema** with three tables:

- `private.revenuecat_customers` — one normalized row per canonical RevenueCat customer +
  environment: `pro_is_active`, `pro_expires_at`, `last_synced_at`, `last_trigger_event_id`.
- `private.revenuecat_aliases` — every RevenueCat App User ID (original or aliased) mapped to its
  canonical customer row.
- `private.revenuecat_webhook_events` — an idempotent ledger of inbound webhook deliveries,
  keyed on RevenueCat's own `event_id`.

**`anon` and `authenticated` are granted nothing on any of the three** — no schema `USAGE`, no
table privileges, and RLS is enabled with zero policies on every table as defense in depth on top
of that. Only `service_role` (and the owning `postgres` role) can reach them. This is
intentionally a second, independent boundary beyond RLS: Supabase's Data API (PostgREST) only
ever serves the schemas listed in `api.schemas` in `supabase/config.toml` (`public`,
`graphql_public`) — `private` is not in that list, so these tables are unreachable through the
REST API regardless of RLS/grants. A **future** Edge Function will need either a direct Postgres
connection (bypassing PostgREST entirely) or a narrowly-scoped `SECURITY DEFINER` RPC wrapper
exposed in `public` with `EXECUTE` restricted to `service_role` — that design choice belongs to
Phase B, not this migration.

No event-type transition logic, RPC, or webhook processing exists yet — see the migration file's
own header comment for why, and the next section.

## Never commit secrets

No Supabase access token, database password, service role key, RevenueCat server/secret API key,
RevenueCat webhook authorization secret, APNs credential, or Apple private key may ever be
committed to this repository — in this directory or anywhere else. Server-side secrets belong in
Supabase's own secret management (`supabase secrets set ...`) once a Phase B Edge Function
actually needs them, never in source control.

## Migrations are additive and reviewed before production apply

Every migration here is meant to be reviewed as a diff before it is ever applied to the live
project. None of the migrations in this repository have been applied to the live project by any
automated process — applying them is a deliberate, separate, manual step.

## What comes next (Phase B and later)

This directory currently provides schema only. Still to come, in later, separately-scoped tasks:

1. **Phase B** — the RevenueCat webhook Edge Function itself: signed-request validation,
   idempotent event claiming against `private.revenuecat_webhook_events`, a canonical
   RevenueCat-server-API refresh, and the normalized write into `private.revenuecat_customers` /
   `private.revenuecat_aliases`. The exact transactional contract (and whether a
   `SECURITY DEFINER` RPC function is introduced for it) is intentionally undesigned here.
2. **Phase C** — webhook secret provisioning + RevenueCat dashboard configuration.
3. **Phase D** — sandbox webhook validation against the deployed function.
4. Installation identity, push-device registration, and Station Price Alerts backend/UI — all
   later, all depending on Phase B–D being green first.

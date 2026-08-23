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

## Phase A schema status

`20260823055527_revenuecat_entitlement_foundation.sql` has been reviewed AND applied to the live
project (`private.revenuecat_customers`, `private.revenuecat_aliases`,
`private.revenuecat_webhook_events`, `private.set_updated_at()` all exist live, RLS enabled, zero
client policies, zero `anon`/`authenticated` privileges). A second, additive migration,
`20260823062025_revenuecat_webhook_ledger_nullable_identity.sql`, relaxes the ledger's
`app_user_id`/`environment` columns to nullable (see that migration file's own header for why —
short version: `TRANSFER` and `TEMPORARY_ENTITLEMENT_GRANT` events don't carry those fields the
same way a normal purchase/renewal/expiration event does, and the ledger must not fabricate values
to satisfy a constraint that assumed every event looks like the latter). **That second migration
has NOT been applied to the live project as of Phase B1** — see the Phase B1 final report for
confirmation.

## Phase B1 — RevenueCat webhook Edge Function (source only, NOT deployed)

`supabase/functions/revenuecat-webhook/` and `supabase/functions/_shared/` contain a complete,
reviewed, but **undeployed** implementation of the webhook receiver described below. Nothing in
this section has been run against the live project, a live RevenueCat webhook, or a live Deno
runtime — see the Phase B1 final report for exactly what validation was and wasn't possible in
that implementation environment.

**Why `verify_jwt = false` for this one function** (`supabase/config.toml`): RevenueCat cannot
send a Supabase user JWT on webhook delivery, so Supabase's default per-function JWT gate would
reject every real request. This function replaces that gate with its own strictly-required,
defense-in-depth authentication instead of skipping authentication — see the next point.

**Authentication — BOTH required, always, no exceptions:**
1. A configured `Authorization` header value, compared in constant time.
2. A valid RevenueCat webhook HMAC-SHA256 signature (`X-RevenueCat-Webhook-Signature: t=...,v1=...`),
   verified against the raw request body bytes with a 5-minute timestamp tolerance, also compared
   in constant time.

Either check failing alone produces the exact same generic `401 {"error":"unauthorized"}` — the
response never reveals which check failed.

**Required runtime environment variables (names only — see "Never commit secrets" above; none of
these values exist anywhere in this repository):**

- `REVENUECAT_PROJECT_ID`
- `REVENUECAT_V2_SECRET_API_KEY` — needs at least `customer_information:subscriptions:read`
- `REVENUECAT_WEBHOOK_AUTH_HEADER` — the entire expected header value, not just a shared token
- `REVENUECAT_WEBHOOK_HMAC_SECRET`
- `SUPABASE_DB_URL` — Supabase provides this to every Edge Function; used for a direct Postgres
  connection (`npm:postgres`, `prepare: false`) so the function can reach the `private` schema
  without ever adding `private` to `[api].schemas`

If any of the five is missing at request time, the function returns `503` and logs only the
missing variable *names* — never falls back to the RevenueCat `appl_` public SDK key, the
Supabase anon key, or anything else client-facing.

**Canonical-state design — the core decision this whole function exists to get right:** the
webhook is treated purely as "RevenueCat says something changed," never as the entitlement
decision itself. On every event that carries a resolvable identity + environment, the function
calls RevenueCat's REST API v2
(`GET /v2/projects/{project_id}/customers/{app_user_id}/subscriptions?environment=sandbox|production`)
and computes `pro_is_active` from the fresh response: a subscription counts only if
`gives_access === true` AND it carries an entitlement with `lookup_key === "pro"`. `status` is
never consulted directly — `gives_access` alone is what RevenueCat defines as the access signal,
and using it (rather than the webhook event's own type) is what makes trials/grace
periods/billing retry/still-paid-through-cancellation all correct without special-casing. The
environment filter is what keeps SANDBOX and PRODUCTION from ever cross-contaminating, even though
Internal and Production iOS builds currently share this one Supabase project (see above).

**Private tables stay non-exposed:** this function is the intended access path Phase A always
described — a direct Postgres connection via `SUPABASE_DB_URL`, not a workaround for `private`
being unreachable through PostgREST. `private` is still not, and must not become, part of
`[api].schemas`.

**Architecture:** every piece of logic with a real decision to get right (HMAC/auth verification,
event parsing/classification, idempotent event-claim decisions, canonical-customer/alias
resolution, Pro calculation, RevenueCat API pagination/error classification) lives in
`supabase/functions/_shared/*.ts` as small, pure, dependency-injectable modules — each has a
co-located `*.test.ts` runnable under Node (`node --test supabase/functions/_shared/*.test.ts`),
independent of Deno, a live Postgres connection, or a live RevenueCat API. Only
`supabase/functions/_shared/database.ts` (Postgres access) and
`supabase/functions/revenuecat-webhook/index.ts` (the `Deno.serve` entry point) are
Deno-runtime-specific glue, deliberately kept thin, and were validated by static
review/type-checking only — see the Phase B1 final report for exactly how.

**Known limitations to close before Phase C deployment:**
- The exact RevenueCat API v2 response shape (`gives_access`, `entitlements.items[].lookup_key`,
  `ends_at`/`current_period_ends_at` field formats, pagination via `next_page`) was implemented
  from the task spec's description, not verified against a live API response or live
  documentation fetch (no internet access in the implementation environment) — re-verify before
  relying on it in production.
- `supabase/migrations/20260823062025_revenuecat_webhook_ledger_nullable_identity.sql` has not
  been applied to the live project.

## What comes next (Phase C and later)

1. **Phase C** — apply the Phase B1 migration to the live project; provision the four RevenueCat
   webhook secrets in Supabase's own secret management (`supabase secrets set`, never in this
   repo); deploy the Edge Function (`supabase functions deploy revenuecat-webhook`); configure the
   webhook URL + Authorization header value in the RevenueCat dashboard.
2. **Phase D** — sandbox webhook validation against the deployed function: purchase → active,
   expiration → inactive, renewal → active, plus a RevenueCat-dashboard-triggered `TEST` event to
   confirm auth/HMAC/delivery independent of any real customer data.
3. Installation identity, push-device registration, and Station Price Alerts backend/UI — all
   later, all depending on Phase C–D being green first.

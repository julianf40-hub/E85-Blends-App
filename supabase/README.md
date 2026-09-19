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
future task is deliberately, narrowly scoped to touch them, exactly as the two
`community_stations_*` migrations below were.

**Historical note, corrected 2026-09-03:** an earlier pass at this file claimed a live `INSERT`
RLS-policy-vs-table-privilege discrepancy (RLS allows `anon` INSERT, but the table privilege
doesn't) on both tables. That was a misreading of `information_schema.role_table_grants`, which
only shows table-wide grants and misses the column-scoped grants both tables actually use — INSERT
worked correctly on both tables the whole time. The **real** issue, found and fixed afterward, was
narrower: `community_stations`' upsert path (`CommunityPriceService.upsertCommunityStation`,
`Prefer: resolution=merge-duplicates` → `INSERT ... ON CONFLICT (normalized_key) DO UPDATE`)
required UPDATE privilege that `anon`/`authenticated` never had. The client now sends
`Prefer: resolution=ignore-duplicates` (`... DO NOTHING`, INSERT-only) instead, so no anonymous
UPDATE capability is needed or granted on `community_stations` — see
`community_stations_allow_public_upsert_update` and `community_stations_revoke_anon_update` in
`supabase/migrations/`, and `docs/PRE_RELEASE_SUPABASE_CHECKLIST.md` for the full verification
record. `e85_price_reports` was never affected — its INSERT-only path worked correctly throughout.
Any further change to either table's schema, RLS, or grants remains a separate, explicitly-scoped
follow-up, not something a future RevenueCat-entitlement (or other) migration should incidentally
touch.

## RevenueCat entitlement tables are private and server-only

`20260823060735_revenuecat_entitlement_foundation.sql` adds a **new, non-exposed `private`
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

`20260823060735_revenuecat_entitlement_foundation.sql` (checked in under this, its authoritative
live version number — see `MIGRATION_RECOVERY.md`; earlier revisions of this file cited it under a
stale local-only timestamp) has been reviewed AND applied to the live project
(`private.revenuecat_customers`, `private.revenuecat_aliases`, `private.revenuecat_webhook_events`,
`private.set_updated_at()` all exist live, RLS enabled, zero client policies, zero
`anon`/`authenticated` privileges). A second, additive migration,
`20260823073614_revenuecat_webhook_ledger_nullable_identity.sql`, relaxes the ledger's
`app_user_id`/`environment` columns to nullable (see that migration file's own header for why —
short version: `TRANSFER` and `TEMPORARY_ENTITLEMENT_GRANT` events don't carry those fields the
same way a normal purchase/renewal/expiration event does, and the ledger must not fabricate values
to satisfy a constraint that assumed every event looks like the latter). **Confirmed applied to the
live project** (`list_migrations` against `zefkbtscieokkdenvnkg`, re-verified 2026-09-19, as part of
85Blends 2.4.0's referral foundation work) — corrected here; an earlier revision of this file said
it had not been, which was accurate when written but is stale now.

## Phase B1 — RevenueCat webhook Edge Function (source deployed live)

`supabase/functions/revenuecat-webhook/` and `supabase/functions/_shared/` implement the webhook
receiver described below. **Confirmed deployed and ACTIVE on the live project** (`slug
"revenuecat-webhook"`, version 6, re-verified via `list_edge_functions` against `zefkbtscieokkdenvnkg`
on 2026-09-19, as part of 85Blends 2.4.0's referral foundation work) — corrected here; earlier
revisions of this file and of `index.ts`'s own header said "source only, NOT deployed," which was
accurate when Phase B1 completed but is stale now. Nothing in *this* implementation environment has
ever run this file against a live Deno runtime, deployed it, or observed a real RevenueCat delivery
first-hand — someone deployed the version now live outside any process this repository's own git
history records (see "Migration ledger and deployed-function drift beyond this repo's tracked
history" below) — so treat "it's live" as a confirmed fact and "it behaves correctly against real
traffic" as still only as validated as the Phase B1 final report and each module's own
`*.test.ts` describe.

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

**Known limitations:**
- The exact RevenueCat API v2 response shape (`gives_access`, `entitlements.items[].lookup_key`,
  `ends_at`/`current_period_ends_at` field formats, pagination via `next_page`) was implemented
  from the task spec's description, not verified against a live API response or live
  documentation fetch in the Phase B1 implementation environment — re-verify against real traffic
  if it hasn't been already.
- `supabase/migrations/20260823073614_revenuecat_webhook_ledger_nullable_identity.sql` — see
  "Phase A schema status" above; confirmed applied, not a remaining limitation.

## Referral paid-qualification + repeatable milestone foundation (85Blends 2.4.0)

Backend-only foundation for referral rewards: every 5 qualified PAID referrals earns one
`reward_type = 'one_month_pro'` reward, repeatable forever. Builds on the four
`private.referral_*` tables `20260910000000_referral_backend_baseline.sql` describes (see that
file and "Migration ledger and deployed-function drift" above for why that migration itself is a
synthetic reconstruction, not something applied here) — confirmed live, empty (zero rows in all
four tables), with `private.generate_referral_code`/`create_or_get_referral_participant`/
`apply_referral_code` also already live, granted only to `service_role`/`postgres`, exactly like
the RevenueCat tables above.

`supabase/migrations/20260919150000_referral_paid_qualification_foundation.sql` (in this
repository, **NOT applied to the live project**) adds, purely additively:
- A fix for a real, confirmed bug in `create_or_get_referral_participant`: it could silently
  no-op — no error, no signal — when an alias was already attached to a different participant.
- `qualifying_transaction_id` / `qualifying_original_transaction_id` (unique) /
  `qualifying_environment` on `private.referral_attributions`, so a later refund reverses the
  correct purchase.
- `private.process_referral_subscription_event(...)`, a single `service_role`-only function that
  atomically qualifies a paid referral (INITIAL_PURCHASE, PRODUCTION, `period_type = NORMAL`, one
  of the three current paid product IDs, attribution applied before purchase, canonical RevenueCat
  confirmation required), reverses it on a `CUSTOMER_SUPPORT`-reasoned refund matching the
  original transaction, restores it on a matching `REFUND_REVERSED`, and reconciles
  `private.referral_rewards` milestones (`floor(qualified_count / 5)`) inside the same transaction.

`supabase/functions/_shared/referral-classification.ts` / `referral-milestones.ts` hold the pure,
Node-tested decision logic (event classification, the milestone formula); `database.ts`/`index.ts`
call the new database function from inside the SAME transaction the existing entitlement mirror
already uses, reusing that same canonical RevenueCat refresh — no second RevenueCat API call.

**Deployment ordering matters here specifically:** the migration must be applied to the live
project BEFORE this revision of `revenuecat-webhook`/`database.ts` is ever deployed. Deploying the
code first would make every INITIAL_PURCHASE/CANCELLATION/REFUND_REVERSED event try to call a
function that doesn't exist yet — `applyReferralAction` in `database.ts` specifically detects that
(Postgres `42883`/`42P01`) and degrades to a clean skip rather than rolling back the entitlement
mirror, but that is a safety net for an ordering mistake, not a substitute for applying the
migration first.

Explicitly not built yet (next phase, not this one): the client bridge (installation identity,
referral-code entry UI, a client-facing Edge Function) and Apple promotional-offer reward
redemption. `referral_rewards.status = 'fulfilled'` stays reserved for that future system — nothing
in this foundation ever sets it.

## What comes next

Phase C (apply the Phase B1 migrations, provision secrets, deploy the Edge Function, configure the
RevenueCat dashboard webhook) and Phase D (sandbox validation) are described in the Phase B1 final
report as the next steps *at the time that report was written*. Live inspection during 85Blends
2.4.0's referral foundation work confirms Phase C's deployment steps have since happened — the
function is live (see above) — but this repository has no record of Phase D's sandbox validation
having been performed or its results, and no reason to assume it has. Before trusting this function
against real production traffic, confirm Phase D was actually done (or do it) rather than assuming
deployed implies validated.

Next for the referral system specifically: a client bridge (installation identity, Keychain,
referral-code entry UI, a client-facing Edge Function) and Apple promotional-offer reward
redemption — both explicitly out of scope for 85Blends 2.4.0's referral paid-qualification
foundation (see that report) and not started.

## Migration ledger and deployed-function drift beyond this repo's tracked history

Re-verified live on 2026-09-19 (85Blends 2.4.0 referral foundation work), beyond what
`MIGRATION_RECOVERY.md` already documents (that file covers only the two synthetic baseline
versions missing from the live ledger): the live project's migration ledger
(`supabase_migrations.schema_migrations`, 27 versions as of this check) also contains **11
migrations with no corresponding file anywhere in this repository's git history, on any branch** —
`20260917231933_harden_community_report_insert_grants` through
`20260918001857_community_report_rate_limit_role_fix` (the full list is in the referral
foundation report). None of their SQL text mentions anything referral-related (checked directly
against `supabase_migrations.schema_migrations.statements`) — by name and content they appear to
be Price Alerts backend work and Community Report rate-limiting hardening, applied directly to the
live project without ever being committed here. Consistent with that: `list_edge_functions` shows
two live, ACTIVE Edge Functions — `price-alerts-api` (version 2) and `price-alerts-worker` (version
1, `verify_jwt: true`) — with no corresponding `supabase/functions/` source anywhere in this
repository either.

This is a real gap in what this repository can tell you about the live project's actual state, not
something the referral foundation work caused or has attempted to fix. Nothing here was applied,
altered, or reconciled as part of that work — read-only live inspection only, per that task's own
constraints.

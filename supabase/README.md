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
history records (see "Migration history: reconciled. Edge Function source drift: still real."
below) — so treat "it's live" as a confirmed fact and "it behaves correctly against real
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
`private.referral_*` tables `20260910000000_referral_backend_baseline.sql` describes — originally a
synthetic reconstruction (see `MIGRATION_RECOVERY.md`), since corrected to also include the three
`private.referral_*` helper functions this foundation itself calls, and now tracked in production's
migration history via `migration repair --status applied` (tracking-only, no schema change —
completed as part of PR #79's migration-history reconciliation, merged into `main`) — with
`private.generate_referral_code`/`create_or_get_referral_participant`/`apply_referral_code` also
live, granted only to `service_role`/`postgres`, exactly like the RevenueCat tables above.

`supabase/migrations/20260919150000_referral_paid_qualification_foundation.sql` — **live on the
production project** (applied and verified) — adds, purely additively:
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

**Deployment ordering mattered here specifically:** the migration had to be applied to the live
project BEFORE this revision of `revenuecat-webhook`/`database.ts` was ever deployed, which is the
order that was followed — deploying the code first would have made every
INITIAL_PURCHASE/CANCELLATION/REFUND_REVERSED event try to call a function that didn't exist yet.
`applyReferralAction` in `database.ts` still specifically detects that case (Postgres
`42883`/`42P01`) and degrades to a clean skip rather than rolling back the entitlement mirror, but
that guard is a safety net for an ordering mistake, not a sign one occurred here.

Explicitly not built by this foundation: Apple promotional-offer reward redemption.
`referral_rewards.status = 'fulfilled'` stays reserved for that future system — nothing here ever
sets it. The client-facing half — installation identity/credentials, applying someone else's code,
and reading referral progress — is the **Referral client API**, described in its own section below
(85Blends 2.4.0, backend-only; iOS UI is a separate, later phase).

## Referral client API (85Blends 2.4.0)

`supabase/functions/referral-api` is the **only** path the iOS app is ever allowed to use to reach
the `private.referral_*` foundation described above — none of those tables/functions are exposed
through PostgREST, and the app must never hold a service-role credential. Client source
(installation identity/Keychain storage, referral-code entry UI) is a separate, later phase and is
**not** part of this backend addition.

**Custom auth model** — mirrors the pattern already established for Station Price Alerts
(`private.price_alert_installations`): `verify_jwt = false` (85Blends does not use Supabase Auth
sessions), replaced by two independent checks on every request — (1) a valid client-safe Supabase
API key (a modern publishable key from `SUPABASE_PUBLISHABLE_KEYS`, and/or the legacy
`SUPABASE_ANON_KEY` — either works, both already ship in the iOS app), and (2) a valid
`(client_installation_id, installation_secret)` pair. These two checks are not equivalent: the API
key is a **public, project-scoped credential** — a first-gate routing/project-identity check, never
app attestation and never proof of a human/user — while the per-installation secret is the actual
**possession credential** that identifies a specific installation. Only `SHA-256(secret)` is ever
stored (`private.referral_client_installations`, `installation_secret_hash` `check`ed to look like
one, secret itself bounded to 32–512 characters); the raw secret is never logged or returned. An
existing installation's secret can never be replaced by a different one — a mismatched secret
against a known `client_installation_id` is a flat `401`, never a silent takeover, enforced
authoritatively inside the bootstrap transaction (not merely a pre-transaction check, which is a
fast-path optimization only) — see `private.create_or_get_referral_participant`'s own concurrency
fix below for why the transactional guarantee matters. Both new tables
(`referral_client_installations`, and `referral_apply_attempts` backing a per-installation
apply-code rate limit) are RLS-enabled, zero-policy, `service_role`-only — no `anon`/`authenticated`
grant, same as every other `private.referral_*` object.

**Concurrency fix — `private.create_or_get_referral_participant`.** Building this client API
exposed the first genuinely concurrent caller of this function (two near-simultaneous bootstrap
requests for the same brand-new installation) — every earlier caller only ever reached it one
already-existing installation at a time. Reproduced with two real concurrent Postgres connections
(not merely sequential statements): the loser's insert failed with a raw, uncaught
`unique_violation` on `installation_id` instead of gracefully returning the participant the winner
had just created. Fixed via `insert ... on conflict (installation_id) do nothing returning ...`,
which absorbs that specific race entirely (a losing transaction picks up the winner's row instead
of retrying a doomed insert) while still retrying on a genuine `referral_code` collision, exactly
as before. Re-verified under the identical concurrent-connection test: both requests now succeed,
return the same participant, and exactly one row is ever created. `referral-api`'s own bootstrap
transaction was hardened the same way — the `created` flag and `app_version` handling are now
transaction-authoritative rather than based on a pre-transaction read, so a losing
same-secret request never "loses" its `app_version`, and a losing different-secret request leaves
zero persisted mutation (participant/alias/credential/`app_version` alike) via transaction
rollback. Signature, return shape, language, `search_path`, and grants are all unchanged —
reverified directly, not assumed.

**Actions** (single POST-only endpoint, JSON body with `action`):
- `bootstrap` — create-or-get this installation's referral participant/code, bind it to the
  caller's current RevenueCat app-user identity, and issue/verify its credential. Safe to call
  again later (e.g. after a RevenueCat identity change) — a new alias can attach to the same
  participant, but an alias already bound to a *different* participant fails closed
  (`409 revenuecat_identity_conflict`), it is never silently reassigned.
- `status` — this installation's own referral/reward progress. Never returns participant/
  attribution/reward UUIDs, another installation's identity, or any RevenueCat identifier —
  only counts, this installation's own referral code, and its own attribution status.
- `apply_code` — apply someone else's referral code, once, ever. Immutable: there is no
  remove/replace endpoint, and a second *different* code after one is already attached is a hard
  `409`, regardless of that attribution's current status (pending/qualified/reversed/
  disqualified). The database's own `private.apply_referral_code` remains the sole authority for
  self-referral/format/existence checks — this endpoint only adds safe UX-level pre-checks and
  idempotent re-application of the *same* code.

Next-milestone progress (`next_milestone_number`/`next_reward_at`/`referrals_needed`) is computed
from reward **history**, not `qualified_count % 5` — a fulfilled milestone is never clawed back
(see the foundation above), so the next target is always the first milestone after the highest one
ever earned or fulfilled, skipping past any milestone that was only ever `revoked`. Computed
server-side (`_shared/referral-milestones.ts`'s `computeNextMilestoneProgress`) so the iOS client
never duplicates this rule.

**Reward redemption is out of scope here**, same as the foundation above — this API only ever
*reads* `private.referral_rewards`; it never sets `status = 'fulfilled'`, never touches RevenueCat
entitlements, and never grants Pro.

**Deployment order** (none of these steps have happened yet as of this addition):
1. merge this source to `main`
2. apply the new `referral_client_api_foundation` migration to production
3. verify the new tables/grants live
4. deploy `referral-api`
5. verify the endpoint against production
6. only then wire/ship the iOS client

## What comes next

Phase C (apply the Phase B1 migrations, provision secrets, deploy the Edge Function, configure the
RevenueCat dashboard webhook) and Phase D (sandbox validation) are described in the Phase B1 final
report as the next steps *at the time that report was written*. Live inspection during 85Blends
2.4.0's referral foundation work confirms Phase C's deployment steps have since happened — the
function is live (see above) — but this repository has no record of Phase D's sandbox validation
having been performed or its results, and no reason to assume it has. Before trusting this function
against real production traffic, confirm Phase D was actually done (or do it) rather than assuming
deployed implies validated.

Next for the referral system specifically: the client-facing Edge Function now exists (see
"Referral client API" above), but installation identity/Keychain storage and referral-code entry
UI on the iOS side, plus Apple promotional-offer reward redemption, remain not started.

## Migration history: reconciled. Edge Function source drift: still real.

**Migration-history reconciliation is COMPLETE** (PR #79, merged into `main` 2026-09-19). The 11
migrations this section previously described as untracked —
`20260917231933_harden_community_report_insert_grants` through
`20260918001857_community_report_rate_limit_role_fix` — were recovered verbatim from the live
ledger's `supabase_migrations.schema_migrations.statements` and are now committed in
`supabase/migrations/`, on `main`. Production's migration ledger is now aligned **29/29** with
`main`, including both previously-synthetic baselines: `20260427000000` and the corrected
`20260910000000` are both tracked via `migration repair --status applied` (tracking-only, no
schema change). See `MIGRATION_RECOVERY.md` for the full recovery and reconciliation record.
`20260919150000_referral_paid_qualification_foundation.sql` — validated by repeated local replay
before being applied — is now also live on production, bringing the ledger to **30/30**. This
revision adds one further migration, `referral_client_api_foundation` (see "Referral client API"
above), not yet applied as of this addition.

**Edge Function source drift remains real and unresolved.** `list_edge_functions` shows two live,
ACTIVE Edge Functions — `price-alerts-api` (version 2) and `price-alerts-worker` (version 1,
`verify_jwt: true`) — with no corresponding `supabase/functions/` source anywhere in this
repository. This is a real gap in what this repository can tell you about the live project's
actual state, not something any of the referral-foundation or migration-reconciliation work caused
or has attempted to fix.

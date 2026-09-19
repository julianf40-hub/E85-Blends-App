# Supabase Migration History Recovery

**This branch is migration-history recovery only.** It reconstructs `supabase/migrations/` so
this repository's checked-in history matches what has actually been applied to the live project.
It contains no application code, no feature work, and no changes outside `supabase/migrations/`
and this file.

## Status

- **Passed a real empty-database replay on September 15, 2026.** The exact branch commit
  `dcf99138b573afc06b85a1ac5c2feb22b2dbd351` was cloned into a disposable checkout on macOS
  27.0 (`arm64`) and tested with Supabase CLI 2.117.0, Docker client 29.8.0, Docker server 29.5.2,
  and Colima 0.10.3. `supabase start --yes` applied all 17 migrations successfully, followed by a
  separate `supabase db reset --local --no-seed --yes` that recreated the local database and
  applied all 17 migrations successfully a second time.
- **The empty-database replay merge gate is satisfied.** Local migration history contained all 17
  expected versions in order. Catalog checks found all 15 application tables with RLS enabled,
  the expected five public policies, eight application triggers, two private helper functions,
  constraints, indexes, role grants, and working `gen_random_uuid()`. `supabase db lint` found no
  schema errors. `supabase db advisors` reported one warning for the intentionally unrestricted
  `Public can insert community stations` policy documented by the founding baseline; it was not a
  replay error or newly introduced drift.
- No seed file exists, so both replays ran without application seed data. The local stack, data
  volumes, container VM/images, temporary checkout, and test-only tooling were removed after
  verification.
- No `supabase db push`, no `supabase migration repair`, and no other live database mutation has
  occurred as part of producing or replaying this branch. Nothing here has touched the live
  project.

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

## 2026-09-19 update — 11 further migrations recovered, drift found beyond this document's scope

Performed as a separate, dedicated, read-only reconciliation task (`audit/supabase-migration-reconciliation`,
branched from `main` at `178af463c17df9500b3e5c6be6e764b9f15f8e3a`), independent of and in addition to
the work this file otherwise documents. **No live database or migration-ledger write of any kind was
performed to produce this update** — every fact below was obtained via read-only SQL
(`supabase_migrations.schema_migrations`, `information_schema`, `pg_catalog`) and `list_migrations`/
`list_edge_functions` against project `zefkbtscieokkdenvnkg`.

**Finding: this document's own account of drift was incomplete.** Re-querying the live ledger on
2026-09-19 found 27 applied versions, not the 17 this file's "empty-database replay" section describes.
The 11 versions beyond this file's own list —

```
20260917231933_harden_community_report_insert_grants
20260917232104_price_alert_worker_primitives
20260917232144_price_alert_prepare_deliveries
20260918000854_price_alert_delivery_lifecycle
20260918000954_harden_community_report_time_and_shape
20260918001235_fix_price_alert_prepare_deliveries
20260918001318_simplify_price_alert_delivery_candidates
20260918001525_price_alert_delivery_claim_payload
20260918001657_price_alert_job_processor_cron
20260918001839_community_report_soft_rate_limits
20260918001857_community_report_rate_limit_role_fix
```

— were applied to production **after** this document's own September 15 replay (their own recorded
timestamps are September 17–18), so their absence here isn't an oversight of the original recovery
work; they didn't exist yet when it ran. They are Price Alerts backend work (worker primitives,
delivery lifecycle, claim/dispatch payload shaping, a `pg_cron` job — `85blends-price-alert-job-prepare`,
scheduled every minute and **currently running live**) and Community Report hardening (grant scoping,
time/shape validation, soft rate limits with a role-check fix). None mention anything referral-related.
Like the two synthetic baselines this file already tracks, none of these 11 exist anywhere in this
repository's git history on any branch — confirmed via `git log --all --diff-filter=A` and
`git grep` across every ref (`git rev-list --all`), not merely a `find` on the working tree.

**Recovery method — an upgrade over this file's own "byte-for-byte from the live ledger" claim for
its 13 migrations.** Rather than trusting a SHA-256 digest match alone, every one of the 11 files
recovered this pass was retrieved by directly reading
`supabase_migrations.schema_migrations.statements` (a `text[]` column Postgres/Supabase populates
with the exact SQL text of each applied migration) for that exact version, via read-only
`array_to_string(statements, …)`. This was independently validated before trusting it for the 11
unknowns: the same query against `20260909101257` (a version this file already lists as recovered)
returned text that matches the corresponding local file byte-for-byte. All 11 new files carry a
`RECOVERED HISTORICAL MIGRATION` header (not `SYNTHETIC RECONSTRUCTION` — that label is reserved for
the two baselines, which genuinely are reconstructed from catalog state, not retrieved verbatim) and
are placed under their own live version numbers — no repair needed for any of them, for the same
reason this file's own 13 need none.

**Referral baseline (`20260910000000`) re-confirmed, not newly contradicted.** Searching all 27 live
migrations' `statements` text for "referral" found exactly one hit: a comment inside
`20260910212848_price_alert_backend_foundation` — `"Reuse the existing private.set_updated_at()
trigger helper used by the RevenueCat/referral backend."` — not a table or function creation. This is
the exact fact this repository's synthetic referral baseline already claimed; today's pass independently
re-derives it rather than taking it on faith. All four `private.referral_*` tables and all three
`private.referral_*` functions were re-verified live on 2026-09-19 (columns, constraints, indexes,
grants, RLS, and full function bodies) and still match what is live today; all four tables are
still empty (0 rows — no referral activity has ever occurred, consistent with no client existing yet).
**Correction, same day, after an executed replay (see the dated section near the end of this file):**
"match the baseline file" above described the three functions' *live* definitions, not this file's
contents — the file itself did not yet define any of the three at the time this paragraph was written.
That gap was only caught once this baseline was actually replayed against an empty database instead of
only being compared column-by-column against live catalog metadata. Corrected below.

**Community pricing baseline (`20260427000000`) re-verified against CURRENT live schema, not just
schema as of this baseline's own authoring.** `public.community_stations`/`public.e85_price_reports`
column shapes re-checked live on 2026-09-19 and still match this file's `20260427000000` migration
exactly. One thing worth flagging: that migration's own comment on the `"Public can insert price
reports"` policy — *"No recorded migration creates this — must be founding... Consumed by: nothing
later alters it; this is the live definition today, unchanged"* — was accurate when written but is now
incomplete: two of the 11 newly-recovered migrations (`20260917231933`, then `20260918000954`) each
`drop policy if exists` and recreate that exact policy with a tightening `with_check`. The live
`with_check` today is what `20260918000954` sets, not the founding one. This is not a replay-order
problem — every later migration correctly guards its `DROP POLICY` with `IF EXISTS`, so replaying
`20260427000000` through the full 27-migration chain in order still converges on the correct
current-live policy — it is only that `20260427000000`'s own comment, taken in isolation, now
undersells how much later history touches what it created. Left as-is (not edited) since it was an
accurate statement of the world as it was reviewed at the time; documented here instead.

**Local-vs-remote correspondence after this update: complete.** All 27 live-applied versions now have
an exact local file under the same version number; the only two local files without a live ledger
counterpart are `20260427000000` and `20260910000000`, both pre-existing, both already documented
above and in each file's own header as pending the same repair gate this document already describes.

**Edge Function drift, found while re-verifying `revenuecat-webhook`'s deployment status (not itself a
migration concern, recorded here for completeness):** `list_edge_functions` shows three live, ACTIVE
functions — `revenuecat-webhook` (version 6), `price-alerts-api` (version 2), `price-alerts-worker`
(version 1, `verify_jwt: true`) — consistent with the Price Alerts migrations above. Only
`revenuecat-webhook` has corresponding source in this repository (`supabase/functions/revenuecat-webhook/`);
`price-alerts-api`/`price-alerts-worker` have none, on any branch.

**Nothing above changes this document's own repair recommendation or its gate.** `supabase migration
repair --status applied 20260910000000` (and, separately, `20260427000000`) remains the eventual,
explicitly-authorized-only next step for the two baselines — still not performed, still gated on a
successful empty-database replay of the now-29-file sequence first. The 11 newly-recovered files need
no repair at all, for the same structural reason the original 13 don't: they already exist in the live
ledger under these exact version numbers, so adding them here only makes Git match what Supabase
already records.

**Static reproducibility check performed this pass — not a replay.** Two independent, read-only
static reviews of all 29 files (in filename/timestamp order) found no fresh-database ordering defect:
every table, column, function, trigger, and extension a later migration depends on is created by a
strictly earlier one (traced explicitly, including the three successive `create or replace` revisions
of `private.prepare_price_alert_deliveries` and the `pg_cron` extension-then-`cron.schedule` ordering
within `20260918001657`), and no `drop` anywhere in the set is missing its `if exists` guard. This is
**static text analysis only, not an executed replay** — no Docker/local Postgres was available this
pass. It does not satisfy the empty-database replay gate above; that gate stays open until a real
replay of the full 29-file sequence runs, exactly as this document already says.

**Referral qualification PR remains blocked on this reconciliation.** PR #78 ("Add referral
paid-qualification and milestone foundation") is explicitly held in draft pending this migration-history
reconciliation, among its own other gates, and is untouched by this update — no commit, rebase, or merge
of any kind. See that PR's own description for its full blocker list.

## 2026-09-19 update (continued) — executed fresh-database replay, referral baseline corrected

The static-only check described above (two independent read-only reviews, no ordering defect found)
has now been superseded by an **actually executed** empty-database replay, closing the gate the rest of
this document has left open since September 15. Tooling: Supabase CLI 2.117.0, Docker 29.3.1, local
Postgres/Supabase image major version 17 (matching production's own major version) — project label
`eightyfiveblends`. **Two independent replays, each from a genuinely fresh state** (`supabase stop
--no-backup` removing every local container and volume before each `supabase start`, not a reset on
top of an already-migrated database): both applied **all 29 files, in order, 29/29, with zero SQL
errors**. The only warning either run produced — `no files matched pattern: supabase/seed.sql` — is
benign and expected; this repository has no seed file, as this document's September 15 section already
notes.

**The first replay exposed a real gap, not a false pass.** Comparing the resulting local schema against
production found `private.generate_referral_code`, `private.create_or_get_referral_participant`, and
`private.apply_referral_code` — three helper functions this document's own text above says were
"re-verified live" — **completely absent** from the replayed database: not merely different, never
created. Confirmed two ways: `grep` across every `.sql` file in `supabase/migrations/` for all three
names (zero matches, any file) and a direct `pg_proc` query against the fresh local database (zero
rows). The synthetic referral baseline (`20260910000000_referral_backend_baseline.sql`) had correctly
reconstructed the four `private.referral_*` tables — this document's live-schema comparisons of *those*
were accurate — but never reconstructed these three functions, which, like the tables, predate every
tracked migration and are created nowhere in this repository's history.

**Fix applied to that same file, then re-verified, not taken on faith.** All three function bodies were
retrieved via `pg_get_functiondef(oid)` against the live project and appended to
`20260910000000_referral_backend_baseline.sql`, re-styled only to this repository's lowercase-keyword
SQL convention (a cosmetic transform Postgres treats identically to the canonical uppercase form
`pg_get_functiondef` returns — no logic, identifier, or literal changed). Grants were set to match the
live grantee set exactly (`information_schema.routine_privileges`): `postgres` (owner) and
`service_role` only, via explicit `revoke ... from public, anon, authenticated` followed by
`grant ... to postgres, service_role` for each function — the same pattern every other private-schema
function in this project already uses. **After the fix, a second fresh replay (from another genuinely
empty state) re-confirmed 29/29 applied, and both the function bodies and their grants matched
production exactly** — verified twice: once via direct comparison against the local replay, and again
via a fresh, independent read-only re-query of production run specifically to confirm this write-up.
`anon`, `authenticated`, and `PUBLIC` hold no execute privilege on any of the three, matching production
exactly; the fix grants no access beyond what already exists live.

One intentional non-correction: `create_or_get_referral_participant`'s `on conflict ... do update ...
where ...` clause silently no-ops (no error) when an alias already belongs to a different participant.
This is reproduced exactly as it exists live, not fixed here — it is the same known issue PR #78's
`20260919150000` migration (not part of this branch) separately corrects going forward with an
insert-then-verify pattern. Faithfully reconstructing the pre-fix historical behavior in this baseline
is the point; fixing it is that other migration's job, not this document's.

**Final schema comparison result: functionally EXACT**, across columns, RLS enablement, policies
(including the final hardened `"Public can insert price reports"`/`"Public can insert ethanol reports"`
with_check clauses), indexes, triggers, all 16 `private`-schema function definitions, installed
extensions (`pg_cron` lands in `pg_catalog` locally too, matching production's own placement exactly —
not the `extensions` schema the migration text requests, which is Supabase's own platform behavior, not
drift), and the live `85blends-price-alert-job-prepare` cron job (schedule, command, and active state
all match).

**One difference remains, environment-only and harmless, left uncorrected.** Locally,
`public.community_stations` and `public.e85_price_reports` carry ten extra table-level grant rows for
`anon`/`authenticated` (DELETE/REFERENCES/TRIGGER/TRUNCATE/UPDATE) that production does not have.
Root-caused, not just observed: these are Postgres/Supabase's own default public-schema privileges,
auto-applied when a table is created, that the founding baseline (`20260427000000`) never explicitly
revokes — unlike the two later report-table migrations (`20260909101353_secure_e85_analytics_events`,
`20260917150403_community_ethanol_reports`), which each defensively `revoke all ... from public, anon,
authenticated` before granting narrowly (the ethanol migration's own comment: *"Existing Supabase
projects can still apply default public-schema privileges automatically. Start from an explicit deny
state..."*). Because RLS is enabled on both tables with only INSERT and SELECT policies defined for
`anon`/`authenticated` — no UPDATE, DELETE, TRUNCATE, TRIGGER, or REFERENCES policy exists for those
roles on either table — none of the ten extra grant rows can actually be exercised: RLS blocks every
one of those operations regardless of the underlying GRANT. No migration change was made for this
difference; it has no functional or security effect.

**Repair readiness, updated:**

- `20260427000000` — schema effect already verified live; now also proven by two independent clean
  replays. **Ready for `supabase migration repair --status applied 20260427000000`, pending explicit
  authorization. Not executed.**
- `20260910000000` — was **not** repair-ready before this update (the baseline was schema-incomplete).
  With the fix above applied, it is now held to the same standard and **ready for
  `supabase migration repair --status applied 20260910000000`, pending explicit authorization. Not
  executed.**

Neither command has been run. No `supabase db push`, no Edge Function deployment, and no write of any
kind reached production while producing this update — every production fact above came from read-only
SQL and read-only Supabase API calls.

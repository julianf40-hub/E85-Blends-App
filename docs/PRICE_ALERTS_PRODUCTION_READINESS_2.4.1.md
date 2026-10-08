# Price Alerts Phase 3C — production readiness, rollout, incident and rollback plan (2.4.1, Phase 3C.1)

> **Status: a PLAN. Nothing in this document has been run against production.** No migration applied, no Edge Function
> deployed, no cron job changed, no worker invoked, no APNs/FCM message sent, no production row read or written, no test
> report or alert created, no secret, entitlement, CloudKit schema, signing setting or Xcode Cloud workflow touched.
> Every step below needs the project owner's **explicit authorization for that step**; a green build, a merged branch or an
> urgent-sounding bug is not authorization. Any temporary scheduler pause (section 9) is likewise a separate, explicit
> decision made at the time.
>
> The evidence quoted here comes from `supabase/tests/price_alert_rollout_compat.test.sh`, which **builds** each intermediate
> state on throwaway local Postgres databases (Postgres 16.15, the migration chain replayed for real) and runs the **previous**
> Edge Functions (exported from git) and the **new** ones in them. The hosted project differs in ways a local replay cannot
> show (Postgres major version, hardware, the real Supabase CLI, real APNs/FCM); those are listed in section 14.

Companion documents: [`PRICE_ALERTS_PAYMENT_TYPES_2.4.1.md`](PRICE_ALERTS_PAYMENT_TYPES_2.4.1.md) (what the change is and how an
alert decides), [`PRICE_ALERTS_CLIENT_INTEGRATION_2.4.1.md`](PRICE_ALERTS_CLIENT_INTEGRATION_2.4.1.md) (the API contract),
`supabase/functions/PRICE_ALERTS_SCHEDULER.md` (how the scheduler was activated; its migration procedure is reused below),
`supabase/functions/PRICE_ALERTS_RECOVERY.md` (the recorded source of the deployed functions).

## 1. Rules of engagement

1. **One step, one authorization.** Do not chain steps. After each step, run its verification and stop at the first mismatch.
2. **Read-only first.** Section 4 is the only thing that may run before anything changes, and even it needs a go-ahead.
3. **Never apply the promo migration.** `supabase/migrations/20260921000000_promo_campaign_foundation.sql` is intentionally not
   applied in production and must stay that way. A plain `supabase db push` or `--include-all` against the repository would try to
   apply it. Use the controlled procedure in section 7 (a temporary deployment copy without it, and a dry run that must list
   **exactly** migrations A and B).
4. **Never revert the engine to the previous comparison once typed reports exist.** The previous `prepare_price_alert_deliveries`
   compares a report with the previous report of any payment type — the false alert this phase removes. The fail-closed move is to
   **pause** (section 9), not to roll back.
5. **Keep Price Alerts separate** from report submission, RevenueCat, Referral, the growth jobs and every unrelated cron job
   (section 12). A Price Alerts incident never justifies touching those.
6. **Production iOS and Android releases are out of scope here.** The default is Internal builds only (`CLAUDE.md`); a production
   archive needs the owner's exact words "prepare production release".

## 2. What exists today

| Item | Repository (branch `claude/price-alerts-phase-3a-ohk92b`) | Production (owner-reported; **not re-verified here**) |
|---|---|---|
| Migration A `20261007120000_community_price_payment_type` | written, tested locally | **not applied** |
| Migration B `20261007130000_price_alert_payment_aware_evaluation` | written, tested locally | **not applied** |
| `price-alerts-api` | new version (payment type, drop-size contract) | the previous version (hardened for Android registration) |
| `price-alerts-worker` | new version (copy names the price) | the previous version |
| Scheduler | unchanged | cron `85blends-price-alert-job-prepare` and `85blends-price-alerts-worker-invoke` **active**, every minute |
| Prerequisite migrations `20261005120000`, `20261005211547`, `20261005233000`, `20261006000000` | in the chain | applied |
| iOS | Phase 3C + 3C.1 on the branch; Xcode Cloud "85Blends Internal" Test – iOS reported SUCCESS for `ad02bf1` | the App Store build (2.4.0) has **no Price Alerts client at all**; only Internal TestFlight builds do |
| Android | no Android code in this repository | an Android app that can register devices and create alerts may exist; its wire behavior is not visible here |
| Price Alerts data | — | empty on 2026-10-06 (before the first real clients); **unknown now** — the preflight (section 4) answers it |

A consequence worth saying plainly: the number of real alerts in production is probably tiny, but that is a guess. The preflight
turns it into a fact (`alerts.by_platform`, `alerts.minimum_change_values`, `installations.by_platform_and_app_version`).

## 3. The dependency chain and what each change touches

**Required order of change: A → B → `price-alerts-api` → `price-alerts-worker` → iOS (Internal) → Android.**

| Change | Requires | Touches | Does not touch |
|---|---|---|---|
| **A** | nothing new | `public.e85_price_reports`: one column (`payment_type`, constant default `'unknown'`, NOT NULL, no table rewrite), one CHECK (added NOT VALID, then validated), `GRANT INSERT (payment_type)` to `anon, authenticated`, one index | RLS policies, the SELECT grant, the immutability of reports, triggers, any function, any cron job |
| **B** | A (it refuses to run without it); `claim_price_alert_deliveries_v2(integer,text)` and `price_alert_jobs_stuck_processing_idx` (the 2026-10-05/06 migrations) | `private.price_alerts` (+3 columns), `private.price_alert_deliveries` (+1 column), 3 CHECKs, 1 partial index, 7 new `private` functions, **replaces** `prepare_price_alert_deliveries` and `mark_price_alert_delivery_sent` (same signatures, same ACLs), 1 trigger, a one-time fill of the reference price of existing alerts | the claim functions, any cron job, any secret, any existing row's content except `baseline_price/baseline_at` of alerts that have a recent unclassified report |
| New API | **B** (its SQL names B's column and function) | `set_alert`, `list_alerts` | bootstrap, device registration, delete, status |
| New worker | nothing (reading B's column is fail-soft) | notification wording for Cash/Credit alerts, an additive payload key | claiming, sending, retry, Pro re-check, the scheduler |

Both migrations begin with `set lock_timeout = '3s'` and end with `reset lock_timeout`, and are idempotent (re-applying is a no-op;
`price_alert_payment_type_migration.test.sh` and scenario G1 prove it).

## 4. Read-only production preflight

Run `supabase/runbooks/price_alerts_3c_preflight_readonly.sql` — **one SELECT inside a `READ ONLY` transaction**, no side effects,
no secret and no personal data in its output (counts, object names, schedules, version strings). Save the full output with the
date, the project ref and the person who ran it; it is the "before" picture for every later comparison.

| What it establishes | Rows | Stop if |
|---|---|---|
| The target is the right project, Postgres version, extensions, the statement timeout of the client roles | `target.*` | the version is not recorded; `pg_cron`/`pg_net` missing |
| Migration history is what the plan assumes | `migrations.*` | A or B already present; any of the four prerequisites missing |
| Size of the reports table (how long A holds its lock) | `reports.rows`, `reports.total_size`, `reports.reports_last_24h` | (decision, not stop) see section 5 |
| The current client write path is as audited | `reports.insert_columns_*`, `reports.update_or_delete_grants_for_clients`, `reports.rls_enabled`, `reports.policies`, `reports.user_triggers` | the INSERT columns differ from the expected list; any UPDATE/DELETE grant; RLS off |
| Who actually uses Price Alerts | `alerts.*`, `installations.*`, `devices.*` | (decision) tells whether the older-client reset or Android legacy alerts affect anyone |
| The queue is empty enough for B | `jobs.by_status`, `jobs.oldest_not_completed_age`, `deliveries.*` | see section 6 |
| The scheduler is as reported | `cron.jobs`, `cron.price_alert_runs_last_24h`, `cron.price_alert_last_run_ago` | either Price Alerts job inactive or failing; unrelated jobs unexpectedly changed |
| What B will replace is recorded | `functions.prepare_md5`, `functions.mark_sent_md5`, `functions.engine_v2_exists` | `engine_v2_exists` is `yes` (B partly applied?) |
| The scheduler secrets exist (names only) | `vault.scheduler_secret_names` | missing |
| Nobody is holding locks on the tables | `activity.*` | long transactions or ungranted locks |

Two more read-only checks the SQL file cannot do (they are Supabase CLI/dashboard reads, also needing authorization):

* **Deployed Edge Function state:** version number, status ACTIVE, **`verify_jwt` flag** and the deployed source. The API must have
  `verify_jwt = false` (the iOS publishable key is not a JWT; a function deployed with the platform default of `true` rejects every
  app request). Compare the deployed source with the repository revision it came from using the hash helper (section 7, step 1).
* **Hourly shape of report submission** (to choose the window): `select extract(hour from created_at at time zone 'UTC') as hour_utc,
  count(*) from public.e85_price_reports where created_at > now() - interval '14 days' group by 1 order by 1;`

## 5. Snapshot, window and what the lock costs

**Record before the first change** (all from the preflight output): migration count and newest version; report row count; the cron
job list; the delivery and job counts by status; `functions.prepare_md5` and `functions.mark_sent_md5`; the INSERT column list;
the deployed function versions and `verify_jwt`; and the downloaded deployed sources (the rollback artifacts, section 7 step 1).

**Window.** Choose the quietest hour the report histogram shows. Both migrations go in **one push, seconds apart** (T1, section 8.1):
between A and B the previous engine is still running, and a typed report arriving in that gap can alert a legacy alert falsely.
Nothing sends typed reports until the iOS build ships (after B), so the exposure is the Internal TestFlight builds only — but there is
no reason to leave the gap open.

**What the locks cost** (local figures; hosted hardware differs):

| | Rows in `e85_price_reports` | Time | Effect |
|---|---|---|---|
| Migration A | 300,000 | 0.32 s | **reads and writes** of the reports table queue behind A's transaction: its first `ALTER TABLE` takes `ACCESS EXCLUSIVE`, which conflicts with every other lock, and the file is one transaction (A's own header says so). That includes the app reading community prices. |
| Migration A | 1,000,000 | 1.27 s | same; the dominant cost is validating the CHECK and building the index |
| Migration B | any | ~55 ms | the report insert's alert-enqueue trigger reads `private.price_alerts`, the worker's claim and the prepare job read the alert and delivery tables — all queue behind B's `ACCESS EXCLUSIVE` locks on those two tables |

A report submitted while a migration runs **waits and then succeeds** (T5: the test holds B's transaction open for 3 s *on purpose* so the
wait is measurable — the real B takes ~55 ms; the report waited 2.05 s, was stored, had its job queued once, and was decided by the new
engine). Supabase documents a default `statement_timeout` of 3 s for the `anon` role, which is the role the app's report insert uses; a wait
longer than the role's timeout surfaces to the app as a failed submission. The preflight row `target.client_role_statement_timeouts` records what
this project actually has. For a very large table the owner should decide whether to accept a window of a few seconds or build the index outside
the migration first. Both migrations give up after 3 s if they cannot get **their** lock (T4: 3.04 s, then nothing changed), so they can never
stall the table behind themselves.

## 6. The queue-drain requirement

**Apply B only when `private.price_alert_jobs` has no `pending`, `processing` or `failed` row**, and ideally no `pending`,
`processing` or `failed` delivery. Why (T3, executed): B's one-time fill anchors each legacy alert on its latest report. A report
whose job is still queued is then judged against **itself**, and its drop is lost — a missed notification, not a false one. The same
report processed first (the previous engine, before B) alerts normally.

How to get there: wait. The prepare cron runs every minute and reports arrive rarely; two or three quiet minutes empty it. Do **not**
force-complete jobs or delete deliveries to "drain" — if the queue does not empty on its own, that is a finding to understand first
(a stuck job is reclaimed after 15 minutes; a delivery whose report is more than 2 hours old is expired as stale at the next claim and is never sent late).

Deliveries that are already queued when B is applied are **left alone**: not re-evaluated, not re-sent, and a delivery queued by the previous
engine still holds its legacy alert's cooldown, so the first report after B cannot duplicate it (T2). The new worker delivers it in the
old wording.

## 7. The rollout, step by step

Each step lists the action, the check, and what to do if the check fails. **Stop at the first failed check.**

### Step 1 — Hash validation and the migration dry run (no change)

1. Download the deployed sources of both functions, read-only (needs authorization), e.g.
   `supabase functions download price-alerts-api --project-ref <ref> --use-api`, and the same for `price-alerts-worker`, into one
   directory with a sub-directory per function.
2. `bash supabase/runbooks/price_alerts_function_hashes.sh --rev <the revision the last deploy came from> --against <dir>`.
   The deployable files of both functions are byte-identical between `0f966ec` (the current `main`, which carries the deployed
   functions) and `1f88df0` (the Phase 3B tip); only two `.md` notes in `supabase/functions` differ, and the script does not compare
   notes. So either revision works for "the previous version". **Expected: `RESULT: every file matches`.** `DIFFER`, `MISSING` or
   `EXTRA` means production runs something other than what this plan assumes — stop and explain it. Keep the downloaded directory:
   **it is the rollback artifact** for the API and the worker.
3. Make a temporary deployment copy of `supabase/` (nothing is committed) **without**
   `supabase/migrations/20260921000000_promo_campaign_foundation.sql` (the only exclusion; no placeholder files, no
   `supabase migration repair`), and run `supabase db push --linked --include-all --dry-run --skip-vault` from it — the same command
   the 2.4.1 scheduler activation used (`PRICE_ALERTS_SCHEDULER.md`, "Exact migration procedure"). **The plan must list exactly
   `20261007120000_community_price_payment_type.sql` and `20261007130000_price_alert_payment_aware_evaluation.sql`.** Anything else —
   the promo migration, a growth migration, `20261005211547`, anything older — stop. `--include-all` is deliberate in the dry run:
   it makes the CLI show **every** local migration the remote history lacks, so a stray one cannot hide. `--skip-vault` keeps the push
   from ever touching Vault. (That procedure was verified with CLI 2.119.0 against a scratch database whose ledger mirrored production;
   it was **not** re-run in this phase, and CLI behavior may have changed since — the dry-run list is the check, not this sentence.)

### Step 2 — Confirm the preconditions

The preflight shows: A and B absent; the four prerequisites present; both Price Alerts jobs active and succeeding; the queue drained
(section 6); no long transactions; the window chosen. The owner authorizes Step 3.

### Step 3 — Apply A and B (one push)

The same command as the dry run, without `--dry-run` — `supabase db push --linked --include-all --skip-vault` — from the same temporary copy,
and only after the dry run listed exactly A and B. The CLI applies each file in its own implicit transaction and records its version only if
the whole file succeeded.

* **B reports `canceling statement due to lock timeout`:** nothing changed (T4). Re-run the push in a quieter minute. A will already be
  applied; the push applies only B.
* **A succeeded and B failed for any other reason:** see section 8.1.

### Step 4 — Verify the database (read-only)

Run `supabase/runbooks/price_alerts_3c_verify_after_readonly.sql` and compare with the preflight: the payment_type column and
validated CHECK, INSERT columns = the preflight list + `payment_type` only, no UPDATE/DELETE grants, policies unchanged, the index,
the three alert columns and the delivery column, three validated constraints, seven engine objects, the anchor trigger, **zero**
client-callable engine functions, `B.prepare_md5` and `B.mark_sent_md5` **different** from the preflight values, every existing alert
`unknown`, deliveries untouched (0 typed), cron jobs exactly as before. Any mismatch: section 8.

### Step 5 — Deploy `price-alerts-api` (only after Step 4 passes)

**Precondition about Android's JSON decoder (cannot be checked from this repository).** The new API *adds* fields to responses an Android
client already parses: `payment_type` on the `set_alert` alert object, and `payment_type`, `latest_comparable_price`,
`latest_comparable_reported_at`, `latest_comparable_payment_type` on every `list_alerts` row. A decoder that ignores unknown keys (Gson, Moshi, the iOS
`Codable` default) is unaffected. One that rejects them (`kotlinx.serialization` without `ignoreUnknownKeys = true`, or Moshi/Jackson configured
to fail on unknown properties) would fail to read `list_alerts` and `set_alert` the moment this step completes. Before Step 5, the owner confirms
with whoever owns the Android client — ideally by running the Android build against the responses the A-series of `price_alert_api_payment_type.test.sh`
asserts field by field — that unknown keys are tolerated. If they are not, either ship the tolerant Android build first, or add a small server change that includes the
new fields only when the request declares `alert_contract_version` (not done here: nothing in this repository can show it is needed, and it would add a second
contract to the API). Until this is confirmed the plan's "Android keeps working" statements (M1/M2) cover **HTTP behavior and notification wording only**, not the
Android app's parsing.

The **whole directory** (`index.ts`, `alert-input.ts`, `values.ts`, `deno.json`), by name, with **`verify_jwt = false`**. Deploying
through a tool whose default is `verify_jwt = true` would lock every app out — set it explicitly or deploy with the CLI, which reads
`supabase/config.toml`. Never deploy the new API before B: its SQL needs B's column and function and would fail every `set_alert` and
`list_alerts` with a 500 (M1). Verify: ACTIVE, the new version number, `price_alerts_function_hashes.sh --against <re-downloaded>`
all `MATCH`, and an unauthenticated request gets the application-level 401 (the check the 2.4.1 activation used). No verification
step creates a production installation, alert or report; the behavior of the older and the new request shapes is what
`price_alert_rollout_compat.test.sh` (M1) and the A-series of `price_alert_api_payment_type.test.sh` prove locally.

### Step 6 — Deploy `price-alerts-worker`

The whole directory (`index.ts`, `auth.ts`, `fcm.ts`, `message.ts`, `deno.json`), by name, `verify_jwt` as in `config.toml` (`false`: the
scheduler authenticates with its own secret header). The invoker cron is **active**, so the new worker is live within a minute; there is
no dry run in production. Safe on either side of B: with B applied it names the price type for Cash/Credit alerts and sends legacy
alerts byte-for-byte as before (M2); without B it logs one warning per run and sends the old wording (M2). Verify the hashes as in Step 5.

### Step 7 — Observe (section 10), then the clients

iOS: an **Internal** TestFlight build only (`EightyFiveBlends Internal`, Xcode Cloud "85Blends Internal"). The App Store build waits for
the owner's exact words "prepare production release". Android: see section 11.

## 8. What happens when a step fails or is interrupted

Evidence is from `price_alert_rollout_compat.test.sh` (M = matrices, T = transition scenarios).

### 8.1 A succeeded, B failed

* **B failed on its lock timeout or by an error:** B is one transaction, so **nothing** of B exists (T4: no column, the same function
  bodies, no trigger). The database is "A only". The previous API, previous worker and previous engine are all exactly as before (M1,
  M2: all 200, same wording). **Risk in this state:** a typed report can make the previous engine alert a legacy alert (T1: credit
  3.19 → cash 2.99 queued a notification). Only clients that send `payment_type` can do that, and none is in production (the App Store
  build has no Price Alerts client; only Internal builds report typed prices). Keep the gap short: fix the cause and re-apply B, or
  hold the Internal builds back from reporting.
* Do **not** "fix" this by dropping A's column or revoking its grant: a client that names the column would then fail every report
  submission with `permission denied`.

### 8.2 B succeeded, but the API deployment failed or was not done

The previous API keeps working against the new schema (M1: all 200). Alerts it saves stay legacy and ignore the extra fields. Typed alerts
cannot be created without the new API, so nothing new depends on it yet. Retry the deploy; no database action is needed. **Never** deploy the
new API from a state where B is not applied (M1).

### 8.3 B succeeded, but the worker deployment failed or was not done

The previous worker keeps delivering (M3). For a legacy alert nothing differs. For a Cash/Credit alert it sends the right alert for the
right price in the **old wording** without the price type (`Station dropped to $3.09/gal.`). That is a degraded message, not a false or
duplicate one. Retry the deploy.

### 8.4 A report arrives during the transition

* During A or B it waits for the migration's transaction and then succeeds (T5). Its job is queued once and is decided by whichever
  engine is installed when the job runs.
* Between A and B (the gap) the previous engine decides it (T1 above).
* An older client's report omits `payment_type`, is stored `unknown`, and is judged by legacy alerts exactly as before.

### 8.5 Notifications prepared under the previous engine

They are untouched by A and B and are delivered by whichever worker runs, in the old wording (T2). A second report inside the cooldown does
not duplicate them. A delivery whose report is more than 2 hours old is expired as stale at the next claim (and one for a disabled or invalidated device is skipped); nothing is ever sent late.

### 8.6 Jobs still queued when B is applied

Their drops are lost, not duplicated (T3). Prevented by section 6.

### 8.7 Both functions fail, or the platform is unhealthy

Redeploy the previous sources you kept in Step 1 (rollback artifacts) — the schema needs no change for that — and verify the hashes. Neither
function is needed for the database to be consistent: engine decisions happen in the database, sends happen in the worker.

## 9. Fail-closed controls, incident plan, rollback and resume

**Executed as a drill** by T6 of the compatibility script (the statements below are the ones it runs, in this order, on an A+B database with
live-looking data). Every control is a separate decision made at the time.

**Report submission is never part of an incident control.** None of C1–C6 touches `public.e85_price_reports`, its grants, its RLS policy or its
triggers (the rate limiter, the alert-job enqueue, the growth refresh): while any of them is in force people can still submit prices, the app can
still read them, and jobs are still enqueued (C1 consumes them without a decision; C3 together with C2 leaves them queued until resume). The one thing that can briefly affect
submission is a *migration's* lock (section 5), never a pause.

### 9.1 Which control for which problem

| Problem | Control | Stops | Leaves running |
|---|---|---|---|
| False or wrong notifications are being **created** | **C1** pause new decisions | new notification decisions | sending of already-queued notifications; reports; the API |
| Queued notifications must **not go out** | **C4** cancel what is queued but unsent (after C2) | those notifications | everything else |
| APNs/FCM misbehaving, or sends must stop now | **C2** pause the worker job | all sending (the worker also prepares jobs, so that stops too) | the prepare job keeps deciding and queueing `pending` deliveries; they go out on resume unless cancelled with C4 or expired as stale (2 hours) |
| Everything must stop | C1 or C3, plus C2 | decisions and sending | reports, the API, RevenueCat, every unrelated job |
| New API misbehaving | **C5** redeploy the previous API (Step 1 artifact) | the new API | the database; legacy alerts keep working (M1). **Trade-off:** the previous API overwrites an alert's drop size on every save, so while it serves, a re-save can reset a chosen size (the very bug §6.1 of the payment-types document fixes) and it cannot set a price type. Prefer fixing forward; use C5 only when the new API is actively harming |
| New worker misbehaving | **C6** redeploy the previous worker | the new wording | deliveries continue in the old wording (M3) |
| A client build misbehaving | stop distributing it / revert the release | — | everything server-side |

### 9.2 The statements

**C1 — pause new decisions.** `private.prepare_price_alert_deliveries` is the single chokepoint: the prepare cron job
(`process_price_alert_jobs`) and the worker (`index.ts`, per claimed job) both call it, so replacing it stops decisions on either path.
The engine becomes a no-op that decides and queues nothing; a report that arrives meanwhile is consumed without a decision (so a drop that
happens during the pause is never notified later — a missed notification, never a late or wrong one); `create or replace` keeps the
function's ACL; scenario D19 and T6 execute exactly this:
```sql
create or replace function private.prepare_price_alert_deliveries(p_price_report_id uuid)
returns table(pending_count integer, skipped_count integer)
language sql
security definer
set search_path = ''
as $$ select 0, 0 $$;
```

**C2 — pause sending** (only the worker's invoker job):
```sql
select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke'), active := false);
```

**C3 — pause job preparation** (only the Price Alerts prepare job; note the worker also prepares jobs, so this alone does not stop decisions):
```sql
select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alert-job-prepare'), active := false);
```

**C4 — cancel what is queued but unsent.** Nothing is deleted; the rows stay as the audit trail with a reason. Run it **after C2** and wait
two minutes so nothing is in flight. Narrow it to the incident with `created_at` (replace the placeholder with the time the problem started;
add `and payment_type is not null` to cover only deliveries the new engine decided):
```sql
update private.price_alert_deliveries
set status = 'skipped', reason_code = 'paused_by_operator'
where status in ('pending', 'failed')
  and created_at >= timestamptz '<incident start>';
```
A `processing` delivery is one a worker has claimed: a live worker finishes it within seconds, and the claim function itself takes back one that has
been `processing` for more than 15 minutes (a stopped worker), so include `processing` rows in the statement only after reading them and only if they are
older than that. A late completion of an in-flight send cannot resurrect a cancelled delivery (`mark_price_alert_delivery_sent` ignores a `skipped` row;
executed in T6) — but a push that had already left for APNs/FCM cannot be recalled, which is why C2 comes first.

**C5 / C6 — redeploy the previous function sources** you kept in Step 1, whole directory, same `verify_jwt` as before, then verify with
`price_alerts_function_hashes.sh --rev <previous revision> --against <re-downloaded>`.

### 9.3 Which scheduler jobs may need to be paused — and which must not be touched

Only these two, by exact name: `85blends-price-alert-job-prepare` (`select * from private.process_price_alert_jobs(50)` every minute) and
`85blends-price-alerts-worker-invoke` (the pg_net call to the worker, every minute). **Never** touch `refresh-85blends-growth-snapshot`,
`sync-85blends-app-store-growth`, or any referral, RevenueCat or unrelated job. T6 asserts that pausing and resuming the two leaves every other
job's state identical. Prefer C1 to pausing the prepare job: with the no-op, reports are consumed so nothing piles up; with the job paused,
jobs queue and are decided on resume (a job whose report is more than 2 hours old can no longer notify; it only moves the reference).

### 9.4 What can be reverted, and what must stay

* **Can be reverted safely:** the iOS release; the API and worker (redeploy); the engine (pause, then fix forward); the cron jobs (re-activate).
* **Must remain additive:** every column, constraint, index, trigger and function A and B created, and A's `INSERT (payment_type)` grant. They are
  inert when the engine is paused, and removing them breaks any client or function that names them (the new API, the app's typed reports). A full
  schema unwind is not part of any incident plan. If it is ever wanted, it is the **last** step after no client sends `payment_type`, and it is a
  one-way loss of the classification of every typed report.
* **Never:** re-apply the previous `prepare_price_alert_deliveries` (migration `20260918001318`) after typed reports exist.

### 9.5 Preserving alert configurations and avoiding duplicates

Pausing and resuming change no alert row: T6 compares a hash of every alert's configuration (id, installation, station, mode, threshold, drop
size, cooldown, payment type, enabled) before and after and requires equality. A cancelled delivery stays cancelled after recovery (no re-send).
A decision is unique per `(alert, report, device)` (unique key), so replaying a report decides nothing twice, and the cooldown is measured from
the last sent or still-queued notification, so recovery cannot produce a burst.

### 9.6 Resume

1. Re-run migration B's SQL — the contents of `20261007130000_price_alert_payment_aware_evaluation.sql`, in the SQL editor or with `psql -f` (**not**
   `supabase db push`: B's version is already recorded in the migration history, so the CLI would find nothing to apply). It is idempotent, restores the
   real engine (T6: the function body hash equals the original), and does **not** repeat the one-time fill (it only runs when the alert columns are
   not there yet). If the pause was C1 only, nothing else is needed for the engine; if the cron jobs were paused (C2/C3), continue with step 2.
2. Re-activate the jobs: the two `cron.alter_job(..., active := true)` statements.
3. Verify with the observation query (section 10). A new qualifying report queues exactly one notification, for that report only (T6).

## 10. After the rollout: what counts as success

Run `supabase/runbooks/price_alerts_3c_observe_readonly.sql` at +15 minutes, +1 hour and +24 hours (one SELECT, read-only). Together with the Edge
Function logs, success means:

| Evidence | Where | Pass |
|---|---|---|
| No notification for a report that is not comparable to the alert's price type | observe row `MUST_BE_ZERO.notifications_for_a_non_comparable_report` | **0** |
| No failed or dead job | `MUST_BE_ZERO.failed_or_dead_jobs_in_window`, `jobs_by_status` | 0 |
| Both jobs ran every minute and succeeded | `cron.price_alert_runs_in_window` | ~60 per job per hour, none failed |
| Queue is small and young | `queued_now`, `oldest_queued_age` | minutes, not hours |
| Alerts still go out | `sent_in_window` against the preflight's `deliveries.sent_last_24h` | in line |
| Typed alerts appear as people choose | `alerts_by_payment_type` | `unknown` shrinks, `cash`/`credit` grow |
| API healthy | Edge Function logs for `price-alerts-api` | no 5xx; `set_alert`/`list_alerts` succeed |
| Worker healthy, not degraded | logs for `price-alerts-worker` | HTTP 200 per run; **no** `payment_type lookup failed` |
| The first natural Cash/Credit notification | a device | new wording, deep link opens the station |

Do not manufacture evidence by creating production reports or alerts without a separate authorization; wait for natural traffic or have the owner
explicitly approve one controlled canary (one Internal-build report at a station that has the owner's own alert).

## 11. Clients

**iOS.** The Internal build shows the new reporting and alert UI. Until A, B and the API are live, an Internal build that tries to report a typed
price is rejected by the current backend (the person sees the existing "could not be submitted" message; it is not silently retried without the
price type), and choosing a price type for a legacy alert is **refused honestly** ("Price type not saved") because the old API ignores the field.
That is why the order in section 3 matters and why the build should not be installed on production-facing devices before Step 6.

**Controlled iOS rollout (each stage separately authorized; the default is Internal only — `CLAUDE.md`).**

1. *Backend first.* Steps 3–6 done and verified (section 7), the observation queries clean for at least a day.
2. *Internal TestFlight* (`EightyFiveBlends Internal`, Xcode Cloud "85Blends Internal", `claude/*` / `fix/*` / `feature/*` branches only). Xcode Cloud's
   **Test – iOS must be SUCCESS on the exact commit** that is distributed. On the owner's own device: report a Cash price, report a Credit price,
   create a Cash alert, open an existing legacy alert and confirm "Choose Your Price Type" appears with nothing preselected, choose one and watch the
   list banner disappear — that is the only production write, made by the owner on purpose, and it is the owner's call whether to do it.
3. *Prerequisites that are NOT part of this plan* and must be separately owner-approved before a build that contains Price Alerts goes to the
   public: the Apple Push capability and `aps-environment` entitlement, and the CloudKit **Production** schema for
   `CD_FuelStation.CD_communityStationID` (`PRICE_ALERTS_UI_2.4.1.md` §6). Without the push capability the feature is visible but cannot deliver.
4. *Production release* only on the owner's exact words "prepare production release" (a separate Xcode Cloud workflow, App Store review, ideally
   with Apple's phased release so the first days reach a fraction of users). Re-run the observation queries at each stage.
5. *Stopping a release:* pause the phased release / remove the build from sale; the backend stays additive and compatible with every older client
   (M1/M2), so an app rollback never requires a database change.

**Legacy alerts.** After the rollout every existing alert is `unknown` and keeps watching unclassified reports. As more reporters send typed
prices, unclassified reports become rare, so legacy alerts hear less. The app now says so: a legacy alert shows "Payment type needed" in the
Price Alerts list and a "Choose Your Price Type" card in its sheet, and nothing is chosen for the person.

**Android (no Android code here).** Everything is additive and optional: older Android clients keep working unchanged at the HTTP level (M1/M2), their
alerts stay legacy, their `set_alert` requests (no `alert_contract_version`) can never reset a drop size chosen elsewhere, and their notifications are
byte-for-byte unchanged. What this repository cannot show is whether the Android app's JSON decoder tolerates the **new response fields** — see the
precondition at Step 5; it is the one Android risk that could break an existing user's screen. To adopt the feature they send `payment_type` and, once they offer a drop size, `alert_contract_version: 2`
(`PRICE_ALERTS_PAYMENT_TYPES_2.4.1.md` section 6.1). Until then Android alerts quiet down as typed reports replace unclassified ones — a product
decision, listed in section 14.

## 12. What this plan never touches

Report **submission availability** (at the measured table sizes A and B each hold a lock for roughly a second at most, and a waiting report succeeds), **RevenueCat** (the Pro
check is unchanged and still server-side at decision and at send), the **Referral** features and functions, the **growth snapshot and App Store
sync** jobs, any **other cron job**, **secrets** (names only are ever read; none is created or changed), **CloudKit**, **entitlements**, **signing**,
the **Xcode Cloud workflows**, **StoreKit/subscriptions**, and the **frozen v2.4.0 tag and snapshot**.

## 13. Evidence index

| Claim | Evidence | Command |
|---|---|---|
| Previous/new API and worker vs database state (before A, A only, A+B) | `price_alert_rollout_compat.test.sh` M1–M3 | `bash supabase/tests/price_alert_rollout_compat.test.sh` |
| A–B gap false alert; queued notification survives B; undrained queue loses a drop; failed B leaves nothing; report during B waits; incident drill; lock window | same, T1–T7 | same |
| Migrations preserve every row and are idempotent | `price_alert_payment_type_migration.test.sh` (M1–M7), `price_alert_payment_type.test.sql` G1 | `bash supabase/tests/price_alert_payment_type_migration.test.sh` |
| The decision matrix, pause (D19), legacy migration through `set_alert` (D27) | `price_alert_payment_type.test.sql` | `psql -f` on a replayed database |
| The real API over HTTP incl. the sensitivity contract (A1–A16) | `price_alert_api_payment_type.test.sh` | Deno |
| Concurrent saves/prepares (PC1–PC6) | `price_alert_payment_type_concurrency.test.sh` | local Postgres |
| Source-hash comparison works | `price_alerts_function_hashes.sh` | `--rev … --against …` |
| The read-only queries are valid on the pre-A and post-B schema | the three files in `supabase/runbooks/` | `psql -f` (they were run locally against both) |

## 14. Not provable here, and open decisions for the owner

**Not provable on Linux (named so nothing is claimed that was not seen):** the hosted Postgres major version (local tests used 16.15); the real
Supabase CLI behavior for the dry run (verified in the 2.4.1 activation with CLI 2.119.0, not re-run); hosted hardware timings; real APNs/FCM
delivery; SwiftUI compilation of the new views by Xcode (the Xcode Cloud "Test – iOS" result on the final commit is the gate); the Android client
(its request shapes and, above all, whether its JSON decoder tolerates the new response fields — Step 5).

**Decisions only the owner can take:**

1. **The window**, and whether a very large reports table needs the index built outside the migration (section 5).
2. **Whether to hold typed-report clients back** until B is in (they are only Internal builds today).
3. **Legacy alerts going quiet** (every Android alert and every iOS alert nobody edits): ship the Android update promptly, accept it, or — a product
   change with a cost — let a legacy alert accept typed reports. Not done.
4. **A controlled canary** after the rollout, or only natural traffic (section 10).
5. **Pausing** — each control in section 9 is used only on an explicit instruction at the time.
6. **Android decoder tolerance** (Step 5): confirm it, or decide between shipping a tolerant Android build first and gating the new response fields on
   the contract marker.
7. **Pre-marker Internal iOS builds** (3A/3B/3C before 3C.1): they keep working, but cannot deliberately switch an *existing* alert back to 5¢ (the
   server keeps the stored size when a request without the marker carries the fixed `0.05`). Updating the Internal build removes the limitation.

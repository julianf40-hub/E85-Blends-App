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
4. **Never put the previous engine back once migration B is applied** — not even "while no typed report exists yet". The previous
   `prepare_price_alert_deliveries` ignores the alert's price type: it compares a report with the previous report of any payment type (the
   false alert this phase removes), and after B it would also queue deliveries that carry no price type, which B's `mark_price_alert_delivery_sent`
   guard then never records on a Cash or Credit alert. The fail-closed move is to **pause** (section 9), not to roll back.
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
| iOS | Phase 3C + 3C.1 on the branch. Xcode Cloud "85Blends Internal" Test – iOS was reported SUCCESS for `ad02bf1` (Phase 3C); the 3C.1 commits are **not** covered by that result — the gate is Test – iOS on the final SHA | the App Store build (2.4.0) has **no Price Alerts client at all**; only Internal TestFlight builds do |
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
| What B will replace is recorded | `functions.prepare_md5`, `functions.mark_sent_md5`, `functions.engine_v2_exists` | `engine_v2_exists` is `yes` (stop: section 8.1). The two hashes are compared with the reference values in the next paragraph |
| The scheduler secrets exist (names only) | `vault.scheduler_secret_names` | missing |
| Nobody is holding locks on the tables | `activity.*` | long transactions or ungranted locks |

**Reference hashes.** A local replay of this repository's migration chain (Postgres 16.15) gives, for the functions B replaces,
`md5(prosrc)` = `81501754ae78b4c4c0ccb3032d2e1dcc` for `prepare_price_alert_deliveries(uuid)` and `d8d42715db93e02fe6b9729ec6b1a8e2` for `mark_price_alert_delivery_sent(uuid,integer)`
(before B), and `d053c90ec345ed70fc8afcfdbb57c5dd` / `eb8fa7fe91dc5fe529a39ec4f0893759` after B. If production's preflight values for the two "before" functions differ from the
first pair, production's functions are not exactly the repository's: that is a question to settle (compare the bodies), not necessarily tampering — a tool that
normalized whitespace when it applied a migration would also change the hash — but it must be settled before B replaces them.

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
Also confirm, in the Supabase dashboard (not readable from SQL), that **backups are on and point-in-time recovery is available**, and note the
time of the latest backup: every other step here is an additive change, but a backup is what turns "unexpected" into "recoverable".

**Window.** Choose the quietest hour the report histogram shows, and **start the push a few seconds after a minute boundary** (about
`:05`–`:10`), not at `:00`: the prepare job and the worker both fire at the top of every minute, and B takes its locks on the alert and
delivery tables. Both migrations go in **one push, seconds apart** (T1, section 8.1): between A and B the previous engine is still running,
and a typed report arriving in that gap can alert a legacy alert falsely. Nothing sends typed reports to production except Internal
TestFlight builds (the App Store build has no Price Alerts client and sends no payment type), but there is no reason to leave the gap
open — and the verification query counts any exposure (`A.gap_exposure_deliveries`).

**What the locks cost** (local figures; hosted hardware differs):

| | Rows in `e85_price_reports` | Time | Effect |
|---|---|---|---|
| Migration A | 300,000 | 0.32 s | **reads and writes** of the reports table queue behind A's transaction: its first `ALTER TABLE` takes `ACCESS EXCLUSIVE`, which conflicts with every other lock, and the file is one transaction (A's own header says so). That includes the app reading community prices. |
| Migration A | 1,000,000 | 1.27 s | same; the dominant cost is validating the CHECK and building the index |
| Migration B | alert and delivery tables empty or small | ~50 ms | the report insert's alert-enqueue trigger reads `private.price_alerts`, the worker's claim and the prepare job read the alert and delivery tables — all queue behind B's `ACCESS EXCLUSIVE` locks on those two tables. **Measured with empty alert and delivery tables; it grows with them** (production's are expected to be small, which the preflight shows) |

A report submitted while a migration runs **waits and then succeeds** (T5: the test holds B's transaction open for 3 s *on purpose* so the
wait is measurable — the real B takes ~50 ms; the report waited 2.05 s, was stored, had its job queued once, and was decided by the new
engine). **What T5 does not prove:** the local roles have no `statement_timeout`; Supabase documents a default of 3 s for the `anon` role, which is
the role the app's report insert uses, and a wait longer than the role's timeout surfaces to the app as a failed submission. The preflight row
`target.client_role_statement_timeouts` records what this project actually has.

**What `lock_timeout` does and does not do.** Both migrations start with `set lock_timeout = '3s'`: if the migration cannot get a lock it gives up
after 3 s and leaves nothing behind (T4 for B: 3.04 s; T4b for A: 3.04 s). That bounds the migration's **own wait**. It does not remove the
stall: while the migration waits for its lock — typically behind a long-running transaction — every new statement on that table queues behind the
pending request (T4b measured a read issued during A's wait being held for ~2 s). So the preflight's `activity.*` rows (no long transactions, no
ungranted locks) are a real gate, not a nicety, and the worst case for B is two successive waits of up to 3 s (it locks `private.price_alerts` and
then `private.price_alert_deliveries`) — about the `anon` statement timeout, which is another reason to start away from the minute boundary and with
the queue empty. Neither migration's *work* after it holds its locks is bounded by `lock_timeout`; that is the 0.3–1.3 s (A) and ~50 ms (B) above.

**If the reports table were far larger than the 1M rows measured**, A's single transaction would hold its lock longer; the way to shorten it would be a lock-light variant of A (add the
column and a `NOT VALID` check in one short step, `VALIDATE CONSTRAINT` and `CREATE INDEX CONCURRENTLY` as separate steps). That is a change to A, not part of this
phase; the index cannot be built first because it names the new column. The preflight's `reports.rows` says whether it matters.

## 6. The queue-drain requirement

**Apply B only when `private.price_alert_jobs` has no `pending`, `processing` or `failed` row AND `private.price_alert_deliveries` has no
`pending`, `processing` or `failed` row** (preflight `jobs.*` and `deliveries.queued_now`). **Re-run those preflight rows within a minute of the push** —
a preflight from an hour earlier proves nothing about now. Two reasons, both executed or reasoned from the migrations:

* *Lost drops (T3).* B's one-time fill anchors each legacy alert on its latest report. A report whose job is still queued is then judged against
  **itself**, and its drop is lost — a missed notification, not a false one. The same report processed first (the previous engine, before B) alerts normally.
* *A lock-order deadlock with a send in flight.* `mark_price_alert_delivery_sent` updates a delivery and then the alert; B locks the alert table and then the
  delivery table. A send finishing at the instant B runs can therefore deadlock with it; if Postgres chooses the send as the victim, the worker records the
  delivery as failed and retries it later — **a duplicate push**. With no delivery `pending`/`processing`/`failed` there is no send in flight, so the
  hazard cannot occur: that is why the delivery gate is a gate and not a preference.

**What the gate cannot close:** a report that arrives in the few seconds between the last check and B's commit has its job queued when B lands and can lose its
drop (T3). That is a missed notification, bounded to those seconds, and the reason to choose a quiet minute.

How to get there: wait. The prepare cron runs every minute and reports arrive rarely; two or three quiet minutes empty it. Do **not**
force-complete jobs or delete deliveries to "drain" — if the queue does not empty on its own, that is a finding to understand first
(a stuck job is reclaimed after 15 minutes; a delivery whose report is more than 2 hours old is expired as stale at the next claim and is never sent late).

Deliveries that are already queued when B is applied are **left alone**: not re-evaluated, not re-sent, and a delivery queued by the previous
engine still holds its legacy alert's cooldown, so the first report after B cannot duplicate it (T2). The new worker delivers it in the
old wording.

## 7. The rollout, step by step

Each step lists the action, the check, and what to do if the check fails. **Stop at the first failed check.**

### Step 1 — Hash validation and the migration dry run (no change)

1. Record what will be shipped: in a **clean** working tree (`git status` shows nothing), `git rev-parse HEAD` — call it `SHIP_SHA`. Every deploy below
   is made from a clean checkout of exactly that commit (`git worktree add /tmp/ship <SHIP_SHA>`), and every hash check names it with `--rev`.
2. Download the deployed sources of both functions, read-only (needs authorization), **into an empty scratch directory outside the repository**:
   `mkdir /tmp/deployed-before && cd /tmp/deployed-before`, then `supabase functions download price-alerts-api --project-ref <ref> --use-api` and the same for
   `price-alerts-worker`. The CLI writes under `./supabase/functions/<name>` of the directory it runs in, so run inside the repository it would overwrite the
   working-tree sources with the deployed code — the "rollback artifact" would be the sources' own directory, a later "deploy the whole directory" would
   redeploy old code, and every comparison against the working tree would trivially match. (The hash helper refuses `--against` without `--rev`, and refuses a
   directory inside the repository.) Afterwards `git status` in the repository must still show nothing.
3. `bash supabase/runbooks/price_alerts_function_hashes.sh --rev <the revision the last deploy came from> --against /tmp/deployed-before/supabase/functions`.
   The deployable files of both functions are byte-identical between `0f966ec` (the current `main`, which carries the deployed
   functions) and `1f88df0` (the Phase 3B tip); only two `.md` notes in `supabase/functions` differ, and the script does not compare
   notes. So either revision works for "the previous version". **Expected: `RESULT: every file matches`.** `DIFFER`, `MISSING` or
   `EXTRA` means production runs something other than what this plan assumes — stop and explain it. Keep `/tmp/deployed-before`:
   **it is the rollback artifact** for the API and the worker (redeploy from it, never from the repository).
4. Make a temporary deployment copy of `supabase/` (nothing is committed) **without**
   `supabase/migrations/20260921000000_promo_campaign_foundation.sql` (the only exclusion; no placeholder files, no
   `supabase migration repair`), and run `supabase db push --linked --include-all --dry-run --skip-vault` from it — the same command
   the 2.4.1 scheduler activation used (`PRICE_ALERTS_SCHEDULER.md`, "Exact migration procedure"). **The plan must list exactly
   `20261007120000_community_price_payment_type.sql` and `20261007130000_price_alert_payment_aware_evaluation.sql`.** Anything else —
   the promo migration, a growth migration, `20261005211547`, anything older — stop. `--include-all` is deliberate in the dry run:
   it makes the CLI show **every** local migration the remote history lacks, so a stray one cannot hide. `--skip-vault` keeps the push
   from ever touching Vault. (That procedure was verified with CLI 2.119.0 against a scratch database whose ledger mirrored production;
   it was **not** re-run in this phase, and CLI behavior may have changed since — the dry-run list is the check, not this sentence.)
   Take the copy from the same clean `SHIP_SHA` checkout, and confirm that its `20261007120000_*.sql` and `20261007130000_*.sql` are byte-identical to the
   ones in the repository at `SHIP_SHA` (`sha256sum` both); the files that are applied are the files that were tested.

### Step 2 — Confirm the preconditions

The preflight shows: A and B absent; the four prerequisites present; both Price Alerts jobs active and succeeding; no long transactions; the window
chosen. **Then re-run the preflight rows `jobs.*`, `deliveries.*` and `activity.*` within a minute of the push** and require the queue to be empty
(section 6: no `pending`/`processing`/`failed` job, and `deliveries.queued_now` = 0 — a hard gate, because a send in flight can deadlock with B). The
owner authorizes Step 3.

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
client-callable engine functions, `B.prepare_md5` and `B.mark_sent_md5` **different** from the preflight values, `B.engine_is_the_real_one` = `yes`, every
existing alert `unknown`, deliveries untouched (0 typed), `A.gap_exposure_deliveries` = 0, cron jobs exactly as before. Any mismatch: section 8.

**Record `B.prepare_md5` now as `ENGINE_REAL`** (and compare it with the reference `d053c90ec345ed70fc8afcfdbb57c5dd` from section 4; a difference means B did not install what was tested). Only a value written down at this moment lets anyone tell, after a pause and a resume, that the real engine
is back and not the no-op: the no-op also differs from the preflight value, and every "must be zero" observation stays green while it is installed. (The reference
is what a local replay produces: `select md5(prosrc) from pg_proc where oid = 'private.prepare_price_alert_deliveries(uuid)'::regprocedure` on a database replayed from `SHIP_SHA`;
recompute it if B ever changes.)

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

**Internal testers on a build older than 3C.1** (3A/3B/3C) are in a limited state from the moment this step completes: their saves carry no contract marker, so they
cannot deliberately switch an *existing* alert back to 5¢, and their build announces "Price Alert updated." while the form re-shows the stored size
(`PRICE_ALERTS_PAYMENT_TYPES_2.4.1.md` §6.1). Ask them to move to the 3C.1 Internal build at this point — not before, because that build against the old backend says
"Price type not saved" — and note that nothing is lost either way.

The **whole directory** (`index.ts`, `alert-input.ts`, `values.ts`, `deno.json`), by name, with **`verify_jwt = false`**. Deploying
through a tool whose default is `verify_jwt = true` would lock every app out — set it explicitly or deploy with the CLI, which reads
`supabase/config.toml`. Never deploy the new API before B: its SQL needs B's column and function and would fail every `set_alert` and
`list_alerts` with a 500 (M1). Deploy from the clean `SHIP_SHA` checkout, at a moment when no delivery is `processing` (an invocation replaced mid-send is killed after the
push left and before it was recorded, and the delivery is re-sent after 15 minutes). Verify: ACTIVE, the new version number; download the deployed files again into a **new**
empty scratch directory and run `price_alerts_function_hashes.sh --rev <SHIP_SHA> --against <that directory>/supabase/functions` — all `MATCH`; and an unauthenticated
request gets the application-level 401 (the check the 2.4.1 activation used). No verification
step creates a production installation, alert or report; the behavior of the older and the new request shapes is what
`price_alert_rollout_compat.test.sh` (M1) and the A-series of `price_alert_api_payment_type.test.sh` prove locally.

### Step 6 — Deploy `price-alerts-worker`

The whole directory (`index.ts`, `auth.ts`, `fcm.ts`, `message.ts`, `deno.json`), by name, `verify_jwt` as in `config.toml` (`false`: the
scheduler authenticates with its own secret header). The invoker cron is **active**, so the new worker is live within a minute; there is
no dry run in production. Safe on either side of B: with B applied it names the price type for Cash/Credit alerts and sends legacy
alerts byte-for-byte as before (M2); without B it logs one warning per run and sends the old wording (M2). Verify the hashes as in Step 5 (`--rev <SHIP_SHA>`, a fresh
scratch download), and deploy when no delivery is `processing`. **Either order of Steps 5 and 6 is safe** (the worker is fail-soft on either side of B): worker first means
the very first Cash or Credit alert ever created is announced in the new wording; API first leaves a short window in which it would be announced in the old wording (M3).

### Step 7 — Observe (section 10), then the clients

iOS: an **Internal** TestFlight build only (`EightyFiveBlends Internal`, Xcode Cloud "85Blends Internal"). The App Store build waits for
the owner's exact words "prepare production release". Android: see section 11.

## 8. What happens when a step fails or is interrupted

Evidence is from `price_alert_rollout_compat.test.sh` (M = matrices, T = transition scenarios).

### 8.1 A succeeded, B failed

* **B failed on its lock timeout or by an error:** B is one transaction, so **nothing** of B exists (T4: no column, the same function
  bodies, no trigger). The database is "A only". The previous API, previous worker and previous engine are all exactly as before (M1,
  M2: all 200, same wording). **Risk in this state:** a typed report can make the previous engine alert a legacy alert (T1: credit
  3.19 → cash 2.99 queued a notification). Only clients that send `payment_type` can do that: the App Store build cannot (it has no Price
  Alerts client and sends no payment type), so the senders are Internal TestFlight builds — which this branch's push also produces, so do not
  assume there are none. Keep the gap short: fix the cause and re-apply B, or hold the Internal builds back from reporting. To find out whether
  the gap was ever exploited, run the verification query (`A.gap_exposure_deliveries`, valid on an A-only database) or the observation query
  (`MUST_BE_ZERO.previous_engine_notifications_for_typed_reports`); anything it counts that is still `pending` can be cancelled (section 9, C4).
* **The preflight says `functions.engine_v2_exists` = yes before you started:** stop. Part of B (or all of it) is already there, applied some other way.
  Compare `migrations.phase3c_already_applied`, `reports.payment_type_column_exists` and `functions.prepare_md5` with what the repository's migrations produce
  before touching anything: B's one-time fill only runs while the alert columns are missing, so re-running B over a half-applied state would not complete it.
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

**Executed as a drill** by T6 of the compatibility script: the statements below are the ones it runs, in the order the plan gives (C1, then C2 and C3,
then C4, then the resume), on an A+B database with live-looking data. Every control is a separate decision made at the time.

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
The engine becomes a no-op that decides and queues nothing; `create or replace` keeps the function's ACL; scenario D19 and T6 execute exactly this.
**What the pause costs:** a report that arrives meanwhile is consumed without a decision and is **never replayed**, and the no-op does not move any alert's
reference. So the first qualifying report after the resume is judged against the reference *as it was before the pause* (D19f): a drop that began during the
pause is announced when that report arrives — late, but a real drop of the right price type, never a cross-payment or duplicate notification — and after a
long pause several alerts can fire as their stations next report. A reference that no comparable report has refreshed for 7 days is re-established without
notifying instead, so a pause longer than a week changes character (no burst, no memory of the drops in between). Keep C1 for as long as it takes to fix
forward — hours, not days. **While the no-op is installed every "must be zero" observation stays green; only `MUST_BE_YES.engine_is_the_real_one` and
`functions.prepare_md5` (compared with the `ENGINE_REAL` recorded at Step 4) tell the no-op from the real engine.**
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

**C4 — cancel what is queued but unsent.** Nothing is deleted; the rows stay as the audit trail. The decision's own `reason_code` (e.g. `price_dropped`) is kept and the
cancellation is recorded in `last_error_code` — the column the claim sweep itself uses for `stale_report` / `device_unusable` skips. Run it **after C2**, and **only once
`select count(*) from private.price_alert_deliveries where status = 'processing'` is 0**: a send in flight cannot be recalled, the worker has no fetch timeout, and a
push that already left for APNs/FCM stays sent. Narrow it to the incident with `created_at` (replace the placeholder with the time the problem started; add
`and payment_type is not null` to cover only deliveries the new engine decided):
```sql
update private.price_alert_deliveries
set status = 'skipped', last_error_code = 'paused_by_operator', locked_at = null
where status in ('pending', 'failed')
  and created_at >= timestamptz '<incident start>';
```
Then tidy the jobs that owned those deliveries (they would otherwise sit in `processing` until the claim reclaims them after 15 minutes — harmless, since a decision is
unique per alert, report and device, but untidy and confusing in `jobs_by_status`); `finalize_price_alert_job` is the same function the claim sweep uses and only completes a job
whose deliveries are all terminal:
```sql
select private.finalize_price_alert_job(r.price_report_id)
from (select distinct price_report_id from private.price_alert_deliveries where last_error_code = 'paused_by_operator') r;
```
A late completion of an in-flight send cannot resurrect a cancelled delivery (`mark_price_alert_delivery_sent` ignores a row that is not `processing`; executed in T6).

**C5 / C6 — redeploy the previous function sources** you kept in `/tmp/deployed-before` (Step 1), whole directory, same `verify_jwt` as before, then download the deployed
files again into a **new** empty scratch directory and verify with
`price_alerts_function_hashes.sh --rev <the previous revision> --against <that directory>/supabase/functions`.

### 9.3 Which scheduler jobs may need to be paused — and which must not be touched

Only these two, by exact name: `85blends-price-alert-job-prepare` (`select * from private.process_price_alert_jobs(50)` every minute) and
`85blends-price-alerts-worker-invoke` (the pg_net call to the worker, every minute). **Never** touch `refresh-85blends-growth-snapshot`,
`sync-85blends-app-store-growth`, or any referral, RevenueCat or unrelated job. T6 asserts that pausing and resuming the two leaves every other
job's state identical. Prefer C1 to pausing the prepare job when the problem is wrong decisions: with the no-op, reports are consumed so nothing piles up; with the
jobs paused (C3 together with C2), jobs queue and are decided on resume (a job whose report is more than 2 hours old can no longer notify; it only moves the reference).

### 9.4 What can be reverted, and what must stay

* **Can be reverted safely:** the iOS release; the API and worker (redeploy); the engine (pause, then fix forward); the cron jobs (re-activate).
* **Must remain additive:** every column, constraint, index, trigger and function A and B created, and A's `INSERT (payment_type)` grant. They are
  inert when the engine is paused, and removing them breaks any client or function that names them (the new API, the app's typed reports). A full
  schema unwind is not part of any incident plan. If it is ever wanted, it is the **last** step after no client sends `payment_type`, and it is a
  one-way loss of the classification of every typed report.
* **Never:** put the previous `prepare_price_alert_deliveries` (migration `20260918001318`) back once B is applied (see rule 4). Pause, then fix forward.

### 9.5 Preserving alert configurations and avoiding duplicates

Pausing and resuming change no alert row: T6 compares a hash of every alert's configuration (id, installation, station, mode, threshold, drop
size, cooldown, payment type, enabled) before and after and requires equality. A cancelled delivery stays cancelled after recovery (no re-send).
A decision is unique per `(alert, report, device)` (unique key), so replaying a report decides nothing twice, and the cooldown is measured from
the last sent or still-queued notification, so recovery cannot produce a burst.

### 9.6 Resume

1. Re-run **the newest migration that defines the engine** — today that is B, `20261007130000_price_alert_payment_aware_evaluation.sql` (if a later fix-forward migration
   replaced the engine, re-run THAT one: re-running B would install B's older engine over it). Use
   `psql -X -v ON_ERROR_STOP=1 --single-transaction -f <that file>` against the production connection (or the SQL editor), **not** `supabase db push`: the version is already
   recorded in the migration history, so the CLI would find nothing to apply. It is idempotent, restores the real engine (T6: the function body hash equals the original), and
   does **not** repeat the one-time fill (it only runs when the alert columns are not there yet). A failure here can be quiet (a pasted fragment, the wrong database, a lock
   timeout) — which is why step 2 exists.
2. **Prove the real engine is back before anything is re-activated:** the observation query's `MUST_BE_YES.engine_is_the_real_one` must say `yes` and its
   `functions.prepare_md5` must equal the `ENGINE_REAL` recorded at Step 4. Do not go on while either is false: every other check is green with the no-op installed.
3. Re-activate the jobs that were paused: the two `cron.alter_job(..., active := true)` statements (C2/C3 only).
4. Verify with the observation query (section 10). A new qualifying report queues exactly one notification, for that report only (T6).

## 10. After the rollout: what counts as success

Run `supabase/runbooks/price_alerts_3c_observe_readonly.sql` at +15 minutes, +1 hour and +24 hours (one SELECT, read-only). The window is one interval at the top of the
file: 60 minutes for the first two runs, **24 hours for the +24 h run** (so that `sent_in_window` can be compared with the preflight's 24-hour `deliveries.sent_last_24h`). Together
with the Edge Function logs, success means:

| Evidence | Where | Pass |
|---|---|---|
| The engine is the real one | `MUST_BE_YES.engine_is_the_real_one`; `functions.prepare_md5` equal to `ENGINE_REAL` | `yes`; equal |
| No notification for a report that is not comparable to the alert's price type | observe row `MUST_BE_ZERO.notifications_for_a_non_comparable_report` | **0** |
| No false alert from the gap between A and B | `MUST_BE_ZERO.previous_engine_notifications_for_typed_reports` (and `A.gap_exposure_deliveries` in the verification query) | **0** |
| No failed or dead job | `MUST_BE_ZERO.failed_or_dead_jobs_in_window`, `jobs_by_status` | 0 |
| Both jobs ran every minute and succeeded | `cron.price_alert_runs_in_window` | ~60 per job per hour, none failed |
| The worker actually answered | `net.http_responses_in_window` (pg_net's recorded status codes; a cron "succeeded" only means the call that starts the request returned) | nearly all `200`; no `401`/`403`/`5xx`/`timed_out` |
| Queue is small and young | `queued_now`, `oldest_queued_age` | minutes, not hours |
| Alerts still go out | `sent_in_window` against the preflight's `deliveries.sent_last_24h` (same window length) | in line |
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

**Android (no Android code here).** Everything is additive and optional: older Android clients keep working unchanged at the HTTP level (M1 covers the API against every
database state; the FCM path of the *new* worker is exercised by `price_alert_worker_message.test.sh`, and the previous worker's was not changed), their alerts stay legacy, and
their notifications for legacy alerts are byte-for-byte unchanged. A `set_alert` request without `alert_contract_version` that omits `minimum_change` or sends the fixed `0.05`
cannot reset a drop size stored for that **installation** — an Android installation is its own (it mints its own id and secret), so the protection matters for version skew
within one installation (an older Android build next to a newer one), not for crossing from iOS to Android. What this repository cannot show is whether the Android app's JSON decoder tolerates the **new response fields** — see the
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
| A–B gap false alert (and the verification query that sees it); queued notification survives B; undrained queue loses a drop; failed B and failed A leave nothing (and what queues behind A's pending lock request); report during B waits; incident drill with the no-op-vs-real-engine detector; lock window | same, T1–T7 and T4b | same |
| Migrations preserve every row and are idempotent | `price_alert_payment_type_migration.test.sh` (M1–M7), `price_alert_payment_type.test.sql` G1 | `bash supabase/tests/price_alert_payment_type_migration.test.sh` |
| The decision matrix, pause (D19), legacy migration through `set_alert` (D27) | `price_alert_payment_type.test.sql` | `psql -f` on a replayed database |
| The real API over HTTP incl. the sensitivity contract (A1–A16) | `price_alert_api_payment_type.test.sh` | Deno |
| Concurrent saves/prepares (PC1–PC6) | `price_alert_payment_type_concurrency.test.sh` | local Postgres |
| Source-hash comparison works, refuses `--against` without `--rev` and refuses a directory inside the repository | `price_alerts_function_hashes.sh` | `--rev <sha> --against <scratch dir>` |
| The read-only queries are valid on the pre-A, A-only and A+B schemas (verification: A-only and A+B; observation: A+B) and the cross-payment check flags a forged delivery | the three files in `supabase/runbooks/` | `psql -f` (run locally against each; T1 and T6 also drive the verification and observation rows) |

## 14. Not provable here, and open decisions for the owner

**Not provable on Linux (named so nothing is claimed that was not seen):**

* the hosted **Postgres major version** — `supabase/config.toml` declares `major_version = 17` for the project, while every local replay ran on **16.15** (nothing in
  migrations A or B relies on a version-specific feature that I know of, but it is unproven on 17; the preflight records the real version);
* the real **Supabase CLI** behavior for the dry run (verified in the 2.4.1 activation with CLI 2.119.0, not re-run) and the exact place `functions download` writes;
* **hosted hardware timings**, and the lock figures for large alert/delivery tables (B was timed with empty ones);
* **stand-ins locally:** `pg_cron`, `pg_net`, Vault and the API roles are shims — no real run history, an empty `net._http_response`, no `statement_timeout` on `anon`; so T5 shows
  "waits, then succeeds", not "survives a 3-second timeout", and the observation rows that read cron/pg_net were exercised on empty data;
* **PostgREST's schema cache** after migration A (the new column must become visible to the REST API; Supabase reloads it on DDL, but it was not observed);
* real **APNs/FCM** delivery;
* **SwiftUI compilation** of the new views by Xcode (the Xcode Cloud "Test – iOS" result on the final commit is the gate);
* the **Android client** (its request shapes and, above all, whether its JSON decoder tolerates the new response fields — Step 5).

**Decisions only the owner can take:**

1. **The window**, and — only if the reports table is far larger than the 1M rows measured — whether to ask for a lock-light variant of A (section 5).
2. **Whether to hold typed-report clients back** until B is in (they are only Internal builds today).
3. **Legacy alerts going quiet** (every Android alert and every iOS alert nobody edits): ship the Android update promptly, accept it, or — a product
   change with a cost — let a legacy alert accept typed reports. Not done.
4. **A controlled canary** after the rollout, or only natural traffic (section 10).
5. **Pausing** — each control in section 9 is used only on an explicit instruction at the time.
6. **Android decoder tolerance** (Step 5): confirm it, or decide between shipping a tolerant Android build first and gating the new response fields on
   the contract marker.
7. **Pre-marker Internal iOS builds** (3A/3B/3C before 3C.1): they keep working, but cannot deliberately switch an *existing* alert back to 5¢ (the
   server keeps the stored size when a request without the marker carries the fixed `0.05`). Updating the Internal build removes the limitation.

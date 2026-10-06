# Price Alerts worker scheduler — readiness runbook (2.4.1)

> **How to read this document.** It has two parts. **Current state and plan**: the next section and the
> last section, [Cross-platform reconciliation and deployment plan](#cross-platform-reconciliation-and-deployment-plan),
> say what production contains today and what to do next. Everything between them is the **original PR #120
> design and observations (HISTORICAL, written 2026-10-05)**, kept for its reasoning. Its "observed"
> statements (the worker is v1 or v2, `verify_jwt = true`, scheduler secrets missing, APNs secrets unknown,
> the worker has never been invoked, `prepared_only` means APNs is missing) were true when written and are
> **not** current; where such a statement remains below it is marked *(historical)*.
>
> No secret value appears in this repository; only secret *names* are used.

## Current production state (as of 2026-10-06; re-verify read-only before acting)

| Item | State |
|---|---|
| `price-alerts-worker` Edge Function | **v4 deployed**, ACTIVE, `verify_jwt = false`, bundle `81ff89f36ba9394bced217433d02fc817f30a1ee156c740e4bb504d24c5d642f`. Cross-platform: iOS through APNs, Android through FCM HTTP v1, claiming with `claim_price_alert_deliveries_v2` once per platform. Authenticates with `x-85blends-cron-secret` (`PRICE_ALERTS_WORKER_CRON_SECRET`) or the service-role Bearer, constant-time, 401 before any database work |
| `price-alerts-api` Edge Function | **v4 deployed**, ACTIVE, `verify_jwt = false`, bundle `6e86ad838de7618b549ed0c2d6d6a806c3f6333dcd222d82db67a6d415cf9e2a` (iOS and Android registration) |
| Edge secret `PRICE_ALERTS_WORKER_CRON_SECRET` | already provisioned |
| Vault secret `price_alerts_worker_cron_token` | already provisioned (and `project_url`) |
| `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY_P8` | already provisioned |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | presence not verified by this work |
| Migration `20261005211547_price_alerts_cross_platform_push` | **already applied** in production (recovered into git by PR #121) |
| Migration `20261005120000_price_alert_worker_scheduler_and_freshness` | **NOT applied** |
| Migration `20261005233000_price_alert_cross_platform_delivery_safety` | **NOT applied** |
| Migration `20261006000000_price_alert_android_active_device_uniqueness` | **NOT applied** |
| `private.invoke_price_alerts_worker()`, `price_alert_jobs_stuck_processing_idx` | absent (created by `20261005120000`) |
| Cron job `85blends-price-alerts-worker-invoke` | **absent** (created *inactive* by `20261005120000`); nothing calls the worker |
| Existing cron jobs | `85blends-price-alert-job-prepare` (every minute), the growth snapshot job, the App Store growth sync job |
| Price Alerts data | empty: no installations, devices, alerts, jobs or deliveries |
| `20260921000000_promo_campaign_foundation` | intentionally **not** applied |

**The repository is no longer identical to the deployed v4 Edge Functions.** PR #121 first recorded the
deployed v4 source exactly (commit `d15112b`), then intentionally changed two functions:

- `price-alerts-worker`: FCM response classification moved to a tested helper, `fcm.ts`; only an explicit
  `UNREGISTERED` invalidates a device (see [FCM failure classification](#fcm-failure-classification)).
- `price-alerts-api`: `registerDevice` takes a row lock on the installation (see
  [Android active-device invariant](#android-active-device-invariant)).

Both must be redeployed, individually and by name, and verified, **before** the scheduler is activated.

**Status of this change: prepared, NOT deployed, NOT applied.** Nothing in this PR has been run against the
production project (`zefkbtscieokkdenvnkg`).

## Original PR #120 design and observations (HISTORICAL)

## Why this exists

Verified read-only against production on 2026-10-05 *(historical: this was before the worker was redeployed and before secrets were provisioned)*:

- `price-alerts-worker` (the only code that talks to APNs) has **never been invoked**. No cron job,
  database function, trigger, webhook or platform scheduler calls it, and the Edge Function logs
  show zero calls to it (and to `price-alerts-api`) for every day since it was deployed.
- The one price-alert cron job, `85blends-price-alert-job-prepare` (every minute), only runs
  `private.process_price_alert_jobs(50)`: it prepares delivery rows and never sends anything.
- Every Price Alerts table is currently empty (no installations, devices, alerts, jobs or
  deliveries), so nothing is stuck today — the pipeline has simply never carried an alert.

```
price report INSERT → trigger → private.price_alert_jobs
   → cron (every minute) private.process_price_alert_jobs(50)  → private.price_alert_deliveries (pending)
   → [NEW] cron (every minute) private.invoke_price_alerts_worker() → pg_net POST
   → price-alerts-worker → claim_price_alert_deliveries → APNs → mark_*_sent / mark_*_failed → finalize job
```

## What changes

| Piece | File | Effect |
|---|---|---|
| Scheduler function + cron job (created **inactive**) | `supabase/migrations/20261005120000_price_alert_worker_scheduler_and_freshness.sql` | Adds `private.invoke_price_alerts_worker()` (validates its configuration) and job `85blends-price-alerts-worker-invoke`. |
| Supporting index | same migration | `price_alert_jobs_stuck_processing_idx` keeps the job claim an index scan. |
| Stale-job recovery | same migration (`claim_price_alert_jobs`) | Reclaims stuck `processing` jobs; never reclaims a job still waiting on deliveries. |
| Bounded expiry + claim exclusion | same migration (`claim_price_alert_deliveries`) | Expires (≤ 500 rows per call, `SKIP LOCKED`) and never sends deliveries whose report is older than 2 hours or whose device is disabled/invalidated. |
| Worker caller auth | `supabase/functions/price-alerts-worker/auth.ts`, `index.ts`, `supabase/config.toml` | Accepts a dedicated scheduler secret header **or** the existing service-role Bearer; `verify_jwt = false`. |
| Tests | `supabase/tests/price_alert_worker_readiness.test.sql`, `supabase/tests/price_alert_worker_concurrency.test.sh`, `supabase/functions/price-alerts-worker/auth.test.ts`, `…/contract.test.ts` | See [Validation](#validation). |

No client-visible secret is involved. The worker API contract (POST, optional `job_limit` /
`delivery_limit`, response shapes) and the `price-alerts-api` function are unchanged.

## What takes effect when the migration is applied

Be precise about this before applying it:

- **Created inactive:** only the **new worker-invocation cron job**
  (`85blends-price-alerts-worker-invoke`). Nothing calls the worker until an operator activates it.
- **Takes effect immediately:** every other change. In particular `private.claim_price_alert_jobs`
  is called every minute by the **already active** job-preparation cron
  (`85blends-price-alert-job-prepare` → `private.process_price_alert_jobs`), so the stale-job
  reclaim and the new index apply to that existing job the moment the migration runs.
  `private.claim_price_alert_deliveries` is only called by the worker, so its new behavior starts
  with the first worker invocation.
- With the Price Alerts tables empty (as observed), the immediate changes have nothing to act on.

## Auth strategy (decision)

*(Historical: when this decision was made.)* The worker was deployed with `verify_jwt = true` and additionally required
`Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>`. Options considered:

- **A — send the legacy service-role JWT from pg_cron.** No worker change, but it puts the project's
  all-powerful key (bypasses RLS everywhere) into Vault and into pg_net's request queue, couples the
  scheduler to a legacy key format that Supabase is moving away from (a new-style `sb_secret_…`
  key is **not a JWT** and is rejected by the `verify_jwt` gate, so a later key migration would
  silently stop alerts), and forces a lock-step Vault update on any key rotation.
- **B — dedicated scheduler secret + `verify_jwt = false` (chosen).** A random secret that can do
  exactly one thing (call this worker), rotated independently, independent of Supabase key format.
  It is the pattern production already uses for `app-store-growth-sync`
  (`x-85blends-cron-secret` header, secret held in Vault). The function still returns 401 before any
  database work when neither credential matches, using a constant-time compare, and an unset or
  short (< 32 chars) scheduler secret simply disables that path. The service-role Bearer is still
  accepted so a manual operator invocation keeps working.
- **C — other Supabase mechanisms.** A dashboard "scheduled Edge Function" is the same
  pg_cron + pg_net + Vault mechanism and would still need a credential stored in Vault; sending an
  `sb_secret_` key with `verify_jwt = false` is Option B with a far more powerful secret.

Trade-off accepted for B: it needs a worker **redeploy** and two copies of one secret (below). With
`verify_jwt = false` the URL is reachable by anyone; the secret check is the only gate, so generate it
with a CSPRNG (for example `openssl rand -hex 32`), never reuse it, and never commit it. The
scheduler secret limits the blast radius of a leak of *that secret*; it does not isolate anything from
a holder of the service-role key, which can also read Vault.

## Secret names (values are never stored in git)

| Name | Where | Used by | State observed 2026-10-05 *(historical; see Current production state)* |
|---|---|---|---|
| `project_url` | Vault | `invoke_price_alerts_worker()` | present (shared with the App Store sync job) |
| `price_alerts_worker_cron_token` | Vault | `invoke_price_alerts_worker()` | **missing** — must be created |
| `PRICE_ALERTS_WORKER_CRON_SECRET` | Edge Function secret | worker `auth.ts` (same value as the Vault token) | **not set** (code does not exist in production yet) |
| `SUPABASE_SERVICE_ROLE_KEY` | Edge Function (platform-provided) | worker `auth.ts` (operator path) | provided by the platform; not inspected |
| `SUPABASE_DB_URL` | Edge Function (platform-provided) | worker | not inspected |
| `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY_P8` | Edge Function secrets | worker `sendApns` | **unknown at the time** (now provisioned). Cross-platform worker: without the three APNs secrets the iOS claim path is not called; without `FIREBASE_SERVICE_ACCOUNT_JSON` the Android claim path is not called; `prepared_only` means neither provider is configured |

## Trusted `project_url` and invoker validation

`project_url` (Vault) is **trusted operator-controlled infrastructure configuration**: only
`postgres`, `service_role` and the admin roles can read or write Vault. It is still validated, because
a typo or bad copy/paste must never make the invoker send the scheduler secret to a cleartext or
unintended endpoint. `private.invoke_price_alerts_worker()` enforces, before any request is sent:

| Check | Rule | Error (fixed text, never contains a value) |
|---|---|---|
| Presence | `project_url` and the token exist and are non-empty (token: after trimming) | `price_alerts_worker_scheduler_not_configured` |
| URL shape | `^https://[A-Za-z0-9][A-Za-z0-9.-]*/?$` — HTTPS origin only; **no** other scheme, userinfo, port, path, query, fragment or whitespace; at most one trailing slash, which is removed before `/functions/v1/price-alerts-worker` is appended. The URL is never trimmed: a padded value is rejected | `price_alerts_worker_scheduler_invalid_project_url` |
| Token shape | trimmed of surrounding whitespace (including the newline copy/paste adds) and only the trimmed value is used; then `^[!-~]{32,}$` (printable non-space ASCII, ≥ 32 characters, header-safe) | `price_alerts_worker_scheduler_invalid_token` |

Every failure raises inside the cron job, so it appears as `failed` in `cron.job_run_details`. The
secret is sent only in the `x-85blends-cron-secret` header, never in the URL or in the cron command
text (`select private.invoke_price_alerts_worker();`).

## Activation order (ORIGINAL PR #120 plan — HISTORICAL; superseded by the current activation order at the end)

Each step is a deliberate, separately authorized action. The new worker-invocation cron job is created
**inactive**; see [what takes effect when the migration is applied](#what-takes-effect-when-the-migration-is-applied)
for what is *not* inactive.

1. Generate one secret value `S` (≥ 32 random characters), for example `openssl rand -hex 32`.
2. Set Edge Function secret `PRICE_ALERTS_WORKER_CRON_SECRET = S`. Confirm the three `APNS_*` secrets
   exist (if they are missing the scheduler is still safe: that provider's claim path is simply not called).
3. Create Vault secret `price_alerts_worker_cron_token = S` **through the Supabase Dashboard Vault UI**
   (Integrations → Vault → Add new secret). Avoid doing this with
   `select vault.create_secret('<S>', …)` in the SQL editor: the secret literal would then sit in SQL
   editor history and potentially in statement logs. If SQL is unavoidable, clear the editor history
   afterwards and rotate `S` if it may have been logged.
4. Deploy the worker from `main` **with `verify_jwt` off**, **by name** (for example
   `supabase functions deploy price-alerts-worker --no-verify-jwt`), so `auth.ts` is bundled with
   `index.ts` and no other function is touched. Do not run a blanket `supabase functions deploy`
   (other functions' repository copies may lag their deployed versions) and do not use a single-file
   dashboard/MCP deploy (it would omit `auth.ts` and the function would fail to boot). Until this
   step the deployed worker (v1) still has `verify_jwt = true` and the old Bearer-only check; the
   repository is intentionally ahead of production here.
5. Smoke test: an unauthenticated `POST` must return `401 {"error":"unauthorized"}`.
6. Re-run the read-only drift check (function fingerprints, signatures, latest migration) and the
   [`net` exposure check](#pg_net-queue-exposure), then apply the migration.
7. Run `select private.invoke_price_alerts_worker();` once and check the response (see
   [Observability](#observability-and-health-checks)); with an empty queue the worker returns
   `prepared_only` or `ok` with zero counters.
8. Activate the job:
   `select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke'), active := true);`
9. Watch the first several minutes of `cron.job_run_details`, `net._http_response` and the Edge logs.

## Rollback

**Order matters: DEACTIVATE the worker-invocation cron job BEFORE rolling the Edge Function back to
any version that has `verify_jwt = true` (the original v1/v2 did; v4 and later do not).** Such a version has `verify_jwt = true`; its platform gate rejects the dedicated-header scheduler request
(no JWT), so an active job against such a version produces a 401 every minute while cron itself still reports
success.

1. **Stop the scheduler:**
   `select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke'), active := false);`
   (or `select cron.unschedule('85blends-price-alerts-worker-invoke');`). In-flight pg_net requests
   still complete; claimed deliveries whose worker dies are reclaimed after 15 minutes.
2. **Roll the Edge Function back** (optional, only after step 1): redeploy the previous version with its
   previous `verify_jwt` setting. The exact deployed v4 source is recorded in git at commit `d15112b` (the
   recovery commit of PR #121); roll back to a *scheduler-compatible* version only (v4 or later accept the
   scheduler header). Removing the `PRICE_ALERTS_WORKER_CRON_SECRET` secret is optional; an unset secret
   simply disables the header path.
3. **Revert the SQL function replacements** (optional — they are safe to leave in place). Re-create the
   previous definitions from the repository history, running only the function statements and their
   `revoke`/`grant` lines:
   - `private.claim_price_alert_jobs(integer)` → from `supabase/migrations/20260917232104_price_alert_worker_primitives.sql`
   - `private.claim_price_alert_deliveries_v2(integer, text)` → from `supabase/migrations/20261005211547_price_alerts_cross_platform_push.sql`
     (the version production had before `20261005233000`; same signature and return shape)
   - `private.claim_price_alert_deliveries(integer)` (v1) → from `supabase/migrations/20260918001525_price_alert_delivery_claim_payload.sql`
     (that migration drops and re-creates the function; return shape is identical)
   - then remove the additions:
     `drop index if exists private.price_alert_push_devices_one_active_android_per_install_idx;`
     `drop index if exists private.price_alert_jobs_stuck_processing_idx;`
     `drop function if exists private.invoke_price_alerts_worker();`
     `select cron.unschedule('85blends-price-alerts-worker-invoke');`
   The migrations' rows in the migration ledger stay; that is expected. Do not use
   `supabase migration repair`.
4. **Irreversible effects:** deliveries already expired to `skipped` (`stale_report` /
   `device_unusable`) are terminal and are not re-queued by any rollback. Re-sending one would need a
   manual update and is deliberately not recommended (it is stale or undeliverable by definition).

| Situation | Effect | Action |
|---|---|---|
| Cron activated, then the worker fails (5xx / APNs outage) | Deliveries stay pending/failed and retry; nothing is lost; stale ones expire after 2 h | Step 1, fix, re-activate |
| Wrong scheduler secret (Vault ≠ Edge) | Every call returns 401; cron still shows success | Step 1, fix one side, re-activate; detect with the health checks |
| Wrong/invalid `project_url` or token in Vault | The invoker raises; `failed` in `cron.job_run_details`; no request is sent | Fix the Vault value |
| APNs or FCM provider failure | Retryable failures follow the 1m / 5m / 15m / 1h ladder, then `dead`; only an explicit invalid-token verdict (APNs `BadDeviceToken` / `Unregistered` / 410, FCM `UNREGISTERED`) disables the device | None needed |
| Auth regression in a newly deployed worker | 401s | Step 1, then roll back (step 2) |
| Migrations applied, hardened Edge Functions not yet deployed (v4 live) | Cron is inactive, nothing calls the worker; the new claim logic is live for the job-prep cron and for any manual worker call | Continue the current activation order |
| Hardened Edge Functions deployed, migrations not applied | The FCM classifier and the API lock work against the old claim functions; the Android index is simply absent | Continue the current activation order |
| FCM configuration failure (wrong Firebase project / credentials) | Android deliveries are retried (`failed`, then `dead` after the attempt cap); **no device is disabled** | Fix `FIREBASE_SERVICE_ACCOUNT_JSON`; no cleanup needed |

## pg_net queue exposure

`net.http_request_queue` stores each pending request's **headers** (so, momentarily, the scheduler
secret) and has no row-level security; the `anon` and `authenticated` roles hold `SELECT` on it at
the database-privilege level. That is only reachable by ordinary clients if the `net` schema is
exposed through the Data API. Verified read-only on 2026-10-05 with the public client key:

- REST: requesting schema `net` returns `PGRST106` — *"Only the following schemas are exposed:
  public, graphql_public"*.
- GraphQL: *"pg_graphql extension is not enabled."*
- No function or view in an exposed schema reads the `net` tables.

Result: **not externally exposed (safe)**. Re-check this before activation, and again whenever the
project's exposed-schema list or the GraphQL extension changes, because a change there would turn the
queue's headers into a client-readable secret. `pg_net` also keeps request metadata only briefly, but
this is why the secret must stay a worker-only value.

## Observability and health checks

**`pg_cron` success does NOT prove the Edge Function returned 2xx.** `pg_net` is asynchronous: a queued
request is a successful cron run even if the HTTP call later fails. A scheduler-secret mismatch therefore
produces repeated `401` responses while `cron.job_run_details` shows `succeeded` every minute.

- Misconfiguration inside the database (missing Vault secret, invalid URL or token) raises a fixed error
  inside the cron job, so it *does* show as `failed` in `cron.job_run_details`.
- **`pg_net` response history is retained only temporarily** (`pg_net.ttl` is **6 hours** on this
  project). Check it regularly during the first days, and do not rely on it for after-the-fact audit.
- HTTP outcomes: `401` = secret mismatch (or a `verify_jwt = true` version), `405` = not a POST, `503` =
  `SUPABASE_DB_URL` missing, `500` = internal error, `200` + `prepared_only` = **neither** push provider is
  configured. The v4 response also reports `apns_configured`, `fcm_configured`, `ios_deliveries` and
  `android_deliveries` (each `null` when that provider is not configured, because its claim path is then
  not called).

```sql
-- 0. is the scheduler actually on? (cron success below does not say whether the job is active)
select jobname, schedule, active from cron.job
where jobname in ('85blends-price-alerts-worker-invoke', '85blends-price-alert-job-prepare');

-- 1. cron health (the new job)
select status, count(*), max(start_time)
from cron.job_run_details
where jobid = (select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke')
group by status;

-- 2. worker HTTP outcomes (last 6 h). net._http_response covers EVERY pg_net request, so classify by body.
select status_code,
       case when content like '%"status":"ok"%'       then 'worker ok'
            when content like '%prepared_only%'       then 'worker prepared_only (no push provider configured)'
            when content like '%unauthorized%'        then 'worker 401 (scheduler secret mismatch)'
            when content like '%server_not_configured%' then 'worker 503 (SUPABASE_DB_URL)'
            when content like '%internal_error%'      then 'worker 500'
            when content ilike '%authorization%'      then 'platform JWT gate (a verify_jwt = true version deployed?)'
            else 'other request / not the worker' end as outcome,
       count(*) as n, max(created) as latest
from net._http_response
where created > now() - interval '6 hours'
group by 1, 2 order by latest desc;

-- 3. delivery queue: counts per status, oldest, and why rows were skipped
select status, count(*) as n, min(created_at) as oldest,
       round(extract(epoch from (now() - min(created_at))) / 60) as oldest_age_min
from private.price_alert_deliveries group by status order by 1;
select last_error_code, count(*) from private.price_alert_deliveries
where status = 'skipped' and last_error_code is not null group by 1;   -- stale_report / device_unusable

-- 4. the single number to alert on: how long has a DUE pending delivery been waiting?
select coalesce(round(extract(epoch from (now() - min(created_at))) / 60), 0) as oldest_due_pending_min
from private.price_alert_deliveries where status = 'pending' and available_at <= now();

-- 5. jobs: counts, and anything stuck
select status, count(*), min(created_at) as oldest from private.price_alert_jobs group by status;
select count(*) as jobs_processing_gt_1h from private.price_alert_jobs
where status = 'processing' and locked_at < now() - interval '1 hour';
```

Investigate if, while the job is active, query 4 stays above about 5 minutes, query 2 shows anything but
`worker ok` / `prepared_only`, or query 3 shows a growing `pending`/`failed` count. No alerting
infrastructure is added by this change; a scheduled check of query 4 is the recommended follow-up.

## Stale-work design and thresholds

| Rule | Value | Reasoning |
|---|---|---|
| Reclaim a stuck `processing` job | locked > **15 min**, no pending/processing/failed deliveries, `attempt_count < 5` | Same 15-minute window the delivery claim already uses; 5 is the dead-letter limit the worker/cron already pass. The delivery check is essential: `finalize_price_alert_job` deliberately keeps a job `processing` while any delivery waits or retries (retry delays are 1m / 5m / 15m / 1h; with the worker's 5-attempt cap the 4h step is never reached, so a healthy job can wait about 81 min), so lock age alone would reprocess healthy jobs. Reprocessing is idempotent (`ON CONFLICT DO NOTHING` per alert/report/device). Served by `price_alert_jobs_stuck_processing_idx`. |
| Freshness window | report `reported_at` within **2 h** (inclusive: exactly 2 h is still sendable, 2 h + 1 s is not) | `reported_at` is the observation time: it is bounded to [now − 7 d, now + 10 min] and so also stops a back-dated report from producing a "now" alert. 2 h is longer than the whole retry horizon (attempts at 0 / 1 / 6 / 21 / 81 min, then `dead`), so no legitimate retry is cut off, and it bounds any post-outage backlog to two hours of reports. |
| Unusable device | device disabled or invalidated | Such a delivery can never be sent. It used to be "claimed" every 15 minutes without ever reaching the worker (attempts inflating, job stuck). It is now expired. |
| Expiry action | delivery → terminal `skipped`, `last_error_code` = `stale_report` or `device_unusable` (stale wins), then the job is finalized | Reuses an existing terminal state (no schema change); not counted as sent; no APNs verdict implied; fully idempotent. |
| Sweep size | **500 rows per claim call**, `FOR UPDATE … SKIP LOCKED` on deliveries and on each job row | One call is a short transaction, never waits behind a row or job another session holds (measured: a locked stale row no longer delays a claim; a 20,000-row backlog expires 500 rows in ~0.1 s per call and drains incrementally). A job whose row is locked elsewhere is left for its holder or, failing that, the stale-job reclaim. No `lock_timeout` is set: every lock taken is `SKIP LOCKED`, so there is nothing left to time out, and a timeout error would only roll back good work. |
| Claim exclusion | the claim predicate independently excludes stale reports **and** unusable devices | A partially drained backlog is never sent, whatever the sweep has or has not reached. |
| Burst limit | worker `delivery_limit` (default 50) **per platform**, one run per minute | The worker calls the claim function separately for each configured provider, so with `delivery_limit = 50` and both APNs and FCM configured one run can claim up to **50 iOS plus 50 Android** deliveries (100 in total), never more than 50 per platform. Combined with the 2 h window this bounds recovery to a bounded drain. Per-device APNs collapse ids (`station-<id>`) additionally merge repeats. |

Not changed by the original PR #120: `prepare_price_alert_deliveries` (still creates rows for any report; stale ones are
expired at claim time), the retry ladder. (The cross-platform worker and API are covered in the last section.)

## Known gaps / follow-ups (not part of this change)

- A job that reaches `attempt_count = 5` while stuck is no longer reclaimed and is not auto-marked
  `dead`; it stays visible in the queue-health queries above.
- Whether `SUPABASE_SERVICE_ROLE_KEY` (legacy JWT key) remains valid is unverified; the scheduler no
  longer depends on it.
- The claim functions scan the deliveries table on every worker run (it did before this
  change, because of its `processing` branch; the new sweep adds about 17 ms at 200,000 deliveries,
  ~48 ms total vs ~31 ms). Deliveries accumulate (nothing prunes them), so if this ever matters a
  partial index on the non-terminal statuses (`pending`, `failed`, `processing`) is the straightforward
  follow-up. It is intentionally not added now.
- The worker's provider `fetch` calls (APNs, FCM and the Google OAuth token exchange) have no timeout
  (pre-existing). A hung call leaves its rows `processing` until the 15-minute reclaim, which can produce a
  duplicate push, bounded by the 2-hour window.
- Pro gating happens when deliveries are prepared (up to about 81 minutes before a retry), not at the
  instant of each send.
- Pro gating reads the RevenueCat ledger. A separate, unrelated production problem was found: the
  `revenuecat-webhook` cannot apply three SANDBOX events because their alias sets bridge two existing
  customer rows (deliberate "refuse to merge" safety rule). That is an identity reconciliation task,
  not an authentication problem, and is intentionally not fixed here.

## Validation

- `node --test supabase/functions/price-alerts-worker/*.test.ts` (auth tests + the cross-file naming
  contract) and the existing `node --test supabase/functions/_shared/*.test.ts`.
- All migrations replayed in order on a scratch PostgreSQL 16 with stand-ins for `pg_cron`, `pg_net`
  and Vault, then `supabase/tests/price_alert_worker_readiness.test.sql` and
  `supabase/tests/price_alert_worker_concurrency.test.sh` (see `supabase/tests/README.md`).
- The `cron` / `net` call shapes and the replaced functions' fingerprints were compared against
  production, read-only.

## Cross-platform reconciliation and deployment plan

Written 2026-10-05/06 after read-only production inspections found drift between git `main` and production,
and updated after the first adversarial review of PR #121. Nothing here has been applied or deployed.

### What production contained that `main` did not (recovered by PR #121)

| Item | Production | Git `main` before PR #121 |
|---|---|---|
| Migration `20261005211547_price_alerts_cross_platform_push` | applied | missing |
| `private.claim_price_alert_deliveries_v2(integer, text)` | live; had no freshness/device-safety hardening | missing |
| `price-alerts-api` | v4 (iOS and Android registration) | iOS-only source |
| `price-alerts-worker` | v4 (APNs + FCM, claim v2 per platform) | APNs-only source |
| Ledger versions `20260927065249`, `20260927065816`, `20260927065914`, `20260927070519` (App Store growth sync / growth snapshot) | applied | missing |

PR #121 recovers all of them into git. Each recovered migration is byte-for-byte the statement stored in
`supabase_migrations.schema_migrations` (plus the repository's final newline); the PR description lists size,
md5 and SHA-256 of each. The migrations contain no secret literal (the App Store sync token is generated at
apply time with `gen_random_uuid()`; the only literal is the public project URL). Because the four growth
migrations are now in git, **no placeholder or empty migration files are needed any more.**

### Deployed v4 versus the repository now

| Function | Deployed (v4) | Repository after PR #121 | Why it differs |
|---|---|---|---|
| `price-alerts-worker` | exact recovered source | `index.ts` delegates FCM classification to the new `fcm.ts` | invalidating a device on a generic 404 or `SENDER_ID_MISMATCH` could permanently disable valid users' tokens |
| `price-alerts-api` | exact recovered source | `registerDevice` locks the installation row | concurrent Android registrations could race |

### Compatibility migration `20261005233000_price_alert_cross_platform_delivery_safety`

Ports the reviewed freshness/device safety to the claim path the live worker uses, keeping iOS and Android
separate: both the expiry sweep (500 rows per call, `FOR UPDATE ... SKIP LOCKED`) and the claim are scoped to
the requested platform; reports older than 2 hours are excluded by the claim predicate itself;
disabled/invalidated devices become terminal `skipped` / `device_unusable` (stale wins); retries are
unchanged. The old v1 claim function becomes an iOS-only wrapper over v2. The migration has preconditions
(it refuses to run unless `20261005211547` and `20261005120000` are applied) and never touches the scheduler
or activates cron.

**What "stale" means when a provider is not configured.** With worker v4 the claim path of a platform is only
called when that provider's credentials exist. If `FIREBASE_SERVICE_ACCOUNT_JSON` is absent the worker does
**not** call `claim_price_alert_deliveries_v2(..., 'android')`, so the Android sweep does not run either:
pending Android deliveries are neither sent nor expired, and can stay `pending` for longer than 2 hours (the
same holds for iOS without the APNs secrets). Once the provider is configured and the claim path runs, the
freshness predicate keeps stale rows from ever being sent and the sweep marks them `skipped` /
`stale_report` (at most 500 per call per platform).

### FCM failure classification

`private.mark_price_alert_delivery_failed(..., p_invalidate_device => true)` permanently disables the device
row, so the worker may request it only on explicit evidence that the registration token itself is dead.
`price-alerts-worker/fcm.ts` (pure, covered by `fcm.test.ts`) classifies an FCM response as:

| Kind | FCM signal | Delivery | Device |
|---|---|---|---|
| `invalid_token` | `UNREGISTERED` | `invalid_device` (not retried) | **disabled / invalidated** |
| `transient` | HTTP 429, any 5xx, `QUOTA_EXCEEDED`, `RESOURCE_EXHAUSTED`, `UNAVAILABLE`, `INTERNAL`, `UNSPECIFIED_ERROR`, `DEADLINE_EXCEEDED` | retried (1m/5m/15m/1h ladder), `dead` after 5 attempts | untouched |
| `configuration` | `SENDER_ID_MISMATCH`, `THIRD_PARTY_AUTH_ERROR`, `UNAUTHENTICATED`, `PERMISSION_DENIED`, and any 401 / 403 / 404 that does not carry `UNREGISTERED` | retried (a fix to the Firebase configuration inside the window recovers it), `dead` after 5 attempts; logged once per failure with status and code only | untouched |
| `rejected` | anything else, e.g. `INVALID_ARGUMENT` | `dead` (not retried) | untouched |

The database side is covered too: no failure path other than `p_invalidate_device => true` changes
`enabled` or `invalidated_at` (a failure only increments `failure_count`). Neither the device token, the
OAuth token nor the service-account JSON is logged. The APNs path is unchanged.

### Android active-device invariant

`price_alert_push_devices_one_active_per_install_idx` is on `(installation_id, bundle_id, apns_environment)`;
Android rows have a NULL environment and NULLs are distinct in a unique index, so it never constrained Android.
Migration `20261006000000_price_alert_android_active_device_uniqueness` adds a partial unique index on
`(installation_id, bundle_id) WHERE platform = 'android' AND enabled AND invalidated_at IS NULL`. It never
modifies data: it raises (a count, no token) if duplicates already exist; production has no devices.
`price-alerts-api` `registerDevice` now starts its transaction with
`select id from private.price_alert_installations where id = $1 for no key update`, so concurrent
registrations for one installation run one after the other and the second deactivates the first's token
instead of failing on the index. Only that installation's row is locked (measured: another installation's
registration returned in ~40 ms while the first was locked, the competing one waited for the release);
`NO KEY UPDATE` does not block foreign-key checks from alert or device inserts. iOS semantics are unchanged.

### Migration order

Production applied `20261005211547` first; `20261005120000` is pending. Replays on a scratch PostgreSQL 16
(stand-ins for `pg_cron`, `pg_net`, Vault only) prove the two orders end in the **same** catalog: the
chronological chain `... 120000 → 211547 → 233000 → 20261006000000`, and the production order (`211547`
already applied) then `120000`, `233000`, `20261006000000`. `20261005120000` only replaces
`claim_price_alert_jobs` and the v1 claim, adds one index and the inactive cron job; it does not touch any
object `20261005211547` created. Between migrations of a single push the live claim path is briefly
un-hardened (nothing calls it: cron is inactive, tables are empty), so apply them in the same push.

### Exact migration procedure (future, needs explicit authorization)

Verified with Supabase CLI **2.119.0** (`supabase db push --help`: `--include-all` "Include all migrations not
found on remote history table", `--dry-run`, `--skip-vault`) against a scratch database whose migration
ledger mirrors production's 40 rows, using the real repository migration files:

| Command (dir = a copy of the repo `supabase/`) | Result |
|---|---|
| `db push --dry-run`, promo present | `DbPushMissingRemoteError`: local migrations older than the latest remote one (`20260921000000` promo, `20261005120000`); asks for `--include-all` |
| `--include-all --dry-run`, promo present | would apply promo + three Price Alerts migrations: **not acceptable** |
| `db push --dry-run`, promo excluded | the same error for `20261005120000` only |
| `--include-all --dry-run`, promo excluded | **exactly** `20261005120000`, `20261005233000`, `20261006000000` |

`--skip-vault` is accepted and is a no-op for this repository (`config.toml` defines no Vault secrets); keep
it so the push can never touch Vault. A real push of the exact plan into the scratch database recorded only
those three versions, did not re-run `20261005211547` or any recovered growth migration, left the promo version
absent, and produced a catalog identical to the chronological replay; a second dry-run then reported "up to date".

Production procedure, in a **temporary deployment copy** of `supabase/` (nothing is committed):

1. Remove `supabase/migrations/20260921000000_promo_campaign_foundation.sql` from the copy. This is the only
   exclusion. Do not add placeholder files; do not run `supabase migration repair`.
2. `supabase db push --linked --include-all --dry-run --skip-vault` — the list **must be exactly**
   `20261005120000_price_alert_worker_scheduler_and_freshness.sql`,
   `20261005233000_price_alert_cross_platform_delivery_safety.sql`,
   `20261006000000_price_alert_android_active_device_uniqueness.sql`. Anything else (promo,
   `20261005211547`, a growth migration): stop.
3. Only then, with authorization: the same command without `--dry-run`.
4. Verify: the ledger contains the three versions and not `20260921000000`; `private.invoke_price_alerts_worker()`,
   `price_alert_jobs_stuck_processing_idx` and `price_alert_push_devices_one_active_android_per_install_idx`
   exist; `85blends-price-alerts-worker-invoke` exists with `active = false`.

### Current activation order (supersedes the original one above)

Each step is separately authorized; stop at the first failed check.

1. Re-verify production read-only (versions, ledger, secrets by **name**, empty tables, no scheduler).
2. Apply the three migrations as described above; verify; the worker cron job must exist **inactive**.
3. Deploy `price-alerts-api` from this branch (whole directory, `verify_jwt = false`), by name; verify its
   metadata and that an unauthenticated POST is rejected by the application (401).
4. Deploy `price-alerts-worker` from this branch (whole directory: `index.ts`, `auth.ts`, `fcm.ts`,
   `deno.json`; `verify_jwt = false`), by name; run `deno check` first; verify metadata and the unauthenticated
   401. Do not deploy any other function.
5. Run `select private.invoke_price_alerts_worker();` **once** and check the `net._http_response` row (expect
   200; zero work with empty tables).
6. Activate the job only after steps 1-5 pass:
   `select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke'), active := true);`
7. Watch several minutes of `cron.job_run_details`, `net._http_response` and the Edge logs (queries above).

### Open items (not changed here)

- `FIREBASE_SERVICE_ACCOUNT_JSON` presence is unverified; without it the Android claim path is not called (see
  above). The same holds for iOS and the APNs secrets.
- The recovered growth migrations match production's *definitions*; production has since changed operational
  state they do not describe (for example the App Store growth sync cron job was created inactive by
  `20260927065816` and is now active).
- Neither `price-alerts-api` nor the worker's provider calls have a fetch timeout.

## Validation (this change)

- `node --test supabase/functions/**/*.test.ts` (auth, contract, FCM classification, shared).
- Full migration chain replayed on a scratch PostgreSQL 16 in chronological order and in production order;
  final catalogs identical. `supabase/tests/price_alert_worker_readiness.test.sql`,
  `price_alert_worker_concurrency.test.sh`, `price_alert_cross_platform_delivery_safety.test.sql`,
  `price_alert_cross_platform_concurrency.test.sh`, `price_alert_android_active_device_uniqueness.test.sql`
  and `price_alert_api_android_registration.test.sh` (the real API under Deno) all pass on both databases
  (see `supabase/tests/README.md`).
- Mutation testing of the delivery-safety migration, the Android index, the registration lock and the FCM
  classifier; see the PR description for the result.

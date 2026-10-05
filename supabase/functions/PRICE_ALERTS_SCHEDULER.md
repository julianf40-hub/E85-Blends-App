# Price Alerts worker scheduler — readiness runbook (2.4.1)

**Status: prepared, NOT deployed, NOT applied.** Nothing in this document has been run against the
production project (`zefkbtscieokkdenvnkg`). The migration, the worker auth change and the cron job
described here only take effect when someone performs the steps in
[Activation order](#activation-order). No secret value appears in this repository; only secret
*names* are used.

## Why this exists

Verified read-only against production on 2026-10-05:

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

The worker is currently deployed with `verify_jwt = true` and additionally requires
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

| Name | Where | Used by | State observed 2026-10-05 |
|---|---|---|---|
| `project_url` | Vault | `invoke_price_alerts_worker()` | present (shared with the App Store sync job) |
| `price_alerts_worker_cron_token` | Vault | `invoke_price_alerts_worker()` | **missing** — must be created |
| `PRICE_ALERTS_WORKER_CRON_SECRET` | Edge Function secret | worker `auth.ts` (same value as the Vault token) | **not set** (code does not exist in production yet) |
| `SUPABASE_SERVICE_ROLE_KEY` | Edge Function (platform-provided) | worker `auth.ts` (operator path) | provided by the platform; not inspected |
| `SUPABASE_DB_URL` | Edge Function (platform-provided) | worker | not inspected |
| `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY_P8` | Edge Function secrets | worker `sendApns` | **unknown** — no read-only way to list Edge Function secrets; without all three the worker returns `prepared_only` and never claims or sends deliveries |

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

## Activation order

Each step is a deliberate, separately authorized action. The new worker-invocation cron job is created
**inactive**; see [what takes effect when the migration is applied](#what-takes-effect-when-the-migration-is-applied)
for what is *not* inactive.

1. Generate one secret value `S` (≥ 32 random characters), for example `openssl rand -hex 32`.
2. Set Edge Function secret `PRICE_ALERTS_WORKER_CRON_SECRET = S`. Confirm the three `APNS_*` secrets
   exist (if they are missing the scheduler is still safe: the worker stays `prepared_only`).
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
v1.** v1 has `verify_jwt = true`; its platform gate rejects the dedicated-header scheduler request
(no JWT), so an active job against v1 produces a 401 every minute while cron itself still reports
success.

1. **Stop the scheduler:**
   `select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke'), active := false);`
   (or `select cron.unschedule('85blends-price-alerts-worker-invoke');`). In-flight pg_net requests
   still complete; claimed deliveries whose worker dies are reclaimed after 15 minutes.
2. **Roll the Edge Function back** (optional, only after step 1): redeploy the previous version with its
   previous `verify_jwt` setting. Removing the `PRICE_ALERTS_WORKER_CRON_SECRET` secret is optional;
   an unset secret simply disables the header path.
3. **Revert the SQL function replacements** (optional — they are safe to leave in place). Re-create the
   previous definitions from the repository history, running only the function statements and their
   `revoke`/`grant` lines:
   - `private.claim_price_alert_jobs(integer)` → from `supabase/migrations/20260917232104_price_alert_worker_primitives.sql`
   - `private.claim_price_alert_deliveries(integer)` → from `supabase/migrations/20260918001525_price_alert_delivery_claim_payload.sql`
     (that migration drops and re-creates the function; return shape is identical)
   - then remove the additions:
     `drop index if exists private.price_alert_jobs_stuck_processing_idx;`
     `drop function if exists private.invoke_price_alerts_worker();`
     `select cron.unschedule('85blends-price-alerts-worker-invoke');`
   The migration's row in the migration ledger stays; that is expected.
4. **Irreversible effects:** deliveries already expired to `skipped` (`stale_report` /
   `device_unusable`) are terminal and are not re-queued by any rollback. Re-sending one would need a
   manual update and is deliberately not recommended (it is stale or undeliverable by definition).

| Situation | Effect | Action |
|---|---|---|
| Cron activated, then the worker fails (5xx / APNs outage) | Deliveries stay pending/failed and retry; nothing is lost; stale ones expire after 2 h | Step 1, fix, re-activate |
| Wrong scheduler secret (Vault ≠ Edge) | Every call returns 401; cron still shows success | Step 1, fix one side, re-activate; detect with the health checks |
| Wrong/invalid `project_url` or token in Vault | The invoker raises; `failed` in `cron.job_run_details`; no request is sent | Fix the Vault value |
| APNs failure | Retryable failures follow the 1m / 5m / 15m / 1h ladder, then `dead`; invalid tokens disable the device | None needed |
| Auth regression in worker v2 | 401s | Step 1, then roll back (step 2) |
| Migration applied, worker not yet deployed (v1 live) | Cron is inactive, nothing calls the worker; the new claim logic is live for the job-prep cron | Continue the activation order |
| Worker v2 deployed, migration not applied | Extra auth path only; the old claim functions still work | Continue the activation order |

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
- HTTP outcomes: `401` = secret mismatch (or the v1 JWT gate), `405` = not a POST, `503` =
  `SUPABASE_DB_URL` missing, `500` = internal error, `200` + `prepared_only` = APNs secrets not all
  present.

```sql
-- 1. cron health (the new job)
select status, count(*), max(start_time)
from cron.job_run_details
where jobid = (select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke')
group by status;

-- 2. worker HTTP outcomes (last 6 h). net._http_response covers EVERY pg_net request, so classify by body.
select status_code,
       case when content like '%"status":"ok"%'       then 'worker ok'
            when content like '%prepared_only%'       then 'worker prepared_only (APNs secrets missing)'
            when content like '%unauthorized%'        then 'worker 401 (scheduler secret mismatch)'
            when content like '%server_not_configured%' then 'worker 503 (SUPABASE_DB_URL)'
            when content like '%internal_error%'      then 'worker 500'
            when content ilike '%authorization%'      then 'platform JWT gate (v1 still deployed?)'
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
| Burst limit | worker `delivery_limit` 50 per run, one run per minute | Already enforced by the invoker body; combined with the 2 h window this caps recovery to a bounded drain. Per-device APNs collapse ids (`station-<id>`) additionally merge repeats. |

Not changed: `prepare_price_alert_deliveries` (still creates rows for any report; stale ones are
expired at claim time), the worker's APNs logic, the retry ladder, the API function.

## Known gaps / follow-ups (not part of this change)

- A job that reaches `attempt_count = 5` while stuck is no longer reclaimed and is not auto-marked
  `dead`; it stays visible in the queue-health queries above.
- Whether `SUPABASE_SERVICE_ROLE_KEY` (legacy JWT key) remains valid is unverified; the scheduler no
  longer depends on it.
- `claim_price_alert_deliveries` scans the deliveries table on every worker run (it did before this
  change, because of its `processing` branch; the new sweep adds about 17 ms at 200,000 deliveries,
  ~48 ms total vs ~31 ms). Deliveries accumulate (nothing prunes them), so if this ever matters a
  partial index on the non-terminal statuses (`pending`, `failed`, `processing`) is the straightforward
  follow-up. It is intentionally not added now.
- The worker's APNs `fetch` has no timeout (pre-existing). A hung call leaves its rows `processing`
  until the 15-minute reclaim, which can produce a duplicate push, bounded by the 2-hour window.
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

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
| Scheduler function + cron job (created **inactive**) | `supabase/migrations/20261005120000_price_alert_worker_scheduler_and_freshness.sql` | Adds `private.invoke_price_alerts_worker()` and job `85blends-price-alerts-worker-invoke`. |
| Stale-job recovery | same migration (`claim_price_alert_jobs`) | Reclaims stuck `processing` jobs; never reclaims a job still waiting on deliveries. |
| Freshness guard | same migration (`claim_price_alert_deliveries`) | Never sends, and expires, deliveries whose report is older than 2 hours. |
| Worker caller auth | `supabase/functions/price-alerts-worker/auth.ts`, `index.ts`, `supabase/config.toml` | Accepts a dedicated scheduler secret header **or** the existing service-role Bearer; `verify_jwt = false`. |
| Tests | `supabase/tests/price_alert_worker_readiness.test.sql`, `supabase/functions/price-alerts-worker/auth.test.ts` | See [Validation](#validation). |

No client-visible secret is involved. The worker API contract (POST, optional `job_limit` /
`delivery_limit`, response shapes) and the `price-alerts-api` function are unchanged.

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
with a CSPRNG (for example `openssl rand -hex 32`), never reuse it, and never commit it.

## Secret names (values are never stored in git)

| Name | Where | Used by | State observed 2026-10-05 |
|---|---|---|---|
| `project_url` | Vault | `invoke_price_alerts_worker()` | present (shared with the App Store sync job) |
| `price_alerts_worker_cron_token` | Vault | `invoke_price_alerts_worker()` | **missing** — must be created |
| `PRICE_ALERTS_WORKER_CRON_SECRET` | Edge Function secret | worker `auth.ts` (same value as the Vault token) | **not set** (code does not exist in production yet) |
| `SUPABASE_SERVICE_ROLE_KEY` | Edge Function (platform-provided) | worker `auth.ts` (operator path) | provided by the platform; not inspected |
| `SUPABASE_DB_URL` | Edge Function (platform-provided) | worker | not inspected |
| `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY_P8` | Edge Function secrets | worker `sendApns` | **unknown** — no read-only way to list Edge Function secrets; without all three the worker returns `prepared_only` and never claims or sends deliveries |

## Activation order

Each step is a deliberate, separately authorized action. The new cron job is created **inactive**, so
applying the migration alone changes no runtime behavior.

1. Generate one secret value `S` (≥ 32 random characters).
2. Set Edge Function secret `PRICE_ALERTS_WORKER_CRON_SECRET = S`. Confirm the three `APNS_*` secrets
   exist (if they are missing the scheduler is still safe: the worker stays `prepared_only`).
3. Create Vault secret `price_alerts_worker_cron_token = S`
   (for example `select vault.create_secret('<S>', 'price_alerts_worker_cron_token');` run by an operator).
4. Deploy the worker from `main` **with `verify_jwt` off** (for example
   `supabase functions deploy price-alerts-worker --no-verify-jwt`), so `auth.ts` is bundled with
   `index.ts`. Until this step the deployed worker (v1) still has `verify_jwt = true` and the old
   Bearer-only check; the repository is intentionally ahead of production here.
5. Smoke test: an unauthenticated `POST` must return `401 {"error":"unauthorized"}`.
6. Apply the migration (job is created inactive).
7. Run `select private.invoke_price_alerts_worker();` once and check the response (see
   [Observability](#observability)); with an empty queue the worker returns `prepared_only` or `ok`
   with zero counters.
8. Activate the job:
   `select cron.alter_job((select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke'), active := true);`
9. Watch the first several minutes of `cron.job_run_details`, `net._http_response` and the Edge logs.

**Rollback:** `select cron.alter_job(<jobid>, active := false);` (or `cron.unschedule('85blends-price-alerts-worker-invoke')`).
The invoker function and the new claim logic are harmless while the job is inactive. Re-applying the
migration never re-activates, re-schedules or duplicates the job.

## Observability

- Misconfiguration (missing Vault secret, short token) raises
  `price_alerts_worker_scheduler_not_configured` **inside the cron job**, so it shows as `failed` in
  `cron.job_run_details`.
- `pg_net` is asynchronous: a queued request counts as a successful cron run even if the HTTP call
  later fails. HTTP outcomes appear in `net._http_response` (retained only briefly) and in the Edge
  Function logs: `401` = secret mismatch, `405` = not a POST, `503` = `SUPABASE_DB_URL` missing,
  `500` = internal error, `200` with `status: prepared_only` = APNs secrets not all present.

```sql
-- cron health (the new job)
select status, count(*), max(start_time)
from cron.job_run_details
where jobid = (select jobid from cron.job where jobname = '85blends-price-alerts-worker-invoke')
group by status;

-- recent HTTP outcomes (short retention)
select status_code, count(*), max(created) from net._http_response group by status_code;

-- queue health: anything old or stuck? (aggregates only)
select status, count(*), min(created_at) as oldest from private.price_alert_jobs group by status;
select status, count(*), min(created_at) as oldest from private.price_alert_deliveries group by status;
select count(*) as jobs_processing_gt_1h from private.price_alert_jobs
 where status = 'processing' and locked_at < now() - interval '1 hour';
```

## Stale-work design and thresholds

| Rule | Value | Reasoning |
|---|---|---|
| Reclaim a stuck `processing` job | locked > **15 min**, no pending/processing/failed deliveries, `attempt_count < 5` | Same 15-minute window the delivery claim already uses; 5 is the dead-letter limit the worker/cron already pass. The delivery check is essential: `finalize_price_alert_job` deliberately keeps a job `processing` while any delivery waits or retries (retry delays are 1m / 5m / 15m / 1h; with the worker's 5-attempt cap the 4h step is never reached, so a healthy job can wait about 81 min), so lock age alone would reprocess healthy jobs. Reprocessing is idempotent (`ON CONFLICT DO NOTHING` per alert/report/device). |
| Freshness window | report `reported_at` within **2 h** | `reported_at` is the observation time: it is bounded to [now − 7 d, now + 10 min] and so also stops a back-dated report from producing a "now" alert. 2 h is longer than the whole retry horizon (attempts at 0 / 1 / 6 / 21 / 81 min, then `dead`), so no legitimate retry is cut off, and it bounds any post-outage backlog to two hours of reports. |
| Expiry action | delivery → terminal `skipped`, `last_error_code = 'stale_report'`, then `finalize_price_alert_job` | Reuses an existing terminal state (no schema change); the job can complete; fully idempotent. |
| Burst limit | worker `delivery_limit` 50 per run, one run per minute | Already enforced by the invoker body; combined with the 2 h window this caps recovery to a bounded drain. Per-device APNs collapse ids (`station-<id>`) additionally merge repeats. |

Not changed: `prepare_price_alert_deliveries` (still creates rows for any report; stale ones are
expired at claim time), the worker's APNs logic, the retry ladder, the API function.

## Known gaps / follow-ups (not part of this change)

- A job that reaches `attempt_count = 5` while stuck is no longer reclaimed and is not auto-marked
  `dead`; it stays visible in the queue-health query above.
- Whether `SUPABASE_SERVICE_ROLE_KEY` (legacy JWT key) remains valid is unverified; the scheduler no
  longer depends on it.
- Pro gating at send time reads the RevenueCat ledger. A separate, unrelated production problem was
  found: the `revenuecat-webhook` cannot apply three SANDBOX events because their alias set bridges
  two existing customer rows (deliberate "refuse to merge" safety rule). That is an identity
  reconciliation task, not an authentication problem, and is intentionally not fixed here.

## Validation

- `node --test supabase/functions/price-alerts-worker/auth.test.ts` (14 tests) and the existing
  `node --test supabase/functions/_shared/*.test.ts` (387 tests).
- All migrations replayed in order on a scratch PostgreSQL 16 with stand-ins for `pg_cron`,
  `pg_net` and Vault, then `supabase/tests/price_alert_worker_readiness.test.sql` (see
  `supabase/tests/README.md`). The cron/pg_net call shapes were also compared against the
  production signatures (`cron.schedule`, `cron.alter_job`, `net.http_post`), read-only.

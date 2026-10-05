# Supabase SQL regression tests

Executable SQL regression matrices for the `private.*` referral and Price Alerts functions. They are **local-replay
only** — never run them against a hosted project. Each file runs in a single transaction that is
rolled back at the end and RAISEs on any unexpected outcome, so a run that prints the file's final
`ALL ... PASSED` line is a full pass and leaves the database unchanged.

## Running

```sh
# 1. Scratch Postgres 16+ (example: a throwaway cluster; any local instance works)
createdb e85_test
# 2. Replay the migration chain in version order. 20260918001657_price_alert_job_processor_cron.sql
#    requires pg_cron; it may be skipped locally — nothing in these tests depends on it.
for f in supabase/migrations/*.sql; do psql -v ON_ERROR_STOP=1 -d e85_test -f "$f"; done
# 3. Run the matrices
psql -v ON_ERROR_STOP=1 -d e85_test -f supabase/tests/referral_reward_active_product_fallback.test.sql
```

## Files

- `referral_reward_active_product_fallback.test.sql` — `claim_referral_reward` webhook-history
  fallback (migrations `20260929230218` + `20260930090000`: gating, subscription-state reduction,
  alias ownership), the reward/code state machine, and `fulfill_referral_reward_offer_code` (see
  the file header for the full scenario list).
- `price_alert_worker_readiness.test.sql` — Price Alerts worker scheduler + stale-work safety
  (migration `20261005120000`), single transaction: the pg_net invoker's configuration matrix (HTTPS
  origin only, token trimming/strength, fixed value-free errors, exact URL/header/body), the
  inactive-by-default and replay-idempotent cron job (active stays active, inactive stays inactive,
  no duplicate), stale-job reclaim incl. the exact 15-minute and attempt-limit boundaries and the
  jobs that must never be reclaimed, the 2-hour freshness guard incl. exact/±1 s/future boundaries,
  the bounded (500-row) expiry with partial-drain safety, disabled/invalidated-device handling, the
  supporting partial index and its query plan, and grants. Run it from the repository root (it
  `\ir`-includes the migration to prove replay idempotency). Unlike the referral matrix it DOES depend
  on cron: the migration calls `cron.schedule`/`cron.alter_job`, so the scratch database needs real
  `pg_cron` or a stand-in providing `cron.job`, `cron.schedule` and `cron.alter_job`. The invoker
  scenarios additionally need a recording stand-in for pg_net (`net.sent_requests`) and Vault
  (`vault.secrets` / `vault.decrypted_secrets`); they are skipped automatically when the real `pg_net`
  is present so the file can never send a request.
- `price_alert_worker_concurrency.test.sh` — the same migration's behavior that needs MORE THAN ONE
  session, so it cannot run in a single transaction: a stale delivery row or a job row locked by
  another transaction must not block a claim (`SKIP LOCKED`), one claim call expires at most 500 rows
  of a 20,000-row stale backlog, and two concurrent workers never double-claim, deadlock, or receive
  a stale delivery. Run it with the libpq environment (`PGHOST`/`PGPORT`/`PGUSER`/`PGDATABASE`) pointing
  at a scratch database with the migrations applied. It COMMITS its fixtures under a unique marker and
  deletes them on exit — never point it at a hosted project.
- `price_alert_cross_platform_delivery_safety.test.sql` — the cross-platform claim path
  (`claim_price_alert_deliveries_v2`, migrations `20261005211547` + `20261005233000`), single transaction,
  run on a database with the FULL chain applied (the same file passes on a chronological replay and on a
  database built in the production order): v2 shape, iOS/Android isolation (the sweep and the claim are
  per platform), the 2-hour freshness boundaries, stale and device-unusable expiry (stale wins,
  attempts not burned), retries, job finalization, argument validation, the iOS-only v1 wrapper, the
  bounded 500-row sweep per platform with fresh rows behind a stale backlog, partially drained unusable
  backlogs, pinned `search_path`, grants (no PUBLIC/anon/authenticated), cron inactive and unique, and an
  idempotent re-apply. It `\ir`-includes the compatibility migration, so run it from any directory.
- `price_alert_cross_platform_concurrency.test.sh` — the multi-session checks for the same path
  (a locked stale row, a locked FRESH row and a locked job row never block a claim; one call expires at
  most 500 of a 20,000-row backlog; two iOS plus two Android concurrent workers never double-claim,
  never cross platforms, never receive a stale delivery, and drain both platforms). Same environment
  rules as the other concurrency script; it COMMITS fixtures under a marker and removes them on exit.

The worker-side Node tests (`node --test supabase/functions/price-alerts-worker/*.test.ts`) include
`contract.test.ts`, which pins the scheduler's names together across the SQL invoker (Vault secret
names, header, URL path), the worker (`auth.ts`, `index.ts`, Edge secret name) and the runbook.

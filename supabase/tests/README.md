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
- `price_alert_payment_type.test.sql` — 2.4.1 Phase 3C: cash/credit/same-for-both report storage and
  grants, the comparable-stream rules, the pure `evaluate_price_alert_v2` decision function, and the
  `prepare_price_alert_deliveries` scenarios (cross-payment isolation, cumulative drops, cooldown and rearm,
  out-of-order and repeated reports, legacy alerts, Pro gate, fail-closed, anchoring, `same_for_both` price drops, the
  documented fail-closed pause, a notification that ends unsent not holding the cooldown, the `mark_sent` guard, and the
  station advisory lock) — see the file header for the scenario index. Phase 3C.1 added D25 (an OLDER client's save keeps a
  drop size a newer app chose, the engine keeps using it, and a declared client's deliberate 5¢ is applied), D26 (repeated
  identical saves are safe and leave the reference, notification memory and cooldown alone) and D27 (a legacy alert moves to
  Cash/Credit through the exact `set_alert` upsert). Run it on a database with the FULL chain applied.
- `price_alert_payment_type_migration.test.sh` — Phase 3C migrations A and B applied to "production-shaped"
  legacy data: nothing rewritten or backfilled, every report/alert/delivery preserved, no retroactive send, cron and
  Vault untouched, old and new clients both able to insert, idempotent re-apply. It builds its own scratch database.
- `price_alert_api_payment_type.test.sh` — Phase 3C: the REAL `price-alerts-api` under Deno on a local port, against a
  database with the full chain applied, driven over HTTP (A1–A16): an older client's `set_alert` (stored `unknown`, legacy
  0.05 / 360), the 2.4.1 app's payment type and drop size, edits that keep the method, `invalid_payment_type`, bounds,
  `list_alerts` (legacy latest vs comparable latest), re-anchoring when the method changes, non-Pro refusal, delete; and, from
  Phase 3C.1, the drop-size contract (A10 an older client's re-save keeps the size and the 2.4.1 app can still choose any size,
  5¢ included; A11 single-field edits; A12 sixteen malformed `alert_contract_version` values refused with nothing stored; A13
  repeated saves; A14 concurrent saves; A15 the Pro gate whatever the version; A16 a legacy alert moving to Cash then Credit).
  Needs deno, curl, jq, psql; COMMITS fixtures under a marker and removes them; refuses a non-local `PGHOST` **and a non-loopback
  `API_DB_URL` host** (the API under test writes through that URL). `API_DIR`
  points it at a different copy of the API (the rollout script uses that for the previous version).
- `price_alert_worker_message.test.sh` + `support/worker_with_recorded_fetch.ts` — Phase 3C: the REAL `price-alerts-worker`
  under Deno with `fetch()` replaced by a recorder (nothing is sent to Apple or Google; any other URL is refused): five alerts
  fire (iOS credit / legacy / cash at-or-below, Android credit / legacy) and the script checks exactly what would have been
  sent — copy, the additive `payment_type`, the legacy payload unchanged, the delivery rows' method. Needs deno, curl, jq,
  openssl (throwaway keys), psql and a FRESH replayed database (the worker claims every pending delivery it finds).
- `price_alert_payment_type_concurrency.test.sh` — Phase 3C multi-session checks (PC1-PC6): the cooldown race, the same
  report prepared twice at once, a concurrent burst through the real grants, `set_alert` racing a prepare, the lock-order
  deadlock between the job processor's multi-job transaction, a newly saved alert and a single prepare, and (3C.1) two
  saves of one alert racing each other — payment-only vs drop-size-only vs an older client — in four forced interleavings.
- `price_alert_rollout_compat.test.sh` — Phase 3C.1: the ROLLOUT COMPATIBILITY MATRIX. It builds throwaway databases in the
  three states production can be in (before migration A, A only, A + B), exports the PREVIOUS `price-alerts-api` and
  `price-alerts-worker` from git (`OLD_REV`, default the Phase 3B tip), and runs the previous and the new functions in each
  (M1 API × state, M2 worker × state, M3 a Cash/Credit alert with the previous worker). Then the transition scenarios: T1 a
  false alert between A and B, T2 a notification queued by the previous engine surviving B, T3 a job still queued when B is
  applied, T4 a B that fails, T4b an A that cannot get its lock (and what queues behind its pending request), T5 a report submitted
  while B runs, T6 the incident drill (pause decisions, pause the two jobs, cancel, resume - with the runbook queries telling the
  no-op from the real engine), T7 the lock window at `ROLLOUT_MEASURE_A_ROWS` rows (default 300000; 0 skips). Local-replay only: it refuses a
  non-local `PGHOST`, drops its own `e85_rollout*` databases, stubs the push providers, and reaches nothing outside the machine.
  Needs deno, curl, jq, openssl, psql, git, tar. The statements it runs in T6 are the ones in
  `docs/PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md` section 9.
- `support/` — `local_supabase_shims.sql` (stand-ins for the Supabase roles, `auth`/`vault`/`cron`/`net` that a plain
  Postgres lacks) and `replay_migrations.sh <database> [--before <version>]` (replays the migration chain onto a scratch
  database), and `worker_with_recorded_fetch.ts` (runs a worker copy — `WORKER_ENTRY` selects another one — with `fetch()`
  replaced by a recorder). Local use only.
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
- `price_alert_android_active_device_uniqueness.test.sql` — the Android invariant (migration
  `20261006000000`): the partial unique index on `(installation_id, bundle_id)` for active Android rows;
  a second active device is rejected by the database while other packages, other installations, disabled
  and invalidated rows are unrestricted; re-enabling is rejected while another is active; the exact
  statements `price-alerts-api` runs for a registration (lock, deactivate the others, upsert) leave one
  active token across sequential registrations (replacement active, previous disabled + invalidated);
  independent installations; iOS unchanged and coexisting with Android; idempotent re-apply.
- `price_alert_api_android_registration.test.sh` — starts the REAL `price-alerts-api` under Deno against a
  scratch database (needs `deno`, `curl`, `psql`; `API_DB_URL` if the server is not at `127.0.0.1:$PGPORT`)
  and drives it with concurrent HTTP registrations: 12 concurrent Android registrations x 5 rounds for one
  installation all return 200 and leave exactly one active token; independent installations; iOS unchanged
  and coexisting; the installation lock is per installation (an unrelated installation does not wait); the
  migration refuses to run, without touching data, when duplicate active Android rows already exist.
  Same environment rules as the other concurrency scripts; it COMMITS fixtures and removes them on exit.

The worker-side Node tests (`node --test supabase/functions/price-alerts-worker/*.test.ts`) include
`fcm.test.ts` (the FCM response classification: only an explicit `UNREGISTERED` invalidates a device; generic
404, `SENDER_ID_MISMATCH`, auth/config and provider errors never do; 429/5xx/`UNAVAILABLE`/`INTERNAL` are
retryable) and `contract.test.ts`, which pins the scheduler's names together across the SQL invoker (Vault secret
names, header, URL path), the worker (`auth.ts`, `index.ts`, Edge secret name) and the runbook.

The production-side companions are **not** tests and are not in this directory: `supabase/runbooks/` holds the read-only
preflight, verification and observation SQL and the Edge Function source-hash check for the Phase 3C rollout (see its README).

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
  (migration `20261005120000`): the pg_net invoker (config failures, exact URL/header/body), the
  inactive-by-default and re-apply-idempotent cron job, stale-job reclaim (and the cases that must
  never be reclaimed), the 2-hour freshness guard/expiry, a post-outage burst, and grants. Run it
  from the repository root (it `\ir`-includes the migration to prove re-apply idempotency). Unlike
  the referral matrix it DOES depend on cron: the migration calls `cron.schedule`/`cron.alter_job`,
  so the scratch database needs real `pg_cron` or a stand-in providing `cron.job`, `cron.schedule`
  and `cron.alter_job`. The invoker scenarios additionally need a recording stand-in for pg_net
  (`net.sent_requests`) and Vault; they are skipped automatically when the real `pg_net` is present
  so the file can never send a request.

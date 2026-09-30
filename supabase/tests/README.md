# Supabase SQL regression tests

Executable SQL regression matrices for the `private.*` referral functions. They are **local-replay
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

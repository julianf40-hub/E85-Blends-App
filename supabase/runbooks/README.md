# Price Alerts Phase 3C — production runbook files (read-only)

These four files support the rollout plan in [`docs/PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md`](../../docs/PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md).
They are **read-only**. Nothing in this directory applies a migration, deploys a function, changes a cron job, sends a
notification or creates a row, and **none of it has been run against production** — running any of it needs the project
owner's explicit authorization for that step.

| File | What it is | When | Rows / output the readiness document refers to |
|---|---|---|---|
| `price_alerts_3c_preflight_readonly.sql` | one `SELECT` inside a `READ ONLY` transaction, ~41 checks, each with its expectation | before anything changes; again for a before/after comparison | `target.*`, `migrations.*`, `reports.*`, `alerts.*`, `installations.*`, `devices.*`, `jobs.*`, `deliveries.*`, `cron.*`, `functions.*`, `vault.scheduler_secret_names`, `activity.*` (section 4) |
| `price_alerts_3c_verify_after_readonly.sql` | the same shape; what must be true after migration A and after migration B | right after each migration | `A.*`, `B.*`, `cron.jobs_unchanged` (section 7, step 4) |
| `price_alerts_3c_observe_readonly.sql` | the same shape; the last 60 minutes of decisions, queue, jobs and cron runs | +15 min, +1 h, +24 h after the rollout | `MUST_BE_ZERO.*`, `decisions_in_window_by_outcome`, `queued_now`, … (section 10) |
| `price_alerts_function_hashes.sh` | prints or compares the SHA-256 of every deployable file of the two Edge Functions (working tree or any git revision) against a directory of sources downloaded from the deployed functions | before a deploy (is production what we think it is?) and after (is it what we meant to ship?) | `RESULT: every file matches` (section 7, steps 1, 5, 6) |

## What they read, and what they never read

* Catalog tables, row **counts**, object **names**, schedules, version strings, timestamps, and `md5(prosrc)` of two functions.
* **Never** `vault.decrypted_secrets` (only the *names* in `vault.secrets`), never `cron.job.command`, never device tokens,
  installation secrets, RevenueCat identities, contributor ids, station or alert contents. The output can be pasted into a ticket.
* Each SQL file starts `begin read only;` and ends `rollback;`, so even a pasted-in mistake cannot write.

## How to run (only when authorized)

```sh
psql -X -f supabase/runbooks/price_alerts_3c_preflight_readonly.sql          # production connection string in PG* variables
# or paste the SELECT (from "select check_name" to the final ";") into the Supabase SQL editor
bash supabase/runbooks/price_alerts_function_hashes.sh                        # sha256 of the working tree
bash supabase/runbooks/price_alerts_function_hashes.sh --rev <git-rev> --against <dir-of-downloaded-functions>
```

`<dir>` holds one sub-directory per function (`price-alerts-api/`, `price-alerts-worker/`), e.g. from
`supabase functions download <name> --project-ref <ref> --use-api`. Exit status 0 only when every file matches and the deployed
copy has no extra file.

## How they were validated (locally; production untouched)

* The three SQL files run on a scratch Postgres 16 with the migration chain replayed and a stand-in
  `supabase_migrations.schema_migrations`: the preflight on the **pre-A** schema (the "A/B not applied" rows say so) and again
  after A + B; the verification file after A and after A + B; the observation file after A + B with live-looking data. The
  cross-payment check was proven by forging one delivery and watching `MUST_BE_ZERO.notifications_for_a_non_comparable_report` flag it.
* The hash helper was run against a directory built from git (all `MATCH`) and against copies with one byte changed, one file
  missing and one extra file (`DIFFER`, `MISSING`, `EXTRA`, exit status 1).
* They are written against what the hosted project is reported to have (`supabase_migrations`, `cron`, `vault`, `pg_net`) and
  against the schemas the migrations create; the hosted Postgres major version is not known here (the local runs were 16.15),
  and that is the one thing a local replay cannot prove. A row that errors on the hosted project is a finding to report, not
  something to work around by editing the query.

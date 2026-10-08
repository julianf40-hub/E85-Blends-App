-- 85Blends 2.4.1 — Price Alerts Phase 3C: READ-ONLY PRODUCTION PREFLIGHT.
--
-- ONE SELECT. It reads catalog tables and counts; it writes nothing, creates nothing, takes no lock beyond the
-- ACCESS SHARE of an ordinary read, and calls no function that has a side effect. Run it BEFORE migration A, save the
-- result next to the date and the project (see docs/PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md, section 4), and compare every
-- row with its "expect" column. A row that does not match is a STOP: do not proceed, report it.
--
-- How to run it (only when the owner has authorized the preflight):
--   * psql against the production connection string:     psql -X -f supabase/runbooks/price_alerts_3c_preflight_readonly.sql
--     (the statement below is wrapped in a READ ONLY transaction, so even a pasted-in mistake cannot write), or
--   * the Supabase SQL editor: paste the SELECT (from "select" to the final ";") as it is.
--
-- It prints NO secret and no personal data: counts, names of objects, schedules, version strings and timestamps. It
-- deliberately does NOT read vault.decrypted_secrets (only the NAMES in vault.secrets) and does not read cron.job.command.
--
-- Written against the migration chain replayed locally (Postgres 16); it uses only objects the hosted project has
-- (supabase_migrations, cron, vault, information_schema, pg_catalog). It is also valid AFTER migrations A and B (the
-- rows that describe "not yet applied" then simply say so), so the same file can be re-run as a before/after comparison.

begin read only;

select check_name, value, expectation
from (
  -- ---- A. what we are talking to -------------------------------------------------------------------------------------
  select 10 as ord, 'target.postgres_version' as check_name, version() as value,
         'record it (the tests ran on 16.x)' as expectation
  union all
  select 11, 'target.extensions',
         coalesce((select string_agg(extname || ' ' || extversion, ', ' order by extname) from pg_extension
                   where extname in ('pg_cron', 'pg_net', 'pgcrypto', 'supabase_vault')), '(none)'),
         'pg_cron and pg_net present'
  union all
  select 12, 'target.server_time', now()::text, 'record it; compare with the cron run times below'
  union all
  select 13, 'target.client_role_statement_timeouts',
         coalesce((select string_agg(rolname || ': ' || coalesce((select substring(c from '^statement_timeout=(.*)$') from unnest(rolconfig) c
                                                                    where c like 'statement_timeout=%'), '(default)'), '; ' order by rolname)
                   from pg_roles where rolname in ('anon', 'authenticated')), '(roles missing)'),
         'record it: a report submitted while a migration holds its lock waits at most this long (Supabase documents 3s for anon) before the app sees a failure'

  -- ---- B. migration history -------------------------------------------------------------------------------------------
  union all
  select 20, 'migrations.applied_count', (select count(*)::text from supabase_migrations.schema_migrations), 'record it'
  union all
  select 21, 'migrations.latest_five',
         (select string_agg(version, ', ' order by version desc)
          from (select version from supabase_migrations.schema_migrations order by version desc limit 5) v),
         'the newest should be 20261006000000 or older work already in the repo; NOT 20261007120000 / 20261007130000'
  union all
  select 22, 'migrations.phase3c_already_applied',
         (select count(*)::text from supabase_migrations.schema_migrations where version in ('20261007120000', '20261007130000')),
         '0 before the rollout (A and B not applied yet)'
  union all
  select 23, 'migrations.prerequisites_present',
         (select count(*)::text from supabase_migrations.schema_migrations
          where version in ('20261005120000', '20261005211547', '20261005233000', '20261006000000')),
         '4 (the scheduler, cross-platform push, delivery-safety and Android uniqueness migrations B depends on)'

  -- ---- C. the reports table (migration A changes it) ----------------------------------------------------------------
  union all
  select 30, 'reports.rows', (select count(*)::text from public.e85_price_reports),
         'record it: migration A takes an ACCESS EXCLUSIVE lock for as long as its CHECK validation and index build take (about 0.3 s per 300k rows locally)'
  union all
  select 31, 'reports.total_size', pg_size_pretty(pg_total_relation_size('public.e85_price_reports')), 'record it'
  union all
  select 32, 'reports.reports_last_24h', (select count(*)::text from public.e85_price_reports where created_at > now() - interval '24 hours'),
         'record it: how busy report submission is (the quiet hours are the window)'
  union all
  select 33, 'reports.newest_report_age', coalesce((select (now() - max(created_at))::text from public.e85_price_reports), '(no reports)'), 'record it'
  union all
  select 34, 'reports.payment_type_column_exists',
         (select count(*)::text from information_schema.columns
          where table_schema = 'public' and table_name = 'e85_price_reports' and column_name = 'payment_type'),
         '0 before migration A'
  union all
  select 35, 'reports.insert_columns_anon',
         coalesce((select string_agg(column_name, ',' order by column_name) from information_schema.column_privileges
                   where table_schema = 'public' and table_name = 'e85_price_reports' and grantee = 'anon' and privilege_type = 'INSERT'), '(none)'),
         'anonymous_reporter_id,app_version,note,price,reported_at,station_id  (column-scoped; no id, no created_at)'
  union all
  select 36, 'reports.insert_columns_authenticated',
         coalesce((select string_agg(column_name, ',' order by column_name) from information_schema.column_privileges
                   where table_schema = 'public' and table_name = 'e85_price_reports' and grantee = 'authenticated' and privilege_type = 'INSERT'), '(none)'),
         'the same list as anon'
  union all
  select 37, 'reports.update_or_delete_grants_for_clients',
         (select count(*)::text from information_schema.column_privileges
          where table_schema = 'public' and table_name = 'e85_price_reports'
            and grantee in ('anon', 'authenticated') and privilege_type in ('UPDATE', 'DELETE'))
         || ' + ' ||
         (select count(*)::text from information_schema.role_table_grants
          where table_schema = 'public' and table_name = 'e85_price_reports'
            and grantee in ('anon', 'authenticated') and privilege_type in ('UPDATE', 'DELETE')),
         '0 + 0 (reports are immutable to clients)'
  union all
  select 38, 'reports.rls_enabled', (select relrowsecurity::text from pg_class where oid = 'public.e85_price_reports'::regclass), 'true'
  union all
  select 39, 'reports.policies',
         coalesce((select string_agg(policyname || ' (' || cmd || ')', ', ' order by policyname) from pg_policies
                   where schemaname = 'public' and tablename = 'e85_price_reports'), '(none)'),
         'record it; migration A does not change any policy'
  union all
  select 40, 'reports.user_triggers',
         coalesce((select string_agg(tgname, ', ' order by tgname) from pg_trigger
                   where tgrelid = 'public.e85_price_reports'::regclass and not tgisinternal), '(none)'),
         'record it (the rate limiter, the alert-job enqueue, the growth refresh)'

  -- ---- D. Price Alerts data -----------------------------------------------------------------------------------------
  union all
  select 50, 'alerts.total_and_enabled',
         (select count(*)::text || ' / ' || count(*) filter (where enabled)::text from private.price_alerts), 'record it'
  union all
  select 51, 'alerts.by_mode',
         coalesce((select string_agg(alert_mode || '=' || n::text, ', ' order by alert_mode)
                   from (select alert_mode, count(*) as n from private.price_alerts group by 1) m), '(none)'),
         'record it: any_change alerts, if any, are the ones the app carries instead of rewriting'
  union all
  select 52, 'alerts.minimum_change_values',
         coalesce((select string_agg(minimum_change::text || ' x' || n::text, ', ' order by minimum_change)
                   from (select minimum_change, count(*) as n from private.price_alerts group by 1) m), '(none)'),
         'record it: if every value is 0.050 there is no chosen drop size to protect yet (a past reset by an older client would look the same); other values are exactly what the drop-size contract keeps safe'
  union all
  select 53, 'alerts.cooldown_values',
         coalesce((select string_agg(cooldown_minutes::text || ' x' || n::text, ', ' order by cooldown_minutes)
                   from (select cooldown_minutes, count(*) as n from private.price_alerts group by 1) m), '(none)'),
         'record it'
  union all
  select 54, 'alerts.by_platform',
         coalesce((select string_agg(client_platform || '=' || n::text, ', ' order by client_platform)
                   from (select i.client_platform, count(*) as n from private.price_alerts a
                         join private.price_alert_installations i on i.id = a.installation_id group by 1) m), '(none)'),
         'record it: Android alerts stay legacy until an Android update; iOS alerts become legacy too until their owner picks a price type'
  union all
  select 55, 'installations.by_platform_and_app_version',
         coalesce((select string_agg(client_platform || ' ' || coalesce(app_version, '-') || ' x' || n::text, '; ' order by client_platform, app_version)
                   from (select client_platform, app_version, count(*) as n from private.price_alert_installations group by 1, 2) m), '(none)'),
         'record it: tells which client generations exist at all'
  union all
  select 56, 'devices.enabled_by_platform',
         coalesce((select string_agg(platform || '=' || n::text, ', ' order by platform)
                   from (select platform, count(*) as n from private.price_alert_push_devices where enabled and invalidated_at is null group by 1) m), '(none)'),
         'record it'
  union all
  select 57, 'jobs.by_status',
         coalesce((select string_agg(status || '=' || n::text, ', ' order by status)
                   from (select status, count(*) as n from private.price_alert_jobs group by 1) m), '(none)'),
         'record it. DRAIN REQUIREMENT: no pending, processing or failed job before migration B'
  union all
  select 58, 'jobs.oldest_not_completed_age',
         coalesce((select (now() - min(created_at))::text from private.price_alert_jobs where status in ('pending', 'processing', 'failed')), '(none)'),
         '(none) before migration B'
  union all
  select 59, 'deliveries.by_status',
         coalesce((select string_agg(status || '=' || n::text, ', ' order by status)
                   from (select status, count(*) as n from private.price_alert_deliveries group by 1) m), '(none)'),
         'record it. Nothing is re-sent or rewritten by A or B; pending/processing rows are left to the worker'
  union all
  select 60, 'deliveries.queued_now',
         (select count(*)::text from private.price_alert_deliveries where status in ('pending', 'processing', 'failed')),
         'ideally 0 before migration B (a queued delivery still holds its alert''s cooldown, so it is safe, just less tidy)'
  union all
  select 61, 'deliveries.sent_last_24h',
         (select count(*)::text from private.price_alert_deliveries where status = 'sent' and sent_at > now() - interval '24 hours'),
         'record it: the baseline for "alerts still go out" after the rollout'

  -- ---- E. the scheduler ---------------------------------------------------------------------------------------------
  union all
  select 70, 'cron.jobs',
         coalesce((select string_agg(coalesce(jobname, '(unnamed #' || jobid::text || ')') || ' [' || schedule || '] ' || case when active then 'active' else 'inactive' end, '; '
                                     order by coalesce(jobname, jobid::text))
                   from cron.job), '(none)'),
         'both 85blends-price-alert-job-prepare and 85blends-price-alerts-worker-invoke ACTIVE (owner-reported); record the others'
  union all
  select 71, 'cron.price_alert_runs_last_24h',
         coalesce((select string_agg(j.jobname || ': ' || d.status || ' x' || d.n::text, '; ' order by j.jobname, d.status)
                   from cron.job j
                   join (select jobid, status, count(*) as n from cron.job_run_details
                         where start_time > now() - interval '24 hours' group by 1, 2) d on d.jobid = j.jobid
                   where j.jobname in ('85blends-price-alert-job-prepare', '85blends-price-alerts-worker-invoke')), '(none)'),
         'every run succeeded; none failed'
  union all
  select 72, 'cron.price_alert_last_run_ago',
         coalesce((select string_agg(j.jobname || ': ' || (now() - r.last_start)::text, '; ' order by j.jobname)
                   from cron.job j
                   join (select jobid, max(start_time) as last_start from cron.job_run_details group by 1) r on r.jobid = j.jobid
                   where j.jobname in ('85blends-price-alert-job-prepare', '85blends-price-alerts-worker-invoke')), '(none)'),
         'about a minute for each active job'

  -- ---- F. the functions migration B replaces, and the secrets the scheduler uses (names only) -------------------------------
  union all
  select 80, 'functions.prepare_md5',
         coalesce((select md5(prosrc) from pg_proc where oid = to_regprocedure('private.prepare_price_alert_deliveries(uuid)')), '(missing)'),
         'RECORD IT: the hash of the engine being replaced. After migration B it must differ; it is the proof of what was there'
  union all
  select 81, 'functions.mark_sent_md5',
         coalesce((select md5(prosrc) from pg_proc where oid = to_regprocedure('private.mark_price_alert_delivery_sent(uuid,integer)')), '(missing)'),
         'RECORD IT (same reason)'
  union all
  select 82, 'functions.engine_v2_exists',
         coalesce((select 'yes' from pg_proc where oid = to_regprocedure('private.evaluate_price_alert_v2(text,numeric,numeric,integer,numeric,numeric,interval,numeric,timestamptz,timestamptz,boolean)')), 'no'),
         'no before migration B. If "yes": STOP - B (or part of it) is already there. Compare migrations.phase3c_already_applied, reports.payment_type_column_exists and functions.prepare_md5 before anything else; B''s one-time fill only runs while the alert columns are missing, so re-running B would not complete a half-applied state'
  union all
  select 83, 'functions.claim_v2_exists',
         coalesce((select 'yes' from pg_proc where oid = to_regprocedure('private.claim_price_alert_deliveries_v2(integer,text)')), 'no'),
         'yes (B refuses to run without it)'
  union all
  select 84, 'vault.scheduler_secret_names',
         coalesce((select string_agg(name, ', ' order by name) from vault.secrets
                   where name in ('price_alerts_worker_cron_token', 'project_url')), '(none)'),
         'price_alerts_worker_cron_token, project_url (names only; values are never read here)'

  -- ---- G. is anything holding locks on the tables the migrations alter? ----------------------------------------------
  union all
  select 90, 'activity.transactions_older_than_1_minute',
         (select count(*)::text from pg_stat_activity
          where pid <> pg_backend_pid() and xact_start is not null and xact_start < now() - interval '1 minute' and state <> 'idle'),
         '0 (a long transaction on the reports or alert tables would make the migration wait, then time out)'
  union all
  select 91, 'activity.ungranted_locks', (select count(*)::text from pg_locks where not granted), '0'
) checks
order by ord;

rollback;

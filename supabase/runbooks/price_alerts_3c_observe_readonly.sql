-- 85Blends 2.4.1 — Price Alerts Phase 3C: READ-ONLY OBSERVATION after the rollout (run repeatedly: +15 min, +1 h, +24 h).
--
-- ONE SELECT inside a READ ONLY transaction; it changes nothing and reads no personal data (counts and codes). THE WINDOW is
-- the single interval on the first line of the `params` CTE below: leave it at 60 minutes for the +15 min and +1 h runs and
-- change it to 24 hours for the +24 h run (every "in_window" row follows it; so does the comparison with the preflight's
-- `deliveries.sent_last_24h`). The rows that must ALWAYS be right: the engine is the real one, a notification for a report that
-- is not comparable to the alert's price type is zero, and no job failed or died.
--
-- Success evidence is a combination: these rows, the cron runs succeeding AND the HTTP responses being 2xx (a cron run that
-- "succeeded" only means the SQL call that starts the HTTP request returned), the Edge Function logs showing no 5xx and no
-- "payment_type lookup failed", and the first natural Cash/Credit notification arriving with the new wording
-- (docs/PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md, section 10).
--
-- Run it only on a database where migration B is applied: it reads B's columns and calls B's comparability function, so on a
-- database without B it stops with "column ... does not exist" by design. That error is not a finding to work around by editing the
-- query - it means B is not there; use the verification file (price_alerts_3c_verify_after_readonly.sql) for the A-only state.

begin read only;

with params as (
  select interval '60 minutes' as w          -- <- THE WINDOW (60 minutes, or 24 hours for the +24 h run)
)
select check_name, value, expectation
from (
  -- ---- the engine itself -------------------------------------------------------------------------------------------------
  select 5 as ord, 'MUST_BE_YES.engine_is_the_real_one' as check_name,
         coalesce((select case when p.prosrc ilike '%evaluate_price_alert_v2%' then 'yes'
                               else 'NO - this is not the payment-aware engine (the pause no-op, or migration B is not in place)' end
                   from pg_proc p where p.oid = to_regprocedure('private.prepare_price_alert_deliveries(uuid)')), '(function missing)') as value,
         'yes. After a pause (C1) and a resume this is THE check that the real engine is back: every other row below stays green while the no-op is installed' as expectation
  union all
  select 6, 'functions.prepare_md5',
         coalesce((select md5(prosrc) from pg_proc where oid = to_regprocedure('private.prepare_price_alert_deliveries(uuid)')), '(missing)'),
         'equal to the B.prepare_md5 you recorded right after migration B (section 7, step 4); a different value means the engine was changed since'

  -- ---- must be zero --------------------------------------------------------------------------------------------------------
  union all
  select 10, 'MUST_BE_ZERO.notifications_for_a_non_comparable_report',
         (select count(*)::text
          from private.price_alert_deliveries d
          join public.e85_price_reports r on r.id = d.price_report_id
          where d.payment_type is not null
            and d.status in ('pending', 'processing', 'sent', 'failed', 'dead')
            and not private.payment_type_is_comparable(d.payment_type, r.payment_type)),
         '0 -- a Cash alert never notifies on a Credit report, a Credit alert never on a Cash report, a legacy alert never on a typed one (since B)'
  union all
  select 11, 'MUST_BE_ZERO.failed_or_dead_jobs_in_window',
         (select count(*)::text from private.price_alert_jobs
          where status in ('failed', 'dead') and coalesce(processed_at, created_at) > now() - (select w from params)),
         '0'
  union all
  select 12, 'MUST_BE_ZERO.duplicate_decisions',
         (select count(*)::text from (select alert_id, price_report_id, push_device_id from private.price_alert_deliveries
                                      group by 1, 2, 3 having count(*) > 1) d),
         '0 (guaranteed by a unique key; shown for completeness)'
  union all
  select 13, 'MUST_BE_ZERO.previous_engine_notifications_for_typed_reports',
         (select count(*)::text
          from private.price_alert_deliveries d
          join public.e85_price_reports r on r.id = d.price_report_id
          where to_jsonb(d) ->> 'payment_type' is null          -- decided by the PREVIOUS engine (it records no price type)
            and r.payment_type <> 'unknown'                     -- for a Cash / Credit / Same-for-Both report
            and d.status in ('pending', 'processing', 'sent', 'failed', 'dead')
            and d.created_at > now() - (select w from params)),
         '0 -- a non-zero count is the false-alert exposure of the gap between migration A and migration B (a typed report judged by the previous engine). Widen the window to look further back; see section 8.1'

  -- ---- what the engine decided -----------------------------------------------------------------------------------------------
  union all
  select 20, 'decisions_in_window_by_outcome',
         coalesce((select string_agg(coalesce(payment_type, 'legacy-or-old') || ' ' || status || ' ' || coalesce(reason_code, '-') || ' x' || n::text, '; '
                                     order by coalesce(payment_type, 'legacy-or-old'), status, reason_code)
                   from (select payment_type, status, reason_code, count(*) as n from private.price_alert_deliveries
                         where created_at > now() - (select w from params) group by 1, 2, 3) m), '(no decisions in the window)'),
         'record it; expect price_dropped / threshold_* as pending-then-sent, and skipped payment_type_mismatch / superseded / cooldown / no_meaningful_drop'
  union all
  select 21, 'sent_in_window',
         (select count(*)::text from private.price_alert_deliveries where status = 'sent' and sent_at > now() - (select w from params)),
         'in line with the preflight baseline for a window of the same length (the preflight''s deliveries.sent_last_24h is a 24-hour count)'
  union all
  select 22, 'not_sent_in_window',
         coalesce((select string_agg(status || ' x' || n::text, ', ' order by status)
                   from (select status, count(*) as n from private.price_alert_deliveries
                         where status in ('failed', 'dead', 'invalid_device') and created_at > now() - (select w from params) group by 1) m), '(none)'),
         'none, or a few invalid_device (a retired token); failed/dead in numbers means the push providers or secrets need a look'
  union all
  select 23, 'queued_now',
         (select count(*)::text from private.price_alert_deliveries where status in ('pending', 'processing', 'failed')),
         'small and falling; oldest below'
  union all
  select 24, 'oldest_queued_age',
         coalesce((select (now() - min(created_at))::text from private.price_alert_deliveries where status in ('pending', 'processing', 'failed')), '(none)'),
         'minutes, not hours (a delivery whose report is more than 2 hours old is expired as stale at the next claim, never sent late)'
  union all
  select 25, 'jobs_by_status',
         coalesce((select string_agg(status || '=' || n::text, ', ' order by status)
                   from (select status, count(*) as n from private.price_alert_jobs group by 1) m), '(none)'),
         'pending near 0; completed grows'
  union all
  select 26, 'alerts_by_payment_type',
         coalesce((select string_agg(payment_type || '=' || n::text, ', ' order by payment_type)
                   from (select payment_type, count(*) as n from private.price_alerts group by 1) m), '(none)'),
         'unknown shrinks as people choose Cash or Credit in the updated app'
  union all
  select 27, 'alerts_waiting_for_a_reference',
         (select count(*)::text from private.price_alerts where enabled and alert_mode = 'price_drop' and baseline_price is null),
         'small: a Price Drop alert with no comparable report yet; the next one sets its starting point'
  union all
  select 28, 'reports_in_window_by_type',
         coalesce((select string_agg(payment_type || '=' || n::text, ', ' order by payment_type)
                   from (select payment_type, count(*) as n from public.e85_price_reports
                         where created_at > now() - (select w from params) group by 1) m), '(none)'),
         'unknown from older apps, typed from the updated one'

  -- ---- the scheduler and the HTTP calls it makes -------------------------------------------------------------------------------
  union all
  select 40, 'cron.price_alert_runs_in_window',
         coalesce((select string_agg(j.jobname || ': ' || d.status || ' x' || d.n::text, '; ' order by j.jobname, d.status)
                   from cron.job j
                   join (select jobid, status, count(*) as n from cron.job_run_details
                         where start_time > now() - (select w from params) group by 1, 2) d on d.jobid = j.jobid
                   where j.jobname in ('85blends-price-alert-job-prepare', '85blends-price-alerts-worker-invoke')), '(none)'),
         'about one run per minute per job (60 per hour); none failed. NOTE: "succeeded" for the invoker only means the call that starts the HTTP request returned'
  union all
  select 41, 'cron.jobs_state',
         coalesce((select string_agg(coalesce(jobname, '(unnamed #' || jobid::text || ')') || ' ' || case when active then 'active' else 'inactive' end, '; '
                                     order by coalesce(jobname, jobid::text))
                   from cron.job), '(none)'),
         'the same as before the rollout'
  union all
  select 42, 'net.http_responses_in_window',
         coalesce((select string_agg(code || ' x' || n::text, ', ' order by code)
                   from (select coalesce(status_code::text, case when timed_out then 'timed_out' else 'no_status' end) as code, count(*) as n
                         from net._http_response where created > now() - (select w from params) group by 1) m), '(none)'),
         'the worker is called every minute: nearly all 200. Any 401/403/5xx or timed_out means the worker is NOT healthy although cron says succeeded. pg_net keeps responses only for a while, and other pg_net callers share this table (only status codes are read here)'
) checks
order by ord;

rollback;

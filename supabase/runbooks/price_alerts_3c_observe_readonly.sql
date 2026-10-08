-- 85Blends 2.4.1 — Price Alerts Phase 3C: READ-ONLY OBSERVATION after the rollout (run repeatedly: +15 min, +1 h, +24 h).
--
-- ONE SELECT inside a READ ONLY transaction; it changes nothing and reads no personal data (counts and codes). The window
-- is the last 60 minutes; widen it by editing the two `interval '60 minutes'` below. The headline rows are the two that
-- must ALWAYS be 0: a notification queued or sent for a report that is not comparable to the alert's price type, and a
-- job that failed or died.
--
-- Success evidence is a combination: these rows, the cron runs succeeding, the Edge Function logs showing no 5xx and no
-- "payment_type lookup failed", and the first natural Cash/Credit notification arriving with the new wording
-- (docs/PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md, section 10).
--
-- Run it only on a database where migration B is applied: it reads B's columns and calls B's comparability function, so on a
-- database without B it stops with "column ... does not exist" by design. That error is not a finding to work around by editing the
-- query - it means B is not there; use the verification file (price_alerts_3c_verify_after_readonly.sql) for the A-only state.

begin read only;

select check_name, value, expectation
from (
  select 10 as ord, 'MUST_BE_ZERO.notifications_for_a_non_comparable_report' as check_name,
         (select count(*)::text
          from private.price_alert_deliveries d
          join public.e85_price_reports r on r.id = d.price_report_id
          where d.payment_type is not null
            and d.status in ('pending', 'processing', 'sent', 'failed', 'dead')
            and not private.payment_type_is_comparable(d.payment_type, r.payment_type)) as value,
         '0 -- a Cash alert never notifies on a Credit report, a Credit alert never on a Cash report, a legacy alert never on a typed one (since B)' as expectation
  union all
  select 11, 'MUST_BE_ZERO.failed_or_dead_jobs_in_window',
         (select count(*)::text from private.price_alert_jobs where status in ('failed', 'dead') and coalesce(processed_at, created_at) > now() - interval '60 minutes'),
         '0'
  union all
  select 12, 'MUST_BE_ZERO.duplicate_decisions',
         (select count(*)::text from (select alert_id, price_report_id, push_device_id from private.price_alert_deliveries
                                      group by 1, 2, 3 having count(*) > 1) d),
         '0 (guaranteed by a unique key; shown for completeness)'
  union all
  select 20, 'decisions_in_window_by_outcome',
         coalesce((select string_agg(coalesce(payment_type, 'legacy-or-old') || ' ' || status || ' ' || coalesce(reason_code, '-') || ' x' || n::text, '; '
                                     order by coalesce(payment_type, 'legacy-or-old'), status, reason_code)
                   from (select payment_type, status, reason_code, count(*) as n from private.price_alert_deliveries
                         where created_at > now() - interval '60 minutes' group by 1, 2, 3) m), '(no decisions in the window)'),
         'record it; expect price_dropped / threshold_* as pending-then-sent, and skipped payment_type_mismatch / superseded / cooldown / no_meaningful_drop'
  union all
  select 21, 'sent_in_window',
         (select count(*)::text from private.price_alert_deliveries where status = 'sent' and sent_at > now() - interval '60 minutes'),
         'in line with the preflight baseline for a comparable hour'
  union all
  select 22, 'not_sent_in_window',
         coalesce((select string_agg(status || ' x' || n::text, ', ' order by status)
                   from (select status, count(*) as n from private.price_alert_deliveries
                         where status in ('failed', 'dead', 'invalid_device') and created_at > now() - interval '60 minutes' group by 1) m), '(none)'),
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
                         where created_at > now() - interval '60 minutes' group by 1) m), '(none)'),
         'unknown from older apps, typed from the updated one'
  union all
  select 40, 'cron.price_alert_runs_in_window',
         coalesce((select string_agg(j.jobname || ': ' || d.status || ' x' || d.n::text, '; ' order by j.jobname, d.status)
                   from cron.job j
                   join (select jobid, status, count(*) as n from cron.job_run_details
                         where start_time > now() - interval '60 minutes' group by 1, 2) d on d.jobid = j.jobid
                   where j.jobname in ('85blends-price-alert-job-prepare', '85blends-price-alerts-worker-invoke')), '(none)'),
         'about 60 succeeded per job; none failed'
  union all
  select 41, 'cron.jobs_state',
         coalesce((select string_agg(jobname || ' ' || case when active then 'active' else 'inactive' end, '; ' order by jobname) from cron.job), '(none)'),
         'the same as before the rollout'
) checks
order by ord;

rollback;

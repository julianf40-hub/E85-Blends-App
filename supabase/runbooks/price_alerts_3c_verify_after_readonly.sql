-- 85Blends 2.4.1 — Price Alerts Phase 3C: READ-ONLY VERIFICATION after migration A (and again after migration B).
--
-- ONE SELECT inside a READ ONLY transaction; it changes nothing. Run it right after each migration, compare every row with
-- its "expect" column and with the preflight you saved (price_alerts_3c_preflight_readonly.sql). Rows that describe the other
-- migration say so ("after A" / "after B"): it runs on a database with A only (the B rows then show 0 / (missing) / "column not
-- there yet") as well as on A + B, so a B that failed can still be inspected. It is NOT meant for a database before A (the
-- A.rows_and_types row needs A's column). A mismatch is a STOP (see docs/PRICE_ALERTS_PRODUCTION_READINESS_2.4.1.md, section 8).
-- No secret and no personal data is read.

begin read only;

select check_name, value, expectation
from (
  -- ---- after migration A: the reports table ---------------------------------------------------------------------------
  select 10 as ord, 'A.payment_type_column' as check_name,
         coalesce((select data_type || ', nullable=' || is_nullable || ', default=' || coalesce(column_default, '-')
                   from information_schema.columns
                   where table_schema = 'public' and table_name = 'e85_price_reports' and column_name = 'payment_type'), '(missing)') as value,
         'text, nullable=NO, default=''unknown''::text' as expectation
  union all
  select 11, 'A.check_constraint',
         coalesce((select conname || ' validated=' || convalidated::text from pg_constraint
                   where conrelid = 'public.e85_price_reports'::regclass and conname = 'e85_price_reports_payment_type_check'), '(missing)'),
         'e85_price_reports_payment_type_check validated=true'
  union all
  select 12, 'A.insert_columns_anon',
         coalesce((select string_agg(column_name, ',' order by column_name) from information_schema.column_privileges
                   where table_schema = 'public' and table_name = 'e85_price_reports' and grantee = 'anon' and privilege_type = 'INSERT'), '(none)'),
         'anonymous_reporter_id,app_version,note,payment_type,price,reported_at,station_id  (the preflight list plus payment_type, nothing else)'
  union all
  select 13, 'A.insert_columns_authenticated',
         coalesce((select string_agg(column_name, ',' order by column_name) from information_schema.column_privileges
                   where table_schema = 'public' and table_name = 'e85_price_reports' and grantee = 'authenticated' and privilege_type = 'INSERT'), '(none)'),
         'the same list as anon'
  union all
  select 14, 'A.update_or_delete_grants_for_clients',
         (select count(*)::text from information_schema.column_privileges
          where table_schema = 'public' and table_name = 'e85_price_reports'
            and grantee in ('anon', 'authenticated') and privilege_type in ('UPDATE', 'DELETE')),
         '0'
  union all
  select 15, 'A.policies_unchanged',
         coalesce((select string_agg(policyname || ' (' || cmd || ')', ', ' order by policyname) from pg_policies
                   where schemaname = 'public' and tablename = 'e85_price_reports'), '(none)'),
         'exactly the preflight list'
  union all
  select 16, 'A.index_exists',
         coalesce((select indexdef from pg_indexes where schemaname = 'public' and indexname = 'e85_price_reports_station_payment_latest_idx'), '(missing)'),
         '... (station_id, payment_type, reported_at DESC, created_at DESC)'
  union all
  select 17, 'A.rows_and_types',
         (select count(*)::text || ' rows; typed (not unknown): ' || count(*) filter (where payment_type <> 'unknown')::text from public.e85_price_reports),
         'rows equals the preflight count (plus reports that arrived since); typed = 0 until a client sends payment_type'
  union all
  select 18, 'A.gap_exposure_deliveries',
         -- to_jsonb(): the deliveries' payment_type column exists only after B, and this file must run on an A-only database too
         (select count(*)::text
          from private.price_alert_deliveries d
          join public.e85_price_reports r on r.id = d.price_report_id
          where to_jsonb(d) ->> 'payment_type' is null          -- decided by the PREVIOUS engine (it records no price type)
            and r.payment_type <> 'unknown'                     -- for a Cash / Credit / Same-for-Both report
            and d.status in ('pending', 'processing', 'sent', 'failed', 'dead')),
         '0. Non-zero = in the gap between A and B the previous engine decided a typed report for a legacy alert (a false alert). B cannot repair it: cancel any that are still pending (section 9, C4) and tell the owner'

  -- ---- after migration B: the alert tables and the engine ----------------------------------------------------------------
  union all
  select 30, 'B.alert_columns',
         (select count(*)::text from information_schema.columns
          where table_schema = 'private' and table_name = 'price_alerts' and column_name in ('payment_type', 'baseline_price', 'baseline_at')),
         '3 after B (0 before)'
  union all
  select 31, 'B.delivery_column',
         (select count(*)::text from information_schema.columns
          where table_schema = 'private' and table_name = 'price_alert_deliveries' and column_name = 'payment_type'),
         '1 after B (0 before)'
  union all
  select 32, 'B.constraints_validated',
         coalesce((select string_agg(conname || '=' || convalidated::text, ', ' order by conname) from pg_constraint
                   where conname in ('price_alerts_payment_type_check', 'price_alerts_baseline_check', 'price_alert_deliveries_payment_type_check')), '(none)'),
         'three constraints, all =true after B'
  union all
  select 33, 'B.alerts_by_payment_type',
         -- to_jsonb(): the column does not exist before B, and this file must still run (and say so) when only A is applied
         coalesce((select string_agg(pt || '=' || n::text, ', ' order by pt)
                   from (select coalesce(to_jsonb(a) ->> 'payment_type', '(column not there yet: B not applied)') as pt, count(*) as n
                         from private.price_alerts a group by 1) m), '(none)'),
         'right after B every existing alert is unknown (nothing was guessed); cash/credit appear only as people choose. After A alone: the column is not there yet'
  union all
  select 34, 'B.alerts_with_a_reference',
         (select count(*) filter (where to_jsonb(a) ->> 'baseline_price' is not null)::text || ' of ' || count(*)::text from private.price_alerts a),
         'a legacy alert has a reference only if an unclassified report from the last 7 days exists for its station'
  union all
  select 35, 'B.engine_objects',
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'private' and p.proname in ('price_alert_reference_horizon', 'comparable_report_types', 'payment_type_is_comparable',
                'latest_comparable_price_report', 'has_newer_comparable_price_report', 'evaluate_price_alert_v2', 'anchor_price_alert_baseline')),
         '7'
  union all
  select 36, 'B.anchor_trigger',
         (select count(*)::text from pg_trigger where tgrelid = 'private.price_alerts'::regclass and tgname = 'price_alerts_anchor_baseline' and not tgisinternal),
         '1'
  union all
  select 37, 'B.queued_deliveries_index',
         coalesce((select indexdef from pg_indexes where schemaname = 'private' and indexname = 'price_alert_deliveries_alert_queued_idx'), '(missing)'),
         '... (alert_id, created_at DESC) WHERE status in (pending, processing, failed)'
  union all
  select 38, 'B.functions_callable_by_clients',
         (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'private'
            and p.proname in ('price_alert_reference_horizon', 'comparable_report_types', 'payment_type_is_comparable', 'latest_comparable_price_report',
                              'has_newer_comparable_price_report', 'evaluate_price_alert_v2', 'anchor_price_alert_baseline',
                              'prepare_price_alert_deliveries', 'mark_price_alert_delivery_sent')
            and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE')
                 or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0))),
         '0 (no client role and not PUBLIC can execute any of them)'
  union all
  select 39, 'B.prepare_md5',
         coalesce((select md5(prosrc) from pg_proc where oid = to_regprocedure('private.prepare_price_alert_deliveries(uuid)')), '(missing)'),
         'DIFFERENT from the preflight value (the engine was replaced). Equal to the preflight value = B did not take effect'
  union all
  select 40, 'B.mark_sent_md5',
         coalesce((select md5(prosrc) from pg_proc where oid = to_regprocedure('private.mark_price_alert_delivery_sent(uuid,integer)')), '(missing)'),
         'DIFFERENT from the preflight value'
  union all
  select 44, 'B.engine_is_the_real_one',
         coalesce((select case when p.prosrc ilike '%evaluate_price_alert_v2%' then 'yes'
                               else 'NO - not the payment-aware engine (expected before B; after B it means the pause no-op or a failed B)' end
                   from pg_proc p where p.oid = to_regprocedure('private.prepare_price_alert_deliveries(uuid)')), '(function missing)'),
         'yes after B. RECORD B.prepare_md5 (above) NOW as the engine you expect to find after any later pause and resume: the no-op also differs from the preflight value'
  union all
  select 41, 'B.deliveries_untouched',
         (select count(*) filter (where to_jsonb(d) ->> 'payment_type' is not null)::text || ' typed of ' || count(*)::text
          from private.price_alert_deliveries d),
         'right after B: 0 typed. The total and the by-status split equal the preflight (B rewrites and re-sends nothing)'
  union all
  select 42, 'B.deliveries_by_status',
         coalesce((select string_agg(status || '=' || n::text, ', ' order by status)
                   from (select status, count(*) as n from private.price_alert_deliveries group by 1) m), '(none)'),
         'the preflight split (plus anything the live engine has queued since)'
  union all
  select 43, 'B.jobs_by_status',
         coalesce((select string_agg(status || '=' || n::text, ', ' order by status)
                   from (select status, count(*) as n from private.price_alert_jobs group by 1) m), '(none)'),
         'no failed or dead job; pending drains within a minute or two'

  -- ---- unchanged by either migration ------------------------------------------------------------------------------------
  union all
  select 60, 'cron.jobs_unchanged',
         coalesce((select string_agg(coalesce(jobname, '(unnamed #' || jobid::text || ')') || ' [' || schedule || '] ' || case when active then 'active' else 'inactive' end, '; '
                                     order by coalesce(jobname, jobid::text))
                   from cron.job), '(none)'),
         'exactly the preflight list: neither migration touches a cron job'
) checks
order by ord;

rollback;

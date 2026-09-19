-- RECOVERED HISTORICAL MIGRATION
-- Source: retrieved verbatim from supabase_migrations.schema_migrations.statements on the live
-- project (zefkbtscieokkdenvnkg), version 20260918001657, name price_alert_job_processor_cron, via
-- read-only SQL on 2026-09-19, as part of the 85Blends 2.4.0 migration-history reconciliation
-- audit. Exact SQL text Supabase recorded as applied for this version — not a reconstruction.
-- Confidence: exact. Absent from this repository's git history on every branch before this file.
--
-- IMPORTANT: this migration schedules a LIVE, RUNNING pg_cron job
-- (`85blends-price-alert-job-prepare`, every minute) on the production database. Recovering this
-- file into git does not create, alter, or touch that job — it is already running; this file only
-- records what created it.
--
-- Not applied by this recovery — already live; this file only makes local history match remote.

create extension if not exists pg_cron with schema extensions;

create or replace function private.process_price_alert_jobs(p_limit integer default 50)
returns table(claimed_count integer, prepared_count integer, failed_count integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job record;
  v_claimed integer := 0;
  v_prepared integer := 0;
  v_failed integer := 0;
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'p_limit must be between 1 and 100';
  end if;

  for v_job in select * from private.claim_price_alert_jobs(p_limit)
  loop
    v_claimed := v_claimed + 1;
    begin
      perform * from private.prepare_price_alert_deliveries(v_job.price_report_id);
      perform private.finalize_price_alert_job(v_job.price_report_id);
      v_prepared := v_prepared + 1;
    exception when others then
      perform private.mark_price_alert_job_failed(
        v_job.job_id,
        left(sqlerrm, 500),
        true,
        5
      );
      v_failed := v_failed + 1;
    end;
  end loop;

  return query select v_claimed, v_prepared, v_failed;
end;
$$;

revoke execute on function private.process_price_alert_jobs(integer) from public, anon, authenticated;
grant execute on function private.process_price_alert_jobs(integer) to postgres, service_role;

select cron.schedule(
  '85blends-price-alert-job-prepare',
  '* * * * *',
  $cron$select * from private.process_price_alert_jobs(50);$cron$
);

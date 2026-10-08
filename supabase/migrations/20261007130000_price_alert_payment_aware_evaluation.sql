-- 85Blends 2.4.1 — Phase 3C, migration B of 2: payment-aware Price Alert evaluation.
--
-- NOT APPLIED TO PRODUCTION. This file only prepares the change; applying it is a separate, explicitly
-- authorized step (see docs/PRICE_ALERTS_PAYMENT_TYPES_2.4.1.md, "Rollout order"). It REQUIRES migration A
-- (20261007120000_community_price_payment_type) and refuses to run without it.
--
-- WHY
--   The engine compared a new report with "the immediately preceding report of the station" whatever its
--   payment method, so Credit $3.19 followed by Cash $2.99 looked like a 20-cent price drop. It also could
--   not add small drops up (5c then 5c never satisfied a 10c alert), judged a late/back-dated report as if
--   it were current, and let two reports prepared before the first was SENT both pass the cooldown. This
--   migration fixes the comparison itself, on the server, where the notification is decided.
--
-- WHAT TAKES EFFECT WHEN THIS IS APPLIED (read before applying)
--   * IMMEDIATE: private.prepare_price_alert_deliveries is called every minute by the already-active
--     job-prepare cron and by the worker, so the new engine decides the very next report.
--   * Existing alerts get payment_type 'unknown' (nothing is invented) and keep working on exactly the
--     reports they always saw: a legacy alert only ever sees 'unknown' reports (every report that exists
--     today, and every report from an app that does not send the field). A one-time, idempotent fill below
--     gives each legacy alert the reference price the old engine would have used for the next report, so the
--     first report after the deploy behaves as before. Cash/credit/same_for_both reports never reach a
--     legacy alert. A person moves an alert to Cash or Credit by editing it in the updated app.
--     Legacy alerts are decided by the same state machine, so three things differ from the old engine, all
--     toward fewer wrong or duplicate notifications: drops smaller than the minimum now add up; a late or
--     back-dated report no longer notifies as if it were current (nor a reference that no report has
--     refreshed for 7 days: it is re-established instead); and two reports prepared before the first was
--     sent cannot both pass the cooldown.
--   * Deliveries already queued or prepared are NOT touched, re-evaluated or re-sent.
--   * Apply it when the job queue is drained (no pending, processing or failed row in private.price_alert_jobs):
--     the one-time fill below anchors each legacy alert on the latest report, so a report whose job is still
--     queued would be judged against itself. A delivery the previous engine queued and has not sent yet still
--     holds its alert's cooldown under the new rules, so the switch-over produces no duplicate.
--   * Nothing here sends anything, schedules anything, or changes the cron jobs.
--   * Locks: this file runs in ONE transaction, so the ALTER TABLEs below hold ACCESS EXCLUSIVE locks on
--     private.price_alerts and private.price_alert_deliveries until it commits, and the constraint validation
--     scans run inside that window. The worker's claim and the prepare job queue behind it for that moment
--     (short at this table size). Apply it in a quiet minute.
--
-- THE MODEL
--   Comparable stream of an alert (the ONLY reports it may be judged on):
--       cash alert    <- cash, same_for_both
--       credit alert  <- credit, same_for_both
--       unknown alert <- unknown                (legacy; same_for_both is NOT mixed in)
--     anything else, including a value this code has never heard of, is NOT comparable (fail closed).
--   A report is acted on only if it is the NEWEST comparable report at decision time; an older one that
--   arrives late is recorded as 'superseded' and changes nothing. A different payment method never
--   changes an alert's reference, so a type switch can never look like a drop.
--   private.price_alerts.baseline_price is the reference the NEXT comparable report is judged against:
--     price_drop   : the highest comparable price since the alert was armed or last fired, so 5c + 5c reaches
--                    a 10c alert and a fall from a new high counts. It is set to the notified price when an
--                    alert fires (that is the rearm point). A rise or an equal price moves it up. A smaller
--                    drop leaves it alone. It is established from the first comparable report when none
--                    existed at configuration time; it is never invented. A reference that no comparable
--                    report has refreshed for 7 days is discarded and re-established without notifying (every
--                    comparable report that is decided moves baseline_at to that report, so while reports keep
--                    arriving the reference is a running high-water mark since the last notification).
--     at_or_below  : the previous comparable price (used to detect a crossing).
--     any_change   : the previous comparable price.
--   Cooldown is measured from the alert's last SENT notification (last_notified_at / last_notified_price, as
--   before) or from a newer notification that is still QUEUED for it under its current payment method (a
--   delivery that is pending, being sent, or failed and awaiting a retry). That closes the race in which two
--   reports are prepared before the first is sent, WITHOUT holding the cooldown for a notification that never
--   goes out: a queued delivery that ends dead, invalid_device or skipped (stale, device unusable) is no longer
--   queued, so it no longer mutes the alert. A qualifying drop that the cooldown suppresses keeps the alert
--   armed: it fires on the next qualifying comparable report after the cooldown; nothing is queued for later.
--
-- CHANGES (all idempotent; safe to re-run)
--   1. private.price_alerts gains payment_type (cash|credit|unknown, default unknown), baseline_price and
--      baseline_at. private.price_alert_deliveries gains payment_type (the alert's method at decision time).
--   2. Helpers: comparable_report_types / payment_type_is_comparable / latest_comparable_price_report /
--      has_newer_comparable_price_report / price_alert_reference_horizon.
--   3. private.evaluate_price_alert_v2: the pure decision function. The old private.evaluate_price_alert is
--      left in place, unchanged and no longer called.
--   4. private.prepare_price_alert_deliveries: replaced, same signature and ACL. It first takes a transaction-level
--      advisory lock on the station, so every preparer of a station locks that station's alert rows in the same
--      order (no lock-order deadlock with a multi-job transaction when an alert is created in between).
--   4b. private.mark_price_alert_delivery_sent: replaced with the same body plus one guard - it records the sent
--       price on the alert only while the alert still has the payment method the delivery was decided under, so an
--       in-flight Credit notification delivered after the person switched the alert to Cash cannot write a Credit
--       price into a Cash alert. Signature, return value, ACL and every other effect are unchanged.
--   5. A trigger anchors the reference when an alert is configured (INSERT, or a change of mode or payment
--      type): the latest comparable price within the horizon, else NULL.
--   NOT CHANGED: private.claim_price_alert_deliveries_v2 and its v1 wrapper (their exact return shape is
--   pinned by supabase/tests/price_alert_cross_platform_delivery_safety.test.sql because the deployed
--   worker depends on it). The worker reads the new deliveries.payment_type with one extra lookup by
--   delivery id, so the claim contract, its safety logic and its tests stay byte-for-byte as they are.
--
-- ROLLBACK / FAIL-CLOSED
--   Do NOT go back to the previous prepare_price_alert_deliveries (20260918001318) once cash / credit /
--   same_for_both reports exist: that engine compares a report with the previous report whatever its payment
--   method, which is the false alert this migration removes. To stop alerting while a problem is fixed forward,
--   PAUSE instead: replace prepare_price_alert_deliveries (same signature, same ACL via CREATE OR REPLACE) with a
--   no-op that returns (0, 0) - it decides and queues nothing. The exact statement is in
--   docs/PRICE_ALERTS_PAYMENT_TYPES_2.4.1.md section 10 and is executed by scenario D19 of
--   supabase/tests/price_alert_payment_type.test.sql. (Or pause the two cron jobs; reports that arrive while the
--   no-op is installed are consumed without a decision.) Re-applying this file resumes the real engine. The new
--   columns can stay (they are inert), the trigger price_alerts_anchor_baseline can stay, and nothing here
--   deletes data.

-- Give up after 3 seconds instead of queueing every reader and writer of a table behind a lock this file cannot get
-- (it runs in one transaction; see the lock note above). Re-run it when the table is quiet.
set lock_timeout = '3s';

do $precondition$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'e85_price_reports' and column_name = 'payment_type'
  ) then
    raise exception 'requires migration 20261007120000_community_price_payment_type (payment_type missing)';
  end if;

  if to_regprocedure('private.claim_price_alert_deliveries_v2(integer,text)') is null
     or to_regclass('private.price_alert_jobs_stuck_processing_idx') is null then
    raise exception 'requires migrations 20261005120000 / 20261005211547 / 20261005233000 (apply them first)';
  end if;
end
$precondition$;

-- ------------------------------------------------------------------------------------------------
-- 1. Columns and constraints (no rewrite: nullable columns and a constant default)
-- ------------------------------------------------------------------------------------------------

-- Is this the FIRST application? Decided before the columns exist, and used only by the one-time fill of
-- legacy alerts in step 6, so that re-applying this file later can never anchor an alert that is
-- legitimately waiting for its first comparable report. (Session-level setting; if it were ever lost the
-- fill is simply skipped, which is the safe direction.)
select set_config(
  'price_alerts.payment_aware_first_run',
  case when exists (
         select 1 from information_schema.columns
         where table_schema = 'private' and table_name = 'price_alerts' and column_name = 'baseline_price'
       ) then 'no' else 'yes' end,
  false
);

alter table private.price_alerts
  add column if not exists payment_type text not null default 'unknown',
  add column if not exists baseline_price numeric(6,3),
  add column if not exists baseline_at timestamptz;

alter table private.price_alert_deliveries
  add column if not exists payment_type text;

do $constraints$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'private.price_alerts'::regclass
                 and conname = 'price_alerts_payment_type_check') then
    alter table private.price_alerts
      add constraint price_alerts_payment_type_check
      check (payment_type in ('cash', 'credit', 'unknown')) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'private.price_alerts'::regclass
                 and conname = 'price_alerts_baseline_check') then
    alter table private.price_alerts
      add constraint price_alerts_baseline_check
      check (
        (baseline_price is null or baseline_price between 1.000 and 8.000)
        and (baseline_price is null or baseline_at is not null)
      ) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'private.price_alert_deliveries'::regclass
                 and conname = 'price_alert_deliveries_payment_type_check') then
    alter table private.price_alert_deliveries
      add constraint price_alert_deliveries_payment_type_check
      check (payment_type is null or payment_type in ('cash', 'credit', 'unknown')) not valid;
  end if;
end
$constraints$;

alter table private.price_alerts validate constraint price_alerts_payment_type_check;
alter table private.price_alerts validate constraint price_alerts_baseline_check;
alter table private.price_alert_deliveries validate constraint price_alert_deliveries_payment_type_check;

-- "Is a notification still queued for this alert?" (pending, being sent, or failed and awaiting a retry): the lookup
-- prepare_price_alert_deliveries makes to measure the cooldown. A delivery leaves this set within minutes, so the
-- partial index stays tiny.
create index if not exists price_alert_deliveries_alert_queued_idx
  on private.price_alert_deliveries (alert_id, created_at desc)
  where status in ('pending', 'processing', 'failed');

comment on column private.price_alerts.payment_type is
  '85Blends 2.4.1 payment method this alert watches: cash, credit, or unknown (a legacy alert that predates payment types - never guessed; it only ever sees unknown reports).';
comment on column private.price_alerts.baseline_price is
  '85Blends 2.4.1 reference price the next COMPARABLE report is judged against (price_drop: highest comparable price since armed/last fired; at_or_below / any_change: previous comparable price). NULL = none yet; established from the first comparable report, never invented.';
comment on column private.price_alerts.baseline_at is
  '85Blends 2.4.1 reported_at of the last comparable report folded into baseline_price; a reference older than 7 days is discarded.';
comment on column private.price_alert_deliveries.payment_type is
  '85Blends 2.4.1 the alert''s payment method when this delivery was decided (cash, credit, unknown). NULL for deliveries prepared before payment types.';

-- ------------------------------------------------------------------------------------------------
-- 2. Helpers (single source of truth for "comparable")
-- ------------------------------------------------------------------------------------------------

create or replace function private.price_alert_reference_horizon()
returns interval
language sql
immutable
parallel safe
set search_path = ''
as $$ select interval '7 days' $$;

create or replace function private.comparable_report_types(p_alert_payment_type text)
returns text[]
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case p_alert_payment_type
    when 'cash'    then array['cash', 'same_for_both']
    when 'credit'  then array['credit', 'same_for_both']
    when 'unknown' then array['unknown']
    else array[]::text[]
  end
$$;

create or replace function private.payment_type_is_comparable(p_alert_payment_type text, p_report_payment_type text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(p_report_payment_type = any (private.comparable_report_types(p_alert_payment_type)), false)
$$;

-- The newest report of a station that an alert of this payment type may be judged on.
-- Ordering is the engine's established one: reported_at, then created_at, then id (newest first).
create or replace function private.latest_comparable_price_report(p_station_id uuid, p_alert_payment_type text)
returns table (id uuid, price numeric, reported_at timestamptz, created_at timestamptz, payment_type text)
language sql
stable
set search_path = ''
as $$
  select r.id, r.price, r.reported_at, r.created_at, r.payment_type
  from unnest(private.comparable_report_types(p_alert_payment_type)) as t(pt)
  cross join lateral (
    select x.id, x.price, x.reported_at, x.created_at, x.payment_type
    from public.e85_price_reports x
    where x.station_id = p_station_id
      and x.payment_type = t.pt
    order by x.reported_at desc, x.created_at desc, x.id desc
    limit 1
  ) r
  order by r.reported_at desc, r.created_at desc, r.id desc
  limit 1
$$;

create or replace function private.has_newer_comparable_price_report(
  p_station_id uuid,
  p_alert_payment_type text,
  p_reported_at timestamptz,
  p_created_at timestamptz,
  p_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from unnest(private.comparable_report_types(p_alert_payment_type)) as t(pt)
    cross join lateral (
      select 1
      from public.e85_price_reports x
      where x.station_id = p_station_id
        and x.payment_type = t.pt
        and x.reported_at >= p_reported_at
        and (
          x.reported_at > p_reported_at
          or (x.created_at, x.id) > (p_created_at, p_id)
        )
      limit 1
    ) n
  )
$$;

-- ------------------------------------------------------------------------------------------------
-- 3. The pure decision function. No tables, no clock except p_now: unit-testable in isolation.
--    Returns the decision AND the reference to store afterwards.
-- ------------------------------------------------------------------------------------------------

create or replace function private.evaluate_price_alert_v2(
  p_alert_mode text,
  p_threshold_price numeric,
  p_minimum_change numeric,
  p_cooldown_minutes integer,
  p_observed_price numeric,
  p_baseline_price numeric,
  p_baseline_age interval,
  p_last_notified_price numeric,
  p_last_notified_at timestamptz,
  p_now timestamptz default now(),
  p_can_notify boolean default true
)
returns table (
  should_notify boolean,
  reason_code text,
  new_baseline_price numeric
)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_min numeric := greatest(coalesce(p_minimum_change, 0.05), 0.01);
  v_cooldown_active boolean;
  v_baseline numeric;
  v_stale boolean;
  v_notify boolean := false;
  v_reason text;
begin
  if p_observed_price is null or p_observed_price < 1.00 or p_observed_price > 8.00 then
    return query select false, 'invalid_observed_price'::text, p_baseline_price;
    return;
  end if;

  if p_cooldown_minutes is null or p_cooldown_minutes < 0 then
    return query select false, 'invalid_cooldown'::text, p_baseline_price;
    return;
  end if;

  v_cooldown_active := p_last_notified_at is not null
    and p_now < p_last_notified_at + make_interval(mins => p_cooldown_minutes);

  -- A reference with no known age, or older than the horizon, is discarded rather than trusted.
  v_stale := p_baseline_price is not null
    and (p_baseline_age is null or p_baseline_age > private.price_alert_reference_horizon());
  v_baseline := case when v_stale then null else p_baseline_price end;

  case p_alert_mode
    when 'price_drop' then
      if p_baseline_price is null then
        return query select false, 'baseline_established'::text, p_observed_price;
        return;
      elsif v_stale then
        return query select false, 'baseline_stale'::text, p_observed_price;
        return;
      end if;
      if (v_baseline - p_observed_price) >= v_min then
        if not p_can_notify then
          return query select false, 'stale_report'::text, p_observed_price;
        elsif v_cooldown_active then
          return query select false, 'cooldown'::text, v_baseline;
        else
          return query select true, 'price_dropped'::text, p_observed_price;
        end if;
      else
        -- A smaller drop leaves the reference where it is (drops accumulate); a rise or an equal price
        -- moves it up to the new high.
        return query select false, 'no_meaningful_drop'::text, greatest(v_baseline, p_observed_price);
      end if;
      return;

    when 'any_change' then
      if p_baseline_price is null then
        return query select false, 'baseline_established'::text, p_observed_price;
        return;
      elsif v_stale then
        return query select false, 'baseline_stale'::text, p_observed_price;
        return;
      end if;
      if abs(p_observed_price - v_baseline) >= v_min then
        if not p_can_notify then
          return query select false, 'stale_report'::text, p_observed_price;
        elsif v_cooldown_active then
          return query select false, 'cooldown'::text, v_baseline;
        else
          return query select true, 'price_changed'::text, p_observed_price;
        end if;
      else
        return query select false, 'change_below_minimum'::text, p_observed_price;
      end if;
      return;

    when 'at_or_below' then
      if p_threshold_price is null or p_threshold_price < 1.00 or p_threshold_price > 8.00 then
        return query select false, 'invalid_threshold'::text, v_baseline;
        return;
      end if;
      if p_observed_price > p_threshold_price then
        return query select false, 'above_threshold'::text, p_observed_price;
        return;
      end if;

      if v_baseline is not null and v_baseline > p_threshold_price then
        v_notify := true;
        v_reason := 'threshold_crossed';
      elsif p_last_notified_price is null then
        v_notify := true;
        v_reason := 'threshold_met';
      elsif abs(p_observed_price - p_last_notified_price) >= v_min then
        v_notify := true;
        v_reason := 'threshold_price_changed';
      else
        v_reason := 'threshold_unchanged';
      end if;

      if v_notify and not p_can_notify then
        return query select false, 'stale_report'::text, p_observed_price;
      elsif v_notify and v_cooldown_active then
        return query select false, 'cooldown'::text, v_baseline;
      else
        return query select v_notify, v_reason, p_observed_price;
      end if;
      return;

    else
      return query select false, 'invalid_mode'::text, p_baseline_price;
      return;
  end case;
end;
$$;

-- ------------------------------------------------------------------------------------------------
-- 4. Delivery preparation. Same signature, return shape and ACL as before.
--    One decision per ALERT (not per device), under a row lock on the alert so two reports processed at
--    the same moment cannot both pass the cooldown, then one ledger row per active device.
-- ------------------------------------------------------------------------------------------------

create or replace function private.prepare_price_alert_deliveries(p_price_report_id uuid)
returns table(pending_count integer, skipped_count integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- Must equal the freshness window of the delivery claim functions (a report older than this is never sent).
  v_send_freshness constant interval := interval '2 hours';
  v_station_id uuid;
  v_observed_price numeric;
  v_reported_at timestamptz;
  v_created_at timestamptz;
  v_report_payment_type text;
  v_report_is_stale boolean;
  v_pending integer := 0;
  v_skipped integer := 0;
  v_alert record;
  v_device record;
  v_decision record;
  v_is_pro boolean;
  v_age interval;
  v_status text;
  v_reason text;
  v_inserted_status text;
  v_live_at timestamptz;
  v_live_price numeric;
  v_last_at timestamptz;
  v_last_price numeric;
begin
  select r.station_id, r.price, r.reported_at, r.created_at, r.payment_type
  into v_station_id, v_observed_price, v_reported_at, v_created_at, v_report_payment_type
  from public.e85_price_reports r
  where r.id = p_price_report_id;

  if v_station_id is null then
    raise exception 'price report not found';
  end if;

  v_report_is_stale := v_reported_at < now() - v_send_freshness;

  -- One cheap station-level lock, taken before any alert row: every preparer of this station queues here first,
  -- so alert rows are never locked in an order that depends on which alerts existed at the time (a multi-job
  -- transaction that already holds one station's alert rows must not deadlock with a single-report call when an
  -- alert with a lower id is created in between). Released at commit; a call for another station never waits.
  perform pg_advisory_xact_lock(hashtextextended('price-alert-station:' || v_station_id::text, 0));

  for v_alert in
    select a.id, a.installation_id, a.alert_mode, a.threshold_price, a.minimum_change, a.cooldown_minutes,
           a.payment_type, a.baseline_price, a.baseline_at, a.last_notified_price, a.last_notified_at
    from private.price_alerts a
    where a.station_id = v_station_id
      and a.enabled = true
    order by a.id
    for update of a
  loop
    -- Already decided for this report (a retried or doubly processed job): do not decide twice.
    if exists (
      select 1 from private.price_alert_deliveries d
      where d.alert_id = v_alert.id and d.price_report_id = p_price_report_id
    ) then
      continue;
    end if;

    -- Pro is verified here exactly as before; a non-Pro installation gets no rows and no state change.
    select exists (
      select 1
      from private.price_alert_installations i
      join private.revenuecat_customers rc on rc.id = i.revenuecat_customer_id
      where i.id = v_alert.installation_id
        and rc.pro_is_active = true
        and rc.entitlement_id = 'pro'
    ) into v_is_pro;

    if not coalesce(v_is_pro, false) then
      continue;
    end if;

    v_status := 'skipped';

    if not private.payment_type_is_comparable(v_alert.payment_type, v_report_payment_type) then
      -- A different payment method (or one this code does not know): not this alert's price. No state change.
      v_reason := 'payment_type_mismatch';
    elsif private.has_newer_comparable_price_report(
            v_station_id, v_alert.payment_type, v_reported_at, v_created_at, p_price_report_id) then
      -- A newer comparable report exists, so this one is out of order: it must not alert or move the reference.
      v_reason := 'superseded';
    else
      v_age := case
        when v_alert.baseline_at is null then null
        else greatest(v_reported_at - v_alert.baseline_at, interval '0')
      end;

      -- What the alert last notified: its last SENT notification, or a newer one still queued for it under its
      -- current payment method (decided before this migration = a legacy 'unknown' delivery). A delivery that ended
      -- dead / invalid_device / skipped is not queued and holds nothing, so a notification that never went out
      -- cannot mute the alert (nor, for at_or_below, pin its "already notified at this price" memory).
      select d.created_at, d.observed_price
      into v_live_at, v_live_price
      from private.price_alert_deliveries d
      where d.alert_id = v_alert.id
        and d.status in ('pending', 'processing', 'failed')
        and coalesce(d.payment_type, 'unknown') = v_alert.payment_type
      order by d.created_at desc
      limit 1;

      if v_live_at is not null and (v_alert.last_notified_at is null or v_live_at >= v_alert.last_notified_at) then
        v_last_at := v_live_at;
        v_last_price := v_live_price;
      else
        v_last_at := v_alert.last_notified_at;
        v_last_price := v_alert.last_notified_price;
      end if;

      select e.should_notify, e.reason_code, e.new_baseline_price
      into v_decision
      from private.evaluate_price_alert_v2(
        v_alert.alert_mode,
        v_alert.threshold_price,
        v_alert.minimum_change,
        v_alert.cooldown_minutes,
        v_observed_price,
        v_alert.baseline_price,
        v_age,
        v_last_price,
        v_last_at,
        now(),
        not v_report_is_stale
      ) e;

      v_reason := v_decision.reason_code;

      update private.price_alerts
      set baseline_price = v_decision.new_baseline_price,
          baseline_at = v_reported_at
      where id = v_alert.id;

      if v_decision.should_notify then
        v_status := 'pending';
      end if;
    end if;

    for v_device in
      select d.id
      from private.price_alert_push_devices d
      where d.installation_id = v_alert.installation_id
        and d.enabled = true
        and d.invalidated_at is null
      order by d.id
    loop
      v_inserted_status := null;

      insert into private.price_alert_deliveries (
        alert_id, price_report_id, push_device_id, observed_price, previous_price,
        status, reason_code, payment_type
      ) values (
        v_alert.id, p_price_report_id, v_device.id, v_observed_price, v_alert.baseline_price,
        v_status, v_reason, v_alert.payment_type
      )
      on conflict (alert_id, price_report_id, push_device_id) do nothing
      returning status into v_inserted_status;

      if v_inserted_status = 'pending' then
        v_pending := v_pending + 1;
      elsif v_inserted_status = 'skipped' then
        v_skipped := v_skipped + 1;
      end if;
    end loop;
  end loop;

  return query select v_pending, v_skipped;
end;
$$;

revoke execute on function private.prepare_price_alert_deliveries(uuid) from public, anon, authenticated;
grant execute on function private.prepare_price_alert_deliveries(uuid) to postgres, service_role;

-- ------------------------------------------------------------------------------------------------
-- 4b. mark_price_alert_delivery_sent: the body of 20260918000854 plus ONE guard (marked below).
--     Signature, return value, ACL (CREATE OR REPLACE keeps it) and every other effect are unchanged.
-- ------------------------------------------------------------------------------------------------

create or replace function private.mark_price_alert_delivery_sent(
  p_delivery_id uuid,
  p_provider_status integer default 200
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_delivery private.price_alert_deliveries%rowtype;
begin
  select * into v_delivery
  from private.price_alert_deliveries
  where id = p_delivery_id
  for update;

  if v_delivery.id is null then
    return false;
  end if;

  if v_delivery.status = 'sent' then
    return true;
  end if;

  if v_delivery.status <> 'processing' then
    return false;
  end if;

  update private.price_alert_deliveries
  set status = 'sent',
      provider_status = p_provider_status,
      sent_at = now(),
      locked_at = null,
      last_error_code = null
  where id = p_delivery_id;

  update private.price_alert_push_devices
  set last_success_at = now(),
      last_failure_at = null,
      failure_count = 0
  where id = v_delivery.push_device_id;

  -- THE GUARD (Phase 3C): record the sent price on the alert only while the alert still has the payment method this
  -- delivery was decided under (a delivery decided before payment methods existed counts as 'unknown'). Switching an
  -- alert from Credit to Cash clears its notification memory; without the guard a Credit notification that is
  -- delivered a moment later would write a Credit price back into the Cash alert.
  update private.price_alerts
  set last_notified_price = v_delivery.observed_price,
      last_notified_at = now()
  where id = v_delivery.alert_id
    and payment_type = coalesce(v_delivery.payment_type, 'unknown');

  perform private.finalize_price_alert_job(v_delivery.price_report_id);
  return true;
end;
$$;

-- ------------------------------------------------------------------------------------------------
-- 5. Anchor the reference when an alert is configured.
--    INSERT, or an UPDATE that changes the mode or the payment method (a reference from another method is
--    meaningless). A plain edit of the threshold, sensitivity or cooldown keeps the reference.
-- ------------------------------------------------------------------------------------------------

create or replace function private.anchor_price_alert_baseline()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anchor_price numeric;
  v_anchor_at timestamptz;
begin
  if tg_op = 'UPDATE'
     and new.alert_mode is not distinct from old.alert_mode
     and new.payment_type is not distinct from old.payment_type then
    return new;
  end if;

  select l.price, l.reported_at
  into v_anchor_price, v_anchor_at
  from private.latest_comparable_price_report(new.station_id, new.payment_type) l
  where l.reported_at >= now() - private.price_alert_reference_horizon();

  -- NULL when there is no comparable price: nothing is invented. The first comparable report establishes it.
  new.baseline_price := v_anchor_price;
  new.baseline_at := v_anchor_at;

  if tg_op = 'UPDATE' then
    -- A price we last notified under another method or mode is not comparable with the new one.
    new.last_notified_price := null;
  end if;

  return new;
end;
$$;

drop trigger if exists price_alerts_anchor_baseline on private.price_alerts;
create trigger price_alerts_anchor_baseline
  before insert or update of alert_mode, payment_type on private.price_alerts
  for each row execute function private.anchor_price_alert_baseline();

-- ------------------------------------------------------------------------------------------------
-- 6. One-time fill for alerts that exist when this migration FIRST runs (all 'unknown'): the reference the
--    old engine would have used as `previous` for the next report, from real data only and only within the
--    horizon. Skipped on any later re-application (see step 1), so the file stays a no-op when re-run.
-- ------------------------------------------------------------------------------------------------

with anchors as (
  select a.id, l.price, l.reported_at
  from private.price_alerts a
  cross join lateral private.latest_comparable_price_report(a.station_id, a.payment_type) l
  where a.baseline_price is null
    and current_setting('price_alerts.payment_aware_first_run', true) = 'yes'
    and l.reported_at >= now() - private.price_alert_reference_horizon()
)
update private.price_alerts a
set baseline_price = anchors.price,
    baseline_at = anchors.reported_at
from anchors
where a.id = anchors.id
  and a.baseline_price is null;

-- ------------------------------------------------------------------------------------------------
-- 7. ACLs of the new internals: postgres only (the API and worker connect as the database owner).
-- ------------------------------------------------------------------------------------------------

revoke execute on function private.price_alert_reference_horizon() from public, anon, authenticated;
revoke execute on function private.comparable_report_types(text) from public, anon, authenticated;
revoke execute on function private.payment_type_is_comparable(text, text) from public, anon, authenticated;
revoke execute on function private.latest_comparable_price_report(uuid, text) from public, anon, authenticated;
revoke execute on function private.has_newer_comparable_price_report(uuid, text, timestamptz, timestamptz, uuid) from public, anon, authenticated;
revoke execute on function private.evaluate_price_alert_v2(
  text, numeric, numeric, integer, numeric, numeric, interval, numeric, timestamptz, timestamptz, boolean
) from public, anon, authenticated;
revoke execute on function private.anchor_price_alert_baseline() from public, anon, authenticated;

grant execute on function private.price_alert_reference_horizon() to postgres;
grant execute on function private.comparable_report_types(text) to postgres;
grant execute on function private.payment_type_is_comparable(text, text) to postgres;
grant execute on function private.latest_comparable_price_report(uuid, text) to postgres;
grant execute on function private.has_newer_comparable_price_report(uuid, text, timestamptz, timestamptz, uuid) to postgres;
grant execute on function private.evaluate_price_alert_v2(
  text, numeric, numeric, integer, numeric, numeric, interval, numeric, timestamptz, timestamptz, boolean
) to postgres;
grant execute on function private.anchor_price_alert_baseline() to postgres;

comment on function private.evaluate_price_alert_v2(
  text, numeric, numeric, integer, numeric, numeric, interval, numeric, timestamptz, timestamptz, boolean
) is '85Blends 2.4.1 payment-aware pure decision function: given an alert, one COMPARABLE observed price and the alert reference, returns whether to notify, why, and the reference to store afterwards. Supersedes private.evaluate_price_alert, which is kept unchanged and is no longer called.';
comment on function private.prepare_price_alert_deliveries(uuid) is
  '85Blends 2.4.1 payment-aware delivery preparation. One locked decision per alert (station-level advisory lock first): only comparable (same payment method, or explicit same_for_both) and newest-comparable reports can notify; the reference is advanced here; the cooldown is measured from the last sent notification or one still queued; one ledger row per active device. Performs no network I/O.';
comment on function private.evaluate_price_alert(
  text, numeric, numeric, integer, numeric, numeric, numeric, timestamptz, timestamptz
) is '85Blends 2.4.0 original decision function. DEPRECATED by 20261007130000: no longer called; use private.evaluate_price_alert_v2.';

reset lock_timeout;

-- 85Blends 2.4.1 — Phase 3C, migration A of 2: community E85 price reports learn WHICH price they are.
--
-- NOT APPLIED TO PRODUCTION. This file only prepares the change; applying it is a separate, explicitly
-- authorized step (see docs/PRICE_ALERTS_PAYMENT_TYPES_2.4.1.md, "Rollout order"). Apply this migration
-- BEFORE migration B (20261007130000) and BEFORE any app build that sends `payment_type`.
--
-- WHY
--   A station can show one price for cash and a different one for credit. Reports carried a single
--   number, so a Cash report followed by a Credit report looked like a price change. This adds the
--   payment method a report applies to, and nothing else. It does not change any alert behavior by
--   itself: the alert engine keeps reading reports exactly as before until migration B.
--
-- VOCABULARY (one spelling in the database, the API and the app)
--   cash            the price shown for paying cash
--   credit          the price shown for paying by card
--   same_for_both   ONE price the reporter saw for both; qualifies as cash AND credit, never inferred
--   unknown         legacy / unspecified: every report that existed before this migration, and every
--                   report from an app version that does not send the field. Nothing is guessed.
--
-- WHAT THIS DOES (all additive; safe to re-run)
--   1. Adds public.e85_price_reports.payment_type text NOT NULL DEFAULT 'unknown'. A constant default is
--      catalog-only on PostgreSQL 11+ (no table rewrite, no per-row backfill); existing rows read as
--      'unknown' and keep their id, price, reported_at, created_at and reporter exactly.
--   2. Adds a CHECK limiting the column to the four values above. It is added NOT VALID and then
--      VALIDATEd so the table scan holds only a SHARE UPDATE EXCLUSIVE lock (inserts keep flowing),
--      the same pattern 20260918000954 used.
--   3. Extends the clients' COLUMN-SCOPED INSERT grant with payment_type (and nothing else). Without
--      this a new app that names the column is refused with "permission denied for column", while an
--      old app that omits it keeps working (an omitted column needs no privilege; it takes the default).
--      The INSERT policy is deliberately NOT touched: it already bounds price, reporter and reported_at,
--      and the CHECK bounds the new column for every writer including the Data API.
--   4. Adds one index for "latest report of a given payment type at a station" - the lookup the alert
--      engine, the alert anchor and the app all make. The existing (station_id, reported_at desc,
--      created_at desc) index stays for "latest of any type". Plain CREATE INDEX holds a SHARE lock
--      (inserts wait, reads do not) for the build only, which is short at this table size; a migration
--      runs in a transaction so CONCURRENTLY is not available.
--
-- WHAT THIS DOES NOT DO
--   * No UPDATE/DELETE grant (reports stay immutable), no RLS change, no new policy, no backfill, no
--     guessed payment types, no change to the rate-limit or alert-enqueue triggers, no change to any
--     function. Older clients, Android included, are unaffected.
--
-- ROLLBACK (only before anything depends on it)
--   drop index if exists public.e85_price_reports_station_payment_latest_idx;
--   revoke insert (payment_type) on public.e85_price_reports from anon, authenticated;
--   alter table public.e85_price_reports drop constraint if exists e85_price_reports_payment_type_check;
--   alter table public.e85_price_reports drop column if exists payment_type;
--   Once migration B or any client depends on the column, drop it only after reverting those first.

alter table public.e85_price_reports
  add column if not exists payment_type text not null default 'unknown';

do $constraint$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.e85_price_reports'::regclass
      and conname = 'e85_price_reports_payment_type_check'
  ) then
    alter table public.e85_price_reports
      add constraint e85_price_reports_payment_type_check
      check (payment_type in ('cash', 'credit', 'same_for_both', 'unknown')) not valid;
  end if;
end
$constraint$;

alter table public.e85_price_reports validate constraint e85_price_reports_payment_type_check;

grant insert (payment_type) on table public.e85_price_reports to anon, authenticated;

create index if not exists e85_price_reports_station_payment_latest_idx
  on public.e85_price_reports (station_id, payment_type, reported_at desc, created_at desc);

comment on column public.e85_price_reports.payment_type is
  '85Blends 2.4.1 payment method this price applies to: cash, credit, same_for_both (one price for both, explicit - never inferred) or unknown (legacy / unspecified - nothing is guessed). Omitted by older clients, which therefore store unknown.';

-- RECOVERED HISTORICAL MIGRATION
-- Source: retrieved verbatim from supabase_migrations.schema_migrations.statements on the live
-- project (zefkbtscieokkdenvnkg), version 20260917231933, name harden_community_report_insert_grants,
-- via read-only SQL (array_to_string(statements, ...)) on 2026-09-19, as part of the 85Blends 2.4.0
-- migration-history reconciliation audit. This is the exact SQL text Supabase recorded as applied
-- for this version — not a reconstruction. Confidence: exact (validated against a known-good case
-- in the same query pass: 20260909101257's retrieved statements matched its local file byte-for-
-- byte). This file previously existed nowhere in this repository's git history, on any branch —
-- verified via `git log --all` / `git grep` across every ref before writing this file.
--
-- Not applied by this recovery — it is already live (this migration restores Git's record of that
-- fact, it does not change the database). Placing this file under its authoritative live version
-- number only makes local history match remote; it requires no ledger change (see
-- MIGRATION_RECOVERY.md's identical framing for the 13 migrations recovered the same way there).

-- 85Blends 2.4.0 backend hardening: restore least-privilege anonymous INSERT grants
-- after the older table-wide compatibility grant, and align price reporter validation
-- with the ethanol-report table. Existing 2.4.0 and legacy payload shapes remain supported.

revoke insert on table public.community_stations from anon, authenticated;
grant insert (name, address, city, state, zip, latitude, longitude, normalized_key, updated_at)
  on public.community_stations
  to anon, authenticated;

revoke insert on table public.e85_price_reports from anon, authenticated;
grant insert (station_id, price, reported_at, anonymous_reporter_id, app_version, note)
  on public.e85_price_reports
  to anon, authenticated;

alter table public.e85_price_reports
  add constraint e85_price_reports_reporter_id_not_blank
  check (btrim(anonymous_reporter_id) <> '');

drop policy if exists "Public can insert price reports" on public.e85_price_reports;
create policy "Public can insert price reports"
  on public.e85_price_reports
  for insert
  to anon, authenticated
  with check (
    price >= 1.00
    and price <= 8.00
    and btrim(anonymous_reporter_id) <> ''
  );

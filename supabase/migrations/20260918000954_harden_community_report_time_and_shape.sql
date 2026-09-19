-- RECOVERED HISTORICAL MIGRATION
-- Source: retrieved verbatim from supabase_migrations.schema_migrations.statements on the live
-- project (zefkbtscieokkdenvnkg), version 20260918000954, name
-- harden_community_report_time_and_shape, via read-only SQL on 2026-09-19, as part of the
-- 85Blends 2.4.0 migration-history reconciliation audit. Exact SQL text Supabase recorded as
-- applied for this version — not a reconstruction. Confidence: exact. Absent from this
-- repository's git history on every branch before this file.
--
-- Not applied by this recovery — already live; this file only makes local history match remote.

alter table public.community_stations
  add constraint community_stations_name_not_blank check (btrim(name) <> '') not valid,
  add constraint community_stations_name_length check (char_length(name) <= 200) not valid,
  add constraint community_stations_address_length check (address is null or char_length(address) <= 300) not valid,
  add constraint community_stations_city_length check (city is null or char_length(city) <= 100) not valid,
  add constraint community_stations_state_length check (state is null or char_length(state) <= 32) not valid,
  add constraint community_stations_zip_length check (zip is null or char_length(zip) <= 20) not valid,
  add constraint community_stations_normalized_key_not_blank check (btrim(normalized_key) <> '') not valid,
  add constraint community_stations_normalized_key_length check (char_length(normalized_key) <= 512) not valid,
  add constraint community_stations_latitude_range check (latitude is null or latitude between -90 and 90) not valid,
  add constraint community_stations_longitude_range check (longitude is null or longitude between -180 and 180) not valid;

alter table public.community_stations validate constraint community_stations_name_not_blank;
alter table public.community_stations validate constraint community_stations_name_length;
alter table public.community_stations validate constraint community_stations_address_length;
alter table public.community_stations validate constraint community_stations_city_length;
alter table public.community_stations validate constraint community_stations_state_length;
alter table public.community_stations validate constraint community_stations_zip_length;
alter table public.community_stations validate constraint community_stations_normalized_key_not_blank;
alter table public.community_stations validate constraint community_stations_normalized_key_length;
alter table public.community_stations validate constraint community_stations_latitude_range;
alter table public.community_stations validate constraint community_stations_longitude_range;

alter table public.e85_price_reports
  add constraint e85_price_reports_note_length check (note is null or char_length(note) <= 500) not valid,
  add constraint e85_price_reports_app_version_length check (app_version is null or char_length(app_version) between 1 and 32) not valid;
alter table public.e85_price_reports validate constraint e85_price_reports_note_length;
alter table public.e85_price_reports validate constraint e85_price_reports_app_version_length;

alter table public.e85_ethanol_reports
  add constraint e85_ethanol_reports_note_length check (note is null or char_length(note) <= 500) not valid,
  add constraint e85_ethanol_reports_app_version_length check (app_version is null or char_length(app_version) between 1 and 32) not valid;
alter table public.e85_ethanol_reports validate constraint e85_ethanol_reports_note_length;
alter table public.e85_ethanol_reports validate constraint e85_ethanol_reports_app_version_length;

drop policy if exists "Public can insert price reports" on public.e85_price_reports;
create policy "Public can insert price reports"
  on public.e85_price_reports
  for insert
  to anon, authenticated
  with check (
    price >= 1.00 and price <= 8.00
    and btrim(anonymous_reporter_id) <> ''
    and reported_at >= now() - interval '7 days'
    and reported_at <= now() + interval '10 minutes'
  );

drop policy if exists "Public can insert ethanol reports" on public.e85_ethanol_reports;
create policy "Public can insert ethanol reports"
  on public.e85_ethanol_reports
  for insert
  to anon, authenticated
  with check (
    ethanol_percentage >= 0 and ethanol_percentage <= 100
    and btrim(anonymous_reporter_id) <> ''
    and reported_at >= now() - interval '7 days'
    and reported_at <= now() + interval '10 minutes'
  );


-- 85Blends 2.3.2 community-station upsert security hardening -- phase 5.
--
-- The interim fix (community_stations_allow_public_upsert_update) granted anon/authenticated
-- column-scoped UPDATE + a permissive "USING (true) WITH CHECK (true)" policy on
-- public.community_stations so the app's ON CONFLICT DO UPDATE upsert would work. That let any
-- anonymous API client directly rewrite the display/location fields of ANY existing community
-- station -- authority no legitimate 85Blends flow actually uses (the client only ever creates
-- new rows or reads existing ones; see CommunityPriceService.upsertCommunityStation).
--
-- The client (this same release) now sends "Prefer: resolution=ignore-duplicates" instead of
-- "resolution=merge-duplicates", so PostgREST generates INSERT ... ON CONFLICT DO NOTHING,
-- which requires only INSERT privilege. UPDATE is no longer needed for any real app behavior,
-- so it is removed here.

drop policy if exists "Public can update community station details" on public.community_stations;

revoke update (name, address, city, state, zip, latitude, longitude, updated_at)
  on public.community_stations
  from anon, authenticated;

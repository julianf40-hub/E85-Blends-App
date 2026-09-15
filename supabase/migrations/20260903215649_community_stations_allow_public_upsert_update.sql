
-- 85Blends 2.3.2 Supabase release gate.
--
-- Verified problem (empirically reproduced, not assumed from documentation):
-- The iOS client's upsertCommunityStation call (CommunityPriceService.swift) submits with
-- header "Prefer: resolution=merge-duplicates", which PostgREST turns into
-- "INSERT ... ON CONFLICT (normalized_key) DO UPDATE SET ...". Postgres requires UPDATE
-- privilege (checked at plan time for the whole statement, not conditionally at runtime)
-- for the DO UPDATE clause to be permitted at all -- even for a row that doesn't actually
-- conflict with anything. anon/authenticated had INSERT (column-scoped) and SELECT on
-- public.community_stations, but no UPDATE grant and no UPDATE policy at all, so every
-- upsertCommunityStation call from a real, anonymous 85Blends user currently fails with
-- "permission denied for table community_stations" -- confirmed live against production
-- via a rolled-back transaction before this migration was written.
--
-- This does NOT touch e85_price_reports (its INSERT-only path already works correctly,
-- confirmed by the same live test), and does not grant DELETE or unrestricted UPDATE
-- anywhere. Least-privilege, symmetric with the existing "Public can insert community
-- stations" policy's own trust model (that policy already allows anon to write arbitrary
-- name/address/coordinate content on INSERT with WITH CHECK (true) -- this extends the same
-- already-accepted trust boundary to the update-half of the app's existing, shipped
-- upsert-merge feature, nothing broader):
--
--   * UPDATE privilege is granted only on the display/geo columns the upsert's DO UPDATE
--     SET clause actually writes -- never on id, external_source, external_id, created_at,
--     or normalized_key (the conflict/identity key itself is never updatable).
--   * The matching RLS UPDATE policy mirrors the existing INSERT policy's permissiveness
--     (USING (true) WITH CHECK (true)) since the column-level grant above is what actually
--     bounds which fields a request can touch, not this policy.

grant update (name, address, city, state, zip, latitude, longitude, updated_at)
  on public.community_stations
  to anon, authenticated;

create policy "Public can update community station details"
  on public.community_stations
  for update
  to anon, authenticated
  using (true)
  with check (true);

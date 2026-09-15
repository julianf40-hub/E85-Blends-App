-- SYNTHETIC RECONSTRUCTION -- not an original migration, never applied anywhere. Authored during
-- a recovery rehearsal (see /tmp/85blends-migration-recovery-20260915094818) to reconstruct the
-- founding state of public.community_stations and public.e85_price_reports as they must have
-- existed immediately before the first recorded migration that touches either one
-- (20260903215649). Neither table has a creation migration anywhere in the live ledger or in any
-- git history reachable from this checkout -- see supabase/README.md's own documented admission.
--
-- Placeholder version 20260427000000: chosen only to sort before every other known migration and
-- to land near this feature's documented real-world origin ("Created by Codex on 4/27/26" in
-- CommunityPriceModels.swift/CommunityPriceService.swift) -- the exact date/time is illustrative,
-- not authoritative. Do not treat this version number as anything but a placeholder pending your
-- own decision.
--
-- Derived by working backward from: current live catalog metadata (columns, constraints,
-- indexes), the exact text of every later recorded migration (to exclude anything they
-- introduce), and this repository's client code / documentation (CommunityPriceService.swift,
-- CommunityPriceModels.swift, docs/PRE_RELEASE_SUPABASE_CHECKLIST.md).
--
-- DELIBERATELY EXCLUDED because a later recovered migration introduces it -- see that migration
-- for the real history, not here:
--   * "Public can update community station details" policy -- created by 20260903215649, dropped
--     by 20260903221221. Never present at true founding; never present live today.
--   * The temporary re-grant of UPDATE on community_stations -- 20260903222357 only.
--   * e85_price_reports_station_latest_idx -- created by 20260910213128, not before.
--   * Any INSERT grant wider than the narrow column list below -- the additional bare, table-wide
--     INSERT grant used live today was added by 20260909101257 (enable_community_price_inserts),
--     which this chain replays afterward.

create table public.community_stations (
  id               uuid        primary key default gen_random_uuid(),
  external_source  text        not null default 'AFDC',
  external_id      text,
  name             text        not null,
  address          text,
  city             text,
  state            text,
  zip              text,
  latitude         double precision,
  longitude        double precision,
  normalized_key   text        not null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint community_stations_normalized_key_key unique (normalized_key)
);
-- VERIFIED against live catalog metadata: id/PK, normalized_key/UNIQUE, every column name/type/
-- nullability/default matches exactly (information_schema.columns + pg_constraint, queried
-- during this rehearsal). Must exist before the first recovered migration: nothing later ALTERs
-- any of these columns or either constraint -- both are exactly what's live today. Consumed by:
-- every one of the 13 recovered migrations that reference community_stations, directly (the
-- three community_stations_* migrations) or transitively via e85_price_reports' foreign key and
-- price_alert_backend_foundation's private.price_alerts.station_id foreign key. A wrong
-- reconstruction of the TABLE ITSELF (missing column, wrong type, missing constraint) is a REPLAY
-- FAILURE risk: every later statement referencing these columns/constraints would break.

alter table public.community_stations enable row level security;
-- VERIFIED (pg_class.relrowsecurity = true live, relforcerowsecurity = false). Must precede any
-- policy on this table (Postgres requires RLS enabled before CREATE POLICY is meaningful, though
-- not strictly before the statement succeeds -- a policy can be created before RLS is enabled and
-- simply has no effect until enabled; ordered first here to match the natural authoring order
-- every other migration in this project uses).

create policy "Public can insert community stations"
  on public.community_stations
  for insert
  to anon, authenticated
  with check (true);
-- VERIFIED name and definition, queried live from pg_policies during this rehearsal. Must exist
-- before 20260903215649, which only ever ADDS an UPDATE policy alongside this one and never
-- creates this one itself -- if this policy didn't already exist, the app's entire community-
-- station creation flow (shipped well before any of the 13 recovered migrations) could never have
-- worked. Consumed by: nothing later alters or drops it; it is the live definition today,
-- unchanged. A wrong NAME here is a replay-failure risk for any future migration that might
-- reference it by name (none of the 13 currently do, but reconstructing under a different name
-- than the real one would misrepresent live history and break any future DROP/ALTER POLICY
-- referencing the real name).

create policy "Public can read community stations"
  on public.community_stations
  for select
  to anon, authenticated
  using (true);
-- VERIFIED name/definition (live pg_policies). Same reasoning as above -- must be founding, never
-- altered since.

grant select on table public.community_stations to anon, authenticated;
grant insert (name, address, city, state, zip, latitude, longitude, normalized_key, updated_at)
  on public.community_stations
  to anon, authenticated;
-- VERIFIED scope, not inferred: 20260903215649's own header comment states the pre-existing state
-- verbatim -- "anon/authenticated had INSERT (column-scoped) and SELECT on
-- public.community_stations, but no UPDATE grant and no UPDATE policy at all" -- and
-- docs/PRE_RELEASE_SUPABASE_CHECKLIST.md independently names the exact excluded columns:
-- "id/external_source/external_id/created_at are not in anon's column-scoped INSERT grant at
-- all". The 9 columns granted here are exactly the 13 live columns minus those 4. Cross-confirmed
-- against the client: CommunityPriceService.swift's CommunityStationPayload sends updated_at on
-- every insert, consistent with it being grantable. Consumed/altered by: 20260909101257
-- (enable_community_price_inserts) grants a second, bare, table-wide INSERT on top of this -- the
-- live column-privilege set today is the union of this grant and that one. A wrong reconstruction
-- here causes FINAL-STATE DRIFT ONLY, never a replay failure -- GRANT statements have no forward
-- dependency that could break; 20260909101257 converges to the correct live end state regardless
-- of exactly which columns started here.

create table public.e85_price_reports (
  id                     uuid         primary key default gen_random_uuid(),
  station_id             uuid         not null references public.community_stations(id) on delete cascade,
  price                  numeric(5,2) not null,
  reported_at            timestamptz  not null default now(),
  anonymous_reporter_id  text         not null,
  app_version            text,
  note                   text,
  created_at             timestamptz  not null default now(),

  constraint e85_price_reports_price_check check (price >= 1.00 and price <= 8.00)
);
-- VERIFIED against live catalog metadata: every column name/type/nullability/default, the foreign
-- key (including ON DELETE CASCADE), and the price CHECK constraint match exactly what's live
-- today (pg_constraint via pg_get_constraintdef, queried during this rehearsal). Must exist
-- before the first recovered migration: no later recorded migration ALTERs this table's columns,
-- its FK, or its CHECK. The price bound is independently confirmed by
-- docs/PRE_RELEASE_SUPABASE_CHECKLIST.md as already live well before any of the 13 recovered
-- migrations were written. Consumed by: price_alert_backend_foundation's own foreign keys
-- (private.price_alerts.station_id -> community_stations.id;
-- private.price_alert_jobs.price_report_id -> e85_price_reports.id) require both tables and this
-- exact shape to already exist. A wrong FK or CHECK here IS a REPLAY-FAILURE risk, not just
-- drift -- price_alert_backend_foundation's own FK constraints would fail to create against a
-- differently-shaped or missing target.

alter table public.e85_price_reports enable row level security;
-- VERIFIED (pg_class.relrowsecurity = true live).

create policy "Public can insert price reports"
  on public.e85_price_reports
  for insert
  to anon, authenticated
  with check (price >= 1.00 and price <= 8.00 and anonymous_reporter_id is not null);
-- VERIFIED name/definition (live pg_policies). No recorded migration creates this -- must be
-- founding. Consumed by: nothing later alters it; this is the live definition today, unchanged.
-- Note (separate from this reconstruction's correctness): reported_at is not constrained by this
-- WITH CHECK at all, live, today -- reproduced faithfully as-is, not corrected here.

create policy "Public can read price reports"
  on public.e85_price_reports
  for select
  to anon, authenticated
  using (true);
-- VERIFIED name/definition (live pg_policies). Same reasoning.

grant select on table public.e85_price_reports to anon, authenticated;
grant insert (station_id, price, reported_at, anonymous_reporter_id, app_version, note)
  on public.e85_price_reports
  to anon, authenticated;
-- INFERRED scope: unlike community_stations, no equally explicit historical quote was found
-- stating e85_price_reports' original INSERT grant was column-scoped in this same narrow way --
-- reconstructed here by analogy to the sibling table's documented least-privilege pattern
-- (id/created_at excluded) and this project's consistently demonstrated design philosophy
-- elsewhere. A wrong guess here causes FINAL-STATE DRIFT ONLY, never a replay failure:
-- 20260909101257's later bare GRANT INSERT on this same table widens either possible starting
-- point (narrow or already-full) to the identical live-matching end state regardless of which is
-- true. This is the one explicitly-flagged inference in this file whose correction, if ever
-- confirmed otherwise, changes nothing about whether the chain replays successfully.

grant delete, insert, references, select, trigger, truncate, update
  on table public.community_stations
  to service_role;
grant delete, insert, references, select, trigger, truncate, update
  on table public.e85_price_reports
  to service_role;
-- CORRECTED (packaging pass): previously left unreconstructed and described as relying on
-- Postgres default ownership/privilege behavior -- that was an implicit, non-deterministic
-- assumption this reconstruction should not have made silently. VERIFIED explicitly instead: a
-- fresh live query (information_schema.role_table_grants, grantee = 'service_role') during this
-- packaging pass confirms the exact live set on both tables is
-- {DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE} -- reproduced verbatim here, in
-- that same order, rather than inferred. A separate fresh check (grantee = 'PUBLIC') confirms zero
-- rows on either table -- nothing in this file grants anything to bare PUBLIC, matching live
-- exactly. Consumed by: nothing later revokes or narrows this; it is the live grant set today,
-- unchanged since (no recorded migration touches service_role's privileges on either table).

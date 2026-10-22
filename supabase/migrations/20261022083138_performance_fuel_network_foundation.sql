-- 85Blends Performance Fuel Network: additive backend foundation.
-- Do not modify legacy community_stations, E85 prices/ethanol reports, or catalogue proxy.
-- Only server-side trusted operations may create, edit, approve, or review entries.

create table public.performance_fuel_locations (
  id uuid primary key default gen_random_uuid(),
  canonical_key text not null unique,
  name text not null,
  location_type text not null
    check (location_type in ('gas_station','race_fuel_pump','performance_shop','distributor','race_track','other')),
  street_address text,
  city text,
  region text,
  postal_code text,
  country_code text not null default 'US'
    check (country_code ~ '^[A-Z]{2}$'),
  latitude double precision not null
    check (latitude >= -90 and latitude <= 90),
  longitude double precision not null
    check (longitude >= -180 and longitude <= 180),
  retail_access text not null default 'unknown'
    check (retail_access in ('public','call_ahead','appointment_only','restricted','unknown')),
  phone text,
  website text,
  hours_note text,
  source text not null default 'admin_research'
    check (source in ('admin_research','approved_community','business_confirmed')),
  last_business_confirmed_at timestamptz,
  status text not null default 'draft'
    check (status in ('draft','published','hidden','retired')),
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint performance_fuel_location_key_chk check (length(btrim(canonical_key)) between 1 and 512),
  constraint performance_fuel_location_name_chk check (length(btrim(name)) between 1 and 200),
  constraint performance_fuel_location_coords_chk check (latitude <> 0 or longitude <> 0),
  constraint performance_fuel_location_published_chk check (status <> 'published' or published_at is not null)
);

create index performance_fuel_locations_geo_idx
  on public.performance_fuel_locations (latitude,longitude)
  where status = 'published';
create index performance_fuel_locations_region_idx
  on public.performance_fuel_locations (region,city)
  where status = 'published';

create table public.performance_fuel_offerings (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.performance_fuel_locations(id) on delete restrict,
  fuel_type text not null
    check (fuel_type in ('e85','racing_ethanol','race_gas','other_performance')),
  product_name text not null,
  octane_rating numeric(5,1) check (octane_rating between 0 and 150),
  octane_method text not null default 'unspecified'
    check (octane_method in ('aki','ron','mon','unspecified')),
  ethanol_min_pct numeric(5,2) check (ethanol_min_pct between 0 and 100),
  ethanol_max_pct numeric(5,2) check (ethanol_max_pct between 0 and 100),
  leaded boolean,
  street_legal boolean,
  delivery_method text not null
    check (delivery_method in ('pump','pail','drum','bulk','other')),
  package_size_gallons numeric(9,2) check (package_size_gallons > 0),
  availability text not null default 'unknown'
    check (availability in ('unknown','available','call_ahead','temporarily_unavailable')),
  price_amount numeric(12,2) check (price_amount >= 0),
  price_unit text not null default 'contact'
    check (price_unit in ('gallon','container','contact')),
  currency_code text not null default 'USD' check (currency_code ~ '^[A-Z]{3}$'),
  price_source text check (price_source in ('community_reported','business_reported','admin_confirmed')),
  price_reported_at timestamptz,
  ethanol_source text check (ethanol_source in ('test_kit','fuel_analyzer','pump_label','business_claim','other')),
  last_confirmed_at timestamptz,
  status text not null default 'draft'
    check (status in ('draft','published','hidden')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint performance_fuel_offerings_name_chk check (length(btrim(product_name)) between 1 and 200),
  constraint performance_fuel_offerings_ethanol_range_chk
    check (ethanol_min_pct is null or ethanol_max_pct is null or ethanol_min_pct <= ethanol_max_pct),
  constraint performance_fuel_offerings_price_chk
    check (
      (price_amount is null and price_source is null and price_reported_at is null)
      or
      (price_amount is not null and price_unit <> 'contact' and price_source is not null and price_reported_at is not null)
    ),
  constraint performance_fuel_offerings_container_chk
    check (price_amount is null or price_unit <> 'container' or package_size_gallons is not null)
);
create index performance_fuel_offerings_location_idx
  on public.performance_fuel_offerings (location_id,fuel_type)
  where status = 'published';

-- Private moderation/evidence never exposed through the public Data API.
create table private.performance_fuel_submissions (
  id uuid primary key default gen_random_uuid(),
  idempotency_key uuid not null,
  submitted_by_app_user_id text not null,
  platform text not null check (platform in ('ios','android')),
  entitlement_environment text not null check (entitlement_environment in ('production','sandbox')),
  entitlement_verified_at timestamptz not null,
  proposed_name text not null,
  proposed_location_type text not null
    check (proposed_location_type in ('gas_station','race_fuel_pump','performance_shop','distributor','race_track','other')),
  proposed_address text,
  proposed_city text,
  proposed_region text,
  proposed_postal_code text,
  proposed_latitude double precision not null
    check (proposed_latitude between -90 and 90),
  proposed_longitude double precision not null
    check (proposed_longitude between -180 and 180),
  gps_latitude double precision not null check (gps_latitude between -90 and 90),
  gps_longitude double precision not null check (gps_longitude between -180 and 180),
  gps_accuracy_meters numeric(8,2) not null check (gps_accuracy_meters > 0 and gps_accuracy_meters <= 100),
  gps_recorded_at timestamptz not null,
  photo_captured_at timestamptz not null,
  photo_storage_path text not null unique,
  photo_sha256 text check (photo_sha256 is null or photo_sha256 ~ '^[0-9a-f]{64}$'),
  proximity_meters numeric(8,2) not null check (proximity_meters between 0 and 150),
  proposed_offerings jsonb not null
    check (jsonb_typeof(proposed_offerings) = 'array' and jsonb_array_length(proposed_offerings) between 1 and 8
      and octet_length(proposed_offerings::text) <= 16384),
  status text not null default 'pending'
    check (status in ('pending','needs_info','approved','rejected','duplicate')),
  approved_location_id uuid references public.performance_fuel_locations(id) on delete set null,
  accepted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by text,
  reviewer_note text check (reviewer_note is null or char_length(reviewer_note) <= 2000),
  constraint performance_fuel_submission_pro_name_chk check (length(btrim(proposed_name)) between 1 and 200),
  constraint performance_fuel_submission_identity_chk check (length(btrim(submitted_by_app_user_id)) between 1 and 256),
  constraint performance_fuel_submission_storage_chk check (length(btrim(photo_storage_path)) between 1 and 512),
  constraint performance_fuel_submission_idempotency_uniq unique (submitted_by_app_user_id,idempotency_key)
);
create index performance_fuel_submissions_review_queue_idx
  on private.performance_fuel_submissions (status,accepted_at);
create index performance_fuel_submissions_contributor_idx
  on private.performance_fuel_submissions (submitted_by_app_user_id,accepted_at desc);

create table private.performance_fuel_submission_reviews (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references private.performance_fuel_submissions(id) on delete restrict,
  review_action text not null check (review_action in ('approved','rejected','needs_info','duplicate','reopened')),
  reviewer_id text not null check (length(btrim(reviewer_id)) between 1 and 256),
  reason text check (reason is null or char_length(reason) <= 2000),
  approved_location_id uuid references public.performance_fuel_locations(id) on delete set null,
  created_at timestamptz not null default now()
);
create index performance_fuel_reviews_submission_idx
  on private.performance_fuel_submission_reviews (submission_id,created_at desc);

-- RLS and minimum permissions. Only approved listings/offerings are visible.
alter table public.performance_fuel_locations enable row level security;
alter table public.performance_fuel_offerings enable row level security;
alter table private.performance_fuel_submissions enable row level security;
alter table private.performance_fuel_submission_reviews enable row level security;

revoke all on table public.performance_fuel_locations from public,anon,authenticated;
revoke all on table public.performance_fuel_offerings from public,anon,authenticated;
revoke all on table private.performance_fuel_submissions from public,anon,authenticated;
revoke all on table private.performance_fuel_submission_reviews from public,anon,authenticated;
grant select on table public.performance_fuel_locations to anon,authenticated;
grant select on table public.performance_fuel_offerings to anon,authenticated;
grant all on table public.performance_fuel_locations to service_role;
grant all on table public.performance_fuel_offerings to service_role;
grant all on table private.performance_fuel_submissions to service_role;
grant all on table private.performance_fuel_submission_reviews to service_role;

create policy performance_fuel_locations_public_published
  on public.performance_fuel_locations for select to anon,authenticated
  using (status = 'published');

create policy performance_fuel_offerings_public_published
  on public.performance_fuel_offerings for select to anon,authenticated
  using (status = 'published' and exists (
    select 1 from public.performance_fuel_locations l
    where l.id=location_id and l.status='published'
  ));

-- Evidence stays private; no public storage read or upload policy exists.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('performance-fuel-evidence','performance-fuel-evidence',false,5242880,
        array['image/jpeg','image/png','image/heic','image/heif'])
on conflict (id) do nothing;

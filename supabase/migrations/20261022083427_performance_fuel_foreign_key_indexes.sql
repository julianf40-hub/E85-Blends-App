-- Cover all new performance fuel foreign keys for moderation and deletes.
create index performance_fuel_offerings_location_fk_idx
  on public.performance_fuel_offerings (location_id);
create index performance_fuel_submissions_approved_location_fk_idx
  on private.performance_fuel_submissions (approved_location_id);
create index performance_fuel_reviews_approved_location_fk_idx
  on private.performance_fuel_submission_reviews (approved_location_id);

# 85Blends Performance Fuel Network — Backend Foundation

Status: **Database foundation deployed, feature not launched** (2026-10-22). Android and iOS app code remain unchanged.

## Production
- Supabase project: `zefkbtscieokkdenvnkg` (existing iOS/Android production backend).
- Production migrations: `20261022083138_performance_fuel_network_foundation.sql` and `20261022083427_performance_fuel_foreign_key_indexes.sql`.
- Zero live performance-fuel listings, offers, photo objects, submissions, or reviews upon deployment.
- Existing `community_stations`, `e85_price_reports`, `e85_ethanol_reports`, and `station-catalogue-v1` API were not modified.
- No new Supabase project or billed branch was created.

## Data model
1. **`public.performance_fuel_locations`** — independently managed business/location directory; source and access method, location category, address, contact, GPS, publication status. Values start in `draft`. Public may SELECT only `published` rows. Anonymous/authenticated clients have **no writes**.
2. **`public.performance_fuel_offerings`** — many fuel offerings per location, E85/racing ethanol/race gas/other, octane rating + rating method, possible ethanol range, leaded and street legality flags, pump/pail/drum/bulk method, availability, optional per-gallon or per-container price with source and timestamp. Public SELECT only `published` offerings attached to `published` locations; **no client writes**.
3. **`private.performance_fuel_submissions`** — server-accepted Pro submission envelope with contributor/platform, verified entitlement timestamp, current GPS + accuracy + proximity + timestamp, photo capture path and time, proposed products (bounded JSON), reviewer state, and idempotency key.
4. **`private.performance_fuel_submission_reviews`** — append-only moderation action history.
5. **Storage bucket `performance-fuel-evidence`** — private, 5 MiB max, accepts JPEG, PNG, HEIC, HEIF. No public Storage policies, so clients cannot upload/read until a secure workflow is deliberately implemented.

## Key feature boundaries
- E85 calculator, Fuel Log, station widget, and existing community Price / E% reporting must remain **E85-only** unless separately redesigned.
- The existing NLR/AFDC catalogue covers nearby public E85 pumps; it is **not** the performance fuel location database. Client discovery will eventually merge two independently sourced result sets with stable identities and deduplication.
- **Viewing approved locations is free.** Only Pro members may propose *new* listings or fuel sellers.
- Future verification must happen on a **trusted Edge Function**: confirm a server-trusted, bound Pro identity against RevenueCat; require fresh, accurate foreground GPS and on-site proximity; issue short-lived scoped private evidence uploads; inspect evidence metadata and reject stale/missing images; store a submission as pending. A client-supplied RevenueCat app user ID or a plain `isPro` boolean is **not authentication**.
- Moderator approval is the only route to public listing/offer publication. Verify retail availability (and call-ahead terms for performance shops), photo, address, possible duplicate, fuel type, and source. GPS/photos deter abuse but are not cryptographic proof of on-site presence.
- Prices and ethanol readings remain **community-reported, timestamped, and source-labeled** unless independently corroborated. Do not conflate approved business/location with verified fuel readings.
- Racing fuel grade, leaded/street use, dispensing method, and per-container prices must be displayed distinctly to avoid unsafe or misleading comparisons.
- Keep contributor's personally identifying and precise GPS evidence in private tables with a defined retention/deletion policy. Consider opt-in badge visibility later; count *approved unique* locations, not unmoderated reports.

## Next steps (not implemented)
1. Add trusted cross-platform submission identity and Pro entitlement validation (including iOS and Android RevenueCat integration and safe replay/idempotency controls).
2. Implement upload-grant and submit Edge Function with authoritative proximity/freshness/EXIF/photo validation. Add abuse limits and deletion/retention policies; do not expose raw direct insert rights.
3. Build private owner moderation tool, review logs, publication transaction, duplicate resolution, reporting/correction mechanism.
4. Pilot a small number of **confirmed** Phoenix listings; don't publish unverified candidate shops as fact.
5. Integrate read-only merged discovery + filters on iOS/Android, regression-test existing E85 behavior and existing reporting.
6. Enable authenticated Pro contribution flows after security/privacy review and end-to-end device testing.
7. Add appreciation messages, opt-in contributor badges/rankings later, only for approved meaningful submissions.

## Verification on deployment
- RLS enabled on all four new tables.
- `anon` cannot INSERT into any of the new tables or SELECT private submissions; `authenticated` cannot UPDATE them.
- Only published public rows/offerings have SELECT policies. Private tables intentionally have no client policies.
- The evidence bucket is private; no `storage.objects` policy refers to it.
- Original three public E85 tables preserved with unchanged row counts during the migration.
- Database advisors: private RLS-without-policy is intentional. Newly unused indexes are expected until traffic is live. The follow-up migration adds indexes for every new FK.

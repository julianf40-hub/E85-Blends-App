# Pre-Release Supabase Safety Checklist

> **⚠ Do not publish to the public App Store until every item below is verified.**
>
> The `SUPABASE_ANON_KEY` embedded in the app binary is the project's **anon** (public) JWT
> (`role:"anon"`). It is intentionally client-visible and safe for distribution — but *only*
> because Supabase Row Level Security (RLS) is the sole gate preventing abuse. If RLS is
> misconfigured, any user (or attacker) with the key can read, write, or delete community
> data at will.

---

## Why the anon key is safe — and what could make it unsafe

The anon key cannot be kept secret from a shipped app. It is designed to be public. Supabase's
security model assumes this: the anon key grants the `anon` Postgres role, which has no
permissions by default. Access is granted only via explicit RLS policies **and** ordinary
Postgres table/column grants — both must independently permit an operation; RLS narrows what a
grant otherwise allows, it does not substitute for the grant.

The risk surface is therefore: **missing or over-broad RLS policies or grants**, not key exposure.

---

## A note on how to check grants correctly (read this before re-auditing)

An earlier pass at this checklist concluded that `anon` INSERT was completely missing on both
tables, based on `information_schema.role_table_grants`. That view **only lists table-wide
grants** — it does not show column-scoped grants (`GRANT INSERT (col1, col2, ...) ON table TO
role`), which is exactly how INSERT (and, for `community_stations`, INSERT-and-later-UPDATE) were
actually implemented here. Checking `information_schema.role_table_grants` alone will always
under-report what `anon`/`authenticated` can actually do on these two tables. Use
`information_schema.column_privileges` (or `SET ROLE anon; ...` inside a rolled-back transaction)
to get the real answer.

**The upsert failure that motivated the fix below was real, but not what it first looked like.**
`CommunityPriceService.upsertCommunityStation` sent `Prefer: resolution=merge-duplicates`, which
PostgREST turns into `INSERT ... ON CONFLICT (normalized_key) DO UPDATE SET ...`. Postgres
requires **UPDATE** privilege for that statement shape — checked for the whole statement at plan
time, regardless of whether a conflict actually occurs at runtime — not INSERT. `anon`/
`authenticated` had (and still have) working column-scoped INSERT; they never had UPDATE, so
every `upsertCommunityStation` call whose initial existence check missed (a brand-new station, or
a genuine two-client race on the same new station) failed with `permission denied for table
community_stations`.

Two fixes were made, in order, as of 2.3.2:
1. **Interim (later reverted):** granted `anon`/`authenticated` column-scoped UPDATE on
   `community_stations`' display/location columns, plus a permissive
   `USING (true) WITH CHECK (true)` UPDATE policy, to restore the app quickly. This worked, but
   let any anonymous client rewrite any existing station's display fields — authority no
   legitimate 85Blends flow needs, since the client already returns early with the existing row
   whenever its own existence check finds one.
2. **Final:** the client now sends `Prefer: resolution=ignore-duplicates` instead, which
   PostgREST turns into `INSERT ... ON CONFLICT (normalized_key) DO NOTHING` — this requires only
   INSERT, never UPDATE, because a `DO NOTHING` conflict action never touches the conflicting row.
   The interim UPDATE grant and policy were then fully revoked. Two racing clients submitting the
   same new station still converge on one row (whichever insert wins), and the loser resolves the
   winner's row by re-fetching it via `normalized_key` — it never edits it.

---

## Table checklist

### `community_stations`

| Check | Expected | Verified? |
|---|---|---|
| RLS is **ENABLED** on this table | Yes | ✅ Verified live (`pg_class.relrowsecurity = true`) |
| Anon role has **INSERT** policy | Yes — for new station submissions | ✅ Verified live (`Public can insert community stations`, `WITH CHECK (true)`), and confirmed functionally via a real, rolled-back `SET ROLE anon` insert and a real HTTP GET/POST-path exercise |
| INSERT policy restricts columns (no `id` override, no `created_at` spoofing) | Yes | ✅ Verified live — `id`/`external_source`/`external_id`/`created_at` are not in `anon`'s column-scoped INSERT grant at all, so they always fall through to their defaults regardless of what a request body contains |
| Anon role has **NO DELETE** policy | Confirmed absent | ✅ Verified live (no DELETE policy exists; a live `SET ROLE anon; DELETE ...` and a direct request both fail with `permission denied`) |
| Anon role has **NO unrestricted UPDATE** capability | Confirmed absent | ✅ Verified live as of 2.3.2. An interim, column-scoped (never fully "unrestricted" — identity columns were always excluded) UPDATE grant + policy existed briefly to unblock the upsert above; both were fully revoked once the client stopped needing them (see the note above). Re-verified after revocation: no UPDATE grant on any column, no UPDATE policy, and a live attempt to change an existing station's name, coordinates, or `normalized_key` — via both a rolled-back `SET ROLE anon` transaction and a real HTTP `PATCH` request — is rejected with `permission denied for table community_stations` in both cases |
| Service role is **not** used anywhere in the iOS client | Confirmed | ✅ Verified — `SupabaseConfig.swift`/`Info.plist` only ever carry the anon key |

### `e85_price_reports`

| Check | Expected | Verified? |
|---|---|---|
| RLS is **ENABLED** on this table | Yes | ✅ Verified live |
| Anon role has **INSERT** policy | Yes — for price reports | ✅ Verified live (`Public can insert price reports`), and functionally via a real, rolled-back `SET ROLE anon` insert matching `CommunityPriceService.submitPriceReport`'s exact request shape |
| INSERT policy validates the price is within a sane range | Recommended | ✅ Verified live — **better than originally specified here.** The live column is named `price` (not `price_per_gallon` as earlier drafts of this checklist assumed), and it is bounded to `[1.00, 8.00]` — tighter than the `> 0 AND < 15` originally proposed — enforced identically at both the RLS `WITH CHECK` and a table `CHECK` constraint. A live attempt to submit `$999.00` is rejected by RLS. |
| Anon role has **NO DELETE** policy | Confirmed absent | ✅ Verified live |
| Anon role has **NO UPDATE** policy | Confirmed absent | ✅ Verified live — a live attempt to overwrite another report's price is rejected with `permission denied` |
| Service role is **not** used anywhere in the iOS client | Confirmed | ✅ Verified |

---

## Recommended server-side hardening (before public release)

These are not blocking for TestFlight but should be in place before the public App Store release:

- [x] **Price range CHECK constraint** on `e85_price_reports.price` — already live:
  ```sql
  -- actual live constraint (column is `price`, not `price_per_gallon`; bound is tighter
  -- than originally proposed here)
  CHECK (price >= 1.00 AND price <= 8.00)
  ```

- [ ] **Rate limiting by reporter** — add a Postgres function or Edge Function that rejects
  more than N price reports per `anonymous_reporter_id` per hour, to prevent flooding. **Not yet
  implemented** — explicitly out of scope for the 2.3.2 upsert-security fix; still open.

- [x] **Read policies** — confirmed: SELECT on both tables is intentionally public
  (`USING (true)` for `anon`/`authenticated` on both), matching the documented intent that
  community prices/stations are designed to be public.

- [ ] **Supabase dashboard audit** — open the Authentication → Policies panel for both
  tables and screenshot/export the policy list for the release record. Not performed from this
  environment; the live-query evidence above (and the migrations that produced the current state)
  serve the same purpose but are not a substitute for the developer's own dashboard screenshot for
  the release record.

---

## Sign-off

Before submitting to App Store Connect:

- [x] All table checks above are verified — directly against the live production database via
  SQL metadata queries, rolled-back `SET ROLE anon` behavioral tests, and real HTTP requests
  against the live REST API (GET/PATCH; no persistent write was made over HTTP — see the
  community-station-upsert-security fix's final report for why)
- [ ] Recommended hardening items are either complete or explicitly deferred with justification —
  price bound and read-policy intent are done; **rate limiting is still open and needs an
  explicit decision** (implement, or knowingly defer with a stated reason) before a large public
  (not just TestFlight) audience
- [ ] Dashboard policy screenshots archived in release notes or internal docs — still needs to be
  done by hand in the Supabase dashboard

**Verified by:** Claude (automated, live-database verification) — 2.3.2 Supabase release gate +
community-station-upsert-security fix
**Date:** 2026-09-03

## Xcode Cloud workflow updated to App Store Connect distribution — 2.1.1 (91)

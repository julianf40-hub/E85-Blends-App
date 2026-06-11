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
permissions by default. Access is granted only via explicit RLS policies.

The risk surface is therefore: **missing or over-broad RLS policies**, not key exposure.

---

## Table checklist

### `community_stations`

| Check | Expected | Verified? |
|---|---|---|
| RLS is **ENABLED** on this table | Yes | ☐ |
| Anon role has **INSERT** policy | Yes — for new station submissions | ☐ |
| INSERT policy restricts columns (no `id` override, no `created_at` spoofing) | Yes | ☐ |
| Anon role has **NO DELETE** policy | Confirmed absent | ☐ |
| Anon role has **NO unrestricted UPDATE** policy | Confirmed absent | ☐ |
| Service role is **not** used anywhere in the iOS client | Confirmed | ☐ |

### `e85_price_reports`

| Check | Expected | Verified? |
|---|---|---|
| RLS is **ENABLED** on this table | Yes | ☐ |
| Anon role has **INSERT** policy | Yes — for price reports | ☐ |
| INSERT policy validates `price_per_gallon` is within a sane range (e.g. `> 0 AND < 15`) | Recommended | ☐ |
| Anon role has **NO DELETE** policy | Confirmed absent | ☐ |
| Anon role has **NO UPDATE** policy | Confirmed absent | ☐ |
| Service role is **not** used anywhere in the iOS client | Confirmed | ☐ |

---

## Recommended server-side hardening (before public release)

These are not blocking for TestFlight but should be in place before the public App Store release:

- [ ] **Price range CHECK constraint** on `e85_price_reports.price_per_gallon`:
  ```sql
  ALTER TABLE e85_price_reports
    ADD CONSTRAINT price_per_gallon_range
    CHECK (price_per_gallon > 0 AND price_per_gallon < 15);
  ```

- [ ] **Rate limiting by reporter** — add a Postgres function or Edge Function that rejects
  more than N price reports per `anonymous_reporter_id` per hour, to prevent flooding.

- [ ] **Read policies** — confirm that SELECT on both tables is either restricted to
  authenticated users or intentionally public (community prices are designed to be public).

- [ ] **Supabase dashboard audit** — open the Authentication → Policies panel for both
  tables and screenshot/export the policy list for the release record.

---

## Sign-off

Before submitting to App Store Connect:

- [ ] All table checks above are verified in the Supabase dashboard
- [ ] Recommended hardening items are either complete or explicitly deferred with justification
- [ ] Dashboard policy screenshots archived in release notes or internal docs

**Verified by:** ___________________  **Date:** ___________________

# Remote Recommended Gear — 2.4.1 first implementation

Status: draft client implementation. Not deployed, not Xcode-verified, not release ready.

## Publication contract shared with Android

A public Supabase Storage bucket named `recommended-gear` serves `catalog-v1.json`.
The iOS client uses the existing Supabase project URL; no new API key is required.
The included JSON mirrors the bundled two-brand / nine-wheel catalog from main.
It is a seed, not authorization to publish eFlexFuel content before brand approval.

Schema version 1 uses camelCase JSON, stable string IDs, ordered arrays and UTC Unix
seconds for optional offer expiry. `brand` cards accept new products/brands, optional
priceText, heroImageURL and a dollar-off offer. `rvp_wheels` is reserved for the
existing RVP sponsor. Remote wheel images use imageURL; bundled assetName identifiers
are iOS fallbacks and Android must explicitly map them to its resources. More than or
fewer than nine wheels use the accessible grid instead of the ring.

Each publication replaces the whole catalog, including removals. Empty brands means
intentionally empty, not fallback. Invalid snapshots preserve the last valid one.
Before the first successful publication, the bundled catalog remains available.
Offers expire on the device clock, checked every second while the screen is open.
Offline clients cannot discover withdrawals until they reconnect; use expiry dates
for time-limited offers. The native screen refreshes on opening and foregrounding.

## Initial operator workflow (private dashboard still to build)

1. Configure the public bucket through Supabase Storage. Public download does NOT
   imply public upload: do not add INSERT/UPDATE/DELETE policies for anon or ordinary
   authenticated users. Only trusted dashboard administrators publish initially.
2. Upload artwork under immutable/versioned filenames. Validate and preview the JSON
   in a development build before publication. Change `revision` for every publish,
   including a rollback. Preserve the prior JSON privately for rollback.
3. Upload the approved catalog as `catalog-v1.json` with application/json content type
   and short Cache-Control (60 seconds). Verify CDN freshness and real device refresh;
   the client bypasses its own HTTP cache, not the CDN cache.
4. Confirm anonymous downloads work and anonymous/non-admin writes fail. Never put a
   service-role key in either mobile app or a browser dashboard.

The private editor, draft/preview/publish workflow, automatic history, remote logos,
remote More-screen placements/homepage link and Android client integration remain
follow-up work. This first slice changes Recommended Gear only. More currently retains
its bundled partner banners, so a whole-partner removal is NOT yet consistent across
both screens. Resolve this before claiming complete remote partner management.

## Required verification before merging

- Build and run the native unit suite, including GearCatalogTests and existing gear,
  carousel, copy, ring, image and accessibility tests using Xcode on a Mac.
- Compare light/dark/OLED, narrow widths, Dynamic Type and VoiceOver to main.
- Test add/edit/remove/reorder, zero/one/many brands, wheel counts other than nine,
  malformed JSON/unsupported version, timeout, cache persistence, image failure,
  expired offers, returning from background, and removal of the selected carousel page.
- Deploy only after reviewing bucket permissions; run live read/write-denial checks.
- Finish the publishing UI and cross-screen partner handling before release sign-off.

No production deployment, version bump, signing change or App Store submission is
part of this draft. Existing docs/PRE_RELEASE_SUPABASE_CHECKLIST.md still contains
separate release checks; this feature does not resolve or waive them.

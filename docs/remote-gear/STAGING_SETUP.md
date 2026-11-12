# Staging catalog setup — proposal for review (nothing here has been applied)

Goal: prove remote Recommended Gear updates on an iPhone using the **staging** catalog, with real
downloads. Production content is not touched. The v1 JSON contract is unchanged (Android-compatible).

## 0. Findings (read-only inspection)

| Item | Finding |
|---|---|
| Supabase project | `zefkbtscieokkdenvnkg` ("julianf40-hub's Project"), active; matches `SUPABASE_URL` in `Info.plist` |
| Storage buckets | only `performance-fuel-evidence` (private). **`recommended-gear` does not exist** |
| Storage objects / policies | none / none (`storage.objects` row-level security, no policies) |
| App catalog URL on `main` (`e97f467`) | **wrong**: `…/rest/v1/storage/v1/object/public/recommended-gear/…` → PostgREST **401**. No catalog could load. Fixed on local branch `fix/gear-catalog-storage-url` (`1345b74`, not pushed) |
| Corrected URLs | `…/storage/v1/object/public/recommended-gear/catalog-v1.json` and `…/staging/catalog-v1.json` → Storage `400 NoSuchBucket` today |
| Installed Build 290 | Default workflow, Release configuration (no `INTERNAL_BUILD`, so no catalog controls), bundle `com.e85blends.app.ios` |

## 1. Backend change (to apply after review)

One public bucket, no write policies. Public **reads** go through the `/object/public/` endpoint,
which needs no key and no SELECT policy. With no policies on `storage.objects`, `anon` and
`authenticated` users cannot list, upload, overwrite or delete. Only the service role (used on
the publishing Mac, never in an app) can write.

```sql
-- Proposed (NOT applied). Creates the bucket only; adds no policies.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('recommended-gear', 'recommended-gear', true, 5242880,
        array['application/json', 'image/png', 'image/jpeg', 'image/heic', 'image/heif']);
```

The 5 MB limit matches the app's image limit; the app separately limits the catalog JSON to
512,000 bytes.

Verify after applying (read-only):

```sql
select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'recommended-gear';
select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects';  -- expect none
```

Then from any machine (no key):

```sh
curl -sI https://zefkbtscieokkdenvnkg.supabase.co/storage/v1/object/public/recommended-gear/staging/catalog-v1.json
#   before the first upload: 400 "Object not found"
curl -s -X POST https://zefkbtscieokkdenvnkg.supabase.co/storage/v1/object/recommended-gear/staging/probe.json \
  -H 'Content-Type: application/json' --data '{}'
#   anonymous write: must be refused (400/401/403)
```

Rollback: delete the staging object(s) in the Supabase dashboard, then the bucket. The app treats
a missing object as "keep the last valid catalog", so a deleted staging object does not clear a
device (publish an empty catalog to clear it).

## 2. Publishing (validation before upload, predictable caching)

`tools/remote-gear/publish_catalog.py` is staging-only and a dry run unless `--upload`:

1. Reads the live staging object (public GET).
2. Stamps a never-used `revision` and `publishedAt = max(now, live + 1)` in whole seconds.
3. Validates the document and its succession over the live one with `validate_catalog.py`,
   the same rules the apps apply.
4. Uploads with `Content-Type: application/json` and **`Cache-Control: max-age=60`**, then reads
   the public URL back and requires identical bytes.

```sh
python3 tools/remote-gear/publish_catalog.py docs/remote-gear/staging/publication-a.json   # dry run
export SUPABASE_SERVICE_ROLE_KEY=...   # Supabase dashboard → Project Settings → API; this shell only
python3 tools/remote-gear/publish_catalog.py --upload docs/remote-gear/staging/publication-a.json
# later
python3 tools/remote-gear/publish_catalog.py --upload docs/remote-gear/staging/publication-b.json
```

Caching:
- The object's `max-age=60` bounds CDN staleness. The app refreshes on opening the screen and
  on returning to the foreground, at most once every 60 s.
- So expect a new publication on the phone within about **2 minutes** (CDN up to 60 s, plus the
  app's 60 s throttle).
- If Supabase Smart CDN applies to this plan, overwrites are invalidated sooner. Don't rely on
  it until it has been observed.

## 3. Test publications (fictional content only)

| | `publication-a.json` | `publication-b.json` |
|---|---|---|
| Example Fuel Tools | "From $49", `https://example.com/fuel-tools`, More card "Staging test card A" | **"From $39"**, **`https://example.com/fuel-tools-v2`**, More card "Staging test card B (edited)" |
| Example Sensor Kit | "From $129", `https://example.com/sensor-kit`, More card | **removed** |

Both are neutral `brand` cards with no images. There are no RVP or eFlexFuel entries, so staging
shows no real partners at all. Ordering is stamped at upload. For an empty-catalog test,
publish a document with `"brands": []`.

## 4. Getting a build with the staging controls

The controls exist only in the **Internal** configuration (`INTERNAL_BUILD`). Only the
`EightyFiveBlends Internal` scheme archives with it:
- bundle `com.e85blends.app.ios.internal` (widget `com.e85blends.app.ios.internal.NearbyE85Widget`);
- separate entitlements (`iCloud.com.e85blends.app.ios.internal`, `group.com.e85blends.app.ios.internal`);
- iOS **26.4** minimum;
- display name "85Blends". It installs beside the normal app as a separate app.

Build 290's TestFlight **Internal Testing** group belongs to the normal app, and its archive used
Release. TestFlight "Internal Testing" is a distribution group, not a build configuration.

Required Xcode Cloud setup (for you to make; I don't edit workflows):
1. An App Store Connect app record for `com.e85blends.app.ios.internal` ("85Blends Internal").
2. An Xcode Cloud workflow **attached to that app**:
   - **Archive** action with scheme **`EightyFiveBlends Internal`** (configuration Internal, pinned by the scheme);
   - **Deployment preparation**: TestFlight (Internal Testing Only);
   - **Post-action**: TestFlight Internal Testing → your tester group;
   - **Start condition**: manual (or the `fix/*`, `feature/*` rules).
3. Run it on the branch carrying the URL fix (once merged, on `main`).

All Xcode Cloud runs so far report to app record `6762037468`, the app Build 290 was delivered
to. An Xcode Cloud product distributes to its own app record. So the existing
"85Blends Internal" workflow can run tests, but may be unable to deliver an Internal-bundle
archive. Screenshots will settle this (§6).

## 5. iPhone test (real downloads; needs §1, the URL fix, and an Internal build)

1. Open the Internal app → Preferences → **Recommended Gear Catalog** → **Staging**.
   - Expect the red banner, "Not found" or "HTTP 400" (nothing published yet), and empty Recommended Gear and More.
2. **Initial fetch:** upload publication A, then wait about 2 minutes. Tap **Refresh Now**, or background and reopen.
   - Expect *Example Fuel Tools* ("From $49") and *Example Sensor Kit* ("From $129") on Recommended Gear.
   - Both More cards appear.
   - The card shows A's revision.
   - The CTA opens `example.com/fuel-tools`.
3. **Update and removal:** upload publication B and wait about 2 minutes.
   - Expect "From $39" and a link to `example.com/fuel-tools-v2`.
   - *Example Sensor Kit* is gone from **both** screens.
   - If you were viewing the Sensor Kit card, the carousel moves to the remaining card.
4. **Offline cache:** turn on airplane mode, force-quit and relaunch.
   - B's content is still shown.
   - Refresh Now reports "Failed (offline or timed out)".
5. **Return to Production:** tap the button.
   - The bundled eFlexFuel and RVP cards return immediately and the banner disappears.
   - The production fetch reports "Not found" or "HTTP 400" until a production catalog exists. That's expected; bundled content is shown.
6. Relaunch: Production stays selected. Switching back to Staging shows B's content immediately (its own cache).

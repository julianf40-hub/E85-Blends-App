# Staging catalog setup and phone test

Status: the bucket (§1) and the Storage URL fix (PR #147) are applied. The bucket is empty: no
catalog has been published. Testing uses the normal 85Blends app through TestFlight (§4).

Goal: prove remote Recommended Gear updates on an iPhone using the **staging** catalog, with real
downloads. Production content is not touched. The v1 JSON contract is unchanged (Android-compatible).

## 0. Findings before setup (read-only inspection, kept for the record)

| Item | Finding |
|---|---|
| Supabase project | `zefkbtscieokkdenvnkg` ("julianf40-hub's Project"), active; matches `SUPABASE_URL` in `Info.plist` |
| Storage buckets | only `performance-fuel-evidence` (private). **`recommended-gear` does not exist** |
| Storage objects / policies | none / none (`storage.objects` row-level security, no policies) |
| App catalog URL on `main` (`e97f467`) | **wrong**: `…/rest/v1/storage/v1/object/public/recommended-gear/…` → PostgREST **401**. No catalog could load. Fixed on local branch `fix/gear-catalog-storage-url` (`1345b74`, not pushed) |
| Corrected URLs | `…/storage/v1/object/public/recommended-gear/catalog-v1.json` and `…/staging/catalog-v1.json` → Storage `400 NoSuchBucket` today |
| Installed Build 290 | Default workflow, Release configuration (no `INTERNAL_BUILD`, so no catalog controls), bundle `com.e85blends.app.ios` |

## 1. Backend change (applied: bucket created, no policies)

One public bucket, no write policies. Public **reads** go through the `/object/public/` endpoint,
which needs no key and no SELECT policy. With no policies on `storage.objects`, `anon` and
`authenticated` users cannot list, upload, overwrite or delete. Only a **service-role key** can write.

That key is a privileged secret. It bypasses every Storage and database access rule, and it
works from **any** machine that has it; it is not tied to a Mac. Limit who holds it. Use it only
from a shell environment variable, never in an app, repository file, browser or chat. Rotate it
in the Supabase dashboard if it is ever exposed. Rotating it also affects any existing server-side
use of the same key.

```sql
-- Applied. Creates the bucket only; adds no policies.
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

1. Reads the live staging object. A dry run uses the public URL with no key. An upload uses the
   authenticated **origin** endpoint, so a stale CDN copy cannot lead it to stamp a publication
   that isn't newer than the real live one.
2. Stamps a never-used `revision` and `publishedAt = max(now, live + 1)` in whole seconds. It
   refuses if the live `publishedAt` is more than 5 minutes in the future, which means a
   publisher's clock is wrong.
3. Validates the document and its succession over the live one with `validate_catalog.py`,
   the same rules the apps apply.
4. Uploads with `Content-Type: application/json` and **`Cache-Control: max-age=60`**, then
   reports the upload and the read-back checks separately:

| Result | Exit | Meaning |
|---|---|---|
| `NOT PUBLISHED` | 1 | Validation or the upload request was refused; nothing changed |
| `PUBLISHED and verified` | 0 | The origin and the public URL serve the new document |
| `PUBLISHED (origin verified)…` | 3 | Stored correctly; the CDN still serves the old copy (up to 60 s) |
| `CONFLICT` | 4 | Uploaded, but the origin now holds a *different* document: someone else published |
| `UPLOADED, but the origin read-back failed` | 5 | Stored, but unconfirmed; check the dashboard |
| `UNKNOWN` | 6 | The request didn't complete; it may or may not be stored |
| `UPLOADED, but the origin still serves the previous publication` | 7 | Upload accepted, but after retrying the origin still shows the old document; read it back before publishing again |

Right after an overwrite, Storage can briefly serve the previous object, so the tool retries the
origin read-back (reads only; never the upload) for at most 30 s including request timeouts.
Our exact bytes mean success. Still failing, or the object missing, is exit 5, and the message
says which. Any *other* document (neither ours nor the one live before the upload) is
`CONFLICT`: content we didn't write is live, and the tool can't tell who wrote it.

**Concurrency is not protected.** Supabase Storage has no conditional (compare-and-swap) write,
so the tool can't prevent two people overwriting each other. Its origin read-back (exit 4) catches
**only some** conflicts: another upload that lands before the read-back. It misses an overwrite
that lands afterwards. It also misses two publishers who read the same live document and stamp
the same second: the later write wins silently, and devices that already accepted the first
reject it as a conflict. **Staging requires one publisher at a time.** The future dashboard
serializes publications with a database lock (`PUBLISHING_DASHBOARD.md`).

```sh
python3 tools/remote-gear/publish_catalog.py docs/remote-gear/staging/publication-a.json   # dry run
read -rs SUPABASE_SERVICE_ROLE_KEY && export SUPABASE_SERVICE_ROLE_KEY   # paste; not echoed or kept in shell history
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

Use the normal app (`com.e85blends.app.ios`) through TestFlight. The separate "85Blends Internal"
app is retired; nothing in this test needs it.

- Builds reach TestFlight through the Xcode Cloud **Default** workflow, which archives the
  `EightyFiveBlends` scheme (Release). Build 293 was archived and delivered this way from `main`
  commit `0955482`, including the Storage URL fix.
- The "85Blends Internal" workflow is manual-start and test-only, with no Archive action and no
  post-actions. It delivers nothing.
- TestFlight builds are Release builds (no `DEBUG`, no `INTERNAL_BUILD`). The catalog controls
  appear because the app verifies, at runtime, that StoreKit signed its install in the sandbox
  environment, which Apple documents for every TestFlight download (README §4a). App Store
  installs never show them and always use production.
- The controls ship in the first TestFlight build made after this change reaches `main`. Earlier
  builds, including 293, don't have them.

## 5. iPhone test (real downloads; needs a TestFlight build with the controls, §4)

1. Install the TestFlight build and open it once while online (StoreKit confirms the TestFlight
   environment, normally within seconds). Preferences → **Recommended Gear Catalog** shows
   **Production** selected. Choose **Staging**.
   - Expect the red banner, "HTTP 400" (nothing published yet), and empty Recommended Gear and More.
   - If the card is missing, background and reopen the app while online; it appears once the
     environment is confirmed.
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

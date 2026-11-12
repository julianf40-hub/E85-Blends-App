# Remote Recommended Gear — 2.4.1

Status: **iOS client complete, not yet built or tested in Xcode. Not deployed. Not release ready.**

One published JSON document drives Recommended Gear **and** the More screen's partner
placements. That lets us add, remove, reorder, hide and edit brands, wheels, links, prices,
product images, logos and offers without shipping a new app version. Layout, colors, bundled
artwork and accessibility stay native on each platform.

| File | Purpose |
|---|---|
| `catalog-v1.json` | Seed. Exactly what the app bundles today (two brands, nine wheels). Publishing it changes nothing visible. |
| `catalog-v1.schema.json` | Structural JSON Schema for the dashboard form and Android models. |
| `../../tools/remote-gear/validate_catalog.py` | Reference validator that mirrors the client rules. It must pass before any publication. |
| `PUBLISHING_DASHBOARD.md` | Proposed private editor: authentication, admin authorization, publish and rollback. |
| `EightyFiveBlends/GearCatalog.swift` | iOS decoding, validation, store, offer timing and refresh. |
| `EightyFiveBlends/GearRemoteImage.swift` | iOS remote image loading and caching. |

The seed's eFlexFuel entry mirrors what main already ships. It is **not** authorization to publish
new eFlexFuel content while eFlexFuel's approval is pending.

## 1. Delivery

- Public Supabase Storage bucket `recommended-gear`, object `catalog-v1.json`.
- Clients GET `<SUPABASE_URL>/storage/v1/object/public/recommended-gear/catalog-v1.json`
  with **no** API key or Authorization header. iOS reuses the existing `SUPABASE_URL`, so no new
  key or Info.plist change is needed.
- Each publication replaces the whole document. There are no partial patches.
- A future incompatible format is published at `catalog-v2.json` **alongside** v1. Older apps keep
  reading v1, so v1 must stay published (and keep being updated, including withdrawals) until no
  supported app version reads it.

## 2. Contract (schema version 1)

camelCase keys. Timestamps are UTC Unix seconds. IDs match `^[a-z0-9-]{1,64}$` and are stable
forever: they key bundled artwork, analytics and the selected card. Array order is display order.

```text
{ schemaVersion: 1, revision: string, publishedAt: number, brands: [Brand] }

Brand (all kinds)
  id, kind, name, tagline, description, ctaTitle, destinationURL (https)
  accessibilityDescription?   VoiceOver/TalkBack text (defaults to description)
  hidden?                     true = withdrawn from EVERY screen
  more?: { subtitle? }        present = also placed on More (default subtitle: tagline)

kind "brand"        neutral Featured Brand card (never a sponsor)
  logo?: { url, darkURL? }    transparent wordmark; darkURL used in dark and OLED
  heroImageURL?               product photo (no photo = no artwork panel)
  priceText?                  short free text, e.g. "From $499"
  offer?: { amountOff (whole USD 1-10000), eligibleProducts, code (no spaces), terms,
            disclosure, startsAt?, expiresAt? }

kind "rvp_wheels"   RVP Supply sponsor card. id must be "rvp-supply-oem-beadlocks"; at most one.
  homepageURL, configuratorURL (https, required)   More banner / ring centre action
  footnote?                    claim pill under the wheels
  wheels?: [{ id, displayName, accessibilityName, productURL, imageURL?, hidden? }]
  (no offer, priceText, logo or heroImageURL: the sponsor card carries no price or discount)
```

Text limits (characters): name 60, tagline 120, description 500, ctaTitle 60,
accessibility text 500, priceText 60, more.subtitle 120, footnote 160, offer code 40, other
offer text 300, revision 200. Document ≤ 512,000 bytes, ≤ 30 brands, ≤ 24 wheels.

### Acceptance rules (both clients, and the validator)

A document is accepted only if **all** of these hold. Otherwise the client keeps what it has.

1. `schemaVersion == 1`. Any other version is reported as unsupported.
2. It is well-formed, within the size, count and text limits, and every URL is https with a host
   and no credentials.
3. Brand and wheel IDs are valid and unique, and there is at most one `rvp_wheels`.
4. A `brand` doesn't use the RVP id or sponsor-only fields, and its copy (name, tagline,
   description, CTA, accessibility text, More subtitle) doesn't contain "sponsor", "partner",
   "affiliate" or "endorse".
5. `rvp_wheels` carries no brand-only fields. Each wheel has `imageURL` **or** a bundled wheel ID.
6. An offer has `startsAt < expiresAt` when both are set.
7. It is correctly ordered relative to the last publication the device accepted (see below).

### Publication ordering

Each device remembers the last accepted publication's `publishedAt`, a digest of its exact
bytes, and the last 100 accepted revisions. It keeps these separately from the cached document,
so they survive an unreadable cache.

| Downloaded document | Result |
|---|---|
| Byte-identical to the last accepted publication | Accepted as **unchanged** (a retry or re-upload). Also restores an unreadable saved copy. |
| Different bytes, `publishedAt` **strictly newer**, revision never used | Accepted. |
| Different bytes, `publishedAt` **older** | Rejected (`stale`). |
| Different bytes, `publishedAt` **equal** | Rejected (`conflict`). Equal timestamps are never a legitimate update. |
| Different bytes, revision already accepted | Rejected (`revisionReused`). |

A rejected document changes nothing on the device: not the saved content, the ordering state
or the stored ETag. So a stale CDN edge or cached copy can never bring back an item that a newer
publication withdrew, including after an offline restart. **A rollback is a new publication**
of the old content, with a new `revision` and a `publishedAt` newer than the live one.
`validate_catalog.py --previous …` applies exactly these rules before publishing. The
publisher's guarantee of strictly increasing timestamps is described in `PUBLISHING_DASHBOARD.md`.

Unknown keys are ignored. That allows optional fields to be added within v1. **Unknown `kind`
values are skipped, not rejected**: a new layout added later is invisible to older apps, but the
rest of the document (including withdrawals) still applies to them.

### Display semantics

- **Featured Brand vs Sponsor.** A `brand` always renders as the neutral "Featured Brand" card,
  and on More as a compact Featured Brand card. Only `rvp_wheels` renders as "Sponsor". The More
  banner's "Sponsored by {name}" disclosure is fixed app copy; only its subtitle and link are
  editable.
- **RVP Supply destinations stay separate.** `homepageURL` is the More banner,
  `destinationURL` is "View All RVP Wheels" (collection), `configuratorURL` is the ring centre /
  "Custom Wheels", and each wheel opens its own `productURL`.
- **Wheel layout.** Exactly nine visible wheels use the ring at standard text sizes on a wide
  enough card. Any other count, accessibility text sizes and narrow cards use the labeled grid,
  with the configurator first. Edit the sponsor `description` ("Nine OEM-style…") when the count
  changes.
- **Offers** are shown only while `startsAt ≤ now < expiresAt` on the device clock, offline
  included. Expiry removes the offer, not the brand.
- **Removal.** Omitting an entry or setting `hidden: true` removes it from Recommended Gear **and**
  More at the same time. If the card a user is viewing disappears, the carousel moves to the first
  card. An empty `brands` array is a valid, authoritative "show nothing".
- **Branding isolation.** Bundled artwork is chosen from stable IDs, never from asset names in
  the JSON. eFlexFuel's wordmark, hero photo and orange offer styling apply only to id
  `eflexfuel`; RVP Supply's logo plate applies only to the sponsor card. Every other brand gets
  neutral theme styling, its own remote logo or a typographic name, and no artwork panel unless it
  supplies `heroImageURL`.

### Download and memory limits (iOS)

Byte limits are enforced **while the body is received**: 512,000 bytes for the catalog and
5,000,000 per image. `Content-Length` is used only to refuse an obviously oversized response
early. A missing or misleading header can't get past the running count, and the transfer is
cancelled the moment the limit is exceeded. Responses served from the image disk cache go through
the same path and limits, and only complete, in-limit 2xx bodies are stored.

Images: the header's pixel size is checked before any pixels are decoded (each side ≤ 8,192 px
and ≤ 40 MP in total). ImageIO then decodes straight to a thumbnail of at most 1,600 px on the
longest side, off the main thread, so a full-resolution bitmap is never created. The in-memory
cache is bounded by decoded bytes (32 MB, 120 entries, least-recently-used) and is emptied on a
memory warning. At most three image transfers/decodes run at once, and concurrent requests for
the same URL share one transfer. Bundled artwork never goes through this path.

### Images

- **Use versioned, immutable URLs** (e.g. `gear/eflexfuel/hero-2026-11-12.png`). To change a
  picture, upload a new file and publish its new URL. Never overwrite an object in place: clients
  treat image URLs as immutable and serve any stored copy, offline included.
- PNG/JPEG/HEIF ≤ 5 MB (aim for ≤ 400 KB), each side ≤ 8,192 px and ≤ 40 MP in total (about
  2,000 px on the longest side is plenty). Wheels square; logos transparent, about 4:1, legible
  on white (light) and near-black (dark/OLED). Supply `darkURL` when the light logo is dark.
- While an image loads, or if it fails or times out (15 s), the client shows bundled artwork,
  the typographic brand name, or a neutral placeholder. It never shows another brand's artwork.

### Bundled artwork mapping (Android must mirror this by ID)

| Stable ID | iOS asset | Android resource (to create) |
|---|---|---|
| brand `eflexfuel` wordmark | `EFlexFuelWordmark` (light/dark variants) | `eflexfuel_wordmark` (+ `-night`) |
| brand `eflexfuel` hero | `EFlexFuelAutoKitHero` | `eflexfuel_autokit_hero` |
| `rvp-supply-oem-beadlocks` logo | `RVPSupplyLogo` (on dark plate) | `rvp_supply_logo` |
| wheel `oem-hellcat` | `RVPWheelOEMHellcat` | `rvp_wheel_oem_hellcat` |
| wheel `oem-hellcat-v2` | `RVPWheelOEMHellcatV2` | `rvp_wheel_oem_hellcat_v2` |
| wheel `oem-hellcat-redeye` | `RVPWheelOEMHellcatRedeye` | `rvp_wheel_oem_hellcat_redeye` |
| wheel `5-spoke-hellcat` | `RVPWheel5SpokeHellcat` | `rvp_wheel_5_spoke_hellcat` |
| wheel `5-spoke-hellcat-v2` | `RVPWheel5SpokeHellcatV2` | `rvp_wheel_5_spoke_hellcat_v2` |
| wheel `oem-demon` | `RVPWheelOEMDemon` | `rvp_wheel_oem_demon` |
| wheel `hollow-5-spoke` | `RVPWheelHollow5Spoke` | `rvp_wheel_hollow_5_spoke` |
| wheel `chrome-oem-hellcat` | `RVPWheelChromeOEMHellcat` | `rvp_wheel_chrome_oem_hellcat` |
| wheel `oem-widebody` | `RVPWheelOEMWidebody` | `rvp_wheel_oem_widebody` |

Android names are proposals (Android resource names can't contain hyphens or start with a digit).
Adding a bundled ID requires an app release on **both** platforms; until then, use `imageURL`.

### Android compatibility requirements (no Android changes made in this assignment)

An Android client must implement the same acceptance rules, persistence states, ordering check,
unknown-kind skipping, offer window and branding isolation as iOS. It must use the same
endpoint without credentials, and render with Android-native components (Compose), not a web
view. `validate_catalog.py` and its tests are the executable spec. Port its cases to the Android
test suite.

## 3. Client lifecycle and resilience (iOS)

| State | Shown |
|---|---|
| Never received a valid publication | Bundled content (the current two brands, nine wheels) |
| Received one | The last valid publication, persisted across launches, offline included |
| Saved publication unreadable (corrupt, or stricter rules after an app update) | **Nothing** until the next valid download. Never bundled content, which might include withdrawn items |

- **Refresh:** when Recommended Gear or More appears, and on every return to the foreground.
  Throttled to once per 60 s. 15 s request timeout, ephemeral session (no cookies, cache or
  credentials), conditional `If-None-Match` with the stored ETag.
- **Failures keep the last valid content:** offline, timeout, any non-200 including 404, invalid
  JSON, unsupported version, failed validation, an older `publishedAt`, an equal one with different bytes, a reused revision, or a body over the byte limit. A deleted object never
  clears the catalog. **Publish an empty catalog to withdraw everything.**
- **Offer timing:** a single timer wakes at the next offer start/expiry (no per-second polling),
  and content is re-resolved on foregrounding and on system clock changes.
- **Carousel:** a new publication resets the carousel's measurements, clears stale link errors and
  moves the selection off a removed card. Reordering keeps the selected card when it still exists.

### Known limitation: offline withdrawals

**A device that is offline cannot learn about a withdrawal until it reconnects and refreshes.**
Until then it keeps showing the last publication it received (only expired offers disappear on
their own). A device that has never been online since installing 2.4.1 shows the bundled catalog.
Mitigations: put `expiresAt` on every time-limited offer, and keep withdrawals in the published
document rather than relying on deleting objects. Nothing in the client can remove content it has
not been told about.

### CDN caching

- Upload `catalog-v1.json` with `Content-Type: application/json` and
  `Cache-Control: max-age=60` (Supabase's upload default is 3600 s; set it explicitly). The
  client bypasses its own HTTP cache but not the CDN, so worst-case propagation is about the CDN
  TTL plus the 60 s client throttle. **Verify on the live project** whether Supabase Smart CDN
  invalidation applies to this plan before relying on faster updates.
- Never re-use an image file name (see Images). Catalog edits are visible only after the CDN TTL;
  the `publishedAt` check keeps a lagging edge from rolling a device back.

### Security

- The app contains no service-role key, admin credential or write path. Catalog reads send no
  key at all.
- Public read **does not** imply public write. The bucket must have **no** INSERT/UPDATE/DELETE
  policies for `anon` or ordinary `authenticated` users. Only the publishing backend writes (see
  `PUBLISHING_DASHBOARD.md`).
- Destinations are https-only and pass `FeaturedBrandLink` again before `openURL`. The app's
  own `e85blends://` scheme, `http`, `javascript:`, `mailto:` and credentials-in-URL are rejected.
- Add a row for the `recommended-gear` bucket's policies to
  `docs/PRE_RELEASE_SUPABASE_CHECKLIST.md` once it exists. That checklist's existing items are
  unaffected by this feature and still apply.

## 4. Operator workflow until the dashboard exists

1. Edit a copy of the live document. Set a new, never-used `revision` and a `publishedAt`
   strictly greater than the live one (current UTC seconds, or live + 1 if that isn't greater).
   Use new file names for any new images.
2. `python3 tools/remote-gear/validate_catalog.py --previous live.json [--previous older.json …] candidate.json`
   must print `OK`. Review any wording warnings.
3. Preview it on an Internal build with the staging source (section 4a) before publishing.
4. Upload with the headers above via the Supabase dashboard (admin login, not the app). Keep the
   previous document privately for rollback.
5. **Rollback** = publish the previous content again with a **new** `revision` and a `publishedAt`
   newer than the live one. Re-uploading an old file unchanged is rejected by devices that
   already hold a newer publication.

## 4a. Internal staging preview (DEBUG and Internal builds only)

Preferences → **Recommended Gear Catalog** (beside the RevenueCat diagnostics card) chooses
**Production** (default) or **Staging**. The control, the staging source, its object path and the
fixture actions are compiled out of App Store (Release) builds (`#if DEBUG || INTERNAL_BUILD`).

- Staging reads `recommended-gear/staging/catalog-v1.json` from the same public bucket, with the
  same v1 contract, the same validation and no credentials. **This object does not exist yet.**
  Until it is created, staging shows nothing and reports "Not found (HTTP 404)".
- Each source has its **own** saved document, ETag, ordering state and revision history. A staging
  publication with a later `publishedAt` never affects what production accepts.
- Staging never shows bundled or production partners: with nothing received it shows the empty
  state. While staging is selected, Recommended Gear and More show a red
  "STAGING CATALOG · Internal preview" banner, and the card is outlined in red with
  **Return to Production**.
- Switching shows that source's saved content immediately (carousel reset) and refreshes it. A
  response still in flight for the previous source is discarded when it arrives.
- **Fixtures without a bucket:** with Staging selected, **Load Fixture from Clipboard** applies a
  document from the clipboard to staging only, through the normal validation and ordering.
  **Reset Staging Data** clears staging so a sequence can be replayed. Generate the sequence with
  `python3 tools/remote-gear/make_fixtures.py <dir>`. It uses a fictional "Example Fuel Tools"
  brand and doesn't change any real partner copy.

## 5. Verification still required on a Mac (NOT RUN in the cloud session)

The cloud sessions that produced this had no Mac, Xcode, simulator or App Store Connect access.
Their Swift results come from a Linux toolchain (logic tests only). **None of the following has
been run.**

### 5.1 Build and tests

```sh
git fetch origin && git checkout feature/2.4.1-remote-gear && git pull --ff-only
# Simulator smoke builds of both schemes (CLAUDE.md: always allowed; never archive Release)
xcodebuild -project EightyFiveBlends.xcodeproj -scheme EightyFiveBlends \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build | tail -40
xcodebuild -project EightyFiveBlends.xcodeproj -scheme "EightyFiveBlends Internal" \
  -destination 'generic/platform=iOS Simulator' build | tail -40
# Prove the staging preview is compiled out of Release (expect no matches)
xcodebuild -project EightyFiveBlends.xcodeproj -scheme EightyFiveBlends \
  -destination 'generic/platform=iOS Simulator' -configuration Release \
  -derivedDataPath /tmp/gear-release build | tail -5
strings /tmp/gear-release/Build/Products/Release-iphonesimulator/EightyFiveBlends.app/EightyFiveBlends \
  | grep -E 'recommendedGear\.staging|staging/catalog-v1|Load Fixture from Clipboard' || echo "compiled out"
xcrun simctl list devices available | grep iPhone
# Full suite. Gear suites: GearCatalogTests, GearCatalogSourceTests, GearDownloadTests (including the
# Darwin-only cachedResponsesPassTheSameLimit), GearImageLimitsTests, GearImageDecoderTests,
# FeaturedGearTests, FeaturedCarouselMetricsTests, FeaturedOfferCopyTests, EFlexFuelAssetTests,
# EFlexFuelHeroAssetTests, RVPSupplyLogoAssetTests, RVPSupplyLogoLayoutTests.
xcodebuild -project EightyFiveBlends.xcodeproj -scheme EightyFiveBlends \
  -destination 'platform=iOS Simulator,name=<installed iPhone>' test | tail -60
xcodebuild -project EightyFiveBlends.xcodeproj -scheme "EightyFiveBlends Internal" \
  -destination 'platform=iOS Simulator,name=<installed iPhone>' test | tail -60
python3 -m unittest discover -s tools/remote-gear -v
```

### 5.2 Simulator scenarios with fixtures (Internal or Debug build)

```sh
python3 tools/remote-gear/make_fixtures.py /tmp/gear-fixtures   # just before testing (offer times)
xcrun simctl pbcopy booted < /tmp/gear-fixtures/01-seed-parity.json   # then tap Load Fixture
```

Preferences → Recommended Gear Catalog → **Staging**: check the red banner on Recommended Gear and
More, and that both are empty before any fixture. Then load each file in order, checking both
screens after each one:

| Fixture | Expect |
|---|---|
| 01 seed parity | Identical to production/bundled |
| 02 add example brand | New first card: typographic name, neutral placeholder art (broken URLs), "From $49", neutral (not orange) styling; new More card |
| 03 reorder | RVP, eFlexFuel, Example; the card you were viewing stays selected |
| 04 edit + offer | Edited copy/price; neutral offer appears ~2 min after generation, disappears at ~5 min, also when relaunched in airplane mode |
| 05 hide example | Gone from Recommended Gear **and** More |
| 06 eight wheels | Ring replaced by the labeled grid |
| 07 remove eFlexFuel | Open eFlexFuel from More first; after loading, the carousel moves to RVP and the More card disappears |
| 08 empty | Empty state card; no partner cards on More; stays empty after an airplane-mode relaunch |
| 09 rollback | Back to parity |

Also: load 03 again after 09 (rejected as stale, nothing changes). **Return to Production**
(production content back immediately, banner gone). Relaunch (the selection persists).

### 5.3 Visual and accessibility (production/bundled and fixture 02)

Light, dark and OLED; iPhone SE (3rd gen) and Pro Max; Dynamic Type default, xxxLarge and AX5;
VoiceOver order on both cards and the More cards; More → eFlexFuel opens on the eFlexFuel page.
Compare with main, and screenshot each combination.

### 5.4 Once a staging object or the live bucket exists

Anonymous GET works; anonymous and ordinary-user INSERT/UPDATE/DELETE fail; response headers
include the expected Cache-Control and ETag. Then check an oversized (> 5 MB) image, a very large-
dimension image, a remote logo with and without `darkURL`, and images loading again in airplane
mode after a first online view.

No production deployment, Storage bucket, version or build number change, signing or entitlement
change, or App Store submission is part of this work.

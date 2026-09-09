# Nearby E85 widget — 2.4.0

## Scope and baseline

Work is confined to `/Users/julianfigueroa/Desktop/EightyFiveBlends-Latest`, on `codex/2.4.0-nearby-e85-widget`, branched from clean `codex/local-2.3.2` at `20b8d89e61222c314d2a6b0a085dc016837da9c2`. At audit time the baseline also matched the local `origin/main` reference and `v2.3.2` tag. No remote update is needed to branch from the explicitly requested baseline. The original older checkout is not modified. No push, merge, archive, or upload is part of this work.

This document originally described the first slice (Small/Medium information cards only, no map, no zoom, no manual refresh). It now covers the full 2.4.0 feature as implemented across ten commits: the initial widget, the MapKit redesign, the Small/Medium/Large split with per-size tap behavior, the marker-alignment fix, Large's zoom controls, the hybrid location-refresh policy with manual refresh, the refresh-control feedback/inset polish, and the zoom-boundary tap-through fix. See "Merge audit — 2.4.0" below for the exact commit list and current validation status. The branch also carries one unrelated feature (App Store review requests, `ReviewRequestEligibility`/`ReviewRequestManager`) added separately on the same branch — not part of this widget and not described further here.

This is a **last-app-location widget**, not autonomous background navigation. It updates when the app completes its existing current-location station search, when available app price previews refresh, when the significant-location-change/hybrid refresh policy below decides a reposition is worth publishing, or when the user taps the widget's own manual refresh button. Opening the app normally selects Stations and runs its existing automatic search. Tapping a station opens directions (Small, Large rows) or the Stations tab (Medium, Large map/fallback); a missing/expired station link falls back to the Stations tab. There is no Pro gating.

## Architecture audit

- `StationLocationManager` is the existing single Core Location owner, including one-shot foreground requests, authorization, fix timestamps/accuracy, and separate Automatic Pump Detection region monitoring. No second location requester, background mode, or Always-permission requirement is introduced.
- `NLRStationService` fetches public operating E85 stations in a requested radius. `LiveFuelStation` includes coordinates and distance but **no E85 price**; its random UUID is unsuitable as a persisted link identity.
- `FuelStation` is the user's SwiftData/CloudKit saved station model; local E85 price and its date are separate from community reports. The widget does not open or migrate SwiftData.
- `RecentLiveStationCache` is the ephemeral Pump Mode cache. `StationsRecentSearchStore` separately retains current-location results and an atomic, rounded-coordinate cross-launch preview. Neither is repurposed as a cross-process database.
- `StationsView` already owns station matching, coordinate distance recomputation, canonical community keys, and community price previews. The publisher consumes these exact paths. Typed-location searches and restored provisional previews are excluded.
- Existing station cards prioritize a saved price over a community price. The widget retains that order, validates with `StationDataValidation`, preserves source and report date, and applies the existing 7/14-day freshness tiers. Unknown/invalid prices are not shown as zero; missing or invalid report dates are explicitly unknown.
- Before this branch there was no WidgetKit extension, App Group entitlement, or inbound URL routing. Test sources existed but neither shared scheme had a testable target.

## Shared boundary and freshness

`SharedNearbyE85/NearbyE85Snapshot.swift` is compiled into both app and extension. It contains only Codable/Sendable value types, cache I/O, validation, and strict deep-link encoding/decoding. Existing `StationDataValidation` is also compiled into the extension; no business service, networking key, subscription SDK, advertising SDK, or CloudKit dependency is added to it.

The app is the sole cache writer. It exports up to three valid unique stations, sorted by approximate straight-line distance, within the successful search's radius. Small displays the nearest station; medium displays the nearest two with individual links. The envelope includes station identity/name/address/coordinates/distance, optional E85 price/source/report date, successful search timestamp, original location-fix timestamp, radius, state, and schema version. It does not store the user's coordinates, reporter identity, vehicle data, or account information.

One bounded JSON file is atomically replaced in the App Group, excluded from backups, and protected until first unlock. A changed successful write requests a reload of only the Nearby E85 widget. An unavailable App Group never falls back to a private container and never crashes the app. Missing, corrupt, unsupported-version, inconsistent, oversized, or expired snapshots produce the setup/refresh state. Reading/enriching a snapshot does not advance its location/search timestamps. Network failures retain the previous useful snapshot.

The widget labels the location as last known from the app, marks it older after one hour, and discards location-based results after 24 hours. Timeline entries precompute stale and expiry transitions and price-day rollover; the extension requests an opportunistic 30-minute reload. WidgetKit controls actual reload timing. Permission revocation clears location-based contents when observed by the app, and the extension checks app location authorization again before returning cached data. The extension does not request locations, so it does not declare `NSWidgetWantsLocation` or rely on `authorizedForWidgetUpdates`. Adding autonomous widget location later requires that separate permission/lifecycle design and real-device testing.

Relevant Apple guidance: [Widget updates and budgeting](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/), [widget location lifecycle](https://developer.apple.com/documentation/widgetkit/accessing-location-information-in-widgets), [sharing extension data](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html).

## Small / Medium / Large behavior (final)

All three sizes share one `NearbyE85WidgetView`/`NearbyE85Entry` and one manual refresh action; only layout and tap regions differ per family.

- **Small** — information-first card: station name, approximate distance, E85 price and its age (when reported), and a stale/older-location indicator. No map. The entire widget body is one tap target that opens directions to the nearest station via the user's preferred maps app. A standalone refresh button sits in the top-trailing corner, inset from the edge, as an independent tap region — it never falls through to the directions action.
- **Medium** — map-only, full-bleed `MKMapSnapshotter` render with the user's location marker and nearby E85 station markers (nearest station gets a price badge). Degrades to the same information card as Small if no map render is available yet (e.g. first run, no user coordinate). Tapping the map body opens the Stations tab, never directions. The refresh button sits top-trailing over the map, inset from the edge.
- **Large** — map on top (partial height) with a readable station list below. Tapping the map opens Stations; tapping a specific row opens directions to that exact station (each row captures its own station ID, never the nearest one). A `+`/`−`/refresh control stack floats on the map's trailing edge, inset from the corner. Zoom level is persisted (`NearbyE85MapZoomStore`, App Group–backed) and independent of Medium, which always renders at the default zoom.

## Map snapshot architecture

`NearbyE85MapRenderer` (widget-extension-only) calls `MKMapSnapshotter` once per timeline computation — never a live `MKMapView` — producing a single raster image plus a list of `NearbyE85MapMarker` points precomputed in that image's own coordinate space. `NearbyE85MapView` then overlays marker views with `.position(marker.point)`; stations draw first, the user's dot last, so a coincident station pin never hides it. The nearest station's price badge is attached via `.overlay`, not a layout-affecting sibling, specifically so decorating it can never shift the circle's own center away from its geographic anchor — this was a real, fixed bug (see "Fix geographic offset of Nearby E85 widget station markers"), and `NearbyE85MapMarkerAnchorTests` locks the invariant in.

`NearbyE85MapRegion` computes the map's centered region/span from the user coordinate and station coordinates, then `NearbyE85MapZoomLevel` (five discrete steps, `.zoomedOutFar` … `.zoomedInFar`, default `.standard`) multiplies that span for Large's zoom controls. Zoom is presentation-only — it never changes which stations are fetched, never touches the App Group cache, and is completely independent of the manual-refresh state (`NearbyE85RefreshAndZoomIndependenceTests`, `NearbyE85ZoomBoundaryIsolationTests`).

**Zoom-boundary tap-through fix:** the `+`/`−` buttons originally used SwiftUI's `.disabled(...)` at the min/max boundary. WidgetKit does not guarantee a disabled interactive element consumes its own tap region — on-device testing showed a disabled Zoom In button letting taps fall through to the sibling map `Link` underneath (mis-firing into Stations in 6 of 8 real taps at the ceiling). The fix keeps the buttons genuinely tappable at the boundary (visually dimmed only, via `NearbyE85IconButtonInteractivity.shouldActuallyDisable`, which only the refresh button's transient in-flight state ever triggers), relying on the zoom step function's existing clamped no-op to make a boundary tap harmless. Re-validated on-device: 0/8 unwanted launches at both extremes.

## Manual refresh and the hybrid location-refresh policy

Widget-extension code cannot reliably obtain a fresh Core Location fix mid-`perform()` — WidgetKit grants only a brief execution window with no guarantee a delegate callback completes in time, and Apple's own interactivity guidance is to keep `perform()` fast and defer slower work to the containing app. `NearbyE85RefreshIntent` (shared by all three sizes) is honest about this: it only marks a pending request (`NearbyE85RefreshRequestStore`, one App-Group-shared timestamp) and reloads the timeline with whatever data is already cached — never a faked "Updated now." `EightyFiveBlendsApp`'s `scenePhase`-active handler consumes that pending request the next time the app is foregrounded, performs one real one-shot location fetch, and republishes through the same hybrid policy below — `isManualRefresh` only bypasses the anti-jitter rate limit, never the content check, so a tap can never fake a newer timestamp when nothing legitimately changed.

Between explicit taps, `NearbyE85LocationRefreshCoordinator` republishes opportunistically whenever a significant-location-change fix arrives (see below) or the app foregrounds. `NearbyE85LocationAcceptance` separates fix *quality* (accuracy/staleness/duplicate rejection) from a presentation-aware *publish decision*: movement alone must clear 0.5mi, but a nearest-station change, a visible station-cluster change, or a material change in the nearest station's displayed distance (≥0.2mi absolute or ≥18% relative) can trigger a refresh well under that floor. A 3-minute minimum publish interval applies to ordinary movement only — never to a genuine nearest/cluster change, accumulated staleness (12-minute override), or an explicit manual refresh.

**Refresh feedback (UI only, never faked):** `NearbyE85RefreshFeedback.isRefreshing(requestedAt:now:)` is a pure, ~8-second window computed from the same pending-request timestamp — while it's true, all three sizes swap the refresh icon for a `ProgressView` and dim/disable just that one button (refresh is the one control that genuinely disables at a boundary, since its "in flight" state is transient by design; see the zoom fix above for why boundary states that can persist indefinitely must not). The timeline provider schedules a follow-up entry exactly when the window ends so the control settles back to normal on its own, with no dependency on whether the app ever reopens to complete the real fetch. This flag has no path to `snapshot`/`updatedAt`/`locationAt`/any station's `priceReportedAt` — verified structurally (the function takes no snapshot parameter) and by test (`NearbyE85RefreshFeedbackHonestyTests`).

## Preferred-map routing

Widget-originated "get directions" taps resolve through `NearbyE85DeepLink` back into the app, then `NearbyE85WidgetRouting.resolve(...)` (pure, unit-tested) maps the parsed destination against the cached snapshot to an outcome — `.openDirections`, `.switchToStations`, or (defensively, for a corrupted/stale cache) `.showStationDetail`. A resolved `.openDirections` calls the same `MapsRoutingHelper.openDirections(to:)` every other in-app "Get Directions" button uses: Apple Maps by default, or the user's preferred Google Maps/Waze, falling back to Apple Maps if the preferred third-party app isn't installed. Trip Planner's route-based handoff (`TripNavigationLauncher`) is a deliberately separate, waypoint-aware system — not used by this widget — documented in that file's own header as an intentional non-duplication, not an oversight.

## Targets, storage safety, and signing

| Configuration | App bundle | Widget bundle | App Group | URL scheme |
| --- | --- | --- | --- | --- |
| Debug / Release | `com.e85blends.app.ios` | `com.e85blends.app.ios.NearbyE85Widget` | `group.com.e85blends.app.ios` | `e85blends` |
| Internal | `com.e85blends.app.ios.internal` | `com.e85blends.app.ios.internal.NearbyE85Widget` | `group.com.e85blends.app.ios.internal` | `e85blends-internal` |

The app embeds and depends on `NearbyE85Widget`. The checkpoint preserves the actual baseline app deployment floor of iOS 17.6 in all three configurations; the new widget and test targets match it. App and widget marketing versions are 2.4.0. Existing development build numbers are retained and matched (42 Debug/Release; 100 Internal). These are not submission numbers: the prior release tag refers to App Store build 163. Assign the next valid submission build when preparing a release.

All app `ModelConfiguration` paths explicitly use `groupContainer: .none`. This is essential: the default `.automatic` may select an entitled App Group when one is added, which would change the location of the user's existing database. The existing CloudKit containers remain unchanged and separate for Internal and production.

Device distribution requires registering both App Groups and the two new widget bundle IDs on team `6G83S7V2SK`, associating each group with its corresponding app and extension, and regenerating provisioning profiles. Local source entitlements alone do not establish portal registration. This branch does not register or alter portal resources.

## iOS/WidgetKit limitations

- **No continuous GPS.** `StationLocationManager` only ever uses one-shot foreground requests and `startMonitoringSignificantLocationChanges()` — never `startUpdatingLocation()`, never `allowsBackgroundLocationUpdates`. The widget extension itself never requests a location at all.
- **When-In-Use is sufficient; nothing here requires Always.** `requestAlwaysAuthorization()` exists only for the separate, user-opt-in Automatic Pump Detection feature — the Nearby E85 widget never calls it and never escalates permission on its own.
- **The extension cannot force a fresh fix.** As above, `NearbyE85RefreshIntent.perform()` marks a pending request and nothing more; only the containing app, once foregrounded, can actually ask Core Location for a new fix. A refresh tap while the app is never reopened will show the in-progress spinner and then honestly settle back to unchanged data.
- **A disabled interactive Button can leak its tap to a sibling view.** This is a real, confirmed WidgetKit behavior (not a hypothetical) — see the zoom-boundary fix above. Any future interactive control added to this widget that can reach a persistent "nothing more to do here" state should use visual-only dimming, not `.disabled(...)`, unless the state is genuinely transient (like refresh's few-second in-flight window).
- **WidgetKit, not the app, controls actual reload timing.** `WidgetCenter.shared.reloadTimelines(ofKind:)` is a request, not a guarantee — it's called only on a real state change (station cache write that changed something, a refresh tap, a zoom tap), never in a loop or unconditionally, but the OS ultimately decides when the re-render happens.

## Validation

Xcode Beta: 27.0 (27A5252f), `/Users/julianfigueroa/Downloads/Xcode-beta.app`.

Tests cover: cache atomic replacement/round-trip/corruption/version/size, permission redaction, typed/restored/moved-location publication exclusion, deep-link validation, significant-location monitoring, location-fix-quality and hybrid publish-decision acceptance, map region/zoom-level math, `MKMapSnapshotter` rendering (real, network-best-effort, and synthetic), marker-anchor stability, zoom persistence, zoom-boundary tap-through isolation, manual-refresh request/feedback timing and honesty, widget URL resolution and routing, preferred-map routing (Apple/Google/Waze + fallback), and image captures of every shipping layout/state across all three families.

Completed local validation (this merge-prep pass):

- Clean Debug build (app + embedded `NearbyE85Widget.appex`): **succeeded**, confirmed via `ValidateEmbeddedBinary .../PlugIns/NearbyE85Widget.appex`. Bundle ID, App Group, URL scheme, and `MARKETING_VERSION = 2.4.0` all verified in `project.pbxproj` and unchanged from baseline.
- Internal build: **fails** at `CompileAssetCatalogVariant`, confirmed by direct build attempt — caused entirely by the unrelated, pre-existing `AppIconInternalV2.appiconset` deletion sitting staged (never committed) on this branch since before any Nearby E85 or review-request work began. Not touched or fixed by this pass; see "Merge audit" below.
- Full suite: 795 tests, 791 passed, 4 failed. The 4 failures are pre-existing `CommunityStationUpsertSecurityTests` (Supabase network/decoding tests), unrelated to this widget and unaffected by any commit on this branch.
- Nearby-E85-scoped tests specifically: **157 of 157 passed** across `NearbyE85Tests.swift` (50), `NearbyE85LocationTests.swift` (49), `NearbyE85WidgetInteractionTests.swift` (43), and `NearbyE85RenderingTests.swift` (15).
- Device-interaction validation (iOS 27.0 Simulator — no physical iPhone was available in this environment): refresh spinner confirmed appearing between +0.5s and +1.5s after tap and reverting between +7s and +9s, consistently on all three sizes; tap isolation confirmed in both directions (refresh never triggers directions/Stations/zoom, and vice versa); zoom persists across a refresh; repeated boundary taps produced 0/8 unwanted Stations launches at both zoom extremes.

Manual release validation still needed on a **physical device**, since simulator/`ImageRenderer` snapshots cannot establish these: true spinner animation smoothness and "feel," haptic response (if any is added later), a provisioned iPhone upgrade from 2.3.2 with existing local/CloudKit data, adding all three widget sizes to a real Home Screen, cold/warm station links, approximate vs. denied location permission, Settings-level permission revocation, offline/stale data, real installed Google Maps/Waze app handoffs, and multi-day Home Screen reload scheduling under real WidgetKit budgeting (not the Simulator's more permissive reload behavior).

## Merge audit — 2.4.0

Full commit list since the `20b8d89` baseline, in order, with classification:

| Commit | Belongs to |
| --- | --- |
| `85e3117` Add Nearby E85 Home Screen widget | Nearby E85 |
| `a4947ec` Redesign Nearby E85 widget with MapKit | Nearby E85 |
| `bf443d7` Add location-aware refresh for the Nearby E85 widget | Nearby E85 |
| `8b1130b` Split Nearby E85 widget into distinct small/medium/large layouts | Nearby E85 |
| `9999d00` Give each Nearby E85 widget size its own tap behavior | Nearby E85 |
| `5f12e25` Fix geographic offset of Nearby E85 widget station markers | Nearby E85 |
| `6970f8a` Add zoom controls to the Large Nearby E85 widget's map | Nearby E85 |
| `1b78d56` Add hybrid location-refresh policy and manual refresh to Nearby E85 widget | Nearby E85 |
| `b1f0845` Restore AppIconInternalV2 assets accidentally swept into the previous commit | **Unrelated** — corrective only; see below |
| `30b77c0` Add App Store review request flow | **App Store review requests** (separate feature) |
| `5b55817` Polish Nearby E85 widget refresh control feedback and inset | Nearby E85 |
| `50ab515` Fix Large widget zoom-boundary tap falling through to Stations | Nearby E85 |

`b1f0845` is neither Nearby E85 nor review-request work — it exists only because commit `1b78d56` accidentally finalized a deletion of unrelated, pre-existing staged `AppIconInternalV2` assets that had been sitting uncommitted on this branch since before this feature started; `b1f0845` restores those files back to their prior staged-but-uncommitted state. The same asset deletion is, as of this audit, staged again in the working tree — a pre-existing, unrelated, in-progress icon change that no Nearby E85 or review-request commit should absorb. It is the sole reason the Internal build configuration fails; the Debug configuration (used by App Store/TestFlight-facing builds and this document's own validation) is unaffected. Three other pre-existing, unrelated, unstaged edits remain in the working tree throughout this branch's history and were never touched by any commit described here: a one-line `import Foundation` fix in `AppExperienceNavigationTests.swift`, a test-determinism fix in `NearbyE85LocationTests.swift` (`monitoringNeverStartsWithoutAuthorization` now forces `authorizationStatus = .notDetermined` instead of relying on ambient Simulator permission state), and cosmetic Xcode-driven reformatting of `Info.plist` and `xcschememanagement.plist` (key reordering/whitespace and scheme-order-hint bookkeeping — no semantic change).

**The App Store review-request feature (`30b77c0`) is intentionally separate 2.4.0 work, not part of Nearby E85.** It touches entirely different files (`ReviewRequestEligibility.swift`, `ReviewRequestManager.swift`, `SubscriptionManager.swift`, `MoreView.swift`, `ContentView.swift`, `EightyFiveBlendsApp.swift`, `ProUpgradeView.swift`, `TripNavigationLauncher.swift`, `AppPreferences.swift`) and shares no code path with the widget beyond both incrementing a shared `stationDirectionsCount` signal when the user gets directions to a station (widget-originated directions included). Whether it should merge together with or split from this branch is a product/release-sequencing decision, not a technical blocker in either direction — see the final report for the recommendation.

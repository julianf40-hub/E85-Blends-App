# Nearby E85 widget — 2.4.0 first slice

## Scope and baseline

Work is confined to `/Users/julianfigueroa/Desktop/EightyFiveBlends-Latest`, on `codex/2.4.0-nearby-e85-widget`, branched from clean `codex/local-2.3.2` at `20b8d89e61222c314d2a6b0a085dc016837da9c2`. At audit time the baseline also matched the local `origin/main` reference and `v2.3.2` tag. No remote update is needed to branch from the explicitly requested baseline. The original older checkout is not modified. No push, merge, archive, or upload is part of this work.

This is a **last-app-location widget**, not autonomous background navigation. It updates when the app completes its existing current-location station search and when available app price previews refresh. Opening the app normally selects Stations and runs its existing automatic search. Tapping a station opens its snapshot details; a missing/expired station link falls back to the Stations tab. There is no Pro gating.

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

## Targets, storage safety, and signing

| Configuration | App bundle | Widget bundle | App Group | URL scheme |
| --- | --- | --- | --- | --- |
| Debug / Release | `com.e85blends.app.ios` | `com.e85blends.app.ios.NearbyE85Widget` | `group.com.e85blends.app.ios` | `e85blends` |
| Internal | `com.e85blends.app.ios.internal` | `com.e85blends.app.ios.internal.NearbyE85Widget` | `group.com.e85blends.app.ios.internal` | `e85blends-internal` |

The app embeds and depends on `NearbyE85Widget`. The checkpoint preserves the actual baseline app deployment floor of iOS 17.6 in all three configurations; the new widget and test targets match it. App and widget marketing versions are 2.4.0. Existing development build numbers are retained and matched (42 Debug/Release; 100 Internal). These are not submission numbers: the prior release tag refers to App Store build 163. Assign the next valid submission build when preparing a release.

All app `ModelConfiguration` paths explicitly use `groupContainer: .none`. This is essential: the default `.automatic` may select an entitled App Group when one is added, which would change the location of the user's existing database. The existing CloudKit containers remain unchanged and separate for Internal and production.

Device distribution requires registering both App Groups and the two new widget bundle IDs on team `6G83S7V2SK`, associating each group with its corresponding app and extension, and regenerating provisioning profiles. Local source entitlements alone do not establish portal registration. This branch does not register or alter portal resources.

## Validation

Xcode Beta: 27.0 (27A5252f), `/Users/julianfigueroa/Downloads/Xcode-beta.app`.

New tests cover nearest-station selection, invalid/missing prices and timestamps, expiry, original-fix age, cache atomic replacement/round trips/corruption/version/size, permission redaction, typed/restored/moved-location publication exclusion, deep-link validation, and image captures of the shipping layouts.

Completed local validation:

- Debug app + embedded widget build: passed with Xcode Beta 27.0 (27A5252f), pinned RevenueCat 5.85.0, Google Mobile Ads 13.8.0, and UMP 3.1.0.
- Focused cache/publication/deep-link tests: 10 passed.
- Focused widget rendering test: 1 passed; eight attachments cover small and medium station, stale-price, no-price, permission, no-station, and no-cache states.
- Internal app + embedded widget build: passed with `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon` supplied only on the command line because the unrelated staged `AppIconInternalV2` asset set is currently deleted. The normal Internal build therefore remains blocked by that pre-existing deletion.
- Full suite: 596 tests ran; 21 recorded issues remain in existing Trip Navigation and Community Station networking tests. No Nearby E85 test failed.

Manual release validation should include a provisioned iPhone upgrade from 2.3.2 with existing local/CloudKit data, adding both widget sizes, cold/warm station links, approximate and denied permission, Settings revocation, offline/stale data, and multi-day Home Screen scheduling. Simulator compilation and image rendering cannot establish these device lifecycle guarantees.

Checkpoint review excludes the unrelated staged Internal icon deletion, personal scheme ordering, an unnecessary AppExperienceNavigationTests import, and unrelated Internal display-name/deployment/launch-storyboard edits. These remain local. Post-commit validation runs from an exact Git archive so local excluded changes cannot affect the result. Real-device signing, shared-container access, gallery appearance, and station-opening behavior remain unverified on a provisioned device.

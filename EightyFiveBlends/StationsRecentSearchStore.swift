//
//  StationsRecentSearchStore.swift
//  EightyFiveBlends
//
//  Stations instant-loading foundation (2.3.2, PR A) — a small, session-scoped, in-memory
//  cache of the most recent CURRENT-LOCATION live-station search, so Stations can render a
//  compatible recent result set immediately on appearance instead of waiting for a fresh
//  Core Location fix + NREL network round trip every time. See the 2.3.2 architecture audit
//  for the full root-cause trace: the ~10-15s real-device delay is dominated by a cold,
//  high-accuracy (kCLLocationAccuracyNearestTenMeters) one-shot location fix, not by the
//  network call itself.
//
//  DELIBERATELY SEPARATE from RecentLiveStationCache (Pump Mode's own cache): that type
//  stores a lightweight subset of fields for a completely different purpose (recognizing a
//  station the user recently drove to, for up to 6 hours, for manual Pump Mode's
//  station-context resolution) and must not be repurposed for Stations' own display needs —
//  its 6-hour lifetime and "wholesale replace" semantics are tuned for Pump Mode's question,
//  not Stations'. This store is Stations-only; StationsView continues to write BOTH caches
//  independently from the same successful fetch (see StationsView.fetchLiveStations) — this
//  store is additive, never a replacement for the existing RecentLiveStationCache write.
//
//  This store owns only reusable session data + freshness/compatibility decisions. It does
//  NOT make network requests, own map camera state, own SwiftUI UI state, own community
//  pricing, or own Pro entitlement — StationsView continues to orchestrate all search/network
//  behavior exactly as before; this store is a passive, injectable record of the last
//  successful current-location search.
//
//  Cross-launch cache (2.3.2, PR #54) — this store now has TWO distinct tiers, layered on top
//  of each other, never conflated:
//    1. SESSION CACHE (original PR A behavior, completely unchanged) — the in-memory `snapshot`
//       below, governed by compatibleSnapshot(near:radiusMiles:now:)'s existing 5-minute
//       "fresh" / 30-minute "staleButUsable" / otherwise "incompatible" rules. This tier's
//       meaning and byte-level behavior are untouched by PR #54.
//    2. PERSISTED PREVIEW (new) — the same `snapshot` may ALSO now be restored from a small,
//       atomic JSON file on disk (Library/Caches, via defaultPersistenceURL) at store `init`,
//       so it can survive an ordinary app relaunch, force quit, or background termination —
//       something the original in-memory-only design explicitly did not attempt. This is a
//       cold-launch DISPLAY OPTIMIZATION ONLY, governed by its own, separate, more permissive
//       persistentPreviewCeiling (24h) and its own persistedPreviewCompatibility(near:
//       radiusMiles:) decision method — see that method's header for why it is deliberately
//       never folded into compatibleSnapshot's own session semantics. Persisting this data
//       never marks `lastCurrentLocationSearchAt` (see that property's own header below) — a
//       restored preview must never suppress the normal automatic cold-launch refresh that
//       already exists for a good reason: to reconcile the preview with reality via a real
//       network fetch as soon as possible.
//
//  Persisted fields are intentionally minimal and boring: station name/address/city/state/zip/
//  coordinate/distance/phone/access-hours/last-confirmed/fuel-type-code (see
//  PersistedLiveFuelStation below) plus the search center (rounded to ~3 decimal places — see
//  roundedForPersistentCache — well coarser than this cache's own >=500m compatibility
//  tolerance), radius, and fetch timestamp. Never community/price data (LiveFuelStation itself
//  carries none), never SwiftData/CloudKit, never Supabase, never RevenueCat, and never the
//  ephemeral LiveFuelStation.id (a restored station is reconstructed with a fresh id — durable
//  station identity for the premium map already comes from canonical station keys elsewhere,
//  not from this UUID). A missing, corrupt, or schema-mismatched file is always treated as "no
//  cache" — persistence is optional and can never break Stations or crash the app.
//

import CoreLocation
import Foundation

/// One completed current-location live-station search, with enough metadata to later decide
/// whether it's still usable for a new appearance of Stations. Deliberately does NOT include
/// price/community data — those have their own, separate refresh lifecycle in StationsView
/// (see refreshCommunityPricePreviews()) and are intentionally left out of this cache to avoid
/// a second, competing source of truth for community pricing.
struct StationsSearchSnapshot: Equatable {
    let stations: [LiveFuelStation]
    let center: StationCoordinate
    let radiusMiles: Double
    let fetchedAt: Date
}

/// Pure, directly-testable freshness/compatibility rules for StationsSearchSnapshot — kept
/// independent of the @Observable store below, mirroring
/// CommunityPriceEligibility/AppExperienceNavigation's existing separation of pure decision
/// logic from the stateful/SwiftUI-facing types that consume it.
enum StationsRecentSearchCompatibility: Equatable {
    /// Usable immediately, no refresh strictly required yet (still inside the automatic
    /// refresh cooldown window).
    case fresh(StationsSearchSnapshot)
    /// Usable immediately, but old enough that a quiet background refresh is worthwhile.
    case staleButUsable(StationsSearchSnapshot)
    /// Wrong radius, wrong location, or too old even to show as stale-but-usable — must not
    /// be hydrated as if it were a valid nearby-search result.
    case incompatible
    /// No snapshot has ever been recorded this session.
    case none
}

/// Cross-launch cache (PR #54) — the outcome of validating a snapshot RESTORED FROM DISK
/// against the CURRENT radius selection and (when known) the current coordinate. See
/// StationsRecentSearchStore.persistedPreviewCompatibility(near:radiusMiles:)'s header for why
/// this is a distinct decision from StationsRecentSearchCompatibility above, never a widening
/// of it.
enum StationsPersistedPreviewCompatibility: Equatable {
    /// A current coordinate is already known and matches the persisted snapshot's search
    /// center — safe to show as if it were an ordinary session-compatible result.
    case validated(StationsSearchSnapshot)
    /// No current coordinate is available yet to confirm the user hasn't moved — may be shown
    /// briefly, explicitly marked unvalidated, while location/network resolve.
    case provisional(StationsSearchSnapshot)
    /// A current coordinate is known and proves the user has materially moved away from the
    /// persisted snapshot's search center — must NOT be shown.
    case incompatibleLocation
    /// No restored snapshot exists, the radius doesn't match, or it's older than
    /// persistentPreviewCeiling.
    case unavailable
}

/// Stations-only location-freshness policy — separate from, and never applied to, Pump
/// Mode's own staleness rules (PumpStationContextResolver's 120s/50m gates, which remain
/// completely untouched). Answers a much less strict question than that resolver does: is an
/// existing foreground fix recent enough that Stations (or the app-foreground prewarm that
/// feeds it) can skip requesting a brand new one right now?
enum StationsLocationFreshness {
    /// Deliberately shorter than StationsRecentSearchStore's freshness/staleness windows
    /// below, so "reuse this coordinate" can never itself be the reason stale-looking nearby
    /// results get shown — it only ever skips a redundant GPS wait, never widens what counts
    /// as an acceptable station-result snapshot.
    static let maximumCoordinateAgeForReuse: TimeInterval = 3 * 60

    static func isCoordinateRecentEnough(fixTimestamp: Date?, now: Date) -> Bool {
        guard let fixTimestamp else { return false }
        return now.timeIntervalSince(fixTimestamp) <= maximumCoordinateAgeForReuse
    }
}

/// Cross-launch cache (PR #54) — a tiny, boring, private Codable persistence DTO. Deliberately
/// NOT LiveFuelStation itself (see this file's header and LiveFuelStation's own "ephemeral id"
/// documentation) — carries only the actual station fields that matter for display, with no
/// `id`, so a restored station always gets a fresh UUID via LiveFuelStation's existing direct
/// field initializer (already used by RouteE85PlannerTests for synthetic stations), never
/// LiveFuelStation.init(from:), which expects a raw NLRFuelStationResponse.
private struct PersistedLiveFuelStation: Codable {
    let name: String
    let address: String
    let city: String
    let state: String
    let zip: String
    let latitude: Double
    let longitude: Double
    let distanceMiles: Double
    let phone: String
    let accessHours: String
    let dateLastConfirmed: String
    let fuelTypeCode: String

    init(_ station: LiveFuelStation) {
        name = station.name
        address = station.address
        city = station.city
        state = station.state
        zip = station.zip
        latitude = station.latitude
        longitude = station.longitude
        distanceMiles = station.distanceMiles
        phone = station.phone
        accessHours = station.accessHours
        dateLastConfirmed = station.dateLastConfirmed
        fuelTypeCode = station.fuelTypeCode
    }

    func toLiveFuelStation() -> LiveFuelStation {
        LiveFuelStation(
            name: name,
            address: address,
            city: city,
            state: state,
            zip: zip,
            latitude: latitude,
            longitude: longitude,
            distanceMiles: distanceMiles,
            phone: phone,
            accessHours: accessHours,
            dateLastConfirmed: dateLastConfirmed,
            fuelTypeCode: fuelTypeCode
        )
    }
}

/// Cross-launch cache (PR #54) — the small, explicitly-versioned envelope actually written to
/// and read from disk (section 8). `schemaVersion` is checked on every restore; anything other
/// than StationsRecentSearchStore.currentSchemaVersion (a missing/renamed field, a decode
/// failure, or a mismatched value) is treated identically to "no cache" — see
/// restorePersistedSnapshotIfAvailable(). No community/price fields, no SwiftData/CloudKit
/// identifiers, no entitlement state — see this file's header.
private struct PersistedStationsSearchSnapshot: Codable {
    let schemaVersion: Int
    let stations: [PersistedLiveFuelStation]
    let centerLatitude: Double
    let centerLongitude: Double
    let radiusMiles: Double
    let fetchedAt: Date
}

@MainActor
@Observable
final class StationsRecentSearchStore {
    /// Mirrors StationsView's own (pre-existing) automatic-search cooldown window — kept as
    /// the single, named source of truth Stations already defined
    /// (StationsView.autoNearbySearchCooldown); a StationsSearchSnapshot at or under this age
    /// is considered "fresh" (no refresh strictly needed yet), matching the existing product
    /// behavior of not re-fetching within 5 minutes of the last current-location search.
    static let freshnessWindow: TimeInterval = 5 * 60

    /// Upper bound past which a same-session snapshot is no longer shown at all, even as
    /// "stale-but-usable." Deliberately NOT borrowed from RecentLiveStationCache's 6-hour Pump
    /// Mode lifetime — that value answers "did the user see this station at all on this trip,"
    /// a much more permissive question than "is this still a reasonable nearby-stations
    /// result to show as if current." Chosen as 6x freshnessWindow: long enough to survive a
    /// normal few-minutes app-background/multitasking gap without a visible regression to the
    /// pre-cache "wait for a fresh search" experience, short enough that showing this data as
    /// an immediate render is very unlikely to be meaningfully wrong.
    static let staleButUsableCeiling: TimeInterval = 30 * 60

    /// Cross-launch cache (PR #54) — the CURRENT persisted-envelope schema. Bumping this
    /// invalidates every previously-written file the moment a new build tries to read it (see
    /// restorePersistedSnapshotIfAvailable()) rather than risk decoding a shape that has since
    /// changed meaning.
    static let currentSchemaVersion = 1

    /// Cross-launch cache (PR #54) — a DISTINCT, more permissive ceiling than
    /// staleButUsableCeiling above (section 11). This does NOT mean 24-hour-old data is
    /// "fresh" — it means "safe enough to provisionally show for a moment while a brand-new
    /// current-location search immediately refreshes it." The existing 5/30-minute in-session
    /// semantics above are completely unaffected by this constant.
    static let persistentPreviewCeiling: TimeInterval = 24 * 60 * 60

    /// Cross-launch cache (PR #54) — one small, replaceable JSON file in the app's Caches
    /// directory (never SwiftData/CloudKit/UserDefaults/Supabase). Caches-directory semantics
    /// are exactly what this data wants: it survives an ordinary relaunch and app update, is
    /// excluded from iCloud/device backup, and the OS may purge it under storage pressure —
    /// all acceptable, since the very next successful current-location search simply rewrites
    /// it (see recordCurrentLocationSearchResult).
    static let defaultPersistenceURL: URL = {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("85Blends", isDirectory: true)
        return directory.appendingPathComponent("StationsCurrentLocationSnapshot-v1.json")
    }()

    /// Cross-launch cache (PR #54) — whether the in-memory `snapshot` below came from restoring
    /// the disk cache on THIS launch, or from a real network fetch completed during this
    /// process. UI code never needs the persistence mechanics behind `.restoredFromDisk` — it
    /// only ever needs this distinction via persistedPreviewCompatibility(near:radiusMiles:)
    /// below, to decide whether a currently-shown result still needs GPS confirmation.
    enum SnapshotOrigin: Equatable {
        case restoredFromDisk
        case currentSession
    }

    private(set) var snapshot: StationsSearchSnapshot?
    private(set) var snapshotOrigin: SnapshotOrigin?

    /// Timestamp of the last current-location search ATTEMPT (stamped at request start, not
    /// on success) — mirrors StationsView's previous view-local `lastNearbySearchDate` exactly,
    /// just relocated here so it survives Stations view-state churn instead of resetting on
    /// every StationsView recreation. Stamped regardless of success/failure so a failing/
    /// offline search still suppresses automatic re-trigger spam, exactly as before.
    ///
    /// Cross-launch cache (PR #54) — deliberately NEVER persisted to disk and NEVER set by
    /// restorePersistedSnapshotIfAvailable(): a fresh app process must always be allowed to
    /// perform its own normal automatic current-location refresh (see
    /// StationsView.shouldPerformAutomaticNearbySearch(), which reads only this property, never
    /// `snapshot`/`snapshotOrigin`), regardless of whether a persisted preview exists. The disk
    /// cache is a presentation optimization only — it must never be able to suppress a network
    /// search.
    private(set) var lastCurrentLocationSearchAt: Date?

    private let persistenceURL: URL

    init(persistenceURL: URL = StationsRecentSearchStore.defaultPersistenceURL) {
        self.persistenceURL = persistenceURL
        // Cross-launch cache (PR #54, section 18) — kept synchronous and tiny on purpose: this
        // is a single, small JSON file, so a plain synchronous read at init is acceptable and
        // avoids launching a Task merely to read it. Never throws, never crashes, never blocks
        // meaningfully — see restorePersistedSnapshotIfAvailable()'s own header.
        restorePersistedSnapshotIfAvailable()
    }

    /// Records that a current-location search attempt began — see doc comment above for why
    /// this is attempt-based, not success-based. Never called for typed-location searches —
    /// StationsView guards this at the call site, same as it always guarded
    /// `lastNearbySearchDate`.
    func recordCurrentLocationSearchAttempt(at date: Date) {
        lastCurrentLocationSearchAt = date
    }

    /// Records a SUCCESSFUL current-location search's full result set for later hydration.
    /// Deliberately accepts (and correctly caches) an empty `stations` array — a successful
    /// search that legitimately found nothing nearby is a valid, cacheable snapshot distinct
    /// from a failed search (which never calls this method at all, leaving any previous good
    /// snapshot untouched — see StationsView.fetchLiveStations's catch branch).
    ///
    /// Cross-launch cache (PR #54) — this remains the SINGLE call site that writes a new
    /// snapshot: it now also atomically persists it to disk and marks its origin as
    /// `.currentSession`, so StationsView never needs a second write path. A network failure
    /// never reaches this method at all (see above), so it can never overwrite a previously
    /// good disk cache with empty/failed data.
    func recordCurrentLocationSearchResult(
        stations: [LiveFuelStation],
        center: StationCoordinate,
        radiusMiles: Double,
        fetchedAt: Date
    ) {
        let newSnapshot = StationsSearchSnapshot(
            stations: stations,
            center: center,
            radiusMiles: radiusMiles,
            fetchedAt: fetchedAt
        )
        snapshot = newSnapshot
        snapshotOrigin = .currentSession
        persistSnapshotToDisk(newSnapshot)
    }

    /// Whether the current snapshot (if any) may be hydrated immediately for a new Stations
    /// appearance. Conservative by design:
    /// - `radiusMiles` must match the snapshot's radius EXACTLY. No subset/superset reuse
    ///   across radii is implemented here — a wrong-radius result set must never be presented
    ///   as if it were the requested one.
    /// - `coordinate` is the user's current best-known location, if any. When `nil` (location
    ///   unavailable), a recent same-session snapshot may still be shown as stale-but-usable —
    ///   it is still gated by `staleButUsableCeiling` and reported as `.staleButUsable`, never
    ///   `.fresh`, since without a current coordinate there is no way to confirm the user
    ///   hasn't materially moved.
    ///
    /// Cross-launch cache (PR #54) — completely UNCHANGED by that feature, on purpose (section
    /// 20): `snapshot` may now originate from a disk restore instead of only a same-process
    /// fetch, but this method's own 5/30-minute meaning is untouched either way. When this
    /// returns `.incompatible`/`.none` for a disk-restored snapshot (most commonly because it
    /// is older than 30 minutes, which a cross-launch snapshot very often is), the SEPARATE
    /// persistedPreviewCompatibility(near:radiusMiles:) below is what StationsView falls back
    /// to — see that method's header.
    func compatibleSnapshot(
        near coordinate: StationCoordinate?,
        radiusMiles: Double,
        now: Date
    ) -> StationsRecentSearchCompatibility {
        guard let snapshot else { return .none }
        guard snapshot.radiusMiles == radiusMiles else { return .incompatible }

        let age = now.timeIntervalSince(snapshot.fetchedAt)
        guard age <= Self.staleButUsableCeiling else { return .incompatible }

        guard let coordinate else {
            // No current coordinate to confirm the user hasn't moved (location unavailable,
            // denied, or not yet resolved) -- NEVER classify as `.fresh` here, regardless of
            // age, since that would present this snapshot as fully current with zero location
            // confirmation. Still gated by `staleButUsableCeiling` above.
            return .staleButUsable(snapshot)
        }

        let distance = Self.distanceMeters(snapshot.center, coordinate)
        guard distance <= Self.compatibilityRadiusMeters(forSearchRadiusMiles: radiusMiles) else {
            return .incompatible
        }

        return age <= Self.freshnessWindow ? .fresh(snapshot) : .staleButUsable(snapshot)
    }

    /// Cross-launch cache (PR #54, section 21) — a SEPARATE decision method for a snapshot that
    /// was RESTORED FROM DISK this launch (guarded by `snapshotOrigin == .restoredFromDisk`;
    /// a current-session snapshot always returns `.unavailable` here — StationsView should
    /// simply never call this when compatibleSnapshot above already found something usable).
    /// Deliberately never folded into compatibleSnapshot itself so that method's own
    /// 5/30-minute in-session meaning never becomes ambiguous (section 20). Reuses the exact
    /// same exact-radius-match requirement and the exact same
    /// compatibilityRadiusMeters(forSearchRadiusMiles:)/distanceMeters location-drift rule as
    /// compatibleSnapshot above — no second, duplicated tolerance is introduced (section 22).
    /// Age is bounded by the much more permissive `persistentPreviewCeiling` (24h) rather than
    /// `staleButUsableCeiling` (30m) — already enforced once at restore time (an expired file
    /// is never even loaded into `snapshot` — see restorePersistedSnapshotIfAvailable()) and
    /// re-checked here defensively for a very long-running session.
    func persistedPreviewCompatibility(
        near coordinate: StationCoordinate?,
        radiusMiles: Double
    ) -> StationsPersistedPreviewCompatibility {
        guard snapshotOrigin == .restoredFromDisk, let snapshot else { return .unavailable }
        guard snapshot.radiusMiles == radiusMiles else { return .unavailable }
        guard Date.now.timeIntervalSince(snapshot.fetchedAt) <= Self.persistentPreviewCeiling else {
            return .unavailable
        }

        guard let coordinate else {
            // No current coordinate yet to validate against -- exactly the cold-launch case
            // this tier exists for (section 25). May be shown, explicitly marked provisional.
            return .provisional(snapshot)
        }

        let distance = Self.distanceMeters(snapshot.center, coordinate)
        guard distance <= Self.compatibilityRadiusMeters(forSearchRadiusMiles: radiusMiles) else {
            return .incompatibleLocation
        }
        return .validated(snapshot)
    }

    /// Cross-launch cache (PR #54, section 53) — a narrow invalidation method, never a generic
    /// "clear everything" API. Guarded to ONLY ever discard a snapshot that was actually
    /// restored from disk THIS launch — a current-session snapshot (a real fetch that already
    /// completed this process) is never touched here, so discovering a location mismatch on a
    /// process where no disk restore ever happened can never wipe out perfectly good,
    /// just-fetched data. Never touches `lastCurrentLocationSearchAt` (no search attempt just
    /// happened) and never touches RecentLiveStationCache (Pump Mode's own, separate cache).
    func discardRestoredSnapshot() {
        guard snapshotOrigin == .restoredFromDisk else { return }
        snapshot = nil
        snapshotOrigin = nil
        removePersistedSnapshotFile()
    }

    /// Cross-launch cache (PR #54, section 18) — synchronous, tiny, and never throws out of
    /// this function: a missing file, a decode failure, an unsupported schemaVersion, or an
    /// expired (>persistentPreviewCeiling) snapshot are ALL treated identically as "no cache" —
    /// `snapshot`/`snapshotOrigin` simply stay nil, and Stations proceeds exactly as it did
    /// before this feature existed. A corrupt or expired file is also removed from disk so a
    /// future launch doesn't keep re-discovering the same unusable file.
    private func restorePersistedSnapshotIfAvailable() {
        guard let data = try? Data(contentsOf: persistenceURL) else { return }

        guard
            let envelope = try? JSONDecoder().decode(PersistedStationsSearchSnapshot.self, from: data),
            envelope.schemaVersion == Self.currentSchemaVersion
        else {
            #if DEBUG
            print("[85Blends] StationsRecentSearchStore: persisted station cache is corrupt or an unsupported schema version -- ignoring and removing it.")
            #endif
            removePersistedSnapshotFile()
            return
        }

        guard Date.now.timeIntervalSince(envelope.fetchedAt) <= Self.persistentPreviewCeiling else {
            #if DEBUG
            print("[85Blends] StationsRecentSearchStore: persisted station cache is older than the 24h preview ceiling -- ignoring and removing it.")
            #endif
            removePersistedSnapshotFile()
            return
        }

        snapshot = StationsSearchSnapshot(
            stations: envelope.stations.map { $0.toLiveFuelStation() },
            center: StationCoordinate(latitude: envelope.centerLatitude, longitude: envelope.centerLongitude),
            radiusMiles: envelope.radiusMiles,
            fetchedAt: envelope.fetchedAt
        )
        snapshotOrigin = .restoredFromDisk
    }

    /// Cross-launch cache (PR #54, section 17) — atomic file replacement (`.atomic`), so an app
    /// termination mid-write can never leave a half-written, corrupt JSON file behind. Failure
    /// at any step (directory creation, encode, write) is caught and silently ignored (DEBUG
    /// logging only, no coordinates/full JSON logged, no user alert, no crash, no assertion in
    /// Release) — persistence is always optional, never required for Stations to keep working
    /// (section 7).
    private func persistSnapshotToDisk(_ snapshot: StationsSearchSnapshot) {
        let envelope = PersistedStationsSearchSnapshot(
            schemaVersion: Self.currentSchemaVersion,
            stations: snapshot.stations.map(PersistedLiveFuelStation.init),
            centerLatitude: Self.roundedForPersistentCache(snapshot.center.latitude),
            centerLongitude: Self.roundedForPersistentCache(snapshot.center.longitude),
            radiusMiles: snapshot.radiusMiles,
            fetchedAt: snapshot.fetchedAt
        )

        do {
            let data = try JSONEncoder().encode(envelope)
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            #if DEBUG
            print("[85Blends] StationsRecentSearchStore: failed to persist station cache to disk: \(error)")
            #endif
        }
    }

    private func removePersistedSnapshotFile() {
        try? FileManager.default.removeItem(at: persistenceURL)
    }

    private static func distanceMeters(_ lhs: StationCoordinate, _ rhs: StationCoordinate) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }

    /// How far the user may have moved from a snapshot's search center before it's no longer
    /// treated as describing "here" — scaled to the search radius so a small 10 mi search
    /// (where a mile of drift meaningfully changes what's nearby) is much more sensitive than
    /// a 100 mi search (where the same mile is noise), but capped so even a very large search
    /// radius doesn't let genuinely substantial travel (a new city) pass as "still compatible."
    /// A simple, explicit, radius-scaled-and-capped rule: 15% of the search radius, floored at
    /// 500m (so ordinary GPS/geocoding jitter on a small-radius search never falsely
    /// invalidates an otherwise-good cache hit) and capped at 8km (so even a 100 mi search
    /// radius doesn't treat a real, multi-mile relocation as "no movement at all").
    ///
    /// Shared verbatim by persistedPreviewCompatibility(near:radiusMiles:) above — see section
    /// 22's explicit "no duplicated constants" requirement.
    private static func compatibilityRadiusMeters(forSearchRadiusMiles radiusMiles: Double) -> CLLocationDistance {
        let metersPerMile = 1609.34
        let scaled = radiusMiles * metersPerMile * 0.15
        return min(max(scaled, 500), 8_000)
    }

    /// Cross-launch cache (PR #54, section 10) — the search center persisted to disk is rounded
    /// to ~3 decimal places (~100m-scale resolution at most latitudes), comfortably coarser
    /// than this cache's own >=500m compatibility tolerance above, so this rounding can never
    /// itself cause a legitimate compatibility check to fail. Applies ONLY to the disk DTO's
    /// search center — the in-memory `StationCoordinate` this class holds (and every
    /// distance/compatibility calculation above) stays at full precision. Station coordinates
    /// themselves are public fuel-station locations, not the user's own location, and are
    /// persisted at their normal precision (see PersistedLiveFuelStation above).
    private static func roundedForPersistentCache(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}

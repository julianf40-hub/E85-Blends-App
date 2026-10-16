import Foundation
import WidgetKit
import OSLog

@MainActor
enum NearbyE85Publisher {
    private static let logger = Logger(subsystem: "com.e85blends", category: "NearbyE85")
    /// `cache` defaults to the real App-Group-backed cache; tests inject
    /// `NearbyE85Cache(fileURL:)` pointed at a temporary file instead.
    static func publish(_ snapshot: NearbyE85Snapshot, cache: NearbyE85Cache = NearbyE85Cache(), now: Date = .now,
                        areaRelevanceStore: NearbyE85AreaRelevanceStore = NearbyE85AreaRelevanceStore(),
                        reloadTimelines: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: NearbyE85Configuration.kind) }) {
        do {
            let changed = try cache.write(snapshot, now: now)
            // 85Blends 2.4.1 Phase 2C — cleared regardless of whether the cache FILE content
            // changed. `cache.write` only reaches this line (doesn't throw) for a snapshot that
            // already passed `isValid(at:)` — i.e. a validated, authoritative result, whether
            // that came from a real Stations search or NearbyE85LocationRefreshCoordinator's
            // reposition succeeding again after the user travels back into range. That snapshot
            // is current for wherever it was computed EITHER WAY, so any previously recorded
            // out-of-area signal is stale regardless of whether the bytes on disk happened to
            // change. Gating the clear on `changed` alone would leave the widget needlessly
            // stuck showing "Location changed" in the (currently only theoretical, but not
            // structurally impossible) case where a fresh validated search reproduces
            // byte-identical content to what was already cached.
            let areaRelevanceChanged = areaRelevanceStore.clear()
            guard changed || areaRelevanceChanged else { return }
            NearbyE85Diagnostics.logReloadRequested(source: "publisher")
            reloadTimelines()
        } catch {
            // No user location, station identity, or price in diagnostics.
            logger.error("Nearby E85 shared cache unavailable; verify App Group signing and storage.")
        }
    }
    static func eligibleSearch(from store: StationsRecentSearchStore, isCurrentLocationSearch: Bool,
                               authorized: Bool, coordinate: StationCoordinate?, fixTimestamp: Date?, now: Date) -> StationsSearchSnapshot? {
        guard authorized, isCurrentLocationSearch, store.snapshotOrigin == .currentSession,
              let snapshot = store.snapshot, snapshot.locationAt != nil,
              let fixTimestamp, StationDataValidation.isValidTimestamp(fixTimestamp, asOf: now),
              StationsLocationFreshness.isCoordinateRecentEnough(fixTimestamp: fixTimestamp, now: now),
              let coordinate else { return nil }
        switch store.compatibleSnapshot(near: coordinate, radiusMiles: snapshot.radiusMiles, now: now) {
        case .fresh, .staleButUsable: return snapshot
        default: return nil
        }
    }
    static func revokeLocation() {
        let cache = NearbyE85Cache()
        guard cache.read()?.state != .permissionRequired else { return }
        publish(.permissionRequired(at: .now))
    }
}

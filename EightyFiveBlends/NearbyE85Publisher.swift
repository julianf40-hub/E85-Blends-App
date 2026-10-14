import Foundation
import WidgetKit
import OSLog

@MainActor
enum NearbyE85Publisher {
    private static let logger = Logger(subsystem: "com.e85blends", category: "NearbyE85")
    /// `cache` defaults to the real App-Group-backed cache; tests inject
    /// `NearbyE85Cache(fileURL:)` pointed at a temporary file instead.
    static func publish(_ snapshot: NearbyE85Snapshot, cache: NearbyE85Cache = NearbyE85Cache(), now: Date = .now,
                        areaRelevanceStore: NearbyE85AreaRelevanceStore = NearbyE85AreaRelevanceStore()) {
        do {
            if try cache.write(snapshot, now: now) {
                // 85Blends 2.4.1 — any snapshot that actually lands here is, by definition,
                // fresh and authoritative for wherever it was computed (a real Stations search,
                // or NearbyE85LocationRefreshCoordinator's reposition succeeding again after
                // the user travels back into range) — so whatever out-of-area signal was
                // previously recorded is now stale and must be cleared. A failed/no-op search
                // never reaches this line at all, so this can never falsely clear a genuinely
                // still-out-of-area cache.
                areaRelevanceStore.clear()
                NearbyE85Diagnostics.logReloadRequested(source: "publisher")
                WidgetCenter.shared.reloadTimelines(ofKind: NearbyE85Configuration.kind)
            }
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

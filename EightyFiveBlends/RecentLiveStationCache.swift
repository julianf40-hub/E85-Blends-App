//
//  RecentLiveStationCache.swift
//  EightyFiveBlends
//
//  Small, in-memory, app-environment-level cache of recent "Find Nearby E85" live search
//  results, so manually opened Pump Mode can consider a station the user just found and
//  drove to even if they never tapped "Save Station" for it. Deliberately NOT persisted —
//  live results are ephemeral by nature (prices/availability age quickly), and this cache
//  must never silently create or favorite a FuelStation. StationsView is the only writer;
//  Pump Mode (via CalculatorView) is a read-only consumer, so the two screens stay
//  decoupled — Pump Mode never talks to StationsView directly.
//

import Foundation

/// Lightweight, cacheable view of one live search result — mirrors the fields
/// `PumpStationContextResolver` actually needs, not the full `LiveFuelStation` shape.
struct LiveStationSnapshot: Identifiable, Equatable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let address: String?
}

@MainActor
@Observable
final class RecentLiveStationCache {
    /// How long a completed live search stays eligible for Pump Mode context matching
    /// before it's treated as expired. Named and centralized rather than a literal.
    static let cacheLifetime: TimeInterval = 6 * 60 * 60 // 6 hours

    private(set) var entries: [LiveStationSnapshot] = []
    private(set) var fetchedAt: Date?

    /// Replaces the cache with a freshly completed live search's results. Called by
    /// StationsView whenever "Find Nearby E85" (or an equivalent live search) succeeds —
    /// including with an empty result set, which correctly clears any previous stations
    /// that are no longer part of the latest search.
    func replace(with stations: [LiveFuelStation], fetchedAt: Date) {
        entries = stations.compactMap { station in
            guard MonitoredStationSelector.isValidCoordinate(latitude: station.latitude, longitude: station.longitude) else {
                return nil
            }
            let addressParts = [station.address, station.city, station.state].filter { $0.isEmpty == false }
            return LiveStationSnapshot(
                id: AutomaticPumpDetectionStationKey.make(name: station.name, latitude: station.latitude, longitude: station.longitude),
                name: station.name,
                latitude: station.latitude,
                longitude: station.longitude,
                address: addressParts.isEmpty ? nil : addressParts.joined(separator: ", ")
            )
        }
        self.fetchedAt = fetchedAt
    }

    func clear() {
        entries = []
        fetchedAt = nil
    }

    /// Non-expired live candidates as of `now`. Returns an empty array (never stale data)
    /// once the cache lifetime has elapsed, or if nothing has ever been cached — Pump Mode
    /// continues to work with saved stations only in either case.
    func currentEntries(now: Date) -> [LiveStationSnapshot] {
        guard let fetchedAt, now.timeIntervalSince(fetchedAt) <= Self.cacheLifetime else {
            return []
        }
        return entries
    }
}

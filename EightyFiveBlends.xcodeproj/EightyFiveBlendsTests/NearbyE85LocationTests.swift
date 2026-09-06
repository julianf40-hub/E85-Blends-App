import CoreLocation
import Foundation
import Testing
@testable import EightyFiveBlends

/// Pure, deterministic acceptance-rule tests — no CLLocationManager, no location simulation,
/// so these never depend on unpredictable real-world movement.
struct NearbyE85LocationAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let home = (latitude: 33.4484, longitude: -112.0740) // Phoenix

    @Test func firstEverFixIsAlwaysAccepted() {
        let decision = NearbyE85LocationAcceptance.decision(
            newLatitude: home.latitude, newLongitude: home.longitude, newHorizontalAccuracyMeters: 50,
            newTimestamp: now, previousLatitude: nil, previousLongitude: nil, previousAcceptedAt: nil, now: now)
        #expect(decision == .accept)
    }

    @Test func smallGPSJitterIsRejected() {
        // ~160 ft north — well under the 0.5 mi movement floor, and the previous fix is recent.
        let decision = NearbyE85LocationAcceptance.decision(
            newLatitude: home.latitude + 0.0005, newLongitude: home.longitude, newHorizontalAccuracyMeters: 20,
            newTimestamp: now, previousLatitude: home.latitude, previousLongitude: home.longitude,
            previousAcceptedAt: now.addingTimeInterval(-60), now: now)
        #expect(decision == .rejectInsignificantMovement)
    }

    @Test func meaningfulMovementIsAccepted() {
        // ~2 miles east.
        let decision = NearbyE85LocationAcceptance.decision(
            newLatitude: home.latitude, newLongitude: home.longitude + 0.03, newHorizontalAccuracyMeters: 50,
            newTimestamp: now, previousLatitude: home.latitude, previousLongitude: home.longitude,
            previousAcceptedAt: now.addingTimeInterval(-60), now: now)
        #expect(decision == .accept)
    }

    @Test func movementAtOrAboveTheThresholdIsAccepted() {
        // Nudge north, degree by degree fraction, until the acceptance function's own distance
        // calculation reports at least the movement threshold — avoids hard-coding an
        // approximate miles-per-degree conversion that could drift from CLLocation's own
        // geodesic distance calculation.
        var latitudeOffset = 0.006
        while NearbyE85LocationAcceptance.distanceMiles(fromLatitude: home.latitude, longitude: home.longitude,
                                                          toLatitude: home.latitude + latitudeOffset, longitude: home.longitude)
                < NearbyE85LocationAcceptance.minimumMovementMiles {
            latitudeOffset += 0.001
        }
        let decision = NearbyE85LocationAcceptance.decision(
            newLatitude: home.latitude + latitudeOffset, newLongitude: home.longitude, newHorizontalAccuracyMeters: 50,
            newTimestamp: now, previousLatitude: home.latitude, previousLongitude: home.longitude,
            previousAcceptedAt: now.addingTimeInterval(-60), now: now)
        #expect(decision == .accept)
    }

    @Test func poorHorizontalAccuracyIsRejectedRegardlessOfMovement() {
        for accuracy in [-1.0, Double.nan, Double.infinity, 5_001.0] {
            let decision = NearbyE85LocationAcceptance.decision(
                newLatitude: home.latitude + 1, newLongitude: home.longitude, newHorizontalAccuracyMeters: accuracy,
                newTimestamp: now, previousLatitude: home.latitude, previousLongitude: home.longitude,
                previousAcceptedAt: now.addingTimeInterval(-60), now: now)
            #expect(decision == .rejectPoorAccuracy)
        }
    }

    @Test func staleAcceptedFixIsAcceptedDespiteInsignificantMovement() {
        // Same tiny jitter as smallGPSJitterIsRejected, but the previous fix is 31 minutes old.
        let decision = NearbyE85LocationAcceptance.decision(
            newLatitude: home.latitude + 0.0005, newLongitude: home.longitude, newHorizontalAccuracyMeters: 20,
            newTimestamp: now, previousLatitude: home.latitude, previousLongitude: home.longitude,
            previousAcceptedAt: now.addingTimeInterval(-31 * 60), now: now)
        #expect(decision == .accept)
    }

    @Test func freshlyAcceptedFixWithInsignificantMovementStaysRejected() {
        let decision = NearbyE85LocationAcceptance.decision(
            newLatitude: home.latitude + 0.0005, newLongitude: home.longitude, newHorizontalAccuracyMeters: 20,
            newTimestamp: now, previousLatitude: home.latitude, previousLongitude: home.longitude,
            previousAcceptedAt: now.addingTimeInterval(-29 * 60), now: now)
        #expect(decision == .rejectInsignificantMovement)
    }
}

/// Pure `reposition(cached:...)` tests — recomputing distances/selection for the already
/// -published stations, with no network access and no CLLocationManager.
struct NearbyE85LocationRefreshCoordinatorRepositionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let home = (latitude: 33.4484, longitude: -112.0740)

    private func station(_ id: String, latitude: Double, longitude: Double, distanceMiles: Double,
                          price: NearbyE85Price? = nil) -> NearbyE85Station {
        .init(id: id, name: id, address: "Address", latitude: latitude, longitude: longitude,
              distanceMiles: distanceMiles, price: price)
    }

    @Test func repositionChangesNearestStationWhenACloserOneNowLeads() {
        let mobil = station("Mobil", latitude: home.latitude, longitude: home.longitude + 0.03, distanceMiles: 2.1)
        let shell = station("Shell", latitude: home.latitude, longitude: home.longitude - 0.06, distanceMiles: 4.0)
        let cached = NearbyE85Snapshot.make(stations: [mobil, shell], radiusMiles: 25, updatedAt: now, locationAt: now,
                                            userLatitude: home.latitude, userLongitude: home.longitude)
        #expect(cached.stations.first?.id == "Mobil")

        // Drive west, past Shell, so Shell is now the closer station.
        let newLongitude = home.longitude - 0.07
        let repositioned = NearbyE85LocationRefreshCoordinator.reposition(
            cached: cached, newLatitude: home.latitude, newLongitude: newLongitude, locationAt: now.addingTimeInterval(600))
        #expect(repositioned?.stations.first?.id == "Shell")
    }

    @Test func repositionDropsStationsThatFallOutsideTheOriginalRadius() {
        let near = station("Near", latitude: home.latitude, longitude: home.longitude, distanceMiles: 0.1)
        let far = station("Far", latitude: home.latitude, longitude: home.longitude + 0.02, distanceMiles: 1.5)
        let cached = NearbyE85Snapshot.make(stations: [near, far], radiusMiles: 2, updatedAt: now, locationAt: now,
                                            userLatitude: home.latitude, userLongitude: home.longitude)
        #expect(cached.stations.count == 2)

        // Move far enough east that "Near" (now several miles behind us) exceeds the original
        // 2-mile radius while "Far" (just ahead) still doesn't — the cluster should shrink to
        // just one station.
        let repositioned = NearbyE85LocationRefreshCoordinator.reposition(
            cached: cached, newLatitude: home.latitude, newLongitude: home.longitude + 0.05, locationAt: now.addingTimeInterval(600))
        #expect(repositioned?.stations.count == 1)
        #expect(repositioned?.stations.first?.id == "Far")
    }

    @Test func sameNearestStationStillUpdatesDistanceForAMaterialMove() {
        let mobil = station("Mobil", latitude: home.latitude, longitude: home.longitude, distanceMiles: 0.1)
        let cached = NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: now, locationAt: now,
                                            userLatitude: home.latitude, userLongitude: home.longitude)
        let repositioned = NearbyE85LocationRefreshCoordinator.reposition(
            cached: cached, newLatitude: home.latitude, newLongitude: home.longitude + 0.03, locationAt: now.addingTimeInterval(600))
        #expect(repositioned?.stations.first?.id == "Mobil")
        #expect((repositioned?.stations.first?.distanceMiles ?? 0) > 1.5)
    }

    @Test func repositionPreservesPriceAndReportedAtIndependentlyOfLocation() {
        let reportedAt = now.addingTimeInterval(-2 * 86_400)
        let priced = station("Mobil", latitude: home.latitude, longitude: home.longitude, distanceMiles: 0.1,
                              price: .init(dollarsPerGallon: 3.89, reportedAt: reportedAt, source: .community))
        let cached = NearbyE85Snapshot.make(stations: [priced], radiusMiles: 25, updatedAt: now, locationAt: now,
                                            userLatitude: home.latitude, userLongitude: home.longitude)
        let repositioned = NearbyE85LocationRefreshCoordinator.reposition(
            cached: cached, newLatitude: home.latitude + 0.02, newLongitude: home.longitude, locationAt: now.addingTimeInterval(600))
        #expect(repositioned?.stations.first?.price?.dollarsPerGallon == 3.89)
        #expect(repositioned?.stations.first?.price?.reportedAt == reportedAt)
    }

    @Test func repositionUpdatesLocationAtWithoutTouchingUpdatedAt() {
        let mobil = station("Mobil", latitude: home.latitude, longitude: home.longitude, distanceMiles: 0.1)
        let searchTime = now.addingTimeInterval(-3600) // the live network search happened an hour ago
        let cached = NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: searchTime, locationAt: searchTime,
                                            userLatitude: home.latitude, userLongitude: home.longitude)
        let newLocationAt = now
        let repositioned = NearbyE85LocationRefreshCoordinator.reposition(
            cached: cached, newLatitude: home.latitude + 0.02, newLongitude: home.longitude, locationAt: newLocationAt)
        #expect(repositioned?.locationAt == newLocationAt)
        #expect(repositioned?.updatedAt == searchTime) // never bumped by a reposition-only update
    }

    @Test func repositionReturnsNilWhenEveryStationFallsOutsideRadius() {
        let mobil = station("Mobil", latitude: home.latitude, longitude: home.longitude, distanceMiles: 0.1)
        let cached = NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 5, updatedAt: now, locationAt: now,
                                            userLatitude: home.latitude, userLongitude: home.longitude)
        // ~60 miles away — nothing in the cached cluster remains within a 5-mile radius.
        let repositioned = NearbyE85LocationRefreshCoordinator.reposition(
            cached: cached, newLatitude: home.latitude, newLongitude: home.longitude + 1.0, locationAt: now.addingTimeInterval(600))
        #expect(repositioned == nil)
    }
}

/// `handle(location:)` integration tests, exercising the cache read → decide → reposition →
/// publish pipeline end to end against a temporary file (never the real App Group container).
@MainActor
struct NearbyE85LocationRefreshCoordinatorHandleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let home = (latitude: 33.4484, longitude: -112.0740)

    private func station(_ id: String, longitudeOffset: Double, distanceMiles: Double) -> NearbyE85Station {
        .init(id: id, name: id, address: "Address", latitude: home.latitude, longitude: home.longitude + longitudeOffset,
              distanceMiles: distanceMiles, price: .init(dollarsPerGallon: 3.89, reportedAt: now, source: .community))
    }

    private func makeCache() -> (NearbyE85Cache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("snapshot.json")
        return (NearbyE85Cache(fileURL: file), directory)
    }

    private func makeLocation(latitude: Double, longitude: Double, horizontalAccuracy: CLLocationAccuracy = 50,
                               timestamp: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), altitude: 0,
                   horizontalAccuracy: horizontalAccuracy, verticalAccuracy: -1, timestamp: timestamp)
    }

    @Test func handleIgnoresAnUpdateWhenNoSnapshotIsCachedYet() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = makeLocation(latitude: home.latitude, longitude: home.longitude, timestamp: now)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: now)
        #expect(cache.read(now: now) == nil)
    }

    @Test func handleIgnoresAnUpdateWhenCachedStateIsPermissionRequired() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        try cache.write(.permissionRequired(at: now), now: now)
        let location = makeLocation(latitude: home.latitude + 1, longitude: home.longitude, timestamp: now.addingTimeInterval(600))
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: now.addingTimeInterval(600))
        #expect(cache.read(now: now.addingTimeInterval(600))?.state == .permissionRequired)
    }

    @Test func handlePublishesARepositionedSnapshotOnAcceptedMovement() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mobil = station("Mobil", longitudeOffset: 0.03, distanceMiles: 2.1)
        let shell = station("Shell", longitudeOffset: -0.06, distanceMiles: 4.0)
        let original = NearbyE85Snapshot.make(stations: [mobil, shell], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: home.latitude, userLongitude: home.longitude)
        try cache.write(original, now: now)

        // Drive several miles west, past Shell.
        let laterNow = now.addingTimeInterval(600)
        let location = makeLocation(latitude: home.latitude, longitude: home.longitude - 0.07, timestamp: laterNow)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: laterNow)

        let updated = cache.read(now: laterNow)
        #expect(updated?.stations.first?.id == "Shell")
        #expect(updated?.locationAt == laterNow)
        #expect(updated?.userCoordinate?.longitude == home.longitude - 0.07)
        // The price attached to Shell must be untouched by the reposition.
        #expect(updated?.stations.first?.price?.reportedAt == now)
    }

    @Test func handleDoesNotRepublishOnInsignificantMovement() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mobil = station("Mobil", longitudeOffset: 0, distanceMiles: 0.1)
        let original = NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: home.latitude, userLongitude: home.longitude)
        try cache.write(original, now: now)

        let laterNow = now.addingTimeInterval(60)
        // ~160 ft north — parking-lot-scale jitter.
        let location = makeLocation(latitude: home.latitude + 0.0005, longitude: home.longitude,
                                     horizontalAccuracy: 20, timestamp: laterNow)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: laterNow)

        #expect(cache.read(now: laterNow) == original)
    }
}

/// StationLocationManager's significant-location-change plumbing — exercised directly against
/// the delegate methods rather than real location simulation, so these are deterministic.
@MainActor
struct StationLocationManagerSignificantLocationTests {
    @Test func significantLocationUpdateHookFiresOnDidUpdateLocations() {
        let manager = StationLocationManager()
        var received: CLLocation?
        manager.onSignificantLocationUpdate = { received = $0 }
        let location = CLLocation(latitude: 33.45, longitude: -112.07)
        manager.locationManager(CLLocationManager(), didUpdateLocations: [location])
        #expect(received?.coordinate.latitude == 33.45)
        #expect(received?.coordinate.longitude == -112.07)
    }

    @Test func monitoringNeverStartsWithoutAuthorization() {
        // A freshly constructed manager in the test/simulator process has not been granted
        // location authorization, so this must stay a no-op — the "no location authorization"
        // case for significant-location monitoring.
        let manager = StationLocationManager()
        manager.startSignificantLocationMonitoringIfPossible()
        #expect(manager.isMonitoringSignificantLocationChanges == false)
    }

    @Test func stoppingWhenNeverStartedIsHarmless() {
        let manager = StationLocationManager()
        manager.stopSignificantLocationMonitoring()
        #expect(manager.isMonitoringSignificantLocationChanges == false)
    }
}

import CoreLocation
import Foundation
import Testing
@testable import EightyFiveBlends

/// Fix-quality-only checks: accuracy, staleness at receipt, and duplicate redelivery detection.
/// None of these depend on presentation — see NearbyE85LocationPublishDecisionTests below for
/// the hybrid movement/presentation policy that decides whether an acceptable fix is actually
/// worth publishing.
struct NearbyE85LocationFixQualityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let home = (latitude: 33.4484, longitude: -112.0740) // Phoenix

    @Test func firstEverFixWithNoPreviousCoordinateIsAcceptable() {
        let decision = NearbyE85LocationAcceptance.fixQuality(
            newLatitude: home.latitude, newLongitude: home.longitude, newHorizontalAccuracyMeters: 50,
            newTimestamp: now, previousLatitude: nil, previousLongitude: nil, previousAcceptedAt: nil, now: now)
        #expect(decision == .acceptable)
    }

    @Test func poorAccuracyIsRejectedRegardlessOfEverythingElse() {
        for accuracy in [-1.0, Double.nan, Double.infinity, 5_001.0] {
            let decision = NearbyE85LocationAcceptance.fixQuality(
                newLatitude: home.latitude, newLongitude: home.longitude, newHorizontalAccuracyMeters: accuracy,
                newTimestamp: now, previousLatitude: home.latitude, previousLongitude: home.longitude,
                previousAcceptedAt: now.addingTimeInterval(-60), now: now)
            #expect(decision == .rejectPoorAccuracy)
        }
    }

    @Test func fixOlderThanTenMinutesAtReceiptIsRejectedAsStale() {
        let decision = NearbyE85LocationAcceptance.fixQuality(
            newLatitude: home.latitude, newLongitude: home.longitude, newHorizontalAccuracyMeters: 50,
            newTimestamp: now.addingTimeInterval(-11 * 60), previousLatitude: nil, previousLongitude: nil,
            previousAcceptedAt: nil, now: now)
        #expect(decision == .rejectStaleFix)
    }

    @Test func fixWithinTenMinutesAtReceiptIsAcceptable() {
        let decision = NearbyE85LocationAcceptance.fixQuality(
            newLatitude: home.latitude, newLongitude: home.longitude, newHorizontalAccuracyMeters: 50,
            newTimestamp: now.addingTimeInterval(-9 * 60), previousLatitude: nil, previousLongitude: nil,
            previousAcceptedAt: nil, now: now)
        #expect(decision == .acceptable)
    }

    @Test func identicalCoordinateNoNewerThanThePreviousAcceptedFixIsRejectedAsDuplicate() {
        let decision = NearbyE85LocationAcceptance.fixQuality(
            newLatitude: home.latitude, newLongitude: home.longitude, newHorizontalAccuracyMeters: 50,
            newTimestamp: now.addingTimeInterval(-30), previousLatitude: home.latitude, previousLongitude: home.longitude,
            previousAcceptedAt: now, now: now)
        #expect(decision == .rejectDuplicateFix)
    }

    @Test func identicalCoordinateStrictlyNewerThanThePreviousAcceptedFixIsNotADuplicate() {
        let decision = NearbyE85LocationAcceptance.fixQuality(
            newLatitude: home.latitude, newLongitude: home.longitude, newHorizontalAccuracyMeters: 50,
            newTimestamp: now.addingTimeInterval(30), previousLatitude: home.latitude, previousLongitude: home.longitude,
            previousAcceptedAt: now, now: now)
        #expect(decision == .acceptable)
    }

    @Test func nearbyButNotIdenticalCoordinateIsNotADuplicateEvenWhenNotNewer() {
        // ~330 ft away — a genuinely different fix, not a redelivery, even though its timestamp
        // happens not to be newer than the last accepted one.
        let decision = NearbyE85LocationAcceptance.fixQuality(
            newLatitude: home.latitude + 0.001, newLongitude: home.longitude, newHorizontalAccuracyMeters: 50,
            newTimestamp: now.addingTimeInterval(-30), previousLatitude: home.latitude, previousLongitude: home.longitude,
            previousAcceptedAt: now, now: now)
        #expect(decision == .acceptable)
    }
}

/// The hybrid publish-decision policy: raw movement is only one signal among several — nearest-
/// station identity, the visible station cluster, and the nearest station's own displayed
/// distance all matter just as much, subject to a minimum publish interval. Feeds `movedMiles`
/// directly rather than deriving it from lat/lon degree math, so these stay exact regardless of
/// CLLocation's own geodesic rounding.
struct NearbyE85LocationPublishDecisionTests {
    private func decide(movedMiles: Double?, timeSinceLastAccepted: TimeInterval? = 60,
                         timeSinceLastPublish: TimeInterval? = 600,
                         previousNearest: String? = "Mobil", newNearest: String? = "Mobil",
                         previousDistance: Double? = 2.0, newDistance: Double? = 2.0,
                         previousCluster: Set<String> = ["Mobil"], newCluster: Set<String> = ["Mobil"],
                         isManualRefresh: Bool = false) -> NearbyE85LocationAcceptance.PublishDecision {
        NearbyE85LocationAcceptance.publishDecision(
            movedMiles: movedMiles, timeSinceLastAccepted: timeSinceLastAccepted, timeSinceLastPublish: timeSinceLastPublish,
            previousNearestStationID: previousNearest, newNearestStationID: newNearest,
            previousNearestDistanceMiles: previousDistance, newNearestDistanceMiles: newDistance,
            previousStationIDs: previousCluster, newStationIDs: newCluster, isManualRefresh: isManualRefresh)
    }

    @Test func firstEverLocationWithNoPreviousCoordinateAlwaysPublishes() {
        #expect(decide(movedMiles: nil) == .publish)
    }

    @Test func fiftyFootJitterAloneIsSuppressed() {
        #expect(decide(movedMiles: 50.0 / 5_280.0) == .suppressInsignificantMovement)
    }

    @Test func oneHundredFiftyFootMovementAloneIsSuppressed() {
        #expect(decide(movedMiles: 150.0 / 5_280.0) == .suppressInsignificantMovement)
    }

    @Test(arguments: [250.0, 500.0, 1_056.0 /* 0.2 mi */, 1_584.0 /* 0.3 mi */])
    func movementBelowTheLargeThresholdAloneIsSuppressedWithoutAPresentationChange(feet: Double) {
        #expect(decide(movedMiles: feet / 5_280.0) == .suppressInsignificantMovement)
    }

    @Test(arguments: [250.0, 500.0, 1_056.0, 1_584.0])
    func movementBelowTheLargeThresholdWithAMaterialDistanceChangePublishes(feet: Double) {
        // Mobil 3.1 mi -> 1.4 mi, same station still nearest.
        #expect(decide(movedMiles: feet / 5_280.0, previousDistance: 3.1, newDistance: 1.4) == .publish)
    }

    @Test func belowTheJitterFloorSuppressesEvenAlongsideAMaterialDistanceChange() {
        // 150 ft is below the jitter floor — a "material" distance delta at this scale is far
        // more likely a stale/hardcoded fixture value than real movement, so it must not count.
        #expect(decide(movedMiles: 150.0 / 5_280.0, previousDistance: 3.1, newDistance: 1.4) == .suppressInsignificantMovement)
    }

    @Test func halfMileMovementAlonePublishesEvenWithoutAPresentationChange() {
        #expect(decide(movedMiles: 0.5) == .publish)
    }

    @Test func sameNearestStationWithNegligibleDistanceChangeIsSuppressed() {
        #expect(decide(movedMiles: 500.0 / 5_280.0, previousDistance: 2.0, newDistance: 2.05) == .suppressInsignificantMovement)
    }

    @Test func sameNearestStationWithMeaningfulDistanceChangePublishes() {
        #expect(decide(movedMiles: 500.0 / 5_280.0, previousDistance: 3.1, newDistance: 1.4) == .publish)
    }

    @Test func nearestStationChangingPublishesRegardlessOfHowLittleTheUserMoved() {
        #expect(decide(movedMiles: 10.0 / 5_280.0, previousNearest: "Mobil", newNearest: "Shell") == .publish)
    }

    @Test func visibleStationClusterChangingPublishesEvenWithTheSameNearestStation() {
        #expect(decide(movedMiles: 10.0 / 5_280.0, previousCluster: ["Mobil", "Shell"], newCluster: ["Mobil", "QuikTrip"]) == .publish)
    }

    @Test func tenToFifteenMinuteStalenessPublishesWithoutMovement() {
        #expect(decide(movedMiles: 0, timeSinceLastAccepted: 13 * 60) == .publish)
    }

    @Test func justUnderTheStalenessThresholdStillSuppressesWithoutMovement() {
        #expect(decide(movedMiles: 0, timeSinceLastAccepted: 11 * 60) == .suppressInsignificantMovement)
    }

    @Test func ordinaryRateLimitSuppressesAFreshLargeMovementTooSoonAfterTheLastPublish() {
        #expect(decide(movedMiles: 0.6, timeSinceLastPublish: 30) == .suppressRateLimited)
    }

    @Test func rateLimitDoesNotApplyOnceTheMinimumIntervalHasElapsed() {
        #expect(decide(movedMiles: 0.6, timeSinceLastPublish: 200) == .publish)
    }

    @Test func nearestStationChangeBypassesTheRateLimit() {
        #expect(decide(movedMiles: 10.0 / 5_280.0, timeSinceLastPublish: 5, previousNearest: "Mobil", newNearest: "Shell") == .publish)
    }

    @Test func clusterChangeBypassesTheRateLimit() {
        #expect(decide(movedMiles: 10.0 / 5_280.0, timeSinceLastPublish: 5,
                       previousCluster: ["Mobil"], newCluster: ["Mobil", "Shell"]) == .publish)
    }

    @Test func stalenessBypassesTheRateLimit() {
        #expect(decide(movedMiles: 0, timeSinceLastAccepted: 13 * 60, timeSinceLastPublish: 5) == .publish)
    }

    @Test func manualRefreshBypassesTheRateLimitButNeverTheContentCheck() {
        // Nothing materially different — a manual tap must not fake freshness.
        #expect(decide(movedMiles: 50.0 / 5_280.0, timeSinceLastPublish: 5, isManualRefresh: true) == .suppressInsignificantMovement)
        // Something IS materially different, seconds after the last publish — an explicit tap
        // must not be swallowed by the ordinary anti-jitter rate limit.
        #expect(decide(movedMiles: 500.0 / 5_280.0, timeSinceLastPublish: 5,
                       previousDistance: 3.1, newDistance: 1.4, isManualRefresh: true) == .publish)
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

    @Test func handlePublishesOnANearestStationChangeEvenSecondsAfterTheLastPublish() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Mobil (east of home) is barely nearer than Shell (west of home) initially.
        let mobil = station("Mobil", longitudeOffset: 0.0008, distanceMiles: 0.046)
        let shell = station("Shell", longitudeOffset: -0.0012, distanceMiles: 0.069)
        let original = NearbyE85Snapshot.make(stations: [mobil, shell], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: home.latitude, userLongitude: home.longitude)
        try cache.write(original, now: now)
        #expect(original.stations.first?.id == "Mobil")

        // A small westward nudge (well under the ordinary jitter floor) is just enough to flip
        // which of the two nearly-equidistant stations is nearest, only 5 seconds after the
        // last publish — comfortably inside the ordinary rate limit, which a genuine
        // nearest-station change must bypass regardless of how little the user physically moved.
        let laterNow = now.addingTimeInterval(5)
        let location = makeLocation(latitude: home.latitude, longitude: home.longitude - 0.0005, timestamp: laterNow)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: laterNow)

        #expect(cache.read(now: laterNow)?.stations.first?.id == "Shell")
    }

    @Test func handleSuppressesAnOrdinaryLargeMovementPublishTooSoonAfterTheLastOne() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mobil = station("Mobil", longitudeOffset: 0, distanceMiles: 0.1)
        let original = NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: home.latitude, userLongitude: home.longitude)
        try cache.write(original, now: now)

        // Several miles of movement, but only 30 seconds after the snapshot was last published —
        // the ordinary rate limit must still apply since nothing else (nearest station, cluster,
        // staleness) qualifies for a bypass.
        let laterNow = now.addingTimeInterval(30)
        let location = makeLocation(latitude: home.latitude, longitude: home.longitude - 0.07, timestamp: laterNow)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: laterNow)

        #expect(cache.read(now: laterNow) == original)
    }

    @Test func handleManualRefreshBypassesTheRateLimitWhenSomethingActuallyChanged() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mobil = station("Mobil", longitudeOffset: 0, distanceMiles: 0.1)
        let original = NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: home.latitude, userLongitude: home.longitude)
        try cache.write(original, now: now)

        let laterNow = now.addingTimeInterval(30) // well inside the ordinary rate limit
        let location = makeLocation(latitude: home.latitude, longitude: home.longitude - 0.07, timestamp: laterNow)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: laterNow, isManualRefresh: true)

        #expect(cache.read(now: laterNow)?.userCoordinate?.longitude == home.longitude - 0.07)
        #expect(cache.read(now: laterNow)?.locationAt == laterNow)
    }

    @Test func handleManualRefreshWithNothingMaterialDifferentStaysHonestlyStale() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mobil = station("Mobil", longitudeOffset: 0, distanceMiles: 0.1)
        let original = NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: home.latitude, userLongitude: home.longitude)
        try cache.write(original, now: now)

        let laterNow = now.addingTimeInterval(30)
        // The exact same coordinate redelivered — no movement, no presentation change at all —
        // must not fake a newer "Updated" timestamp just because the user tapped refresh.
        let location = makeLocation(latitude: home.latitude, longitude: home.longitude, timestamp: laterNow)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: laterNow, isManualRefresh: true)

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

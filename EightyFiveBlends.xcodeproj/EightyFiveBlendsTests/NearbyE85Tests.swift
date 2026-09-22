import Foundation
import MapKit
import Testing
@testable import EightyFiveBlends

struct NearbyE85Tests {
    private let now = Date(timeIntervalSince1970: 1_788_600_000)
    private func station(_ id: String = "station|a & b", miles: Double = 1, price: NearbyE85Price? = nil,
                          ethanol: NearbyE85Ethanol? = nil) -> NearbyE85Station {
        .init(id: id, name: "E85 station", address: "123 Main St", latitude: 33.45, longitude: -112.07,
              distanceMiles: miles, price: price, ethanol: ethanol)
    }
    private func snapshot(stations: [NearbyE85Station]? = nil) -> NearbyE85Snapshot {
        .make(stations: stations ?? [station()], radiusMiles: 25, updatedAt: now, locationAt: now)
    }

    @Test func nearestValidStationsAreSortedDeduplicatedAndBounded() {
        let result = snapshot(stations: [station("far", miles: 26), station("bad", miles: .nan),
            station("c", miles: 3), station("a", miles: 1), station("b", miles: 2), station("a", miles: 4), station("d", miles: 4)])
        #expect(result.stations.map(\.id) == ["a", "b", "c"])
        #expect(result.stations[0].price == nil)
        #expect(result.isValid(at: now))
    }
    @Test func zeroDistanceIsValidAndUnknownCoordinatesAreRejected() {
        #expect(snapshot(stations: [station(miles: 0)]).stations.count == 1)
        let bad = NearbyE85Station(id: "bad", name: "Bad", address: "", latitude: 0, longitude: 0, distanceMiles: 0, price: nil)
        #expect(snapshot(stations: [bad]).state == .noStations)
    }
    @Test func userCoordinateIsKeptWhenValidAndDroppedWhenNot() {
        let withCoordinate = NearbyE85Snapshot.make(stations: [station()], radiusMiles: 25, updatedAt: now, locationAt: now,
                                                     userLatitude: 33.44, userLongitude: -112.08)
        #expect(withCoordinate.userCoordinate?.latitude == 33.44)
        #expect(withCoordinate.userCoordinate?.longitude == -112.08)
        #expect(withCoordinate.isValid(at: now))

        let nullIsland = NearbyE85Snapshot.make(stations: [station()], radiusMiles: 25, updatedAt: now, locationAt: now,
                                                 userLatitude: 0, userLongitude: 0)
        #expect(nullIsland.userCoordinate == nil)

        let missing = NearbyE85Snapshot.make(stations: [station()], radiusMiles: 25, updatedAt: now, locationAt: now)
        #expect(missing.userCoordinate == nil)
        #expect(missing.isValid(at: now))
    }
    @Test func mismatchedUserCoordinateHalfIsInvalid() {
        let value = NearbyE85Snapshot(version: NearbyE85Snapshot.schemaVersion, state: .ready, stations: [station()],
                                       radiusMiles: 25, updatedAt: now, locationAt: now, userLatitude: 33.44, userLongitude: nil)
        #expect(!value.isValid(at: now))
    }
    @Test func emptyResultsPermissionAndMissingCacheAreDistinct() {
        #expect(snapshot(stations: []).state == .noStations)
        #expect(NearbyE85Snapshot.permissionRequired(at: now).state == .permissionRequired)
        #expect(NearbyE85Cache(fileURL: nil).read(now: now) == nil)
        #expect(throws: (any Error).self) { try NearbyE85Cache(fileURL: nil).write(snapshot(), now: now) }
    }
    @Test func oldLocationExpiresEvenWhenSearchJustFinished() {
        let value = NearbyE85Snapshot.make(stations: [station()], radiusMiles: 25, updatedAt: now,
                                           locationAt: now.addingTimeInterval(-NearbyE85Snapshot.expiresAfter))
        #expect(!value.isValid(at: now))
    }
    @Test func freshnessAndExpiryHaveExplicitBoundaries() {
        #expect(!snapshot().isStale(at: now.addingTimeInterval(3599)))
        #expect(snapshot().isStale(at: now.addingTimeInterval(3600)))
        #expect(snapshot().isValid(at: now.addingTimeInterval(86399)))
        #expect(!snapshot().isValid(at: now.addingTimeInterval(86400)))
    }
    @Test func invalidPricesNeverBecomeZeroOrFreshPrices() {
        for amount in [0, -1, .nan, .infinity, 999] {
            #expect(NearbyE85Price.validated(amount, reportedAt: now, source: .community, now: now) == nil)
        }
        let future = NearbyE85Price.validated(2.89, reportedAt: now.addingTimeInterval(600), source: .community, now: now)
        #expect(future?.reportedAt == nil)
        #expect(future?.status(at: now) == "Age unknown")
        let old = NearbyE85Price.validated(2.89, reportedAt: now.addingTimeInterval(-20 * 86400), source: .saved, now: now)
        #expect(old?.status(at: now) == "Stale · 20d ago")
    }
    @Test func cacheRoundTripRevocationCorruptionAndVersioning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        let cache = NearbyE85Cache(fileURL: file)
        #expect(cache.read(now: now) == nil)
        #expect(try cache.write(snapshot(), now: now))
        #expect(cache.read(now: now) == snapshot())
        #expect(try !cache.write(snapshot(), now: now))
        #expect(cache.read(now: now.addingTimeInterval(86400)) == nil)
        try cache.write(.permissionRequired(at: now), now: now)
        #expect(cache.read(now: now)?.stations.isEmpty == true)
        try Data("invalid json".utf8).write(to: file)
        #expect(cache.read(now: now) == nil)
        let unknown = NearbyE85Snapshot(version: 99, state: .ready, stations: [station()], radiusMiles: 25, updatedAt: now, locationAt: now)
        try JSONEncoder().encode(unknown).write(to: file)
        #expect(cache.read(now: now) == nil)
        try Data(repeating: 0, count: 65_537).write(to: file)
        #expect(cache.read(now: now) == nil)
    }
    @Test func readingDoesNotRefreshTimestampAndInvalidWritesPreserveLastGoodSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NearbyE85Cache(fileURL: directory.appendingPathComponent("snapshot.json"))
        try cache.write(snapshot(), now: now)
        #expect(cache.read(now: now.addingTimeInterval(100))?.updatedAt == now)
        let bad = NearbyE85Snapshot(version: 1, state: .noStations, stations: [station()], radiusMiles: 25, updatedAt: now, locationAt: now)
        #expect(throws: (any Error).self) { try cache.write(bad, now: now) }
        #expect(cache.read(now: now) == snapshot())
    }
    @Test func directionsLinksRoundTripAndRejectMalformedOrForeignURLs() {
        let key = "station|a & b?#/é"
        let link = NearbyE85DeepLink.directionsURL(stationID: key, scheme: "e85blends")
        #expect(NearbyE85DeepLink.parse(link, scheme: "e85blends") == .directions(stationID: key))
        #expect(NearbyE85DeepLink.parse(NearbyE85DeepLink.stationsURL(scheme: "e85blends"), scheme: "e85blends") == .stations)
        for raw in ["https://stations", "e85blends://evil", "e85blends://stations/path", "e85blends://stations?id=a",
                    "e85blends://directions/station?id=", "e85blends://directions/station?id=a&id=b",
                    "e85blends://directions/station?other=a", "e85blends://directions/other?id=a",
                    "e85blends://directions/station#test", "e85blends-internal://stations"] {
            #expect(NearbyE85DeepLink.parse(URL(string: raw)!, scheme: "e85blends") == nil)
        }
    }
    @Test func publicationRejectsTypedSearchesRevokedPermissionTravelAndRestoredPreviews() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("search.json")
        let store = StationsRecentSearchStore(persistenceURL: url)
        let center = StationCoordinate(latitude: 33.45, longitude: -112.07)
        store.recordCurrentLocationSearchResult(stations: [], center: center, radiusMiles: 25,
                                               fetchedAt: now, locationAt: now)
        func eligible(_ source: StationsRecentSearchStore, current: Bool = true, authorized: Bool = true,
                      coordinate: StationCoordinate? = nil, fix: Date? = nil) -> StationsSearchSnapshot? {
            NearbyE85Publisher.eligibleSearch(from: source, isCurrentLocationSearch: current, authorized: authorized,
                                             coordinate: coordinate ?? center, fixTimestamp: fix ?? now, now: now)
        }
        #expect(eligible(store) != nil)
        #expect(eligible(store, current: false) == nil)
        #expect(eligible(store, authorized: false) == nil)
        #expect(eligible(store, coordinate: .init(latitude: 40, longitude: -80)) == nil)
        #expect(eligible(store, fix: now.addingTimeInterval(-181)) == nil)
        #expect(eligible(store, fix: now.addingTimeInterval(600)) == nil)
        #expect(eligible(StationsRecentSearchStore(persistenceURL: url)) == nil)
    }

    // MARK: - 85Blends 2.4.0 widget ethanol polish

    @Test func ethanolQualifiesOnlyWhenCurrentAndWithinPhysicalRange() {
        for percentage in [-1, 101, Double.nan, Double.infinity, -Double.infinity] {
            #expect(NearbyE85Ethanol.validated(percentage: percentage, reportedAt: now, now: now) == nil)
        }
        #expect(NearbyE85Ethanol.validated(percentage: nil, reportedAt: now, now: now) == nil)
        #expect(NearbyE85Ethanol.validated(percentage: 78, reportedAt: nil, now: now) == nil)
        // Exactly at the 14-day bar still qualifies (StationDataValidation.isStale is `days >
        // thresholdDays`, so 14 itself is not yet stale) — one day older does not.
        let atBoundary = NearbyE85Ethanol.validated(percentage: 78, reportedAt: now.addingTimeInterval(-14 * 86400), now: now)
        #expect(atBoundary?.percentage == 78)
        #expect(NearbyE85Ethanol.validated(percentage: 78, reportedAt: now.addingTimeInterval(-15 * 86400), now: now) == nil)
        // A report meaningfully in the future fails StationDataValidation.isValidTimestamp and is
        // never valid. A full day is used deliberately, well beyond isValidTimestamp's own
        // 300-second clock-skew tolerance, so this stays an unambiguous future-report case even
        // if that tolerance is ever retuned — not a borderline clock-skew one.
        #expect(NearbyE85Ethanol.validated(percentage: 78, reportedAt: now.addingTimeInterval(86400), now: now) == nil)
    }

    /// A separate, deliberately independent concern from physical validity above — mirrors
    /// CommunityEthanolValidation's own "hard validity vs. expected-range classification" split.
    /// A recent, otherwise-valid report outside the 51...83 "expected E85 range" is real
    /// (CommunityEthanolValidation never rejects it — see requiresConfirmation), just not
    /// eligible for the widget: this release has no room for the confirmation/disclaimer context
    /// the full Stations UI gives an out-of-range reading, so the widget simply omits it rather
    /// than showing an unqualified number.
    @Test func ethanolOutsideExpectedE85RangeIsOmittedEvenWhenRecentAndOtherwiseValid() {
        #expect(NearbyE85Ethanol.validated(percentage: 78, reportedAt: now, now: now)?.percentage == 78) // recent, normal -> included
        #expect(NearbyE85Ethanol.validated(percentage: 70, reportedAt: now, now: now)?.percentage == 70) // recent, normal -> included
        #expect(NearbyE85Ethanol.validated(percentage: 51, reportedAt: now, now: now)?.percentage == 51) // lower bound -> included
        #expect(NearbyE85Ethanol.validated(percentage: 83, reportedAt: now, now: now)?.percentage == 83) // upper bound -> included
        // requiresConfirmation == true under CommunityEthanolValidation -> omitted from the widget,
        // even though the value is physically valid, recent, and never rejected by the main app.
        for requiresConfirmation in [0.0, 10.0, 50.9, 83.1, 95.0, 100.0] {
            #expect(NearbyE85Ethanol.validated(percentage: requiresConfirmation, reportedAt: now, now: now) == nil)
        }
    }

    @Test func ethanolLabelTextMatchesMainAppsWholeNumberAndOneDecimalFormatting() {
        #expect(NearbyE85Ethanol.validated(percentage: 78, reportedAt: now, now: now)?.labelText == "E78")
        #expect(NearbyE85Ethanol.validated(percentage: 72.5, reportedAt: now, now: now)?.labelText == "E72.5")
        // Rounds to one decimal place, never showing a trailing ".0" once rounded to a whole number.
        #expect(NearbyE85Ethanol.validated(percentage: 70.04, reportedAt: now, now: now)?.labelText == "E70")
    }

    /// The Large widget's on-screen badge text must say "Reported", not a bare percentage — this
    /// is the one line item from the correction pass that isn't otherwise provable from a
    /// screenshot alone, so it gets a direct, rendering-independent assertion.
    @Test func ethanolBadgeTextAlwaysCarriesTheReportedPrefixOnScreen() {
        #expect(NearbyE85Ethanol.validated(percentage: 78, reportedAt: now, now: now)?.badgeText == "Reported E78")
        #expect(NearbyE85Ethanol.validated(percentage: 72.5, reportedAt: now, now: now)?.badgeText == "Reported E72.5")
    }

    @Test func ethanolAgeTextMatchesTodayAndDaysAgoWording() {
        let fresh = NearbyE85Ethanol.validated(percentage: 78, reportedAt: now, now: now)
        #expect(fresh?.agoText(at: now) == "Today")
        #expect(fresh?.accessibilityAgeText(at: now) == "updated today")
        let threeDaysOld = NearbyE85Ethanol.validated(percentage: 78, reportedAt: now.addingTimeInterval(-3 * 86400), now: now)
        #expect(threeDaysOld?.agoText(at: now) == "3d ago")
        #expect(threeDaysOld?.accessibilityAgeText(at: now) == "updated 3 days ago")
        let oneDayOld = NearbyE85Ethanol.validated(percentage: 78, reportedAt: now.addingTimeInterval(-1 * 86400), now: now)
        #expect(oneDayOld?.accessibilityAgeText(at: now) == "updated 1 day ago")
    }

    @Test func stationEthanolFieldDefaultsToNilForExistingCallSiteCompatibility() {
        // Every pre-existing call site across the app and tests constructs NearbyE85Station
        // without an `ethanol:` argument — confirms that still compiles and still means "none".
        #expect(station().ethanol == nil)
    }

    // Named "physically invalid," not "out of range," to stay distinct from
    // ethanolOutsideExpectedE85RangeIsOmittedEvenWhenRecentAndOtherwiseValid below: 101% fails
    // the 0...100 hard bound outright, unlike a StationDataValidation.expectedE85EthanolRange
    // miss (e.g. 90%), which is physically valid and only omitted from the widget by policy.
    @Test func snapshotValidationRejectsPhysicallyInvalidOrFutureStationEthanol() {
        let good = station(ethanol: .init(percentage: 78, reportedAt: now.addingTimeInterval(-86400)))
        #expect(snapshot(stations: [good]).isValid(at: now))

        // NearbyE85Ethanol.validated(...) is the only normal construction path and already
        // forbids these, but isValid(at:) re-checks independently — the same defense-in-depth
        // isValid already applies to price above, since a snapshot decoded from disk didn't
        // necessarily pass through `validated` at all.
        let outOfRange = NearbyE85Station(id: "bad", name: "Bad", address: "", latitude: 33.45, longitude: -112.07,
                                          distanceMiles: 1, price: nil,
                                          ethanol: NearbyE85Ethanol(percentage: 101, reportedAt: now))
        #expect(!snapshot(stations: [outOfRange]).isValid(at: now))
        // A full day ahead — well beyond isValidTimestamp's 300-second clock-skew tolerance —
        // so this is unambiguously a future report, not a borderline clock-skew case.
        let future = NearbyE85Station(id: "bad2", name: "Bad", address: "", latitude: 33.45, longitude: -112.07,
                                      distanceMiles: 1, price: nil,
                                      ethanol: NearbyE85Ethanol(percentage: 78, reportedAt: now.addingTimeInterval(86400)))
        #expect(!snapshot(stations: [future]).isValid(at: now))
    }

    /// Simulates a real snapshot-v1.json already on a user's disk from before ethanol support
    /// existed: encodes a normal (post-change) station, then removes the "ethanol" key entirely
    /// — not merely nulls it — so this proves decoding a payload that never had the key at all,
    /// the genuine old-file shape, not just one with an explicit null.
    @Test func stationsFromBeforeEthanolSupportStillDecodeSuccessfully() throws {
        let modern = station(price: .init(dollarsPerGallon: 2.89, reportedAt: now, source: .community))
        var stationJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(modern)) as? [String: Any])
        #expect(stationJSON["ethanol"] == nil, "a nil optional should already be omitted, confirming this fixture matches a genuine old payload")
        stationJSON.removeValue(forKey: "ethanol")

        let oldSnapshot = snapshot(stations: [modern])
        var snapshotJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldSnapshot)) as? [String: Any])
        snapshotJSON["stations"] = [stationJSON]
        let oldData = try JSONSerialization.data(withJSONObject: snapshotJSON)

        let decoded = try JSONDecoder().decode(NearbyE85Snapshot.self, from: oldData)
        #expect(decoded.stations.first?.ethanol == nil)
        #expect(decoded.stations.first?.price?.dollarsPerGallon == 2.89)
        #expect(decoded.isValid(at: now))
    }
}

/// Pure geometry for the medium widget's map. Phoenix-area coordinates throughout so distances
/// are realistic; assertions check behavior against the algorithm's own named bounds rather than
/// recomputing exact spans, so they stay meaningful if the constants are retuned later.
struct NearbyE85MapRegionTests {
    private let user = CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740)
    private func milesPerDegreeLongitude(at latitude: Double) -> Double {
        max(69.0 * cos(latitude * .pi / 180), 1)
    }
    private func offset(_ coordinate: CLLocationCoordinate2D, latitude: Double = 0, longitude: Double = 0) -> CLLocationCoordinate2D {
        .init(latitude: coordinate.latitude + latitude, longitude: coordinate.longitude + longitude)
    }

    @Test func oneVeryCloseStationDoesNotOverZoom() {
        // A station essentially on top of the user must not collapse the map to street level.
        let station = offset(user, latitude: 0.0005)
        let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: [station], aspectRatio: 2.0)
        let latitudeSpanMiles = region.span.latitudeDelta * 69.0
        #expect(abs(latitudeSpanMiles - NearbyE85MapRegion.minimumSpanMiles) < 0.05)
    }

    @Test func severalNearbyStationsRemainInFrame() {
        let stations = [offset(user, latitude: 0.01, longitude: 0.01),
                         offset(user, latitude: -0.01, longitude: -0.02),
                         offset(user, latitude: 0.02, longitude: -0.01)]
        let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stations, aspectRatio: 2.0)
        let latitudeSpanMiles = region.span.latitudeDelta * 69.0
        let longitudeSpanMiles = region.span.longitudeDelta * milesPerDegreeLongitude(at: region.center.latitude)
        #expect(latitudeSpanMiles >= NearbyE85MapRegion.minimumSpanMiles - 0.01)
        #expect(latitudeSpanMiles <= NearbyE85MapRegion.maximumSpanMiles)
        #expect(longitudeSpanMiles >= NearbyE85MapRegion.minimumSpanMiles - 0.01)
        for station in stations + [user] {
            #expect(abs(station.latitude - region.center.latitude) <= region.span.latitudeDelta / 2 + 0.0001)
            #expect(abs(station.longitude - region.center.longitude) <= region.span.longitudeDelta / 2 + 0.0001)
        }
    }

    @Test func distantOutlierDoesNotZoomOutToMetroScale() {
        let close = offset(user, latitude: 0.01)
        let farOutlier = offset(user, longitude: 1.0) // ~55 miles east at this latitude
        let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: [close, farOutlier], aspectRatio: 2.0)
        let longitudeSpanMiles = region.span.longitudeDelta * milesPerDegreeLongitude(at: region.center.latitude)
        #expect(longitudeSpanMiles <= NearbyE85MapRegion.maximumSpanMiles + 0.5)
        // The outlier's own presence must not have driven the span past the metro-scale ceiling.
        #expect(longitudeSpanMiles < 1.0 * milesPerDegreeLongitude(at: user.latitude) * NearbyE85MapRegion.paddingFactor)
    }

    @Test func aspectRatioWidensTheShorterAxisWithoutShrinkingTheOther() {
        let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: [], aspectRatio: 3.0)
        let latitudeSpanMiles = region.span.latitudeDelta * 69.0
        let longitudeSpanMiles = region.span.longitudeDelta * milesPerDegreeLongitude(at: region.center.latitude)
        #expect(abs(latitudeSpanMiles - NearbyE85MapRegion.minimumSpanMiles) < 0.05)
        #expect(abs(longitudeSpanMiles / latitudeSpanMiles - 3.0) < 0.05)
    }

    @Test func centerIsTheMidpointOfUserAndStations() {
        let station = offset(user, latitude: 0.02, longitude: 0.02)
        let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: [station], aspectRatio: 2.0)
        #expect(abs(region.center.latitude - (user.latitude + station.latitude) / 2) < 0.0001)
        #expect(abs(region.center.longitude - (user.longitude + station.longitude) / 2) < 0.0001)
    }

    @Test func userMarkerIsNudgedAwayFromAnAlmostCoincidingStationPin() {
        // The nearest station is often almost exactly where the user is standing (e.g. at the
        // pump); the blue dot must not disappear underneath that pin.
        let stationPoint = CGPoint(x: 100, y: 100)
        let userPoint = CGPoint(x: 101, y: 100.5) // sub-pixel apart before decluttering
        let result = NearbyE85MapRegion.declutteredUserPoint(userPoint, avoiding: [stationPoint], minimumSeparation: 24)
        let dx = result.x - stationPoint.x, dy = result.y - stationPoint.y
        #expect((dx * dx + dy * dy).squareRoot() >= 23.99)
    }

    @Test func userMarkerIsLeftAloneWhenAlreadyWellSeparated() {
        let stationPoint = CGPoint(x: 100, y: 100)
        let userPoint = CGPoint(x: 160, y: 160)
        let result = NearbyE85MapRegion.declutteredUserPoint(userPoint, avoiding: [stationPoint], minimumSeparation: 24)
        #expect(result == userPoint)
    }

    // MARK: - Zoom multiplier (applied strictly after the base algorithm above)

    @Test func defaultZoomLevelExactlyMatchesTheUnzoomedRegion() {
        let stations = [offset(user, latitude: 0.01, longitude: 0.01), offset(user, latitude: -0.01, longitude: -0.02)]
        let unzoomed = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stations, aspectRatio: 2.0)
        let defaulted = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stations, aspectRatio: 2.0, zoomLevel: .default)
        #expect(abs(unzoomed.span.latitudeDelta - defaulted.span.latitudeDelta) < 1e-9)
        #expect(abs(unzoomed.span.longitudeDelta - defaulted.span.longitudeDelta) < 1e-9)
        #expect(unzoomed.center.latitude == defaulted.center.latitude)
        #expect(unzoomed.center.longitude == defaulted.center.longitude)
    }

    @Test func zoomingInShrinksTheSpanBelowDefault() {
        let stations = [offset(user, latitude: 0.02, longitude: 0.02)]
        let standard = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stations, aspectRatio: 2.0, zoomLevel: .standard)
        let zoomedIn = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stations, aspectRatio: 2.0, zoomLevel: .zoomedIn4)
        #expect(zoomedIn.span.latitudeDelta < standard.span.latitudeDelta)
        #expect(zoomedIn.span.longitudeDelta < standard.span.longitudeDelta)
    }

    @Test func zoomingOutGrowsTheSpanAboveDefault() {
        let stations = [offset(user, latitude: 0.02, longitude: 0.02)]
        let standard = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stations, aspectRatio: 2.0, zoomLevel: .standard)
        let zoomedOut = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stations, aspectRatio: 2.0, zoomLevel: .zoomedOut4)
        #expect(zoomedOut.span.latitudeDelta > standard.span.latitudeDelta)
        #expect(zoomedOut.span.longitudeDelta > standard.span.longitudeDelta)
    }

    @Test func spanShrinksOrHoldsMonotonicallyAcrossEveryZoomStepFromOutToIn() {
        // Rigorously exercises the smoother, ~9-level progression itself (not just the two old
        // extremes vs. standard above): each step further "in" must never produce a LARGER span
        // than the step before it. Non-strict (`<=`, not `<`) because the widened safe-bounds
        // clamp (see extremeZoomStaysWithinTheWidenedSafeBounds) can legitimately flatten the
        // span across two adjacent steps near the extremes without that being a regression.
        let stations = [offset(user, latitude: 0.015, longitude: 0.015)]
        let ordered = NearbyE85MapZoomLevel.allCases.sorted { $0.rawValue < $1.rawValue }
        let spans = ordered.map { level in
            NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stations, aspectRatio: 2.0, zoomLevel: level).span.latitudeDelta
        }
        for (wider, narrower) in zip(spans, spans.dropFirst()) {
            #expect(narrower <= wider + 1e-9)
        }
    }

    @Test func zoomNeverMovesTheRegionCenter() {
        let stations = [offset(user, latitude: 0.02, longitude: -0.03)]
        for level in NearbyE85MapZoomLevel.allCases {
            let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stations, aspectRatio: 2.0, zoomLevel: level)
            #expect(abs(region.center.latitude - (user.latitude + stations[0].latitude) / 2) < 0.0001)
            #expect(abs(region.center.longitude - (user.longitude + stations[0].longitude) / 2) < 0.0001)
        }
    }

    @Test func extremeZoomStaysWithinTheWidenedSafeBounds() {
        // A single very-close station (base region floors to minimumSpanMiles) zoomed all the
        // way in must not collapse to an unusably tight street-level crop.
        let closeStation = offset(user, latitude: 0.0005)
        let zoomedIn = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: [closeStation],
                                                 aspectRatio: 2.0, zoomLevel: .zoomedIn4)
        #expect(zoomedIn.span.latitudeDelta * 69.0 >= NearbyE85MapRegion.zoomedMinimumSpanMiles - 0.05)

        // A distant outlier (base region ceilings to maximumSpanMiles) zoomed all the way out
        // must not balloon into a whole-metro view.
        let farOutlier = offset(user, longitude: 1.0)
        let zoomedOut = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: [farOutlier],
                                                   aspectRatio: 2.0, zoomLevel: .zoomedOut4)
        let longitudeSpanMiles = zoomedOut.span.longitudeDelta * milesPerDegreeLongitude(at: zoomedOut.center.latitude)
        #expect(longitudeSpanMiles <= NearbyE85MapRegion.zoomedMaximumSpanMiles + 0.5)
    }

    @Test func userAndStationCoordinatesRemainWithinFrameAtEveryZoomLevelThatIsNotZoomedInPastThem() {
        // Zooming out must never push the user/stations out of frame; zooming in past the base
        // framing legitimately can (that's the point of zooming in), so this only asserts the
        // non-magnifying levels.
        let stations = [offset(user, latitude: 0.01, longitude: 0.01), offset(user, latitude: -0.01, longitude: -0.02)]
        for level in [NearbyE85MapZoomLevel.zoomedOut4, .zoomedOut3, .zoomedOut2, .zoomedOut1, .standard] {
            let region = NearbyE85MapRegion.region(userCoordinate: user, stationCoordinates: stations, aspectRatio: 2.0, zoomLevel: level)
            for coordinate in stations + [user] {
                #expect(abs(coordinate.latitude - region.center.latitude) <= region.span.latitudeDelta / 2 + 0.0001)
                #expect(abs(coordinate.longitude - region.center.longitude) <= region.span.longitudeDelta / 2 + 0.0001)
            }
        }
    }
}

/// `NearbyE85MapRenderer.mapSize` — the snapshot's requested size, in the exact same point-space
/// the widget later displays it at. Medium and large deliberately request different fractions of
/// the widget's canvas; both must stay purely a function of the family's own displaySize, with no
/// separate scale/crop step introduced later that could desync the image from marker points.
struct NearbyE85MapRendererTests {
    @Test func mediumOccupiesTheFullDisplaySizeWithNoScaling() {
        let displaySize = CGSize(width: 329, height: 155)
        #expect(NearbyE85MapRenderer.mapSize(for: displaySize, heightFraction: 1.0) == displaySize)
    }

    @Test func largeScalesOnlyHeightNeverWidth() {
        let displaySize = CGSize(width: 329, height: 345)
        let size = NearbyE85MapRenderer.mapSize(for: displaySize, heightFraction: 0.6)
        #expect(size.width == displaySize.width)
        #expect(abs(size.height - displaySize.height * 0.6) < 0.001)
    }

    @Test func differentFamiliesProduceDifferentMapFramesFromTheSameWidth() {
        let displaySize = CGSize(width: 329, height: 345)
        let mediumLike = NearbyE85MapRenderer.mapSize(for: displaySize, heightFraction: 1.0)
        let largeLike = NearbyE85MapRenderer.mapSize(for: displaySize, heightFraction: 0.6)
        #expect(mediumLike.width == largeLike.width)
        #expect(mediumLike.height > largeLike.height)
    }

    @Test func heightFractionIsClampedAndFloored() {
        let displaySize = CGSize(width: 300, height: 500)
        #expect(NearbyE85MapRenderer.mapSize(for: displaySize, heightFraction: 0.01).height == 80)
        #expect(NearbyE85MapRenderer.mapSize(for: displaySize, heightFraction: 5.0).height == displaySize.height)
    }

    @Test func degenerateDisplaySizeFallsBackToANonZeroDefault() {
        let size = NearbyE85MapRenderer.mapSize(for: .zero, heightFraction: 1.0)
        #expect(size.width > 0 && size.height > 0)
    }
}

/// `NearbyE85MapZoomLevel` — the pure step/clamp logic each zoom AppIntent (and NearbyE85MapRegion)
/// relies on. No UserDefaults, no WidgetKit, no rendering.
struct NearbyE85MapZoomLevelTests {
    @Test func defaultLevelHasNoEffectOnSpan() {
        #expect(NearbyE85MapZoomLevel.default == .standard)
        #expect(NearbyE85MapZoomLevel.default.spanMultiplier == 1.0)
    }

    @Test func stepsIncrementAndDecrementByExactlyOne() {
        #expect(NearbyE85MapZoomLevel.standard.zoomedInOneStep() == .zoomedIn1)
        #expect(NearbyE85MapZoomLevel.standard.zoomedOutOneStep() == .zoomedOut1)
    }

    @Test func clampsAtMaximumAndRepeatedTapsAreHarmless() {
        #expect(NearbyE85MapZoomLevel.maximum.zoomedInOneStep() == .maximum)
        // Simulates repeated "+" taps once already at max.
        var level = NearbyE85MapZoomLevel.maximum
        for _ in 0..<5 { level = level.zoomedInOneStep() }
        #expect(level == .maximum)
        #expect(level.isAtMaximum)
    }

    @Test func clampsAtMinimumAndRepeatedTapsAreHarmless() {
        #expect(NearbyE85MapZoomLevel.minimum.zoomedOutOneStep() == .minimum)
        var level = NearbyE85MapZoomLevel.minimum
        for _ in 0..<5 { level = level.zoomedOutOneStep() }
        #expect(level == .minimum)
        #expect(level.isAtMinimum)
    }

    @Test func multipliersAreMonotonicallyDecreasingFromZoomedOutToZoomedIn() {
        let ordered = NearbyE85MapZoomLevel.allCases.sorted { $0.rawValue < $1.rawValue }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            #expect(a.spanMultiplier > b.spanMultiplier)
        }
    }

    @Test func fullZoomInThenFullZoomOutRoundTripsToTheSameLevel() {
        var level = NearbyE85MapZoomLevel.zoomedOut1
        for _ in 0..<10 { level = level.zoomedInOneStep() }
        #expect(level == .maximum)
        for _ in 0..<10 { level = level.zoomedOutOneStep() }
        #expect(level == .minimum)
    }

    // MARK: - Legacy raw-value migration (85Blends 2.4.0 5-level -> 9-level widget quality pass)

    @Test func everyLegacyRawValueMigratesToItsProportionallyEquivalentNewLevel() {
        #expect(NearbyE85MapZoomLevel.migrated(fromLegacyRawValue: 0) == .zoomedOut4) // old max zoom out
        #expect(NearbyE85MapZoomLevel.migrated(fromLegacyRawValue: 1) == .zoomedOut2) // old zoomedOutSlightly
        #expect(NearbyE85MapZoomLevel.migrated(fromLegacyRawValue: 2) == .standard)   // old standard
        #expect(NearbyE85MapZoomLevel.migrated(fromLegacyRawValue: 3) == .zoomedIn2)  // old zoomedIn
        #expect(NearbyE85MapZoomLevel.migrated(fromLegacyRawValue: 4) == .zoomedIn4)  // old max zoom in
    }

    @Test func outOfRangeLegacyRawValuesFailToMigrateRatherThanGuessing() {
        for legacyRaw in [-1, 5, 999] {
            #expect(NearbyE85MapZoomLevel.migrated(fromLegacyRawValue: legacyRaw) == nil)
        }
    }
}

/// `NearbyE85MapZoomStore` — App-Group-backed persistence, exercised through an injected
/// UserDefaults suite so it never touches the real app group or requires the entitlement.
struct NearbyE85MapZoomStoreTests {
    private func store() -> NearbyE85MapZoomStore {
        NearbyE85MapZoomStore(defaults: UserDefaults(suiteName: "nearby-e85-zoom-test-\(UUID().uuidString)"))
    }

    @Test func defaultsToStandardWhenNothingStoredYet() {
        #expect(store().read() == .default)
    }

    @Test func writeThenReadRoundTrips() {
        let subject = store()
        subject.write(.zoomedIn4)
        #expect(subject.read() == .zoomedIn4)
        subject.write(.zoomedOut4)
        #expect(subject.read() == .zoomedOut4)
    }

    @Test func missingAppGroupFallsBackToDefaultRatherThanCrashing() {
        let subject = NearbyE85MapZoomStore(defaults: nil)
        subject.write(.zoomedIn4) // no-op: nothing to write to
        #expect(subject.read() == .default)
    }

    @Test func corruptedOutOfRangeStoredValueUnderTheCurrentKeyFallsBackToDefault() {
        let defaults = UserDefaults(suiteName: "nearby-e85-zoom-test-\(UUID().uuidString)")
        defaults?.set(999, forKey: NearbyE85MapZoomStore.key)
        #expect(NearbyE85MapZoomStore(defaults: defaults).read() == .default)
    }

    @Test func wrongTypeStoredValueUnderTheCurrentKeyFallsBackToDefault() {
        let defaults = UserDefaults(suiteName: "nearby-e85-zoom-test-\(UUID().uuidString)")
        defaults?.set("not-an-int", forKey: NearbyE85MapZoomStore.key)
        #expect(NearbyE85MapZoomStore(defaults: defaults).read() == .default)
    }

    // MARK: - Legacy-key migration (85Blends 2.4.0 5-level -> 9-level widget quality pass)

    @Test func readMigratesAnExistingLegacyValueToTheNewKeyAndClearsTheLegacyKey() {
        let defaults = UserDefaults(suiteName: "nearby-e85-zoom-migration-test-\(UUID().uuidString)")
        // Simulates an install from before this pass: only the old 5-level key has ever been
        // written. Raw 3 == the old scheme's `.zoomedIn` (one step in from its own standard).
        defaults?.set(3, forKey: NearbyE85MapZoomStore.legacyKey)
        let subject = NearbyE85MapZoomStore(defaults: defaults)

        #expect(subject.read() == .zoomedIn2)
        // Migration is not just a read-time translation: it must persist under the new key...
        #expect(defaults?.object(forKey: NearbyE85MapZoomStore.key) as? Int == NearbyE85MapZoomLevel.zoomedIn2.rawValue)
        // ...and remove the legacy key, so this migration runs at most once per install.
        #expect(defaults?.object(forKey: NearbyE85MapZoomStore.legacyKey) == nil)
    }

    @Test func aValueAlreadyStoredUnderTheNewKeyIsNeverOverriddenByALegacyValue() {
        let defaults = UserDefaults(suiteName: "nearby-e85-zoom-migration-test-\(UUID().uuidString)")
        defaults?.set(NearbyE85MapZoomLevel.zoomedIn1.rawValue, forKey: NearbyE85MapZoomStore.key)
        // A stale legacy value some earlier build path could conceivably have left behind.
        defaults?.set(0, forKey: NearbyE85MapZoomStore.legacyKey)
        let subject = NearbyE85MapZoomStore(defaults: defaults)

        #expect(subject.read() == .zoomedIn1)
        // The legacy leftover is simply irrelevant once the new key has a value — never consulted,
        // never migrated over it, and left exactly as it was.
        #expect(defaults?.object(forKey: NearbyE85MapZoomStore.legacyKey) as? Int == 0)
    }

    @Test func corruptedOutOfRangeLegacyValueFallsBackToDefaultRatherThanGuessing() {
        let defaults = UserDefaults(suiteName: "nearby-e85-zoom-migration-test-\(UUID().uuidString)")
        defaults?.set(999, forKey: NearbyE85MapZoomStore.legacyKey)
        #expect(NearbyE85MapZoomStore(defaults: defaults).read() == .default)
    }

    @Test func nothingStoredUnderEitherKeyFallsBackToDefault() {
        let defaults = UserDefaults(suiteName: "nearby-e85-zoom-migration-test-\(UUID().uuidString)")
        #expect(NearbyE85MapZoomStore(defaults: defaults).read() == .default)
    }
}

/// `NearbyE85ZoomAction` — the pure step each AppIntent's `perform()` delegates to.
struct NearbyE85ZoomActionTests {
    private func store() -> NearbyE85MapZoomStore {
        NearbyE85MapZoomStore(defaults: UserDefaults(suiteName: "nearby-e85-zoom-action-test-\(UUID().uuidString)"))
    }

    @Test func zoomInAdvancesAndPersistsOneStep() {
        let subject = store()
        let result = NearbyE85ZoomAction.zoomIn.apply(using: subject)
        #expect(result == .zoomedIn1)
        #expect(subject.read() == .zoomedIn1)
    }

    @Test func zoomOutRetreatsAndPersistsOneStep() {
        let subject = store()
        let result = NearbyE85ZoomAction.zoomOut.apply(using: subject)
        #expect(result == .zoomedOut1)
        #expect(subject.read() == .zoomedOut1)
    }

    @Test func repeatedZoomInEventuallyClampsAtMaximumAndPersistsThat() {
        let subject = store()
        var last: NearbyE85MapZoomLevel = .default
        for _ in 0..<10 { last = NearbyE85ZoomAction.zoomIn.apply(using: subject) }
        #expect(last == .maximum)
        #expect(subject.read() == .maximum)
    }
}

/// `NearbyE85RefreshRequestStore` — the pending-manual-refresh flag the widget's refresh
/// AppIntent sets and the app-active handler consumes exactly once. Same injectable-UserDefaults
/// shape as NearbyE85MapZoomStore, for the same testability reason.
struct NearbyE85RefreshRequestStoreTests {
    private func store() -> NearbyE85RefreshRequestStore {
        NearbyE85RefreshRequestStore(defaults: UserDefaults(suiteName: "nearby-e85-refresh-test-\(UUID().uuidString)"))
    }

    @Test func noPendingRequestByDefault() {
        #expect(store().pendingRequestDate() == nil)
    }

    @Test func markThenReadRoundTripsToWithinRoundingOfTheOriginalTimestamp() {
        let subject = store()
        let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        subject.markRequested(at: requestedAt)
        #expect(abs((subject.pendingRequestDate() ?? .distantPast).timeIntervalSince(requestedAt)) < 1)
    }

    @Test func clearRemovesThePendingRequest() {
        let subject = store()
        subject.markRequested(at: .now)
        #expect(subject.pendingRequestDate() != nil)
        subject.clear()
        #expect(subject.pendingRequestDate() == nil)
    }

    @Test func missingAppGroupFallsBackToNoPendingRequestRatherThanCrashing() {
        let subject = NearbyE85RefreshRequestStore(defaults: nil)
        subject.markRequested(at: .now) // no-op: nothing to write to
        #expect(subject.pendingRequestDate() == nil)
        subject.clear() // also a harmless no-op
    }
}

/// The manual-refresh request and the Large-widget zoom preference are two independent App
/// -Group-backed values — marking/clearing one must never read or write the other.
struct NearbyE85RefreshAndZoomIndependenceTests {
    @Test func markingARefreshRequestNeverTouchesTheZoomPreference() {
        let suite = "nearby-e85-independence-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        let zoomStore = NearbyE85MapZoomStore(defaults: defaults)
        let refreshStore = NearbyE85RefreshRequestStore(defaults: defaults)

        zoomStore.write(.zoomedIn4)
        refreshStore.markRequested(at: .now)
        refreshStore.clear()

        #expect(zoomStore.read() == .zoomedIn4)
    }

    @Test func writingTheZoomPreferenceNeverTouchesAPendingRefreshRequest() {
        let suite = "nearby-e85-independence-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        let zoomStore = NearbyE85MapZoomStore(defaults: defaults)
        let refreshStore = NearbyE85RefreshRequestStore(defaults: defaults)

        let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        refreshStore.markRequested(at: requestedAt)
        zoomStore.write(.zoomedOut4)
        zoomStore.write(.standard)

        #expect(abs((refreshStore.pendingRequestDate() ?? .distantPast).timeIntervalSince(requestedAt)) < 1)
    }
}

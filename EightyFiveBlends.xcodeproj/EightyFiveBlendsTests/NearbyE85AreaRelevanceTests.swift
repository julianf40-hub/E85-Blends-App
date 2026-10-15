//
//  NearbyE85AreaRelevanceTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.1 — covers the out-of-area signal end to end: the pure store, the pure
//  expiry rule, NearbyE85LocationRefreshCoordinator.handle setting it, NearbyE85Publisher.
//  publish clearing it, and NearbyE85Provider/NearbyE85WidgetURLResolver consuming it.
//

import Testing
import CoreLocation
import WidgetKit
@testable import EightyFiveBlends

// MARK: - Pure store

struct NearbyE85AreaRelevanceStoreTests {
    private func isolatedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: "nearby-e85-area-relevance-test-\(UUID().uuidString)")
    }
    private func isolatedStore() -> NearbyE85AreaRelevanceStore { NearbyE85AreaRelevanceStore(defaults: isolatedDefaults()) }

    @Test func nothingStoredReadsAsInArea() {
        #expect(isolatedStore().read() == .inArea)
        #expect(isolatedStore().read().isOutOfArea == false)
    }

    @Test func markOutOfAreaThenReadRoundTrips() {
        let store = isolatedStore()
        let markedAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(store.markOutOfArea(at: markedAt))
        let state = store.read()
        #expect(state.isOutOfArea)
        #expect(state.version == NearbyE85AreaRelevanceState.currentVersion)
        #expect(abs(state.determinedAt.timeIntervalSince(markedAt)) < 1)
    }

    @Test func markingOutOfAreaASecondTimeReportsNoVisibleChangeButRefreshesTheTimestamp() {
        let store = isolatedStore()
        #expect(store.markOutOfArea(at: Date(timeIntervalSince1970: 1_800_000_000)))
        let laterMark = Date(timeIntervalSince1970: 1_800_000_500)
        #expect(store.markOutOfArea(at: laterMark) == false)
        #expect(abs(store.read().determinedAt.timeIntervalSince(laterMark)) < 1)
    }

    @Test func clearAfterOutOfAreaReturnsToInAreaAndReportsAChange() {
        let store = isolatedStore()
        store.markOutOfArea(at: .now)
        #expect(store.clear())
        #expect(store.read() == .inArea)
    }

    @Test func clearWhenAlreadyInAreaIsAHarmlessNoChange() {
        let store = isolatedStore()
        #expect(store.clear() == false)
        #expect(store.read() == .inArea)
    }

    @Test func missingAppGroupFallsBackToInAreaAndMarkReportsNoVisibleChange() {
        let store = NearbyE85AreaRelevanceStore(defaults: nil)
        #expect(store.markOutOfArea(at: .now) == false) // nothing to write to; never claims a change happened
        #expect(store.read() == .inArea)
        #expect(store.clear() == false)
    }

    @Test func corruptBytesReadAsInArea() {
        let defaults = isolatedDefaults()
        defaults?.set(Data("definitely not json".utf8), forKey: NearbyE85AreaRelevanceStore.key)
        #expect(NearbyE85AreaRelevanceStore(defaults: defaults).read() == .inArea)
    }

    @Test func wrongTypeUnderTheKeyReadsAsInArea() {
        let defaults = isolatedDefaults()
        defaults?.set("true", forKey: NearbyE85AreaRelevanceStore.key)
        #expect(NearbyE85AreaRelevanceStore(defaults: defaults).read() == .inArea)
    }

    @Test func unrecognisedVersionReadsAsInAreaEvenWithAnOutOfAreaPayload() throws {
        let defaults = isolatedDefaults()
        let bogus = NearbyE85AreaRelevanceState(version: 999, isOutOfArea: true, determinedAt: .now)
        defaults?.set(try JSONEncoder().encode(bogus), forKey: NearbyE85AreaRelevanceStore.key)
        #expect(NearbyE85AreaRelevanceStore(defaults: defaults).read() == .inArea)
    }
}

// MARK: - Pure expiry rule

struct NearbyE85AreaRelevanceDecisionTests {
    @Test func inAreaStateIsNeverOutOfAreaRegardlessOfTiming() {
        #expect(NearbyE85AreaRelevance.isCurrentlyOutOfArea(state: .inArea, now: .now) == false)
        #expect(NearbyE85AreaRelevance.isCurrentlyOutOfArea(state: .inArea, now: .distantFuture) == false)
    }

    @Test func outOfAreaIsTrueImmediatelyAfterBeingDetermined() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = NearbyE85AreaRelevanceState(isOutOfArea: true, determinedAt: now)
        #expect(NearbyE85AreaRelevance.isCurrentlyOutOfArea(state: state, now: now))
    }

    @Test func outOfAreaRemainsTrueWithinTheExpiryWindow() {
        let determinedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let state = NearbyE85AreaRelevanceState(isOutOfArea: true, determinedAt: determinedAt)
        let now = determinedAt.addingTimeInterval(NearbyE85Snapshot.expiresAfter - 1)
        #expect(NearbyE85AreaRelevance.isCurrentlyOutOfArea(state: state, now: now))
    }

    @Test func outOfAreaExpiresAtExactlyTheSnapshotExpiryWindow() {
        let determinedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let state = NearbyE85AreaRelevanceState(isOutOfArea: true, determinedAt: determinedAt)
        let now = determinedAt.addingTimeInterval(NearbyE85Snapshot.expiresAfter)
        #expect(NearbyE85AreaRelevance.isCurrentlyOutOfArea(state: state, now: now) == false)
    }

    @Test func aFutureDeterminedAtClockSkewIsNeverOutOfArea() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = NearbyE85AreaRelevanceState(isOutOfArea: true, determinedAt: now.addingTimeInterval(60))
        #expect(NearbyE85AreaRelevance.isCurrentlyOutOfArea(state: state, now: now) == false)
    }
}

// MARK: - NearbyE85LocationRefreshCoordinator.handle sets/leaves the flag

struct NearbyE85AreaRelevanceCoordinatorTests {
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
    private func isolatedAreaStore() -> NearbyE85AreaRelevanceStore {
        NearbyE85AreaRelevanceStore(defaults: UserDefaults(suiteName: "nearby-e85-area-coordinator-test-\(UUID().uuidString)"))
    }

    @Test func movementWithinTheSearchAreaNeverMarksOutOfArea() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        let mobil = station("Mobil", longitudeOffset: 0.03, distanceMiles: 2.1)
        let original = NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: home.latitude, userLongitude: home.longitude)
        try cache.write(original, now: now)

        let laterNow = now.addingTimeInterval(600)
        let location = makeLocation(latitude: home.latitude, longitude: home.longitude - 0.05, timestamp: laterNow)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: laterNow, areaRelevanceStore: areaStore)

        #expect(areaStore.read() == .inArea)
    }

    @Test func movementFarOutsideTheSearchAreaMarksOutOfArea() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        let mobil = station("Mobil", longitudeOffset: 0.03, distanceMiles: 2.1)
        let original = NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: home.latitude, userLongitude: home.longitude)
        try cache.write(original, now: now)

        // ~120 miles away — Phoenix to Tucson, well past the 25-mile search radius.
        let laterNow = now.addingTimeInterval(3600)
        let location = makeLocation(latitude: home.latitude - 1.7, longitude: home.longitude, timestamp: laterNow)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: laterNow, areaRelevanceStore: areaStore)

        #expect(areaStore.read().isOutOfArea)
        // The stale Phoenix snapshot itself is untouched — handle() never overwrites it with a
        // guess, it only raises the independent out-of-area signal.
        #expect(cache.read(now: laterNow) == original)
    }

    /// 85Blends 2.4.1 Phase 2C — proves the actual WidgetCenter call site fires, not just that
    /// `markOutOfArea` returned true. `NearbyE85LocationRefreshCoordinator.handle` previously had
    /// no way for a test to observe the real reload call; this exercises the injected closure
    /// the same way `NearbyE85RefreshIntent`/`NearbyE85ZoomIntentHandler` already do.
    @Test func movementFarOutsideTheSearchAreaRequestsExactlyOneTimelineReload() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        let mobil = station("Mobil", longitudeOffset: 0.03, distanceMiles: 2.1)
        try cache.write(NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: now, locationAt: now,
                                               userLatitude: home.latitude, userLongitude: home.longitude), now: now)

        var reloadCount = 0
        let laterNow = now.addingTimeInterval(3600)
        NearbyE85LocationRefreshCoordinator.handle(
            location: makeLocation(latitude: home.latitude - 1.7, longitude: home.longitude, timestamp: laterNow),
            cache: cache, now: laterNow, areaRelevanceStore: areaStore, reloadTimelines: { reloadCount += 1 })

        #expect(areaStore.read().isOutOfArea)
        #expect(reloadCount == 1)
    }

    /// Mirrors `repeatedOutOfRangeFixesKeepTheFlagSetWithoutError` but observes the actual
    /// reload call count rather than inferring it from the store alone — the second, still-out-
    /// of-range fix must spend none of WidgetKit's reload budget on a re-render that would be
    /// identical to what's already showing.
    @Test func repeatedOutOfRangeFixesRequestNoAdditionalReload() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        let mobil = station("Mobil", longitudeOffset: 0.03, distanceMiles: 2.1)
        try cache.write(NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: now, locationAt: now,
                                               userLatitude: home.latitude, userLongitude: home.longitude), now: now)

        var reloadCount = 0
        let firstFix = now.addingTimeInterval(3600)
        NearbyE85LocationRefreshCoordinator.handle(
            location: makeLocation(latitude: home.latitude - 1.7, longitude: home.longitude, timestamp: firstFix),
            cache: cache, now: firstFix, areaRelevanceStore: areaStore, reloadTimelines: { reloadCount += 1 })
        #expect(reloadCount == 1)

        let secondFix = now.addingTimeInterval(4200)
        NearbyE85LocationRefreshCoordinator.handle(
            location: makeLocation(latitude: home.latitude - 1.71, longitude: home.longitude, timestamp: secondFix),
            cache: cache, now: secondFix, areaRelevanceStore: areaStore, reloadTimelines: { reloadCount += 1 })
        #expect(reloadCount == 1)
    }

    @Test func repeatedOutOfRangeFixesKeepTheFlagSetWithoutError() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        let mobil = station("Mobil", longitudeOffset: 0.03, distanceMiles: 2.1)
        try cache.write(NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: now, locationAt: now,
                                               userLatitude: home.latitude, userLongitude: home.longitude), now: now)

        let firstFix = now.addingTimeInterval(3600)
        NearbyE85LocationRefreshCoordinator.handle(location: makeLocation(latitude: home.latitude - 1.7, longitude: home.longitude, timestamp: firstFix),
                                                   cache: cache, now: firstFix, areaRelevanceStore: areaStore)
        #expect(areaStore.read().isOutOfArea)

        let secondFix = now.addingTimeInterval(4200)
        NearbyE85LocationRefreshCoordinator.handle(location: makeLocation(latitude: home.latitude - 1.71, longitude: home.longitude, timestamp: secondFix),
                                                   cache: cache, now: secondFix, areaRelevanceStore: areaStore)
        #expect(areaStore.read().isOutOfArea)
        // determinedAt advances with each qualifying fix, keeping the expiry window honest.
        #expect(abs(areaStore.read().determinedAt.timeIntervalSince(secondFix)) < 1)
    }

    @Test func travelingBackIntoRangeClearsTheFlagViaTheOrdinaryRepositionPublish() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        areaStore.markOutOfArea(at: now) // simulate having previously traveled out of range

        let mobil = station("Mobil", longitudeOffset: 0.03, distanceMiles: 2.1)
        try cache.write(NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: now, locationAt: now,
                                               userLatitude: home.latitude, userLongitude: home.longitude), now: now)

        let laterNow = now.addingTimeInterval(600)
        // Back within range of the still-cached station.
        let location = makeLocation(latitude: home.latitude, longitude: home.longitude - 0.05, timestamp: laterNow)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: laterNow, areaRelevanceStore: areaStore)

        #expect(areaStore.read() == .inArea)
    }

    @Test func aPoorAccuracyFixNeverTouchesTheAreaRelevanceFlag() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        let mobil = station("Mobil", longitudeOffset: 0.03, distanceMiles: 2.1)
        try cache.write(NearbyE85Snapshot.make(stations: [mobil], radiusMiles: 25, updatedAt: now, locationAt: now,
                                               userLatitude: home.latitude, userLongitude: home.longitude), now: now)

        let laterNow = now.addingTimeInterval(600)
        // Horizontal accuracy far beyond NearbyE85LocationAcceptance.maximumAcceptableHorizontalAccuracyMeters.
        let location = makeLocation(latitude: home.latitude - 1.7, longitude: home.longitude, horizontalAccuracy: 50_000, timestamp: laterNow)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: laterNow, areaRelevanceStore: areaStore)

        #expect(areaStore.read() == .inArea)
    }

    @Test func noCachedSnapshotNeverTouchesTheAreaRelevanceFlag() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        let location = makeLocation(latitude: home.latitude - 1.7, longitude: home.longitude, timestamp: now)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: now, areaRelevanceStore: areaStore)
        #expect(areaStore.read() == .inArea)
    }

    /// An empty search result (`.noStations`) must never be treated as proof the cache is out
    /// of area — handle()'s own `cached.state == .ready` guard already excludes it from ever
    /// reaching reposition().
    @Test func anEmptyCachedSearchResultNeverTouchesTheAreaRelevanceFlag() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        try cache.write(.make(stations: [], radiusMiles: 25, updatedAt: now, locationAt: now,
                              userLatitude: home.latitude, userLongitude: home.longitude), now: now)

        let laterNow = now.addingTimeInterval(600)
        let location = makeLocation(latitude: home.latitude - 1.7, longitude: home.longitude, timestamp: laterNow)
        NearbyE85LocationRefreshCoordinator.handle(location: location, cache: cache, now: laterNow, areaRelevanceStore: areaStore)

        #expect(areaStore.read() == .inArea)
    }
}

// MARK: - NearbyE85Publisher.publish clears the flag

struct NearbyE85AreaRelevancePublisherTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeCache() -> (NearbyE85Cache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("snapshot.json")
        return (NearbyE85Cache(fileURL: file), directory)
    }
    private func isolatedAreaStore() -> NearbyE85AreaRelevanceStore {
        NearbyE85AreaRelevanceStore(defaults: UserDefaults(suiteName: "nearby-e85-area-publisher-test-\(UUID().uuidString)"))
    }

    @Test func aFreshReadySnapshotClearsAPreviouslyMarkedOutOfAreaFlag() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        areaStore.markOutOfArea(at: now)

        let station = NearbyE85Station(id: "one", name: "Mobil", address: "Address", latitude: 33.45, longitude: -112.07,
                                        distanceMiles: 1.0, price: nil)
        let fresh = NearbyE85Snapshot.make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now,
                                           userLatitude: 33.44, userLongitude: -112.08)
        NearbyE85Publisher.publish(fresh, cache: cache, now: now, areaRelevanceStore: areaStore)

        #expect(areaStore.read() == .inArea)
    }

    @Test func aFreshNoStationsSnapshotAlsoClearsTheOutOfAreaFlag() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        areaStore.markOutOfArea(at: now)

        NearbyE85Publisher.publish(.make(stations: [], radiusMiles: 25, updatedAt: now, locationAt: now), cache: cache, now: now, areaRelevanceStore: areaStore)

        #expect(areaStore.read() == .inArea)
    }

    @Test func revokingLocationAlsoClearsTheOutOfAreaFlag() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        areaStore.markOutOfArea(at: now)

        NearbyE85Publisher.publish(.permissionRequired(at: now), cache: cache, now: now, areaRelevanceStore: areaStore)

        #expect(areaStore.read() == .inArea)
    }

    /// 85Blends 2.4.1 Phase 2C fix — publishing byte-identical content (cache.write short-
    /// circuits and returns false) must still clear a previously-recorded out-of-area flag.
    /// `cache.write` only reaches this call without throwing for a snapshot that already passed
    /// `isValid(at:)`, so this IS a validated, authoritative result regardless of whether the
    /// bytes on disk happened to match — gating the clear on the file-content comparison alone
    /// would leave the widget needlessly stuck on "Location changed" after a genuinely
    /// successful search. This replaces a prior version of this test that asserted the opposite
    /// (confirmed defect, corrected here).
    @Test func aFreshValidatedSnapshotClearsTheOutOfAreaFlagEvenWhenCacheContentIsUnchanged() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        let station = NearbyE85Station(id: "one", name: "Mobil", address: "Address", latitude: 33.45, longitude: -112.07,
                                        distanceMiles: 1.0, price: nil)
        let snapshot = NearbyE85Snapshot.make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: 33.44, userLongitude: -112.08)
        try cache.write(snapshot, now: now)
        areaStore.markOutOfArea(at: now)

        var reloadCount = 0
        // Publishing the exact same content again is a no-op write (cache.write short-circuits
        // on equality) — but the out-of-area flag must still clear, and exactly one reload must
        // still be requested, since the widget-visible state (the flag) did change even though
        // the underlying file did not.
        NearbyE85Publisher.publish(snapshot, cache: cache, now: now, areaRelevanceStore: areaStore, reloadTimelines: { reloadCount += 1 })

        #expect(areaStore.read() == .inArea)
        #expect(reloadCount == 1)
    }

    /// Preserves the pre-existing no-duplicate-reload behavior for the ordinary case: nothing
    /// changed (same content, already in-area) — no reload should be spent.
    @Test func publishingAnIdenticalSnapshotWhileAlreadyInAreaRequestsNoReload() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let areaStore = isolatedAreaStore()
        let station = NearbyE85Station(id: "one", name: "Mobil", address: "Address", latitude: 33.45, longitude: -112.07,
                                        distanceMiles: 1.0, price: nil)
        let snapshot = NearbyE85Snapshot.make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: 33.44, userLongitude: -112.08)
        try cache.write(snapshot, now: now)

        var reloadCount = 0
        NearbyE85Publisher.publish(snapshot, cache: cache, now: now, areaRelevanceStore: areaStore, reloadTimelines: { reloadCount += 1 })

        #expect(areaStore.read() == .inArea)
        #expect(reloadCount == 0)
    }

    /// 85Blends 2.4.1 Phase 2D cache-write safety review — `NearbyE85Cache.write` throws
    /// (rather than returning) for every failure case (invalid App Group container here;
    /// a failed disk write or encoding failure take the identical `catch` path in `publish`).
    /// `areaRelevanceStore.clear()` sits inside the SAME `do` block, after the `try cache.write`
    /// line — so a throw jumps straight to `catch` and that line is never reached. This proves
    /// `publish` can never clear (or report a reload for) an out-of-area state on the strength
    /// of data that was never actually persisted.
    @Test func aCacheWriteFailureNeverClearsTheOutOfAreaFlagOrReloads() {
        let areaStore = isolatedAreaStore()
        areaStore.markOutOfArea(at: now)
        let brokenCache = NearbyE85Cache(fileURL: nil) // simulates an unavailable/invalid App Group container

        let station = NearbyE85Station(id: "one", name: "Mobil", address: "Address", latitude: 33.45, longitude: -112.07,
                                        distanceMiles: 1.0, price: nil)
        let snapshot = NearbyE85Snapshot.make(stations: [station], radiusMiles: 25, updatedAt: now, locationAt: now,
                                              userLatitude: 33.44, userLongitude: -112.08)

        var reloadCount = 0
        NearbyE85Publisher.publish(snapshot, cache: brokenCache, now: now, areaRelevanceStore: areaStore, reloadTimelines: { reloadCount += 1 })

        #expect(areaStore.read().isOutOfArea)
        #expect(reloadCount == 0)
    }
}

// MARK: - NearbyE85Provider consumes the flag per timeline entry

struct NearbyE85AreaRelevanceProviderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var readySnapshot: NearbyE85Snapshot {
        .make(stations: [.init(id: "one", name: "Mobil", address: "Address", latitude: 33.45, longitude: -112.07,
                               distanceMiles: 1.0, price: nil)],
              radiusMiles: 25, updatedAt: now, locationAt: now, userLatitude: 33.44, userLongitude: -112.08)
    }
    private func inputs(areaRelevance: NearbyE85AreaRelevanceState) -> NearbyE85Provider.ProInputs {
        .init(snapshot: readySnapshot, zoomLevel: .default, mapRender: nil, pendingRefreshAt: nil, areaRelevance: areaRelevance)
    }

    @Test func entryReflectsOutOfAreaWhenStillWithinTheExpiryWindow() async {
        let markedAt = now.addingTimeInterval(-60)
        let entry = await NearbyE85Provider.entry(access: .pro, now: now) {
            self.inputs(areaRelevance: .init(isOutOfArea: true, determinedAt: markedAt))
        }
        #expect(entry.isOutOfArea)
        // The snapshot itself is untouched/still present — isOutOfArea is a separate flag, not
        // a mutation of the cached data.
        #expect(entry.snapshot == readySnapshot)
    }

    @Test func entryIsNotOutOfAreaOnceThePastExpiryWindowHasElapsed() async {
        let markedAt = now.addingTimeInterval(-NearbyE85Snapshot.expiresAfter)
        let entry = await NearbyE85Provider.entry(access: .pro, now: now) {
            self.inputs(areaRelevance: .init(isOutOfArea: true, determinedAt: markedAt))
        }
        #expect(entry.isOutOfArea == false)
    }

    @Test func timelineEntriesIndependentlyReflectOutOfAreaAgainstEachEntrysOwnDate() async {
        let markedAt = now.addingTimeInterval(60)
        let timeline = await NearbyE85Provider.timeline(access: .pro, now: now) {
            self.inputs(areaRelevance: .init(isOutOfArea: true, determinedAt: markedAt))
        }
        // An entry dated before the signal was even determined must not show it...
        let beforeEntries = timeline.entries.filter { $0.date <= markedAt }
        #expect(!beforeEntries.isEmpty)
        for entry in beforeEntries { #expect(entry.isOutOfArea == false) }
        // ...while an entry dated after it (but inside the window) does.
        let afterEntries = timeline.entries.filter { $0.date > markedAt && $0.date < markedAt.addingTimeInterval(NearbyE85Snapshot.expiresAfter) }
        for entry in afterEntries { #expect(entry.isOutOfArea) }
    }

    @Test func lockedEntryAndTimelineAreNeverOutOfAreaRegardlessOfTheStoredSignal() {
        let locked = NearbyE85Provider.lockedEntry(access: .free, now: now)
        #expect(locked.isOutOfArea == false)
        let lockedTimeline = NearbyE85Provider.lockedTimeline(access: .free, now: now)
        for entry in lockedTimeline.entries { #expect(entry.isOutOfArea == false) }
    }
}

// MARK: - NearbyE85WidgetURLResolver never ships a stale directions link while out of area

struct NearbyE85WidgetURLResolverAreaRelevanceTests {
    private let readyWithStation = NearbyE85Snapshot.make(
        stations: [.init(id: "one", name: "Mobil", address: "Address", latitude: 33.45, longitude: -112.07, distanceMiles: 1.0, price: nil)],
        radiusMiles: 25, updatedAt: .now, locationAt: .now)

    @Test func outOfAreaAlwaysResolvesToStationsRegardlessOfFamily() {
        for family: WidgetFamily in [.systemSmall, .systemMedium, .systemLarge] {
            let url = NearbyE85WidgetURLResolver.widgetURL(family: family, snapshot: readyWithStation, access: .pro, isOutOfArea: true)
            #expect(url == NearbyE85DeepLink.stationsURL())
        }
    }

    @Test func notOutOfAreaPreservesTheOrdinaryProRule() {
        let url = NearbyE85WidgetURLResolver.widgetURL(family: .systemSmall, snapshot: readyWithStation, access: .pro, isOutOfArea: false)
        #expect(url == NearbyE85DeepLink.directionsURL(stationID: "one"))
    }
}

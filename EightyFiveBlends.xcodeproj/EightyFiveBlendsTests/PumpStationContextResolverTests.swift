//
//  PumpStationContextResolverTests.swift
//  EightyFiveBlendsTests
//
//  Tests for manually opened Pump Mode's station-context resolver — deliberately separate
//  from PumpProximityTests.swift, which covers the automatic-prompt threshold on its own
//  (the two radii are independently maintained; see pumpProximityThresholdsIndependentOfManualResolver).
//  No real Core Location manager, network access, or wall-clock timing is used: `now` and
//  every location/accuracy input are injected directly into the functions under test.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until
//  a test target is added. Written to compile and pass once one exists.
//
//  A few of the task's requested scenarios are architectural guarantees verified by code
//  inspection rather than unit tests here, since they depend on CalculatorView's private
//  @State (session tokens, notification-driven bypass of the resolver) rather than on
//  PumpStationContextResolver itself:
//   - "Notification-selected saved station remains selected" —
//     CalculatorView.resolvePendingDetectedStationIfNeeded sets `.matched` directly and
//     never calls the resolver, so no resolution can regress it.
//   - "Late result from an obsolete Pump Mode session is ignored" —
//     CalculatorView.resolvePumpStationContext/requestBoundedFreshLocation both re-check
//     `sessionToken == pumpModeSessionToken` before applying any result.
//   - "Reduced-accuracy location state → appropriate failure state" is partially covered
//     here (an inaccurate fix is rejected — see `rejectsInaccurateLocation`); the specific
//     `.preciseLocationRequired` UI mapping additionally depends on
//     `StationLocationManager.isPreciseLocationEnabled`, which requires a live
//     CLLocationManager and isn't reachable from a pure unit test.
//

import CoreLocation
import Foundation
import Testing
@testable import EightyFiveBlends

struct PumpStationContextResolverSelectionTests {
    private let userLatitude = 40.0
    private let userLongitude = -83.0
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Displaces purely in latitude so the resulting distance is predictable and monotonic
    /// with `meters` for the small offsets used in these tests (~111,320 m/degree near 40°N).
    private func latitudeOffset(forMeters meters: Double) -> Double {
        meters / 111_320.0
    }

    private func savedCandidate(id: String = "saved", name: String = "Saved Station", meters: Double, e85Price: Double? = 3.49) -> PumpStationContextCandidate {
        PumpStationContextCandidate(
            id: id,
            name: name,
            latitude: userLatitude + latitudeOffset(forMeters: meters),
            longitude: userLongitude,
            address: nil,
            e85Price: e85Price,
            source: .saved
        )
    }

    private func liveCandidate(id: String = "live", name: String = "Live Station", meters: Double) -> PumpStationContextCandidate {
        PumpStationContextCandidate(
            id: id,
            name: name,
            latitude: userLatitude + latitudeOffset(forMeters: meters),
            longitude: userLongitude,
            address: nil,
            e85Price: nil,
            source: .live
        )
    }

    private func resolve(candidates: [PumpStationContextCandidate], accuracy: CLLocationAccuracy? = 5, ageSeconds: TimeInterval = 0) -> PumpStationContextResult {
        PumpStationContextResolver.resolve(
            candidates: candidates,
            freshLatitude: userLatitude,
            freshLongitude: userLongitude,
            horizontalAccuracyMeters: accuracy,
            locationTimestamp: now.addingTimeInterval(-ageSeconds),
            now: now
        )
    }

    @Test("Saved station ~3 m away with good accuracy is matched")
    func matchesVeryCloseSavedStation() {
        let station = savedCandidate(meters: 3)
        let result = resolve(candidates: [station])
        #expect(result == .matched(station))
    }

    @Test("Saved station ~35 m away is matchable in manual context, while PumpProximity's automatic prompt would remain false")
    func matchesAtAutomaticPromptBoundary() {
        let station = savedCandidate(meters: 35)
        let result = resolve(candidates: [station])
        #expect(result == .matched(station))
        // The automatic prompt is a separate, stricter gate (its own 40 m manual-context
        // radius vs. PumpProximity's 30 m automatic entry radius) — 35 m is comfortably
        // inside this resolver's manual radius but just outside the automatic prompt's entry
        // radius, and must stay rejected there regardless of this resolver's outcome.
        #expect(PumpProximity.isAtPump(distanceMeters: 35, horizontalAccuracyMeters: 5, wasAtPump: false) == false)
    }

    @Test("Saved station ~18 m away is matched in manual context")
    func matchesAt18Meters() {
        let station = savedCandidate(meters: 18)
        let result = resolve(candidates: [station])
        #expect(result == .matched(station))
    }

    @Test("Station beyond the 40 m manual context radius is not matched")
    func rejectsBeyondManualRadius() {
        let station = savedCandidate(meters: 45)
        let result = resolve(candidates: [station])
        #expect(result == .noCandidates)
        #expect(PumpStationContextResolver.manualContextRadiusMeters == 40)
    }

    @Test("Live-only nearby station is matched with source .live")
    func matchesLiveOnlyStation() {
        let station = liveCandidate(meters: 10)
        let result = resolve(candidates: [station])
        #expect(result == .matched(station))
        if case .matched(let matched) = result {
            #expect(matched.source == .live)
            #expect(matched.e85Price == nil) // live candidates never carry a price
        }
    }

    @Test("Saved and live copies of the same physical station are deduplicated, preferring saved")
    func prefersSavedOverLiveDuplicate() {
        let sameID = AutomaticPumpDetectionStationKey.make(name: "Shared Station", latitude: userLatitude, longitude: userLongitude)
        let saved = PumpStationContextCandidate(id: sameID, name: "Shared Station", latitude: userLatitude, longitude: userLongitude, address: nil, e85Price: 3.29, source: .saved)
        let live = PumpStationContextCandidate(id: sameID, name: "Shared Station", latitude: userLatitude, longitude: userLongitude, address: nil, e85Price: nil, source: .live)

        let result = resolve(candidates: [live, saved])
        #expect(result == .matched(saved))
    }

    @Test("Station without valid coordinates is excluded")
    func excludesInvalidCoordinates() {
        let invalid = PumpStationContextCandidate(id: "bad", name: "Bad Station", latitude: .nan, longitude: userLongitude, address: nil, e85Price: nil, source: .saved)
        let result = resolve(candidates: [invalid])
        #expect(result == .noCandidates)
    }

    @Test("Stale location is rejected")
    func rejectsStaleLocation() {
        let station = savedCandidate(meters: 3)
        let result = resolve(candidates: [station], ageSeconds: PumpStationContextResolver.maximumLocationAge + 1)
        #expect(result == .locationStale)
    }

    @Test("Location accurate at the exact staleness boundary is still accepted")
    func acceptsLocationAtStalenessBoundary() {
        let station = savedCandidate(meters: 3)
        let result = resolve(candidates: [station], ageSeconds: PumpStationContextResolver.maximumLocationAge)
        #expect(result == .matched(station))
    }

    @Test("Inaccurate location above the manual limit is rejected")
    func rejectsInaccurateLocation() {
        let station = savedCandidate(meters: 3)
        let result = resolve(candidates: [station], accuracy: PumpStationContextResolver.maximumAccuracyMeters + 1)
        #expect(result == .locationInaccurate)
        #expect(PumpStationContextResolver.maximumAccuracyMeters == 50) // matches PumpProximity's own max accuracy gate
    }

    @Test("Two distinct stations within the ambiguity threshold are returned as ambiguous")
    func ambiguousWhenTooClose() {
        let a = savedCandidate(id: "a", name: "Station A", meters: 10)
        let b = savedCandidate(id: "b", name: "Station B", meters: 18) // 8 m apart, within the 10 m ambiguity delta
        let result = resolve(candidates: [a, b])
        guard case .ambiguous(let candidates) = result else {
            Issue.record("Expected .ambiguous, got \(result)")
            return
        }
        #expect(Set(candidates.map(\.id)) == Set([a.id, b.id]))
        #expect(PumpStationContextResolver.ambiguityDistanceDeltaMeters == 10)
    }

    @Test("Two stations with a clear nearest winner match the nearest, not ambiguous")
    func matchesNearestWhenNotAmbiguous() {
        let near = savedCandidate(id: "near", name: "Near Station", meters: 5)
        let far = savedCandidate(id: "far", name: "Far Station", meters: 30) // 25 m apart — well beyond the ambiguity delta
        let result = resolve(candidates: [far, near])
        #expect(result == .matched(near))
    }

    @Test("Location unavailable (no fix) is reported distinctly from a rejected fix")
    func reportsLocationUnavailable() {
        let station = savedCandidate(meters: 3)
        let result = PumpStationContextResolver.resolve(
            candidates: [station],
            freshLatitude: nil,
            freshLongitude: nil,
            horizontalAccuracyMeters: nil,
            locationTimestamp: nil,
            now: now
        )
        #expect(result == .locationUnavailable)
    }

    @Test("Saved station resolves correctly when the live cache is empty")
    func worksWithSavedOnlyNoLiveCandidates() {
        let station = savedCandidate(meters: 5)
        let result = resolve(candidates: [station]) // no live candidates passed at all
        #expect(result == .matched(station))
    }

    @Test("PumpProximity's automatic-prompt thresholds stay independent of this resolver's manual-context radius")
    func pumpProximityThresholdsIndependentOfManualResolver() {
        // These are PumpProximity's real-world-calibrated values (see PumpProximity.swift) —
        // asserted here only to guard against this file's manual-context tests silently
        // masking a change to the automatic prompt's own, separately maintained thresholds.
        #expect(PumpProximity.atPumpEntryRadiusMeters == 30.0)
        #expect(PumpProximity.atPumpExitRadiusMeters == 75.0)
        #expect(PumpProximity.maximumPumpModeLocationAccuracyMeters == 50.0)
    }

    @Test("A candidate matchable at the 40 m manual-context radius does not become eligible for the automatic prompt")
    func manualRadiusNeverFeedsAutomaticPrompt() {
        // 35 m is comfortably inside the manual context radius (40 m) but outside
        // PumpProximity's 30 m entry radius — the automatic prompt must still refuse it.
        let station = savedCandidate(meters: 35)
        let result = resolve(candidates: [station])
        #expect(result == .matched(station))
        #expect(PumpProximity.isAtPump(distanceMeters: 35, horizontalAccuracyMeters: 5, wasAtPump: false) == false)
    }
}

struct RecentLiveStationCacheTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func liveStation(name: String = "Cached Station", latitude: Double = 40.0, longitude: Double = -83.0) -> LiveFuelStation {
        LiveFuelStation(name: name, address: "123 Main St", city: "Columbus", state: "OH", zip: "43215", latitude: latitude, longitude: longitude)
    }

    @Test("An expired live-result cache is ignored")
    func expiredCacheIsIgnored() async {
        let cache = await RecentLiveStationCache()
        await cache.replace(with: [liveStation()], fetchedAt: now.addingTimeInterval(-(RecentLiveStationCache.cacheLifetime + 1)))
        let entries = await cache.currentEntries(now: now)
        #expect(entries.isEmpty)
    }

    @Test("A recent live-result cache is eligible")
    func recentCacheIsEligible() async {
        let cache = await RecentLiveStationCache()
        await cache.replace(with: [liveStation()], fetchedAt: now.addingTimeInterval(-60))
        let entries = await cache.currentEntries(now: now)
        #expect(entries.count == 1)
        #expect(entries.first?.name == "Cached Station")
    }

    @Test("Cache at the exact lifetime boundary is still eligible")
    func cacheAtExactLifetimeBoundaryIsEligible() async {
        let cache = await RecentLiveStationCache()
        await cache.replace(with: [liveStation()], fetchedAt: now.addingTimeInterval(-RecentLiveStationCache.cacheLifetime))
        let entries = await cache.currentEntries(now: now)
        #expect(entries.count == 1)
    }

    @Test("An empty cache (nothing ever fetched) yields no entries")
    func emptyCacheYieldsNoEntries() async {
        let cache = await RecentLiveStationCache()
        let entries = await cache.currentEntries(now: now)
        #expect(entries.isEmpty)
    }

    @Test("A live station with invalid coordinates is excluded when caching")
    func excludesInvalidCoordinatesFromCache() async {
        let cache = await RecentLiveStationCache()
        await cache.replace(with: [liveStation(latitude: 0, longitude: 0)], fetchedAt: now)
        let entries = await cache.currentEntries(now: now)
        #expect(entries.isEmpty)
    }
}

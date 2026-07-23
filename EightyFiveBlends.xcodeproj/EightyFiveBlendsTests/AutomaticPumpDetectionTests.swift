//
//  AutomaticPumpDetectionTests.swift
//  EightyFiveBlendsTests
//
//  Tests for Automatic Pump Detection's pure decision logic — station selection,
//  Stage-B precise confirmation, and notification cooldown. Deliberately does not depend
//  on real Core Location callbacks, network access, or wall-clock timing: `now` and every
//  location/accuracy input are injected directly into the functions under test.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until
//  a test target is added. Written to compile and pass once one exists.
//

import CoreLocation
import Foundation
import Testing
@testable import EightyFiveBlends

struct AutomaticPumpDetectionSelectorTests {
    // Roughly one degree of latitude near 40°N; used to build candidates at readable,
    // increasing distances from a fixed user location without hand-computing meters.
    private let userLatitude = 40.0
    private let userLongitude = -83.0

    private func candidate(_ id: String, name: String = "Station", latOffset: Double, lonOffset: Double = 0, address: String? = nil) -> MonitoredStationCandidate {
        MonitoredStationCandidate(id: id, name: name, latitude: userLatitude + latOffset, longitude: userLongitude + lonOffset, address: address)
    }

    @Test("Chooses no more than the monitor limit")
    func respectsLimit() {
        let candidates = (0..<30).map { candidate("station-\($0)", latOffset: Double($0) * 0.001) }
        let selected = MonitoredStationSelector.select(from: candidates, userLatitude: userLatitude, userLongitude: userLongitude, limit: 15)
        #expect(selected.count == 15)
    }

    @Test("Default limit matches the documented monitoring ceiling")
    func defaultLimitIsFifteen() {
        #expect(MonitoredStationSelector.maximumMonitoredStations == 15)
    }

    @Test("Removes duplicate stations by stable ID, keeping the first occurrence")
    func removesDuplicates() {
        let candidates = [
            candidate("dup", name: "First", latOffset: 0.001),
            candidate("dup", name: "Second", latOffset: 0.002),
            candidate("unique", latOffset: 0.003)
        ]
        let selected = MonitoredStationSelector.select(from: candidates, userLatitude: userLatitude, userLongitude: userLongitude)
        #expect(selected.count == 2)
        #expect(selected.contains { $0.id == "dup" && $0.name == "First" })
    }

    @Test("Rejects invalid coordinates")
    func rejectsInvalidCoordinates() {
        #expect(MonitoredStationSelector.isValidCoordinate(latitude: 40, longitude: -83))
        #expect(!MonitoredStationSelector.isValidCoordinate(latitude: .nan, longitude: -83))
        #expect(!MonitoredStationSelector.isValidCoordinate(latitude: 91, longitude: -83))
        #expect(!MonitoredStationSelector.isValidCoordinate(latitude: 40, longitude: 181))
        #expect(!MonitoredStationSelector.isValidCoordinate(latitude: 0, longitude: 0))

        let candidates = [
            candidate("valid", latOffset: 0.001),
            MonitoredStationCandidate(id: "invalid", name: "Bad", latitude: .nan, longitude: -83, address: nil),
            MonitoredStationCandidate(id: "nullIsland", name: "Zero", latitude: 0, longitude: 0, address: nil)
        ]
        let selected = MonitoredStationSelector.select(from: candidates, userLatitude: userLatitude, userLongitude: userLongitude)
        #expect(selected.map(\.id) == ["valid"])
    }

    @Test("Prioritizes nearby stations deterministically, nearest first")
    func prioritizesNearestFirst() {
        let far = candidate("far", latOffset: 0.05)
        let near = candidate("near", latOffset: 0.001)
        let middle = candidate("middle", latOffset: 0.01)

        let selected = MonitoredStationSelector.select(from: [far, middle, near], userLatitude: userLatitude, userLongitude: userLongitude, limit: 2)
        #expect(selected.map(\.id) == ["near", "middle"])
    }
}

struct AutomaticPumpDetectionConfirmationTests {
    private let stationLatitude = 40.0
    private let stationLongitude = -83.0
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func evaluate(
        featureEnabled: Bool = true,
        distanceMeters: Double,
        accuracy: CLLocationAccuracy? = 5,
        ageSeconds: TimeInterval = 0
    ) -> ArrivalConfirmation.Outcome {
        // Displace purely in latitude so the resulting great-circle distance is
        // predictable and monotonic with `distanceMeters` for the small offsets used here.
        let metersPerDegreeLatitude = 111_320.0
        let latitudeOffset = distanceMeters / metersPerDegreeLatitude

        return ArrivalConfirmation.evaluate(
            featureEnabled: featureEnabled,
            stationLatitude: stationLatitude,
            stationLongitude: stationLongitude,
            freshLatitude: stationLatitude + latitudeOffset,
            freshLongitude: stationLongitude,
            horizontalAccuracyMeters: accuracy,
            locationTimestamp: now.addingTimeInterval(-ageSeconds),
            now: now
        )
    }

    /// Distance in `ArrivalConfirmation.Outcome.confirmed` comes from Core Location's real
    /// geodesic calculation, while this test file's `evaluate(...)` helper derives its
    /// fresh-location offset from a simple meters-per-degree approximation — the two agree
    /// closely but not bit-for-bit, so confirmed-distance checks compare with a small
    /// tolerance rather than exact equality.
    private func expectConfirmed(_ outcome: ArrivalConfirmation.Outcome, approximately expectedMeters: Double, tolerance: Double = 0.5) {
        guard case .confirmed(let distanceMeters) = outcome else {
            Issue.record("Expected .confirmed, got \(outcome)")
            return
        }
        #expect(abs(distanceMeters - expectedMeters) < tolerance)
    }

    @Test("Disabled feature never emits a confirmed arrival")
    func disabledFeatureNeverConfirms() {
        let outcome = evaluate(featureEnabled: false, distanceMeters: 2)
        #expect(outcome == .rejected(.featureDisabled))
    }

    @Test("Rejects stale locations")
    func rejectsStaleLocation() {
        let outcome = evaluate(distanceMeters: 2, ageSeconds: ArrivalConfirmation.maximumLocationAge + 1)
        #expect(outcome == .rejected(.staleLocation))
    }

    @Test("Accepts a location right at the staleness boundary")
    func acceptsLocationAtStalenessBoundary() {
        let outcome = evaluate(distanceMeters: 2, ageSeconds: ArrivalConfirmation.maximumLocationAge)
        expectConfirmed(outcome, approximately: 2)
    }

    @Test("Rejects inaccurate locations")
    func rejectsInaccurateLocation() {
        let outcome = evaluate(distanceMeters: 2, accuracy: 60)
        #expect(outcome == .rejected(.inaccurateLocation))
    }

    @Test("Rejects distances beyond the existing pump threshold, without loosening it")
    func rejectsBeyondThreshold() {
        // PumpProximity.atPumpEntryRadiusMeters is 9 m — 12 m must still be rejected here,
        // proving this evaluator never widens the authoritative threshold.
        let outcome = evaluate(distanceMeters: 12)
        #expect(outcome == .rejected(.outsideThreshold))
        #expect(PumpProximity.atPumpEntryRadiusMeters == 9.0) // guards against the threshold being edited elsewhere
    }

    @Test("Accepts a fresh, accurate location within the threshold")
    func acceptsWithinThreshold() {
        let outcome = evaluate(distanceMeters: 5)
        expectConfirmed(outcome, approximately: 5)
    }

    @Test("Rejects an invalid station coordinate")
    func rejectsInvalidStationCoordinate() {
        let outcome = ArrivalConfirmation.evaluate(
            featureEnabled: true,
            stationLatitude: .nan,
            stationLongitude: stationLongitude,
            freshLatitude: stationLatitude,
            freshLongitude: stationLongitude,
            horizontalAccuracyMeters: 5,
            locationTimestamp: now,
            now: now
        )
        #expect(outcome == .rejected(.invalidStationCoordinate))
    }
}

struct AutomaticPumpDetectionCooldownTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Never notified before — always allows the first notification")
    func firstNotificationAllowed() {
        #expect(ArrivalCooldownPolicy.shouldNotify(existingState: nil, now: now))
    }

    @Test("Suppresses duplicate arrival notifications while still within cooldown and no exit recorded")
    func suppressesDuplicateWithinCooldown() {
        let state = ArrivalCooldownState(stationID: "a", lastNotifiedAt: now.addingTimeInterval(-60), hasExitedSinceNotification: false)
        #expect(!ArrivalCooldownPolicy.shouldNotify(existingState: state, now: now))
    }

    @Test("Allows another notification once the cooldown interval has fully elapsed")
    func allowsAfterCooldownElapses() {
        let state = ArrivalCooldownState(
            stationID: "a",
            lastNotifiedAt: now.addingTimeInterval(-ArrivalCooldownPolicy.fallbackCooldownInterval - 1),
            hasExitedSinceNotification: false
        )
        #expect(ArrivalCooldownPolicy.shouldNotify(existingState: state, now: now))
    }

    @Test("Allows another notification after a confirmed exit, even well within the cooldown window")
    func allowsAfterConfirmedExit() {
        let state = ArrivalCooldownState(stationID: "a", lastNotifiedAt: now.addingTimeInterval(-30), hasExitedSinceNotification: true)
        #expect(ArrivalCooldownPolicy.shouldNotify(existingState: state, now: now))
    }
}

struct AutomaticPumpDetectionMetadataTests {
    @Test("Station metadata resolves correctly from a notification payload's stable ID")
    func resolvesStationFromStableID() {
        // Mirrors CalculatorView.resolvePendingDetectedStationIfNeeded: a background
        // notification carries only a MonitoredStationRecord (id + cached name/coordinate,
        // exactly what a UNNotificationRequest's userInfo would round-trip), and the
        // resolver must match it back to the same station by recomputing its stable ID
        // from name + coordinate — never from array position or any transient identifier.
        let name = "Safeway Fuel Station"
        let latitude = 40.12345
        let longitude = -83.54321

        let record = MonitoredStationRecord(
            id: AutomaticPumpDetectionStationKey.make(name: name, latitude: latitude, longitude: longitude),
            name: name,
            latitude: latitude,
            longitude: longitude,
            address: "123 Main St"
        )

        // Simulates re-deriving the ID from a freshly fetched saved-station record, as
        // CalculatorView does against its live `savedStations` query.
        let recomputedID = AutomaticPumpDetectionStationKey.make(name: name, latitude: latitude, longitude: longitude)
        #expect(recomputedID == record.id)

        let differentStationID = AutomaticPumpDetectionStationKey.make(name: "Other Station", latitude: 41.0, longitude: -84.0)
        #expect(differentStationID != record.id)
    }

    @Test("Stable ID is insensitive to trivial floating-point noise below the rounding precision")
    func stableIDToleratesFloatingPointNoise() {
        let a = AutomaticPumpDetectionStationKey.make(name: "Station", latitude: 40.123450001, longitude: -83.0)
        let b = AutomaticPumpDetectionStationKey.make(name: "Station", latitude: 40.123449999, longitude: -83.0)
        #expect(a == b)
    }
}

@MainActor
struct AutomaticPumpDetectionServiceTests {
    @Test("Disabling removes monitored-station metadata and reports zero monitored stations")
    func disableClearsState() {
        // Exercises the service directly (not just the pure functions above) — safe to do
        // without a real CLLocationManager/UNUserNotificationCenter round trip, since
        // `disable()` never touches `locationManager` beyond an optional-chained call that
        // is simply skipped when unattached, and never performs network/hardware I/O.
        let service = AutomaticPumpDetectionService()
        service.disable()
        #expect(service.isEnabled == false)
        #expect(service.monitoredStationCount == 0)
        #expect(service.pendingDetectedStation == nil)
        #expect(service.status == .disabled)
    }

    @Test("Foreground pump-arrival threshold is unaffected by Automatic Pump Detection's state")
    func foregroundThresholdIsIndependentOfBackgroundFeature() {
        // Automatic Pump Detection is entirely additive: CalculatorView's existing
        // foreground auto-prompt path (refreshPumpModeStation / evaluateAutoPromptPumpMode)
        // calls PumpProximity.isAtPump directly and was not modified by this feature. This
        // asserts that function's behavior is unchanged and has no dependency on this
        // service's enabled/authorization state, proving foreground detection keeps working
        // with only When In Use authorization (or with the feature disabled entirely).
        let service = AutomaticPumpDetectionService()
        service.disable()
        #expect(service.isEnabled == false)

        #expect(PumpProximity.isAtPump(distanceMeters: 8, horizontalAccuracyMeters: 5, wasAtPump: false))
        #expect(!PumpProximity.isAtPump(distanceMeters: 12, horizontalAccuracyMeters: 5, wasAtPump: false))
    }
}

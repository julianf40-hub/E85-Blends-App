//
//  PumpProximityTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the At the Pump proximity trigger: entry/exit hysteresis and the
//  horizontal-accuracy gate, including the coarse-fix stale-latch fix.
//

import CoreLocation
import Testing
@testable import EightyFiveBlends

struct PumpProximityTests {

    @Test("Enters at the tight radius with a good fix")
    func entersAtEntryRadius() {
        #expect(PumpProximity.isAtPump(distanceMeters: 8, horizontalAccuracyMeters: 5, wasAtPump: false))
        #expect(!PumpProximity.isAtPump(distanceMeters: 12, horizontalAccuracyMeters: 5, wasAtPump: false))
    }

    @Test("Hysteresis: stays latched inside exit radius, releases beyond it")
    func hysteresis() {
        #expect(PumpProximity.isAtPump(distanceMeters: 20, horizontalAccuracyMeters: 5, wasAtPump: true))
        #expect(!PumpProximity.isAtPump(distanceMeters: 30, horizontalAccuracyMeters: 5, wasAtPump: true))
        #expect(!PumpProximity.isAtPump(distanceMeters: 20, horizontalAccuracyMeters: 5, wasAtPump: false))
    }

    @Test("Coarse fix never turns pump mode ON")
    func coarseFixNoEntry() {
        #expect(!PumpProximity.isAtPump(distanceMeters: 5, horizontalAccuracyMeters: 60, wasAtPump: false))
        #expect(!PumpProximity.isAtPump(distanceMeters: 5, horizontalAccuracyMeters: nil, wasAtPump: false))
    }

    @Test("Ambiguous coarse fix keeps the previous state")
    func coarseFixKeepsState() {
        // 100 m away with 150 m error: could still be at the pump — keep latched.
        #expect(PumpProximity.isAtPump(distanceMeters: 100, horizontalAccuracyMeters: 150, wasAtPump: true))
        #expect(PumpProximity.isAtPump(distanceMeters: 5, horizontalAccuracyMeters: nil, wasAtPump: true))
    }

    @Test("Unambiguously distant coarse fix clears the latch")
    func coarseFixClearsWhenClearlyFar() {
        // 8 km away with 150 m error: cannot be at the pump — release.
        #expect(!PumpProximity.isAtPump(distanceMeters: 8000, horizontalAccuracyMeters: 150, wasAtPump: true))
    }

    @Test("Negative accuracy is treated as unreliable")
    func negativeAccuracyUnreliable() {
        #expect(!PumpProximity.isAtPump(distanceMeters: 5, horizontalAccuracyMeters: -1, wasAtPump: false))
        #expect(PumpProximity.isAtPump(distanceMeters: 8000, horizontalAccuracyMeters: -1, wasAtPump: true))
    }
}

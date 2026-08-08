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
        // Entry radius is 30 m — see PumpProximity.atPumpEntryRadiusMeters.
        #expect(PumpProximity.isAtPump(distanceMeters: 25, horizontalAccuracyMeters: 5, wasAtPump: false))
        #expect(!PumpProximity.isAtPump(distanceMeters: 35, horizontalAccuracyMeters: 5, wasAtPump: false))
    }

    @Test("Hysteresis: stays latched inside exit radius, releases beyond it")
    func hysteresis() {
        // Entry radius is 30 m, exit radius is 75 m — 50 m sits in the hysteresis band:
        // too far to newly enter, but close enough to stay latched once already at the pump.
        #expect(PumpProximity.isAtPump(distanceMeters: 50, horizontalAccuracyMeters: 5, wasAtPump: true))
        #expect(!PumpProximity.isAtPump(distanceMeters: 80, horizontalAccuracyMeters: 5, wasAtPump: true))
        #expect(!PumpProximity.isAtPump(distanceMeters: 50, horizontalAccuracyMeters: 5, wasAtPump: false))
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

    @Test("rejectionReason is nil exactly when isAtPump is true")
    func rejectionReasonNilOnSuccess() {
        #expect(PumpProximity.rejectionReason(distanceMeters: 25, horizontalAccuracyMeters: 5, wasAtPump: false) == nil)
    }

    @Test("rejectionReason explains a missing/unreliable fix")
    func rejectionReasonMissingFix() {
        #expect(PumpProximity.rejectionReason(distanceMeters: 5, horizontalAccuracyMeters: nil, wasAtPump: false) != nil)
        #expect(PumpProximity.rejectionReason(distanceMeters: 5, horizontalAccuracyMeters: -1, wasAtPump: false) != nil)
    }

    @Test("rejectionReason explains a too-coarse fix distinctly from a too-far distance")
    func rejectionReasonDistinguishesAccuracyFromDistance() {
        // Accuracy alone fails the gate (60 m > the 50 m max) — reason should mention accuracy.
        let accuracyReason = PumpProximity.rejectionReason(distanceMeters: 5, horizontalAccuracyMeters: 60, wasAtPump: false)
        #expect(accuracyReason?.localizedCaseInsensitiveContains("accuracy") == true)

        // Accuracy is fine but the station is beyond the entry radius — reason should mention distance, not accuracy.
        let distanceReason = PumpProximity.rejectionReason(distanceMeters: 35, horizontalAccuracyMeters: 5, wasAtPump: false)
        #expect(distanceReason?.localizedCaseInsensitiveContains("away") == true)
        #expect(distanceReason?.localizedCaseInsensitiveContains("accuracy") == false)
    }
}

/// Tests for the "At the Pump?" auto-prompt's per-visit suppression rule (see
/// PumpVisitPromptPolicy in PumpProximity.swift and CalculatorView's
/// evaluateAutoPromptPumpMode()/clearPumpModeStation()). Covers the scenarios that matter in
/// practice: no repeat-prompt spam while parked at the same station, "Not Now" holding for the
/// rest of that visit, and a later, separate visit becoming eligible again — all without any
/// calendar-based/multi-day cooldown, matching the codebase's visit-based suppression design.
struct PumpVisitPromptPolicyTests {
    @Test("First arrival at a station is eligible to prompt")
    func firstArrivalPrompts() {
        #expect(PumpVisitPromptPolicy.shouldPrompt(hasPromptedForCurrentVisit: false, isAuthorized: true))
    }

    @Test("Remaining inside the station's radius after prompting does not prompt again (no spam)")
    func remainingInsideDoesNotRepromptWithinSameVisit() {
        // Simulates evaluateAutoPromptPumpMode() being called repeatedly (e.g. by the
        // periodic foreground re-check) while still parked at the same station: once
        // hasPromptedForCurrentVisit flips true, further calls with the same flag must stay
        // silent for the remainder of this visit — whether the user tapped "Not Now" or simply
        // hasn't responded to the alert yet, the underlying state is identical.
        #expect(!PumpVisitPromptPolicy.shouldPrompt(hasPromptedForCurrentVisit: true, isAuthorized: true))
    }

    @Test("Leaving and returning later makes the prompt eligible again")
    func reEntryAfterLeavingIsEligibleAgain() {
        // Mirrors CalculatorView.clearPumpModeStation(), which resets
        // hasPromptedForCurrentPumpVisit to false whenever pumpModeStation clears (i.e. the
        // user left the exit radius) — a later, separate arrival starts from this same
        // "never yet prompted this visit" state, so it is eligible again.
        let stateAfterLeavingAndReturning = false // clearPumpModeStation() reset this to false
        #expect(PumpVisitPromptPolicy.shouldPrompt(hasPromptedForCurrentVisit: stateAfterLeavingAndReturning, isAuthorized: true))
    }

    @Test("Never prompts without at least When In Use authorization, regardless of visit state")
    func unauthorizedNeverPrompts() {
        #expect(!PumpVisitPromptPolicy.shouldPrompt(hasPromptedForCurrentVisit: false, isAuthorized: false))
        #expect(!PumpVisitPromptPolicy.shouldPrompt(hasPromptedForCurrentVisit: true, isAuthorized: false))
    }
}

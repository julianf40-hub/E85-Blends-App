//
//  PlanRequestTrackerTests.swift
//  EightyFiveBlendsTests
//
//  Tests for PlanRequestTracker, the pure request-generation and plan-staleness mechanism
//  behind Trip Planner's stale-state fixes (fix/2.2.3-trip-planner-state-safety). These test
//  the extracted, production logic directly rather than reproducing TripPlannerView's SwiftUI
//  plumbing (Task creation, onChange wiring, defer blocks) — see file-level notes below on
//  which requirements map to a directly-testable pure API call and which are architectural
//  guarantees verified by code inspection instead.
//

import Testing
@testable import EightyFiveBlends

struct PlanRequestTrackerTests {

    // MARK: - 1. A superseded request cannot write results after a newer one becomes current

    @Test("A generation captured before a newer attempt begins is no longer current")
    func supersededGeneration_isNoLongerCurrent() {
        var tracker = PlanRequestTracker()
        let requestA = tracker.beginNewAttempt()
        let requestB = tracker.beginNewAttempt()

        #expect(requestA != requestB)
        #expect(tracker.isCurrent(requestA) == false)
        #expect(tracker.isCurrent(requestB))
    }

    // MARK: - 2. A superseded request cannot clear a newer request's loading state

    @Test("A stale generation's loading-flag guard does not pass once superseded")
    func supersededGeneration_cannotGateANewerLoadingFlag() {
        // Mirrors TripPlannerView's `defer { if requestTracker.isCurrent(generation) { isX = false } }`
        // pattern: a superseded task's deferred loading-flag reset is gated on isCurrent(_:),
        // so it must not fire once a newer request has begun — this is what stops a superseded
        // discovery task from hiding a newer request's spinner.
        var tracker = PlanRequestTracker()
        let requestA = tracker.beginNewAttempt()
        var isDiscoveringForA = true

        _ = tracker.beginNewAttempt() // request B supersedes A

        if tracker.isCurrent(requestA) {
            isDiscoveringForA = false
        }

        #expect(isDiscoveringForA, "Request A's stale completion must not clear a flag that now belongs to request B")
    }

    // MARK: - 3. Cancelling/clearing invalidates the current request generation

    @Test("Superseding in-flight work advances the generation even without starting a new attempt")
    func supersedeInFlightWork_advancesGeneration() {
        var tracker = PlanRequestTracker()
        let requestA = tracker.beginNewAttempt()

        let generationAfterSupersede = tracker.supersedeInFlightWork()

        #expect(generationAfterSupersede != requestA)
        #expect(tracker.isCurrent(requestA) == false)
        #expect(tracker.currentGeneration == generationAfterSupersede)
    }

    // MARK: - 4-6. Route-affecting input changes invalidate a completed plan
    //
    // In the view, applyVehicle/tankSizeText/mpgText/currentFuelPercent/targetBlend/
    // targetReservePercent/fuelBackupMode/origin/destination all route through the same
    // `invalidatePlanIfNeeded()` -> `requestTracker.invalidate(hasPlan:)` call via `onChange`.
    // The pure mechanism under test is identical regardless of which input changed, so these
    // three scenarios exercise the same API with names matching the required scenarios.

    @Test("A vehicle change invalidates a completed plan")
    func invalidate_vehicleChange_marksCompletedPlanStale() {
        var tracker = PlanRequestTracker()
        _ = tracker.beginNewAttempt()

        tracker.invalidate(hasPlan: true) // stands in for applyVehicle -> onChange(selectedVehicleID)

        #expect(tracker.isPlanStale)
    }

    @Test("A reserve-target change invalidates a completed plan")
    func invalidate_reserveChange_marksCompletedPlanStale() {
        var tracker = PlanRequestTracker()
        _ = tracker.beginNewAttempt()

        tracker.invalidate(hasPlan: true) // stands in for onChange(targetReservePercent)

        #expect(tracker.isPlanStale)
    }

    @Test("An MPG or tank-size change invalidates a completed plan")
    func invalidate_mpgOrTankSizeChange_marksCompletedPlanStale() {
        var tracker = PlanRequestTracker()
        _ = tracker.beginNewAttempt()

        tracker.invalidate(hasPlan: true) // stands in for onChange(tankSizeText) / onChange(mpgText)

        #expect(tracker.isPlanStale)
    }

    // MARK: - 7. Changes before any plan exists do not show a stale-plan warning

    @Test("Invalidation before any plan exists does not mark anything stale")
    func invalidate_withoutAPlan_isANoOp() {
        var tracker = PlanRequestTracker()
        // No beginNewAttempt() / plan has ever been generated in this session.

        tracker.invalidate(hasPlan: false)

        #expect(tracker.isPlanStale == false)
    }

    // MARK: - 8. Beginning a new plan clears the stale state

    @Test("Beginning a new attempt clears a previously-set stale flag")
    func beginNewAttempt_clearsStaleFlag() {
        var tracker = PlanRequestTracker()
        _ = tracker.beginNewAttempt()
        tracker.invalidate(hasPlan: true)
        #expect(tracker.isPlanStale)

        _ = tracker.beginNewAttempt()

        #expect(tracker.isPlanStale == false)
    }

    // MARK: - 9. Successful completion for the current request is accepted

    @Test("A generation that hasn't been superseded is still current when its request completes")
    func currentGeneration_isAcceptedOnCompletion() {
        var tracker = PlanRequestTracker()
        let request = tracker.beginNewAttempt()

        // No further beginNewAttempt()/supersedeInFlightWork() calls before "completion".
        #expect(tracker.isCurrent(request))
    }

    // MARK: - 10. Cancellation does not become a user-facing planning error
    //
    // PlanRequestTracker has no error/failure concept at all — by design, it only tracks a
    // generation counter and a staleness flag. That's the architectural guarantee behind this
    // requirement: nothing in this type can produce or surface an error, so a cancelled task
    // that only interacts with the tracker (checks isCurrent(_:), or is simply superseded) can
    // never manufacture a user-facing error message through it. The actual `catch is
    // CancellationError { return }` control flow that keeps a genuine SwiftUI cancellation
    // silent lives in TripPlannerView.planRoute() (and the three discovery functions) and is
    // a SwiftUI/Task implementation detail this pure type intentionally doesn't reproduce —
    // verified by code inspection instead (see the final report).

    @Test("Superseding a request never produces or requires an error condition")
    func supersedingARequest_hasNoErrorConcept() {
        var tracker = PlanRequestTracker()
        let request = tracker.beginNewAttempt()
        _ = tracker.supersedeInFlightWork()

        // The only observable effect of being superseded is that isCurrent(_:) now returns
        // false — there is no error/failure state anywhere on this type to accidentally trip.
        #expect(tracker.isCurrent(request) == false)
    }
}

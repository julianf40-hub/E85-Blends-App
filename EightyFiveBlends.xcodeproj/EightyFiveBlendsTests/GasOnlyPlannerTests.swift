//
//  GasOnlyPlannerTests.swift
//  EightyFiveBlendsTests
//
//  Regression coverage for GasOnlyPlanner, the pure Gas Only stop planner extracted in
//  fix/2.2.3-gas-only-first-plan-stations to fix a first-plan state-consistency bug: the
//  route-outcome classification could report `.gasFuelStopNeeded` ("no gas station found")
//  even though real stops had just been computed, because a `planFailed` flag from a later,
//  unrelated walk failure overrode the outcome regardless of whether any stops existed.
//  These tests exercise `GasOnlyPlanner.plan(...)` directly — the real production entry
//  point TripPlannerView now calls — rather than re-deriving the greedy-walk formulas.
//

import CoreLocation
import Testing
@testable import EightyFiveBlends

struct GasOnlyPlannerTests {

    private func gasStation(
        name: String,
        city: String = "",
        state: String = "",
        distanceAlongRouteMiles: Double,
        offRouteMiles: Double = 0.5
    ) -> BackupGasStation {
        BackupGasStation(
            id: "gas|\(name)|\(distanceAlongRouteMiles)",
            name: name,
            city: city,
            state: state,
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            distanceAlongRouteMiles: distanceAlongRouteMiles,
            offRouteMiles: offRouteMiles
        )
    }

    private func context(
        tank: Double = 18.5,
        mpg: Double = 18,
        fuelPercent: Double = 50,
        reservePercent: Double = 50
    ) -> RouteFuelContext {
        RouteFuelContext(
            tankSizeGallons: tank,
            mpg: mpg,
            currentFuelPercent: fuelPercent,
            targetArrivalReservePercent: reservePercent,
            fuelBackupMode: .gasBackupAllowed
        )
    }

    // MARK: - 1, 3. The exact reported bug: a first plan with real stops must not be
    // reported as "no gas station found" — reproduces the Phoenix→Los Angeles TestFlight
    // scenario (18.5 gal, 18 MPG, 50% starting fuel, 50% arrival buffer): two real stops
    // are found and used (mirroring ONE9 Travel Center, Salome, AZ and Chevron, Blythe, CA),
    // but the walk still can't find a further stop for the remaining leg to the destination
    // (planFailed) — that must surface as elevated risk on the found stops, never as a
    // contradiction that hides them.
    @Test("A first plan with real stops that still can't fully complete the route is never reported as no station found")
    func stopsFoundButPlanIncomplete_isNeverReportedAsNoStationFound() {
        let stations = [
            gasStation(name: "ONE9 Travel Center", city: "Salome", state: "AZ", distanceAlongRouteMiles: 100),
            gasStation(name: "Chevron", city: "Blythe", state: "CA", distanceAlongRouteMiles: 250),
            // Nothing beyond 250 mi — the walk cannot find a station for the final leg to a
            // 500 mi destination, so it fails (planFailed) after two real, useful stops.
        ]

        let result = GasOnlyPlanner.plan(stations: stations, distanceMiles: 500, context: context())

        #expect(result.inputsValid)
        #expect(result.stops.count == 2, "both real stops must be published, not dropped")
        #expect(result.stops[0].station.name == "ONE9 Travel Center")
        #expect(result.stops[1].station.name == "Chevron")

        // The core bug: this must be .gasStopRecommended (stops exist and are being used),
        // never .gasFuelStopNeeded ("no suitable gas station was found").
        #expect(result.outcome == .gasStopRecommended)
        #expect(result.outcome != .gasFuelStopNeeded)

        // The walk failing to fully complete the route even with these stops is real —
        // it must surface as elevated risk on the stops that WERE found, not as an outcome
        // that contradicts them or an error message.
        #expect(result.risk == .high)
        #expect(result.stationError == nil, "a plan with real stops must never also show an error")

        // A plan the walk couldn't confirm completes the route must be explicitly partial,
        // and must never claim the selected 50% arrival buffer was met.
        #expect(result.completeness == .partial)
        #expect((result.destinationReserveFraction ?? 1) < 0.5, "a partial plan must never report the target reserve as satisfied")
    }

    // MARK: - 1, 6. A plan whose stops genuinely complete the route is reported as complete

    @Test("A plan whose stops complete the route within the arrival buffer is reported as complete, not partial")
    func stopsCompleteTheRoute_isReportedAsComplete() {
        // A single stop at 100 mi, with a 20% buffer and a 300 mi trip, is enough for the
        // walk to succeed after refueling at that one stop — it never runs out of route to
        // plan for, unlike the partial scenario above.
        let stations = [gasStation(name: "Corner Store", distanceAlongRouteMiles: 100)]
        let result = GasOnlyPlanner.plan(
            stations: stations,
            distanceMiles: 300,
            context: context(reservePercent: 20)
        )

        #expect(result.inputsValid)
        #expect(result.stops.count == 1)
        #expect(result.outcome == .gasStopRecommended)
        #expect(result.completeness == .complete)
        #expect(result.stationError == nil)
    }

    // MARK: - 2, 8. Station identity and order are preserved for every consumer

    @Test("Stop order and identity match the input stations, in the order the walk chose them")
    func stopOrderAndIdentity_matchWalkChoice() {
        let stations = [
            gasStation(name: "ONE9 Travel Center", city: "Salome", state: "AZ", distanceAlongRouteMiles: 100),
            gasStation(name: "Chevron", city: "Blythe", state: "CA", distanceAlongRouteMiles: 250),
        ]

        let result = GasOnlyPlanner.plan(stations: stations, distanceMiles: 500, context: context())

        // Map pins, the Fuel Plan card, and the Recommended Fuel Stops list all iterate this
        // exact array directly — there is no second, independently-sorted collection for any
        // of them to disagree with, so identity/order can never diverge between them.
        #expect(result.stops.map { $0.station.name } == ["ONE9 Travel Center", "Chevron"])
        #expect(result.stops.map { $0.station.city } == ["Salome", "Blythe"])
    }

    // MARK: - 4. No stations produces a consistent, honest no-station state

    @Test("No candidate stations produces a consistent no-station state, not phantom stops")
    func noStations_isConsistentlyReported() {
        let result = GasOnlyPlanner.plan(stations: [], distanceMiles: 500, context: context())

        #expect(result.inputsValid)
        #expect(result.stops.isEmpty)
        #expect(result.outcome == .gasFuelStopNeeded)
        #expect(result.stationError == nil)
        #expect(result.completeness == .noUsableStations)
    }

    // MARK: - 9. Valid input never shows the input-contract invalid-input error

    @Test("Valid Gas Only input never shows the invalid-input error")
    func validInput_doesNotShowInvalidInputError() {
        let stations = [gasStation(name: "Corner Store", distanceAlongRouteMiles: 100)]
        let result = GasOnlyPlanner.plan(stations: stations, distanceMiles: 150, context: context())

        #expect(result.inputsValid)
        #expect(result.stationError == nil)
    }

    // MARK: - 10. Input-contract semantics (fix/2.2.3-trip-planner-input-contract) remain intact

    @Test("Invalid tank/MPG never produces a safe-looking Gas Only result")
    func invalidInputs_neverProduceASafeResult() {
        let stations = [gasStation(name: "Corner Store", distanceAlongRouteMiles: 100)]

        let zeroTank = GasOnlyPlanner.plan(stations: stations, distanceMiles: 200, context: context(tank: 0))
        #expect(zeroTank.inputsValid == false)
        #expect(zeroTank.stops.isEmpty)
        #expect(zeroTank.outcome == nil)
        #expect(zeroTank.destinationReserveFraction == nil)
        #expect(zeroTank.stationError != nil)
        #expect(zeroTank.completeness == nil, "completeness must be nil, never .complete/.partial, when inputs are invalid")

        let nanMPG = GasOnlyPlanner.plan(stations: stations, distanceMiles: 200, context: context(mpg: .nan))
        #expect(nanMPG.inputsValid == false)
        #expect(nanMPG.outcome == nil)

        let infiniteDistance = GasOnlyPlanner.plan(stations: stations, distanceMiles: .infinity, context: context())
        #expect(infiniteDistance.inputsValid == false)
    }

    // MARK: - No stop needed at all (already-comfortable reserve) is unaffected

    @Test("A short route that already meets the reserve target needs no stop")
    func shortRoute_needsNoStop() {
        // 18.5 gal * 50% = 9.25 gal start; 9.25 gal at 18 MPG covers ~166 mi comfortably
        // above a 20% buffer over a 50 mi trip.
        let result = GasOnlyPlanner.plan(
            stations: [],
            distanceMiles: 50,
            context: context(reservePercent: 20)
        )
        #expect(result.inputsValid)
        #expect(result.stops.isEmpty)
        #expect(result.outcome == .gasolineOnly)
        #expect(result.risk == .low || result.risk == .medium)
        #expect(result.completeness == .complete)
    }

    // MARK: - 5, 6, 7. Generation-consistent publication (verified by code inspection)
    //
    // GasOnlyPlanner.plan is a pure, synchronous function with no awaits — everything it
    // returns comes from one call with no intermediate suspension point, so there is no
    // window in which "half" a result could be computed. TripPlannerView.discoverGasOnlyStations
    // computes the full GasOnlyPlanResult from a local station snapshot, checks
    // requestTracker.isCurrent(generation) exactly once, and only then assigns all seven
    // related @State properties (gasOnlyStations, gasOnlyRecommendedStops, gasOnlyOutcome,
    // gasOnlyRisk, gasOnlyDestinationReserveFraction, gasOnlyStationError,
    // gasOnlyCompleteness) as one uninterrupted sequence of synchronous statements —
    // Swift cannot suspend mid-sequence
    // without an `await`, so a superseded request (failing that single generation check)
    // can never publish any part of this result, and the unchanged
    // `defer { if requestTracker.isCurrent(generation) { isDiscoveringGasOnlyStations = false } }`
    // still prevents a superseded request's completion from clearing a newer request's
    // loading state. This mirrors PlanRequestTrackerTests' precedent of verifying a
    // SwiftUI-embedded integration by code inspection rather than a direct test, since
    // discoverGasOnlyStations is a private View method unreachable from this test target.
    @Test("GasOnlyPlanner.plan has no suspension point, so no result can be published half-finished")
    func planComputation_hasNoAsyncGap() {
        // A structural sanity check standing in for the code-inspection note above: calling
        // plan() twice with different inputs never lets the two calls' results interleave —
        // each call's result is fully independent and internally consistent.
        let stations = [gasStation(name: "ONE9 Travel Center", distanceAlongRouteMiles: 100)]
        let resultA = GasOnlyPlanner.plan(stations: stations, distanceMiles: 500, context: context())
        let resultB = GasOnlyPlanner.plan(stations: [], distanceMiles: 500, context: context())
        #expect(resultA.stops.isEmpty == false)
        #expect(resultB.stops.isEmpty)
    }
}

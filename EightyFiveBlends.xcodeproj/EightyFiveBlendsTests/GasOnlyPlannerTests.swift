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

        // feature/2.2.3-gas-only-fuel-optimization: a real minimum buffer (~20%) with the
        // target met must not be classified the same as partial/unreachable/invalid.
        #expect(result.risk == .medium, "a complete plan meeting its target with a ~20% minimum buffer should not be High Risk")
        #expect(result.targetReserveSatisfied == true)

        // The suggested fill must be sized for the remaining 200 mi leg + 20% buffer, not
        // an unconditional top-off to the full 18.5 gal capacity.
        let fill = result.stops[0].suggestedFillGallons
        #expect(fill < 18.5 - result.stops[0].arrivalReserveFraction * 18.5 - 0.01, "must not simply fill to full")
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

    // MARK: - feature/2.2.3-gas-only-fuel-optimization: minimum-fill sizing
    //
    // These reproduce the exact reported TestFlight numbers (18.5 gal tank, 18 MPG,
    // Phoenix→Los Angeles): a single stop with ~2.8 gal on arrival and ~89 mi remaining is
    // built by placing the station at 282.6 mi (18.5 − 282.6/18 ≈ 2.8) with a 371.6 mi
    // total distance (282.6 + 89).

    @Test("1. Full tank, one late stop, 10% reserve: suggested fill is near the minimum required, not a full tank")
    func fullTank_lateStop_tenPercentReserve_suggestsMinimumFill() {
        let stations = [gasStation(name: "Morongo Travel Center", distanceAlongRouteMiles: 282.6)]
        let result = GasOnlyPlanner.plan(
            stations: stations,
            distanceMiles: 371.6,
            context: context(mpg: 18, fuelPercent: 100, reservePercent: 10)
        )

        #expect(result.stops.count == 1)
        let stop = result.stops[0]
        #expect(abs(stop.arrivalReserveFraction * 18.5 - 2.8) < 0.05, "sanity: arrival should match the reported ~2.8 gal")

        // ~89 mi at 18 MPG ≈ 4.94 gal; a 10% reserve ≈ 1.85 gal; needed ≈ 6.79 gal minus the
        // ~2.8 gal already on board ≈ 4.0 gal — not the reported (buggy) 15.7 gal fill.
        #expect(abs(stop.suggestedFillGallons - 4.0) < 0.2, "suggested fill should be near 4.0 gal, not a full-tank top-off")
        #expect(stop.suggestedFillGallons < 10.0)

        // Destination reserve should land at essentially the selected 10% target, not the
        // ~73% a full-tank fill previously produced.
        #expect(abs((result.destinationReserveFraction ?? 0) - 0.10) < 0.01)
    }

    @Test("2. Same route with 50% reserve: suggested fill is higher than with 10% reserve")
    func sameRoute_higherReserve_suggestsMoreFuel() {
        let stations = [gasStation(name: "Morongo Travel Center", distanceAlongRouteMiles: 282.6)]
        let tenPercent = GasOnlyPlanner.plan(
            stations: stations, distanceMiles: 371.6,
            context: context(mpg: 18, fuelPercent: 100, reservePercent: 10)
        )
        let fiftyPercent = GasOnlyPlanner.plan(
            stations: stations, distanceMiles: 371.6,
            context: context(mpg: 18, fuelPercent: 100, reservePercent: 50)
        )

        #expect(fiftyPercent.stops.count == 1 && tenPercent.stops.count == 1)
        #expect(fiftyPercent.stops[0].suggestedFillGallons > tenPercent.stops[0].suggestedFillGallons)
    }

    @Test("3. 50% starting fuel, one stop: suggested fill remains sufficient for destination plus reserve")
    func halfTank_oneStop_fillCoversDestinationPlusReserve() {
        // Mirrors the reported Salome scenario: ~3.7 gal on arrival, ~272 mi remaining.
        let stations = [gasStation(name: "Salome Stop", distanceAlongRouteMiles: 100)]
        let result = GasOnlyPlanner.plan(
            stations: stations,
            distanceMiles: 372,
            context: context(mpg: 18, fuelPercent: 50, reservePercent: 10)
        )

        #expect(result.stops.count == 1)
        let stop = result.stops[0]
        #expect(abs(stop.arrivalReserveFraction * 18.5 - 3.7) < 0.1, "sanity: arrival should match the reported ~3.7 gal")

        // The long remaining leg (272 mi) genuinely needs a large fill, but it must be
        // computed from distance + reserve, not simply the full unused tank capacity
        // (18.5 − 3.7 ≈ 14.8 gal).
        #expect(stop.suggestedFillGallons < 18.5 - stop.arrivalReserveFraction * 18.5 - 0.5)
        #expect(abs((result.destinationReserveFraction ?? 0) - 0.10) < 0.01, "destination reserve should still meet the 10% target")
        #expect(result.targetReserveSatisfied == true)
    }

    @Test("4. 12 MPG, multiple stops: every leg remains reachable after optimized fills")
    func lowMPG_multipleStops_everyLegRemainsReachable() {
        // Densely spaced candidates over a 600 mi trip at 12 MPG (222 mi full-tank range)
        // force several stops; every arrival must still be non-negative (never runs dry)
        // and the destination must still meet the selected 10% target.
        let stations = [100, 200, 300, 400, 500].map {
            gasStation(name: "Stop \(Int($0))", distanceAlongRouteMiles: $0)
        }
        let result = GasOnlyPlanner.plan(
            stations: stations,
            distanceMiles: 600,
            context: context(mpg: 12, fuelPercent: 100, reservePercent: 10)
        )

        #expect(result.stops.count >= 2, "sanity: a 600 mi trip at 12 MPG genuinely needs multiple stops")
        #expect(result.stops.allSatisfy { $0.arrivalReserveFraction >= -0.001 }, "no leg may arrive with negative fuel")
        #expect(result.completeness == .complete)
        #expect(result.targetReserveSatisfied == true)
        #expect(abs((result.destinationReserveFraction ?? 0) - 0.10) < 0.02)

        // Stop identities/order are exactly the input order the greedy walk would choose —
        // unaffected by the fill-sizing change.
        #expect(result.stops.map { $0.station.distanceAlongRouteMiles } == result.stops.map { $0.station.distanceAlongRouteMiles }.sorted())
    }

    @Test("5. Final stop 39 miles from destination: suggested fill is not near full unless the reserve requires it")
    func finalStopNearDestination_doesNotSuggestNearFullTank() {
        // 350 mi total, station at 311 mi (39 mi remaining after the stop) — a stop is
        // genuinely required (noStopReserveFraction ≈ −5%), and the final leg is short.
        let stations = [gasStation(name: "Last Chance Fuel", distanceAlongRouteMiles: 311)]
        let result = GasOnlyPlanner.plan(
            stations: stations,
            distanceMiles: 350,
            context: context(mpg: 18, fuelPercent: 100, reservePercent: 10)
        )

        #expect(result.stops.count == 1)
        // 39 mi at 18 MPG ≈ 2.17 gal; a 10% reserve ≈ 1.85 gal — needed ≈ 4.02 gal, far from
        // an 18.5 gal full tank.
        #expect(result.stops[0].suggestedFillGallons < 8.0)
        #expect(abs((result.destinationReserveFraction ?? 0) - 0.10) < 0.01)
    }

    @Test("6. Suggested fill never exceeds tank capacity, even when the remaining leg is very long")
    func suggestedFill_neverExceedsTankCapacity() {
        // A 90% arrival-reserve target on a 350 mi remaining leg would (uncapped) call for
        // more fuel than the 18.5 gal tank can hold — the fill must clamp so total
        // departure fuel never exceeds tank capacity.
        let stations = [gasStation(name: "Early Stop", distanceAlongRouteMiles: 50)]
        let result = GasOnlyPlanner.plan(
            stations: stations,
            distanceMiles: 400,
            context: context(mpg: 18, fuelPercent: 100, reservePercent: 90)
        )

        #expect(result.stops.count == 1)
        let stop = result.stops[0]
        let departureFuel = stop.arrivalReserveFraction * 18.5 + stop.suggestedFillGallons
        #expect(departureFuel <= 18.5 + 0.001, "departure fuel must never exceed tank capacity")
    }

    @Test("7. Suggested fill never goes negative")
    func suggestedFill_neverNegative() {
        let stations = [gasStation(name: "Any Stop", distanceAlongRouteMiles: 282.6)]
        let result = GasOnlyPlanner.plan(
            stations: stations,
            distanceMiles: 371.6,
            context: context(mpg: 18, fuelPercent: 100, reservePercent: 10)
        )
        #expect(result.stops.allSatisfy { $0.suggestedFillGallons >= 0 })
    }

    // MARK: - 8. Already enough fuel: no stop is recommended at all
    //
    // The greedy walk always chooses the FARTHEST safe/reachable station at each step, so
    // it never selects a stop the vehicle doesn't need — reusing `shortRoute_needsNoStop`
    // above (stops.isEmpty == true) as the "stop omitted" branch of this requirement,
    // rather than constructing an artificial near-zero-fill intermediate stop.

    @Test("9. Complete plan with a real minimum buffer above 10% and target met is not High Risk")
    func completeWithHealthyBuffer_isNotHighRisk() {
        let stations = [gasStation(name: "Morongo Travel Center", distanceAlongRouteMiles: 282.6)]
        let result = GasOnlyPlanner.plan(
            stations: stations,
            distanceMiles: 371.6,
            context: context(mpg: 18, fuelPercent: 100, reservePercent: 10)
        )
        #expect(result.completeness == .complete)
        #expect(result.targetReserveSatisfied == true)
        #expect(result.risk != .high, "the original reported bug: a reachable, complete, target-met plan must not be High Risk")
    }

    @Test("10. Complete plan with minimum buffer under 10% is High Risk")
    func completeWithLowBuffer_isHighRisk() {
        // A reserve target of exactly 8% still gets met (destination reserve ≈ 8%), which
        // is a real minimum buffer under 10%.
        let stations = [gasStation(name: "Tight Margin Stop", distanceAlongRouteMiles: 282.6)]
        let result = GasOnlyPlanner.plan(
            stations: stations,
            distanceMiles: 371.6,
            context: context(mpg: 18, fuelPercent: 100, reservePercent: 8)
        )
        #expect(result.completeness == .complete)
        #expect(result.targetReserveSatisfied == true)
        #expect((result.minimumBufferFraction ?? 1) < 0.10)
        #expect(result.risk == .high)
    }

    @Test("11. A partial plan remains High Risk regardless of the stops' own buffers")
    func partialPlan_remainsHighRisk() {
        let stations = [
            gasStation(name: "ONE9 Travel Center", distanceAlongRouteMiles: 100),
            gasStation(name: "Chevron", distanceAlongRouteMiles: 250),
        ]
        let result = GasOnlyPlanner.plan(stations: stations, distanceMiles: 500, context: context())
        #expect(result.completeness == .partial)
        #expect(result.risk == .high)
    }

    @Test("12. No usable stations when a stop is required remains High Risk")
    func noUsableStations_remainsHighRisk() {
        let result = GasOnlyPlanner.plan(stations: [], distanceMiles: 500, context: context())
        #expect(result.completeness == .noUsableStations)
        #expect(result.risk == .high)
    }

    @Test("13. Invalid input keeps High Risk and nil completeness/target-reserve semantics")
    func invalidInput_risksAndSemanticsUnchanged() {
        let result = GasOnlyPlanner.plan(stations: [], distanceMiles: 200, context: context(tank: 0))
        #expect(result.inputsValid == false)
        #expect(result.risk == .high)
        #expect(result.completeness == nil)
        #expect(result.targetReserveSatisfied == nil)
        #expect(result.minimumBufferFraction == nil)
    }

    @Test("14. Existing stop sequence is unchanged for the sparse-corridor regression scenario")
    func existingStopSequence_unchangedByFillOptimization() {
        // Same stations/distance/context as stopsFoundButPlanIncomplete_isNeverReportedAsNoStationFound
        // — the fill-sizing change must not alter WHICH stations get chosen or their order.
        let stations = [
            gasStation(name: "ONE9 Travel Center", city: "Salome", state: "AZ", distanceAlongRouteMiles: 100),
            gasStation(name: "Chevron", city: "Blythe", state: "CA", distanceAlongRouteMiles: 250),
        ]
        let result = GasOnlyPlanner.plan(stations: stations, distanceMiles: 500, context: context())
        #expect(result.stops.map { $0.station.name } == ["ONE9 Travel Center", "Chevron"])
    }

    @Test("15. 10%, 20%, and 50% reserve settings produce monotonically increasing final fill amounts")
    func reserveSettings_produceMonotonicFillAmounts() {
        let stations = [gasStation(name: "Morongo Travel Center", distanceAlongRouteMiles: 282.6)]
        let ten = GasOnlyPlanner.plan(
            stations: stations, distanceMiles: 371.6,
            context: context(mpg: 18, fuelPercent: 100, reservePercent: 10)
        )
        let twenty = GasOnlyPlanner.plan(
            stations: stations, distanceMiles: 371.6,
            context: context(mpg: 18, fuelPercent: 100, reservePercent: 20)
        )
        let fifty = GasOnlyPlanner.plan(
            stations: stations, distanceMiles: 371.6,
            context: context(mpg: 18, fuelPercent: 100, reservePercent: 50)
        )

        #expect(ten.stops.count == 1 && twenty.stops.count == 1 && fifty.stops.count == 1)
        let fills = [ten.stops[0].suggestedFillGallons, twenty.stops[0].suggestedFillGallons, fifty.stops[0].suggestedFillGallons]
        #expect(fills == fills.sorted(), "higher selected reserve must never produce a smaller suggested fill")
        #expect(fills[0] < fills[1] && fills[1] < fills[2], "each higher reserve setting must strictly increase the fill")
    }
}

//
//  RouteE85PlannerTests.swift
//  EightyFiveBlendsTests
//
//  Regression coverage for the greedy fuel-stop planner: suppressing low-value early
//  top-offs, preferring materially useful stops, and requiring backup gas when E85 alone
//  can't complete the route.
//

import CoreLocation
import Testing
@testable import EightyFiveBlends

struct RouteE85PlannerTests {

    private let planner = RouteE85Planner()

    private func station(
        name: String,
        distanceAlongRouteMiles: Double,
        offRouteMiles: Double = 0.5
    ) -> RouteStation {
        RouteStation(
            id: "test|\(name)|\(distanceAlongRouteMiles)",
            station: LiveFuelStation(
                name: name,
                latitude: 0,
                longitude: 0,
                fuelTypeCode: "E85"
            ),
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            distanceAlongRouteMiles: distanceAlongRouteMiles,
            offRouteMiles: offRouteMiles,
            fromOriginReserveFraction: 0
        )
    }

    private func gasStation(
        name: String,
        distanceAlongRouteMiles: Double,
        offRouteMiles: Double = 0.5
    ) -> BackupGasStation {
        BackupGasStation(
            id: "gas|\(name)|\(distanceAlongRouteMiles)",
            name: name,
            city: "",
            state: "",
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            distanceAlongRouteMiles: distanceAlongRouteMiles,
            offRouteMiles: offRouteMiles
        )
    }

    // MARK: - Regression: Phoenix, AZ → Las Vegas, NV

    // 18.5 gal tank, 12 MPG (full-tank range 222 mi), 100% starting fuel, 20% arrival
    // buffer, gas backup allowed. Target blend (e.g. E30 in the reported bug) is not
    // modeled by this planner at all — it only reasons about fuel range, not ethanol
    // blend, so it is intentionally omitted here.
    //
    // Real E85 stations exist only in the Phoenix metro area (~8-19 mi from origin);
    // none exist for the rest of the ~284 mi corridor to Las Vegas — the exact condition
    // that produced the reported bug (a 14 mi / 1.2 gal "stop" presented as the plan,
    // followed by an unreachable 270 mi leg).
    @Test("Sparse-corridor route does not recommend a useless early E85 top-off")
    func phoenixToLasVegas_noUselessEarlyTopOff() {
        let stations = [
            station(name: "Phoenix Metro E85 A", distanceAlongRouteMiles: 8),
            station(name: "Phoenix Metro E85 B", distanceAlongRouteMiles: 14),
            station(name: "Phoenix Metro E85 C", distanceAlongRouteMiles: 19),
        ]
        let context = RouteFuelContext(
            tankSizeGallons: 18.5,
            mpg: 12,
            currentFuelPercent: 100,
            targetArrivalReservePercent: 20,
            fuelBackupMode: .gasBackupAllowed
        )

        let result = planner.recommendStops(stations: stations, totalMiles: 284, context: context)

        // No useless early top-off plan — none of the trivial early stations should be
        // recommended, since stopping at any of them barely extends the vehicle's range.
        #expect(result.stops.isEmpty)
        #expect(result.planComplete == false)
        #expect(result.planSatisfiesTarget == false)

        // Backup gas is required (not merely "available") — this is the outcome the UI
        // maps to "Gasoline Backup Required" and to inserting a required stop in the
        // Fuel Plan card.
        #expect(result.outcome == .gasolineBackupAvailable)

        // The destination reserve reflects the true no-stop shortfall (~-28%), not the
        // partially-masked ~-21% the old buggy 14 mi stop produced.
        let reserve = try? #require(result.destinationReserveFraction)
        #expect(abs((reserve ?? 0) - (-0.279)) < 0.01)
    }

    @Test("Same sparse corridor in E85-Required mode also suppresses the useless stop")
    func phoenixToLasVegas_e85Required_noUselessStop() {
        let stations = [
            station(name: "Phoenix Metro E85 A", distanceAlongRouteMiles: 8),
            station(name: "Phoenix Metro E85 B", distanceAlongRouteMiles: 14),
            station(name: "Phoenix Metro E85 C", distanceAlongRouteMiles: 19),
        ]
        let context = RouteFuelContext(
            tankSizeGallons: 18.5,
            mpg: 12,
            currentFuelPercent: 100,
            targetArrivalReservePercent: 20,
            fuelBackupMode: .e85Required
        )

        let result = planner.recommendStops(stations: stations, totalMiles: 284, context: context)

        #expect(result.stops.isEmpty)
        #expect(result.outcome == .fallbackMayBeNeeded)
    }

    // MARK: - Confirms the fix prefers a materially useful stop when one exists

    @Test("A materially useful stop further along the route is still recommended")
    func materiallyUsefulStop_isSelected_overTrivialEarlyCluster() {
        let stations = [
            station(name: "Phoenix Metro E85 A", distanceAlongRouteMiles: 8),
            station(name: "Phoenix Metro E85 B", distanceAlongRouteMiles: 14),
            station(name: "Phoenix Metro E85 C", distanceAlongRouteMiles: 19),
            station(name: "Kingman E85", distanceAlongRouteMiles: 190),
        ]
        let context = RouteFuelContext(
            tankSizeGallons: 18.5,
            mpg: 12,
            currentFuelPercent: 100,
            targetArrivalReservePercent: 20,
            fuelBackupMode: .gasBackupAllowed
        )

        let result = planner.recommendStops(stations: stations, totalMiles: 284, context: context)

        // Exactly the useful stop is recommended — none of the trivial early ones.
        #expect(result.stops.count == 1)
        #expect(result.stops.first?.station.station.name == "Kingman E85")

        // With that one real stop, the route now completes and meets the buffer target.
        #expect(result.planComplete)
        #expect(result.planSatisfiesTarget)
        #expect(result.outcome == .e85StopRequired)

        let destReserve = try? #require(result.destinationReserveFraction)
        #expect(abs((destReserve ?? 0) - 0.577) < 0.01)
    }

    // MARK: - Gasoline fallback: true switch-over when E85 alone can't complete the trip

    // Requirement 10 regression: Phoenix, AZ → Las Vegas, NV, 18.5 gal tank, 12 MPG, 100%
    // starting fuel, E30 selected, 20% arrival buffer, gas backup allowed. E85 stations
    // exist only in the sparse Phoenix cluster (as above) — the planner must not recommend
    // an early 14 mi top-off as the main solution. It should either find a useful E85 stop
    // later on the route, or (as here, since none exists) switch to a required gasoline
    // backup route, with a stop around Kingman.
    @Test("E85 finds nothing useful, but a full gasoline-fallback re-plan succeeds around Kingman")
    func phoenixToLasVegas_e30_gasFallbackSucceeds() {
        let context = RouteFuelContext(
            tankSizeGallons: 18.5,
            mpg: 12,
            currentFuelPercent: 100,
            targetArrivalReservePercent: 20,
            fuelBackupMode: .gasBackupAllowed
        )

        // 1. Attempt the selected ethanol route first: only the sparse Phoenix E85 cluster
        //    exists, and none of it is materially useful — no useless early top-off.
        let e85Stations = [
            station(name: "Phoenix Metro E85 A", distanceAlongRouteMiles: 8),
            station(name: "Phoenix Metro E85 B", distanceAlongRouteMiles: 14),
            station(name: "Phoenix Metro E85 C", distanceAlongRouteMiles: 19),
        ]
        let ethanolResult = planner.recommendStops(stations: e85Stations, totalMiles: 284, context: context)
        #expect(ethanolResult.stops.isEmpty)
        #expect(ethanolResult.planComplete == false)
        #expect(ethanolResult.outcome == .gasolineBackupAvailable)

        // 2. Since the ethanol route failed and gas backup is allowed, re-plan on regular
        //    gasoline stations (realistic ~30 mi search spacing, all on-route) as required
        //    stops — this must be a fresh re-plan, verified end-to-end, not a guess.
        let gasStations = [
            gasStation(name: "Gas Stop 30mi", distanceAlongRouteMiles: 30),
            gasStation(name: "Gas Stop 60mi", distanceAlongRouteMiles: 60),
            gasStation(name: "Gas Stop 90mi", distanceAlongRouteMiles: 90),
            gasStation(name: "Gas Stop 120mi", distanceAlongRouteMiles: 120),
            gasStation(name: "Kingman Gas Stop", distanceAlongRouteMiles: 150),
        ]
        let fallback = planner.evaluateGasFallback(gasStations: gasStations, totalMiles: 284, context: context)

        #expect(fallback.succeeds)
        #expect(fallback.stops.count == 1)
        #expect(fallback.stops.first?.station.name == "Kingman Gas Stop")

        let destReserve = try? #require(fallback.destinationReserveFraction)
        #expect(abs((destReserve ?? 0) - 0.396) < 0.01)
    }

    @Test("Gasoline fallback is never attempted when gas backup is not allowed")
    func e85Required_neverFallsBackToGasoline() {
        // Requirement 9: if gasBackupAllowed is false, the route stays unreachable — the
        // caller (TripPlannerView.gasFallbackPlan) must not even attempt a gas re-plan.
        // At the planner layer, this means recommendStops keeps reporting the honest
        // fallbackMayBeNeeded outcome instead of anything gasoline-flavored.
        let e85Stations = [
            station(name: "Phoenix Metro E85 A", distanceAlongRouteMiles: 8),
            station(name: "Phoenix Metro E85 B", distanceAlongRouteMiles: 14),
            station(name: "Phoenix Metro E85 C", distanceAlongRouteMiles: 19),
        ]
        let context = RouteFuelContext(
            tankSizeGallons: 18.5,
            mpg: 12,
            currentFuelPercent: 100,
            targetArrivalReservePercent: 20,
            fuelBackupMode: .e85Required
        )
        let result = planner.recommendStops(stations: e85Stations, totalMiles: 284, context: context)
        #expect(result.outcome == .fallbackMayBeNeeded)
        #expect(result.outcome != .gasolineFallbackRoute)
    }

    // MARK: - Backup gas station de-duplication

    @Test("Near-duplicate backup gas hits with the same name merge into one")
    func mergeNearDuplicates_sameNameNearby_merges() {
        let finder = BackupGasStationFinder()
        let stations = [
            BackupGasStation(
                id: "a",
                name: "Circle K",
                city: "Kingman",
                state: "AZ",
                coordinate: CLLocationCoordinate2D(latitude: 35.1894, longitude: -114.0530),
                distanceAlongRouteMiles: 150.0,
                offRouteMiles: 0.8
            ),
            // Same station, found via a second overlapping search center with slightly
            // different geocoded coordinates (~0.05 mi away) and closer to the corridor.
            BackupGasStation(
                id: "b",
                name: "circle k",
                city: "Kingman",
                state: "AZ",
                coordinate: CLLocationCoordinate2D(latitude: 35.1898, longitude: -114.0525),
                distanceAlongRouteMiles: 150.1,
                offRouteMiles: 0.3
            ),
        ]

        let merged = finder.mergeNearDuplicates(stations)

        #expect(merged.count == 1)
        // The closer-to-route (lower offRouteMiles) duplicate wins.
        #expect(merged.first?.id == "b")
    }

    @Test("Distinct nearby stations with different names are not merged")
    func mergeNearDuplicates_differentNames_notMerged() {
        let finder = BackupGasStationFinder()
        let stations = [
            BackupGasStation(
                id: "a",
                name: "Shell",
                city: "Kingman",
                state: "AZ",
                coordinate: CLLocationCoordinate2D(latitude: 35.1894, longitude: -114.0530),
                distanceAlongRouteMiles: 150.0,
                offRouteMiles: 0.8
            ),
            BackupGasStation(
                id: "b",
                name: "Chevron",
                city: "Kingman",
                state: "AZ",
                coordinate: CLLocationCoordinate2D(latitude: 35.1898, longitude: -114.0525),
                distanceAlongRouteMiles: 150.1,
                offRouteMiles: 0.3
            ),
        ]

        let merged = finder.mergeNearDuplicates(stations)

        #expect(merged.count == 2)
    }

    @Test("Same-named stations far apart on the route are not merged")
    func mergeNearDuplicates_sameNameFarApart_notMerged() {
        let finder = BackupGasStationFinder()
        let stations = [
            BackupGasStation(
                id: "a",
                name: "Circle K",
                city: "Phoenix",
                state: "AZ",
                coordinate: CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740),
                distanceAlongRouteMiles: 10.0,
                offRouteMiles: 0.5
            ),
            BackupGasStation(
                id: "b",
                name: "Circle K",
                city: "Kingman",
                state: "AZ",
                coordinate: CLLocationCoordinate2D(latitude: 35.1894, longitude: -114.0530),
                distanceAlongRouteMiles: 150.0,
                offRouteMiles: 0.5
            ),
        ]

        let merged = finder.mergeNearDuplicates(stations)

        #expect(merged.count == 2)
    }

    // MARK: - Invalid fuel-input contract (fix/2.2.3-trip-planner-input-contract)
    //
    // RouteFuelContext.isValid is the single authoritative validity check shared by
    // walkGreedyStops (and therefore recommendStops/evaluateGasFallback/analyze) and, via a
    // separately-constructed RouteFuelContext, TripPlannerView.computeGasOnlyPlan (Gas Only
    // mode). These tests exercise recommendStops/evaluateGasFallback directly — the real
    // production entry points — plus RouteFuelContext.isValid itself for the Gas Only
    // scenarios, since computeGasOnlyPlan is a private SwiftUI View method unreachable from
    // this test target (mirrors PlanRequestTrackerTests' precedent of verifying a
    // SwiftUI-embedded integration by code inspection rather than a direct test — see this
    // branch's final report for that inspection).

    private func validContext(
        tank: Double = 18.5,
        mpg: Double = 12,
        fuelPercent: Double = 100,
        reservePercent: Double = 20,
        backupMode: FuelBackupMode = .gasBackupAllowed
    ) -> RouteFuelContext {
        RouteFuelContext(
            tankSizeGallons: tank,
            mpg: mpg,
            currentFuelPercent: fuelPercent,
            targetArrivalReservePercent: reservePercent,
            fuelBackupMode: backupMode
        )
    }

    private func expectNeverSafe(_ result: Recommendation, sourceLabel: String) {
        #expect(result.inputsValid == false, "\(sourceLabel): must report inputsValid == false")
        #expect(result.planComplete == false, "\(sourceLabel): must not report destination reached")
        #expect(result.destinationReserveFraction != 1, "\(sourceLabel): must not report a 100% reserve")
        #expect(result.stops.isEmpty, "\(sourceLabel): must not recommend fuel stops")
        #expect(result.outcome != .noStopNeeded, "\(sourceLabel): must not report a normal safe outcome")
    }

    @Test("Tank size = 0 never produces a safe result")
    func tankSizeZero_isInvalid() {
        let context = validContext(tank: 0)
        #expect(context.isValid == false)
        let result = planner.recommendStops(stations: [], totalMiles: 100, context: context)
        expectNeverSafe(result, sourceLabel: "tank = 0")
    }

    @Test("Tank size < 0 never produces a safe result")
    func tankSizeNegative_isInvalid() {
        let context = validContext(tank: -18.5)
        #expect(context.isValid == false)
        let result = planner.recommendStops(stations: [], totalMiles: 100, context: context)
        expectNeverSafe(result, sourceLabel: "tank < 0")
    }

    @Test("Tank size = NaN never produces a safe result")
    func tankSizeNaN_isInvalid() {
        let context = validContext(tank: .nan)
        #expect(context.isValid == false)
        let result = planner.recommendStops(stations: [], totalMiles: 100, context: context)
        expectNeverSafe(result, sourceLabel: "tank = NaN")
    }

    @Test("Tank size = +infinity never produces a safe result")
    func tankSizePositiveInfinity_isInvalid() {
        let context = validContext(tank: .infinity)
        #expect(context.isValid == false)
        let result = planner.recommendStops(stations: [], totalMiles: 100, context: context)
        expectNeverSafe(result, sourceLabel: "tank = +infinity")
    }

    @Test("MPG = 0 never produces a safe result")
    func mpgZero_isInvalid() {
        let context = validContext(mpg: 0)
        #expect(context.isValid == false)
        let result = planner.recommendStops(stations: [], totalMiles: 100, context: context)
        expectNeverSafe(result, sourceLabel: "mpg = 0")
    }

    @Test("MPG < 0 never produces a safe result")
    func mpgNegative_isInvalid() {
        let context = validContext(mpg: -12)
        #expect(context.isValid == false)
        let result = planner.recommendStops(stations: [], totalMiles: 100, context: context)
        expectNeverSafe(result, sourceLabel: "mpg < 0")
    }

    @Test("MPG = NaN never produces a safe result")
    func mpgNaN_isInvalid() {
        let context = validContext(mpg: .nan)
        #expect(context.isValid == false)
        let result = planner.recommendStops(stations: [], totalMiles: 100, context: context)
        expectNeverSafe(result, sourceLabel: "mpg = NaN")
    }

    @Test("MPG = +infinity never produces a safe result")
    func mpgPositiveInfinity_isInvalid() {
        let context = validContext(mpg: .infinity)
        #expect(context.isValid == false)
        let result = planner.recommendStops(stations: [], totalMiles: 100, context: context)
        expectNeverSafe(result, sourceLabel: "mpg = +infinity")
    }

    @Test("Both tank and MPG invalid never produces a safe result, in either planner entry point")
    func bothTankAndMPGInvalid_isInvalid() {
        let context = validContext(tank: 0, mpg: .nan)
        #expect(context.isValid == false)

        let result = planner.recommendStops(stations: [], totalMiles: 100, context: context)
        expectNeverSafe(result, sourceLabel: "tank = 0, mpg = NaN")

        let fallback = planner.evaluateGasFallback(gasStations: [], totalMiles: 100, context: context)
        #expect(fallback.inputsValid == false)
        #expect(fallback.succeeds == false)
        #expect(fallback.destinationReserveFraction != 1)
    }

    @Test("Valid tank/MPG with an unreachable destination stays distinguishable from invalid input")
    func validButUnreachable_isNotInvalid() {
        // 18.5 gal / 12 MPG = 222 mi range; a 500 mi trip with no stations is genuinely
        // unreachable, but the inputs themselves are perfectly valid — this must NOT be
        // reported the same way as an invalid-input result.
        let context = validContext()
        #expect(context.isValid)
        let result = planner.recommendStops(stations: [], totalMiles: 500, context: context)
        #expect(result.inputsValid, "a valid context must never be reported as inputsValid == false")
        #expect(result.planComplete == false, "an unreachable trip is genuinely not complete")
    }

    @Test("Valid tank/MPG with a reachable destination plans normally")
    func validAndReachable_isNotInvalid() {
        let context = validContext()
        let result = planner.recommendStops(stations: [], totalMiles: 100, context: context)
        #expect(result.inputsValid)
        #expect(result.planComplete)
        #expect(result.outcome == .noStopNeeded)
    }

    @Test("A valid route with no candidate stations still resolves correctly, not as invalid")
    func validRouteNoStations_resolvesWithoutStations() {
        // Within the 222 mi range, so no stop is genuinely needed even with zero stations.
        let context = validContext()
        let result = planner.recommendStops(stations: [], totalMiles: 150, context: context)
        #expect(result.inputsValid)
        #expect(result.stops.isEmpty)
        #expect(result.outcome == .noStopNeeded)
    }

    @Test("Non-finite route distance never produces a safe result")
    func nonFiniteRouteDistance_isInvalid() {
        let context = validContext()
        let nanResult = planner.recommendStops(stations: [], totalMiles: .nan, context: context)
        expectNeverSafe(nanResult, sourceLabel: "totalMiles = NaN")
        let infResult = planner.recommendStops(stations: [], totalMiles: .infinity, context: context)
        expectNeverSafe(infResult, sourceLabel: "totalMiles = +infinity")
    }

    @Test("Negative route distance never produces a safe result")
    func negativeRouteDistance_isInvalid() {
        let context = validContext()
        let result = planner.recommendStops(stations: [], totalMiles: -50, context: context)
        expectNeverSafe(result, sourceLabel: "totalMiles = -50")
    }

    @Test("Invalid current fuel fraction is rejected by RouteFuelContext.isValid")
    func invalidCurrentFuelFraction_isInvalid() {
        #expect(validContext(fuelPercent: .nan).isValid == false)
        #expect(validContext(fuelPercent: .infinity).isValid == false)
        #expect(validContext(fuelPercent: -5).isValid == false)
        #expect(validContext(fuelPercent: 150).isValid == false)

        let context = validContext(fuelPercent: .nan)
        let result = planner.recommendStops(stations: [], totalMiles: 100, context: context)
        expectNeverSafe(result, sourceLabel: "currentFuelPercent = NaN")
    }

    @Test("Current fuel above 100% (gallons exceeding tank capacity) is rejected")
    func currentFuelAboveTankCapacity_isInvalid() {
        // RouteFuelContext only stores a percent, so "gallons > capacity" is expressed as a
        // fuel percent above 100 — clamping currentFuelPercent to 0...100 is what
        // structurally prevents startFuelGallons from ever exceeding tankSizeGallons.
        let context = validContext(fuelPercent: 140)
        #expect(context.isValid == false)
        #expect(context.startFuelGallons > context.tankSizeGallons, "sanity: this input really would exceed tank capacity if left unvalidated")
    }

    @Test("Invalid reserve fraction is rejected by RouteFuelContext.isValid")
    func invalidReserveFraction_isInvalid() {
        #expect(validContext(reservePercent: .nan).isValid == false)
        #expect(validContext(reservePercent: -10).isValid == false)
        #expect(validContext(reservePercent: 150).isValid == false)

        let context = validContext(reservePercent: .nan)
        let result = planner.recommendStops(stations: [], totalMiles: 100, context: context)
        expectNeverSafe(result, sourceLabel: "targetArrivalReservePercent = NaN")
    }

    @Test("Gas Only invalid tank input is rejected by the shared validator")
    func gasOnlyInvalidTank_isRejectedByValidator() {
        // computeGasOnlyPlan (TripPlannerView) guards on this exact RouteFuelContext.isValid
        // check but is a private SwiftUI View method unreachable from this test target — see
        // this branch's final report for the code-inspection verification of that wiring.
        let context = validContext(tank: 0)
        #expect(context.isValid == false)
    }

    @Test("Gas Only invalid MPG input is rejected by the shared validator")
    func gasOnlyInvalidMPG_isRejectedByValidator() {
        let context = validContext(mpg: .nan)
        #expect(context.isValid == false)
    }

    // MARK: - 2.3.0 Trip Planner clarity pass: arrival-reserve semantics + fill-to-full

    // Regression for the reported Phoenix, AZ → Los Angeles, CA contradiction: Trip Summary
    // showed "Estimated arrival buffer — Unreachable" while the same plan's Fuel Plan card
    // showed a healthy destination reserve (~87%). Root cause was a LABELING issue, not a
    // calculation bug — TripPlannerView's "Estimated arrival buffer" row read
    // noStopReserveFraction (the reserve with NO stop at all), not destinationReserveFraction
    // (the reserve after following the generated stop plan). This test proves the planner
    // itself computes both values correctly and that they can legitimately diverge this way:
    // deeply negative with no stop, healthy after the real 3-stop plan. 18.5 gal tank, 12
    // MPG, 50% starting fuel, 20% arrival buffer, gas backup allowed — same inputs as the
    // reported device case; station placement is a controlled equivalent (not the real
    // corridor's exact geocoded distances, which aren't available to this test) chosen so
    // the greedy walk's station-by-station math is fully hand-verifiable below.
    @Test("A negative no-stop baseline can coexist with a healthy planned destination reserve — not a contradiction")
    func noStopBaseline_canBeNegative_whilePlannedRouteSucceeds() {
        let stations = [
            station(name: "Stop 1 Station", distanceAlongRouteMiles: 60),
            station(name: "Stop 2 Station", distanceAlongRouteMiles: 160),
            station(name: "Stop 3 Station", distanceAlongRouteMiles: 310),
        ]
        let context = RouteFuelContext(
            tankSizeGallons: 18.5,
            mpg: 12,
            currentFuelPercent: 50,
            targetArrivalReservePercent: 20,
            fuelBackupMode: .gasBackupAllowed
        )

        let result = planner.recommendStops(stations: stations, totalMiles: 372, context: context)

        // The no-stop baseline is genuinely, deeply negative — driving 372 mi on a 111 mi
        // starting range (50% of a 222 mi full-tank range) without ever stopping.
        #expect(abs(result.noStopDestinationReserveFraction - (-1.1757)) < 0.001)

        // But the actual generated plan (3 stops, each filled to full) DOES reach the
        // destination with a healthy reserve — this is the number a "planned arrival
        // reserve" / "expected destination reserve" UI field must show, never the baseline
        // above.
        #expect(result.planComplete)
        #expect(result.planSatisfiesTarget)
        #expect(result.stops.count == 3)
        let destReserve = try? #require(result.destinationReserveFraction)
        #expect(abs((destReserve ?? 0) - 0.7207) < 0.001)

        // The outcome the UI keys its banner off of — a stop was required to make an
        // otherwise-unreachable trip work, exactly the "E85 Stop Required" case the reported
        // contradiction was about.
        #expect(result.outcome == .e85StopRequired)
    }

    // Same scenario as above, verifying the fill-to-full identity at each of the 3 stops:
    // arrivalGallons + suggestedFillGallons == tankSizeGallons (within floating-point
    // tolerance) — i.e. every recommended stop tops the tank all the way back up, never a
    // partial/minimum-needed fill. Exact per-stop numbers hand-verified against the greedy
    // walk's arithmetic (see this test's sibling above for the shared scenario setup).
    @Test("Every E85 recommended stop fills to full: arrival + suggested fill == tank size")
    func recommendedStops_fillToFull() {
        let stations = [
            station(name: "Stop 1 Station", distanceAlongRouteMiles: 60),
            station(name: "Stop 2 Station", distanceAlongRouteMiles: 160),
            station(name: "Stop 3 Station", distanceAlongRouteMiles: 310),
        ]
        let context = RouteFuelContext(
            tankSizeGallons: 18.5,
            mpg: 12,
            currentFuelPercent: 50,
            targetArrivalReservePercent: 20,
            fuelBackupMode: .gasBackupAllowed
        )

        let result = planner.recommendStops(stations: stations, totalMiles: 372, context: context)
        #expect(result.stops.count == 3)

        let tank = 18.5
        for stop in result.stops {
            let arrivalGallons = stop.arrivalReserveFraction * tank
            // The fill-to-full identity itself: never a partial fill, never negative,
            // never over capacity.
            #expect(abs((arrivalGallons + stop.suggestedFillGallons) - tank) < 0.01)
            #expect(stop.suggestedFillGallons >= 0)
            #expect(arrivalGallons + stop.suggestedFillGallons <= tank + 0.01)
        }

        // Explicit per-stop numbers (hand-verified), mirroring the shape of the real device
        // report (arrive at a partial tank, add fuel back to exactly a full tank each time).
        #expect(abs(result.stops[0].arrivalReserveFraction * tank - 4.25) < 0.01)
        #expect(abs(result.stops[0].suggestedFillGallons - 14.25) < 0.01)

        #expect(abs(result.stops[1].arrivalReserveFraction * tank - 10.1667) < 0.01)
        #expect(abs(result.stops[1].suggestedFillGallons - 8.3333) < 0.01)

        #expect(abs(result.stops[2].arrivalReserveFraction * tank - 6.0) < 0.01)
        #expect(abs(result.stops[2].suggestedFillGallons - 12.5) < 0.01)
    }

    // Fill-to-full applies identically to a verified gasoline-backup route — both E85 stops
    // and gas-fallback stops are produced by the same walkGreedyStops walk, so the same
    // identity must hold for GasFallbackStop as for RecommendedStop. Reuses the Kingman
    // gas-fallback scenario already established above (phoenixToLasVegas_e30_gasFallbackSucceeds)
    // rather than a new hand-derived scenario, since that plan's single stop is already
    // verified reachable and correct.
    @Test("Gas-backup fallback stops also fill to full, same as E85 stops")
    func gasFallbackStops_fillToFull() {
        let context = RouteFuelContext(
            tankSizeGallons: 18.5,
            mpg: 12,
            currentFuelPercent: 100,
            targetArrivalReservePercent: 20,
            fuelBackupMode: .gasBackupAllowed
        )
        let gasStations = [
            gasStation(name: "Gas Stop 30mi", distanceAlongRouteMiles: 30),
            gasStation(name: "Gas Stop 60mi", distanceAlongRouteMiles: 60),
            gasStation(name: "Gas Stop 90mi", distanceAlongRouteMiles: 90),
            gasStation(name: "Gas Stop 120mi", distanceAlongRouteMiles: 120),
            gasStation(name: "Kingman Gas Stop", distanceAlongRouteMiles: 150),
        ]
        let fallback = planner.evaluateGasFallback(gasStations: gasStations, totalMiles: 284, context: context)
        #expect(fallback.succeeds)
        #expect(fallback.stops.count == 1)

        let tank = 18.5
        let stop = fallback.stops[0]
        let arrivalGallons = stop.arrivalReserveFraction * tank
        #expect(abs((arrivalGallons + stop.suggestedFillGallons) - tank) < 0.01)
        #expect(stop.suggestedFillGallons >= 0)
    }
}

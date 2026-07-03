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
}

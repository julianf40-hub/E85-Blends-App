//
//  RouteE85Planner.swift
//  EightyFiveBlends
//
//  85Blends v2.2 Trip Planner — Phase 2 engine. Turns an MKRoute into a route-aware E85
//  plan: it samples the route corridor, discovers REAL E85 stations along it via the
//  existing NLR/AFDC station service, de-duplicates them, computes per-station reachability
//  from the driver's current fuel assumptions, and greedily recommends realistic fuel stops.
//
//  This file contains no UI and no fabricated data — every station it returns comes from a
//  live station search. It is consumed by TripPlannerView.
//

import Foundation
import MapKit
import CoreLocation

// MARK: - Fuel backup mode

/// Whether the planner may treat gasoline as a safe fallback when E85 can't satisfy the route
/// or the selected arrival-reserve target.
enum FuelBackupMode {
    /// E85 preferred, but the vehicle can safely continue on gasoline if needed.
    case gasBackupAllowed
    /// The trip is only considered safe when E85 stops can support it.
    case e85Required

    var displayLabel: String {
        switch self {
        case .gasBackupAllowed: return "E85 Preferred, Gas Backup Allowed"
        case .e85Required:      return "E85 Required"
        }
    }
}

// MARK: - Fuel context

/// The driver's fuel assumptions for a trip. All ranges are simple `gallons * mpg` estimates.
struct RouteFuelContext {
    let tankSizeGallons: Double
    let mpg: Double
    let currentFuelPercent: Double
    /// How much fuel the driver wants left on arrival (percent of a full tank).
    let targetArrivalReservePercent: Double
    /// Whether gasoline is an allowed fallback for this trip.
    let fuelBackupMode: FuelBackupMode

    var startFuelGallons: Double { tankSizeGallons * (currentFuelPercent / 100) }
    var fullTankRangeMiles: Double { tankSizeGallons * mpg }
    var startRangeMiles: Double { startFuelGallons * mpg }
    /// Target arrival reserve as a fraction of a full tank (0…1).
    var targetReserveFraction: Double { max(0, min(1, targetArrivalReservePercent / 100)) }
}

// MARK: - Route outcome

/// High-level outcome of a planned trip, relative to the driver's chosen reserve target.
enum RouteOutcome {
    /// Destination reachable AND arrival reserve ≥ target — nothing to do.
    case noStopNeeded
    /// Destination reachable, but arrival reserve is below target — a stop is suggested to meet it.
    case reserveStopRecommended
    /// Destination is NOT reachable without stopping — a stop is required.
    case e85StopRequired
    /// No reachable E85 plan meets the trip/target, but the vehicle may continue on gasoline.
    case gasolineBackupAvailable
    /// No reachable E85 stop can satisfy the trip or reserve target, and gas backup is not allowed.
    case fallbackMayBeNeeded
    /// E85 stop(s) were available but skipped because they required too much detour;
    /// gas backup is recommended for those segments instead.
    case e85DetourAvoided
    /// Trip is being planned on pump gasoline only (flex-fuel vehicle); no E85 stops
    /// are required or sought.
    case gasolineOnly
    /// Gas Only mode: the current fuel + discovered gas stops can satisfy the route,
    /// but one or more stops are recommended to meet range or arrival reserve.
    case gasStopRecommended
    /// Gas Only mode: a fuel stop is needed but no suitable gas station was found.
    case gasFuelStopNeeded
}

// MARK: - Reserve classification

/// Arrival-reserve classification used for per-station risk indicators.
enum ReserveClass {
    case safe       // arrive with > 20%
    case caution    // arrive with 10–20%
    case risky      // arrive with < 10%

    init(reserveFraction: Double) {
        if reserveFraction > 0.20 {
            self = .safe
        } else if reserveFraction >= 0.10 {
            self = .caution
        } else {
            self = .risky
        }
    }
}

// MARK: - Detour severity

/// How far off the main route a station sits. Used for UI classification and subtle routing
/// preference — stations are never rejected solely because of their detour severity.
enum DetourSeverity {
    case onRoute        // < 1 mi off route
    case smallDetour    // 1–3 mi
    case moderateDetour // 3–7 mi
    case majorDetour    // > 7 mi

    init(offRouteMiles: Double) {
        if offRouteMiles < 1.0 { self = .onRoute }
        else if offRouteMiles < 3.0 { self = .smallDetour }
        else if offRouteMiles < 7.0 { self = .moderateDetour }
        else { self = .majorDetour }
    }

    var label: String {
        switch self {
        case .onRoute:        return "On Route"
        case .smallDetour:    return "Small Detour"
        case .moderateDetour: return "Moderate Detour"
        case .majorDetour:    return "Major Detour"
        }
    }
}

// MARK: - Discovered station along the route

/// A real E85 station discovered along the route, annotated with where it falls on the trip
/// and whether it is reachable on the starting tank (no intermediate refuels).
struct RouteStation: Identifiable {
    let id: String                       // stable dedup key (not the volatile LiveFuelStation UUID)
    let station: LiveFuelStation
    let coordinate: CLLocationCoordinate2D
    let distanceAlongRouteMiles: Double  // how far into the trip this station sits
    let offRouteMiles: Double            // straight-line distance from the route corridor

    /// Reserve fraction (of a full tank) on arrival from the origin on the starting tank,
    /// with no intermediate refuels. Can be negative (unreachable on the starting tank).
    let fromOriginReserveFraction: Double

    var reachableFromOrigin: Bool { fromOriginReserveFraction >= 0 }

    var classification: ReserveClass {
        ReserveClass(reserveFraction: fromOriginReserveFraction)
    }

    var detourSeverity: DetourSeverity { DetourSeverity(offRouteMiles: offRouteMiles) }
}

// MARK: - Recommended stop

/// A single recommended fuel stop within the greedy plan, with the reserve the driver would
/// arrive with and how much E85 to add (fill-to-full).
struct RecommendedStop: Identifiable {
    let id: String
    let station: RouteStation
    let arrivalReserveFraction: Double   // reserve on arrival at this stop within the plan
    let suggestedFillGallons: Double
    /// True when this stop is recommended to satisfy the reserve target (the destination is
    /// reachable without it), rather than being strictly required to reach the destination.
    let recommendedForReserveTarget: Bool

    var arrivalClass: ReserveClass {
        ReserveClass(reserveFraction: arrivalReserveFraction)
    }
}

// MARK: - Analysis result

/// The full route-aware E85 analysis surfaced to the UI.
struct RouteE85Analysis {
    let stations: [RouteStation]             // all unique stations discovered along the corridor
    let recommendedStops: [RecommendedStop]  // the greedy fuel-stop plan
    let lowestArrivalReserveFraction: Double? // min arrival reserve across the plan (incl. destination)
    let estimatedStops: Int
    let planComplete: Bool                    // false if a gap exceeds range / trip not completable
    let risk: TripPlan.RouteRisk
    let outcome: RouteOutcome                 // outcome relative to the reserve target
    let destinationReserveFraction: Double?   // estimated arrival reserve at the destination after the plan
    let noStopReserveFraction: Double         // arrival reserve if the driver does NOT make an E85 stop
    let targetReserveFraction: Double         // the driver's chosen reserve target
    let fuelBackupMode: FuelBackupMode        // whether gasoline backup was allowed for this plan

    var stationCount: Int { stations.count }
}

// MARK: - Errors

enum RouteE85PlannerError: LocalizedError {
    case noStationsFound
    case searchUnavailable
    case network

    var errorDescription: String? {
        switch self {
        case .noStationsFound:
            return "No E85 stations were found along this route. You may need to plan fuel stops manually."
        case .searchUnavailable:
            return "Live E85 station search isn't available right now. Your route and estimates still work."
        case .network:
            return "We couldn't load E85 stations for this route. Check your connection and try again."
        }
    }
}

// MARK: - Planner

struct RouteE85Planner {
    private let service: NLRStationService

    // Tuning constants. Search query centers are spaced far enough apart (with overlapping
    // radii) to fully cover the corridor while keeping the number of API requests bounded —
    // this is how we reconcile "sample the route" with "avoid excessive API requests".
    private let geometrySampleIntervalMiles = 2.0   // fine sampling for accurate along-route distance
    private let maxSearchQueries = 12               // hard cap on concurrent station searches
    private let maxCorridorOffsetMiles = 18.0       // ignore stations farther than this off-route
    private let minArrivalReserveFraction = 0.12    // don't recommend arriving below ~12%
    // A stop must add at least this fraction of a full tank's worth of extra range to be
    // worth recommending — filters out "drive 14 mi, add 1.2 gal" style top-offs picked
    // simply for being the farthest low-detour station nearby, when the tank is still
    // mostly full. See recommendStops() for the full rationale.
    private let minMaterialGainFraction = 0.15

    init(service: NLRStationService = NLRStationService()) {
        self.service = service
    }

    /// Discover and analyze real E85 stations along the route corridor for the given fuel
    /// context. Takes plain coordinates (Sendable) rather than the non-Sendable MKRoute so it
    /// runs cleanly off the main actor. Respects task cancellation.
    func analyze(
        routeCoordinates coordinates: [CLLocationCoordinate2D],
        routeDistanceMeters: Double,
        context: RouteFuelContext,
        reportedUnavailableKeys: Set<String> = []
    ) async throws -> RouteE85Analysis {
        guard coordinates.count >= 2 else { throw RouteE85PlannerError.noStationsFound }

        // 1. Densify the route into evenly-spaced samples with cumulative along-route distance.
        let samples = densifiedSamples(from: coordinates, intervalMiles: geometrySampleIntervalMiles)
        let totalMiles = samples.last?.distanceAlong ?? (routeDistanceMeters / 1609.344)
        guard totalMiles > 0 else { throw RouteE85PlannerError.noStationsFound }

        // 2. Choose a bounded set of search centers spaced along the corridor.
        let searchInterval = searchIntervalMiles(forTotal: totalMiles)
        let searchRadius = searchRadiusMiles(forInterval: searchInterval)
        let centers = searchCenters(from: samples, total: totalMiles, spacing: searchInterval)

        try Task.checkCancellation()

        // 3. Discover stations concurrently around each center. Per-task failures are tolerated;
        //    we only surface an error if every search failed (or all returned nothing).
        var collected: [LiveFuelStation] = []
        var sawSuccess = false
        var lastError: Error?

        await withTaskGroup(of: Result<[LiveFuelStation], Error>.self) { group in
            for center in centers {
                group.addTask {
                    do {
                        let stations = try await service.fetchNearbyE85Stations(
                            latitude: center.latitude,
                            longitude: center.longitude,
                            radius: searchRadius,
                            limit: 20
                        )
                        return .success(stations)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let stations):
                    sawSuccess = true
                    collected.append(contentsOf: stations)
                case .failure(let error):
                    lastError = error
                }
            }
        }

        try Task.checkCancellation()

        if collected.isEmpty {
            if sawSuccess {
                throw RouteE85PlannerError.noStationsFound
            }
            if let nlrError = lastError as? NLRServiceError, case .missingAPIKey = nlrError {
                throw RouteE85PlannerError.searchUnavailable
            }
            if let urlError = lastError as? URLError,
               urlError.code == .notConnectedToInternet || urlError.code == .timedOut {
                throw RouteE85PlannerError.network
            }
            throw lastError == nil ? RouteE85PlannerError.noStationsFound : RouteE85PlannerError.network
        }

        // 4. De-duplicate and map each unique station onto the route corridor.
        let unique = deduplicate(collected)
        let routeStations = unique
            .compactMap { mapToRoute($0, samples: samples, context: context) }
            .filter { $0.offRouteMiles <= maxCorridorOffsetMiles }
            .sorted { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles }

        if routeStations.isEmpty {
            throw RouteE85PlannerError.noStationsFound
        }

        // 5. Greedy stop recommendations + 6. risk scoring.
        let recommendation = recommendStops(
            stations: routeStations,
            totalMiles: totalMiles,
            context: context,
            reportedUnavailableKeys: reportedUnavailableKeys
        )

        let risk = computeRisk(recommendation: recommendation, context: context)

        return RouteE85Analysis(
            stations: routeStations,
            recommendedStops: recommendation.stops,
            lowestArrivalReserveFraction: recommendation.lowestArrivalReserveFraction,
            estimatedStops: recommendation.stops.count,
            planComplete: recommendation.planComplete,
            risk: risk,
            outcome: recommendation.outcome,
            destinationReserveFraction: recommendation.destinationReserveFraction,
            noStopReserveFraction: recommendation.noStopDestinationReserveFraction,
            targetReserveFraction: context.targetReserveFraction,
            fuelBackupMode: context.fuelBackupMode
        )
    }

    // MARK: - Corridor sampling

    private struct RouteSample {
        let coordinate: CLLocationCoordinate2D
        let distanceAlong: Double
    }

    /// Walk the polyline and emit points every `intervalMiles`, carrying cumulative distance.
    /// Linear interpolation within each short segment is accurate enough for corridor work.
    private func densifiedSamples(
        from coordinates: [CLLocationCoordinate2D],
        intervalMiles: Double
    ) -> [RouteSample] {
        var samples: [RouteSample] = [RouteSample(coordinate: coordinates[0], distanceAlong: 0)]
        var cumulativeAtSegmentStart = 0.0
        var nextSampleAt = intervalMiles

        for index in 1..<coordinates.count {
            let a = coordinates[index - 1]
            let b = coordinates[index]
            let segment = milesBetween(a, b)
            if segment > 0 {
                while nextSampleAt <= cumulativeAtSegmentStart + segment {
                    let fraction = (nextSampleAt - cumulativeAtSegmentStart) / segment
                    let interpolated = interpolate(a, b, fraction: fraction)
                    samples.append(RouteSample(coordinate: interpolated, distanceAlong: nextSampleAt))
                    nextSampleAt += intervalMiles
                }
            }
            cumulativeAtSegmentStart += segment
        }

        if let last = samples.last, last.distanceAlong < cumulativeAtSegmentStart {
            samples.append(RouteSample(coordinate: coordinates[coordinates.count - 1], distanceAlong: cumulativeAtSegmentStart))
        }
        return samples
    }

    private func searchIntervalMiles(forTotal total: Double) -> Double {
        // Base spacing follows the "≈5 mi short / ≈10 mi long" intent, but is widened so the
        // number of search queries never exceeds `maxSearchQueries`.
        let base = total <= 150 ? 25.0 : 35.0
        let boundedByCap = total / Double(maxSearchQueries)
        return max(base, boundedByCap)
    }

    private func searchRadiusMiles(forInterval interval: Double) -> Double {
        // Radius covers half the spacing (so circles overlap at midpoints) plus corridor margin.
        min(45.0, max(20.0, interval / 2 + 12))
    }

    private func searchCenters(
        from samples: [RouteSample],
        total: Double,
        spacing: Double
    ) -> [CLLocationCoordinate2D] {
        guard total > 0 else { return samples.first.map { [$0.coordinate] } ?? [] }
        var centers: [CLLocationCoordinate2D] = []
        var target = 0.0
        var sampleIndex = 0
        while target <= total {
            while sampleIndex < samples.count - 1 && samples[sampleIndex].distanceAlong < target {
                sampleIndex += 1
            }
            centers.append(samples[sampleIndex].coordinate)
            target += spacing
        }
        // Always include the very end of the route so the destination area is searched.
        if let last = samples.last {
            centers.append(last.coordinate)
        }
        return centers
    }

    // MARK: - De-duplication

    /// A station can surface from multiple overlapping searches. Prefer a name+address key
    /// (the AFDC data is stable across requests); fall back to rounded-coordinate proximity.
    private func deduplicate(_ stations: [LiveFuelStation]) -> [LiveFuelStation] {
        var seen = Set<String>()
        var result: [LiveFuelStation] = []
        for station in stations {
            let key = dedupKey(for: station)
            if seen.insert(key).inserted {
                result.append(station)
            }
        }
        return result
    }

    private func dedupKey(for station: LiveFuelStation) -> String {
        let name = normalize(station.name)
        let address = normalize(station.address)
        if name.isEmpty == false && address.isEmpty == false {
            return "na|\(name)|\(address)"
        }
        // Coordinate proximity fallback (~4 decimals ≈ 11 m).
        let lat = (station.latitude * 10_000).rounded() / 10_000
        let lon = (station.longitude * 10_000).rounded() / 10_000
        return "co|\(lat)|\(lon)|\(name)"
    }

    private func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    // MARK: - Map a station onto the route

    private func mapToRoute(
        _ station: LiveFuelStation,
        samples: [RouteSample],
        context: RouteFuelContext
    ) -> RouteStation? {
        guard isValidCoordinate(latitude: station.latitude, longitude: station.longitude) else {
            return nil
        }
        let stationCoordinate = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)

        // Nearest densified sample → along-route distance + off-route offset.
        var bestDistance = Double.greatestFiniteMagnitude
        var bestAlong = 0.0
        for sample in samples {
            let d = milesBetween(stationCoordinate, sample.coordinate)
            if d < bestDistance {
                bestDistance = d
                bestAlong = sample.distanceAlong
            }
        }

        let consumedGallons = context.mpg > 0 ? bestAlong / context.mpg : .greatestFiniteMagnitude
        let reserveGallons = context.startFuelGallons - consumedGallons
        let reserveFraction = context.tankSizeGallons > 0 ? reserveGallons / context.tankSizeGallons : 0

        return RouteStation(
            id: dedupKey(for: station),
            station: station,
            coordinate: stationCoordinate,
            distanceAlongRouteMiles: bestAlong,
            offRouteMiles: bestDistance,
            fromOriginReserveFraction: reserveFraction
        )
    }

    // MARK: - Greedy stop recommendations

    /// Internal (not private) so `RouteE85PlannerTests` can exercise the greedy planner
    /// directly with synthetic stations, without needing a live station search.
    struct Recommendation {
        let stops: [RecommendedStop]
        let planComplete: Bool                 // plan reaches the destination (reserve ≥ 0)
        let planSatisfiesTarget: Bool          // destination arrival reserve ≥ target
        let outcome: RouteOutcome
        let destinationReserveFraction: Double? // estimated arrival reserve at destination (after the plan)
        let noStopDestinationReserveFraction: Double // arrival reserve if the driver does NOT stop
        let lowestArrivalReserveFraction: Double?
        let minViableOptions: Int   // fewest reachable options at any decision point
        let hadRiskyLeg: Bool       // a leg forced arrival below the comfortable reserve
        let skippedE85ForDetour: Bool // gasBackupAllowed: a high-detour E85 stop was intentionally skipped
    }

    /// A stop chosen during the greedy walk, before we know the final plan-wide outcome.
    private struct RawStop {
        let station: RouteStation
        let arrivalFraction: Double
        let fillGallons: Double
    }

    /// Internal (not private) for direct testability — see `Recommendation` above.
    func recommendStops(
        stations: [RouteStation],
        totalMiles: Double,
        context: RouteFuelContext,
        reportedUnavailableKeys: Set<String> = []
    ) -> Recommendation {
        let mpg = context.mpg
        let tank = context.tankSizeGallons
        let targetGallons = context.targetReserveFraction * tank

        guard mpg > 0, tank > 0 else {
            return Recommendation(
                stops: [], planComplete: true, planSatisfiesTarget: true,
                outcome: .noStopNeeded, destinationReserveFraction: nil,
                noStopDestinationReserveFraction: 1,
                lowestArrivalReserveFraction: nil, minViableOptions: 0, hadRiskyLeg: false,
                skippedE85ForDetour: false
            )
        }

        // Destination reserve on the starting tank with no intermediate refuels.
        let noStopDestReserveFraction = (context.startFuelGallons - totalMiles / mpg) / tank

        var position = 0.0
        var fuelGallons = context.startFuelGallons
        var rawStops: [RawStop] = []
        var lowestReserve = Double.greatestFiniteMagnitude
        var minViableOptions = Int.max
        var hadRiskyLeg = false
        var skippedE85ForDetour = false  // gasBackupAllowed: a high-detour E85 stop was intentionally skipped

        // Keep adding stops until the destination arrival reserve meets the target, or we run
        // out of reachable stations to add.
        var safety = 0
        while safety < 64 {
            safety += 1

            let distanceToDestination = totalMiles - position
            let reserveAtDestinationGallons = fuelGallons - distanceToDestination / mpg
            // Complete once the chosen reserve target is satisfied at the destination.
            if reserveAtDestinationGallons >= targetGallons {
                break
            }

            // Stations ahead of the current position, with their arrival reserve on this leg.
            let ahead = stations.filter { $0.distanceAlongRouteMiles > position + 0.5 }
            let safeOptions = ahead.filter {
                let arrival = fuelGallons - ($0.distanceAlongRouteMiles - position) / mpg
                return arrival / tank >= minArrivalReserveFraction
            }

            // Usefulness gate: a stop only counts if refueling there adds a material amount
            // of extra range (see minMaterialGainFraction). Without this, a station reached
            // very early — while the tank is still mostly full — can win purely on being the
            // farthest low-detour option nearby, producing a "drive 14 mi, add 1.2 gal"
            // recommendation that does nothing to help the trip actually complete.
            let minMaterialGainMiles = minMaterialGainFraction * tank * mpg
            let materialSafeOptions = safeOptions.filter {
                let arrival = fuelGallons - ($0.distanceAlongRouteMiles - position) / mpg
                let fillGallons = max(0, tank - arrival)
                return fillGallons * mpg >= minMaterialGainMiles
            }

            let chosen: RouteStation?
            if materialSafeOptions.isEmpty == false {
                minViableOptions = min(minViableOptions, materialSafeOptions.count)

                // Remove recently-reported unavailable stations when clean alternatives exist.
                let cleanPool: [RouteStation]
                if reportedUnavailableKeys.isEmpty {
                    cleanPool = materialSafeOptions
                } else {
                    let filtered = materialSafeOptions.filter { reportedUnavailableKeys.contains($0.id) == false }
                    cleanPool = filtered.isEmpty ? materialSafeOptions : filtered
                }

                if context.fuelBackupMode == .gasBackupAllowed {
                    // Flex-fuel / gas-backup mode: strongly prefer low-detour E85 stops.
                    // Moderate/major detour stops are avoided when gas backup can cover the gap.
                    let lowDetourPool = cleanPool.filter {
                        $0.detourSeverity == .onRoute || $0.detourSeverity == .smallDetour
                    }
                    if lowDetourPool.isEmpty == false {
                        // Good low-detour E85 options available — pick the farthest.
                        chosen = lowDetourPool.max(by: { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles })
                    } else {
                        // All safeOptions are moderate or major detour.
                        let canCoastToDestination = fuelGallons - (totalMiles - position) / mpg >= 0
                        let moderatePool = cleanPool.filter { $0.detourSeverity == .moderateDetour }
                        if canCoastToDestination {
                            // Destination reachable — any detour stop is optional for reserve only.
                            // Skip it and let gas backup handle the reserve shortfall.
                            skippedE85ForDetour = true
                            chosen = nil
                        } else if moderatePool.isEmpty == false {
                            // Must stop; accept a moderate-detour station as a necessary last resort.
                            chosen = moderatePool.max(by: { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles })
                        } else {
                            // Must stop; only major-detour E85 available. Skip — gas backup recommended.
                            skippedE85ForDetour = true
                            chosen = nil
                        }
                    }
                } else {
                    // E85 Required mode: avoid major detours when a better option is nearby,
                    // but never refuse to stop — E85 is the only acceptable fuel.
                    if let farthest = cleanPool.max(by: { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles }),
                       farthest.detourSeverity == .majorDetour {
                        let betterDetour = cleanPool
                            .filter { $0.detourSeverity != .majorDetour &&
                                      farthest.distanceAlongRouteMiles - $0.distanceAlongRouteMiles <= 20 }
                            .max(by: { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles })
                        chosen = betterDetour ?? farthest
                    } else {
                        chosen = cleanPool.max(by: { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles })
                    }
                }
            } else if safeOptions.isEmpty == false {
                // Only trivial top-offs are safely reachable from here — none of them
                // materially improve reachability or the arrival buffer. Don't recommend
                // one; the loop will either find the destination coastable as-is (and exit
                // on the next check above) or fall through to the emergency relax step
                // below once genuinely nothing safe remains.
                chosen = nil
            } else {
                // Relax: any station we can physically reach (arrive with ≥ 0). This is a
                // genuine last resort, so it is NOT subject to the material-gain filter —
                // when nothing safe is reachable at all, any reachable fuel matters.
                let reachable = ahead.filter {
                    fuelGallons - ($0.distanceAlongRouteMiles - position) / mpg >= 0
                }
                if reachable.isEmpty {
                    chosen = nil
                } else {
                    minViableOptions = 0
                    hadRiskyLeg = true
                    chosen = reachable.max { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles }
                }
            }

            // No reachable station to add → stop planning here.
            guard let stop = chosen, stop.distanceAlongRouteMiles > position + 0.5 else {
                break
            }

            let arrivalGallons = fuelGallons - (stop.distanceAlongRouteMiles - position) / mpg
            let arrivalFraction = arrivalGallons / tank
            lowestReserve = min(lowestReserve, arrivalFraction)

            rawStops.append(
                RawStop(
                    station: stop,
                    arrivalFraction: arrivalFraction,
                    fillGallons: max(0, tank - arrivalGallons)
                )
            )

            // Refuel to full and continue from the chosen station.
            position = stop.distanceAlongRouteMiles
            fuelGallons = tank
        }

        // Final destination reserve after the plan.
        let finalDestReserveGallons = fuelGallons - (totalMiles - position) / mpg
        let destReserveFraction = finalDestReserveGallons / tank
        lowestReserve = min(lowestReserve, destReserveFraction)

        let planReachesDestination = finalDestReserveGallons >= 0
        let planSatisfiesTarget = finalDestReserveGallons >= targetGallons

        // An E85-only plan "succeeds" only if it both reaches the destination AND meets the
        // chosen reserve target. Otherwise the outcome depends on the fuel-backup mode.
        let e85PlanSucceeds = planReachesDestination && planSatisfiesTarget

        let outcome: RouteOutcome
        if e85PlanSucceeds {
            if rawStops.isEmpty {
                outcome = .noStopNeeded             // reachable + target met, no stop
            } else if noStopDestReserveFraction >= 0 {
                outcome = .reserveStopRecommended   // reachable without stops; stop(s) meet the target
            } else {
                outcome = .e85StopRequired          // stop(s) required to reach + meet the target
            }
        } else {
            // E85 can't satisfy the trip or the reserve target.
            switch context.fuelBackupMode {
            case .gasBackupAllowed:
                // Distinguish "we intentionally skipped a high-detour E85 stop" from
                // "there simply was no usable E85 station" so the UI can give better copy.
                outcome = skippedE85ForDetour ? .e85DetourAvoided : .gasolineBackupAvailable
            case .e85Required:
                outcome = .fallbackMayBeNeeded
            }
        }

        let recommendedForReserveTarget = (outcome == .reserveStopRecommended)
        let stops = rawStops.map { raw in
            RecommendedStop(
                id: raw.station.id,
                station: raw.station,
                arrivalReserveFraction: raw.arrivalFraction,
                suggestedFillGallons: raw.fillGallons,
                recommendedForReserveTarget: recommendedForReserveTarget
            )
        }

        let lowest = lowestReserve == .greatestFiniteMagnitude ? nil : lowestReserve
        let viable = minViableOptions == .max ? 0 : minViableOptions
        return Recommendation(
            stops: stops,
            planComplete: planReachesDestination,
            planSatisfiesTarget: planSatisfiesTarget,
            outcome: outcome,
            destinationReserveFraction: destReserveFraction,
            noStopDestinationReserveFraction: noStopDestReserveFraction,
            lowestArrivalReserveFraction: lowest,
            minViableOptions: viable,
            hadRiskyLeg: hadRiskyLeg,
            skippedE85ForDetour: skippedE85ForDetour
        )
    }

    // MARK: - Risk scoring

    private func computeRisk(
        recommendation: Recommendation,
        context: RouteFuelContext
    ) -> TripPlan.RouteRisk {
        let target = context.targetReserveFraction
        let destReserve = recommendation.destinationReserveFraction ?? 1
        let lowest = recommendation.lowestArrivalReserveFraction ?? 1

        switch recommendation.outcome {
        case .fallbackMayBeNeeded:
            // E85 required but no valid E85 plan is available.
            return .high

        case .gasolineBackupAvailable:
            // The user allows gasoline backup, so an E85 shortfall is Medium — unless a planned
            // E85 leg itself arrives unsafe (below ~10%), which is a real hazard regardless.
            let unsafeLeg = recommendation.hadRiskyLeg
                || recommendation.stops.contains { $0.arrivalReserveFraction < 0.10 }
            return unsafeLeg ? .high : .medium

        case .e85DetourAvoided:
            // E85 was intentionally skipped (too much detour) and the vehicle can use gas.
            // The route is navigable — treat the same as gasolineBackupAvailable.
            return .medium

        case .noStopNeeded:
            // Reachable with the target satisfied and no stop: comfortable → Low,
            // reserve close to target → Medium.
            return (destReserve - target) < 0.05 ? .medium : .low

        case .e85StopRequired, .reserveStopRecommended:
            // Any planned leg arriving below ~10% is fragile.
            if recommendation.hadRiskyLeg || lowest < 0.10 {
                return .high
            }
            // The plan can't reach the chosen reserve target.
            if recommendation.planSatisfiesTarget == false {
                // Below target with no usable stop → High; a recommended stop that still
                // falls short → Medium.
                return recommendation.stops.isEmpty ? .high : .medium
            }
            // Target satisfied: single option or a thin margin → Medium, otherwise Low.
            if recommendation.minViableOptions <= 1 {
                return .medium
            }
            if (destReserve - target) < 0.05 {
                return .medium
            }
            // A required stop that is a major detour adds routing uncertainty → bump Low to Medium.
            let hasMajorDetourRequired = recommendation.stops.contains {
                $0.station.detourSeverity == .majorDetour && $0.recommendedForReserveTarget == false
            }
            if hasMajorDetourRequired { return .medium }
            return .low

        case .gasolineOnly, .gasStopRecommended, .gasFuelStopNeeded:
            // These cases are never produced by the E85 planner — they are set by the UI in
            // Gas Only mode where the E85 analysis is skipped entirely. Treat as Low here;
            // actual risk is computed by computeGasOnlyPlan in TripPlannerView.
            return .low
        }
    }

    // MARK: - Geometry helpers

    private func milesBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let locationA = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let locationB = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return locationA.distance(from: locationB) / 1609.344
    }

    private func interpolate(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        fraction: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * fraction,
            longitude: a.longitude + (b.longitude - a.longitude) * fraction
        )
    }

    private func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude) && (latitude != 0 || longitude != 0)
    }
}

// MARK: - MKPolyline coordinate extraction

extension MKPolyline {
    /// All vertex coordinates of the polyline, in order.
    var routeCoordinates: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

// MARK: - Gas Only stop

/// A recommended regular-gas stop computed for Gas Only planning mode.
/// Analogous to RecommendedStop for E85 but rooted in BackupGasStation data.
struct GasOnlyStop: Identifiable {
    let id: String
    let station: BackupGasStation
    let arrivalReserveFraction: Double   // tank fraction on arrival at this stop
    let suggestedFillGallons: Double
    let recommendedForReserveTarget: Bool

    var arrivalClass: ReserveClass {
        ReserveClass(reserveFraction: arrivalReserveFraction)
    }
}

// MARK: - Backup gas station

/// A regular gasoline station discovered along the route corridor. Surfaced as a fallback
/// option when fuel-backup mode is "Gas Backup Allowed." Never mixed into E85 logic.
struct BackupGasStation: Identifiable {
    let id: String                          // stable dedup key
    let name: String
    let city: String
    let state: String
    let coordinate: CLLocationCoordinate2D
    let distanceAlongRouteMiles: Double
    let offRouteMiles: Double

    var detourSeverity: DetourSeverity { DetourSeverity(offRouteMiles: offRouteMiles) }
}

// MARK: - Backup gas station finder

/// Uses MapKit local search to find regular gasoline stations along a route corridor.
/// Completely independent of E85 planning — results are never mixed into the E85 analysis.
struct BackupGasStationFinder {

    private let baseSearchCenters = 12      // default; raised from 8 for better corridor coverage
    private let longRouteSearchCenters = 16 // used when route > 300 miles
    // 25 km is plenty for gas stations, which are common.
    private let searchRadiusMeters = 25_000.0
    private let maxOffRouteMiles = 12.0
    // Two hits within this distance sharing a normalized name are treated as the same
    // real-world station (see mergeNearDuplicates) — wider than the exact-key dedup's
    // ~111 m rounding so overlapping search circles don't surface the same station twice.
    private let nearDuplicateRadiusMiles = 0.1

    // Extracted data from a single MKMapItem — avoids passing non-Sendable MKMapItem across
    // actor/task boundaries in the concurrent search group.
    private struct GasHit: Sendable {
        let name: String
        let locality: String
        let adminArea: String
        let latitude: Double
        let longitude: Double
        let distanceAlong: Double
    }

    func find(
        routeCoordinates: [CLLocationCoordinate2D],
        routeDistanceMeters: Double
    ) async -> [BackupGasStation] {
        guard routeCoordinates.count >= 2 else { return [] }

        let totalMiles = routeDistanceMeters / 1609.344
        guard totalMiles > 0 else { return [] }

        let maxCenters = totalMiles > 300 ? longRouteSearchCenters : baseSearchCenters
        let spacingMiles = max(30.0, totalMiles / Double(maxCenters))
        let centers = sampledCenters(from: routeCoordinates, totalMiles: totalMiles, spacingMiles: spacingMiles)

        guard Task.isCancelled == false else { return [] }

        // Run MapKit local searches concurrently; individual failures are tolerated silently.
        var hits: [GasHit] = []

        await withTaskGroup(of: [GasHit].self) { group in
            for center in centers {
                group.addTask {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = "gas station"
                    request.region = MKCoordinateRegion(
                        center: center,
                        latitudinalMeters: searchRadiusMeters,
                        longitudinalMeters: searchRadiusMeters
                    )
                    request.resultTypes = .pointOfInterest
                    do {
                        let response = try await MKLocalSearch(request: request).start()
                        // Access MapKit/CoreLocation types on the main actor — they are
                        // @MainActor-isolated in iOS 27's SDK. GasHit is Sendable so the
                        // result crosses back to the calling task context safely.
                        return await MainActor.run {
                            response.mapItems.compactMap { item -> GasHit? in
                                let c = item.placemark.coordinate
                                guard Self.validCoord(c) else { return nil }
                                return GasHit(
                                    name: item.name ?? "Gas Station",
                                    locality: item.placemark.locality ?? "",
                                    adminArea: item.placemark.administrativeArea ?? "",
                                    latitude: c.latitude,
                                    longitude: c.longitude,
                                    distanceAlong: Self.nearestAlong(c, in: routeCoordinates)
                                )
                            }
                        }
                    } catch {
                        return []
                    }
                }
            }
            for await batch in group {
                hits.append(contentsOf: batch)
            }
        }

        guard Task.isCancelled == false else { return [] }

        // De-duplicate by coordinate proximity, apply corridor-offset filter, sort along route.
        var seen = Set<String>()
        var result: [BackupGasStation] = []

        for hit in hits.sorted(by: { $0.distanceAlong < $1.distanceAlong }) {
            let coord = CLLocationCoordinate2D(latitude: hit.latitude, longitude: hit.longitude)
            let offRoute = Self.minOffRoute(coord, in: routeCoordinates)
            guard offRoute <= maxOffRouteMiles else { continue }

            let key = stableKey(latitude: hit.latitude, longitude: hit.longitude, name: hit.name)
            guard seen.insert(key).inserted else { continue }

            result.append(BackupGasStation(
                id: key,
                name: hit.name,
                city: hit.locality,
                state: hit.adminArea,
                coordinate: coord,
                distanceAlongRouteMiles: hit.distanceAlong,
                offRouteMiles: offRoute
            ))
        }

        return mergeNearDuplicates(result)
    }

    /// The exact-key dedup above only catches identical rounded coordinates. Overlapping
    /// search circles can still surface the same real-world station twice with slightly
    /// different geocoded coordinates (e.g. two "Circle K" hits in Kingman ~120 m apart).
    /// Merge entries that share a normalized name AND sit within `nearDuplicateRadiusMiles`
    /// of each other, keeping whichever sits closer to the route corridor. Stations that
    /// merely share a name from opposite ends of the route, or sit near each other under
    /// different names, are left as genuinely separate results.
    ///
    /// Internal (not private) so `RouteE85PlannerTests` can exercise it directly with
    /// synthetic stations, without a live MapKit search.
    func mergeNearDuplicates(_ stations: [BackupGasStation]) -> [BackupGasStation] {
        var kept: [BackupGasStation] = []
        for station in stations {
            let normalizedName = station.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let existingIndex = kept.firstIndex(where: {
                $0.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedName &&
                Self.mi($0.coordinate, station.coordinate) <= nearDuplicateRadiusMiles
            }) {
                if station.offRouteMiles < kept[existingIndex].offRouteMiles {
                    kept[existingIndex] = station
                }
                continue
            }
            kept.append(station)
        }
        return kept
    }

    // MARK: - Geometry helpers (self-contained; intentionally not shared with RouteE85Planner's
    // private types to keep BackupGasStationFinder independently usable.)

    private func sampledCenters(
        from coords: [CLLocationCoordinate2D],
        totalMiles: Double,
        spacingMiles: Double
    ) -> [CLLocationCoordinate2D] {
        var centers: [CLLocationCoordinate2D] = [coords[0]]
        var cumulative = 0.0
        var nextTarget = spacingMiles
        var prev = coords[0]

        for i in 1..<coords.count {
            let curr = coords[i]
            let seg = Self.mi(prev, curr)
            while nextTarget <= cumulative + seg {
                let f = seg > 0 ? (nextTarget - cumulative) / seg : 0
                centers.append(CLLocationCoordinate2D(
                    latitude: prev.latitude + (curr.latitude - prev.latitude) * f,
                    longitude: prev.longitude + (curr.longitude - prev.longitude) * f
                ))
                nextTarget += spacingMiles
            }
            cumulative += seg
            prev = curr
        }
        centers.append(coords[coords.count - 1])
        return centers
    }

    private static func nearestAlong(_ point: CLLocationCoordinate2D, in coords: [CLLocationCoordinate2D]) -> Double {
        var bestDist = Double.greatestFiniteMagnitude
        var bestAlong = 0.0
        var cumulative = 0.0
        var prev = coords[0]
        for i in 1..<coords.count {
            let curr = coords[i]
            let d = mi(point, prev)
            if d < bestDist { bestDist = d; bestAlong = cumulative }
            cumulative += mi(prev, curr)
            prev = curr
        }
        if mi(point, prev) < bestDist { bestAlong = cumulative }
        return bestAlong
    }

    private static func minOffRoute(_ point: CLLocationCoordinate2D, in coords: [CLLocationCoordinate2D]) -> Double {
        coords.reduce(Double.greatestFiniteMagnitude) { min($0, mi(point, $1)) }
    }

    // Pure Haversine formula — avoids CLLocation (which is @MainActor in iOS 27) so these
    // helpers stay nonisolated and can be called from concurrent task closures.
    private static func mi(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let sin2 = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 3958.8 * 2 * atan2(sqrt(sin2), sqrt(1 - sin2))
    }

    private static func validCoord(_ c: CLLocationCoordinate2D) -> Bool {
        (-90...90).contains(c.latitude) && (-180...180).contains(c.longitude) && (c.latitude != 0 || c.longitude != 0)
    }

    // Round to ~100 m precision (3 decimal places ≈ 111 m) to dedup nearby results.
    private func stableKey(latitude: Double, longitude: Double, name: String) -> String {
        let lat = (latitude * 1000).rounded() / 1000
        let lon = (longitude * 1000).rounded() / 1000
        let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)
        return "gas|\(lat)|\(lon)|\(n)"
    }
}

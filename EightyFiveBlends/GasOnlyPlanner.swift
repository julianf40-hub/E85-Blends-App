//
//  GasOnlyPlanner.swift
//  EightyFiveBlends
//
//  Pure, SwiftUI-independent Gas Only stop planner. Computes a complete
//  `GasOnlyPlanResult` from a station snapshot in one call so TripPlannerView can publish
//  every related piece of UI state (stations, stops, outcome, risk, reserve, error)
//  together instead of writing them from logic that could disagree with itself — see
//  fix/2.2.3-gas-only-first-plan-stations, which fixed exactly that: the outcome
//  classification could report `.gasFuelStopNeeded` ("no station found") even when real
//  stops had just been computed and published, because a `planFailed` flag from a later,
//  unrelated walk failure was allowed to override the outcome regardless of whether any
//  stops existed. Mirrors RouteE85Planner.Recommendation's inputsValid contract, but this
//  is deliberately its own algorithm — not merged with RouteE85Planner's greedy walk (see
//  fix/2.2.3-trip-planner-input-contract's restriction against unifying the two).
//

import Foundation

/// Whether a valid Gas Only plan's stops (if any) are known to complete the trip.
/// Distinct from `inputsValid`/`RouteFuelContext.isValid`: this only applies once the
/// inputs are already known to be valid, and it never affects `stops` — a partial plan's
/// stops are exactly the real, useful stops the walk found, still worth showing and
/// getting directions to; only the "does this route now meet your buffer" claim changes.
enum GasOnlyPlanCompleteness: Equatable {
    /// The route is reachable and the selected arrival buffer is met — either no stop was
    /// needed, or the recommended stops (if any) fully satisfy the trip.
    case complete
    /// One or more usable stops were found and are being recommended, but the walk could
    /// not confirm the route reaches the destination while meeting the arrival buffer —
    /// e.g. it ran out of further usable stations for a later leg. The stops shown are
    /// real and still useful; the trip is not confirmed safe/complete with them alone.
    case partial
    /// No usable stops exist at all — the existing no-station state.
    case noUsableStations
}

/// The complete outcome of one Gas Only planning attempt, ready to publish atomically.
struct GasOnlyPlanResult {
    /// The raw discovered candidate stations (echoes the input; kept for parity with the
    /// E85 path's discovered-stations state).
    let stations: [BackupGasStation]
    let stops: [GasOnlyStop]
    let outcome: RouteOutcome?
    let risk: TripPlan.RouteRisk?
    let destinationReserveFraction: Double?
    let stationError: String?
    /// False when the fuel context or route distance was invalid — see
    /// `RouteFuelContext.isValid`. Every other field is then an explicit non-safe
    /// placeholder (no stations, no stops, no outcome), never a result of real range math.
    let inputsValid: Bool
    /// Nil only when `inputsValid` is false. The single source every Gas Only UI section
    /// (Trip Summary banner, Fuel Plan, Recommended Fuel Stops heading, route-outcome row)
    /// must read to decide whether it's safe to present the route as complete — see
    /// `GasOnlyPlanCompleteness`.
    let completeness: GasOnlyPlanCompleteness?
}

enum GasOnlyPlanner {
    private static let minSafeArrivalFraction = 0.12

    /// Greedy gas-stop planner for Gas Only mode. Mirrors the E85 planner's approach: walk
    /// the route, fill to full at each chosen stop, prefer low-detour stations.
    static func plan(
        stations: [BackupGasStation],
        distanceMiles: Double,
        context: RouteFuelContext
    ) -> GasOnlyPlanResult {
        // Reuse RouteFuelContext.isValid — the same authoritative validity check the E85
        // planner gates on — rather than re-deriving a local finite/positive check here.
        // Invalid tank/MPG/fuel/reserve inputs must never be reported as a safe Gas Only
        // plan; a distance that isn't finite and non-negative is equally untrustworthy.
        guard context.isValid, distanceMiles.isFinite, distanceMiles >= 0 else {
            return GasOnlyPlanResult(
                stations: [],
                stops: [],
                outcome: nil,
                risk: .high,
                destinationReserveFraction: nil,
                stationError: "Trip Planner could not calculate a safe plan because the vehicle fuel settings are invalid.",
                inputsValid: false,
                completeness: nil
            )
        }

        let tankSize = context.tankSizeGallons
        let mpg = context.mpg
        let targetFraction = context.targetReserveFraction
        let startGallons = context.startFuelGallons

        // Reserve at destination without any stop.
        let noStopReserveFraction = (startGallons - distanceMiles / mpg) / tankSize

        // No stop needed if the reserve target is already met.
        if noStopReserveFraction >= targetFraction {
            return GasOnlyPlanResult(
                stations: stations,
                stops: [],
                outcome: .gasolineOnly,
                risk: (noStopReserveFraction - targetFraction) < 0.05 ? .medium : .low,
                destinationReserveFraction: noStopReserveFraction,
                stationError: nil,
                inputsValid: true,
                completeness: .complete
            )
        }

        // Stop needed but no stations available.
        if stations.isEmpty {
            return GasOnlyPlanResult(
                stations: [],
                stops: [],
                outcome: .gasFuelStopNeeded,
                risk: noStopReserveFraction < 0 ? .high : .medium,
                destinationReserveFraction: noStopReserveFraction,
                stationError: nil,
                inputsValid: true,
                completeness: .noUsableStations
            )
        }

        let sorted = stations.sorted { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles }
        var position = 0.0
        var fuelGallons = startGallons
        var stops: [GasOnlyStop] = []
        var lowestReserve = noStopReserveFraction
        var hadRiskyLeg = false
        var planFailed = false
        var safety = 0

        while safety < 32 {
            safety += 1
            let distToDestination = distanceMiles - position
            let reserveAtDestFraction = (fuelGallons - distToDestination / mpg) / tankSize
            if reserveAtDestFraction >= targetFraction { break }

            let ahead = sorted.filter { $0.distanceAlongRouteMiles > position + 0.5 }
            let safeOptions = ahead.filter { s in
                let legMiles = s.distanceAlongRouteMiles - position
                return (fuelGallons - legMiles / mpg) / tankSize >= minSafeArrivalFraction
            }

            let chosen: BackupGasStation?
            if safeOptions.isEmpty {
                let reachable = ahead.filter { s in
                    let legMiles = s.distanceAlongRouteMiles - position
                    return (fuelGallons - legMiles / mpg) >= 0
                }
                if reachable.isEmpty { planFailed = true; break }
                hadRiskyLeg = true
                chosen = reachable.max { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles }
            } else {
                let lowDetour = safeOptions.filter {
                    $0.detourSeverity == .onRoute || $0.detourSeverity == .smallDetour
                }
                let pool = lowDetour.isEmpty ? safeOptions : lowDetour
                chosen = pool.max { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles }
            }

            guard let stop = chosen, stop.distanceAlongRouteMiles > position + 0.5 else {
                planFailed = true
                break
            }

            let legMiles = stop.distanceAlongRouteMiles - position
            let arrivalGallons = fuelGallons - legMiles / mpg
            let arrivalFraction = arrivalGallons / tankSize
            lowestReserve = min(lowestReserve, arrivalFraction)

            stops.append(GasOnlyStop(
                id: stop.id + "_\(stops.count)",
                station: stop,
                arrivalReserveFraction: arrivalFraction,
                suggestedFillGallons: max(0, tankSize - arrivalGallons),
                recommendedForReserveTarget: true
            ))

            position = stop.distanceAlongRouteMiles
            fuelGallons = tankSize
        }

        let finalReserveFraction: Double
        if planFailed || stops.isEmpty {
            finalReserveFraction = noStopReserveFraction
        } else {
            let remaining = distanceMiles - position
            finalReserveFraction = (fuelGallons - remaining / mpg) / tankSize
            lowestReserve = min(lowestReserve, finalReserveFraction)
        }

        // Whether any real stops were found is checked FIRST — a plan that found and is
        // recommending stops must never be reported as "no station found," even if the
        // walk later failed to find a further stop needed to fully complete the route.
        // That situation is real and must be visible, but as elevated RISK on the stops
        // that WERE found, not as an outcome that contradicts (and hides) them.
        let outcome: RouteOutcome
        let risk: TripPlan.RouteRisk
        let completeness: GasOnlyPlanCompleteness
        if stops.isEmpty {
            if planFailed || finalReserveFraction < targetFraction {
                outcome = .gasFuelStopNeeded
                risk = .high
                completeness = .noUsableStations
            } else {
                outcome = .gasolineOnly
                risk = .low
                completeness = .complete
            }
        } else {
            outcome = .gasStopRecommended
            if planFailed || hadRiskyLeg || lowestReserve < 0.10 {
                risk = .high
            } else if stops.count == 1, let s = stops.first,
                      s.station.detourSeverity == .moderateDetour {
                risk = .medium
            } else if (finalReserveFraction - targetFraction) < 0.05 {
                risk = .medium
            } else {
                risk = .low
            }
            // The walk running out of further usable stations for a later leg (planFailed)
            // means these real stops don't confirm the route meets the buffer — that must
            // stay visible as "partial," not get silently folded into a normal complete plan.
            completeness = planFailed ? .partial : .complete
        }

        return GasOnlyPlanResult(
            stations: stations,
            stops: stops,
            outcome: outcome,
            risk: risk,
            destinationReserveFraction: finalReserveFraction,
            stationError: nil,
            inputsValid: true,
            completeness: completeness
        )
    }
}

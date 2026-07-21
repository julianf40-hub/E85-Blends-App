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
//  feature/2.2.3-gas-only-fuel-optimization: the greedy walk below still SELECTS which
//  stations to stop at exactly as before (unchanged, so existing stop sequences are
//  preserved) — but it now only records the chosen station order, not fill amounts. A
//  separate `minimalFillStops` pass then sizes each purchase to the minimum needed for the
//  planned onward leg (the existing minSafeArrivalFraction margin for an intermediate leg,
//  the user's selected destination reserve for the final leg) instead of always filling to
//  full, and risk is now classified from the REAL minimum buffer actually experienced along
//  the route (each stop's true arrival fraction plus the destination reserve) rather than
//  from a stale "if you'd never stopped at all" number that could never recover once seeded.
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
    /// The lowest arrival-reserve fraction actually experienced anywhere along the route —
    /// across every real stop arrival and the destination — used to classify risk. Nil only
    /// when `inputsValid` is false. Deliberately excludes the "if you never stopped at all"
    /// hypothetical, since that isn't part of the route once a stop is actually planned.
    let minimumBufferFraction: Double?
    /// Whether the destination reserve meets or exceeds the user's selected target. Nil
    /// only when `inputsValid` is false.
    let targetReserveSatisfied: Bool?
}

enum GasOnlyPlanner {
    private static let minSafeArrivalFraction = 0.12

    /// Greedy gas-stop planner for Gas Only mode. Mirrors the E85 planner's approach: walk
    /// the route, choosing the farthest materially safe/reachable station at each step,
    /// preferring low-detour stations. Stop SELECTION only — see `minimalFillStops` for how
    /// each chosen stop's actual purchase amount is sized.
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
                completeness: nil,
                minimumBufferFraction: nil,
                targetReserveSatisfied: nil
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
                risk: classifyRisk(
                    completeness: .complete,
                    targetReserveSatisfied: true,
                    minimumBufferFraction: noStopReserveFraction
                ),
                destinationReserveFraction: noStopReserveFraction,
                stationError: nil,
                inputsValid: true,
                completeness: .complete,
                minimumBufferFraction: noStopReserveFraction,
                targetReserveSatisfied: true
            )
        }

        // Stop needed but no stations available.
        if stations.isEmpty {
            return GasOnlyPlanResult(
                stations: [],
                stops: [],
                outcome: .gasFuelStopNeeded,
                risk: classifyRisk(
                    completeness: .noUsableStations,
                    targetReserveSatisfied: false,
                    minimumBufferFraction: noStopReserveFraction
                ),
                destinationReserveFraction: noStopReserveFraction,
                stationError: nil,
                inputsValid: true,
                completeness: .noUsableStations,
                minimumBufferFraction: noStopReserveFraction,
                targetReserveSatisfied: false
            )
        }

        // MARK: - Stop selection (unchanged from prior branches)
        //
        // This walk assumes a full tank after every chosen stop purely to decide WHICH
        // stations are viable candidates — it never changes which stops are chosen. Actual
        // purchase amounts are computed afterward by `minimalFillStops`.
        let sorted = stations.sorted { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles }
        var position = 0.0
        var fuelGallons = startGallons
        var chosenStations: [BackupGasStation] = []
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

            chosenStations.append(stop)
            position = stop.distanceAlongRouteMiles
            fuelGallons = tankSize
        }

        // MARK: - Minimum-fill sizing (feature/2.2.3-gas-only-fuel-optimization)
        //
        // Recomputes real arrival/purchase amounts for the CHOSEN sequence above using
        // minimum safe fills instead of the full-tank assumption used only for selection.
        let (stops, fuelAfterLastStop) = minimalFillStops(
            chosenStations: chosenStations,
            startGallons: startGallons,
            distanceMiles: distanceMiles,
            tankSize: tankSize,
            mpg: mpg,
            targetFraction: targetFraction
        )

        let finalReserveFraction: Double
        if planFailed || stops.isEmpty {
            finalReserveFraction = noStopReserveFraction
        } else {
            let remaining = distanceMiles - stops[stops.count - 1].station.distanceAlongRouteMiles
            finalReserveFraction = (fuelAfterLastStop - remaining / mpg) / tankSize
        }

        // The minimum buffer actually experienced along the REAL route: every stop's true
        // arrival fraction plus the destination reserve. Deliberately excludes the "if you
        // never stopped" hypothetical (noStopReserveFraction) — that isn't part of the
        // route once a stop is genuinely planned, and seeding from it here previously kept
        // this value pinned low even when the real trip's minimum was comfortably positive.
        let realizedFractions = stops.map { $0.arrivalReserveFraction } + [finalReserveFraction]
        let minimumBufferFraction = realizedFractions.min() ?? finalReserveFraction

        // Whether any real stops were found is checked FIRST — a plan that found and is
        // recommending stops must never be reported as "no station found," even if the
        // walk later failed to find a further stop needed to fully complete the route.
        // That situation is real and must be visible, but as elevated RISK on the stops
        // that WERE found, not as an outcome that contradicts (and hides) them.
        let outcome: RouteOutcome
        let completeness: GasOnlyPlanCompleteness
        let targetReserveSatisfied = finalReserveFraction >= targetFraction - 1e-9
        if stops.isEmpty {
            if planFailed || finalReserveFraction < targetFraction {
                outcome = .gasFuelStopNeeded
                completeness = .noUsableStations
            } else {
                outcome = .gasolineOnly
                completeness = .complete
            }
        } else {
            outcome = .gasStopRecommended
            // The walk running out of further usable stations for a later leg (planFailed)
            // means these real stops don't confirm the route meets the buffer — that must
            // stay visible as "partial," not get silently folded into a normal complete plan.
            completeness = planFailed ? .partial : .complete
        }

        let risk = classifyRisk(
            completeness: completeness,
            targetReserveSatisfied: targetReserveSatisfied,
            minimumBufferFraction: minimumBufferFraction,
            hadRiskyLeg: hadRiskyLeg
        )

        return GasOnlyPlanResult(
            stations: stations,
            stops: stops,
            outcome: outcome,
            risk: risk,
            destinationReserveFraction: finalReserveFraction,
            stationError: nil,
            inputsValid: true,
            completeness: completeness,
            minimumBufferFraction: minimumBufferFraction,
            targetReserveSatisfied: targetReserveSatisfied
        )
    }

    // MARK: - Minimum-fill sizing

    /// Given the stop SEQUENCE already chosen by the greedy walk (positions/identities
    /// unchanged), computes the minimum safe purchase at each stop instead of always
    /// filling to full.
    ///
    /// Two passes:
    /// 1. Backward: the minimum fuel that must be ON BOARD when DEPARTING each stop — the
    ///    user's selected destination reserve for the final leg, the existing
    ///    `minSafeArrivalFraction` safety margin (the same threshold stop selection above
    ///    already used to call a leg "safe") for every earlier leg — each clamped to
    ///    `0...tankSize`.
    /// 2. Forward: using the vehicle's REAL starting fuel, turns those departure targets
    ///    into actual arrival amounts and purchase sizes.
    ///
    /// This preserves safety on every leg: whenever the walk chose a stop via its normal
    /// (non-emergency) "safe" path, the required departure fuel for the leg before it is
    /// guaranteed to be ≤ tankSize (the same arithmetic the walk already verified when
    /// picking that stop), so no clamping occurs and arrival at the next stop lands exactly
    /// on the existing safety margin — never below it. When a leg was only reachable via
    /// the walk's emergency "relax" fallback (hadRiskyLeg), the required departure fuel
    /// clamps to a full tank — identical to the walk's own (already-accepted) assumption
    /// for that leg, so it can never become less safe than before.
    private static func minimalFillStops(
        chosenStations: [BackupGasStation],
        startGallons: Double,
        distanceMiles: Double,
        tankSize: Double,
        mpg: Double,
        targetFraction: Double
    ) -> (stops: [GasOnlyStop], fuelAfterLastStop: Double) {
        guard chosenStations.isEmpty == false else { return ([], startGallons) }

        let n = chosenStations.count
        var requiredDeparture = [Double](repeating: 0, count: n)

        let lastLegMiles = distanceMiles - chosenStations[n - 1].distanceAlongRouteMiles
        requiredDeparture[n - 1] = min(tankSize, max(0, lastLegMiles / mpg + targetFraction * tankSize))

        if n >= 2 {
            for i in stride(from: n - 2, through: 0, by: -1) {
                let legMiles = chosenStations[i + 1].distanceAlongRouteMiles - chosenStations[i].distanceAlongRouteMiles
                requiredDeparture[i] = min(tankSize, max(0, legMiles / mpg + minSafeArrivalFraction * tankSize))
            }
        }

        var stops: [GasOnlyStop] = []
        var fuelOnBoard = startGallons
        var previousPosition = 0.0

        for i in 0..<n {
            let station = chosenStations[i]
            let legMiles = station.distanceAlongRouteMiles - previousPosition
            let arrivalGallons = fuelOnBoard - legMiles / mpg
            let arrivalFraction = arrivalGallons / tankSize
            let fillGallons = max(0, min(requiredDeparture[i], tankSize) - arrivalGallons)

            stops.append(GasOnlyStop(
                id: station.id + "_\(i)",
                station: station,
                arrivalReserveFraction: arrivalFraction,
                suggestedFillGallons: fillGallons,
                recommendedForReserveTarget: true
            ))

            fuelOnBoard = arrivalGallons + fillGallons
            previousPosition = station.distanceAlongRouteMiles
        }

        return (stops, fuelOnBoard)
    }

    // MARK: - Risk classification
    //
    // One authoritative function, in this required order:
    // 1. Not a complete plan and no stops exist (no usable stations) → High.
    // 2. Partial plan (stops exist, route not confirmed complete) → High.
    // 3. Complete plan that (defensively) doesn't actually satisfy the target → High.
    // 4. Complete plan meeting the target → classify by minimum buffer actually
    //    experienced along the route: Low ≥ 30%, Medium 10...<30%, High < 10%.
    //
    // TripPlan.RouteRisk has exactly three cases (low/medium/high), so this uses the
    // three-tier scheme rather than inventing a fourth level.
    private static func classifyRisk(
        completeness: GasOnlyPlanCompleteness,
        targetReserveSatisfied: Bool,
        minimumBufferFraction: Double,
        hadRiskyLeg: Bool = false
    ) -> TripPlan.RouteRisk {
        guard completeness == .complete else { return .high }
        guard targetReserveSatisfied else { return .high }
        // A leg that only became reachable via the walk's emergency "relax" fallback is a
        // real hazard regardless of how comfortable the final numbers look.
        if hadRiskyLeg { return .high }
        // A tiny epsilon guards the tier boundaries against floating-point noise: a plan
        // whose minimum buffer is mathematically exactly the target (e.g. fuel sized to
        // land precisely on a 10% reserve) must not spuriously tip into the worse tier
        // just because subtraction/addition of the same terms landed a few ULPs below it.
        let epsilon = 1e-9
        if minimumBufferFraction < 0.10 - epsilon { return .high }
        if minimumBufferFraction < 0.30 - epsilon { return .medium }
        return .low
    }
}

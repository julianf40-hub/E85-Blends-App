//
//  PumpStationContextResolver.swift
//  EightyFiveBlends
//
//  Pure station-context matching for a MANUALLY opened Pump Mode session — deliberately
//  separate from PumpProximity, which remains the sole authority for the automatic "At the
//  Pump?" prompt (this resolver's own radius is independently maintained; it doesn't read
//  or reuse PumpProximity's constants). This resolver answers a different question: once the
//  user has already explicitly chosen Pump Mode, which nearby station (saved OR recently
//  seen via live search) most likely matches where they're standing? It tolerates normal
//  GPS drift under a gas-station canopy that the automatic prompt's tighter 30 m/75 m gate
//  correctly refuses to.
//
//  Never feed this resolver's radius or result into the automatic prompt
//  (evaluateAutoPromptPumpMode) — see CalculatorView for the enforced separation.
//

import CoreLocation
import Foundation

// MARK: - Candidate model

/// A station eligible for manual Pump Mode context matching — either a locally saved
/// FuelStation or a recently seen live search result. Deliberately independent of
/// SwiftData/NREL types so it stays pure and unit-testable.
struct PumpStationContextCandidate: Identifiable, Equatable {
    enum Source: Equatable {
        case saved
        case live
    }

    /// Deterministic key derived from name + coordinate — see
    /// `AutomaticPumpDetectionStationKey.make`, reused here rather than duplicated so
    /// saved/live copies of the same physical station always produce the same ID.
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let address: String?
    /// E85 price if known. Saved stations may have one; live (NREL) results currently
    /// never do, since the feed doesn't carry station-level pricing.
    let e85Price: Double?
    let source: Source
}

/// Caller-provided view of one saved station, decoupled from the `FuelStation` SwiftData
/// model — mirrors `SavedStationSnapshot` (Automatic Pump Detection) but also carries the
/// E85 price this resolver needs for fuel-log prefill.
struct PumpContextSavedStationSnapshot {
    let name: String
    let latitude: Double?
    let longitude: Double?
    let address: String?
    let e85Price: Double?
}

// MARK: - Result

enum PumpStationContextResult: Equatable {
    case matched(PumpStationContextCandidate)
    case noCandidates
    case locationUnavailable
    case locationStale
    case locationInaccurate
    case ambiguous([PumpStationContextCandidate])
}

// MARK: - Session state

/// One candidate in an ambiguous-match picker, with the distance (from the fresh fix that
/// produced the ambiguity) needed to display it meaningfully. Kept separate from the pure
/// `PumpStationContextResult.ambiguous` payload (which stays exactly the candidate list the
/// resolver reasoned about, for simple, direct testing) — the UI-facing session state adds
/// distance on top once CalculatorView has both the fix and the result in hand.
struct PumpStationContextAmbiguousCandidate: Identifiable, Equatable {
    let candidate: PumpStationContextCandidate
    let distanceMeters: CLLocationDistance
    var id: String { candidate.id }
}

/// Session-scoped view of a manually opened Pump Mode's station-context resolution,
/// consumed by CalculatorView/AtThePumpView. Distinct from `PumpStationContextResult` —
/// adds `.resolving` (no result yet, the sheet just opened) and `.preciseLocationRequired`
/// (a UX-specific read of `.locationInaccurate`/`.locationStale` when the device's own
/// accuracy authorization is reduced, so the copy can point at the actual fix rather than
/// a generic failure).
enum PumpModeStationContextState: Equatable {
    case resolving
    case matched(PumpStationContextCandidate)
    case noMatch
    case locationUnavailable
    case preciseLocationRequired
    case ambiguous([PumpStationContextAmbiguousCandidate])
}

// MARK: - Resolver

enum PumpStationContextResolver {
    // MARK: Policy constants (separate from PumpProximity; never reused for the auto-prompt)

    /// Station-context match radius after the user has explicitly opened Pump Mode.
    /// Deliberately wider than PumpProximity's 30 m entry radius to tolerate normal GPS
    /// drift under a canopy, but still tightly bounded — nowhere near the old half-mile
    /// "detect station" search radius used elsewhere in the fuel log.
    static let manualContextRadiusMeters: CLLocationDistance = 40

    /// Oldest a fresh fix may be before it's treated as stale for context matching.
    static let maximumLocationAge: TimeInterval = 120

    /// Worst horizontal accuracy accepted for context matching. Matches PumpProximity's own
    /// 50 m accuracy gate — both decisions (attributing a fill-up here vs. interrupting the
    /// user there) tolerate the same realistic canopy-degraded GPS accuracy.
    static let maximumAccuracyMeters: CLLocationAccuracy = 50

    /// How long a single fresh-location request is allowed to take before giving up on it.
    static let freshLocationTimeout: TimeInterval = 8

    /// At most this many fresh-location attempts per manual Pump Mode session.
    static let maximumFreshLocationAttempts = 2

    /// If the two nearest distinct stations are both within the context radius and their
    /// distance difference is this small or less, do not silently pick one — ask the user.
    static let ambiguityDistanceDeltaMeters: CLLocationDistance = 10

    // MARK: Candidate construction

    static func candidate(fromSaved snapshot: PumpContextSavedStationSnapshot) -> PumpStationContextCandidate? {
        guard let latitude = snapshot.latitude, let longitude = snapshot.longitude,
              MonitoredStationSelector.isValidCoordinate(latitude: latitude, longitude: longitude) else {
            return nil
        }
        return PumpStationContextCandidate(
            id: AutomaticPumpDetectionStationKey.make(name: snapshot.name, latitude: latitude, longitude: longitude),
            name: snapshot.name,
            latitude: latitude,
            longitude: longitude,
            address: snapshot.address,
            e85Price: snapshot.e85Price,
            source: .saved
        )
    }

    static func candidate(fromLive snapshot: LiveStationSnapshot) -> PumpStationContextCandidate? {
        guard MonitoredStationSelector.isValidCoordinate(latitude: snapshot.latitude, longitude: snapshot.longitude) else {
            return nil
        }
        return PumpStationContextCandidate(
            id: snapshot.id,
            name: snapshot.name,
            latitude: snapshot.latitude,
            longitude: snapshot.longitude,
            address: snapshot.address,
            e85Price: nil,
            source: .live
        )
    }

    // MARK: Resolution

    /// Resolves the most likely station for a manually opened Pump Mode session. Pure and
    /// deterministic given its inputs — `now` is always injected so staleness can be
    /// tested without wall-clock timing.
    static func resolve(
        candidates: [PumpStationContextCandidate],
        freshLatitude: Double?,
        freshLongitude: Double?,
        horizontalAccuracyMeters: CLLocationAccuracy?,
        locationTimestamp: Date?,
        now: Date
    ) -> PumpStationContextResult {
        guard let freshLatitude, let freshLongitude, let locationTimestamp else {
            return .locationUnavailable
        }
        guard now.timeIntervalSince(locationTimestamp) <= maximumLocationAge else {
            return .locationStale
        }
        guard let accuracy = horizontalAccuracyMeters, accuracy >= 0, accuracy <= maximumAccuracyMeters else {
            return .locationInaccurate
        }

        let userLocation = CLLocation(latitude: freshLatitude, longitude: freshLongitude)

        let inRange: [(candidate: PumpStationContextCandidate, distance: CLLocationDistance)] = candidates.compactMap { candidate in
            guard MonitoredStationSelector.isValidCoordinate(latitude: candidate.latitude, longitude: candidate.longitude) else {
                return nil
            }
            let distance = userLocation.distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude))
            guard distance <= manualContextRadiusMeters else { return nil }
            return (candidate, distance)
        }

        guard inRange.isEmpty == false else {
            return .noCandidates
        }

        // Prefer a saved copy over a live copy of the same physical station (same
        // deterministic ID) before applying ambiguity — a station the user already saved
        // is always the more authoritative match for price/name prefill.
        var bestByID: [String: (candidate: PumpStationContextCandidate, distance: CLLocationDistance)] = [:]
        for entry in inRange {
            guard let existing = bestByID[entry.candidate.id] else {
                bestByID[entry.candidate.id] = entry
                continue
            }
            let entryIsSaved = entry.candidate.source == .saved
            let existingIsSaved = existing.candidate.source == .saved
            if entryIsSaved && existingIsSaved == false {
                bestByID[entry.candidate.id] = entry
            } else if entryIsSaved == existingIsSaved, entry.distance < existing.distance {
                bestByID[entry.candidate.id] = entry
            }
        }

        let deduped = bestByID.values.sorted { $0.distance < $1.distance }

        guard deduped.count > 1 else {
            return .matched(deduped[0].candidate)
        }

        let nearest = deduped[0]
        let secondNearest = deduped[1]
        if secondNearest.distance - nearest.distance <= ambiguityDistanceDeltaMeters {
            return .ambiguous([nearest.candidate, secondNearest.candidate])
        }

        return .matched(nearest.candidate)
    }
}

//
//  AutomaticPumpDetectionModels.swift
//  EightyFiveBlends
//
//  Pure data types and decision logic for Automatic Pump Detection, kept free of Core
//  Location manager instances, UNUserNotificationCenter, and SwiftData so they can be unit
//  tested directly (see AutomaticPumpDetectionTests.swift). The impure orchestration —
//  CLLocationManager region monitoring, notification scheduling, persistence — lives in
//  AutomaticPumpDetectionService.swift, which calls into these pure functions rather than
//  duplicating their logic.
//

import CoreLocation
import Foundation

/// Lightweight, persistable snapshot of a station being background-monitored. Deliberately
/// minimal: just enough to register a region, resolve a notification tap, and show a
/// station name — never a copy of the full station database. See
/// `AutomaticPumpDetectionService` for how this is persisted and refreshed.
struct MonitoredStationRecord: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let address: String?
}

enum AutomaticPumpDetectionStationKey {
    /// A deterministic identifier derived from a station's own name + coordinate. Stable
    /// across app relaunches without requiring any schema change to `FuelStation` (which
    /// has no explicit stable ID field of its own — only SwiftData's opaque
    /// `persistentModelID`, which isn't a plain String/UUID suitable for a CLRegion
    /// identifier). Rounding the coordinate to 5 decimal places (~1.1 m) absorbs
    /// floating-point noise while remaining station-specific.
    static func make(name: String, latitude: Double, longitude: Double) -> String {
        let lat = String(format: "%.5f", latitude)
        let lon = String(format: "%.5f", longitude)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "station:\(normalizedName)|\(lat)|\(lon)"
    }
}

/// Input to `MonitoredStationSelector`. Anything with a name/coordinate can become a
/// monitoring candidate — the selector never touches `FuelStation`/`LiveFuelStation`
/// directly, keeping it independent of SwiftData/network types.
struct MonitoredStationCandidate: Equatable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let address: String?
}

/// A caller-provided view of one saved station — lets `AutomaticPumpDetectionService`
/// accept station data without importing SwiftData or knowing about `FuelStation`
/// directly. Views that already query `[FuelStation]` map into this at the call site.
struct SavedStationSnapshot {
    let name: String
    let latitude: Double?
    let longitude: Double?
    let address: String?
}

enum MonitoredStationSelector {
    /// Core Location limits circular-region monitoring to a small number of active
    /// conditions per app (historically 20 across all apps' monitored regions combined at
    /// the OS level, though the practical per-app ceiling is effectively the same 20).
    /// Reserve headroom rather than use every slot.
    static let maximumMonitoredStations = 15

    /// Chooses which stations to background-monitor: valid coordinates only, deduplicated
    /// by stable ID (first occurrence wins), nearest-first, capped at `limit`. Pure and
    /// deterministic — no Core Location manager, no I/O — so it is directly unit-testable.
    static func select(
        from candidates: [MonitoredStationCandidate],
        userLatitude: Double,
        userLongitude: Double,
        limit: Int = maximumMonitoredStations
    ) -> [MonitoredStationCandidate] {
        guard limit > 0 else { return [] }

        var seenIDs = Set<String>()
        let userLocation = CLLocation(latitude: userLatitude, longitude: userLongitude)

        let deduped = candidates.filter { candidate in
            guard isValidCoordinate(latitude: candidate.latitude, longitude: candidate.longitude) else {
                return false
            }
            guard seenIDs.contains(candidate.id) == false else {
                return false
            }
            seenIDs.insert(candidate.id)
            return true
        }

        let sorted = deduped.sorted { lhs, rhs in
            let lhsDistance = userLocation.distance(from: CLLocation(latitude: lhs.latitude, longitude: lhs.longitude))
            let rhsDistance = userLocation.distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
            return lhsDistance < rhsDistance
        }

        return Array(sorted.prefix(limit))
    }

    /// Rejects NaN/infinite coordinates, out-of-range coordinates, and the (0, 0)
    /// "null island" sentinel some feeds use for an unset/unknown location.
    static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite &&
            latitude >= -90 && latitude <= 90 &&
            longitude >= -180 && longitude <= 180 &&
            !(latitude == 0 && longitude == 0)
    }
}

/// Stage B of Automatic Pump Detection: turns a coarse "entered the area" wake-up into a
/// precise, confirmed arrival — or a rejection with a diagnostic reason. Reuses
/// `PumpProximity`'s existing, authoritative entry threshold and accuracy gate; never
/// redefines or loosens it.
enum ArrivalConfirmation {
    enum RejectionReason: String {
        case featureDisabled
        case staleLocation
        case inaccurateLocation
        case outsideThreshold
        case invalidStationCoordinate
    }

    enum Outcome: Equatable {
        case confirmed(distanceMeters: CLLocationDistance)
        case rejected(RejectionReason)
    }

    /// Maximum age of a fresh fix that Stage B will still trust. Older than this and a
    /// stale cached location could wrongly "confirm" an arrival the user has already left.
    static let maximumLocationAge: TimeInterval = 120

    static func evaluate(
        featureEnabled: Bool,
        stationLatitude: Double,
        stationLongitude: Double,
        freshLatitude: Double,
        freshLongitude: Double,
        horizontalAccuracyMeters: CLLocationAccuracy?,
        locationTimestamp: Date,
        now: Date,
        maximumLocationAge: TimeInterval = ArrivalConfirmation.maximumLocationAge
    ) -> Outcome {
        guard featureEnabled else {
            return .rejected(.featureDisabled)
        }
        guard MonitoredStationSelector.isValidCoordinate(latitude: stationLatitude, longitude: stationLongitude) else {
            return .rejected(.invalidStationCoordinate)
        }
        guard now.timeIntervalSince(locationTimestamp) <= maximumLocationAge else {
            return .rejected(.staleLocation)
        }

        let stationLocation = CLLocation(latitude: stationLatitude, longitude: stationLongitude)
        let freshLocation = CLLocation(latitude: freshLatitude, longitude: freshLongitude)
        let distance = freshLocation.distance(from: stationLocation)

        // A background confirmation is always evaluated as a fresh entry check (never an
        // already-latched "was at pump" state carried over), so it always uses
        // PumpProximity's tighter entry radius rather than its looser exit radius.
        let isAtPump = PumpProximity.isAtPump(
            distanceMeters: distance,
            horizontalAccuracyMeters: horizontalAccuracyMeters,
            wasAtPump: false
        )

        guard isAtPump else {
            // isAtPump already folds "accuracy too poor to trust" into `false` — but
            // diagnostics want to know WHY. Reconstruct the reason from the same inputs
            // PumpProximity itself gates on, without changing that gate's behavior.
            if let accuracy = horizontalAccuracyMeters,
               accuracy >= 0,
               accuracy <= PumpProximity.maximumPumpModeLocationAccuracyMeters {
                return .rejected(.outsideThreshold)
            }
            return .rejected(.inaccurateLocation)
        }

        return .confirmed(distanceMeters: distance)
    }
}

/// Per-station notification cooldown state — prevents repeated "you're at the pump"
/// notifications while the user simply remains parked at the same station.
struct ArrivalCooldownState: Codable, Equatable {
    let stationID: String
    var lastNotifiedAt: Date?
    var hasExitedSinceNotification: Bool
}

enum ArrivalCooldownPolicy {
    /// Fallback cooldown used when the device hasn't clearly exited the station's
    /// monitored area since the last notification (e.g. an exit event was missed).
    /// Centralized here as a named constant rather than a literal scattered through the
    /// service.
    static let fallbackCooldownInterval: TimeInterval = 4 * 60 * 60 // 4 hours

    /// Whether a freshly confirmed arrival should produce a notification, given whatever
    /// cooldown state (if any) exists for this station. Pure and deterministic — `now` is
    /// always injected so cooldown behavior can be tested without wall-clock timing.
    static func shouldNotify(existingState: ArrivalCooldownState?, now: Date) -> Bool {
        guard let existingState, let lastNotifiedAt = existingState.lastNotifiedAt else {
            return true // never notified for this station before
        }
        if existingState.hasExitedSinceNotification {
            return true // a clean exit followed by a brand-new confirmed arrival is always allowed
        }
        return now.timeIntervalSince(lastNotifiedAt) >= fallbackCooldownInterval
    }
}

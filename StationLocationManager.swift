//
//  StationLocationManager.swift
//  EightyFiveBlends
//

import CoreLocation

struct StationCoordinate: Equatable {
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@MainActor
@Observable
final class StationLocationManager: NSObject, CLLocationManagerDelegate {
    /// A region-monitoring entry/exit/failure event, forwarded to whichever feature
    /// registered `onRegionEvent` — this class deliberately stays ignorant of what a
    /// monitored region *means* (e.g. Automatic Pump Detection's coarse station wake-up),
    /// keeping it the single, reusable Core Location authority rather than acquiring
    /// feature-specific knowledge.
    enum RegionEventKind {
        case entered
        case exited
        case monitoringFailed
        /// A `requestState(for:)` reconciliation found the device already inside a monitored
        /// region — never a live boundary crossing. Kept distinct from `.entered` purely so
        /// diagnostics can tell the two apart; callers that don't care may treat them the same.
        case alreadyInside
    }

    typealias FreshLocationResult = (coordinate: StationCoordinate, horizontalAccuracyMeters: CLLocationAccuracy, timestamp: Date)

    private let manager = CLLocationManager()

    var authorizationStatus: CLAuthorizationStatus
    var latestCoordinate: StationCoordinate?
    /// Horizontal accuracy (meters) of the fix behind `latestCoordinate`. Negative or nil
    /// means the fix is unreliable. Pump-mode auto-triggering gates on this so a coarse
    /// indoor/cell fix can never place the user "at the pump" from half a mile away.
    var latestHorizontalAccuracyMeters: CLLocationAccuracy?
    /// Timestamp Core Location attached to the fix behind `latestCoordinate` (not when this
    /// app received it — the two can differ under poor signal). Nothing in the pump-detection
    /// logic reads this; it exists solely so diagnostics UI can show "last location age"
    /// without adding a second source of truth for freshness.
    var latestFixTimestamp: Date?

    /// Fired on region monitoring entry/exit/failure. Set by a feature (e.g. Automatic
    /// Pump Detection) that registered regions via `startMonitoringRegion`.
    var onRegionEvent: ((_ identifier: String, _ kind: RegionEventKind) -> Void)?

    /// At most one Stage-B "give me a fresh fix right now" request in flight at a time —
    /// see `requestFreshLocationAsync()`.
    private var pendingFreshLocationContinuation: CheckedContinuation<FreshLocationResult?, Never>?

    var authorizationDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    var isAuthorizedForUserLocation: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isAuthorizedAlways: Bool {
        authorizationStatus == .authorizedAlways
    }

    /// False when the user has granted only "Approximate Location" (iOS 14+). A reduced
    /// fix is commonly hundreds of meters off — far too coarse for Automatic Pump
    /// Detection's Stage-B confirmation, which needs to trust distances against a ~30 m
    /// threshold. Surfaced so Settings UI can explain why background detection isn't fully
    /// active even with Always authorization granted.
    var isPreciseLocationEnabled: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    /// Currently active region-monitoring identifiers, as tracked by the OS — this
    /// persists across app relaunch independent of any in-process state.
    var monitoredRegionIdentifiers: Set<String> {
        Set(manager.monitoredRegions.map(\.identifier))
    }

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Pump-mode auto-triggering needs a fix roughly as tight as PumpProximity's entry
        // radius. Hundred-meter fixes made the old prompt fire from far away.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func requestUserLocation() {
        authorizationStatus = manager.authorizationStatus

        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            latestCoordinate = nil
            latestFixTimestamp = nil
        @unknown default:
            latestCoordinate = nil
            latestFixTimestamp = nil
        }
    }

    /// Upgrades to Always authorization. Only meaningful (and should only be called) after
    /// When In Use has already been granted and the user has explicitly opted into a
    /// feature that needs background delivery — see AutomaticPumpDetectionService's staged
    /// enable flow. A no-op call is harmless: iOS simply re-shows nothing if there is
    /// nothing left to upgrade.
    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    /// One-shot async location fetch, independent of `requestUserLocation()`'s existing
    /// synchronous/delegate-driven path (that path keeps working exactly as before — this
    /// is purely additive). Used by Automatic Pump Detection's Stage-B precise confirmation,
    /// where a plain callback-driven request doesn't compose well with an async event
    /// handler. Returns nil if unauthorized, or if a fresh-location request is already in
    /// flight (callers are expected to serialize their own Stage-B confirmations).
    func requestFreshLocationAsync() async -> FreshLocationResult? {
        guard isAuthorizedForUserLocation else { return nil }
        guard pendingFreshLocationContinuation == nil else { return nil }

        return await withCheckedContinuation { continuation in
            pendingFreshLocationContinuation = continuation
            manager.requestLocation()
        }
    }

    /// Bounded variant of `requestFreshLocationAsync()` for manual Pump Mode's
    /// station-context resolution, which must never block the UI indefinitely. Races the
    /// existing single-continuation request against a timeout and returns whichever
    /// finishes first. If the timeout wins, the underlying request (if still in flight) is
    /// left alone — its continuation is still resumed normally by the delegate callbacks
    /// above when Core Location eventually responds, satisfying "never leave a
    /// continuation unresolved" — this call simply stops waiting for that value. Does not
    /// alter `requestFreshLocationAsync()`'s existing behavior or its callers (Automatic
    /// Pump Detection), and does not begin continuous updates.
    func requestFreshLocationAsync(timeout: TimeInterval) async -> FreshLocationResult? {
        await withTaskGroup(of: FreshLocationResult?.self) { group -> FreshLocationResult? in
            group.addTask { await self.requestFreshLocationAsync() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return nil
            }
            // `group.next()` unwraps one level (does a child exist); its result is itself
            // the child's `FreshLocationResult?` — do not double-unwrap it away.
            guard let firstResult = await group.next() else {
                return nil
            }
            group.cancelAll()
            return firstResult
        }
    }

    /// Registers a small circular region for background entry/exit monitoring. Does not
    /// enable continuous location updates or set `allowsBackgroundLocationUpdates` — Core
    /// Location delivers region-monitoring events (and, briefly, background execution time
    /// to react to them) independent of that flag and of the "location" background mode.
    func startMonitoringRegion(_ region: CLCircularRegion) {
        manager.startMonitoring(for: region)
    }

    func stopMonitoringRegion(identifier: String) {
        if let region = manager.monitoredRegions.first(where: { $0.identifier == identifier }) {
            manager.stopMonitoring(for: region)
        }
    }

    func stopMonitoringAllRegions() {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
    }

    /// Asks Core Location whether the device is currently inside an already-monitored region.
    /// Registering a region only fires `didEnterRegion` on a future OUTSIDE-to-INSIDE crossing —
    /// if the user is already inside at the moment a region is registered (enabling the feature
    /// while standing at a station, or relaunching while parked at one), no such crossing will
    /// ever occur and the visit would otherwise go undetected until an unrelated future
    /// exit+reentry. This reconciles that by treating an `.inside` result exactly like a fresh
    /// `didEnterRegion` — see `locationManager(_:didDetermineState:for:)` below — reusing the
    /// same Stage A → Stage B pipeline rather than a second, parallel one. A no-op if the
    /// identifier isn't currently monitored.
    func requestState(for identifier: String) {
        guard let region = manager.monitoredRegions.first(where: { $0.identifier == identifier }) else { return }
        manager.requestState(for: region)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            latestHorizontalAccuracyMeters = location.horizontalAccuracy
            latestFixTimestamp = location.timestamp
            latestCoordinate = StationCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )

            if let continuation = pendingFreshLocationContinuation {
                pendingFreshLocationContinuation = nil
                continuation.resume(returning: (
                    coordinate: latestCoordinate!,
                    horizontalAccuracyMeters: location.horizontalAccuracy,
                    timestamp: location.timestamp
                ))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let continuation = pendingFreshLocationContinuation {
            pendingFreshLocationContinuation = nil
            continuation.resume(returning: nil)
        }

        if let clError = error as? CLError, clError.code == .denied {
            authorizationStatus = manager.authorizationStatus
            latestCoordinate = nil
            latestFixTimestamp = nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            latestCoordinate = nil
            latestFixTimestamp = nil
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        onRegionEvent?(region.identifier, .entered)
    }

    /// Response to `requestState(for:)`. Only `.inside` is meaningful here — `.outside` and
    /// `.unknown` are not events (the user simply isn't confirmed to be there), so they are
    /// deliberately no-ops rather than being forwarded as an exit or a failure.
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state == .inside else { return }
        onRegionEvent?(region.identifier, .alreadyInside)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        onRegionEvent?(region.identifier, .exited)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        if let identifier = region?.identifier {
            onRegionEvent?(identifier, .monitoringFailed)
        }
    }
}

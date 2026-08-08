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
    }

    typealias FreshLocationResult = (coordinate: StationCoordinate, horizontalAccuracyMeters: CLLocationAccuracy, timestamp: Date)

    private let manager = CLLocationManager()

    var authorizationStatus: CLAuthorizationStatus
    var latestCoordinate: StationCoordinate?
    /// Horizontal accuracy (meters) of the fix behind `latestCoordinate`. Negative or nil
    /// means the fix is unreliable. Pump-mode auto-triggering gates on this so a coarse
    /// indoor/cell fix can never place the user "at the pump" from half a mile away.
    var latestHorizontalAccuracyMeters: CLLocationAccuracy?

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
        @unknown default:
            latestCoordinate = nil
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

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            latestHorizontalAccuracyMeters = location.horizontalAccuracy
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
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            latestCoordinate = nil
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        onRegionEvent?(region.identifier, .entered)
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

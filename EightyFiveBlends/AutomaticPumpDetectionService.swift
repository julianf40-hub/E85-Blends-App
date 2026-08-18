//
//  AutomaticPumpDetectionService.swift
//  EightyFiveBlends
//
//  Opt-in, battery-conscious background arrival detection. Off by default. When enabled,
//  monitors a small rotating set of the user's saved E85 stations via low-power circular
//  region monitoring (StationLocationManager.startMonitoringRegion) instead of continuous
//  location updates. A region entry is only a coarse wake-up signal (Stage A) — it is never
//  trusted directly. On wake, this service requests one fresh location fix and re-validates
//  distance/accuracy against PumpProximity's shared pump-arrival threshold (Stage B) —
//  the same threshold CalculatorView's foreground path uses, so background and foreground
//  detection can never disagree on what "at the pump" means — before ever scheduling a
//  notification or opening Pump Mode.
//
//  Deliberately does NOT set `allowsBackgroundLocationUpdates = true` and does NOT declare
//  the "location" UIBackgroundModes capability. Region monitoring wakes the app through a
//  separate, OS-managed mechanism that needs neither; a single `requestLocation()` call made
//  during the OS-granted background execution window after a wake is the standard,
//  Apple-documented pattern for reacting to a region event and does not require continuous
//  background updates either. See the branch's final report for the full rationale.
//
//  This service owns only its own state (enabled flag, monitored-station metadata,
//  per-station cooldown). It never touches SwiftData/FuelStation directly — callers that
//  already have `[FuelStation]` map into `SavedStationSnapshot` at the call site (see
//  StationsView/CalculatorView), keeping this file free of persistence-layer coupling and
//  fully independent of Garage/FuelLog data.
//

import CoreLocation
import Foundation
import UIKit
import UserNotifications

@MainActor
@Observable
final class AutomaticPumpDetectionService: NSObject {

    // MARK: - UI-facing status

    enum Status {
        case disabled
        case locationNotDetermined
        case whenInUseOnly
        case locationDenied
        case reducedAccuracy
        case notificationsDenied
        case backgroundActive
    }

    // MARK: - Tunable, named constants (no scattered literals)

    /// Coarse "you're near a known station" wake-up radius (Stage A). Deliberately much
    /// larger than PumpProximity's ~30 m entry radius — real-world region-monitoring
    /// boundary-crossing detection is commonly off by 100+ meters, so a small geofence
    /// would miss delivery entirely. Stage B's precise confirmation — not this radius — is
    /// what actually gates a notification.
    static let coarseWakeRadiusMeters: CLLocationDistance = 150

    /// Rebuild the monitored set only after the user has moved at least this far since the
    /// last refresh — avoids rebuilding on every minor GPS update.
    static let refreshMovementThresholdMeters: CLLocationDistance = 500

    /// Stage B, in the background, gets only a region-triggered wake to react to — there's no
    /// periodic foreground-style refresh loop to fall back on if the first fix is poor, and
    /// OS-granted background execution time after a region event is short. A single unbounded
    /// location request risked either never returning before the OS suspended the process, or
    /// returning exactly once with a canopy-degraded fix and never trying again — see the
    /// branch report. Bounded instead: up to this many attempts, each capped at
    /// `backgroundConfirmationAttemptTimeout`, only continuing past a rejection when
    /// `ArrivalConfirmation.isRetryable` says a fresh fix could plausibly help.
    static let maximumBackgroundConfirmationAttempts = 2

    /// Per-attempt bound for the retry above. `maximumBackgroundConfirmationAttempts *
    /// backgroundConfirmationAttemptTimeout` (8s) comfortably fits within the execution window
    /// Core Location grants after a region event, per Apple's documented background behavior.
    static let backgroundConfirmationAttemptTimeout: TimeInterval = 4

    private static let notificationTitle = "You're at an E85 station"
    private static let notificationTypeKey = "type"
    private static let notificationTypeValue = "automaticPumpDetection"
    private static let notificationStationIDKey = "stationRecordID"

    // MARK: - Public, observable state (drives Settings UI)

    private(set) var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: AppPreferenceKey.automaticPumpDetectionEnabled) }
    }
    private(set) var monitoredStationCount = 0
    private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    /// Set when a notification tap (or, in principle, any other resolved arrival) should
    /// open Pump Mode for a specific station. CalculatorView observes this and clears it
    /// once handled — the one piece of cross-tab "pending navigation" state this feature
    /// needs; everything else reuses CalculatorView's existing sheet-presentation flow.
    var pendingDetectedStation: MonitoredStationRecord?
    /// Plain-language reason the feature isn't fully active, for Settings UI to display.
    private(set) var lastEnableFailureReason: String?
    /// Single "what happened last" snapshot of the background arrival pipeline — region
    /// events, Stage B outcomes, notification scheduling — for PumpDetectionDiagnosticsView.
    /// Never a history; always overwritten. See `recordBackgroundDiagnostic(...)`.
    private(set) var lastBackgroundDiagnostic: BackgroundDetectionDiagnosticSnapshot?

    /// Read-only mirror of CalculatorView's live foreground state, published purely so
    /// Stations' hidden diagnostics sheet (a different view/tab) can observe it — see
    /// PumpDetectionDiagnosticsView. CalculatorView remains the sole owner of the real
    /// decision logic; these properties are written by it (via the two methods in the
    /// "Foreground diagnostics mirror" section below) and never read by any pump-detection
    /// or prompt-suppression code path, so they can never influence behavior.
    private(set) var isForegroundRefreshActive = false
    private(set) var foregroundHasNearbyStation = false
    private(set) var foregroundHasPromptedForCurrentVisit = false

    var status: Status {
        guard isEnabled else { return .disabled }
        guard let locationManager else { return .locationNotDetermined }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            return .locationNotDetermined
        case .denied, .restricted:
            return .locationDenied
        case .authorizedWhenInUse:
            return .whenInUseOnly
        case .authorizedAlways:
            if notificationAuthorizationStatus == .denied {
                return .notificationsDenied
            }
            if locationManager.isPreciseLocationEnabled == false {
                return .reducedAccuracy
            }
            return .backgroundActive
        @unknown default:
            return .locationNotDetermined
        }
    }

    // MARK: - Private state

    private weak var locationManager: StationLocationManager?
    private var monitoredStations: [MonitoredStationRecord] = []
    private var cooldownState: [String: ArrivalCooldownState] = [:]
    private var isConfirmingArrival = false

    override init() {
        isEnabled = UserDefaults.standard.bool(forKey: AppPreferenceKey.automaticPumpDetectionEnabled)
        super.init()
        monitoredStations = Self.loadMonitoredStations()
        cooldownState = Self.loadCooldownState()
        monitoredStationCount = monitoredStations.count
        lastBackgroundDiagnostic = Self.loadLastBackgroundDiagnostic()
    }

    // MARK: - Attachment (called once from EightyFiveBlendsApp)

    /// Wires this service to the app's single authoritative location manager and resumes
    /// monitoring if the feature was already enabled from a previous launch. Safe to call
    /// before authorization is known.
    func attach(to locationManager: StationLocationManager) {
        self.locationManager = locationManager
        locationManager.onRegionEvent = { [weak self] identifier, kind in
            Task { @MainActor in
                self?.handleRegionEvent(identifier: identifier, kind: kind)
            }
        }
        UNUserNotificationCenter.current().delegate = self

        Task {
            notificationAuthorizationStatus = await Self.currentNotificationAuthorizationStatus()
        }

        if isEnabled {
            debugLog("Resuming — feature was enabled on a previous launch.")
            resumeMonitoringAfterRelaunch()
        }
    }

    // MARK: - Enable / disable (staged authorization)

    /// Staged enable flow, run only when the user explicitly turns the feature on:
    /// 1. (In-app explanation is the always-visible Settings card copy — see StationsView.)
    /// 2. Request When In Use if `.notDetermined`.
    /// 3. If When In Use is granted, request Always.
    /// 4. Request notification permission.
    /// 5. Refresh the monitored set if Always was granted; otherwise the feature stays
    ///    "enabled" but inert in the background — foreground detection keeps working
    ///    regardless, via the pre-existing CalculatorView path, which needs none of this.
    func enable() async {
        isEnabled = true
        lastEnableFailureReason = nil
        guard let locationManager else { return }

        let whenInUseStatus = await awaitAuthorizationDetermined()
        guard whenInUseStatus == .authorizedWhenInUse || whenInUseStatus == .authorizedAlways else {
            lastEnableFailureReason = "Location access is needed for Automatic Pump Detection. Enable it in Settings."
            debugLog("Enable blocked — location access not granted (\(whenInUseStatus.rawValue)).")
            return
        }

        if whenInUseStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
            _ = await awaitAuthorizationDetermined()
        }

        let notificationGranted = await requestNotificationAuthorizationIfNeeded()
        if notificationGranted == false {
            lastEnableFailureReason = "Notifications are turned off, so background arrival alerts can't be delivered. Foreground detection still works — enable notifications in Settings for background alerts."
            debugLog("Notifications not granted — background alerts unavailable; foreground path unaffected.")
        }

        if locationManager.isAuthorizedAlways {
            debugLog("Always authorization granted — refreshing monitored set.")
        } else {
            lastEnableFailureReason = lastEnableFailureReason ?? "Background detection needs Always location access. You can grant it later in Settings — foreground detection works with When In Use."
            debugLog("Always not granted — background monitoring inactive; foreground detection continues via the existing CalculatorView path.")
        }
    }

    /// Stops and removes every station monitor this feature owns, clears pending
    /// detection work, and removes only this feature's persisted metadata. Never touches
    /// the saved-station database, foreground nearby-station search, or any other feature.
    func disable() {
        isEnabled = false
        lastEnableFailureReason = nil
        pendingDetectedStation = nil
        locationManager?.stopMonitoringAllRegions()
        monitoredStations = []
        monitoredStationCount = 0
        cooldownState = [:]
        lastBackgroundDiagnostic = nil
        persistMonitoredStations()
        persistCooldownState()
        UserDefaults.standard.removeObject(forKey: AppPreferenceKey.automaticPumpDetectionLastRefreshLatitude)
        UserDefaults.standard.removeObject(forKey: AppPreferenceKey.automaticPumpDetectionLastRefreshLongitude)
        UserDefaults.standard.removeObject(forKey: AppPreferenceKey.automaticPumpDetectionLastRefreshAt)
        UserDefaults.standard.removeObject(forKey: AppPreferenceKey.automaticPumpDetectionLastBackgroundDiagnostic)
        debugLog("Disabled — all station monitors removed, persisted metadata cleared.")
    }

    // MARK: - Foreground diagnostics mirror (read-only signal for Stations' diagnostics sheet)
    //
    // Both methods below are called only from CalculatorView (see runPeriodicPumpLocationRefresh()
    // and the locationManager.latestCoordinate/onAppear wiring) and only ever WRITE these
    // mirror properties — nothing in this file, or in CalculatorView's own actual
    // detection/suppression logic, ever reads them back. That one-way flow is what keeps this
    // diagnostics-only: it cannot change when a notification fires, when the in-app prompt
    // fires, or how suppression behaves.

    /// Whether CalculatorView's periodic foreground location-refresh loop is currently
    /// running (i.e. the app is foregrounded and Calculator is in the view hierarchy).
    func updateForegroundRefreshActive(_ isActive: Bool) {
        isForegroundRefreshActive = isActive
    }

    /// Snapshot of CalculatorView's live "At the Pump?" visit state after a
    /// refreshPumpModeStation()/evaluateAutoPromptPumpMode() pass.
    func updateForegroundVisitState(hasNearbyStation: Bool, hasPromptedForCurrentVisit: Bool) {
        foregroundHasNearbyStation = hasNearbyStation
        foregroundHasPromptedForCurrentVisit = hasPromptedForCurrentVisit
    }

    // MARK: - Monitor refresh

    /// Rebuilds the monitored station set from the caller's saved stations, subject to the
    /// enabled/authorization/movement gates below. Safe to call liberally (e.g. from every
    /// location update) — internally a no-op unless a real refresh is warranted. `reason`
    /// is diagnostic-only, for debug logging.
    func refreshMonitoredStations(
        savedStations: [SavedStationSnapshot],
        userLatitude: Double? = nil,
        userLongitude: Double? = nil,
        force: Bool = false,
        reason: String
    ) {
        guard isEnabled else { return }
        guard let locationManager, locationManager.isAuthorizedAlways else {
            debugLog("Refresh skipped (\(reason)) — Always authorization not granted.")
            return
        }

        let latitude = userLatitude ?? locationManager.latestCoordinate?.latitude
        let longitude = userLongitude ?? locationManager.latestCoordinate?.longitude
        guard let latitude, let longitude else {
            debugLog("Refresh skipped (\(reason)) — no current location available yet.")
            return
        }

        if force == false, shouldSkipRefresh(userLatitude: latitude, userLongitude: longitude) {
            return
        }

        let candidates = savedStations.compactMap { station -> MonitoredStationCandidate? in
            guard let lat = station.latitude, let lon = station.longitude else { return nil }
            let id = AutomaticPumpDetectionStationKey.make(name: station.name, latitude: lat, longitude: lon)
            return MonitoredStationCandidate(id: id, name: station.name, latitude: lat, longitude: lon, address: station.address)
        }

        let selected = MonitoredStationSelector.select(from: candidates, userLatitude: latitude, userLongitude: longitude)
        applyMonitoredSet(selected, reason: reason)

        UserDefaults.standard.set(latitude, forKey: AppPreferenceKey.automaticPumpDetectionLastRefreshLatitude)
        UserDefaults.standard.set(longitude, forKey: AppPreferenceKey.automaticPumpDetectionLastRefreshLongitude)
        UserDefaults.standard.set(Date(), forKey: AppPreferenceKey.automaticPumpDetectionLastRefreshAt)
    }

    private func shouldSkipRefresh(userLatitude: Double, userLongitude: Double) -> Bool {
        guard monitoredStations.isEmpty == false else { return false }
        guard
            let lastLat = UserDefaults.standard.object(forKey: AppPreferenceKey.automaticPumpDetectionLastRefreshLatitude) as? Double,
            let lastLon = UserDefaults.standard.object(forKey: AppPreferenceKey.automaticPumpDetectionLastRefreshLongitude) as? Double
        else {
            return false
        }
        let last = CLLocation(latitude: lastLat, longitude: lastLon)
        let current = CLLocation(latitude: userLatitude, longitude: userLongitude)
        return last.distance(from: current) < Self.refreshMovementThresholdMeters
    }

    private func applyMonitoredSet(_ selected: [MonitoredStationCandidate], reason: String) {
        guard let locationManager else { return }

        let newRecords = selected.map {
            MonitoredStationRecord(id: $0.id, name: $0.name, latitude: $0.latitude, longitude: $0.longitude, address: $0.address)
        }
        let newIDs = Set(newRecords.map(\.id))
        let oldIDs = Set(monitoredStations.map(\.id))

        for staleID in oldIDs.subtracting(newIDs) {
            locationManager.stopMonitoringRegion(identifier: staleID)
            cooldownState.removeValue(forKey: staleID)
        }

        for record in newRecords where oldIDs.contains(record.id) == false {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: record.latitude, longitude: record.longitude),
                radius: Self.coarseWakeRadiusMeters,
                identifier: record.id
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            locationManager.startMonitoringRegion(region)
            // Reconcile immediately: if the user is already standing inside this region right
            // now (e.g. enabling the feature, or adding this station, while at the station),
            // no future didEnterRegion crossing will ever occur for this visit — see
            // requestState(for:)'s doc comment.
            locationManager.requestState(for: record.id)
        }

        monitoredStations = newRecords
        monitoredStationCount = newRecords.count
        persistMonitoredStations()
        persistCooldownState()
        debugLog("Monitor set refreshed (\(reason)) — now monitoring \(newRecords.count) station(s).")
    }

    private func resumeMonitoringAfterRelaunch() {
        // Region monitoring itself is restored automatically by the OS (monitored regions
        // persist across relaunch) — this just re-syncs our own bookkeeping, or tears
        // everything down safely if authorization was revoked while the app was gone.
        guard let locationManager else { return }
        guard locationManager.isAuthorizedAlways else {
            debugLog("Resumed with Always no longer granted — disabling background monitoring.")
            locationManager.stopMonitoringAllRegions()
            return
        }
        monitoredStationCount = monitoredStations.count
        debugLog("Resumed with \(monitoredStations.count) previously monitored station(s) intact.")

        // Reconcile every previously monitored region on relaunch — including a cold launch
        // triggered by something other than a region event — so a user who happens to already
        // be inside a monitored region when the process (re)starts isn't left undetected until
        // an unrelated future exit+reentry. Region monitoring itself is restored by the OS
        // automatically; this only asks Core Location for each region's CURRENT state.
        for record in monitoredStations {
            locationManager.requestState(for: record.id)
        }
    }

    // MARK: - Stage A -> Stage B

    private func handleRegionEvent(identifier: String, kind: StationLocationManager.RegionEventKind) {
        guard isEnabled else { return }

        switch kind {
        case .exited:
            if var state = cooldownState[identifier] {
                state.hasExitedSinceNotification = true
                cooldownState[identifier] = state
                persistCooldownState()
            }
            recordBackgroundDiagnostic(
                kind: .regionExited,
                stationName: monitoredStations.first(where: { $0.id == identifier })?.name
            )
            debugLog("Exited monitored area for station id \(identifier).")
            return
        case .monitoringFailed:
            // Previously DEBUG-log only, so a production build had zero trace of a monitoring
            // failure ever happening — see the branch report. Recorded here so Diagnostics can
            // show it even in Release/TestFlight.
            recordBackgroundDiagnostic(
                kind: .regionMonitoringFailed,
                stationName: monitoredStations.first(where: { $0.id == identifier })?.name
            )
            debugLog("Region monitoring failed for station id \(identifier).")
            return
        case .entered, .alreadyInside:
            break
        }

        guard let record = monitoredStations.first(where: { $0.id == identifier }) else {
            debugLog("Candidate entry for unknown station id \(identifier) — ignoring.")
            return
        }

        recordBackgroundDiagnostic(
            kind: kind == .alreadyInside ? .regionAlreadyInside : .regionEntered,
            stationName: record.name
        )
        debugLog(kind == .alreadyInside
            ? "Reconciled already-inside for station: \(record.name)."
            : "Candidate station entered: \(record.name).")

        // Foreground arrivals are already handled by CalculatorView's own existing
        // refreshPumpModeStation/evaluateAutoPromptPumpMode path — skip here so the two
        // paths can never double-prompt the same arrival.
        guard UIApplication.shared.applicationState != .active else {
            debugLog("App is foreground-active — deferring to the existing in-app prompt.")
            return
        }

        Task {
            await confirmArrival(for: record)
        }
    }

    /// Stage B, bounded: up to `maximumBackgroundConfirmationAttempts` fresh-location attempts,
    /// each capped at `backgroundConfirmationAttemptTimeout`. Retries only when the rejection
    /// reason is one `ArrivalConfirmation.isRetryable` says a subsequent fix could plausibly
    /// resolve (poor accuracy/borderline distance) — never for a stale/invalid/disabled
    /// rejection, which retrying immediately cannot fix. Stops at the first `.confirmed`.
    private func confirmArrival(for record: MonitoredStationRecord) async {
        guard isConfirmingArrival == false else {
            debugLog("Confirmation already in progress — ignoring re-entry for \(record.name).")
            return
        }
        isConfirmingArrival = true
        defer { isConfirmingArrival = false }

        guard let locationManager else { return }

        for attempt in 1...Self.maximumBackgroundConfirmationAttempts {
            guard let fix = await locationManager.requestFreshLocationAsync(timeout: Self.backgroundConfirmationAttemptTimeout) else {
                debugLog("Precise confirmation attempt \(attempt) for \(record.name) — no fresh fix available.")
                recordBackgroundDiagnostic(kind: .stageBNoFix, stationName: record.name, detail: "attempt \(attempt) of \(Self.maximumBackgroundConfirmationAttempts)")
                return
            }

            let outcome = ArrivalConfirmation.evaluate(
                featureEnabled: isEnabled,
                stationLatitude: record.latitude,
                stationLongitude: record.longitude,
                freshLatitude: fix.coordinate.latitude,
                freshLongitude: fix.coordinate.longitude,
                horizontalAccuracyMeters: fix.horizontalAccuracyMeters,
                locationTimestamp: fix.timestamp,
                now: Date()
            )

            switch outcome {
            case .confirmed(let distance):
                debugLog("Precise confirmation accepted for \(record.name) (\(Int(distance)) m) on attempt \(attempt).")
                recordBackgroundDiagnostic(kind: .stageBConfirmed, stationName: record.name, detail: "\(Int(distance))m, attempt \(attempt)")
                await handleConfirmedArrival(record)
                return
            case .rejected(let reason):
                debugLog("Precise confirmation rejected for \(record.name) on attempt \(attempt): \(reason.rawValue).")
                let hasMoreAttempts = attempt < Self.maximumBackgroundConfirmationAttempts
                guard ArrivalConfirmation.isRetryable(reason), hasMoreAttempts else {
                    recordBackgroundDiagnostic(kind: .stageBRejected, stationName: record.name, detail: "\(reason.rawValue), attempt \(attempt)")
                    return
                }
                // Retryable, and attempts remain — loop and request another fresh fix.
            }
        }
    }

    private func handleConfirmedArrival(_ record: MonitoredStationRecord) async {
        let now = Date()
        guard ArrivalCooldownPolicy.shouldNotify(existingState: cooldownState[record.id], now: now) else {
            debugLog("Notification suppressed for \(record.name) — within cooldown.")
            recordBackgroundDiagnostic(kind: .notificationSuppressedCooldown, stationName: record.name)
            return
        }

        guard UIApplication.shared.applicationState != .active else {
            // Confirmed while foregrounded mid-confirmation — the in-app path now owns
            // this, no notification needed.
            recordBackgroundDiagnostic(kind: .notificationSuppressedForeground, stationName: record.name)
            return
        }

        await scheduleArrivalNotification(for: record)

        cooldownState[record.id] = ArrivalCooldownState(stationID: record.id, lastNotifiedAt: now, hasExitedSinceNotification: false)
        persistCooldownState()
    }

    // MARK: - Notifications

    private func requestNotificationAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationAuthorizationStatus = settings.authorizationStatus
            return true
        case .denied:
            notificationAuthorizationStatus = .denied
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                notificationAuthorizationStatus = await Self.currentNotificationAuthorizationStatus()
                return granted
            } catch {
                debugLog("Notification authorization request failed: \(error)")
                return false
            }
        @unknown default:
            return false
        }
    }

    private static func currentNotificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func scheduleArrivalNotification(for record: MonitoredStationRecord) async {
        let content = UNMutableNotificationContent()
        content.title = Self.notificationTitle
        content.body = "Tap to open At The Pump for \(record.name)."
        content.sound = .default
        content.userInfo = [
            Self.notificationTypeKey: Self.notificationTypeValue,
            Self.notificationStationIDKey: record.id
        ]

        let request = UNNotificationRequest(identifier: record.id, content: content, trigger: nil)

        do {
            try await UNUserNotificationCenter.current().add(request)
            debugLog("Notification scheduled for \(record.name).")
            recordBackgroundDiagnostic(kind: .notificationScheduled, stationName: record.name)
        } catch {
            debugLog("Notification scheduling failed for \(record.name): \(error)")
            recordBackgroundDiagnostic(kind: .notificationSchedulingFailed, stationName: record.name, detail: error.localizedDescription)
        }
    }

    private func handleNotificationOpened(stationID: String) {
        guard let record = monitoredStations.first(where: { $0.id == stationID }) else {
            debugLog("Notification opened for unknown station id \(stationID) — metadata no longer available.")
            return
        }
        debugLog("Notification opened for \(record.name).")
        pendingDetectedStation = record
    }

    // MARK: - Authorization await helper

    /// Awaits the next authorization-status change (or returns immediately if already
    /// determined), with a timeout fallback so a dismissed system prompt can never hang
    /// the enable flow indefinitely.
    private func awaitAuthorizationDetermined(timeout: TimeInterval = 12) async -> CLAuthorizationStatus {
        guard let locationManager else { return .notDetermined }
        if locationManager.authorizationStatus != .notDetermined {
            return locationManager.authorizationStatus
        }

        return await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            withObservationTracking {
                _ = locationManager.authorizationStatus
            } onChange: {
                Task { @MainActor [weak self] in
                    box.resume(with: self?.locationManager?.authorizationStatus ?? .notDetermined)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run {
                    box.resume(with: locationManager.authorizationStatus)
                }
            }
        }
    }

    /// Guards a `CheckedContinuation` against being resumed more than once — both the
    /// observation callback and the timeout fallback above race to resume it.
    private final class ContinuationBox {
        private var continuation: CheckedContinuation<CLAuthorizationStatus, Never>?
        init(_ continuation: CheckedContinuation<CLAuthorizationStatus, Never>) {
            self.continuation = continuation
        }
        func resume(with status: CLAuthorizationStatus) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: status)
        }
    }

    // MARK: - Persistence

    private static func loadMonitoredStations() -> [MonitoredStationRecord] {
        guard let data = UserDefaults.standard.data(forKey: AppPreferenceKey.automaticPumpDetectionMonitoredStations) else { return [] }
        return (try? JSONDecoder().decode([MonitoredStationRecord].self, from: data)) ?? []
    }

    private func persistMonitoredStations() {
        guard let data = try? JSONEncoder().encode(monitoredStations) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferenceKey.automaticPumpDetectionMonitoredStations)
    }

    private static func loadCooldownState() -> [String: ArrivalCooldownState] {
        guard let data = UserDefaults.standard.data(forKey: AppPreferenceKey.automaticPumpDetectionCooldownState) else { return [:] }
        return (try? JSONDecoder().decode([String: ArrivalCooldownState].self, from: data)) ?? [:]
    }

    private func persistCooldownState() {
        guard let data = try? JSONEncoder().encode(cooldownState) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferenceKey.automaticPumpDetectionCooldownState)
    }

    private static func loadLastBackgroundDiagnostic() -> BackgroundDetectionDiagnosticSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: AppPreferenceKey.automaticPumpDetectionLastBackgroundDiagnostic) else { return nil }
        return try? JSONDecoder().decode(BackgroundDetectionDiagnosticSnapshot.self, from: data)
    }

    private func persistLastBackgroundDiagnostic() {
        guard let lastBackgroundDiagnostic, let data = try? JSONEncoder().encode(lastBackgroundDiagnostic) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferenceKey.automaticPumpDetectionLastBackgroundDiagnostic)
    }

    // MARK: - Diagnostics

    /// Production-accessible (unlike `debugLog` below): overwrites the single "last event"
    /// snapshot PumpDetectionDiagnosticsView reads, so a real-device test that produced no
    /// notification can be traced to exactly one of: no region event, a Stage B rejection/no
    /// fix, a suppressed notification, or a scheduling failure — see the branch report. Never
    /// passed a coordinate; `detail` is limited to reasons, error descriptions, and distances.
    private func recordBackgroundDiagnostic(
        kind: BackgroundDetectionDiagnosticSnapshot.EventKind,
        stationName: String?,
        detail: String? = nil
    ) {
        lastBackgroundDiagnostic = BackgroundDetectionDiagnosticSnapshot(
            kind: kind,
            stationName: stationName,
            detail: detail,
            timestamp: Date()
        )
        persistLastBackgroundDiagnostic()
    }

    /// Debug-only, never compiled into release builds. Logs station names/distances/
    /// counts for troubleshooting — deliberately never logs raw coordinates or any
    /// persistent location history.
    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[85Blends][pumpDetection] \(message())")
        #endif
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AutomaticPumpDetectionService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Scheduling itself is already suppressed while foreground-active (see
        // handleConfirmedArrival) — if one somehow still arrives while visible, show it
        // plainly rather than silently dropping it.
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard
            userInfo[Self.notificationTypeKey] as? String == Self.notificationTypeValue,
            let stationID = userInfo[Self.notificationStationIDKey] as? String
        else {
            completionHandler()
            return
        }

        Task { @MainActor [weak self] in
            self?.handleNotificationOpened(stationID: stationID)
            completionHandler()
        }
    }
}

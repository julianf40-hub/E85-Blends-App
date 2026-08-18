//
//  CalculatorView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData
import CoreLocation

struct CalculatorView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppPreferenceKey.defaultTargetBlend) private var preferredDefaultTargetBlend = BlendPreferenceOption.e30.rawValue
    @Query(filter: #Predicate<VehicleProfile> { $0.isActive == true })
    private var activeVehicles: [VehicleProfile]
    @Query(sort: \FuelLogEntry.date, order: .reverse)
    private var fuelLogEntries: [FuelLogEntry]
    @Query(sort: \FuelStation.updatedAt, order: .reverse)
    private var savedStations: [FuelStation]

    @State private var selectedBlend = "E50"
    @State private var isGuideExpanded = false
    @State private var isAdvancedExpanded = false
    @State private var isInstructionsExpanded = false
    @State private var tankSize = "15.5"
    @State private var currentLevel = "25"
    @State private var currentFuelEthanol = "20"
    @State private var targetFuelEthanol = "50"
    @State private var e85Ethanol = "82"
    @State private var e85Octane = "105"
    @State private var gasEthanol = "10"
    @State private var gasOctane = "91"
    @State private var loadedDefaultsKey = ""
    // Pump/Gas Ethanol app-level preferences are loaded once per view lifetime, independent of
    // the active-vehicle-triggered defaults refresh above — see loadRememberedFuelPreferencesIfNeeded().
    @State private var hasLoadedRememberedFuelPreferences = false
    @State private var calculatorFuelLogDraft: FuelLogDraft?
    @State private var isShowingCompareFuelCost = false
    @Environment(StationLocationManager.self) private var locationManager
    @Environment(AutomaticPumpDetectionService.self) private var pumpDetectionService
    @Environment(RecentLiveStationCache.self) private var recentLiveStationCache
    @Environment(\.scenePhase) private var scenePhase
    @State private var pumpModeStation: FuelStation?
    @State private var isShowingPumpMode = false
    // Visit-based, not permanent: reset whenever pumpModeStation clears (see
    // clearPumpModeStation()) so leaving the station's exit radius and returning later — even
    // within the same app session — makes the prompt eligible again. Renamed from
    // didAutoPromptPumpMode, which never reset and so could only ever prompt once per launch.
    @State private var hasPromptedForCurrentPumpVisit = false
    @State private var autoPromptStation: FuelStation?
    /// Manually opened Pump Mode's station-context resolution — separate from
    /// `pumpModeStation`/PumpProximity, which remain the untouched source for the
    /// automatic prompt (`evaluateAutoPromptPumpMode`). See `openPumpMode()`.
    @State private var pumpContextState: PumpModeStationContextState = .noMatch
    /// Incremented on every Pump Mode open; an in-flight resolution checks this before
    /// applying its result so a stale async result from a closed/reopened session can
    /// never mutate a later, unrelated session (Phase 8).
    @State private var pumpModeSessionToken = 0

    // No vehicle selected at all — unaffected by the 2.3.0 Garage simplification's "don't
    // silently pretend a SELECTED vehicle has a 16-gallon tank" rule (audit item 4); this is
    // just the generic starting point shown with no vehicle context, freely editable.
    private var fallbackDefaults: CalculatorDefaults {
        CalculatorDefaults(
            nickname: "No Vehicle Selected",
            tankSizeGallons: 16,
            targetEthanolPercent: PreferredTargetResolution.resolve(vehicle: nil, appPreferredTarget: preferredTargetBlendValue),
            currentEthanolPercent: CurrentEthanolResolution.resolve(latestLoggedBlendPercent: nil),
            gasOctane: 91
        )
    }

    // Vehicle-scoped calculator defaults — tank size, Preferred Ethanol Target, Current Ethanol
    // (from Fuel Log history), and required octane. Pump Ethanol and Gas Ethanol are NOT part of
    // this: they are app-level "remembered" preferences now, loaded once independently of the
    // active vehicle — see loadRememberedFuelPreferencesIfNeeded().
    private func calculatorDefaults(for vehicle: VehicleProfile) -> CalculatorDefaults {
        CalculatorDefaults(
            nickname: vehicle.nickname.isEmpty ? "No Vehicle Selected" : vehicle.nickname,
            // Raw value, NOT `> 0 ? … : 16` — a selected vehicle with no known tank capacity
            // must never be silently treated as 16 gallons (audit item 4). applyDefaultsIfNeeded
            // renders 0 as a blank field, and BlendCalculator's existing "Enter a tank size
            // greater than 0 gallons" guard clearly communicates what's missing.
            tankSizeGallons: vehicle.tankSizeGallons,
            targetEthanolPercent: PreferredTargetResolution.resolve(vehicle: vehicle, appPreferredTarget: preferredTargetBlendValue),
            currentEthanolPercent: CurrentEthanolResolution.resolve(latestLoggedBlendPercent: lastLoggedBlendForActiveVehicle),
            gasOctane: vehicle.requiredOctane
        )
    }

    private var activeVehicle: VehicleProfile? {
        activeVehicles.first
    }

    private var pumpModeActiveVehicle: VehicleProfile? {
        activeVehicles.first(where: { $0.isActive }) ?? activeVehicles.first
    }

    /// Final blend from the newest fuel log for the active vehicle — read-only smart
    /// default for the pump sheet's "current blend". Entries are already sorted
    /// newest-first by the query.
    private var lastLoggedBlendForActiveVehicle: Double? {
        guard let vehicle = pumpModeActiveVehicle else {
            return nil
        }

        return fuelLogEntries
            .first(where: { $0.vehicleName == vehicle.nickname && $0.finalBlendPercent > 0 })?
            .finalBlendPercent
    }

    // Pump/Gas Ethanol are deliberately NOT part of this key — they're app-level preferences
    // now (loaded once, independent of the active vehicle) rather than vehicle fields, so
    // switching vehicles must never reset them. defaultTargetEthanolPercent is still included
    // because a legacy-semantics vehicle's effective target comes directly from it.
    private var activeVehicleKey: String {
        guard let activeVehicle else {
            return "no-vehicle"
        }

        return [
            activeVehicle.nickname,
            String(activeVehicle.createdAt.timeIntervalSinceReferenceDate),
            String(activeVehicle.updatedAt.timeIntervalSinceReferenceDate),
            String(activeVehicle.tankSizeGallons),
            String(activeVehicle.calculatorPreferenceSemanticsVersion),
            String(activeVehicle.preferredEthanolTargetPercent ?? -1),
            String(activeVehicle.defaultTargetEthanolPercent),
            String(activeVehicle.requiredOctane),
            String(lastLoggedBlendForActiveVehicle ?? -1),
        ].joined(separator: "|")
    }

    // True when the active vehicle's resolved Preferred Ethanol Target actually depends on the
    // app-level preference (no vehicle at all, or a new-semantics vehicle with no target set) —
    // used to decide whether a change to that app-level preference needs to re-sync Calculator.
    // A legacy-semantics vehicle's target never depends on it (PreferredTargetResolution always
    // honors defaultTargetEthanolPercent for those), so it must NOT trigger a refresh there.
    private var activeVehicleTargetDependsOnAppPreference: Bool {
        guard let activeVehicle else { return true }
        return activeVehicle.calculatorPreferenceSemanticsVersion >= VehiclePreferenceSemantics.current
            && activeVehicle.preferredEthanolTargetPercent == nil
    }

    private var headerNickname: String {
        guard let activeVehicle, activeVehicle.nickname.isEmpty == false else {
            return fallbackDefaults.nickname
        }

        return activeVehicle.nickname
    }

    private var showsVehicleHint: Bool {
        activeVehicle == nil
    }

    private var calculation: BlendCalculator.Result {
        BlendCalculator.calculate(
            input: .init(
                tankSizeGallons: doubleValue(from: tankSize),
                currentFuelLevelPercent: doubleValue(from: currentLevel),
                currentFuelEthanolPercent: doubleValue(from: currentFuelEthanol),
                targetEthanolPercent: doubleValue(from: targetFuelEthanol),
                e85EthanolPercent: doubleValue(from: e85Ethanol),
                gasEthanolPercent: doubleValue(from: gasEthanol),
                e85Octane: doubleValue(from: e85Octane),
                gasOctane: doubleValue(from: gasOctane)
            )
        )
    }

    private var preferredTargetBlendValue: Double {
        AppPreferredTargetBlend.percent(fromRawValue: preferredDefaultTargetBlend)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    compareFuelCostCard

                    if showsVehicleHint {
                        vehicleHintCard
                    }

                    TargetBlendSelector(
                        options: ["E20", "E30", "E40", "E50", "E60", "E85"],
                        selectedBlend: $selectedBlend,
                        targetFuelEthanol: $targetFuelEthanol
                    )

                    ExpandableSection(
                        title: "Blend Guide",
                        subtitle: "Range vs Power",
                        isExpanded: $isGuideExpanded
                    ) {
                        BlendGuideSection(
                            selectedBlend: $selectedBlend,
                            targetFuelEthanol: $targetFuelEthanol
                        )
                    }

                    TankInputSection(
                        tankSize: $tankSize,
                        currentLevel: $currentLevel,
                        currentFuelEthanol: $currentFuelEthanol,
                        targetFuelEthanol: $targetFuelEthanol
                    )

                    ExpandableSection(
                        title: "Show Advanced Settings",
                        subtitle: nil,
                        isExpanded: $isAdvancedExpanded
                    ) {
                        AdvancedSettingsSection(
                            e85Ethanol: $e85Ethanol,
                            e85Octane: $e85Octane,
                            gasEthanol: $gasEthanol,
                            gasOctane: $gasOctane
                        )
                    }

                    if let warningMessage = calculation.warningMessage {
                        WarningCard(title: "Blend Warning", message: warningMessage)
                    }

                    if let guidanceMessage = calculation.guidanceMessage {
                        InfoCard(title: "Pump E85 Only", message: guidanceMessage)
                    }

                    BlendResultCard(result: calculation)

                    ExpandableSection(
                        title: "Pump Instructions",
                        subtitle: nil,
                        isExpanded: $isInstructionsExpanded
                    ) {
                        PumpInstructionsSection(result: calculation)
                    }

                    PrimaryButton(title: "+ Log This Fill-Up") {
                        calculatorFuelLogDraft = FuelLogStore.prefillDraft(from: calculation, vehicle: activeVehicle)
                    }
                }
                .padding(16)
            }
            .dismissKeyboardOnTap()
            .background(AppTheme.Colors.charcoal)
            .toolbar(.hidden, for: .navigationBar)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .keyboardDoneToolbar()
        .onAppear {
            applyDefaultsIfNeeded(for: activeVehicleKey)
            loadRememberedFuelPreferencesIfNeeded()
            requestPumpModeLocationIfNeeded()
            resolvePendingDetectedStationIfNeeded()
            publishForegroundVisitDiagnostics()
        }
        // StationLocationManager's requestUserLocation() is a ONE-SHOT fix, not continuous
        // updates (this app never calls startUpdatingLocation()) — without this loop, the
        // foreground "At the Pump?" path gets exactly one chance to catch a good GPS fix per
        // tab appearance. Re-requesting periodically while the tab is visible and the app is
        // foregrounded lets a user who is already standing at the pump (or whose first fix was
        // a coarse one) still get caught by refreshPumpModeStation()/evaluateAutoPromptPumpMode()
        // on a later fix. .task(id: scenePhase) restarts (and SwiftUI auto-cancels the previous
        // run of) this loop whenever scenePhase changes, so it's inert the instant the app
        // backgrounds and never fires while this view isn't on screen.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await runPeriodicPumpLocationRefresh()
        }
        .onChange(of: activeVehicleKey) { _, newValue in
            applyDefaultsIfNeeded(for: newValue)
        }
        .onChange(of: preferredDefaultTargetBlend) { _, _ in
            if activeVehicleTargetDependsOnAppPreference {
                loadedDefaultsKey = ""
                applyDefaultsIfNeeded(for: activeVehicleKey)
            }
        }
        .onChange(of: e85Ethanol) { _, newValue in
            rememberPumpEthanolIfValid(newValue)
        }
        .onChange(of: gasEthanol) { _, newValue in
            rememberGasEthanolIfValid(newValue)
        }
        .onChange(of: locationManager.authorizationStatus) { _, newValue in
            handleAuthorizationChange(newValue)
            refreshPumpDetectionMonitoredStations(reason: "Location authorization changed")
        }
        .onChange(of: locationManager.latestCoordinate) { _, _ in
            refreshPumpModeStation()
            evaluateAutoPromptPumpMode()
            refreshPumpDetectionMonitoredStations(reason: "Location updated")
            publishForegroundVisitDiagnostics()
        }
        .onChange(of: pumpDetectionService.pendingDetectedStation) { _, _ in
            resolvePendingDetectedStationIfNeeded()
        }
        .onChange(of: savedStations) { _, _ in
            refreshPumpDetectionMonitoredStations(reason: "Saved stations changed")
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Returning to the foreground while Pump Mode is still open is the one case
            // worth a fresh, bounded re-resolution — the cached fix from before
            // backgrounding may now be stale (Phase 8). This never requests permissions,
            // never loops, and is a no-op whenever Pump Mode isn't presented.
            guard newPhase == .active, isShowingPumpMode else { return }
            let sessionToken = pumpModeSessionToken
            debugPumpContextLog("App became active while Pump Mode is open — re-resolving session \(sessionToken).")
            Task { @MainActor in
                await resolvePumpStationContext(sessionToken: sessionToken)
            }
        }
        .sheet(isPresented: calculatorFuelLogSheetBinding) {
            if let calculatorFuelLogDraft {
                AddEditFuelLogView(entry: nil, initialDraft: calculatorFuelLogDraft) { draft in
                    _ = try FuelLogStore.save(
                        draft: draft,
                        editing: nil,
                        entries: fuelLogEntries,
                        activeVehicle: activeVehicle,
                        modelContext: modelContext
                    )
                    self.calculatorFuelLogDraft = nil
                }
            }
        }
        .sheet(isPresented: $isShowingPumpMode) {
            AtThePumpView(
                initialTankSizeGallons: doubleValue(from: tankSize),
                initialCurrentFuelLevelPercent: doubleValue(from: currentLevel),
                initialCurrentFuelEthanolPercent: doubleValue(from: currentFuelEthanol),
                initialTargetEthanolPercent: doubleValue(from: targetFuelEthanol),
                initialE85EthanolPercent: doubleValue(from: e85Ethanol),
                initialGasEthanolPercent: doubleValue(from: gasEthanol),
                initialE85Octane: doubleValue(from: e85Octane),
                initialGasOctane: doubleValue(from: gasOctane),
                activeVehicle: pumpModeActiveVehicle,
                stationContext: pumpContextState,
                locationAccessDenied: locationManager.authorizationDenied,
                lastLoggedBlendPercent: lastLoggedBlendForActiveVehicle,
                selectAmbiguousCandidateAction: { candidate in
                    pumpContextState = .matched(candidate)
                },
                logFillUpAction: { updatedCalculation in
                    openPumpModeFuelLog(with: updatedCalculation)
                },
                closeAction: {
                    // Bump the session token so a still-in-flight resolution from this
                    // session is discarded on arrival rather than silently applying to a
                    // now-closed sheet (Phase 8).
                    pumpModeSessionToken += 1
                    isShowingPumpMode = false
                }
            )
        }
        // CostCalculatorView doesn't self-wrap in a NavigationStack (it's normally pushed from
        // More's own stack), so a NavigationStack + explicit Done button is added here at the
        // sheet call site only — More's existing NavigationLink entry point is untouched.
        .sheet(isPresented: $isShowingCompareFuelCost) {
            NavigationStack {
                CostCalculatorView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                isShowingCompareFuelCost = false
                            }
                        }
                    }
            }
        }
        .alert("At the Pump?", isPresented: autoPromptAlertBinding) {
            Button("Not Now", role: .cancel) {
                autoPromptStation = nil
            }
            Button("Open Pump Mode") {
                pumpModeStation = autoPromptStation
                // The automatic prompt already confirmed this station via PumpProximity's
                // strict gate — trust it directly rather than re-running the manual
                // resolver, so the sheet never regresses to "resolving"/"no match" for a
                // station we're already certain about.
                if let autoPromptStation, let candidate = pumpContextCandidate(from: autoPromptStation) {
                    pumpContextState = .matched(candidate)
                } else {
                    pumpContextState = .noMatch
                }
                autoPromptStation = nil
                pumpModeSessionToken += 1
                isShowingPumpMode = true
            }
        } message: {
            Text("You're near \(autoPromptStation?.name ?? "a saved station"). Open pump mode for one-handed blend guidance?")
        }
    }

    private func doubleValue(from string: String) -> Double {
        Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private var calculatorFuelLogSheetBinding: Binding<Bool> {
        Binding(
            get: { calculatorFuelLogDraft != nil },
            set: { isPresented in
                if isPresented == false {
                    calculatorFuelLogDraft = nil
                }
            }
        )
    }



    private var autoPromptAlertBinding: Binding<Bool> {
        Binding(
            get: { autoPromptStation != nil },
            set: { isPresented in
                if isPresented == false {
                    autoPromptStation = nil
                }
            }
        )
    }

    private func formatted(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }

        return String(format: "%.1f", value)
    }

    private func nearestBlendChip(for value: Double) -> String {
        let options = [20.0, 30.0, 40.0, 50.0, 60.0, 85.0]
        let nearest = options.min { abs($0 - value) < abs($1 - value) } ?? 30
        return "E\(Int(nearest))"
    }

    private func requestPumpModeLocationIfNeeded() {
        guard locationManager.isAuthorizedForUserLocation else {
            return
        }

        locationManager.requestUserLocation()
    }

    /// Backing loop for the `.task(id: scenePhase)` above — requests a fresh one-shot fix
    /// every ~20s while active. requestPumpModeLocationIfNeeded() already guards on
    /// authorization, so this never triggers a permission prompt (it only ever reaches
    /// `.requestLocation()`, never `.requestWhenInUseAuthorization()`). 20s balances catching a
    /// good fix promptly against not polling GPS so fast it wastes battery.
    private func runPeriodicPumpLocationRefresh() async {
        pumpDetectionService.updateForegroundRefreshActive(true)
        defer { pumpDetectionService.updateForegroundRefreshActive(false) }
        while Task.isCancelled == false {
            requestPumpModeLocationIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000_000)
        }
    }

    /// Mirrors this view's current pump-mode/prompt-suppression @State onto the shared
    /// AutomaticPumpDetectionService purely so Stations' hidden diagnostics sheet — a
    /// different view entirely — can display it (see
    /// AutomaticPumpDetectionService.updateForegroundVisitState). Read-only, one-way,
    /// diagnostics-only: called after refreshPumpModeStation()/evaluateAutoPromptPumpMode()
    /// have already finished, so it never influences their outcome.
    private func publishForegroundVisitDiagnostics() {
        pumpDetectionService.updateForegroundVisitState(
            hasNearbyStation: pumpModeStation != nil,
            hasPromptedForCurrentVisit: hasPromptedForCurrentPumpVisit
        )
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestUserLocation()
        case .denied, .restricted:
            clearPumpModeStation()
        default:
            break
        }
    }

    private func refreshPumpModeStation() {
        guard let coordinate = locationManager.latestCoordinate else {
            if locationManager.authorizationDenied {
                clearPumpModeStation()
            }
            return
        }

        guard let candidate = nearestSavedStation(to: coordinate) else {
            clearPumpModeStation()
            return
        }

        // Hysteresis + accuracy gate live in PumpProximity: enter at the tight radius,
        // exit at the larger one, and don't change state on an ambiguous coarse fix.
        let accuracy = locationManager.latestHorizontalAccuracyMeters
        let isAtPump = PumpProximity.isAtPump(
            distanceMeters: candidate.distance,
            horizontalAccuracyMeters: accuracy,
            wasAtPump: pumpModeStation != nil
        )

        guard isAtPump else {
            clearPumpModeStation()
            return
        }

        // Only (re)derive WHICH station from a reliable fix — a coarse fix that merely
        // kept the previous state must not swap the attached station (the name and E85
        // price flow into the fill-up log).
        let fixIsReliable = accuracy.map { $0 >= 0 && $0 <= PumpProximity.maximumPumpModeLocationAccuracyMeters } ?? false
        if fixIsReliable || pumpModeStation == nil {
            pumpModeStation = candidate.station
        }
    }

    /// Clears the current pump-mode station and, critically, resets the per-visit prompt
    /// suppression flag with it. Every "leave the station" path funnels through here so that
    /// re-entering later — even later in the same app session — makes the "At the Pump?"
    /// prompt eligible again instead of being permanently silenced after the first visit.
    private func clearPumpModeStation() {
        guard pumpModeStation != nil else { return }
        pumpModeStation = nil
        hasPromptedForCurrentPumpVisit = false
    }

    private func evaluateAutoPromptPumpMode() {
        guard PumpVisitPromptPolicy.shouldPrompt(
            hasPromptedForCurrentVisit: hasPromptedForCurrentPumpVisit,
            isAuthorized: locationManager.isAuthorizedForUserLocation
        ) else {
            return
        }

        guard let nearbyStation = pumpModeStation else {
            return
        }

        hasPromptedForCurrentPumpVisit = true
        autoPromptStation = nearbyStation
    }

    /// Nearest saved station with coordinates, unfiltered by distance. Whether that
    /// station counts as "at the pump" is decided by PumpProximity (tiny entry/exit
    /// radii + accuracy gate), not by a broad search radius here.
    private func nearestSavedStation(to coordinate: StationCoordinate) -> (station: FuelStation, distance: CLLocationDistance)? {
        let currentLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return savedStations
            .compactMap { station -> (station: FuelStation, distance: CLLocationDistance)? in
                guard let latitude = station.latitude, let longitude = station.longitude else {
                    return nil
                }

                let stationLocation = CLLocation(latitude: latitude, longitude: longitude)
                return (station, currentLocation.distance(from: stationLocation))
            }
            .min { $0.distance < $1.distance }
    }

    /// Feeds the current saved-station list into Automatic Pump Detection's monitor
    /// refresh — the service itself decides (via movement/authorization gates) whether a
    /// real rebuild is warranted, so this is safe to call from every location update.
    private func refreshPumpDetectionMonitoredStations(reason: String) {
        let snapshots = savedStations.map {
            SavedStationSnapshot(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, address: $0.address)
        }
        pumpDetectionService.refreshMonitoredStations(savedStations: snapshots, reason: reason)
    }

    /// Resolves a background-detected station (from a tapped notification) back to a live
    /// `FuelStation` by matching name + coordinate, since Automatic Pump Detection persists
    /// only lightweight metadata, not a SwiftData reference. Fails safely — if the station
    /// was deleted or no longer matches, Pump Mode simply opens without a preselected
    /// station rather than crashing or showing stale data.
    private func resolvePendingDetectedStationIfNeeded() {
        guard let detected = pumpDetectionService.pendingDetectedStation else { return }

        let match = savedStations.first { station in
            guard let latitude = station.latitude, let longitude = station.longitude else { return false }
            let expectedID = AutomaticPumpDetectionStationKey.make(name: station.name, latitude: latitude, longitude: longitude)
            return expectedID == detected.id
        }

        pumpModeStation = match
        pumpModeSessionToken += 1
        // A background arrival notification already carries a precisely confirmed
        // station (see AutomaticPumpDetectionService's Stage-B confirmation) — trust it
        // directly rather than re-running the manual resolver, so the sheet never briefly
        // regresses to "No Nearby E85 Station Found" while a resolution we don't need runs.
        if let match, let candidate = pumpContextCandidate(from: match) {
            pumpContextState = .matched(candidate)
        } else {
            pumpContextState = .noMatch
        }
        isShowingPumpMode = true
        pumpDetectionService.pendingDetectedStation = nil
    }

    private func openPumpMode() {
        AppHaptics.selection()

        if locationManager.authorizationStatus == .notDetermined || locationManager.isAuthorizedForUserLocation {
            locationManager.requestUserLocation()
        }

        // Manual open no longer resolves station context from whatever coordinate happens
        // to be cached (that stale-read race was the root cause of "No Nearby Station
        // Detected" while standing at a real pump) — present the sheet immediately with a
        // resolving state, then let resolvePumpStationContext fetch a fresh, bounded fix.
        pumpModeSessionToken += 1
        let sessionToken = pumpModeSessionToken
        pumpContextState = .resolving
        isShowingPumpMode = true

        Task { @MainActor in
            await resolvePumpStationContext(sessionToken: sessionToken)
        }
    }

    /// Re-resolves station context for the currently open Pump Mode session with a fresh,
    /// bounded location fetch. Safe to call multiple times per session (e.g. the app
    /// becoming active again) — any result is discarded if `sessionToken` no longer
    /// matches the current session (Pump Mode was closed/reopened in the meantime).
    private func resolvePumpStationContext(sessionToken: Int) async {
        let cachedAccuracyDescription = locationManager.latestHorizontalAccuracyMeters.map { "\(Int($0)) m" } ?? "unknown"
        debugPumpContextLog("Manual Pump Mode opened (session \(sessionToken)) — cached fix accuracy: \(cachedAccuracyDescription) (not used for resolution; a fresh fix is always requested).")

        let fix = await requestBoundedFreshLocation(sessionToken: sessionToken)
        guard sessionToken == pumpModeSessionToken else {
            debugPumpContextLog("Discarding stale resolution for session \(sessionToken) — a newer session is active.")
            return
        }

        if let fix {
            debugPumpContextLog("Fresh fix received — accuracy \(Int(fix.horizontalAccuracyMeters)) m.")
        } else {
            debugPumpContextLog("No fresh fix available within the attempt/timeout budget.")
        }

        let savedCandidates = savedStations.compactMap { station in
            pumpContextCandidate(from: station)
        }
        let liveEntries = recentLiveStationCache.currentEntries(now: Date())
        let liveCandidates = liveEntries.compactMap { PumpStationContextResolver.candidate(fromLive: $0) }
        let cacheAgeDescription = recentLiveStationCache.fetchedAt.map { "\(Int(Date().timeIntervalSince($0))) s old" } ?? "empty"
        debugPumpContextLog("Considering \(savedCandidates.count) saved and \(liveCandidates.count) recent live candidate(s) (live cache: \(cacheAgeDescription)).")

        let result = PumpStationContextResolver.resolve(
            candidates: savedCandidates + liveCandidates,
            freshLatitude: fix?.coordinate.latitude,
            freshLongitude: fix?.coordinate.longitude,
            horizontalAccuracyMeters: fix?.horizontalAccuracyMeters,
            locationTimestamp: fix?.timestamp,
            now: Date()
        )

        guard sessionToken == pumpModeSessionToken else {
            debugPumpContextLog("Discarding stale resolution for session \(sessionToken) — a newer session is active.")
            return
        }

        applyPumpContextResult(result, fix: fix)
    }

    /// Up to `PumpStationContextResolver.maximumFreshLocationAttempts` bounded fresh-fix
    /// requests, accepting the first one that meets the manual-context accuracy bar (or
    /// the last attempt's result, even if imperfect, once attempts are exhausted — the
    /// resolver itself will correctly reject it if it's still not good enough).
    private func requestBoundedFreshLocation(sessionToken: Int) async -> StationLocationManager.FreshLocationResult? {
        var lastFix: StationLocationManager.FreshLocationResult?

        for attempt in 1...PumpStationContextResolver.maximumFreshLocationAttempts {
            guard sessionToken == pumpModeSessionToken else { return nil }

            debugPumpContextLog("Fresh-location attempt \(attempt) started (timeout \(Int(PumpStationContextResolver.freshLocationTimeout))s).")
            guard let fix = await locationManager.requestFreshLocationAsync(timeout: PumpStationContextResolver.freshLocationTimeout) else {
                debugPumpContextLog("Fresh-location attempt \(attempt) timed out or was unauthorized.")
                continue
            }

            lastFix = fix
            let isGoodEnough = fix.horizontalAccuracyMeters >= 0
                && fix.horizontalAccuracyMeters <= PumpStationContextResolver.maximumAccuracyMeters
            if isGoodEnough {
                return fix
            }
            debugPumpContextLog("Fresh-location attempt \(attempt) was too inaccurate (\(Int(fix.horizontalAccuracyMeters)) m) — retrying if attempts remain.")
        }

        return lastFix
    }

    private func applyPumpContextResult(_ result: PumpStationContextResult, fix: StationLocationManager.FreshLocationResult?) {
        switch result {
        case .matched(let candidate):
            pumpContextState = .matched(candidate)
            debugPumpContextLog("Resolver matched \(candidate.source == .saved ? "saved" : "live") station: \(candidate.name).")
        case .ambiguous(let candidates):
            // The resolver already confirmed these are all within the manual context
            // radius of the same fix that produced this result — recompute each
            // candidate's distance from that same fix purely for display in the picker.
            let userLocation = fix.map { CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            let withDistance = candidates.map { candidate -> PumpStationContextAmbiguousCandidate in
                let distance = userLocation?.distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)) ?? 0
                return PumpStationContextAmbiguousCandidate(candidate: candidate, distanceMeters: distance)
            }
            pumpContextState = .ambiguous(withDistance)
            debugPumpContextLog("Resolver found \(candidates.count) ambiguous candidates — asking the user to choose.")
        case .noCandidates:
            pumpContextState = .noMatch
            debugPumpContextLog("Resolver result: no candidate within the manual context radius.")
        case .locationUnavailable:
            pumpContextState = .locationUnavailable
            debugPumpContextLog("Resolver result: location unavailable.")
        case .locationStale, .locationInaccurate:
            // Reduced ("Approximate") accuracy authorization is the single most common,
            // actionable cause of a persistently poor fix — surface that specifically when
            // it applies, since turning Precise Location back on directly fixes it.
            if locationManager.isPreciseLocationEnabled == false {
                pumpContextState = .preciseLocationRequired
                debugPumpContextLog("Resolver result: \(result == .locationStale ? "stale" : "inaccurate") fix with reduced accuracy authorization.")
            } else {
                pumpContextState = .locationUnavailable
                debugPumpContextLog("Resolver result: \(result == .locationStale ? "stale" : "inaccurate") fix.")
            }
        }
        debugPumpContextLog("Final Pump Mode context state: \(pumpContextStateDebugLabel).")
    }

    private var pumpContextStateDebugLabel: String {
        switch pumpContextState {
        case .resolving: return "resolving"
        case .matched(let candidate): return "matched(\(candidate.source == .saved ? "saved" : "live"))"
        case .noMatch: return "noMatch"
        case .locationUnavailable: return "locationUnavailable"
        case .preciseLocationRequired: return "preciseLocationRequired"
        case .ambiguous(let candidates): return "ambiguous(\(candidates.count))"
        }
    }

    /// Converts a saved `FuelStation` into a resolver candidate. Returns nil for a station
    /// without valid coordinates, matching `nearestSavedStation`'s existing filtering.
    private func pumpContextCandidate(from station: FuelStation) -> PumpStationContextCandidate? {
        PumpStationContextResolver.candidate(fromSaved: PumpContextSavedStationSnapshot(
            name: station.name,
            latitude: station.latitude,
            longitude: station.longitude,
            address: [station.address, station.city, station.state].filter { $0.isEmpty == false }.joined(separator: ", "),
            e85Price: station.lastKnownE85Price > 0 ? station.lastKnownE85Price : nil
        ))
    }

    private func debugPumpContextLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[85Blends][pumpContext] \(message())")
        #endif
    }

    private func openPumpModeFuelLog(with result: BlendCalculator.Result) {
        let draft = pumpModeFuelLogDraft(from: result)
        isShowingPumpMode = false

        Task { @MainActor in
            await Task.yield()
            calculatorFuelLogDraft = draft
        }
    }

    private func pumpModeFuelLogDraft(from result: BlendCalculator.Result) -> FuelLogDraft {
        var draft = FuelLogStore.prefillDraft(from: result, vehicle: activeVehicle)

        if case .matched(let candidate) = pumpContextState {
            draft.stationName = candidate.name

            if let price = candidate.e85Price, price > 0 {
                draft.e85PricePerGallon = price
            }
        }

        return draft
    }

    @MainActor
    private func applyDefaultsIfNeeded(for key: String) {
        guard loadedDefaultsKey != key else {
            return
        }

        let defaults = activeVehicle.map(calculatorDefaults(for:)) ?? fallbackDefaults

        // Blank, not "0" — a selected vehicle with no known tank capacity must never silently
        // compute from a guessed 16-gallon assumption (audit item 4). Left blank, the field
        // parses to 0 and BlendCalculator's existing "Enter a tank size greater than 0 gallons"
        // guard clearly tells the user what's needed, right here in Calculator — no trip back to
        // Garage required, and nothing is written back to the vehicle from this screen.
        tankSize = defaults.tankSizeGallons > 0 ? formatted(defaults.tankSizeGallons) : ""
        targetFuelEthanol = formatted(defaults.targetEthanolPercent)
        currentFuelEthanol = formatted(defaults.currentEthanolPercent)
        gasOctane = formatted(defaults.gasOctane)
        selectedBlend = nearestBlendChip(for: defaults.targetEthanolPercent)
        loadedDefaultsKey = key
    }

    // Pump Ethanol / Gas Ethanol are app-level "remembered" preferences (audit items 9-10), not
    // vehicle fields — loaded once per view lifetime rather than on every active-vehicle switch,
    // so switching vehicles never resets or leaks a session value that was never vehicle-scoped
    // to begin with.
    @MainActor
    private func loadRememberedFuelPreferencesIfNeeded() {
        guard hasLoadedRememberedFuelPreferences == false else { return }
        hasLoadedRememberedFuelPreferences = true
        e85Ethanol = formatted(PumpEthanolResolution.resolve(remembered: RememberedFuelPreferenceStore.rememberedPumpEthanolPercent()))
        gasEthanol = formatted(GasEthanolResolution.resolve(remembered: RememberedFuelPreferenceStore.rememberedGasEthanolPercent()))
    }

    private func rememberPumpEthanolIfValid(_ text: String) {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return }
        RememberedFuelPreferenceStore.rememberPumpEthanolPercent(value)
    }

    private func rememberGasEthanolIfValid(_ text: String) {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return }
        RememberedFuelPreferenceStore.rememberGasEthanolPercent(value)
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BLEND TOOL")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text("E85 Calculator")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(headerNickname)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Spacer()

            Button {
                openPumpMode()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "fuelpump.fill")
                    Text("Pump")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AppTheme.Colors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // Discoverable entry point to Compare Fuel Cost — high on the screen, before the long Tank
    // Info form, so it doesn't require scrolling to find. Available in both Simple and Normal
    // App Experience Mode (Calculator itself is never gated by mode), and opens the exact same
    // CostCalculatorView the More entry reaches — no separate/duplicated calculator.
    private var compareFuelCostCard: some View {
        Button {
            AppHaptics.selection()
            isShowingCompareFuelCost = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.Colors.accentYellow)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.Colors.accentYellow.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare Fuel Cost")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("See what different ethanol blends cost.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }
            .padding(14)
            .background(AppTheme.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens a tool to compare fuel costs across ethanol blends.")
    }

    private var vehicleHintCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "car.circle")
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.accentYellow)

            Text("Add a vehicle in Garage to auto-fill your calculator defaults.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

}

#Preview {
    CalculatorView()
        .modelContainer(for: [VehicleProfile.self, FuelLogEntry.self, FuelStation.self], inMemory: true)
        .environment(StationLocationManager())
}

// Pump Ethanol / Gas Ethanol are intentionally NOT fields here anymore — they're app-level
// "remembered" preferences (see FuelPreferenceResolution.swift), not vehicle- or
// active-vehicle-switch-scoped values. See fallbackDefaults / calculatorDefaults(for:) above and
// loadRememberedFuelPreferencesIfNeeded() for how they're actually resolved.
private struct CalculatorDefaults {
    let nickname: String
    let tankSizeGallons: Double
    let targetEthanolPercent: Double
    let currentEthanolPercent: Double
    let gasOctane: Double
}

private struct TargetBlendSelector: View {
    let options: [String]
    @Binding var selectedBlend: String
    @Binding var targetFuelEthanol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Target Blend")
                .font(.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(options, id: \.self) { blend in
                        Button {
                            AppHaptics.selection()
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                                selectedBlend = blend
                                targetFuelEthanol = String(blend.dropFirst())
                            }
                        } label: {
                            Text(blend)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(
                                    selectedBlend == blend
                                    ? AppTheme.Colors.textPrimary
                                    : AppTheme.Colors.textSecondary
                                )
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    selectedBlend == blend
                                    ? AppTheme.Colors.primaryGreen
                                    : AppTheme.Colors.cardBackground
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(
                                            selectedBlend == blend
                                            ? AppTheme.Colors.primaryGreen.opacity(0.95)
                                            : AppTheme.Colors.borderColor,
                                            lineWidth: 1
                                        )
                                )
                                .scaleEffect(selectedBlend == blend ? 1.04 : 1)
                                .opacity(selectedBlend == blend ? 1 : 0.88)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: selectedBlend)
                    }
                }
            }
        }
    }
}

private struct TankInputSection: View {
    @Binding var tankSize: String
    @Binding var currentLevel: String
    @Binding var currentFuelEthanol: String
    @Binding var targetFuelEthanol: String

    var body: some View {
        CalculatorCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tank Info")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                inputRow(title: "Tank Size", value: $tankSize, suffix: "gal", keyboard: .decimalPad)
                inputRow(title: "Current Level (%)", value: $currentLevel, suffix: "%", keyboard: .decimalPad)

                HStack(spacing: 10) {
                    quickLevelButton("E", value: "0")
                    quickLevelButton("1/4", value: "25")
                    quickLevelButton("1/2", value: "50")
                    quickLevelButton("3/4", value: "75")
                }

                inputRow(title: "Current Fuel Ethanol %", value: $currentFuelEthanol, suffix: "%", keyboard: .decimalPad)
                inputRow(title: "Target Ethanol %", value: $targetFuelEthanol, suffix: "%", keyboard: .decimalPad)
            }
        }
    }

    private func inputRow(title: String, value: Binding<String>, suffix: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            HStack {
                TextField("", text: value)
                    .keyboardType(keyboard)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(suffix)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(AppTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func quickLevelButton(_ title: String, value: String) -> some View {
        Button {
            currentLevel = value
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityLabel("Set current fuel level to \(title)")
    }
}

private struct BlendResultCard: View {
    let result: BlendCalculator.Result

    var body: some View {
        CalculatorCard {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("\(result.blendLabel)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(AppTheme.Colors.primaryGreen.opacity(0.22))
                        .clipShape(Capsule())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Blend Result")
                            .font(.headline)
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text("Estimated using your current tank and fuel assumptions.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                HStack(spacing: 14) {
                    metricTile(title: "E85 gallons", value: String(format: "%.2f", result.e85Gallons), accent: AppTheme.Colors.primaryGreen)
                    metricTile(title: "Gas gallons", value: String(format: "%.2f", result.gasGallons), accent: AppTheme.Colors.gasOrange)
                    metricTile(title: "Estimated octane", value: String(format: "%.1f", result.estimatedOctane), accent: AppTheme.Colors.primaryGreen)
                }

                Divider()
                    .overlay(AppTheme.Colors.border)

                HStack(alignment: .top) {
                    detailMetric(title: "Final ethanol %", value: String(format: "%.1f%%", result.finalEthanolPercent))
                    Spacer()
                    detailMetric(title: "Total gallons to add", value: String(format: "%.2f gal", result.totalGallonsToAdd))
                }
            }
            .padding(2)
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(AppTheme.Colors.elevatedCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(AppTheme.Colors.primaryGreen.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func metricTile(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .minimumScaleFactor(0.8)
                .lineLimit(1)

            Rectangle()
                .fill(accent.opacity(0.75))
                .frame(width: 28, height: 3)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 16)
        .background(AppTheme.Colors.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func detailMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
    }
}

private struct BlendGuideSection: View {
    @Binding var selectedBlend: String
    @Binding var targetFuelEthanol: String

    private let tiers: [BlendGuideTier] = [
        .init(
            range: "E20-E30",
            title: "Daily / Range",
            octane: "91-94 oct",
            description: "Best range with a modest ethanol bump.",
            rangeDots: 4,
            powerDots: 1
        ),
        .init(
            range: "E40-E50",
            title: "Balanced",
            octane: "95-98 oct",
            description: "A strong middle ground for street use.",
            rangeDots: 3,
            powerDots: 3
        ),
        .init(
            range: "E60-E70",
            title: "Performance",
            octane: "99-102 oct",
            description: "Higher ethanol for harder driving.",
            rangeDots: 2,
            powerDots: 4
        ),
        .init(
            range: "E85",
            title: "Highest Blend",
            octane: "105+ oct",
            description: "Highest common pump blend with the shortest range.",
            rangeDots: 1,
            powerDots: 5
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tap a tier to apply")
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textMuted)

            ForEach(tiers) { tier in
                BlendGuideRow(
                    tier: tier,
                    isActive: tier.contains(blend: selectedBlend),
                    applyAction: { applyTier(tier) }
                )
            }
        }
    }

    private func applyTier(_ tier: BlendGuideTier) {
        let blend = tier.preferredBlend
        AppHaptics.impact()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.74)) {
            selectedBlend = blend
            targetFuelEthanol = String(blend.dropFirst())
        }
    }
}

private struct BlendGuideRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let tier: BlendGuideTier
    let isActive: Bool
    let applyAction: () -> Void

    private var activeCardBackground: Color {
        // Light: white card so the accent border and Active badge carry the emphasis.
        // Dark/OLED: keep the existing dark accent fill for clear contrast on dark surfaces.
        colorScheme == .light
            ? AppTheme.Colors.cardBackground
            : AppTheme.Colors.softGreenBackground.opacity(0.78)
    }

    var body: some View {
        Button(action: applyAction) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tier.range)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isActive ? AppTheme.Colors.primaryGreen : AppTheme.Colors.textMuted)

                        Text(tier.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text(tier.octane)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.accentYellow)
                    }

                    Spacer()

                    if isActive {
                        Text("Active")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AppTheme.Colors.primaryGreen)
                            .clipShape(Capsule())
                    }
                }

                Text(tier.description)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(2)

                HStack(spacing: 16) {
                    indicatorRow(title: "Range", filledDots: tier.rangeDots)
                    indicatorRow(title: "Power", filledDots: tier.powerDots)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? activeCardBackground : AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isActive ? AppTheme.Colors.primaryGreen.opacity(0.75) : AppTheme.Colors.borderColor, lineWidth: isActive ? 1.2 : 1)
            )
            .shadow(color: isActive ? AppTheme.Colors.primaryGreen.opacity(0.12) : .clear, radius: 10, y: 4)
            .scaleEffect(isActive ? 1.01 : 1)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(BlendGuideTierButtonStyle(isActive: isActive))
        .accessibilityLabel("Apply \(tier.title), \(tier.range)")
        .animation(.spring(response: 0.28, dampingFraction: 0.74), value: isActive)
    }

    private func indicatorRow(title: String, filledDots: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            HStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(index < filledDots ? (title == "Range" ? AppTheme.Colors.rangeBlue : AppTheme.Colors.powerRed) : AppTheme.Colors.borderColor)
                        .frame(width: 8, height: 8)
                }
            }
        }
    }
}

private struct AdvancedSettingsSection: View {
    @Binding var e85Ethanol: String
    @Binding var e85Octane: String
    @Binding var gasEthanol: String
    @Binding var gasOctane: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fuel Properties")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            SettingsInputRow(title: "E85 Ethanol %", value: $e85Ethanol, suffix: "%")
            SettingsInputRow(title: "Gas Ethanol %", value: $gasEthanol, suffix: "%")
            SettingsInputRow(title: "E85 Octane", value: $e85Octane, suffix: "oct")
            SettingsInputRow(title: "Gas Octane", value: $gasOctane, suffix: "oct")

            VStack(alignment: .leading, spacing: 10) {
                Text("Quick Octane")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                HStack(spacing: 10) {
                    octaneButton("87")
                    octaneButton("89")
                    octaneButton("91")
                    octaneButton("93")
                }
            }
        }
    }

    private func octaneButton(_ value: String) -> some View {
        Button {
            gasOctane = value
        } label: {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(gasOctane == value ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(gasOctane == value ? AppTheme.Colors.gasOrange.opacity(0.22) : AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(gasOctane == value ? AppTheme.Colors.gasOrange : AppTheme.Colors.borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct PumpInstructionsSection: View {
    let result: BlendCalculator.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PumpInstructionStep(
                step: "Step 1",
                title: "Fill calculated gallons of E85 first",
                detail: "Start with \(String(format: "%.2f", result.e85Gallons)) gallons of E85 to anchor the blend."
            )

            PumpInstructionStep(
                step: "Step 2",
                title: "Top off with calculated gallons of gas",
                detail: "Add \(String(format: "%.2f", result.gasGallons)) gallons of pump gas to finish the mix."
            )

            PumpInstructionStep(
                step: "Step 3",
                title: "Result blend and octane",
                detail: "\(result.blendLabel) at roughly \(String(format: "%.1f", result.estimatedOctane)) octane with \(String(format: "%.2f", result.totalGallonsToAdd)) gallons added."
            )
        }
    }
}

private struct PumpInstructionStep: View {
    let step: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(step == "Step 1" ? AppTheme.Colors.primaryGreen : (step == "Step 2" ? AppTheme.Colors.gasOrange : AppTheme.Colors.stationYellow))
                .frame(width: 38, height: 38)
                .overlay(
                    Text(String(step.suffix(1)))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.black)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ScalePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct SettingsInputRow: View {
    let title: String
    @Binding var value: String
    let suffix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            HStack {
                TextField("", text: $value)
                    .keyboardType(.decimalPad)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(suffix)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct BlendGuideTier: Identifiable {
    let id = UUID()
    let range: String
    let title: String
    let octane: String
    let description: String
    let rangeDots: Int
    let powerDots: Int

    var preferredBlend: String {
        switch range {
        case "E20-E30":
            "E30"
        case "E40-E50":
            "E50"
        case "E60-E70":
            "E60"
        case "E85":
            "E85"
        default:
            "E30"
        }
    }

    func contains(blend: String) -> Bool {
        switch blend {
        case "E20", "E30":
            return range == "E20-E30"
        case "E40", "E50":
            return range == "E40-E50"
        case "E60":
            return range == "E60-E70"
        case "E85":
            return range == "E85"
        default:
            return false
        }
    }
}

private struct BlendGuideTierButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.04 : 0))
            )
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ExpandableSection<Content: View>: View {
    let title: String
    let subtitle: String?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        CalculatorCard {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let subtitle {
                                Text("\(title) — \(subtitle)")
                                    .font(.headline)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                            } else {
                                Text(title)
                                    .font(.headline)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                            }
                        }

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                if isExpanded {
                    content
                }
            }
        }
    }
}

private struct CalculatorCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.elevatedCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

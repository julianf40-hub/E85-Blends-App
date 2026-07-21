//
//  TripPlannerView.swift
//  EightyFiveBlends
//
//  85Blends Pro feature. Only reached when the user has Pro (gated by ProFeatureGate in
//  StationsView). This is the v2.2 Trip Planner: plan an E85 route before driving —
//  geocode origin/destination, request driving directions via MapKit, discover live E85
//  stations along the corridor, recommend stops, and score route risk.
//
//  Also ships: Detour Severity, E85 Detour Avoided routing, Save Route (Pro), Station
//  Availability Reporting, and Backup Gas Stations.
//

import SwiftUI
import SwiftData
import MapKit
import CoreLocation

struct TripPlannerView: View {
    @Environment(\.openURL) private var openURL
    @Query(sort: \VehicleProfile.createdAt, order: .forward)
    private var vehicles: [VehicleProfile]

    // Common E85-blend targets offered as quick chips.
    private static let blendOptions: [Double] = [30, 50, 70, 85]
    /// Sentinel blend value meaning "plan on pump gasoline only". Only selectable for
    /// flex-fuel vehicles. 0.0 is safe because no real ethanol blend uses 0%.
    private static let gasolineOnlyBlend: Double = 0.0

    // MARK: - Inputs
    @State private var origin = ""
    @State private var destination = ""
    @State private var selectedVehicleID: PersistentIdentifier?
    @State private var currentFuelPercent: Double = 50
    @State private var tankSizeText = ""
    @State private var mpgText = ""
    @State private var targetBlend: Double = 30
    /// How much fuel the driver wants left on arrival (percent of a full tank). Default 20%.
    @State private var targetReservePercent: Double = 20
    /// Whether gasoline is an allowed fallback for this trip. Defaults from the selected
    /// vehicle's flex-fuel flag (see applyVehicle); unknown vehicles default to E85 required.
    @State private var fuelBackupMode: FuelBackupMode = .e85Required

    // MARK: - Planning state
    @State private var plan: TripPlan?
    @State private var isPlanning = false
    @State private var errorMessage: String?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var planTask: Task<Void, Never>?
    /// Gates the inline route map so it inserts a tick AFTER the results layout settles —
    /// this avoids MapKit allocating a 0×0 Metal drawable during the same layout pass.
    @State private var showRouteMap = false

    /// Pure request-generation and plan-staleness tracking, extracted from view state so it's
    /// independently unit-testable (see PlanRequestTracker.swift / PlanRequestTrackerTests).
    /// Every planning-related Task captures the generation active when it starts and confirms
    /// via `requestTracker.isCurrent(_:)` that it's still current before writing any shared
    /// result/loading/error state — Task cancellation is cooperative (a superseded task can
    /// still be mid-flight when a newer one starts), so this is what actually prevents a stale
    /// request from overwriting a newer one, not `Task.isCancelled` alone.
    @State private var requestTracker = PlanRequestTracker()

    // MARK: - Route-aware E85 station discovery (Phase 2)
    @State private var analysis: RouteE85Analysis?
    @State private var isDiscoveringStations = false
    @State private var stationError: String?
    @State private var discoveryTask: Task<Void, Never>?

    // MARK: - Backup gas station discovery (gas-backup mode only)
    @State private var backupGasStations: [BackupGasStation] = []
    @State private var isDiscoveringGasStations = false
    @State private var gasStationError: String?
    @State private var gasDiscoveryTask: Task<Void, Never>?
    /// Whether the backup gas section is expanded; auto-set when the E85 plan can't satisfy the trip.
    @State private var showBackupGasStations = false

    // MARK: - Gas Only station discovery (active when Target Fuel = Gas Only)
    @State private var gasOnlyStations: [BackupGasStation] = []
    @State private var gasOnlyRecommendedStops: [GasOnlyStop] = []
    @State private var isDiscoveringGasOnlyStations = false
    @State private var gasOnlyStationError: String?
    @State private var gasOnlyDiscoveryTask: Task<Void, Never>?
    @State private var gasOnlyOutcome: RouteOutcome?
    @State private var gasOnlyRisk: TripPlan.RouteRisk?
    /// Estimated arrival reserve at the destination after the Gas Only plan (nil while planning).
    @State private var gasOnlyDestinationReserveFraction: Double?
    /// Whether the current Gas Only plan's stops (if any) are known to complete the trip —
    /// the single source every Gas Only UI section reads before presenting the route as
    /// safe/complete. See `GasOnlyPlanCompleteness`.
    @State private var gasOnlyCompleteness: GasOnlyPlanCompleteness?

    // MARK: - Feature 2: Saved trips
    @State private var showSavedTrips = false

    // MARK: - Full-screen route map
    @State private var showFullMap = false

    // MARK: - Feature 3: Report toast
    @State private var reportToastMessage = ""
    @State private var reportToastVisible = false

    /// Risk shown on the map badge: route-aware risk once stations load, else the
    /// preliminary range-based risk. Gas Only risk is computed by the gas-only planner.
    ///
    /// Once a gasoline-backup route is verified, risk reflects THAT route's own buffer
    /// strength, not the failed ethanol attempt's — a strong gas-backup buffer must never
    /// still read as "Medium Risk" carried over from the E85 miss.
    private var displayRisk: TripPlan.RouteRisk? {
        if let fallback = gasFallbackPlan, fallback.succeeds {
            let lowest = fallback.lowestArrivalReserveFraction ?? fallback.destinationReserveFraction ?? 0
            if lowest < 0.10 { return .high }
            if lowest < 0.20 { return .medium }
            return .low
        }
        if isGasolineOnly { return gasOnlyRisk ?? (plan != nil ? .low : nil) }
        return analysis?.risk ?? plan?.risk
    }

    /// Custom risk-badge wording used once a gasoline-backup route is active, so the
    /// active route reads as "reachable via a verified fallback," not as a generic
    /// severity level that could be misread as "the plan is unsafe."
    private var displayRiskLabelOverride: String? {
        guard gasFallbackPlan?.succeeds == true else { return nil }
        switch displayRisk {
        case .low:    return "Reachable with Gas"
        case .medium: return "Gas Backup — Caution"
        case .high:   return "Gas Backup — Risky"
        case nil:     return nil
        }
    }

    /// True when the currently selected vehicle is marked flex-fuel.
    private var selectedVehicleIsFlexFuel: Bool {
        guard let id = selectedVehicleID else { return false }
        return vehicles.first(where: { $0.persistentModelID == id })?.isFlexFuel ?? false
    }

    /// True when the user has chosen to plan on pump gasoline only (no E85).
    private var isGasolineOnly: Bool { abs(targetBlend) < 0.1 }

    /// Chip options for the "Target Fuel" row. Gas Only is prepended for flex-fuel vehicles.
    private var targetFuelOptions: [Double] {
        selectedVehicleIsFlexFuel
            ? [Self.gasolineOnlyBlend, 30, 50, 70, 85]
            : [30, 50, 70, 85]
    }

    /// Ordered intermediate waypoint coordinates for the navigation handoff.
    ///
    /// Priority:
    /// 1. Recommended E85 stops (in route order)
    /// 2. First backup gas station when the outcome calls for a gas fallback
    /// 3. Empty — direct origin→destination routing
    ///
    /// Gas Only mode always returns empty (no intermediate stops needed).
    private var navigationWaypoints: [CLLocationCoordinate2D] {
        // Gas Only: use discovered gas stops as waypoints
        if isGasolineOnly {
            return gasOnlyRecommendedStops.map { $0.station.coordinate }
        }

        // Verified gasoline-backup route: use its own stop sequence directly, rather than
        // relying on the backup-gas list's ranking to surface the right station(s) first.
        if let fallback = gasFallbackPlan, fallback.succeeds {
            return fallback.stops.map { $0.station.coordinate }
        }

        if let stops = analysis?.recommendedStops, stops.isEmpty == false {
            return stops.map { $0.station.coordinate }
        }

        if fuelBackupMode == .gasBackupAllowed,
           let outcome = analysis?.outcome,
           (outcome == .gasolineBackupAvailable || outcome == .e85DetourAvoided),
           let first = displayedBackupGasStations.first {
            return [first.coordinate]
        }

        return []
    }

    /// Display string for the first recommended fuel stop, used by the Copy Fuel Stop action.
    /// Composes name + address + city/state for E85 stops (full address available), and
    /// name + city/state for backup gas stops (MapKit doesn't provide street address).
    /// Falls back to decimal coordinates if all name/address fields are empty.
    private var fuelStopCopyString: String? {
        guard navigationWaypoints.isEmpty == false else { return nil }

        // Gas Only: first gas stop (BackupGasStation has no street address)
        if isGasolineOnly, let first = gasOnlyRecommendedStops.first {
            let s = first.station
            let result = [s.name, s.city, s.state]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
                .joined(separator: ", ")
            if result.isEmpty == false { return result }
        }

        if let stop = analysis?.recommendedStops.first {
            let s = stop.station.station
            let result = [s.name, s.address, s.city, s.state]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
                .joined(separator: ", ")
            if result.isEmpty == false { return result }
        }

        if let first = displayedBackupGasStations.first {
            let result = [first.name, first.city, first.state]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
                .joined(separator: ", ")
            if result.isEmpty == false { return result }
        }

        if let coord = navigationWaypoints.first {
            return String(format: "%.5f, %.5f", coord.latitude, coord.longitude)
        }

        return nil
    }

    /// Cap the number of station pins drawn on the map. Dense routes can surface 90+ stations;
    /// rendering that many custom annotations stresses MapKit (and can wedge its Metal layer),
    /// so we draw the recommended-stop stations plus an evenly-spaced subset of the rest. The
    /// full count is always reported in the list below — only the map pins are limited.
    private static let maxMapPins = 20

    /// Maximum number of backup gas station cards shown in the UI. Discovery may return more, but
    /// showing all of them overwhelms the Trip Planner list. We keep the best 10 by proximity to
    /// the route first, then progress along the route, then name as a tie-breaker.
    private static let maxBackupGasCards = 10

    /// IDs of stations in the recommended fuel-stop plan — used only to give their map
    /// pins a distinct treatment. Tiny set (0–3 entries).
    private var recommendedStationIDs: Set<String> {
        Set(analysis?.recommendedStops.map { $0.station.id } ?? [])
    }

    /// True when E85 alone — with whatever materially useful stops the planner found —
    /// cannot physically reach the destination, so a backup gas stop is required (not just
    /// optional) to finish the route. Drives both the Fuel Plan card's required-stop leg
    /// and its gating, so the Fuel Plan never implies safety the Trip Summary doesn't show.
    private var e85CannotCompleteRoute: Bool {
        guard isGasolineOnly == false, fuelBackupMode == .gasBackupAllowed else { return false }
        return (analysis?.destinationReserveFraction ?? 0) < 0
    }

    /// "E30" / "Max E85" — the selected target fuel, for copy that needs to name it
    /// (e.g. the gasoline-fallback outcome subtitle and Trip Summary rows).
    private var targetBlendLabel: String {
        isGasolineOnly ? "Gas Only" : "E\(Int(targetBlend.rounded()))"
    }

    /// True when the selected ethanol/E85 plan cannot complete the trip or meet the
    /// arrival buffer — the trigger condition for attempting a gasoline-backup fallback
    /// (requirements: try the ethanol route first, only fall back when it demonstrably
    /// doesn't work).
    private var didEthanolPlanFail: Bool {
        switch analysis?.outcome {
        case .gasolineBackupAvailable, .e85DetourAvoided, .fallbackMayBeNeeded:
            return true
        default:
            return false
        }
    }

    /// A full re-plan of this route using only regular gas stations, computed when the
    /// selected ethanol plan can't complete the trip or meet the arrival buffer and gas
    /// backup is allowed. Gas backup is a TRUE fallback: only treated as "the route" once
    /// verified to actually reach the destination and meet the buffer — never because E85
    /// merely failed (requirement 9: if gas backup isn't allowed, or the fallback itself
    /// doesn't work, the trip stays unsafe/unreachable — no silent fallback either way).
    private var gasFallbackPlan: GasFallbackPlan? {
        guard isGasolineOnly == false,
              fuelBackupMode == .gasBackupAllowed,
              didEthanolPlanFail,
              isDiscoveringStations == false,
              isDiscoveringGasStations == false,
              backupGasStations.isEmpty == false,
              let plan,
              let tank = tankSizeValue,
              let mpg = mpgValue
        else {
            return nil
        }

        let context = RouteFuelContext(
            tankSizeGallons: tank,
            mpg: mpg,
            currentFuelPercent: currentFuelPercent,
            targetArrivalReservePercent: targetReservePercent,
            fuelBackupMode: .gasBackupAllowed
        )
        return RouteE85Planner().evaluateGasFallback(
            gasStations: backupGasStations,
            totalMiles: plan.distanceMiles,
            context: context
        )
    }

    /// The outcome actually shown to the user: a verified gasoline-fallback route
    /// overrides the raw (failed) E85 outcome, since the trip is no longer being planned
    /// on ethanol. Falls back to the raw E85 outcome otherwise — including when a fallback
    /// was attempted but did not itself succeed (requirement 9).
    private var effectiveOutcome: RouteOutcome? {
        if let fallback = gasFallbackPlan, fallback.succeeds {
            return .gasolineFallbackRoute
        }
        return analysis?.outcome
    }

    /// True once a verified gasoline-backup route is active — the active route the driver
    /// is following, not just a possibility. Drives label/copy overrides throughout the
    /// Trip Summary, Fuel Plan, and Backup Gas Stations sections so the failed ethanol
    /// plan's numbers are never confused with the active route's.
    private var isFallbackActive: Bool {
        gasFallbackPlan?.succeeds == true
    }

    private var mapStations: [RouteStation] {
        guard let analysis else { return [] }
        let all = analysis.stations
        if all.count <= Self.maxMapPins { return all }

        let recommendedIDs = Set(analysis.recommendedStops.map { $0.station.id })
        let recommended = all.filter { recommendedIDs.contains($0.id) }
        let others = all.filter { recommendedIDs.contains($0.id) == false }

        let remaining = max(0, Self.maxMapPins - recommended.count)
        let step = max(1, others.count / max(1, remaining))
        let sampledOthers = stride(from: 0, to: others.count, by: step).prefix(remaining).map { others[$0] }

        return (recommended + sampledOthers).sorted { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles }
    }

    /// Gas backup pins for the map — drawn only when the section is expanded. Budget is what
    /// remains after E85 pins are allocated, up to the shared 20-pin cap.
    private var mapGasStations: [BackupGasStation] {
        guard showBackupGasStations, fuelBackupMode == .gasBackupAllowed, backupGasStations.isEmpty == false else {
            return []
        }
        let remaining = max(0, Self.maxMapPins - mapStations.count)
        guard remaining > 0 else { return [] }
        let step = max(1, backupGasStations.count / remaining)
        return Array(stride(from: 0, to: backupGasStations.count, by: step)
            .prefix(remaining)
            .map { backupGasStations[$0] })
    }

    /// Below this distance from the origin, a backup gas station is treated as too close
    /// to meaningfully help complete the route (the same intuition as the planner's own
    /// material-gain filter) — deprioritized in fallback mode unless it's actually part of
    /// the verified plan.
    private static let minUsefulBackupGasDistanceMiles = 20.0

    /// The backup gas stations shown in the UI list. Outside fallback mode, sorted by
    /// proximity to the route, then progress along it, then name (unchanged). In fallback
    /// mode, ranked by usefulness for completing the route instead: the station(s) the
    /// verified plan actually uses lead the list, stations too close to the origin (e.g. a
    /// gas station a mile from the start) sink to the bottom, then proximity as before.
    /// Full discovery results are preserved in `backupGasStations` for map-pin sampling.
    private var displayedBackupGasStations: [BackupGasStation] {
        guard let fallback = gasFallbackPlan, isFallbackActive else {
            let sorted = backupGasStations.sorted {
                if $0.offRouteMiles != $1.offRouteMiles { return $0.offRouteMiles < $1.offRouteMiles }
                if $0.distanceAlongRouteMiles != $1.distanceAlongRouteMiles { return $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles }
                return $0.name < $1.name
            }
            return Array(sorted.prefix(Self.maxBackupGasCards))
        }

        let planStationIDs = Set(fallback.stops.map { $0.station.id })
        let ranked = backupGasStations.sorted { lhs, rhs in
            let lhsInPlan = planStationIDs.contains(lhs.id)
            let rhsInPlan = planStationIDs.contains(rhs.id)
            if lhsInPlan != rhsInPlan { return lhsInPlan }

            let lhsTooClose = lhs.distanceAlongRouteMiles < Self.minUsefulBackupGasDistanceMiles
            let rhsTooClose = rhs.distanceAlongRouteMiles < Self.minUsefulBackupGasDistanceMiles
            if lhsTooClose != rhsTooClose { return rhsTooClose }

            if lhs.offRouteMiles != rhs.offRouteMiles { return lhs.offRouteMiles < rhs.offRouteMiles }
            if lhs.distanceAlongRouteMiles != rhs.distanceAlongRouteMiles { return lhs.distanceAlongRouteMiles < rhs.distanceAlongRouteMiles }
            return lhs.name < rhs.name
        }
        return Array(ranked.prefix(Self.maxBackupGasCards))
    }

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case origin, destination, tankSize, mpg
    }

    var body: some View {
        // GeometryReader captures the exact viewport width once so the scroll content
        // can be pinned to that exact width. Using .frame(maxWidth: .infinity) only
        // sets the *reported* width; a child that escapes its layout proposal (e.g.
        // the inline Map's GeometryReader on first layout pass on physical devices)
        // can still widen the scroll content and enable horizontal dragging even in a
        // vertical-only ScrollView. An exact .frame(width:) prevents any overflow.
        GeometryReader { proxy in
            let contentWidth = proxy.size.width
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    ProShellHeader(
                        icon: "map.fill",
                        title: "Trip Planner",
                        subtitle: "Plan an E85 route before you drive. Enter your trip and vehicle to estimate fuel, range, and stops."
                    )

                    tripInputCard

                    if let errorMessage {
                        errorCard(errorMessage)
                    }

                    if let plan {
                        if requestTracker.isPlanStale {
                            planStaleBanner
                        }
                        routeMapCard(plan)
                        tripSummaryCard(plan)
                        fuelPlanCardIfNeeded(plan)
                        if !isGasolineOnly {
                            stopsAlongRouteSection
                            backupGasSection
                        } else {
                            gasOnlyStopsSection
                        }
                        if !navigationWaypoints.isEmpty {
                            navigationRecommendationCard
                        }
                        navigationHandoffCard(plan)
                        if isDiscoveringStations == false,
                           isDiscoveringGasOnlyStations == false,
                           analysis != nil || isGasolineOnly {
                            saveRouteSection(plan)
                        }
                        // Extra breathing room below the last result card — the fixed
                        // Plan Route bar already reserves its own space via safeAreaInset,
                        // this just keeps the final buttons from sitting flush against it.
                        Color.clear.frame(height: 24)
                    }
                }
                .padding(16)
                // Exact width — not maxWidth — so no child can report a frame wider
                // than the viewport and trigger horizontal pan in the vertical ScrollView.
                .frame(width: contentWidth, alignment: .leading)
            }
            // Note: .scrollDismissesKeyboard is intentionally absent — on physical iPhone
            // it interprets rapid key-repeat layout re-measurements as scroll events,
            // triggering keyboard dismissal mid-delete, which flips focusedField and
            // causes a UIKit safeAreaInset height-oscillation crash.
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .safeAreaInset(edge: .bottom) {
                planBottomBar
            }
            .background(AppTheme.Colors.charcoal.ignoresSafeArea())
            .keyboardDoneToolbar()
            .dismissKeyboardOnTap()
            .overlay(alignment: .bottom) {
                toastOverlay
                    .padding(.bottom, 90)
            }
        }
        .navigationTitle("Trip Planner")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: prefillFromActiveVehicleIfNeeded)
        .onDisappear {
            // Cancellation only — leaving the screen must not clear an already-valid plan
            // the user may simply be navigating back to (e.g. after a momentary sheet or
            // backgrounding). The generation bump still guarantees any in-flight work can't
            // write stale results in after this point.
            cancelAllPlanningTasks()
            requestTracker.supersedeInFlightWork()
        }
        .onChange(of: origin) { _, _ in invalidatePlanIfNeeded() }
        .onChange(of: destination) { _, _ in invalidatePlanIfNeeded() }
        .onChange(of: selectedVehicleID) { _, _ in invalidatePlanIfNeeded() }
        .onChange(of: tankSizeText) { _, _ in invalidatePlanIfNeeded() }
        .onChange(of: mpgText) { _, _ in invalidatePlanIfNeeded() }
        .onChange(of: targetBlend) { _, _ in invalidatePlanIfNeeded() }
        .onChange(of: currentFuelPercent) { _, _ in invalidatePlanIfNeeded() }
        .onChange(of: targetReservePercent) { _, _ in invalidatePlanIfNeeded() }
        .onChange(of: fuelBackupMode) { _, _ in invalidatePlanIfNeeded() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                savedTripsToolbarButton
            }
        }
        .sheet(isPresented: $showSavedTrips) {
            NavigationStack {
                SavedTripsListView { savedTrip in
                    applyFromSavedTrip(savedTrip)
                    showSavedTrips = false
                }
            }
        }
        .sheet(isPresented: $showFullMap) {
            if let currentPlan = plan {
                FullRouteMapView(
                    plan: currentPlan,
                    mapStations: mapStations,
                    mapGasStations: mapGasStations,
                    gasOnlyStops: gasOnlyRecommendedStops,
                    recommendedStationIDs: recommendedStationIDs,
                    displayRisk: displayRisk,
                    displayRiskLabelOverride: displayRiskLabelOverride
                )
            }
        }
    }

    // MARK: - Input card

    private var tripInputCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Your Trip")

            // Origin
            labeledField(
                label: "Origin",
                icon: "location.circle.fill",
                placeholder: "City, address, or ZIP",
                text: $origin,
                field: .origin,
                showError: showOriginError,
                errorText: "Enter a starting location."
            )

            // Swap origin ↔ destination
            HStack {
                Spacer()
                Button {
                    swapOriginDestination()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption.weight(.bold))
                        Text("Swap")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(canSwap ? AppTheme.Colors.primaryGreen : AppTheme.Colors.textMuted)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(AppTheme.Colors.cardBackground)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(
                            canSwap ? AppTheme.Colors.primaryGreen.opacity(0.5) : AppTheme.Colors.borderColor,
                            lineWidth: 1
                        )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSwap)
                .accessibilityLabel("Swap origin and destination")
            }

            // Destination
            labeledField(
                label: "Destination",
                icon: "mappin.circle.fill",
                placeholder: "City, address, or ZIP",
                text: $destination,
                field: .destination,
                showError: showDestinationError,
                errorText: "Enter a destination."
            )

            vehiclePicker

            // Current fuel level
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    fieldLabel("Current Fuel Level", icon: "fuelpump.circle.fill")
                    Spacer()
                    Text("\(Int(currentFuelPercent.rounded()))%")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                        .monospacedDigit()
                }
                Slider(value: $currentFuelPercent, in: 0...100, step: 1)
                    .tint(AppTheme.Colors.primaryGreen)
            }

            // Tank size + MPG side by side
            HStack(alignment: .top, spacing: 12) {
                numericField(
                    label: "Tank Size",
                    icon: "drop.fill",
                    placeholder: "16",
                    suffix: "gal",
                    text: $tankSizeText,
                    field: .tankSize,
                    showError: showTankError,
                    errorText: "Enter gallons."
                )
                numericField(
                    label: "Est. MPG",
                    icon: "gauge.with.dots.needle.67percent",
                    placeholder: "22",
                    suffix: "mpg",
                    text: $mpgText,
                    field: .mpg,
                    showError: showMPGError,
                    errorText: "Enter MPG."
                )
            }

            // Target fuel (Gas Only appears first for flex-fuel vehicles)
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Target Fuel", icon: "fuelpump.fill")
                HStack(spacing: 8) {
                    ForEach(targetFuelOptions, id: \.self) { blend in
                        blendChip(blend)
                    }
                }
            }

            arrivalReserveSection

            if !isGasolineOnly {
                fuelBackupSection
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var vehiclePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Vehicle", icon: "car.fill")
            Menu {
                if vehicles.isEmpty {
                    Text("No vehicles in your Garage yet")
                } else {
                    ForEach(vehicles) { vehicle in
                        Button {
                            applyVehicle(vehicle)
                        } label: {
                            Label(vehicleTitle(vehicle), systemImage: selectedVehicleID == vehicle.persistentModelID ? "checkmark" : "car")
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(selectedVehicleTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if vehicles.isEmpty {
                Text("Add a vehicle in the Garage tab to auto-fill tank size and blend.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func blendChip(_ blend: Double) -> some View {
        let isGasOnly = abs(blend) < 0.1
        let isSelected = abs(targetBlend - blend) < 0.5
        let chipLabel = isGasOnly ? "Gas Only" : "E\(Int(blend))"
        return Button {
            // Cancel any in-flight discovery for the mode being left and clear prior
            // results (both E85- and Gas-Only-side) via the one authoritative reset path,
            // without disturbing an already-visible route map. Setting targetBlend after
            // triggers invalidatePlanIfNeeded() via onChange if a plan is still present.
            resetForNewPlanningAttempt()
            targetBlend = isGasOnly ? Self.gasolineOnlyBlend : blend
            AppHaptics.selection()
        } label: {
            Text(chipLabel)
                .font(.subheadline.weight(.semibold))
                .minimumScaleFactor(0.75)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .black : AppTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? AppTheme.Colors.stationYellow : AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? AppTheme.Colors.stationYellow : AppTheme.Colors.borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isGasOnly ? "Plan trip using gasoline only." : "Target E\(Int(blend)) blend")
    }

    // MARK: - Arrival reserve target

    private static let reservePresets: [(label: String, sub: String, value: Double)] = [
        ("10%", "Minimum", 10),
        ("20%", "Safer", 20),
        ("50%", "Half Tank", 50)
    ]

    private var arrivalReserveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Arrival Range Buffer", icon: "gauge.with.dots.needle.bottom.50percent")

            Text("Choose how much fuel range you want to keep as a buffer when you arrive.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ForEach(Self.reservePresets, id: \.value) { preset in
                    reserveChip(label: preset.label, sub: preset.sub, value: preset.value)
                }
            }

            HStack {
                Text("Custom")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                Text("\(Int(targetReservePercent.rounded()))%")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .monospacedDigit()
            }
            Slider(value: $targetReservePercent, in: 5...75, step: 1)
                .tint(AppTheme.Colors.stationYellow)
        }
    }

    private func reserveChip(label: String, sub: String, value: Double) -> some View {
        let isSelected = abs(targetReservePercent - value) < 0.5
        return Button {
            targetReservePercent = value
            AppHaptics.selection()
        } label: {
            VStack(spacing: 1) {
                Text(label)
                    .font(.subheadline.weight(.bold))
                Text(sub)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? .black : AppTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(isSelected ? AppTheme.Colors.stationYellow : AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? AppTheme.Colors.stationYellow : AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fuel backup mode

    private var fuelBackupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Fuel Backup", icon: "fuelpump.and.filter")

            Text("Choose whether this vehicle can safely continue on gasoline if E85 is not available.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            fuelBackupOption(
                mode: .gasBackupAllowed,
                title: "E85 Preferred, Gas Backup Allowed",
                detail: "This planner will prefer E85 but may fall back to gasoline if no safe E85 stop is available."
            )
            fuelBackupOption(
                mode: .e85Required,
                title: "E85 Required",
                detail: "This planner will only consider the route safe when E85 stops can support the trip."
            )
        }
    }

    private func fuelBackupOption(mode: FuelBackupMode, title: String, detail: String) -> some View {
        let isSelected = fuelBackupMode == mode
        return Button {
            fuelBackupMode = mode
            AppHaptics.selection()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.textMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppTheme.Colors.primaryGreen.opacity(0.10) : AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? AppTheme.Colors.primaryGreen.opacity(0.5) : AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reusable input rows

    private func fieldLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.primaryGreen)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    private func labeledField(
        label: String,
        icon: String,
        placeholder: String,
        text: Binding<String>,
        field: Field,
        showError: Bool,
        errorText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(label, icon: icon)
            TextField(placeholder, text: text)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(.next)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(showError ? AppTheme.Colors.warningRed.opacity(0.6) : AppTheme.Colors.borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if showError {
                Text(errorText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.warningRed)
            }
        }
    }

    private func numericField(
        label: String,
        icon: String,
        placeholder: String,
        suffix: String,
        text: Binding<String>,
        field: Field,
        showError: Bool,
        errorText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(label, icon: icon)
            HStack(spacing: 6) {
                TextField(placeholder, text: text)
                    .keyboardType(.decimalPad)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .focused($focusedField, equals: field)
                Text(suffix)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(showError ? AppTheme.Colors.warningRed.opacity(0.6) : AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if showError {
                Text(errorText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.warningRed)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Plan button

    private var planBottomBar: some View {
        planButton
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Divider()
            }
    }

    private var planButton: some View {
        Button {
            focusedField = nil
            planRoute()
        } label: {
            HStack(spacing: 8) {
                if isPlanning {
                    ProgressView().tint(AppTheme.Colors.textPrimary)
                } else {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                }
                Text(isPlanning ? "Planning Route…" : "Plan Route")
            }
            .font(.headline)
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(canPlan ? AppTheme.Colors.primaryGreen : AppTheme.Colors.primaryGreen.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canPlan)
    }

    /// Shown above the results whenever a route-affecting input has changed since `plan` was
    /// generated (see `invalidatePlanIfNeeded()`). The stale plan/stations stay visible below
    /// it rather than disappearing — this only flags them as out of date and points at the
    /// existing Plan Route action (always available via the bottom bar) to refresh them.
    private var planStaleBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.gasOrange)
            Text("Your trip settings changed. Plan the route again to update your fuel stops.")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.gasOrange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.Colors.gasOrange.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.gasOrange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't Plan Route")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.gasOrange.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Route map

    private func routeMapCard(_ plan: TripPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "map.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
                Text("Route")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Spacer()
                if let displayRisk {
                    RouteRiskBadge(risk: displayRisk, labelOverride: displayRiskLabelOverride)
                }
            }

            // Non-interactive inline preview — interactionModes: [] prevents the map's pan/zoom
            // gesture from intercepting the parent ScrollView's vertical drag. Full pinch/pan is
            // available via Open Full Map. The map is inserted one tick after layout settles
            // (showRouteMap) to avoid a 0×0 Metal drawable race on first render.
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground)

                    if showRouteMap, geo.size.width > 1, geo.size.height > 1 {
                        Map(position: $cameraPosition, interactionModes: []) {
                            Marker("Start", systemImage: "flag.fill", coordinate: plan.sourceCoordinate)
                                .tint(AppTheme.Colors.primaryGreen)
                            Marker("End", systemImage: "flag.checkered", coordinate: plan.destinationCoordinate)
                                .tint(AppTheme.Colors.stationYellow)
                            MapPolyline(plan.route.polyline)
                                .stroke(AppTheme.Colors.primaryGreen, lineWidth: 5)

                            // E85 stations (pin count capped; full list in stops section).
                            // The recommended plan stops get a distinct green star pin so
                            // they stand out from ordinary yellow station pins. Annotation
                            // content only — insertion/capping is untouched.
                            ForEach(mapStations) { routeStation in
                                Annotation(routeStation.station.name, coordinate: routeStation.coordinate) {
                                    if recommendedStationIDs.contains(routeStation.id) {
                                        Image(systemName: "star.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(AppTheme.Colors.primaryGreen)
                                            .background(Circle().fill(.black.opacity(0.35)))
                                            .accessibilityLabel("Recommended stop: \(routeStation.station.name)")
                                    } else {
                                        Image(systemName: "fuelpump.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(AppTheme.Colors.stationYellow)
                                            .background(Circle().fill(.black.opacity(0.25)))
                                            .accessibilityLabel("E85 station \(routeStation.station.name)")
                                    }
                                }
                            }
                            // Gas Only recommended fuel stops — always shown; small fixed set (1–2 stops).
                            ForEach(gasOnlyRecommendedStops) { stop in
                                Annotation(stop.station.name, coordinate: stop.station.coordinate) {
                                    Image(systemName: "fuelpump.fill")
                                        .font(.title3)
                                        .foregroundStyle(AppTheme.Colors.gasOrange)
                                        .background(Circle().fill(.black.opacity(0.25)))
                                        .accessibilityLabel("Fuel stop: \(stop.station.name)")
                                }
                            }
                            // Backup gas pins are intentionally omitted from the inline preview.
                            // Adding them after the map has rendered triggers a MapKit Metal
                            // MSAA redraw crash on iOS 27 beta. They remain visible in the
                            // full-screen interactive map opened via "Open Full Map".
                        }
                        .mapStyle(.standard)
                        .overlay(alignment: .bottomTrailing) {
                            Button {
                                AppHaptics.selection()
                                showFullMap = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.caption2.weight(.bold))
                                    Text("Open Full Map")
                                        .font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                        }
                    } else {
                        ProgressView().tint(AppTheme.Colors.primaryGreen)
                    }
                }
                .frame(width: max(0, geo.size.width), height: max(0, geo.size.height))
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )

            HStack(spacing: 16) {
                routeStat(icon: "ruler.fill", value: formattedMiles(plan.distanceMiles), label: "Distance")
                Divider().frame(height: 28)
                routeStat(icon: "clock.fill", value: formattedTravelTime(plan.travelTime), label: "Drive Time")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.elevatedCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func routeStat(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.Colors.primaryGreen)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }
        }
    }

    // MARK: - Trip summary

    private func tripSummaryCard(_ plan: TripPlan) -> some View {
        // Estimated stops + lowest reserve come from the route-aware analysis once it loads;
        // fall back to the preliminary range-based estimate while stations are discovering.
        let estimatedStops = analysis?.estimatedStops ?? plan.estimatedStops
        let lowestReserve = analysis?.lowestArrivalReserveFraction

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Trip Summary")

            HStack(spacing: 12) {
                metricTile(
                    icon: "fuelpump.fill",
                    value: String(format: "%.1f gal", plan.fuelNeededGallons),
                    label: "Fuel Required"
                )
                metricTile(
                    icon: "gauge.open.with.lines.needle.33percent",
                    value: formattedMiles(plan.fullTankRangeMiles),
                    label: "Full-Tank Range"
                )
            }

            if isGasolineOnly {
                outcomeBanner(
                    gasOnlyOutcome ?? .gasolineOnly,
                    labelOverride: gasOnlyOutcomeLabel,
                    messageOverride: gasOnlyOutcomeMessage
                )
            } else if let analysis, isDiscoveringStations == false {
                if let fallback = gasFallbackPlan, fallback.succeeds {
                    outcomeBanner(
                        .gasolineFallbackRoute,
                        messageOverride: "Your selected \(targetBlendLabel) plan cannot meet the arrival buffer because no useful E85 stop is available. The planner switched to gasoline backup to complete the trip safely."
                    )
                } else {
                    outcomeBanner(analysis.outcome)
                }
            } else {
                reachabilityRow(plan)
            }

            VStack(spacing: 0) {
                summaryRow(icon: "ruler.fill", label: "Total distance", value: formattedMiles(plan.distanceMiles))
                summaryDivider
                summaryRow(icon: "clock.fill", label: "Estimated drive time", value: formattedTravelTime(plan.travelTime))
                summaryDivider
                summaryRow(
                    icon: "target",
                    label: "Target arrival buffer",
                    value: "\(Int(targetReservePercent.rounded()))%"
                )
                if !isGasolineOnly {
                    summaryDivider
                    summaryRow(
                        icon: "fuelpump.and.filter",
                        label: "Fuel backup",
                        value: fuelBackupMode == .gasBackupAllowed ? "Gas allowed" : "E85 required"
                    )
                }
                if let fallback = gasFallbackPlan, fallback.succeeds {
                    // Requirement: clearly distinguish the desired ethanol plan from the
                    // gasoline route actually being used, so the summary can't be misread
                    // as "the E30 plan worked."
                    summaryDivider
                    summaryRow(icon: "drop.fill", label: "Desired target fuel", value: targetBlendLabel)
                    summaryDivider
                    summaryRow(icon: "arrow.triangle.2.circlepath", label: "Actual route mode", value: "Gasoline backup")
                    summaryDivider
                    summaryRow(
                        icon: "fuelpump.circle.fill",
                        label: "E85 stops",
                        value: (analysis?.recommendedStops.isEmpty ?? true) ? "0 (none useful)" : "\(analysis?.recommendedStops.count ?? 0)"
                    )
                    summaryDivider
                    summaryRow(icon: "fuelpump.and.filter", label: "Backup gas stop", value: "Required")
                    summaryDivider
                    summaryRow(
                        icon: "drop.fill",
                        label: "Gas backup arrival buffer",
                        value: fallback.destinationReserveFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
                    )
                }
                summaryDivider
                summaryRow(
                    icon: "drop.fill",
                    // The active route is gasoline backup, not the failed ethanol plan —
                    // these two rows report the ORIGINAL (failed) E85-only math, so they're
                    // clearly labeled as such rather than looking like the active route's
                    // numbers (requirement: don't mix active gas-backup metrics with failed
                    // E85-only metrics under ambiguous labels).
                    label: isFallbackActive ? "E85-only arrival buffer" : "Estimated arrival buffer",
                    value: arrivalReserveText
                )
                // "Estimated E85/gas stops" duplicates the "E85 stops" row already shown
                // above in fallback mode — skip it there to avoid showing the same count twice.
                if isFallbackActive == false {
                    summaryDivider
                    summaryRow(
                        icon: "fuelpump.circle.fill",
                        label: isGasolineOnly ? "Estimated gas stops" : "Estimated E85 stops",
                        value: isGasolineOnly
                            ? (isDiscoveringGasOnlyStations ? "…" : "\(gasOnlyRecommendedStops.count)")
                            : (isDiscoveringStations ? "…" : "\(estimatedStops)")
                    )
                }
                summaryDivider
                summaryRow(
                    icon: "drop.triangle.fill",
                    label: isFallbackActive ? "E85-only lowest buffer" : "Lowest trip buffer",
                    value: isGasolineOnly
                        ? gasOnlyLowestReserveText
                        : (lowestReserve.map { "\(Int(($0 * 100).rounded()))%" } ?? (isDiscoveringStations ? "…" : "—"))
                )
                summaryDivider
                HStack(spacing: 10) {
                    Image(systemName: "flag.checkered")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .frame(width: 22)
                    Text("Route outcome")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Spacer()
                    if isGasolineOnly {
                        let outcome = gasOnlyOutcome ?? .gasolineOnly
                        // Reuses the exact same override the Trip Summary banner reads, so
                        // this row and the banner can never disagree on a partial plan.
                        Text(gasOnlyOutcomeLabel ?? outcome.label)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(outcome.foreground)
                            .multilineTextAlignment(.trailing)
                    } else if isDiscoveringStations == false, let outcome = effectiveOutcome {
                        Text(outcome.label)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(outcome.foreground)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text(isDiscoveringStations ? "…" : "—").foregroundStyle(AppTheme.Colors.textMuted)
                    }
                }
                .padding(.vertical, 11)
                summaryDivider
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .frame(width: 22)
                    Text("Route risk")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Spacer()
                    if let displayRisk {
                        RouteRiskBadge(risk: displayRisk, labelOverride: displayRiskLabelOverride)
                    } else {
                        Text("—").foregroundStyle(AppTheme.Colors.textMuted)
                    }
                }
                .padding(.vertical, 11)
            }
            .padding(.horizontal, 14)
            .background(AppTheme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )

            Text("Estimates assume \(Int(currentFuelPercent.rounded()))% of a \(tankSizeText.isEmpty ? "—" : tankSizeText)-gal tank at \(mpgText.isEmpty ? "—" : mpgText) MPG. Arrival buffer is an estimate and may vary with speed, weather, traffic, and driving style.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func summaryRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .frame(width: 22)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .monospacedDigit()
        }
        .padding(.vertical, 11)
    }

    private var summaryDivider: some View {
        Divider().overlay(AppTheme.Colors.borderColor)
    }

    // The arrival reserve the driver would have WITHOUT stopping — this is the figure the
    // reserve target is compared against (it's what motivates a recommended stop).
    private var arrivalReserveText: String {
        if isGasolineOnly {
            guard let fraction = gasOnlyDestinationReserveFraction else {
                return isDiscoveringGasOnlyStations ? "…" : "—"
            }
            if fraction < 0 { return "Unreachable" }
            return "\(Int((fraction * 100).rounded()))%"
        }
        guard let fraction = analysis?.noStopReserveFraction else {
            return isDiscoveringStations ? "…" : "—"
        }
        if fraction < 0 { return "Unreachable" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Traffic-light colour for a reserve fraction. Use the raw fraction (not a rounded %)
    /// to avoid rounding artefacts at the boundaries.
    private func fuelReserveColor(for fraction: Double) -> Color {
        if fraction >= 0.20 { return AppTheme.Colors.primaryGreen }
        if fraction >= 0.10 { return AppTheme.Colors.stationYellow }
        return AppTheme.Colors.warningRed
    }

    private var gasOnlyLowestReserveText: String {
        if isDiscoveringGasOnlyStations { return "…" }
        let all = gasOnlyRecommendedStops.map { $0.arrivalReserveFraction }
            + [gasOnlyDestinationReserveFraction].compactMap { $0 }
        guard let lowest = all.min() else { return "—" }
        return "\(Int((lowest * 100).rounded()))%"
    }

    /// Count-aware label for the Gas Only outcome banner and the "Route outcome" summary
    /// row — both read this one property so they can never disagree with each other.
    private var gasOnlyOutcomeLabel: String? {
        guard gasOnlyOutcome == .gasStopRecommended else { return nil }
        let n = gasOnlyRecommendedStops.count
        if gasOnlyCompleteness == .partial {
            return n == 1 ? "Partial Fuel Plan — 1 Stop Found" : "Partial Fuel Plan — \(n) Stops Found"
        }
        return n == 1 ? "1 Fuel Stop Recommended" : "\(n) Fuel Stops Recommended"
    }

    /// Refined message for the Gas Only outcome banner when stops are recommended. A
    /// partial plan (real stops found, but the walk couldn't confirm a further leg) must
    /// never claim the route now meets the selected arrival buffer.
    private var gasOnlyOutcomeMessage: String? {
        guard gasOnlyOutcome == .gasStopRecommended else { return nil }
        if gasOnlyCompleteness == .partial {
            return "Some usable gasoline stops were found, but they do not complete this route safely. Verify additional stops before driving."
        }
        return "This route exceeds your available range while maintaining your selected arrival buffer. Gasoline fuel stops are recommended."
    }

    /// Outcome-aware banner shown once station discovery completes. Pass `labelOverride`
    /// and `messageOverride` to substitute count-aware copy (e.g. "2 Fuel Stops Recommended").
    private func outcomeBanner(
        _ outcome: RouteOutcome,
        labelOverride: String? = nil,
        messageOverride: String? = nil
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: outcome.icon)
                .font(.title3)
                .foregroundStyle(outcome.foreground)
            VStack(alignment: .leading, spacing: 2) {
                Text(labelOverride ?? outcome.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(messageOverride ?? outcome.message)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(outcome.tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(outcome.tint.opacity(0.35), lineWidth: 1)
        )
    }

    private func reachabilityRow(_ plan: TripPlan) -> some View {
        HStack(spacing: 10) {
            Image(systemName: plan.reachableWithoutStops ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(plan.reachableWithoutStops ? AppTheme.Colors.primaryGreen : AppTheme.Colors.gasOrange)
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.reachableWithoutStops ? "Reachable without an E85 stop" : "E85 stop(s) likely needed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Current fuel range ≈ \(formattedMiles(plan.currentRangeMiles))")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((plan.reachableWithoutStops ? AppTheme.Colors.primaryGreen : AppTheme.Colors.gasOrange).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke((plan.reachableWithoutStops ? AppTheme.Colors.primaryGreen : AppTheme.Colors.gasOrange).opacity(0.35), lineWidth: 1)
        )
    }

    private func metricTile(icon: String, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.stationYellow)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.Colors.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - E85 stops along route (Phase 2 — real station discovery)

    @ViewBuilder
    private var stopsAlongRouteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Once the app has switched to gasoline backup, "E85 Stops Along Route" reads
            // oddly over a fallback explanation card — the section is now explaining why
            // gas backup was used, not listing E85 stops.
            SectionHeader(title: isFallbackActive ? "Why Gas Backup Was Used" : "E85 Stops Along Route")

            if isDiscoveringStations {
                discoveringStationsCard
            } else if let stationError {
                stationsMessageCard(
                    icon: "exclamationmark.triangle.fill",
                    tint: AppTheme.Colors.gasOrange,
                    title: "E85 Stations Unavailable",
                    message: stationError
                )
            } else if let analysis {
                stopsContent(analysis)
            }
        }
    }

    @ViewBuilder
    private func stopsContent(_ analysis: RouteE85Analysis) -> some View {
        let stationsFound = "We found \(analysis.stationCount) E85 station\(analysis.stationCount == 1 ? "" : "s") along the route"

        if let fallback = gasFallbackPlan, fallback.succeeds {
            // The selected ethanol plan couldn't complete the trip or meet the buffer —
            // the planner already switched to a verified gasoline-backup route (see the
            // Fuel Plan and Trip Summary), so this section just explains why no E85 stop
            // is shown rather than repeating the full outcome switch below.
            stationsMessageCard(
                icon: "arrow.triangle.2.circlepath",
                tint: AppTheme.Colors.gasOrange,
                title: "Switched to Gasoline Backup",
                message: "Your selected \(targetBlendLabel) plan can't meet your buffer target because no useful E85 stop is available. \(stationsFound), but none materially improve this route, so the planner switched to gasoline backup — see the Fuel Plan below."
            )
        } else if analysis.recommendedStops.isEmpty {
            // No stop in the plan — the message depends on the outcome relative to the target
            // and the fuel-backup mode.
            switch analysis.outcome {
            case .noStopNeeded:
                stationsMessageCard(
                    icon: "checkmark.seal.fill",
                    tint: AppTheme.Colors.primaryGreen,
                    title: "No E85 Stop Needed",
                    message: "You can reach your destination with your target buffer intact. \(stationsFound) if you'd like to top off."
                )
            case .reserveStopRecommended:
                stationsMessageCard(
                    icon: "exclamationmark.circle.fill",
                    tint: AppTheme.Colors.gasOrange,
                    title: "Below Your Buffer Target",
                    message: "Reachable, but below your buffer target. No E85 station along this route can raise your arrival buffer to \(Int(targetReservePercent.rounded()))%. \(stationsFound)."
                )
            case .gasolineBackupAvailable:
                stationsMessageCard(
                    icon: "fuelpump.and.filter",
                    tint: AppTheme.Colors.stationYellow,
                    title: "Gasoline Backup Required",
                    message: "No safe E85 plan found. Gasoline backup is required to complete this route. \(stationsFound)."
                )
            case .fallbackMayBeNeeded:
                stationsMessageCard(
                    icon: "exclamationmark.triangle.fill",
                    tint: AppTheme.Colors.warningRed,
                    title: "Fallback May Be Needed",
                    message: "No safe E85 plan found for this route and buffer target. \(stationsFound)."
                )
            case .e85StopRequired:
                stationsMessageCard(
                    icon: "exclamationmark.triangle.fill",
                    tint: AppTheme.Colors.warningRed,
                    title: "E85 Stop Required",
                    message: "An E85 stop is required, but we couldn't find a reachable one along this route. \(stationsFound)."
                )
            case .e85DetourAvoided:
                stationsMessageCard(
                    icon: "arrow.triangle.turn.up.right.diamond.fill",
                    tint: AppTheme.Colors.stationYellow,
                    title: "E85 Detour Avoided",
                    message: "An E85 stop was available but required a significant detour. Since gas backup is allowed, use an on-route gas station if needed. \(stationsFound)."
                )
            case .gasolineOnly, .gasStopRecommended, .gasFuelStopNeeded, .gasolineFallbackRoute:
                // gasolineFallbackRoute is never actually stored on analysis.outcome (it's
                // a view-level combination of this analysis with a verified gas re-plan,
                // handled by the branch above) — case exists only for switch exhaustiveness.
                EmptyView()
            }
        } else {
            ForEach(Array(analysis.recommendedStops.enumerated()), id: \.element.id) { index, stop in
                recommendedStopCard(stop, number: index + 1)
            }

            Text(stopsFootnote(analysis))
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }

    // MARK: - Backup gas station section

    /// Shown only when gas backup is allowed and the E85 analysis is complete.
    @ViewBuilder
    private var backupGasSection: some View {
        if fuelBackupMode == .gasBackupAllowed,
           let currentAnalysis = analysis,
           isDiscoveringStations == false {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Backup Gas Stations",
                    subtitle: "Shown only as fallback options because gas backup is allowed for this trip."
                )

                if showBackupGasStations {
                    backupGasExpandedContent(currentAnalysis)
                } else {
                    backupGasCollapsedRow
                }
            }
        }
    }

    private var backupGasCollapsedRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "car.fill")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(width: 38, height: 38)
                .background(AppTheme.Colors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                )

            Text(isDiscoveringGasStations
                 ? "Searching for backup gas stations…"
                 : backupGasStations.isEmpty
                    ? "Backup gas stations available along this route."
                    : "\(backupGasStations.count) backup gas stations available along this route.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if isDiscoveringGasStations == false {
                Button {
                    AppHaptics.selection()
                    showBackupGasStations = true
                } label: {
                    Text("Show")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(AppTheme.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                ProgressView().tint(AppTheme.Colors.primaryGreen).scaleEffect(0.8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func backupGasExpandedContent(_ currentAnalysis: RouteE85Analysis) -> some View {
        // Contextual note when E85 can't satisfy the trip (or was skipped due to detour).
        if currentAnalysis.outcome == .gasolineBackupAvailable || currentAnalysis.outcome == .fallbackMayBeNeeded || currentAnalysis.outcome == .e85DetourAvoided {
            let detourAvoided = currentAnalysis.outcome == .e85DetourAvoided
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: detourAvoided ? "arrow.triangle.turn.up.right.diamond.fill" : "info.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                Text(detourAvoided
                     ? "E85 was skipped because the nearest stop required a significant detour. Use one of these gas stations instead."
                     : "E85 alone can't complete this route or meet your buffer target. Gasoline backup is required — use one of these gas stations.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AppTheme.Colors.stationYellow.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.Colors.stationYellow.opacity(0.3), lineWidth: 1)
            )
        }

        if isDiscoveringGasStations {
            HStack(spacing: 12) {
                ProgressView().tint(AppTheme.Colors.primaryGreen)
                Text("Finding backup gas stations along your route…")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
            }
            .padding(16)
            .background(AppTheme.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
        } else if let gasError = gasStationError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                Text(gasError)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AppTheme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            if backupGasStations.count > Self.maxBackupGasCards {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                    Text("Showing the \(Self.maxBackupGasCards) best backup gas options along this route.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
            }
            ForEach(displayedBackupGasStations) { station in
                gasBackupStationCard(station)
            }
        }

        // Collapse button
        Button {
            AppHaptics.selection()
            showBackupGasStations = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                Text("Hide Backup Gas Stations")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(AppTheme.Colors.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private func gasBackupStationCard(_ station: BackupGasStation) -> some View {
        let cityState = [station.city, station.state].filter { $0.isEmpty == false }.joined(separator: ", ")
        // Requirement: clearly mark the station the verified fallback route actually uses,
        // so it doesn't get lost among stations that are merely nearby.
        let isRequiredStop = gasFallbackPlan?.stops.contains(where: { $0.station.id == station.id }) ?? false

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "car.fill")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if cityState.isEmpty == false {
                        Text(cityState)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if isRequiredStop {
                    Text("Required Stop")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppTheme.Colors.primaryGreen.opacity(0.16))
                        .overlay(Capsule().stroke(AppTheme.Colors.primaryGreen.opacity(0.5), lineWidth: 1))
                        .clipShape(Capsule())
                } else {
                    // Gas Backup badge
                    Text("Gas Backup")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppTheme.Colors.cardBackground)
                        .overlay(Capsule().stroke(AppTheme.Colors.borderColor, lineWidth: 1))
                        .clipShape(Capsule())
                }
                reportMenuGas(stationKey: station.id, stationName: station.name)
            }

            HStack(spacing: 10) {
                gasMetric(
                    icon: "point.topleft.down.to.point.bottomright.curvepath.fill",
                    value: formattedMiles(station.distanceAlongRouteMiles),
                    label: "Along route"
                )
                gasMetric(
                    icon: "arrow.up.right",
                    value: formattedMiles(station.offRouteMiles),
                    label: "Off route"
                )
                detourBadge(station.detourSeverity)
            }

            HStack(spacing: 8) {
                gasHandoffButton(title: "Apple Maps", icon: "applelogo", disabled: requestTracker.isPlanStale) {
                    openGasStationInAppleMaps(station)
                }
                gasHandoffButton(title: "Google", icon: "globe", disabled: requestTracker.isPlanStale) {
                    openExternal(googleMapsURL(to: station.coordinate))
                }
                gasHandoffButton(title: "Waze", icon: "car.fill", disabled: requestTracker.isPlanStale) {
                    openExternal(wazeURL(to: station.coordinate))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    isRequiredStop ? AppTheme.Colors.primaryGreen.opacity(0.6) : AppTheme.Colors.borderColor.opacity(0.7),
                    lineWidth: isRequiredStop ? 1.5 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func gasMetric(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .lineLimit(1)
            }
        }
        // frame(maxWidth: .infinity) ensures multiple gasMetrics in an HStack share
        // available width equally instead of sizing to their intrinsic content.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
    }

    private func gasHandoffButton(title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            AppHaptics.selection()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityHint(disabled ? "Plan the route again to update this stop before getting directions." : "")
    }

    private func openGasStationInAppleMaps(_ station: BackupGasStation) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: station.coordinate))
        item.name = station.name.isEmpty ? "Gas Station" : station.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private func stopsFootnote(_ analysis: RouteE85Analysis) -> String {
        let found = "Found \(analysis.stationCount) E85 station\(analysis.stationCount == 1 ? "" : "s") along this route."
        let target = Int(targetReservePercent.rounded())
        switch analysis.outcome {
        case .gasolineBackupAvailable:
            return "\(found) These are the best E85 stops we found, but they don't fully meet your \(target)% buffer target — gasoline backup is required to complete this route."
        case .fallbackMayBeNeeded:
            return "\(found) These E85 stops don't fully meet your \(target)% buffer target. This route may require gasoline, a different route, or a different stop."
        case .e85DetourAvoided:
            return "\(found) These low-detour E85 stops are recommended for the segments they cover. Use an on-route gas station for any remaining segments — detour stops were skipped."
        default:
            return "\(found) Recommended stops maximize progress while keeping your arrival buffer at or above \(target)%."
        }
    }

    /// "Stop 1 of 2 · Next stop in 86 mi" / "Stop 2 of 2 · Then 142 mi to destination".
    /// Uses the same along-route deltas as the Fuel Plan card's legs — no new routing math.
    private func stopSequenceLine(number: Int, total: Int, currentAlongMiles: Double, nextAlongMiles: Double?) -> String {
        var parts = ["Stop \(number) of \(total)"]

        if let nextAlongMiles {
            let toNext = max(0, nextAlongMiles - currentAlongMiles)
            parts.append("Next stop in \(Int(toNext.rounded())) mi")
        } else if let plan {
            let toDestination = max(0, plan.route.distance / 1609.344 - currentAlongMiles)
            parts.append("Then \(Int(toDestination.rounded())) mi to destination")
        }

        return parts.joined(separator: " · ")
    }

    private func stopSequenceRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.Colors.primaryGreen)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func recommendedStopCard(_ stop: RecommendedStop, number: Int) -> some View {
        let station = stop.station.station
        let cityState = [station.city, station.state].filter { $0.isEmpty == false }.joined(separator: ", ")
        let allStops = analysis?.recommendedStops ?? []
        let nextAlongMiles = number < allStops.count ? allStops[number].station.distanceAlongRouteMiles : nil
        // "Safe" on a stop's badge should mean the whole route is safely completed by E85
        // alone, not just that this one leg arrives comfortably — these outcomes are the
        // only ones where an E85-only plan actually reaches the destination with the
        // target buffer met. Otherwise this stop is merely reachable, and the badge says so.
        let routeIsSafe: Bool
        switch analysis?.outcome {
        case .noStopNeeded, .e85StopRequired, .reserveStopRecommended:
            routeIsSafe = true
        default:
            routeIsSafe = false
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(AppTheme.Colors.primaryGreen.opacity(0.16))
                    Text("\(number)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name.isEmpty ? "E85 Station" : station.name)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if cityState.isEmpty == false {
                        Text(cityState)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                Spacer(minLength: 0)

                ReserveBadge(reserveClass: stop.arrivalClass, routeIsSafe: routeIsSafe)
                reportMenuE85(stationKey: stop.station.id, stationName: station.name)
            }

            // Warning when this station has a recent local unavailability report
            if StationReportStore.shared.hasRecentNegativeReport(for: stop.station.id) {
                reportedWarningBanner
            }

            if stop.recommendedForReserveTarget {
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                    Text("Recommended to meet your arrival buffer.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if allStops.isEmpty == false {
                stopSequenceRow(stopSequenceLine(
                    number: number,
                    total: allStops.count,
                    currentAlongMiles: stop.station.distanceAlongRouteMiles,
                    nextAlongMiles: nextAlongMiles
                ))
            }

            // Stop metrics
            HStack(spacing: 10) {
                stopMetric(
                    icon: "point.topleft.down.to.point.bottomright.curvepath.fill",
                    value: formattedMiles(stop.station.distanceAlongRouteMiles),
                    label: "Along route"
                )
                stopMetric(
                    icon: "gauge.with.dots.needle.33percent",
                    value: "\(Int((stop.arrivalReserveFraction * 100).rounded()))%",
                    label: "Arrival buffer"
                )
                stopMetric(
                    icon: "fuelpump.fill",
                    value: String(format: "%.1f gal", stop.suggestedFillGallons),
                    label: "Suggested fill"
                )
            }

            // Off-route distance and detour severity
            HStack(spacing: 8) {
                stopMetric(
                    icon: "arrow.up.right",
                    value: formattedMiles(stop.station.offRouteMiles),
                    label: "Off route"
                )
                detourBadge(stop.station.detourSeverity)
                Spacer(minLength: 0)
            }

            // Per-station navigation handoff
            HStack(spacing: 8) {
                stationHandoffButton(title: "Apple Maps", icon: "applelogo", disabled: requestTracker.isPlanStale) {
                    openStationInAppleMaps(stop.station)
                }
                stationHandoffButton(title: "Google", icon: "globe", disabled: requestTracker.isPlanStale) {
                    openExternal(googleMapsURL(to: stop.station.coordinate))
                }
                stationHandoffButton(title: "Waze", icon: "car.fill", disabled: requestTracker.isPlanStale) {
                    openExternal(wazeURL(to: stop.station.coordinate))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func stopMetric(icon: String, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.stationYellow)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
    }

    private func stationHandoffButton(title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            AppHaptics.selection()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(AppTheme.Colors.primaryGreen)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityHint(disabled ? "Plan the route again to update this stop before getting directions." : "")
    }

    private var discoveringStationsCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(AppTheme.Colors.primaryGreen)
            VStack(alignment: .leading, spacing: 4) {
                Text("Finding E85 stations along your route")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Searching real E85 stations in the route corridor.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func stationsMessageCard(icon: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Gas Only stops section

    @ViewBuilder
    private var gasOnlyStopsSection: some View {
        let shouldShow = isDiscoveringGasOnlyStations
            || gasOnlyRecommendedStops.isEmpty == false
            || gasOnlyStationError != nil
            || gasOnlyOutcome == .gasFuelStopNeeded
        if shouldShow {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Recommended Fuel Stops",
                    subtitle: gasOnlyCompleteness == .partial
                        ? "These are the usable gasoline stops found so far — they do not yet complete this route safely."
                        : "These gasoline stops help keep your trip within range and meet your selected arrival buffer."
                )

                if isDiscoveringGasOnlyStations {
                    discoveringGasOnlyCard
                } else if let message = gasOnlyStationError {
                    stationsMessageCard(
                        icon: "exclamationmark.triangle.fill",
                        tint: AppTheme.Colors.warningRed,
                        title: "Can't Calculate Fuel Stops",
                        message: message
                    )
                } else if gasOnlyOutcome == .gasFuelStopNeeded {
                    stationsMessageCard(
                        icon: "exclamationmark.triangle.fill",
                        tint: AppTheme.Colors.warningRed,
                        title: "No Gas Station Found",
                        message: "No suitable gas station was found along this route. You may need to plan fuel stops manually."
                    )
                } else if gasOnlyRecommendedStops.isEmpty == false {
                    if gasOnlyCompleteness == .partial {
                        gasOnlyPartialPlanBanner
                    }
                    ForEach(Array(gasOnlyRecommendedStops.enumerated()), id: \.element.id) { index, stop in
                        gasOnlyStopCard(stop, number: index + 1)
                    }
                    Text("Suggested fill amounts are the estimated minimum needed for the planned route and selected arrival buffer, based on your tank size and MPG settings.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
            }
        }
    }

    /// Shown above the stop cards when `gasOnlyCompleteness == .partial` — real, useful
    /// stops are listed below, but they must not be presented as completing the route.
    private var gasOnlyPartialPlanBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.warningRed)
            VStack(alignment: .leading, spacing: 2) {
                Text("Partial fuel plan")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Some usable gasoline stops were found, but they do not complete this route safely. Verify additional stops before driving.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.warningRed.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.Colors.warningRed.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var discoveringGasOnlyCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(AppTheme.Colors.stationYellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Finding gas stations along your route")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Searching for gas stations in the route corridor.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func gasOnlyStopCard(_ stop: GasOnlyStop, number: Int) -> some View {
        let station = stop.station
        let cityState = [station.city, station.state]
            .filter { $0.isEmpty == false }.joined(separator: ", ")
        let allStops = gasOnlyRecommendedStops
        let nextAlongMiles = number < allStops.count ? allStops[number].station.distanceAlongRouteMiles : nil

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(AppTheme.Colors.stationYellow.opacity(0.16))
                    Text("\(number)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name.isEmpty ? "Gas Station" : station.name)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if cityState.isEmpty == false {
                        Text(cityState)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                Spacer(minLength: 0)

                ReserveBadge(reserveClass: stop.arrivalClass)
                reportMenuGas(stationKey: station.id, stationName: station.name)
            }

            if allStops.isEmpty == false {
                stopSequenceRow(stopSequenceLine(
                    number: number,
                    total: allStops.count,
                    currentAlongMiles: station.distanceAlongRouteMiles,
                    nextAlongMiles: nextAlongMiles
                ))
            }

            HStack(spacing: 10) {
                stopMetric(
                    icon: "point.topleft.down.to.point.bottomright.curvepath.fill",
                    value: formattedMiles(station.distanceAlongRouteMiles),
                    label: "Along route"
                )
                stopMetric(
                    icon: "gauge.with.dots.needle.33percent",
                    value: "\(Int((stop.arrivalReserveFraction * 100).rounded()))%",
                    label: "Arrival buffer"
                )
                stopMetric(
                    icon: "fuelpump.fill",
                    value: String(format: "%.1f gal", stop.suggestedFillGallons),
                    label: "Suggested fill"
                )
            }

            HStack(spacing: 8) {
                stopMetric(
                    icon: "arrow.up.right",
                    value: formattedMiles(station.offRouteMiles),
                    label: "Off route"
                )
                detourBadge(station.detourSeverity)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                stationHandoffButton(title: "Apple Maps", icon: "applelogo", disabled: requestTracker.isPlanStale) {
                    openGasStationInAppleMaps(station)
                }
                stationHandoffButton(title: "Google", icon: "globe", disabled: requestTracker.isPlanStale) {
                    openExternal(googleMapsURL(to: station.coordinate))
                }
                stationHandoffButton(title: "Waze", icon: "car.fill", disabled: requestTracker.isPlanStale) {
                    openExternal(wazeURL(to: station.coordinate))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Fuel Plan itinerary card

    private struct FuelPlanItem: Identifiable {
        let id: Int
        let icon: String
        let label: String
        let accent: Color
        let isHeadline: Bool
        /// True for the final "Arrive with X%" row: renders at subheadline weight
        /// but uses `accent` for its text colour instead of textPrimary.
        var isArrival: Bool = false
    }

    /// Returns the Fuel Plan card when there are recommended stops (Gas Only or E85).
    /// Returns an empty view otherwise so the body stays clean.
    @ViewBuilder
    private func fuelPlanCardIfNeeded(_ plan: TripPlan) -> some View {
        let showGas = isGasolineOnly && gasOnlyRecommendedStops.isEmpty == false
        let showE85 = !isGasolineOnly
            && isDiscoveringStations == false
            && (analysis?.recommendedStops.isEmpty == false) == true
        // Also show the card when E85 alone can't complete the route — it needs to render
        // the required backup gas stop (or the full verified fallback route) so the plan
        // doesn't stay silent about the shortfall the Trip Summary already reports.
        let showRequiredBackup = !isGasolineOnly && isDiscoveringStations == false
            && (e85CannotCompleteRoute || (gasFallbackPlan?.succeeds ?? false))
        if showGas || showE85 || showRequiredBackup {
            fuelPlanCard(plan)
        }
    }

    private func fuelPlanCard(_ plan: TripPlan) -> some View {
        let items = buildFuelPlanItems(plan)
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Fuel Plan")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    fuelPlanItemRow(item)
                    if item.id < items.count - 1 {
                        Divider().overlay(AppTheme.Colors.borderColor)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(AppTheme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func buildFuelPlanItems(_ plan: TripPlan) -> [FuelPlanItem] {
        var items: [FuelPlanItem] = []
        var nextId = 0
        // Tank size is used to convert reserve fractions to approximate gallons.
        // If the user hasn't entered tank size yet we skip the gallons display.
        let tank = tankSizeValue ?? 0.0

        func add(_ icon: String, _ label: String, _ accent: Color, headline: Bool = false, arrival: Bool = false) {
            items.append(FuelPlanItem(id: nextId, icon: icon, label: label, accent: accent, isHeadline: headline, isArrival: arrival))
            nextId += 1
        }

        // Adds a "Drive X mi to <destination>" row; clamped so negative roundoff never shows.
        func addLeg(_ raw: Double, destination: String) {
            let miles = max(0.0, raw)
            if miles > 0.1 {
                add("arrow.down", "Drive \(formattedMiles(miles)) to \(destination)", AppTheme.Colors.textMuted)
            }
        }

        // "Arrive with about 21% buffer · approx. 3.9 gal" or "Arrival buffer unavailable".
        func arrivalLine(fraction: Double) -> String {
            if fraction < 0 { return "Arrival buffer unavailable" }
            let pct = Int((fraction * 100).rounded())
            if tank > 0 {
                return "Arrive with about \(pct)% buffer · approx. \(String(format: "%.1f gal", fraction * tank))"
            }
            return "Arrive with about \(pct)% buffer"
        }

        // "About 14% buffer · approx. 2.6 gal on arrival" shown as a sub-line under each stop name.
        func stopArrivalLine(fraction: Double) -> String {
            if fraction < 0 { return "Arrives below empty" }
            let pct = Int((fraction * 100).rounded())
            if tank > 0 {
                return "About \(pct)% buffer · approx. \(String(format: "%.1f gal", fraction * tank)) on arrival"
            }
            return "About \(pct)% buffer on arrival"
        }

        let startPct = Int(currentFuelPercent.rounded())
        add("fuelpump.circle.fill", "Start: \(startPct)% tank", AppTheme.Colors.primaryGreen, headline: true)

        var prevMiles = 0.0

        if isGasolineOnly {
            let totalStops = gasOnlyRecommendedStops.count
            for (i, stop) in gasOnlyRecommendedStops.enumerated() {
                let stopLabel = "Stop \(i + 1)"
                addLeg(stop.station.distanceAlongRouteMiles - prevMiles, destination: stopLabel)
                let loc = [stop.station.city, stop.station.state].filter { !$0.isEmpty }.joined(separator: ", ")
                let name = stop.station.name.isEmpty ? "Gas Station" : stop.station.name
                let fullName = loc.isEmpty ? name : "\(name), \(loc)"
                add("fuelpump.fill", "\(stopLabel) — \(fullName)", AppTheme.Colors.stationYellow, headline: true)
                add("drop.fill", stopArrivalLine(fraction: stop.arrivalReserveFraction),
                    fuelReserveColor(for: stop.arrivalReserveFraction))
                add("plus.circle.fill", "Add \(String(format: "%.1f gal", stop.suggestedFillGallons))", AppTheme.Colors.stationYellow)
                prevMiles = stop.station.distanceAlongRouteMiles
                _ = totalStops // suppress unused-variable warning
            }
            addLeg(plan.distanceMiles - prevMiles, destination: "Destination")
            if let f = gasOnlyDestinationReserveFraction {
                add("mappin.circle.fill", arrivalLine(fraction: f),
                    fuelReserveColor(for: f), arrival: true)
            }
        } else if let fallback = gasFallbackPlan, fallback.succeeds {
            // The selected ethanol plan couldn't complete the trip or meet the buffer, and
            // gas backup was verified to work — the planner switched entirely to this
            // route, so show it as the plan instead of the (replaced) E85 attempt.
            // Requirement 6: the required backup stop(s) belong directly in the main plan.
            for (i, stop) in fallback.stops.enumerated() {
                let stopLabel = "Stop \(i + 1)"
                addLeg(stop.station.distanceAlongRouteMiles - prevMiles, destination: stopLabel)
                let loc = [stop.station.city, stop.station.state].filter { !$0.isEmpty }.joined(separator: ", ")
                let name = stop.station.name.isEmpty ? "Gas Station" : stop.station.name
                let fullName = loc.isEmpty ? name : "\(name), \(loc)"
                add("fuelpump.and.filter", "\(stopLabel) — \(fullName) (Gas Backup)", AppTheme.Colors.gasOrange, headline: true)
                add("drop.fill", stopArrivalLine(fraction: stop.arrivalReserveFraction),
                    fuelReserveColor(for: stop.arrivalReserveFraction))
                add("plus.circle.fill", "Add \(String(format: "%.1f gal", stop.suggestedFillGallons))", AppTheme.Colors.gasOrange)
                prevMiles = stop.station.distanceAlongRouteMiles
            }
            addLeg(plan.distanceMiles - prevMiles, destination: "Destination")
            if let f = fallback.destinationReserveFraction {
                add("mappin.circle.fill", arrivalLine(fraction: f),
                    fuelReserveColor(for: f), arrival: true)
            } else {
                add("mappin.circle.fill", "Arrival buffer unavailable", AppTheme.Colors.textMuted)
            }
        } else if isGasolineOnly == false {
            let stops = analysis?.recommendedStops ?? []
            let totalStops = stops.count
            for (i, stop) in stops.enumerated() {
                let stopLabel = "Stop \(i + 1)"
                addLeg(stop.station.distanceAlongRouteMiles - prevMiles, destination: stopLabel)
                let s = stop.station.station
                let loc = [s.city, s.state].filter { !$0.isEmpty }.joined(separator: ", ")
                let name = s.name.isEmpty ? "E85 Station" : s.name
                let fullName = loc.isEmpty ? name : "\(name), \(loc)"
                add("fuelpump.circle.fill", "\(stopLabel) — \(fullName)", AppTheme.Colors.primaryGreen, headline: true)
                add("drop.fill", stopArrivalLine(fraction: stop.arrivalReserveFraction),
                    fuelReserveColor(for: stop.arrivalReserveFraction))
                add("plus.circle.fill", "Add \(String(format: "%.1f gal", stop.suggestedFillGallons))", AppTheme.Colors.primaryGreen)
                prevMiles = stop.station.distanceAlongRouteMiles
                _ = totalStops // suppress unused-variable warning
            }

            // E85 alone (with whatever useful stops it found, possibly none) can't reach
            // the destination, and a full verified gas fallback either isn't available yet
            // (still discovering) or genuinely couldn't be found. Insert the best backup
            // gas station as a best-effort REQUIRED stop for the remaining leg, and
            // recompute the arrival estimate assuming a fill-up there — showing the
            // original E85-only shortfall here would contradict the gas stop just added.
            var finalArrivalFraction = analysis?.destinationReserveFraction
            if e85CannotCompleteRoute {
                let mpg = mpgValue ?? 0
                // Nearest-ahead station from the full discovery set (not the display-capped,
                // off-route-sorted top 10) — the right "required next stop" is the soonest
                // usable gas station ahead of the current position, not the most on-route one.
                let candidate = backupGasStations
                    .filter { $0.distanceAlongRouteMiles > prevMiles + 0.5 }
                    .min(by: { $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles })
                    ?? displayedBackupGasStations.first

                if let candidate {
                    addLeg(candidate.distanceAlongRouteMiles - prevMiles, destination: "Backup Gas Stop")
                    let loc = [candidate.city, candidate.state].filter { !$0.isEmpty }.joined(separator: ", ")
                    let name = candidate.name.isEmpty ? "Gas Station" : candidate.name
                    let fullName = loc.isEmpty ? name : "\(name), \(loc)"
                    add("fuelpump.and.filter", "Required — \(fullName)", AppTheme.Colors.gasOrange, headline: true)
                    add("exclamationmark.triangle.fill",
                        "E85 alone can't complete this route — fill up with regular gas here.",
                        AppTheme.Colors.gasOrange)
                    prevMiles = candidate.distanceAlongRouteMiles
                    if tank > 0, mpg > 0 {
                        let remaining = max(0, plan.distanceMiles - prevMiles)
                        finalArrivalFraction = (tank - remaining / mpg) / tank
                    } else {
                        finalArrivalFraction = nil
                    }
                } else if isDiscoveringGasStations {
                    add("ellipsis.circle", "Searching for a required backup gas stop…", AppTheme.Colors.textMuted)
                } else {
                    add("exclamationmark.triangle.fill",
                        "No backup gas station found along this route — plan fuel manually.",
                        AppTheme.Colors.warningRed)
                }
            }

            addLeg(plan.distanceMiles - prevMiles, destination: "Destination")
            if let f = finalArrivalFraction {
                add("mappin.circle.fill", arrivalLine(fraction: f),
                    fuelReserveColor(for: f), arrival: true)
            } else {
                add("mappin.circle.fill", "Arrival buffer unavailable", AppTheme.Colors.textMuted)
            }
        }

        return items
    }

    private func fuelPlanItemRow(_ item: FuelPlanItem) -> some View {
        let useSemibold = item.isHeadline || item.isArrival
        let textColor: Color = item.isHeadline ? AppTheme.Colors.textPrimary : item.accent
        return HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(useSemibold ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(item.accent)
                .frame(width: 20)
            Text(item.label)
                .font(useSemibold ? .subheadline.weight(.semibold) : .caption)
                // Headline rows: textPrimary (station names, start row).
                // Arrival rows (isArrival): accent colour = reserve traffic-light colour.
                // All other non-headline rows: accent colour (drive muted / add accented).
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.vertical, 10)
    }

    // MARK: - Navigation handoff

    /// Informational card shown above the navigation buttons when fuel stops exist.
    /// Sets per-app expectations so the user knows Google Maps and Apple Maps give
    /// the best multi-stop experience while Waze requires a manual in-app step.
    private var navigationRecommendationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                Text("Best Experience")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }

            Text("Google Maps and Apple Maps can include recommended fuel stops automatically. Waze may require adding fuel stops manually after navigation begins.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                navAppBadgeRow(appName: "Google Maps", icon: "globe",     status: "Recommended",        recommended: true)
                Divider().overlay(AppTheme.Colors.borderColor)
                navAppBadgeRow(appName: "Apple Maps",  icon: "applelogo", status: "Recommended",        recommended: true)
                Divider().overlay(AppTheme.Colors.borderColor)
                navAppBadgeRow(appName: "Waze",        icon: "car.fill",  status: "Extra steps required", recommended: false)
            }
            .padding(.horizontal, 14)
            .background(AppTheme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func navAppBadgeRow(appName: String, icon: String, status: String, recommended: Bool) -> some View {
        let accent: Color = recommended ? AppTheme.Colors.primaryGreen : AppTheme.Colors.gasOrange
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.primaryGreen)
                .frame(width: 22)
            Text(appName)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Spacer()
            Text(status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(accent.opacity(0.12))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(accent.opacity(0.4), lineWidth: 0.5))
        }
        .padding(.vertical, 10)
    }

    private func navigationHandoffCard(_ plan: TripPlan) -> some View {
        let hasStops = !navigationWaypoints.isEmpty
        // In fallback mode the waypoint is the required backup gas stop, not a generic
        // "fuel stop" — name it accordingly so the handoff copy matches the Fuel Plan.
        let stopNoun = isFallbackActive ? "backup gas stop" : "fuel stop"
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: hasStops ? "Open Route With \(stopNoun.capitalized)" : "Open Directions In",
                subtitle: hasStops
                    ? "Google Maps will include supported \(stopNoun)s. Apple Maps may include stops. For Waze, add the \(stopNoun) manually after opening the route."
                    : nil
            )
            HStack(spacing: 10) {
                handoffButton(title: "Apple Maps", icon: "applelogo", disabled: requestTracker.isPlanStale) {
                    openInAppleMaps(plan)
                }
                handoffButton(title: "Google Maps", icon: "globe", disabled: requestTracker.isPlanStale) {
                    openExternal(navigationGoogleMapsURL(plan))
                }
                handoffButton(title: "Waze", icon: "car.fill", disabled: requestTracker.isPlanStale) {
                    openExternal(navigationWazeURL(plan))
                }
            }
            if hasStops {
                wazeHandoffHelperRow
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var wazeHandoffHelperRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Waze opens your destination first. Add the recommended fuel stop manually if needed.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let copyText = fuelStopCopyString {
                Button {
                    UIPasteboard.general.string = copyText
                    AppHaptics.selection()
                    showToast("Fuel stop copied.")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2.weight(.semibold))
                        Text("Copy Stop")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppTheme.Colors.cardBackground)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(AppTheme.Colors.borderColor, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(requestTracker.isPlanStale)
                .opacity(requestTracker.isPlanStale ? 0.45 : 1)
                .accessibilityHint(requestTracker.isPlanStale ? "Plan the route again to update this stop before copying it." : "")
            }
        }
    }

    private func handoffButton(title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            AppHaptics.selection()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityHint(disabled ? "Plan the route again to update this before getting directions." : "")
    }

    // MARK: - Validation

    private var trimmedOrigin: String { origin.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedDestination: String { destination.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tankSizeValue: Double? {
        guard let value = Double(tankSizeText), value > 0, value <= 200 else { return nil }
        return value
    }
    private var mpgValue: Double? {
        guard let value = Double(mpgText), value > 0, value <= 150 else { return nil }
        return value
    }

    private var canPlan: Bool {
        !trimmedOrigin.isEmpty && !trimmedDestination.isEmpty &&
        tankSizeValue != nil && mpgValue != nil && !isPlanning
    }

    // Inline errors only show once the user has typed something invalid.
    private var showOriginError: Bool { origin.isEmpty == false && trimmedOrigin.isEmpty }
    private var showDestinationError: Bool { destination.isEmpty == false && trimmedDestination.isEmpty }
    private var showTankError: Bool { tankSizeText.isEmpty == false && tankSizeValue == nil }
    private var showMPGError: Bool { mpgText.isEmpty == false && mpgValue == nil }

    // Swap is available when at least one field has content to move.
    private var canSwap: Bool { !trimmedOrigin.isEmpty || !trimmedDestination.isEmpty }

    private var isCurrentRouteSaved: Bool {
        guard let tankSize = tankSizeValue, let mpg = mpgValue else { return false }
        return SavedTripStore.shared.canSave(
            origin: trimmedOrigin, destination: trimmedDestination,
            tankSizeGallons: tankSize, estimatedMPG: mpg,
            targetBlendPercent: targetBlend,
            targetArrivalReservePercent: targetReservePercent,
            fuelBackupMode: fuelBackupMode
        ) == false
    }

    // MARK: - Vehicle helpers

    private var selectedVehicleTitle: String {
        guard let id = selectedVehicleID,
              let vehicle = vehicles.first(where: { $0.persistentModelID == id }) else {
            return vehicles.isEmpty ? "No vehicle selected" : "Select a vehicle"
        }
        return vehicleTitle(vehicle)
    }

    private func vehicleTitle(_ vehicle: VehicleProfile) -> String {
        let trimmedNickname = vehicle.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNickname.isEmpty == false { return trimmedNickname }
        let parts = [vehicle.year, vehicle.make, vehicle.model]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        return parts.isEmpty ? "Vehicle" : parts.joined(separator: " ")
    }

    private func applyVehicle(_ vehicle: VehicleProfile) {
        selectedVehicleID = vehicle.persistentModelID
        if vehicle.tankSizeGallons > 0 {
            tankSizeText = formattedInput(vehicle.tankSizeGallons)
        }
        targetBlend = nearestBlendOption(to: vehicle.defaultTargetEthanolPercent)
        // Default the fuel-backup mode from the vehicle's flex-fuel flag: flex-fuel cars can
        // safely run gasoline, so gas backup is allowed; otherwise default to the stricter
        // E85-required. The user can still override per trip in the Fuel Backup section.
        // TODO: When the Garage gains a dedicated fuel-compatibility field, prefer it here
        // instead of `isFlexFuel`.
        fuelBackupMode = vehicle.isFlexFuel ? .gasBackupAllowed : .e85Required
        AppHaptics.selection()
    }

    private func prefillFromActiveVehicleIfNeeded() {
        guard selectedVehicleID == nil else { return }
        if let active = vehicles.first(where: { $0.isActive }) ?? vehicles.first {
            applyVehicle(active)
        }
    }

    private func nearestBlendOption(to value: Double) -> Double {
        Self.blendOptions.min(by: { abs($0 - value) < abs($1 - value) }) ?? 30
    }

    private func formattedInput(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: - Route planning

    /// The single authoritative place that cancels Trip Planner's in-flight work. Every other
    /// place that needs to stop in-flight planning tasks should go through this (directly, or
    /// via `resetForNewPlanningAttempt()`/`clearRouteResults()`) rather than cancelling tasks
    /// individually. Cancellation alone is only a hint for a task to stop early — callers pair
    /// this with a `requestTracker` generation advance (see below) to make a superseded task's
    /// writes inert even if it doesn't stop before completing.
    private func cancelAllPlanningTasks() {
        planTask?.cancel()
        discoveryTask?.cancel()
        gasDiscoveryTask?.cancel()
        gasOnlyDiscoveryTask?.cancel()
    }

    /// Cancels in-flight work and clears every per-attempt result/loading/error field EXCEPT
    /// `plan`, `showRouteMap`, and `isPlanning` — used at the start of a (re)plan and anywhere
    /// else that should reset discovery state without tearing down an already-visible route
    /// map. Returns the new generation so the caller can tag the Task(s) it starts next.
    /// Callers that need a full teardown (including `plan`/`showRouteMap`) should call
    /// `clearRouteResults()` instead.
    @discardableResult
    private func resetForNewPlanningAttempt() -> Int {
        cancelAllPlanningTasks()
        let generation = requestTracker.beginNewAttempt()
        isPlanning = false
        errorMessage = nil
        analysis = nil
        stationError = nil
        isDiscoveringStations = false
        backupGasStations = []
        gasStationError = nil
        isDiscoveringGasStations = false
        showBackupGasStations = false
        gasOnlyStations = []
        gasOnlyRecommendedStops = []
        gasOnlyStationError = nil
        isDiscoveringGasOnlyStations = false
        gasOnlyOutcome = nil
        gasOnlyRisk = nil
        gasOnlyDestinationReserveFraction = nil
        gasOnlyCompleteness = nil
        return generation
    }

    /// Full teardown — used on a failed plan, a swap, or applying a different saved trip.
    /// Removing the map here is fine — the next successful plan re-inserts it once, with the
    /// deferred/size-gated guard.
    private func clearRouteResults() {
        resetForNewPlanningAttempt()
        plan = nil
        showRouteMap = false
    }

    /// Call whenever an input that materially affects a completed plan changes (vehicle, tank
    /// size, MPG, current fuel level, target blend/fuel mode, arrival reserve, backup-gas mode,
    /// origin, or destination). Flags the existing plan as stale instead of silently continuing
    /// to present it as current — it does not clear the plan, touch any other input, or start a
    /// new network request; the user still has to tap Plan Route to act on it. A no-op before
    /// any plan has ever been generated, so the stale banner never shows on first input.
    private func invalidatePlanIfNeeded() {
        requestTracker.invalidate(hasPlan: plan != nil)
    }

    // MARK: - Swap origin / destination

    private func swapOriginDestination() {
        focusedField = nil
        let temp = origin
        origin = destination
        destination = temp
        clearRouteResults()
        errorMessage = nil
        AppHaptics.selection()
    }

    // MARK: - Saved trip helpers

    private func applyFromSavedTrip(_ trip: SavedTrip) {
        origin = trip.originText
        destination = trip.destinationText
        tankSizeText = formattedInput(trip.tankSizeGallons)
        mpgText = formattedInput(trip.estimatedMPG)
        targetBlend = trip.targetBlendPercent == Self.gasolineOnlyBlend
            ? Self.gasolineOnlyBlend
            : nearestBlendOption(to: trip.targetBlendPercent)
        currentFuelPercent = trip.currentFuelLevelPercent
        targetReservePercent = trip.targetArrivalReservePercent
        fuelBackupMode = trip.fuelBackupMode
        clearRouteResults()
        errorMessage = nil
        stationError = nil
    }

    private func saveCurrentRoute(_ plan: TripPlan) {
        guard let tankSize = tankSizeValue, let mpg = mpgValue else { return }
        let risk = isGasolineOnly ? (gasOnlyRisk ?? .low) : (analysis?.risk ?? plan.risk)
        let outcome: RouteOutcome? = isGasolineOnly ? (gasOnlyOutcome ?? .gasolineOnly) : effectiveOutcome
        let riskRaw: String
        switch risk {
        case .low:    riskRaw = "low"
        case .medium: riskRaw = "medium"
        case .high:   riskRaw = "high"
        }
        let outcomeRaw: String
        switch outcome {
        case .noStopNeeded:            outcomeRaw = "noStopNeeded"
        case .reserveStopRecommended:  outcomeRaw = "reserveStopRecommended"
        case .e85StopRequired:         outcomeRaw = "e85StopRequired"
        case .gasolineBackupAvailable: outcomeRaw = "gasolineBackupAvailable"
        case .fallbackMayBeNeeded:     outcomeRaw = "fallbackMayBeNeeded"
        case .e85DetourAvoided:        outcomeRaw = "e85DetourAvoided"
        case .gasolineOnly:            outcomeRaw = "gasolineOnly"
        case .gasStopRecommended:      outcomeRaw = "gasStopRecommended"
        case .gasFuelStopNeeded:       outcomeRaw = "gasFuelStopNeeded"
        case .gasolineFallbackRoute:   outcomeRaw = "gasolineFallbackRoute"
        case nil:                      outcomeRaw = ""
        }
        let trip = SavedTrip(
            id: UUID(),
            originText: trimmedOrigin,
            destinationText: trimmedDestination,
            selectedVehicleName: selectedVehicleTitle,
            tankSizeGallons: tankSize,
            estimatedMPG: mpg,
            targetBlendPercent: targetBlend,
            currentFuelLevelPercent: currentFuelPercent,
            targetArrivalReservePercent: targetReservePercent,
            fuelBackupModeRaw: fuelBackupMode == .gasBackupAllowed ? "gasBackupAllowed" : "e85Required",
            totalDistanceMiles: plan.distanceMiles,
            estimatedDriveTimeSeconds: plan.travelTime,
            estimatedFuelNeededGallons: plan.fuelNeededGallons,
            estimatedStopsCount: isGasolineOnly
            ? gasOnlyRecommendedStops.count
            : (analysis?.estimatedStops ?? plan.estimatedStops),
            routeRiskRaw: riskRaw,
            routeOutcomeRaw: outcomeRaw,
            savedDate: Date(),
            recommendedStopNames: analysis?.recommendedStops.map { $0.station.station.name } ?? []
        )
        SavedTripStore.shared.save(trip)
        AppHaptics.success()
        showToast("Route saved.")
    }

    private func submitReport(stationKey: String, stationName: String, stationType: StationReportStationType, reportType: StationReportType) {
        let report = StationReport(
            id: UUID(),
            stationKey: stationKey,
            stationName: stationName,
            stationType: stationType,
            reportType: reportType,
            timestamp: Date()
        )
        StationReportStore.shared.add(report)
        AppHaptics.success()
        showToast("Thanks — report saved.")
    }

    private func showToast(_ message: String) {
        reportToastMessage = message
        withAnimation(.easeInOut(duration: 0.25)) { reportToastVisible = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.easeInOut(duration: 0.25)) { reportToastVisible = false }
        }
    }

    private func planRoute() {
        guard let tankSize = tankSizeValue, let mpg = mpgValue else { return }
        let originQuery = trimmedOrigin
        let destinationQuery = trimmedDestination
        guard originQuery.isEmpty == false, destinationQuery.isEmpty == false else { return }

        // NOTE: we intentionally do NOT clear `plan`/`showRouteMap` here. Keeping the existing
        // route map alive across a replan lets SwiftUI update the live MapKit view's content
        // instead of tearing it down and re-instantiating it — the re-instantiation is what
        // triggered MapKit's 0×0-drawable Metal assertion on dense routes. On a failed plan we
        // clear them in the catch blocks below via clearRouteResults().
        let generation = resetForNewPlanningAttempt()
        isPlanning = true
        AppHaptics.impact()

        let fuelPercent = currentFuelPercent

        planTask = Task { @MainActor in
            defer {
                // A superseded attempt must not clear a newer attempt's loading state.
                if requestTracker.isCurrent(generation) { isPlanning = false }
            }
            do {
                let source = try await geocode(originQuery, label: "starting location")
                guard requestTracker.isCurrent(generation) else { return }
                let dest = try await geocode(destinationQuery, label: "destination")
                guard requestTracker.isCurrent(generation) else { return }

                let request = MKDirections.Request()
                request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
                request.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
                request.transportType = .automobile

                let response = try await MKDirections(request: request).calculate()
                guard requestTracker.isCurrent(generation), Task.isCancelled == false else { return }
                guard let route = response.routes.first else {
                    clearRouteResults()
                    errorMessage = "No driving route was found between these locations. Try nearby cities or check spelling."
                    return
                }

                let newPlan = TripPlan.make(
                    route: route,
                    source: source,
                    destination: dest,
                    tankSizeGallons: tankSize,
                    mpg: mpg,
                    currentFuelPercent: fuelPercent
                )
                plan = newPlan
                AppHaptics.success()

                if showRouteMap == false {
                    // First plan: insert the map after layout settles. cameraPosition
                    // stays at .automatic — MapKit auto-fits to the route polyline and
                    // markers. Never call .rect() after map insertion: that transition
                    // triggers the iOS 27 beta MapKit MSAA crash (resolve texture lost
                    // during MTLStoreActionMultisampleResolve on camera resize).
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        guard requestTracker.isCurrent(generation) else { return }
                        showRouteMap = true
                    }
                }
                // Replan: map already live, cameraPosition stays .automatic.
                // MapKit re-fits to new route content automatically — no camera
                // transition needed and no MSAA crash risk.

                // Gas Only mode: find gas stations along the route and compute stops.
                if isGasolineOnly {
                    discoverGasOnlyStations(
                        route: route,
                        tankSize: tankSize,
                        mpg: mpg,
                        currentFuelPercent: fuelPercent,
                        generation: generation
                    )
                    return
                }

                // Kick off route-aware E85 station discovery (Phase 2).
                discoverStationsAlongRoute(
                    route: route,
                    tankSize: tankSize,
                    mpg: mpg,
                    currentFuelPercent: fuelPercent,
                    generation: generation
                )

                // Backup gas discovery runs in parallel, only when gas backup is allowed.
                if fuelBackupMode == .gasBackupAllowed {
                    discoverBackupGasStations(route: route, generation: generation)
                }
            } catch is CancellationError {
                // Cancellation is not a failure — never surface it as a planning error.
                return
            } catch let clError as CLError {
                guard requestTracker.isCurrent(generation) else { return }
                clearRouteResults()
                errorMessage = geocodeErrorMessage(for: clError)
            } catch let geocodeError as GeocodeFailure {
                guard requestTracker.isCurrent(generation) else { return }
                clearRouteResults()
                errorMessage = geocodeError.message
            } catch let urlError as URLError where urlError.code == .notConnectedToInternet {
                guard requestTracker.isCurrent(generation) else { return }
                clearRouteResults()
                errorMessage = "You're offline. Connect to the internet to plan a route."
            } catch {
                guard requestTracker.isCurrent(generation) else { return }
                clearRouteResults()
                errorMessage = "We couldn't plan this route. Please check your locations and try again."
            }
        }
    }

    private struct GeocodeFailure: Error { let message: String }

    private func geocode(_ query: String, label: String) async throws -> CLLocationCoordinate2D {
        let placemarks = try await CLGeocoder().geocodeAddressString(query)
        guard let coordinate = placemarks.first?.location?.coordinate,
              (-90...90).contains(coordinate.latitude),
              (-180...180).contains(coordinate.longitude) else {
            throw GeocodeFailure(message: "We couldn't find the \(label) \"\(query)\". Try a city, address, or ZIP code.")
        }
        return coordinate
    }

    private func geocodeErrorMessage(for error: CLError) -> String {
        switch error.code {
        case .geocodeFoundNoResult, .geocodeFoundPartialResult:
            return "We couldn't find one of those locations. Try a city, address, or ZIP code."
        case .network:
            return "Location lookup failed. Check your connection and try again."
        default:
            return "We couldn't look up those locations. Please try again."
        }
    }

    // MARK: - Route-aware station discovery

    private func discoverStationsAlongRoute(
        route: MKRoute,
        tankSize: Double,
        mpg: Double,
        currentFuelPercent: Double,
        generation: Int
    ) {
        // Cancel any in-flight discovery so rapid replanning never stacks requests.
        discoveryTask?.cancel()
        analysis = nil
        stationError = nil
        isDiscoveringStations = true

        // Extract Sendable values on the main actor; the planner runs off-main.
        let coordinates = route.polyline.routeCoordinates
        let distanceMeters = route.distance
        let context = RouteFuelContext(
            tankSizeGallons: tankSize,
            mpg: mpg,
            currentFuelPercent: currentFuelPercent,
            targetArrivalReservePercent: targetReservePercent,
            fuelBackupMode: fuelBackupMode
        )

        let reportedKeys = StationReportStore.shared.recentNegativeKeys
        discoveryTask = Task { @MainActor in
            defer {
                // A superseded discovery must not hide a newer request's loading spinner.
                if requestTracker.isCurrent(generation) { isDiscoveringStations = false }
            }
            do {
                let result = try await RouteE85Planner().analyze(
                    routeCoordinates: coordinates,
                    routeDistanceMeters: distanceMeters,
                    context: context,
                    reportedUnavailableKeys: reportedKeys
                )
                guard requestTracker.isCurrent(generation), Task.isCancelled == false else { return }
                analysis = result
                // Backup Gas Stations always starts collapsed after a (re)plan — the user
                // expands it manually via the "Show" row. See showBackupGasStations.
            } catch is CancellationError {
                return
            } catch let plannerError as RouteE85PlannerError {
                guard requestTracker.isCurrent(generation) else { return }
                stationError = plannerError.errorDescription
            } catch {
                guard requestTracker.isCurrent(generation) else { return }
                stationError = "We couldn't load E85 stations for this route. Please try again."
            }
        }
    }

    // MARK: - Backup gas station discovery

    private func discoverBackupGasStations(route: MKRoute, generation: Int) {
        gasDiscoveryTask?.cancel()
        backupGasStations = []
        gasStationError = nil
        isDiscoveringGasStations = true

        let coordinates = route.polyline.routeCoordinates
        let distanceMeters = route.distance

        gasDiscoveryTask = Task { @MainActor in
            defer {
                if requestTracker.isCurrent(generation) { isDiscoveringGasStations = false }
            }
            guard requestTracker.isCurrent(generation), Task.isCancelled == false else { return }
            let stations = await BackupGasStationFinder().find(
                routeCoordinates: coordinates,
                routeDistanceMeters: distanceMeters
            )
            guard requestTracker.isCurrent(generation), Task.isCancelled == false else { return }
            if stations.isEmpty {
                gasStationError = "No backup gas stations found along this route."
            } else {
                backupGasStations = stations
            }
        }
    }

    // MARK: - Gas Only station discovery

    private func discoverGasOnlyStations(
        route: MKRoute,
        tankSize: Double,
        mpg: Double,
        currentFuelPercent: Double,
        generation: Int
    ) {
        gasOnlyDiscoveryTask?.cancel()
        gasOnlyStations = []
        gasOnlyRecommendedStops = []
        gasOnlyStationError = nil
        gasOnlyOutcome = nil
        gasOnlyRisk = nil
        gasOnlyDestinationReserveFraction = nil
        gasOnlyCompleteness = nil
        isDiscoveringGasOnlyStations = true

        let coordinates = route.polyline.routeCoordinates
        let distanceMeters = route.distance
        let fuelPct = currentFuelPercent

        gasOnlyDiscoveryTask = Task { @MainActor in
            defer {
                if requestTracker.isCurrent(generation) { isDiscoveringGasOnlyStations = false }
            }
            guard requestTracker.isCurrent(generation), Task.isCancelled == false else { return }

            let stations = await BackupGasStationFinder().find(
                routeCoordinates: coordinates,
                routeDistanceMeters: distanceMeters
            )

            // Compute the full result from this request's own station snapshot before
            // touching any @State — nothing here is written half-finished. The generation
            // check runs once, immediately before publishing every related field together,
            // so a superseded request can never publish part of a Gas Only result (stations,
            // stops, outcome, risk, reserve, error all move as one atomic step).
            let fuelContext = RouteFuelContext(
                tankSizeGallons: tankSize,
                mpg: mpg,
                currentFuelPercent: fuelPct,
                targetArrivalReservePercent: targetReservePercent,
                fuelBackupMode: fuelBackupMode
            )
            let result = GasOnlyPlanner.plan(
                stations: stations,
                distanceMiles: distanceMeters / 1609.344,
                context: fuelContext
            )

            guard requestTracker.isCurrent(generation), Task.isCancelled == false else { return }

            gasOnlyStations = result.stations
            gasOnlyRecommendedStops = result.stops
            gasOnlyOutcome = result.outcome
            gasOnlyRisk = result.risk
            gasOnlyDestinationReserveFraction = result.destinationReserveFraction
            gasOnlyStationError = result.stationError
            gasOnlyCompleteness = result.completeness
        }
    }

    // MARK: - Navigation handoff actions

    private func openStationInAppleMaps(_ routeStation: RouteStation) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: routeStation.coordinate))
        item.name = routeStation.station.name.isEmpty ? "E85 Station" : routeStation.station.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private func googleMapsURL(to coordinate: CLLocationCoordinate2D) -> URL? {
        URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(coordinate.latitude),\(coordinate.longitude)&travelmode=driving")
    }

    private func wazeURL(to coordinate: CLLocationCoordinate2D) -> URL? {
        URL(string: "https://waze.com/ul?ll=\(coordinate.latitude),\(coordinate.longitude)&navigate=yes")
    }

    private func openInAppleMaps(_ plan: TripPlan) {
        let source = MKMapItem(placemark: MKPlacemark(coordinate: plan.sourceCoordinate))
        source.name = "Start"
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: plan.destinationCoordinate))
        destination.name = "Destination"

        let waypoints = navigationWaypoints
        var items: [MKMapItem] = [source]
        for (index, coord) in waypoints.enumerated() {
            let stop = MKMapItem(placemark: MKPlacemark(coordinate: coord))
            stop.name = waypoints.count == 1 ? "Fuel Stop" : "Fuel Stop \(index + 1)"
            items.append(stop)
        }
        items.append(destination)

        MKMapItem.openMaps(
            with: items,
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        )
    }

    /// Google Maps URL for the main navigation handoff. Includes waypoints when
    /// recommended stops exist. Per-station buttons use the separate `googleMapsURL(to:)`.
    private func navigationGoogleMapsURL(_ plan: TripPlan) -> URL? {
        let waypoints = navigationWaypoints
        let origin = "\(plan.sourceCoordinate.latitude),\(plan.sourceCoordinate.longitude)"
        let dest   = "\(plan.destinationCoordinate.latitude),\(plan.destinationCoordinate.longitude)"
        var urlStr = "https://www.google.com/maps/dir/?api=1&origin=\(origin)&destination=\(dest)&travelmode=driving"
        if waypoints.isEmpty == false {
            let waypointStr = waypoints
                .map { "\($0.latitude),\($0.longitude)" }
                .joined(separator: "|")
            urlStr += "&waypoints=\(waypointStr)"
        }
        return URL(string: urlStr)
    }

    /// Waze URL for the main navigation handoff. Always opens the final destination
    /// because Waze does not reliably support waypoints from URL handoff. When fuel
    /// stops are recommended the user is prompted to add them manually inside Waze.
    /// Per-station buttons use the separate `wazeURL(to:)`.
    private func navigationWazeURL(_ plan: TripPlan) -> URL? {
        let coord = plan.destinationCoordinate
        return URL(string: "https://waze.com/ul?ll=\(coord.latitude),\(coord.longitude)&navigate=yes")
    }

    private func openExternal(_ url: URL?) {
        guard let url else { return }
        openURL(url)
    }

    // MARK: - Formatting

    private func formattedMiles(_ miles: Double) -> String {
        if miles >= 100 { return "\(Int(miles.rounded())) mi" }
        return String(format: "%.1f mi", miles)
    }

    private func formattedTravelTime(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        return "\(minutes) min"
    }

    // MARK: - Feature 1: Detour severity badge

    @ViewBuilder
    private func detourBadge(_ severity: DetourSeverity) -> some View {
        if severity != .onRoute {
            Text(severity.label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(detourBadgeColor(severity))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(detourBadgeColor(severity).opacity(0.12))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(detourBadgeColor(severity).opacity(0.3), lineWidth: 0.5))
        }
    }

    private func detourBadgeColor(_ severity: DetourSeverity) -> Color {
        switch severity {
        case .onRoute:        return AppTheme.Colors.primaryGreen
        case .smallDetour:    return AppTheme.Colors.textSecondary
        case .moderateDetour: return AppTheme.Colors.stationYellow
        case .majorDetour:    return AppTheme.Colors.gasOrange
        }
    }

    private var reportedWarningBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.gasOrange)
            Text("Recently reported unavailable — verify before visiting.")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.gasOrange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.Colors.gasOrange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Feature 3: Report menus

    private func reportMenuE85(stationKey: String, stationName: String) -> some View {
        Menu {
            Button { submitReport(stationKey: stationKey, stationName: stationName, stationType: .e85, reportType: .e85Confirmed) }
                label: { Label("E85 Confirmed", systemImage: "checkmark.circle") }
            Button { submitReport(stationKey: stationKey, stationName: stationName, stationType: .e85, reportType: .e85Unavailable) }
                label: { Label("E85 Unavailable", systemImage: "xmark.circle") }
            Button { submitReport(stationKey: stationKey, stationName: stationName, stationType: .e85, reportType: .pumpOffline) }
                label: { Label("Pump Offline", systemImage: "wrench.and.screwdriver") }
            Button { submitReport(stationKey: stationKey, stationName: stationName, stationType: .e85, reportType: .priceUpdated) }
                label: { Label("Price Updated", systemImage: "dollarsign.circle") }  // TODO: add price input in a future pass
        } label: {
            Image(systemName: "flag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textMuted)
                .padding(7)
                .background(AppTheme.Colors.cardBackground)
                .clipShape(Circle())
                .overlay(Circle().stroke(AppTheme.Colors.borderColor, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func reportMenuGas(stationKey: String, stationName: String) -> some View {
        Menu {
            Button { submitReport(stationKey: stationKey, stationName: stationName, stationType: .backupGas, reportType: .stationOpen) }
                label: { Label("Station Open", systemImage: "checkmark.circle") }
            Button { submitReport(stationKey: stationKey, stationName: stationName, stationType: .backupGas, reportType: .stationUnavailable) }
                label: { Label("Station Unavailable", systemImage: "xmark.circle") }
        } label: {
            Image(systemName: "flag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textMuted)
                .padding(7)
                .background(AppTheme.Colors.cardBackground)
                .clipShape(Circle())
                .overlay(Circle().stroke(AppTheme.Colors.borderColor, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feature 2: Saved trips UI

    private var savedTripsToolbarButton: some View {
        Button {
            AppHaptics.selection()
            showSavedTrips = true
        } label: {
            let count = SavedTripStore.shared.trips.count
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bookmark.fill")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                if count > 0 {
                    Text("\(min(count, 9))")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(3)
                        .background(AppTheme.Colors.stationYellow)
                        .clipShape(Circle())
                        .offset(x: 7, y: -5)
                }
            }
        }
        .accessibilityLabel("Saved Trips, \(SavedTripStore.shared.trips.count) saved")
    }

    private func saveRouteSection(_ plan: TripPlan) -> some View {
        let isPro = SubscriptionManager.shared.isProUser
        let alreadySaved = isCurrentRouteSaved

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Save Route")

            if isPro {
                let isStale = requestTracker.isPlanStale
                Button {
                    guard alreadySaved == false, isStale == false else { return }
                    saveCurrentRoute(plan)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: alreadySaved ? "checkmark.circle.fill" : "bookmark.fill")
                            .font(.subheadline.weight(.semibold))
                        Text(alreadySaved ? "Route Saved" : "Save Route")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(alreadySaved ? AppTheme.Colors.textMuted : AppTheme.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(alreadySaved ? AppTheme.Colors.cardBackground : AppTheme.Colors.primaryGreen.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(alreadySaved ? AppTheme.Colors.borderColor : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(alreadySaved || isStale)
                .opacity(isStale && alreadySaved == false ? 0.45 : 1)
                .accessibilityHint(isStale ? "Plan the route again to save your changed trip settings." : "")

                if isStale {
                    Text("Plan the route again to save your changed trip settings.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                } else if alreadySaved {
                    Text("Open Saved Trips to plan again or delete.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
            } else {
                ProFeatureLockView(
                    icon: "bookmark.fill",
                    title: "Save Route",
                    description: "Save planned routes and quickly plan them again later with one tap."
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Toast overlay

    private var toastOverlay: some View {
        Group {
            if reportToastVisible {
                Text(reportToastMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.78))
                    .clipShape(Capsule())
            }
        }
        .animation(.easeInOut(duration: 0.25), value: reportToastVisible)
    }
}

// MARK: - Route outcome styling

extension RouteOutcome {
    var label: String {
        switch self {
        case .noStopNeeded:            return "No Stop Needed"
        case .reserveStopRecommended:  return "Buffer Stop Recommended"
        case .e85StopRequired:         return "E85 Stop Required"
        case .gasolineBackupAvailable: return "Gasoline Backup Required"
        case .fallbackMayBeNeeded:     return "Fallback May Be Needed"
        case .e85DetourAvoided:        return "E85 Detour Avoided"
        case .gasolineOnly:            return "Gasoline Route"
        case .gasStopRecommended:      return "Gas Stop Recommended"
        case .gasFuelStopNeeded:       return "Fuel Stop Needed"
        case .gasolineFallbackRoute:   return "Destination Reachable on Gasoline Backup"
        }
    }

    var message: String {
        switch self {
        case .noStopNeeded:
            return "Destination is reachable with your arrival buffer target intact."
        case .reserveStopRecommended:
            return "Reachable, but below your buffer target. An E85 stop is recommended to meet it."
        case .e85StopRequired:
            return "Destination isn't reachable without refueling. Plan an E85 stop along the way."
        case .gasolineBackupAvailable:
            return "No reachable E85 plan meets your arrival buffer target. Gasoline backup is required to complete this route safely."
        case .fallbackMayBeNeeded:
            return "No reachable E85 plan meets your target. This route may require gasoline, a different route, or a different stop."
        case .e85DetourAvoided:
            return "An E85 stop was available, but it required a significant detour. Since gas backup is allowed, use an on-route gas station if needed."
        case .gasolineOnly:
            return "This trip is being planned using pump gasoline only. No fuel stop is required."
        case .gasStopRecommended:
            return "This trip is being planned using pump gasoline. Fuel stops are recommended to meet your range or arrival buffer target."
        case .gasFuelStopNeeded:
            return "This trip may require a fuel stop, but no suitable gas station was found along the route."
        case .gasolineFallbackRoute:
            return "Your selected ethanol plan can't complete this route or meet the arrival buffer. The planner switched to a verified gasoline-backup route to complete the trip safely."
        }
    }

    var icon: String {
        switch self {
        case .noStopNeeded:            return "checkmark.seal.fill"
        case .reserveStopRecommended:  return "exclamationmark.circle.fill"
        case .e85StopRequired:         return "fuelpump.circle.fill"
        case .gasolineBackupAvailable: return "fuelpump.and.filter"
        case .fallbackMayBeNeeded:     return "exclamationmark.triangle.fill"
        case .e85DetourAvoided:        return "arrow.triangle.turn.up.right.diamond.fill"
        case .gasolineOnly:            return "car.fill"
        case .gasStopRecommended:      return "fuelpump.fill"
        case .gasFuelStopNeeded:       return "exclamationmark.triangle.fill"
        case .gasolineFallbackRoute:   return "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .noStopNeeded:            return AppTheme.Colors.primaryGreen
        case .reserveStopRecommended:  return AppTheme.Colors.stationYellow
        case .e85StopRequired:         return AppTheme.Colors.stationYellow
        case .gasolineBackupAvailable: return AppTheme.Colors.stationYellow
        case .fallbackMayBeNeeded:     return AppTheme.Colors.warningRed
        case .e85DetourAvoided:        return AppTheme.Colors.stationYellow
        case .gasolineOnly:            return AppTheme.Colors.primaryGreen
        case .gasStopRecommended:      return AppTheme.Colors.stationYellow
        case .gasFuelStopNeeded:       return AppTheme.Colors.warningRed
        case .gasolineFallbackRoute:   return AppTheme.Colors.stationYellow
        }
    }

    var foreground: Color {
        switch self {
        case .noStopNeeded:            return AppTheme.Colors.primaryGreen
        case .reserveStopRecommended:  return AppTheme.Colors.gasOrange
        case .e85StopRequired:         return AppTheme.Colors.gasOrange
        case .gasolineBackupAvailable: return AppTheme.Colors.gasOrange
        case .fallbackMayBeNeeded:     return AppTheme.Colors.warningRed
        case .e85DetourAvoided:        return AppTheme.Colors.gasOrange
        case .gasolineOnly:            return AppTheme.Colors.primaryGreen
        case .gasStopRecommended:      return AppTheme.Colors.gasOrange
        case .gasFuelStopNeeded:       return AppTheme.Colors.warningRed
        case .gasolineFallbackRoute:   return AppTheme.Colors.gasOrange
        }
    }
}

// MARK: - Reserve classification styling

extension ReserveClass {
    var label: String {
        switch self {
        case .safe: return "Safe"
        case .caution: return "Caution"
        case .risky: return "Risky"
        }
    }

    var icon: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .caution: return "exclamationmark.circle.fill"
        case .risky: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .safe: return AppTheme.Colors.primaryGreen
        case .caution: return AppTheme.Colors.stationYellow
        case .risky: return AppTheme.Colors.warningRed
        }
    }

    var foreground: Color {
        switch self {
        case .safe: return AppTheme.Colors.primaryGreen
        case .caution: return AppTheme.Colors.gasOrange
        case .risky: return AppTheme.Colors.warningRed
        }
    }
}

private struct ReserveBadge: View {
    let reserveClass: ReserveClass
    /// Whether the recommended stop is part of a plan that safely completes the whole
    /// route (E85 alone, destination reached, target buffer met). When false, a
    /// technically-comfortable arrival at THIS stop still shouldn't read as "Safe" — the
    /// trip as a whole isn't. Defaults to true so callers outside the E85 stop-planning
    /// flow (e.g. Gas Only stops) keep their existing "Safe" wording unchanged.
    var routeIsSafe: Bool = true

    private var displayLabel: String {
        (reserveClass == .safe && routeIsSafe == false) ? "Reachable" : reserveClass.label
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: reserveClass.icon)
                .font(.caption2.weight(.bold))
            Text(displayLabel)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(reserveClass.foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(reserveClass.tint.opacity(0.18))
        .overlay(Capsule().stroke(reserveClass.tint.opacity(0.5), lineWidth: 1))
        .clipShape(Capsule())
    }
}

// MARK: - Route risk badge

private struct RouteRiskBadge: View {
    let risk: TripPlan.RouteRisk
    /// Overrides the displayed text (e.g. "Reachable with Gas") while keeping the
    /// underlying risk's icon/tint — used when a verified gasoline-backup route is active
    /// and a plain "Medium Risk" label would misleadingly imply the active route is unsafe.
    var labelOverride: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: risk.icon)
                .font(.caption2.weight(.bold))
            Text(labelOverride ?? risk.label)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(risk.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(risk.tint.opacity(0.18))
        .overlay(Capsule().stroke(risk.tint.opacity(0.5), lineWidth: 1))
        .clipShape(Capsule())
    }
}

// MARK: - Trip plan model + computation

struct TripPlan {
    enum RouteRisk {
        case low, medium, high

        var label: String {
            switch self {
            case .low: return "Low Risk"
            case .medium: return "Medium Risk"
            case .high: return "High Risk"
            }
        }

        var icon: String {
            switch self {
            case .low: return "checkmark.circle.fill"
            case .medium: return "exclamationmark.circle.fill"
            case .high: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .low: return AppTheme.Colors.primaryGreen
            case .medium: return AppTheme.Colors.stationYellow
            case .high: return AppTheme.Colors.warningRed
            }
        }

        var foreground: Color {
            switch self {
            case .low: return AppTheme.Colors.primaryGreen
            case .medium: return AppTheme.Colors.gasOrange
            case .high: return AppTheme.Colors.warningRed
            }
        }
    }

    let route: MKRoute
    let sourceCoordinate: CLLocationCoordinate2D
    let destinationCoordinate: CLLocationCoordinate2D
    let distanceMiles: Double
    let travelTime: TimeInterval
    let fuelNeededGallons: Double
    let fullTankRangeMiles: Double
    let currentRangeMiles: Double
    let reachableWithoutStops: Bool
    let estimatedStops: Int
    let risk: RouteRisk

    static func make(
        route: MKRoute,
        source: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        tankSizeGallons: Double,
        mpg: Double,
        currentFuelPercent: Double
    ) -> TripPlan {
        let distanceMiles = route.distance / 1609.344
        let currentGallons = tankSizeGallons * (currentFuelPercent / 100)
        let currentRange = currentGallons * mpg
        let fullTankRange = tankSizeGallons * mpg
        let fuelNeeded = mpg > 0 ? distanceMiles / mpg : 0
        let reachable = currentRange >= distanceMiles

        // Stops: distance the current tank can't cover, divided by a usable refuel range
        // (refuel to full, run down to a ~10% reserve before the next stop).
        let stops: Int
        if reachable {
            stops = 0
        } else {
            let usablePerStop = max(fullTankRange * 0.9, 1)
            let deficit = distanceMiles - currentRange
            stops = max(1, Int(ceil(deficit / usablePerStop)))
        }

        let risk: RouteRisk
        if stops >= 2 {
            risk = .high
        } else if stops == 1 {
            risk = .medium
        } else {
            // Reachable: comfortable margin → low, thin buffer → medium.
            let margin = distanceMiles > 0 ? (currentRange - distanceMiles) / distanceMiles : 1
            risk = margin < 0.1 ? .medium : .low
        }

        return TripPlan(
            route: route,
            sourceCoordinate: source,
            destinationCoordinate: destination,
            distanceMiles: distanceMiles,
            travelTime: route.expectedTravelTime,
            fuelNeededGallons: fuelNeeded,
            fullTankRangeMiles: fullTankRange,
            currentRangeMiles: currentRange,
            reachableWithoutStops: reachable,
            estimatedStops: stops,
            risk: risk
        )
    }

    // Web URLs (no custom-scheme entitlement needed; redirect to the app if installed).
    var googleMapsURL: URL? {
        URL(string: "https://www.google.com/maps/dir/?api=1&origin=\(sourceCoordinate.latitude),\(sourceCoordinate.longitude)&destination=\(destinationCoordinate.latitude),\(destinationCoordinate.longitude)&travelmode=driving")
    }

    var wazeURL: URL? {
        // Waze navigates to a destination from the user's current position.
        URL(string: "https://waze.com/ul?ll=\(destinationCoordinate.latitude),\(destinationCoordinate.longitude)&navigate=yes")
    }
}

/// Shared header for Pro feature shells — large icon, title, and a short description.
struct ProShellHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(.title, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                ProBadge()
            }

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Saved Trips List (Feature 2)

private struct SavedTripsListView: View {
    let onPlanAgain: (SavedTrip) -> Void

    @Environment(\.dismiss) private var dismiss

    private var store: SavedTripStore { SavedTripStore.shared }

    var body: some View {
        Group {
            if store.trips.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.trips) { trip in
                            savedTripCard(trip)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .navigationTitle("Saved Trips")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bookmark.slash")
                .font(.system(size: 44))
                .foregroundStyle(AppTheme.Colors.textMuted)
            Text("No Saved Trips")
                .font(.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Text("Plan a route and tap Save Route to save it here.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func savedTripCard(_ trip: SavedTrip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Origin → Destination header
            HStack(spacing: 6) {
                Image(systemName: "location.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
                Text(trip.originText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                Text(trip.destinationText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Metadata pills — two fixed rows to avoid width overflows.
            HStack(spacing: 6) {
                tripPill(icon: "ruler.fill", text: formattedMiles(trip.totalDistanceMiles))
                if let risk = trip.routeRisk {
                    riskPill(risk)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                tripPill(icon: "target", text: "\(Int(trip.targetArrivalReservePercent.rounded()))% buffer")
                tripPill(
                    icon: "fuelpump.and.filter",
                    text: trip.fuelBackupMode == .gasBackupAllowed ? "Gas backup" : "E85 required"
                )
                tripPill(icon: "calendar", text: formattedDate(trip.savedDate))
                Spacer(minLength: 0)
            }

            // Actions
            HStack(spacing: 8) {
                Button {
                    onPlanAgain(trip)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption.weight(.bold))
                        Text("Plan Again")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(AppTheme.Colors.primaryGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    SavedTripStore.shared.delete(trip)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                            .font(.caption.weight(.bold))
                        Text("Delete")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(AppTheme.Colors.warningRed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(AppTheme.Colors.warningRed.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppTheme.Colors.warningRed.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func tripPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textMuted)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(AppTheme.Colors.borderColor, lineWidth: 1))
    }

    private func riskPill(_ risk: TripPlan.RouteRisk) -> some View {
        HStack(spacing: 4) {
            Image(systemName: risk.icon)
                .font(.caption2.weight(.bold))
            Text(risk.label)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(risk.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(risk.tint.opacity(0.15))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(risk.tint.opacity(0.4), lineWidth: 1))
    }

    private func formattedMiles(_ miles: Double) -> String {
        miles >= 100 ? "\(Int(miles.rounded())) mi" : String(format: "%.1f mi", miles)
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

// MARK: - Full-screen interactive route map

/// Full-screen map sheet with free pan/zoom, Fit Route, and Done controls.
/// Pin count uses the same 20-pin cap as the inline map to avoid MapKit Metal issues.
private struct FullRouteMapView: View {
    let plan: TripPlan
    let mapStations: [RouteStation]
    let mapGasStations: [BackupGasStation]
    let gasOnlyStops: [GasOnlyStop]
    let recommendedStationIDs: Set<String>
    let displayRisk: TripPlan.RouteRisk?
    var displayRiskLabelOverride: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            Map(position: $cameraPosition) {
                Marker("Start", systemImage: "flag.fill", coordinate: plan.sourceCoordinate)
                    .tint(AppTheme.Colors.primaryGreen)
                Marker("End", systemImage: "flag.checkered", coordinate: plan.destinationCoordinate)
                    .tint(AppTheme.Colors.stationYellow)
                MapPolyline(plan.route.polyline)
                    .stroke(AppTheme.Colors.primaryGreen, lineWidth: 4)

                ForEach(mapStations) { routeStation in
                    Annotation(routeStation.station.name, coordinate: routeStation.coordinate) {
                        if recommendedStationIDs.contains(routeStation.id) {
                            Image(systemName: "star.circle.fill")
                                .font(.title2)
                                .foregroundStyle(AppTheme.Colors.primaryGreen)
                                .background(Circle().fill(.black.opacity(0.35)))
                                .accessibilityLabel("Recommended stop: \(routeStation.station.name)")
                        } else {
                            Image(systemName: "fuelpump.circle.fill")
                                .font(.title3)
                                .foregroundStyle(AppTheme.Colors.stationYellow)
                                .background(Circle().fill(.black.opacity(0.25)))
                                .accessibilityLabel("E85 station: \(routeStation.station.name)")
                        }
                    }
                }

                ForEach(mapGasStations) { gasStation in
                    Annotation(gasStation.name, coordinate: gasStation.coordinate) {
                        Image(systemName: "car.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .padding(4)
                            .background(Circle().fill(AppTheme.Colors.cardBackground.opacity(0.9)))
                            .overlay(Circle().stroke(AppTheme.Colors.borderColor, lineWidth: 0.5))
                            .accessibilityLabel("Gas station: \(gasStation.name)")
                    }
                }

                // Gas Only recommended fuel stops.
                ForEach(gasOnlyStops) { stop in
                    Annotation(stop.station.name, coordinate: stop.station.coordinate) {
                        Image(systemName: "fuelpump.fill")
                            .font(.title3)
                            .foregroundStyle(AppTheme.Colors.gasOrange)
                            .background(Circle().fill(.black.opacity(0.25)))
                            .accessibilityLabel("Fuel stop: \(stop.station.name)")
                    }
                }
            }
            .mapStyle(.standard)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .topTrailing) {
                if let risk = displayRisk {
                    RouteRiskBadge(risk: risk, labelOverride: displayRiskLabelOverride)
                        .padding(.top, 56)
                        .padding(.trailing, 16)
                }
            }
            .navigationTitle("Route Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        cameraPosition = .automatic
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "viewfinder")
                                .font(.caption.weight(.bold))
                            Text("Fit Route")
                                .font(.subheadline)
                        }
                    }
                    .accessibilityLabel("Fit route to screen")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        TripPlannerView()
    }
}

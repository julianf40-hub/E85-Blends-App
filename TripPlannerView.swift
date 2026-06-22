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

    // MARK: - Feature 2: Saved trips
    @State private var showSavedTrips = false

    // MARK: - Full-screen route map
    @State private var showFullMap = false

    // MARK: - Feature 3: Report toast
    @State private var reportToastMessage = ""
    @State private var reportToastVisible = false

    /// Risk shown on the map badge: refined route-aware risk once stations load, else the
    /// preliminary range-based risk.
    private var displayRisk: TripPlan.RouteRisk? {
        analysis?.risk ?? plan?.risk
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

    /// The backup gas stations shown in the UI list — sorted by proximity to the route, then
    /// progress along the route, then name, and capped at maxBackupGasCards. Full discovery
    /// results are preserved in `backupGasStations` for map-pin sampling.
    private var displayedBackupGasStations: [BackupGasStation] {
        let sorted = backupGasStations.sorted {
            if $0.offRouteMiles != $1.offRouteMiles { return $0.offRouteMiles < $1.offRouteMiles }
            if $0.distanceAlongRouteMiles != $1.distanceAlongRouteMiles { return $0.distanceAlongRouteMiles < $1.distanceAlongRouteMiles }
            return $0.name < $1.name
        }
        return Array(sorted.prefix(Self.maxBackupGasCards))
    }

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case origin, destination, tankSize, mpg
    }

    var body: some View {
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
                    routeMapCard(plan)
                    tripSummaryCard(plan)
                    stopsAlongRouteSection
                    backupGasSection
                    navigationHandoffCard(plan)
                    if isDiscoveringStations == false, analysis != nil {
                        saveRouteSection(plan)
                    }
                }
            }
            // padding BEFORE frame so the frame constrains the padded content to the
            // scroll view width. Reversing this (frame then padding) can report a width
            // wider than the scroll view when any child exceeds the layout proposal,
            // causing the page to shift horizontally.
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Vertical-only bounce prevents the page from shifting left/right.
        // Note: .scrollDismissesKeyboard is intentionally absent — on physical iPhone
        // it interprets rapid key-repeat layout re-measurements as scroll events,
        // triggering keyboard dismissal mid-delete, which flips focusedField and
        // causes a UIKit safeAreaInset height-oscillation crash.
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .safeAreaInset(edge: .bottom) {
            planBottomBar
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .navigationTitle("Trip Planner")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneToolbar()
        .dismissKeyboardOnTap()
        .onAppear(perform: prefillFromActiveVehicleIfNeeded)
        .onDisappear {
            planTask?.cancel()
            discoveryTask?.cancel()
            gasDiscoveryTask?.cancel()
        }
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
                    displayRisk: displayRisk
                )
            }
        }
        .overlay(alignment: .bottom) {
            toastOverlay
                .padding(.bottom, 90)
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

            // Target ethanol blend
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Target Ethanol Blend", icon: "leaf.fill")
                HStack(spacing: 10) {
                    ForEach(Self.blendOptions, id: \.self) { blend in
                        blendChip(blend)
                    }
                }
            }

            arrivalReserveSection

            fuelBackupSection
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
        let isSelected = abs(targetBlend - blend) < 0.5
        return Button {
            targetBlend = blend
            AppHaptics.selection()
        } label: {
            Text("E\(Int(blend))")
                .font(.subheadline.weight(.semibold))
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
    }

    // MARK: - Arrival reserve target

    private static let reservePresets: [(label: String, sub: String, value: Double)] = [
        ("10%", "Minimum", 10),
        ("20%", "Safer", 20),
        ("50%", "Half Tank", 50)
    ]

    private var arrivalReserveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Arrival Reserve", icon: "gauge.with.dots.needle.bottom.50percent")

            Text("Choose how much fuel you want left when you arrive.")
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
                    RouteRiskBadge(risk: displayRisk)
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
                            ForEach(mapStations) { routeStation in
                                Annotation(routeStation.station.name, coordinate: routeStation.coordinate) {
                                    Image(systemName: "fuelpump.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(AppTheme.Colors.stationYellow)
                                        .background(Circle().fill(.black.opacity(0.25)))
                                        .accessibilityLabel("E85 station \(routeStation.station.name)")
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

            if let analysis, isDiscoveringStations == false {
                outcomeBanner(analysis.outcome)
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
                    label: "Arrival reserve target",
                    value: "\(Int(targetReservePercent.rounded()))%"
                )
                summaryDivider
                summaryRow(
                    icon: "fuelpump.and.filter",
                    label: "Fuel backup",
                    value: fuelBackupMode == .gasBackupAllowed ? "Gas allowed" : "E85 required"
                )
                summaryDivider
                summaryRow(
                    icon: "drop.fill",
                    label: "Estimated arrival reserve",
                    value: arrivalReserveText
                )
                summaryDivider
                summaryRow(
                    icon: "fuelpump.circle.fill",
                    label: "Estimated E85 stops",
                    value: isDiscoveringStations ? "…" : "\(estimatedStops)"
                )
                summaryDivider
                summaryRow(
                    icon: "drop.triangle.fill",
                    label: "Lowest arrival reserve",
                    value: lowestReserve.map { "\(Int(($0 * 100).rounded()))%" } ?? (isDiscoveringStations ? "…" : "—")
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
                    if let analysis, isDiscoveringStations == false {
                        Text(analysis.outcome.label)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(analysis.outcome.foreground)
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
                        RouteRiskBadge(risk: displayRisk)
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

            Text("Estimates assume \(Int(currentFuelPercent.rounded()))% of a \(tankSizeText.isEmpty ? "—" : tankSizeText)-gal tank at \(mpgText.isEmpty ? "—" : mpgText) MPG. Real-world range varies with driving and conditions.")
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
        guard let fraction = analysis?.noStopReserveFraction else {
            return isDiscoveringStations ? "…" : "—"
        }
        if fraction < 0 { return "Unreachable" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Outcome-aware banner shown once station discovery completes — replaces the preliminary
    /// reachability row with a message tied to the driver's reserve target.
    private func outcomeBanner(_ outcome: RouteOutcome) -> some View {
        HStack(spacing: 10) {
            Image(systemName: outcome.icon)
                .font(.title3)
                .foregroundStyle(outcome.foreground)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(outcome.message)
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
            SectionHeader(title: "E85 Stops Along Route")

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

        if analysis.recommendedStops.isEmpty {
            // No stop in the plan — the message depends on the outcome relative to the target
            // and the fuel-backup mode.
            switch analysis.outcome {
            case .noStopNeeded:
                stationsMessageCard(
                    icon: "checkmark.seal.fill",
                    tint: AppTheme.Colors.primaryGreen,
                    title: "No E85 Stop Needed",
                    message: "You can reach your destination with your target reserve intact. \(stationsFound) if you'd like to top off."
                )
            case .reserveStopRecommended:
                stationsMessageCard(
                    icon: "exclamationmark.circle.fill",
                    tint: AppTheme.Colors.gasOrange,
                    title: "Below Your Reserve Target",
                    message: "Reachable, but below your reserve target. No E85 station along this route can raise your arrival reserve to \(Int(targetReservePercent.rounded()))%. \(stationsFound)."
                )
            case .gasolineBackupAvailable:
                stationsMessageCard(
                    icon: "fuelpump.and.filter",
                    tint: AppTheme.Colors.stationYellow,
                    title: "Gasoline Backup Available",
                    message: "No safe E85 plan found. Continue with gasoline backup if needed. \(stationsFound)."
                )
            case .fallbackMayBeNeeded:
                stationsMessageCard(
                    icon: "exclamationmark.triangle.fill",
                    tint: AppTheme.Colors.warningRed,
                    title: "Fallback May Be Needed",
                    message: "No safe E85 plan found for this route and reserve target. \(stationsFound)."
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
                 : "Backup gas stations available along this route.")
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
                     : "Use backup gas stations only if E85 is unavailable or your reserve target cannot be met on E85.")
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

                // Gas Backup badge
                Text("Gas Backup")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(AppTheme.Colors.cardBackground)
                    .overlay(Capsule().stroke(AppTheme.Colors.borderColor, lineWidth: 1))
                    .clipShape(Capsule())
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
                gasHandoffButton(title: "Apple Maps", icon: "applelogo") {
                    openGasStationInAppleMaps(station)
                }
                gasHandoffButton(title: "Google", icon: "globe") {
                    openExternal(googleMapsURL(to: station.coordinate))
                }
                gasHandoffButton(title: "Waze", icon: "car.fill") {
                    openExternal(wazeURL(to: station.coordinate))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.borderColor.opacity(0.7), lineWidth: 1)
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

    private func gasHandoffButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
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
            return "\(found) These are the best E85 stops we found, but they don't fully meet your \(target)% reserve target — continue with gasoline backup if needed."
        case .fallbackMayBeNeeded:
            return "\(found) These E85 stops don't fully meet your \(target)% reserve target. This route may require gasoline, a different route, or a different stop."
        case .e85DetourAvoided:
            return "\(found) These low-detour E85 stops are recommended for the segments they cover. Use an on-route gas station for any remaining segments — detour stops were skipped."
        default:
            return "\(found) Recommended stops maximize progress while keeping your arrival reserve at or above \(target)%."
        }
    }

    private func recommendedStopCard(_ stop: RecommendedStop, number: Int) -> some View {
        let station = stop.station.station
        let cityState = [station.city, station.state].filter { $0.isEmpty == false }.joined(separator: ", ")

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

                ReserveBadge(reserveClass: stop.arrivalClass)
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
                    Text("Recommended to meet your arrival reserve.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                    label: "Arrive reserve"
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
                stationHandoffButton(title: "Apple Maps", icon: "applelogo") {
                    openStationInAppleMaps(stop.station)
                }
                stationHandoffButton(title: "Google", icon: "globe") {
                    openExternal(googleMapsURL(to: stop.station.coordinate))
                }
                stationHandoffButton(title: "Waze", icon: "car.fill") {
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

    private func stationHandoffButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
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

    // MARK: - Navigation handoff

    private func navigationHandoffCard(_ plan: TripPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Open Directions In")
            HStack(spacing: 10) {
                handoffButton(title: "Apple Maps", icon: "applelogo") {
                    openInAppleMaps(plan)
                }
                handoffButton(title: "Google Maps", icon: "globe") {
                    openExternal(plan.googleMapsURL)
                }
                handoffButton(title: "Waze", icon: "car.fill") {
                    openExternal(plan.wazeURL)
                }
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

    private func handoffButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
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

    /// Tears down the route results (used on a failed plan). Removing the map here is fine —
    /// the next successful plan re-inserts it once, with the deferred/size-gated guard.
    private func clearRouteResults() {
        plan = nil
        analysis = nil
        showRouteMap = false
        backupGasStations = []
        gasStationError = nil
        isDiscoveringGasStations = false
        showBackupGasStations = false
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
        targetBlend = nearestBlendOption(to: trip.targetBlendPercent)
        currentFuelPercent = trip.currentFuelLevelPercent
        targetReservePercent = trip.targetArrivalReservePercent
        fuelBackupMode = trip.fuelBackupMode
        clearRouteResults()
        errorMessage = nil
        stationError = nil
    }

    private func saveCurrentRoute(_ plan: TripPlan) {
        guard let tankSize = tankSizeValue, let mpg = mpgValue else { return }
        let risk = analysis?.risk ?? plan.risk
        let outcome = analysis?.outcome
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
            estimatedStopsCount: analysis?.estimatedStops ?? plan.estimatedStops,
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

        planTask?.cancel()
        discoveryTask?.cancel()
        gasDiscoveryTask?.cancel()
        isPlanning = true
        errorMessage = nil
        analysis = nil
        stationError = nil
        isDiscoveringStations = false
        backupGasStations = []
        gasStationError = nil
        isDiscoveringGasStations = false
        showBackupGasStations = false
        // NOTE: we intentionally do NOT clear `plan`/`showRouteMap` here. Keeping the existing
        // route map alive across a replan lets SwiftUI update the live MapKit view's content
        // instead of tearing it down and re-instantiating it — the re-instantiation is what
        // triggered MapKit's 0×0-drawable Metal assertion on dense routes. On a failed plan we
        // clear them in the catch blocks below.
        AppHaptics.impact()

        let fuelPercent = currentFuelPercent

        planTask = Task { @MainActor in
            defer { isPlanning = false }
            do {
                let source = try await geocode(originQuery, label: "starting location")
                let dest = try await geocode(destinationQuery, label: "destination")

                let request = MKDirections.Request()
                request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
                request.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
                request.transportType = .automobile

                let response = try await MKDirections(request: request).calculate()
                guard Task.isCancelled == false else { return }
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
                        showRouteMap = true
                    }
                }
                // Replan: map already live, cameraPosition stays .automatic.
                // MapKit re-fits to new route content automatically — no camera
                // transition needed and no MSAA crash risk.

                // Kick off route-aware E85 station discovery (Phase 2).
                discoverStationsAlongRoute(
                    route: route,
                    tankSize: tankSize,
                    mpg: mpg,
                    currentFuelPercent: fuelPercent
                )

                // Backup gas discovery runs in parallel, only when gas backup is allowed.
                if fuelBackupMode == .gasBackupAllowed {
                    discoverBackupGasStations(route: route)
                }
            } catch is CancellationError {
                return
            } catch let clError as CLError {
                clearRouteResults()
                errorMessage = geocodeErrorMessage(for: clError)
            } catch let geocodeError as GeocodeFailure {
                clearRouteResults()
                errorMessage = geocodeError.message
            } catch let urlError as URLError where urlError.code == .notConnectedToInternet {
                clearRouteResults()
                errorMessage = "You're offline. Connect to the internet to plan a route."
            } catch {
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
        currentFuelPercent: Double
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
            defer { isDiscoveringStations = false }
            do {
                let result = try await RouteE85Planner().analyze(
                    routeCoordinates: coordinates,
                    routeDistanceMeters: distanceMeters,
                    context: context,
                    reportedUnavailableKeys: reportedKeys
                )
                guard Task.isCancelled == false else { return }
                analysis = result
                // Auto-expand the backup gas section when E85 can't satisfy the trip
                // or when a high-detour E85 stop was intentionally skipped.
                if fuelBackupMode == .gasBackupAllowed {
                    switch result.outcome {
                    case .gasolineBackupAvailable, .fallbackMayBeNeeded, .e85DetourAvoided:
                        showBackupGasStations = true
                    default:
                        break
                    }
                }
            } catch is CancellationError {
                return
            } catch let plannerError as RouteE85PlannerError {
                stationError = plannerError.errorDescription
            } catch {
                stationError = "We couldn't load E85 stations for this route. Please try again."
            }
        }
    }

    // MARK: - Backup gas station discovery

    private func discoverBackupGasStations(route: MKRoute) {
        gasDiscoveryTask?.cancel()
        backupGasStations = []
        gasStationError = nil
        isDiscoveringGasStations = true

        let coordinates = route.polyline.routeCoordinates
        let distanceMeters = route.distance

        gasDiscoveryTask = Task { @MainActor in
            defer { isDiscoveringGasStations = false }
            guard Task.isCancelled == false else { return }
            let stations = await BackupGasStationFinder().find(
                routeCoordinates: coordinates,
                routeDistanceMeters: distanceMeters
            )
            guard Task.isCancelled == false else { return }
            if stations.isEmpty {
                gasStationError = "No backup gas stations found along this route."
            } else {
                backupGasStations = stations
            }
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
        MKMapItem.openMaps(
            with: [source, destination],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        )
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
                Button {
                    guard alreadySaved == false else { return }
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
                .disabled(alreadySaved)

                if alreadySaved {
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
        case .reserveStopRecommended:  return "Reserve Stop Recommended"
        case .e85StopRequired:         return "E85 Stop Required"
        case .gasolineBackupAvailable: return "Gasoline Backup Available"
        case .fallbackMayBeNeeded:     return "Fallback May Be Needed"
        case .e85DetourAvoided:        return "E85 Detour Avoided"
        }
    }

    var message: String {
        switch self {
        case .noStopNeeded:
            return "Destination is reachable with your arrival reserve target intact."
        case .reserveStopRecommended:
            return "Reachable, but below your reserve target. An E85 stop is recommended to meet it."
        case .e85StopRequired:
            return "Destination isn't reachable without refueling. Plan an E85 stop along the way."
        case .gasolineBackupAvailable:
            return "No reachable E85 plan meets your arrival reserve target, but this vehicle can continue using gasoline if needed."
        case .fallbackMayBeNeeded:
            return "No reachable E85 plan meets your target. This route may require gasoline, a different route, or a different stop."
        case .e85DetourAvoided:
            return "An E85 stop was available, but it required a significant detour. Since gas backup is allowed, use an on-route gas station if needed."
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

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: reserveClass.icon)
                .font(.caption2.weight(.bold))
            Text(reserveClass.label)
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

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: risk.icon)
                .font(.caption2.weight(.bold))
            Text(risk.label)
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
                tripPill(icon: "target", text: "\(Int(trip.targetArrivalReservePercent.rounded()))% reserve")
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
    let displayRisk: TripPlan.RouteRisk?

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
                        Image(systemName: "fuelpump.circle.fill")
                            .font(.title3)
                            .foregroundStyle(AppTheme.Colors.stationYellow)
                            .background(Circle().fill(.black.opacity(0.25)))
                            .accessibilityLabel("E85 station: \(routeStation.station.name)")
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
            }
            .mapStyle(.standard)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .topTrailing) {
                if let risk = displayRisk {
                    RouteRiskBadge(risk: risk)
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

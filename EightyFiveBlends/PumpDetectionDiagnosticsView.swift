//
//  PumpDetectionDiagnosticsView.swift
//  EightyFiveBlends
//

import SwiftUI
import CoreLocation

/// Read-only, on-device troubleshooting sheet for Automatic Pump Detection. Compiled into
/// every build configuration — Debug, Internal, AND production Release — because pump
/// detection needs to be diagnosable against the production App Store build, not just an
/// Internal TestFlight build. It has no persistent, discoverable entry point for ordinary
/// users: StationsView only presents it after a discreet ~2s long-press on the "Automatic
/// Pump Detection" section header (see StationsView.automaticPumpDetectionSection).
///
/// Strictly read-only and local:
///  - never writes any pump-detection/location state, only reads it
///  - never persists anything of its own
///  - never transmits anything over the network, no analytics, no logging service
///  - never displays raw latitude/longitude, and never any history of past locations —
///    only the single current fix's derived distance/accuracy figures, exactly like the
///    inline diagnostics this view replaces
///  - reuses the app's single StationLocationManager/AutomaticPumpDetectionService
///    instances (via the existing environment injection) — never creates its own
///    CLLocationManager, never starts a new polling loop; it observes whatever refresh
///    already happened via Calculator's existing ~20s foreground loop or Stations' own
///    location requests, plus a single one-shot request on appear (see .onAppear below).
struct PumpDetectionDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(StationLocationManager.self) private var locationManager
    @Environment(AutomaticPumpDetectionService.self) private var pumpDetectionService

    let savedStations: [FuelStation]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Local, read-only troubleshooting for Automatic Pump Detection. Nothing shown here is stored, logged, or sent anywhere — this just reads current on-device state to help explain why a prompt or notification did or didn't fire.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    group("Detector") {
                        row("Automatic detection", pumpDetectionService.isEnabled ? "Enabled" : "Disabled")
                        row("Detector status", "\(pumpDetectionService.status)")
                        row("Notification auth", "\(pumpDetectionService.notificationAuthorizationStatus)")
                        row("Location auth", "\(locationManager.authorizationStatus)")
                    }

                    group("Stations") {
                        row("Saved stations", "\(savedStations.count)")
                        row("Monitored stations", "\(pumpDetectionService.monitoredStationCount)")
                        row("Monitored regions", "\(locationManager.monitoredRegionIdentifiers.count)")
                        row("Nearest saved station", nearestStationNameText)
                        row("Distance to nearest", nearestStationDistanceText)
                    }

                    group("Current fix") {
                        row("Last location age", fixAgeText)
                        row("Horizontal accuracy", accuracyText)
                        row("Proximity gate", proximityGateText)
                    }

                    group("Foreground (Calculator)") {
                        row("Foreground refresh", pumpDetectionService.isForegroundRefreshActive ? "Active (~20s interval)" : "Inactive")
                        row("Visit suppression", visitSuppressionText)
                    }

                    group("Background (last event)") {
                        row("Event", backgroundEventText)
                        row("Station", backgroundEventStationText)
                        row("Detail", backgroundEventDetailText)
                        row("When", backgroundEventAgeText)
                    }

                    group("Thresholds") {
                        row("Entry radius", "\(Int(PumpProximity.atPumpEntryRadiusMeters))m")
                        row("Exit/reset radius", "\(Int(PumpProximity.atPumpExitRadiusMeters))m")
                        row("Max accuracy", "\(Int(PumpProximity.maximumPumpModeLocationAccuracyMeters))m")
                    }
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationTitle("Pump Detection Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.Colors.charcoal, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // A single one-shot request for a fresh fix, mirroring the same pattern
            // CalculatorView/StationsView already use on appear — not a new recurring poll,
            // and not a second location manager (StationLocationManager is the one shared
            // instance the whole app uses).
            if locationManager.isAuthorizedForUserLocation {
                locationManager.requestUserLocation()
            }
        }
    }

    // MARK: - Row/group helpers

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.0)
                .foregroundStyle(AppTheme.Colors.textMuted)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .background(AppTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textMuted)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Derived diagnostic text

    /// Nearest saved station to the last known fix — mirrors CalculatorView's own
    /// `nearestSavedStation` (including its optional-coordinate unwrap, since FuelStation's
    /// latitude/longitude are `Double?`), so this reflects what the foreground path itself
    /// would see, independent of the background service's own capped monitored-region set.
    private var nearestCandidate: (station: FuelStation, distance: CLLocationDistance)? {
        guard let coordinate = locationManager.latestCoordinate else { return nil }
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

    private var nearestStationNameText: String {
        guard let candidate = nearestCandidate else {
            return savedStations.isEmpty ? "No saved stations" : "No fix yet"
        }
        return candidate.station.name
    }

    private var nearestStationDistanceText: String {
        guard let candidate = nearestCandidate else { return "N/A" }
        return "\(Int(candidate.distance))m"
    }

    private var fixAgeText: String {
        guard let timestamp = locationManager.latestFixTimestamp else { return "No fix yet" }
        let age = Date().timeIntervalSince(timestamp)
        guard age >= 0 else { return "Just now" }
        if age < 60 {
            return "\(Int(age))s ago"
        }
        return "\(Int(age / 60))m ago"
    }

    private var accuracyText: String {
        guard let accuracy = locationManager.latestHorizontalAccuracyMeters else { return "No fix yet" }
        return "\(Int(accuracy))m"
    }

    /// Always evaluated against the (tighter) entry radius — the same bar a brand-new
    /// arrival must clear. CalculatorView's own live wasAtPump/hysteresis state isn't
    /// visible from here (see visitSuppressionText for what is), so this intentionally shows
    /// the stricter, more useful "would a fresh arrival be detected right now" answer.
    private var proximityGateText: String {
        guard let candidate = nearestCandidate else { return "N/A" }

        if let reason = PumpProximity.rejectionReason(
            distanceMeters: candidate.distance,
            horizontalAccuracyMeters: locationManager.latestHorizontalAccuracyMeters,
            wasAtPump: false
        ) {
            return reason
        }
        return "Within range \u{2713}"
    }

    /// Reads CalculatorView's foreground visit-suppression state as mirrored (read-only,
    /// diagnostics-only — see AutomaticPumpDetectionService.updateForegroundVisitState) onto
    /// the shared service. Falls back to an explanatory placeholder if Calculator hasn't run
    /// this session yet, since that mirror is only ever written from there.
    private var visitSuppressionText: String {
        guard pumpDetectionService.foregroundHasNearbyStation else {
            return "No station nearby (or Calculator not opened yet this session)"
        }
        return pumpDetectionService.foregroundHasPromptedForCurrentVisit
            ? "Suppressed — already prompted this visit"
            : "Eligible to prompt"
    }

    /// Single "what happened last" snapshot of the background pipeline (region event → Stage
    /// B → notification) — see BackgroundDetectionDiagnosticSnapshot. This is the one field
    /// this view adds specifically so a real-device test that produced no notification can be
    /// traced to a specific stage after the fact, rather than guessed at.
    private var backgroundEventText: String {
        pumpDetectionService.lastBackgroundDiagnostic?.kind.displayLabel ?? "No background event recorded yet"
    }

    private var backgroundEventStationText: String {
        pumpDetectionService.lastBackgroundDiagnostic?.stationName ?? "N/A"
    }

    private var backgroundEventDetailText: String {
        pumpDetectionService.lastBackgroundDiagnostic?.detail ?? "N/A"
    }

    private var backgroundEventAgeText: String {
        guard let timestamp = pumpDetectionService.lastBackgroundDiagnostic?.timestamp else { return "N/A" }
        let age = Date().timeIntervalSince(timestamp)
        guard age >= 0 else { return "Just now" }
        if age < 60 {
            return "\(Int(age))s ago"
        }
        if age < 3600 {
            return "\(Int(age / 60))m ago"
        }
        return "\(Int(age / 3600))h ago"
    }
}

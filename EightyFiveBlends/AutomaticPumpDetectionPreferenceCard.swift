//
//  AutomaticPumpDetectionPreferenceCard.swift
//  EightyFiveBlends
//
//  Automatic Pump Detection's user-facing toggle/status/privacy card — relocated here from
//  Stations, which now focuses on station discovery, map, search, Trip Planner, and pricing.
//  This is UI relocation only: every production detection behavior (foreground prompts,
//  background region monitoring, Stage A/B confirmation, notifications, cooldowns) is owned by
//  AutomaticPumpDetectionService exactly as before and is untouched by this file. Stations still
//  keeps its own production monitoring-refresh hooks (saved stations changed, location updated,
//  location authorization changed) — those aren't UI and have nothing to do with where this
//  card lives.
//
//  Presentation-only: reads the single shared AutomaticPumpDetectionService instance from the
//  environment (injected once, in EightyFiveBlendsApp) and never constructs its own. Free for
//  all users — not gated by Pro entitlement, Simple Mode, or Garage/Reminders tab visibility.
//
//  Also owns re-enable reconciliation: AutomaticPumpDetectionService deliberately never touches
//  SwiftData/FuelStation (see that file's header), so it cannot rebuild its own monitored-
//  station set after enable() — a caller that already has saved stations must push a refresh.
//  Stations does this on every location/authorization/saved-station change (see
//  StationsView.refreshPumpDetectionMonitoredStations), but none of those events necessarily
//  fires again right after the user flips this toggle back on from Preferences, which is what
//  previously left the monitored count stranded at the disable()-cleared value of 0 until the
//  user did something else (moved, visited Stations, relaunched). See reconcileMonitoredStations
//  below for the fix — it queries the SAME [FuelStation] this app already has and maps them
//  with the identical field-by-field conversion StationsView uses, so the two call sites can
//  never drift into subtly different snapshots.

import SwiftData
import SwiftUI

struct AutomaticPumpDetectionPreferenceCard: View {
    @Environment(AutomaticPumpDetectionService.self) private var pumpDetectionService
    @Environment(StationLocationManager.self) private var locationManager
    @Query(sort: \FuelStation.updatedAt, order: .reverse) private var stations: [FuelStation]

    // Set only while waiting for a fresh coordinate to arrive after re-enabling with none
    // available yet — see reconcileMonitoredStations()/the .onChange below. Never anything
    // more than a one-shot latch; not persisted, not a second monitoring state.
    @State private var isAwaitingCoordinateForReconciliation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "Location & Pump Detection",
                subtitle: "Control arrival detection and background alerts."
            )

            Toggle(isOn: toggleBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Automatic Pump Detection")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text("Get notified when you arrive at a saved E85 station, even when 85Blends isn't open. Your location is used only for station arrival features.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(AppTheme.Colors.primaryGreen)

            statusRow

            Text("Foreground detection at the pump always works, even without background access. 85Blends does not display or store your travel history — background detection is only used to identify arrival at monitored saved stations and deliver the At The Pump alert.")
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        // Reconciliation is bounded to exactly one retry: if enable() resolves before a
        // coordinate is available, isAwaitingCoordinateForReconciliation latches true and this
        // fires once when the next coordinate arrives. No timers, no polling — latestCoordinate
        // is already @Observable, so this is the same pattern StationsView's own
        // .onChange(of: locationManager.latestCoordinate) uses for its own refresh.
        .onChange(of: locationManager.latestCoordinate) { _, newCoordinate in
            guard isAwaitingCoordinateForReconciliation, newCoordinate != nil else { return }
            isAwaitingCoordinateForReconciliation = false
            refreshMonitoredStations(force: true)
        }
    }

    // Identical to Stations' former binding: the service remains the single source of truth
    // for isEnabled — this reads/writes it directly, never a second UserDefaults key. The only
    // addition versus the old Stations binding is the reconciliation call after enable() —
    // see reconcileMonitoredStations().
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { pumpDetectionService.isEnabled },
            set: { isOn in
                AppHaptics.selection()
                if isOn {
                    Task {
                        await pumpDetectionService.enable()
                        reconcileMonitoredStations()
                    }
                } else {
                    pumpDetectionService.disable()
                }
            }
        )
    }

    // Runs immediately after enable() resolves. refreshMonitoredStations(savedStations:...)
    // already guards on isEnabled/Always-authorization internally and is a harmless no-op when
    // those aren't met (e.g. When-In-Use-only, or Always denied) — so it's always safe to call
    // here without re-checking status first. The only thing this function adds on top of that
    // is handling the one edge case AutomaticPumpDetectionService can't: no coordinate yet.
    private func reconcileMonitoredStations() {
        if locationManager.latestCoordinate != nil {
            refreshMonitoredStations(force: true)
        } else {
            // requestUserLocation() is safe to call here even if authorization is still
            // .notDetermined for some reason (it would just re-prompt); in the normal re-enable
            // path authorization is already resolved by enable() above, so this reaches
            // manager.requestLocation() directly — no fresh permission prompt.
            isAwaitingCoordinateForReconciliation = true
            locationManager.requestUserLocation()
        }
    }

    // force: true bypasses AutomaticPumpDetectionService's movement-distance throttle
    // (shouldSkipRefresh), which exists to avoid rebuilding on every minor GPS update — that
    // throttle must NOT suppress an explicit re-enable, since the user just watched the count
    // drop to 0 and expects it to come back without walking 500 m first. Field-by-field mapping
    // kept identical to StationsView.refreshPumpDetectionMonitoredStations by design (see the
    // file header comment) — do not let these two drift apart.
    private func refreshMonitoredStations(force: Bool) {
        let snapshots = stations.map {
            SavedStationSnapshot(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, address: $0.address)
        }
        pumpDetectionService.refreshMonitoredStations(
            savedStations: snapshots,
            force: force,
            reason: "Automatic Pump Detection re-enabled from Preferences"
        )
    }

    // Every case from AutomaticPumpDetectionService.Status, carried over unchanged.
    @ViewBuilder
    private var statusRow: some View {
        switch pumpDetectionService.status {
        case .disabled:
            EmptyView()
        case .locationNotDetermined:
            statusText(
                "Waiting for a location permission response…",
                tint: AppTheme.Colors.textSecondary
            )
        case .whenInUseOnly:
            statusBanner(
                "Foreground detection at the pump is active. For background alerts when 85Blends isn't open, allow Always location access in Settings.",
                tint: AppTheme.Colors.stationYellow,
                showsSettingsButton: true
            )
        case .locationDenied:
            statusBanner(
                "Location access is turned off, so Automatic Pump Detection can't run. Enable it in Settings → Privacy → Location Services.",
                tint: AppTheme.Colors.warningRed,
                showsSettingsButton: true
            )
        case .reducedAccuracy:
            statusBanner(
                "Precise Location is off, so arrivals can't be confirmed reliably. Enable Precise Location for 85Blends in Settings.",
                tint: AppTheme.Colors.stationYellow,
                showsSettingsButton: true
            )
        case .notificationsDenied:
            statusBanner(
                "Notifications are turned off, so background arrival alerts can't be delivered. Enable notifications for 85Blends in Settings.",
                tint: AppTheme.Colors.stationYellow,
                showsSettingsButton: true
            )
        case .backgroundActive:
            statusText(
                "Background detection is active for \(pumpDetectionService.monitoredStationCount) saved station\(pumpDetectionService.monitoredStationCount == 1 ? "" : "s").",
                tint: AppTheme.Colors.primaryGreen
            )
        }
    }

    private func statusText(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusBanner(_ text: String, tint: Color, showsSettingsButton: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsSettingsButton {
                Button {
                    openSystemSettings()
                } label: {
                    Text("Open Settings")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // Moved here from StationsView, which no longer has any consumer for it (its own
    // "Location Access Denied" alert doesn't open Settings — it's a plain OK-dismiss alert).
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

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

import SwiftUI

struct AutomaticPumpDetectionPreferenceCard: View {
    @Environment(AutomaticPumpDetectionService.self) private var pumpDetectionService

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
    }

    // Identical to Stations' former binding: the service remains the single source of truth
    // for isEnabled — this reads/writes it directly, never a second UserDefaults key.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { pumpDetectionService.isEnabled },
            set: { isOn in
                AppHaptics.selection()
                if isOn {
                    Task { await pumpDetectionService.enable() }
                } else {
                    pumpDetectionService.disable()
                }
            }
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

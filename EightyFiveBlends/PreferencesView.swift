//
//  PreferencesView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct PreferencesView: View {
    @AppStorage(AppPreferenceKey.preferredMapsApp) private var preferredMapsApp = MapsAppOption.appleMaps.rawValue
    @AppStorage(AppPreferenceKey.defaultTargetBlend) private var defaultTargetBlend = BlendPreferenceOption.e30.rawValue
    @AppStorage(AppPreferenceKey.themePreference) private var themePreference = ThemePreferenceOption.system.rawValue
    @AppStorage(AppPreferenceKey.showGarageTab) private var showGarageTab = true
    @AppStorage(AppPreferenceKey.showRemindersTab) private var showRemindersTab = true
    @AppStorage(AppPreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = true
    @AppStorage(AppPreferenceKey.hasAcknowledgedDisclaimer) private var hasAcknowledgedDisclaimer = false
    @AppStorage(AppPreferenceKey.disclaimerAcknowledgedAt) private var disclaimerAcknowledgedAt = 0.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferences")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("Tune the app experience to match your workflow and display preference.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                settingsCard
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "App Settings", subtitle: "Stored locally on this device.")

            PreferenceMenuRow(
                title: "Preferred Maps App",
                selection: $preferredMapsApp,
                options: MapsAppOption.allCases.map(\.rawValue)
            )

            PreferenceMenuRow(
                title: "Default Target Blend",
                selection: $defaultTargetBlend,
                options: BlendPreferenceOption.allCases.map(\.rawValue)
            )

            PreferenceMenuRow(
                title: "Theme Preference",
                selection: $themePreference,
                options: ThemePreferenceOption.allCases.map(\.rawValue)
            )

            PreferenceToggleRow(title: "Show Garage Tab", isOn: $showGarageTab)
            PreferenceToggleRow(title: "Show Reminders Tab", isOn: $showRemindersTab)

            Button {
                hasCompletedOnboarding = false
                hasAcknowledgedDisclaimer = false
                disclaimerAcknowledgedAt = 0
                AppHaptics.selection()
            } label: {
                HStack {
                    Text("Reset Onboarding")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(14)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
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
}

private struct PreferenceMenuRow: View {
    let title: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
            .tint(AppTheme.Colors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct PreferenceToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .tint(AppTheme.Colors.primaryGreen)
        .padding(14)
        .background(AppTheme.Colors.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

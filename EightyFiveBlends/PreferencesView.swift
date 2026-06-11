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
                #if DEBUG || INTERNAL_BUILD
                proStatusCard
                #endif
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

            AccentThemeSelectorRow()

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

    private var proStatusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "85Blends Pro", subtitle: "Your current subscription status.")

            proStatusRow

            #if DEBUG || INTERNAL_BUILD
            debugOverrideRow
            #endif
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

    private var proStatusRow: some View {
        let manager = SubscriptionManager.shared
        let (label, icon, color): (String, String, Color) = {
            if manager.isLoadingProducts {
                return ("Loading…", "arrow.triangle.2.circlepath", AppTheme.Colors.textMuted)
            } else if manager.isPro {
                return ("Pro", "crown.fill", AppTheme.Colors.stationYellow)
            } else if !manager.isProStoreKit && manager.availableProducts.isEmpty && !manager.isLoadingProducts {
                return ("Free · plans unavailable", "person.circle", AppTheme.Colors.textMuted)
            } else {
                return ("Free", "person.circle", AppTheme.Colors.textSecondary)
            }
        }()

        return HStack {
            Text("Status")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(label)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(color)
        }
        .padding(14)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    #if DEBUG || INTERNAL_BUILD
    private var debugOverrideRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Developer Pro Override")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.warningRed)

                Text("Developer/Internal builds — compiled out in App Store release.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }

            Picker(
                "Developer Pro Override",
                selection: Binding(
                    get: { SubscriptionManager.shared.debugProOverride },
                    set: { SubscriptionManager.shared.debugProOverride = $0 }
                )
            ) {
                ForEach(SubscriptionManager.DebugProOverride.allCases, id: \.rawValue) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .tint(AppTheme.Colors.warningRed)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.warningRed.opacity(0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
    #endif
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

private struct AccentThemeSelectorRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Accent Theme")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                Text("Color style for buttons, tabs, and highlights.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }

            VStack(spacing: 8) {
                ForEach(AppAccentTheme.allCases, id: \.rawValue) { theme in
                    themeOptionRow(theme)
                }
            }
        }
    }

    @ViewBuilder
    private func themeOptionRow(_ theme: AppAccentTheme) -> some View {
        let isSelected = AccentThemeStore.shared.current == theme

        Button {
            AccentThemeStore.shared.select(theme)
            AppHaptics.selection()
        } label: {
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(theme.primaryColor)
                        .frame(width: 13, height: 13)
                    Circle()
                        .fill(AppTheme.Colors.stationYellow)
                        .frame(width: 13, height: 13)
                }

                Text(theme.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isSelected
                    ? AppTheme.Colors.softGreenBackground
                    : AppTheme.Colors.cardBackground
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected
                            ? AppTheme.Colors.primaryGreen.opacity(0.6)
                            : AppTheme.Colors.borderColor,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

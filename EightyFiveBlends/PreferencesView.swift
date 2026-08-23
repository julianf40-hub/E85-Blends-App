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
    @AppStorage(AppPreferenceKey.appExperienceMode) private var appExperienceModeRaw = AppExperienceMode.normal.rawValue
    @AppStorage(AppPreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = true
    @AppStorage(AppPreferenceKey.hasAcknowledgedDisclaimer) private var hasAcknowledgedDisclaimer = false
    @AppStorage(AppPreferenceKey.disclaimerAcknowledgedAt) private var disclaimerAcknowledgedAt = 0.0

    private var appExperienceMode: AppExperienceMode {
        .resolved(from: appExperienceModeRaw)
    }

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

                appExperienceCard
                settingsCard
                AutomaticPumpDetectionPreferenceCard()
                proStatusCard

                #if DEBUG || INTERNAL_BUILD
                subscriptionDiagnosticsCard
                #endif
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }

    // Switching modes takes effect immediately (both @AppStorage-backed) and never touches
    // showGarageTab/showRemindersTab, SwiftData, CloudKit, or Pro entitlement state — see
    // AppExperienceMode/AppExperienceNavigation.swift.
    private var appExperienceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "App Experience",
                subtitle: "Choose how much of 85Blends is shown. Nothing is deleted either way."
            )

            AppExperienceModeSelectorRow(
                selection: Binding(
                    get: { appExperienceMode },
                    set: { newMode in
                        appExperienceModeRaw = newMode.rawValue
                        AppHaptics.selection()
                    }
                )
            )
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

            // Garage/Reminders tab visibility only applies to Normal Mode — Simple Mode always
            // shows just Calculator, Stations, and More. The toggles stay visible (disabled,
            // not hidden) so it's clear these choices are preserved, not lost, while in Simple
            // Mode; switching back to Normal Mode restores them unchanged.
            VStack(alignment: .leading, spacing: 8) {
                PreferenceToggleRow(title: "Show Garage Tab", isOn: $showGarageTab)
                    .disabled(appExperienceMode == .simple)
                    .opacity(appExperienceMode == .simple ? 0.5 : 1)
                PreferenceToggleRow(title: "Show Reminders Tab", isOn: $showRemindersTab)
                    .disabled(appExperienceMode == .simple)
                    .opacity(appExperienceMode == .simple ? 0.5 : 1)

                if appExperienceMode == .simple {
                    Text("Unavailable in Simple Mode. Your selections are saved and return when you switch back to Normal Mode.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
            }

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
            } else if !manager.canPurchase {
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
    // Visually reacts to isDebugProOverrideActive (SubscriptionManager.swift) so a lingering
    // Force Pro/Force Free from an earlier test session is impossible to miss the moment
    // Preferences is opened — this was the actual cause of a fresh, entitlement-free RevenueCat
    // sandbox customer still showing "You have 85Blends Pro" in the app. The Picker's binding and
    // options are unchanged from before; only the surrounding header/subtitle react to state, and
    // a "Reset Override" action appears when there's something to reset.
    private var debugOverrideRow: some View {
        let manager = SubscriptionManager.shared
        let isActive = manager.isDebugProOverrideActive

        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if isActive {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.warningRed)
                            .accessibilityHidden(true)
                    }
                    Text(isActive ? "Developer Pro Override — ACTIVE" : "Developer Pro Override")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.warningRed)
                }

                Text(
                    isActive
                        ? "Overriding real entitlement with \"\(manager.debugProOverride.rawValue)\" — reset before testing real purchases, restores, or a fresh sandbox account."
                        : "Developer/Internal builds — compiled out in App Store release."
                )
                .font(.caption2)
                .foregroundStyle(isActive ? AppTheme.Colors.warningRed : AppTheme.Colors.textMuted)
            }

            Picker(
                "Developer Pro Override",
                selection: Binding(
                    get: { manager.debugProOverride },
                    set: { manager.debugProOverride = $0 }
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

            if isActive {
                Button {
                    manager.resetDebugProOverride()
                    AppHaptics.selection()
                } label: {
                    HStack {
                        Text("Reset Override")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AppTheme.Colors.warningRed)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(AppTheme.Colors.warningRed.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.Colors.warningRed.opacity(0.4), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
    #endif

    // MARK: - RevenueCat subscription diagnostics (85Blends 2.3.0 — RevenueCat is authoritative)
    //
    // Internal/Debug only, exactly like debugOverrideRow above. RevenueCat is the real
    // subscription entitlement source for this build — this card surfaces exactly what it
    // reports so a developer can see it without changing Pro access; nothing on this card
    // grants or revokes Pro itself (Refresh below only re-fetches CustomerInfo).
    #if DEBUG || INTERNAL_BUILD
    private var subscriptionDiagnosticsCard: some View {
        let manager = SubscriptionManager.shared
        let rc = RevenueCatSubscriptionService.shared

        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "RevenueCat Subscription",
                subtitle: "RevenueCat is the authoritative subscription entitlement source for this build."
            )

            VStack(alignment: .leading, spacing: 10) {
                diagnosticRow(label: "SDK", value: rc.isConfigured ? "Configured" : "Not configured")
                diagnosticRow(label: "Entitlement", value: rc.revenueCatIsPro ? "PRO" : "FREE")
                diagnosticRow(label: "Effective", value: manager.isPro ? "PRO" : "FREE")
                diagnosticRow(label: "Override", value: manager.debugProOverride.rawValue)
                diagnosticRow(label: "Customer Info", value: revenueCatCustomerInfoLabel(rc.customerInfoLastUpdatedAt))
                diagnosticRow(label: "App User ID", value: rc.maskedAppUserID ?? "—")
                diagnosticRow(label: "Offering", value: revenueCatOfferingLabel(rc.packageAvailability))
                diagnosticRow(label: "Monthly Package", value: revenueCatMonthlyPackageLabel(rc.packageAvailability))
                diagnosticRow(label: "Product", value: SubscriptionManager.monthlyID)
                diagnosticRow(label: "Environment", value: revenueCatEnvironmentLabel(rc.isSandboxEnvironment))

                if let lastError = rc.lastErrorDescription {
                    diagnosticRow(label: "Last Error", value: lastError)
                }
            }

            // Re-fetches CustomerInfo only — never a purchase or restore call. See
            // RevenueCatSubscriptionService.refreshCustomerInfoNow()'s own doc comment.
            Button {
                Task { await RevenueCatSubscriptionService.shared.refreshCustomerInfoNow() }
                AppHaptics.selection()
            } label: {
                HStack {
                    Text("Refresh RevenueCat Status")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.clockwise")
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
            .disabled(rc.isConfigured == false)
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

    private func diagnosticRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func revenueCatCustomerInfoLabel(_ lastUpdatedAt: Date?) -> String {
        guard let lastUpdatedAt else { return "Never" }
        return lastUpdatedAt.formatted(.relative(presentation: .named))
    }

    private func revenueCatOfferingLabel(_ availability: RevenueCatSubscriptionService.PackageAvailability) -> String {
        switch availability {
        case .notLoaded: return "Not loaded"
        case .loading: return "Loading…"
        case .offeringUnavailable: return "Unavailable"
        case .ready, .packageUnavailable, .unexpectedProduct: return "Available"
        }
    }

    private func revenueCatMonthlyPackageLabel(_ availability: RevenueCatSubscriptionService.PackageAvailability) -> String {
        switch availability {
        case .notLoaded: return "Not loaded"
        case .loading: return "Loading…"
        case .offeringUnavailable: return "N/A — offering unavailable"
        case .packageUnavailable: return "Unavailable"
        case .ready: return "Available"
        case .unexpectedProduct(let productID): return "Unexpected product: \(productID)"
        }
    }

    private func revenueCatEnvironmentLabel(_ isSandbox: Bool?) -> String {
        switch isSandbox {
        case .some(true): return "Sandbox"
        case .some(false): return "Production"
        case .none: return "Unknown"
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

private struct AppExperienceModeSelectorRow: View {
    @Binding var selection: AppExperienceMode

    var body: some View {
        VStack(spacing: 8) {
            ForEach(AppExperienceMode.allCases) { mode in
                modeOptionRow(mode)
            }
        }
    }

    @ViewBuilder
    private func modeOptionRow(_ mode: AppExperienceMode) -> some View {
        let isSelected = selection == mode

        Button {
            selection = mode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text(mode.settingsSummary)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                // Selection is never color-only — the checkmark glyph and stroke weight both
                // change, so it reads correctly for colorblind and reduced-transparency users.
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.textMuted)
                    .accessibilityHidden(true)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.displayName) mode. \(mode.settingsSummary)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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

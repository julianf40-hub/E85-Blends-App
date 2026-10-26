//
//  OnboardingView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

// 85Blends 2.4.1: a single quick-start screen replaces the previous six-step flow. It introduces
// the app, highlights the two core tools, and requires explicit safety acknowledgment before
// completing. No vehicle creation, App Experience/tab choices, Pro marketing, paywall, or
// permission prompts — all of those remain reachable later (Garage, More → Preferences, More).
// Completion rules and persisted values live in OnboardingQuickStart.
struct OnboardingView: View {
    @State private var disclaimerAcknowledged = false
    @State private var isShowingFullDisclaimer = false
    @State private var disclaimerGuidanceMessage: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            AppTheme.Colors.oledBackground
                .ignoresSafeArea()

            Circle()
                .fill(AppTheme.Colors.primaryGreen.opacity(0.14))
                .frame(width: 320, height: 320)
                .blur(radius: 70)
                .offset(x: 120, y: -240)
                .accessibilityHidden(true)

            Circle()
                .fill(AppTheme.Colors.stationYellow.opacity(0.08))
                .frame(width: 240, height: 240)
                .blur(radius: 70)
                .offset(x: -140, y: 300)
                .accessibilityHidden(true)

            // Content scrolls so every Dynamic Type size (including accessibility sizes) fits;
            // the primary action stays pinned below it — except at accessibility sizes, where it
            // scrolls with the content so the pinned footer can't cover the safety note.
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        featuresCard
                        vehicleNote
                        disclaimerCard
                    }
                    .padding(24)

                    if usesStackedLayout {
                        footer
                    }
                }

                if usesStackedLayout == false {
                    footer
                }
            }
        }
        .sheet(isPresented: $isShowingFullDisclaimer) {
            NavigationStack {
                DisclaimerView()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WELCOME")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .accessibilityHidden(true)

            Text("Welcome to 85Blends")
                .font(.largeTitle.weight(.bold))
                .fontDesign(.rounded)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text("Your ethanol toolkit. E85 is up to 85% ethanol — 85Blends helps you mix the right blend and find E85 near you.")
                .font(.body)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(
                systemImage: "fuelpump.fill",
                tint: AppTheme.Colors.accentGreen,
                title: "Blend Calculator",
                detail: "Work out how much E85 and gas to add to reach E30, E50, E85, or any target blend."
            )
            featureRow(
                systemImage: "mappin.and.ellipse",
                tint: AppTheme.Colors.stationYellow,
                title: "E85 Station Finder",
                detail: "Find nearby E85 stations with community-reported prices."
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func featureRow(systemImage: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(minWidth: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var vehicleNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "car.fill")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .accessibilityHidden(true)

            Text("Adding a vehicle is optional. You can add one anytime later in Garage.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Safety Note")
                .font(.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 10) {
                safetyPoint("Blend and octane calculations are estimates — always verify actual ethanol content and fuel quality.")
                safetyPoint("Vehicle compatibility, tuning, warranty, emissions, and legal compliance are your responsibility.")
                safetyPoint("85Blends is not professional mechanical, legal, financial, or regulatory advice.")
            }

            acknowledgmentToggle
            .padding(14)
            .background(AppTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        disclaimerNeedsHighlight ? AppTheme.Colors.stationYellow : AppTheme.Colors.border,
                        lineWidth: disclaimerNeedsHighlight ? 1.6 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(.easeInOut(duration: 0.22), value: disclaimerNeedsHighlight)
            .onChange(of: disclaimerAcknowledged) { _, newValue in
                if newValue {
                    disclaimerGuidanceMessage = nil
                }
            }

            Button {
                isShowingFullDisclaimer = true
            } label: {
                HStack {
                    Text("View full disclaimer")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHidden(true)
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
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var acknowledgmentToggle: some View {
        let label = Text("I understand these calculations are estimates and I am responsible for verifying fuel compatibility.")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)

        if usesStackedLayout {
            // The label gets the full card width above the switch instead of being squeezed beside
            // it; the Toggle keeps the same label so VoiceOver reads one combined control.
            VStack(alignment: .leading, spacing: 12) {
                label
                    .accessibilityHidden(true)
                Toggle(isOn: $disclaimerAcknowledged) { label }
                    .labelsHidden()
                    .tint(AppTheme.Colors.accentGreen)
                    .accessibilityHint("Required to start using 85Blends.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Toggle(isOn: $disclaimerAcknowledged) { label }
                .tint(AppTheme.Colors.accentGreen)
                .accessibilityHint("Required to start using 85Blends.")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let disclaimerGuidanceMessage {
                Text(disclaimerGuidanceMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Stays tappable before acknowledgment so a tap can explain what's missing (and
            // VoiceOver announces it) rather than silently doing nothing.
            Button {
                handleStart()
            } label: {
                Text("Start Using 85Blends")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppTheme.Colors.textPrimary.opacity(canComplete ? 1 : 0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canComplete ? AppTheme.Colors.accentGreen : AppTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                canComplete ? AppTheme.Colors.accentGreen : AppTheme.Colors.textMuted.opacity(0.5),
                                lineWidth: 1
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint(canComplete ? "" : "Acknowledge the safety note first.")
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(AppTheme.Colors.oledBackground)
    }

    private func safetyPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.accentYellow)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usesStackedLayout: Bool {
        OnboardingQuickStart.usesStackedLayout(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    private var canComplete: Bool {
        OnboardingQuickStart.canComplete(disclaimerAcknowledged: disclaimerAcknowledged)
    }

    private var disclaimerNeedsHighlight: Bool {
        disclaimerGuidanceMessage != nil && disclaimerAcknowledged == false
    }

    private func handleStart() {
        guard canComplete else {
            let message = "Please acknowledge the safety note to continue."
            disclaimerGuidanceMessage = message
            AccessibilityNotification.Announcement(message).post()
            return
        }
        AppHaptics.success()
        // Writes hasAcknowledgedDisclaimer, disclaimerAcknowledgedAt, then hasCompletedOnboarding
        // to the same UserDefaults.standard store ContentView's @AppStorage observes.
        OnboardingQuickStart.complete(disclaimerAcknowledged: disclaimerAcknowledged, defaults: .standard)
    }
}

#Preview {
    OnboardingView()
}

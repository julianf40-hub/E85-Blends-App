//
//  OnboardingView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VehicleProfile.createdAt, order: .forward)
    private var vehicles: [VehicleProfile]

    @AppStorage(AppPreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppPreferenceKey.hasAcknowledgedDisclaimer) private var hasAcknowledgedDisclaimer = false
    @AppStorage(AppPreferenceKey.disclaimerAcknowledgedAt) private var disclaimerAcknowledgedAt = 0.0
    @AppStorage(AppPreferenceKey.showGarageTab) private var showGarageTab = true
    @AppStorage(AppPreferenceKey.showRemindersTab) private var showRemindersTab = true

    @State private var currentStep = 0
    @State private var draft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)
    @State private var disclaimerState = DisclaimerAcknowledgementState()
    @State private var isShowingFullDisclaimer = false
    @State private var disclaimerGuidanceMessage: String?

    private let steps: [OnboardingStep] = [
        // 0: Welcome
        .init(
            emoji: "🚗",
            title: "Welcome to 85Blends",
            subtitle: "Calculate blends, find E85 stations, and keep your ethanol fueling organized.",
            bulletPoints: [
                "Blend Calculator & At the Pump mode",
                "Nearby E85 Stations & community pricing",
                "Fuel Logs, MPG trends & cost tracking",
                "Garage, Reminders & cost comparisons"
            ]
        ),
        // 1: Vehicle setup (optional form — body routes here via currentStep == 1)
        .init(
            emoji: "🔧",
            title: "Manage Your Build",
            subtitle: "Optional — add your vehicle to personalize blend defaults. You can skip this and add it later in Garage."
        ),
        // 2: Feature overview
        .init(
            emoji: "⛽",
            title: "Fuel with Confidence",
            subtitle: "Calculate blends, estimate costs, and quickly find nearby E85 stations.",
            bulletPoints: [
                "Blend Calculator — E30, E50, E60, or E85 in seconds.",
                "At the Pump mode for one-handed fueling guidance.",
                "Nearby E85 stations with community-reported prices.",
                "Fuel Log with MPG, spend, and trend tracking.",
                "Cost Calculator to compare blends vs gasoline."
            ]
        ),
        // 3: Tab selection (tabSelectionStepIndex)
        .init(
            emoji: "🎨",
            title: "Built for E85 Enthusiasts",
            subtitle: "Save vehicles, track fuel history, and stay on top of maintenance reminders."
        ),
        // 4: Disclaimer (disclaimerStepIndex)
        .init(
            emoji: "🔥",
            title: "Ready to Blend?",
            subtitle: "Track fuel, find stations, manage your build, and make every fill-up smarter."
        ),
        // 5: 85Blends Pro intro (proStepIndex) — informational only, no paywall or purchase flow
        .init(
            emoji: "👑",
            title: "Unlock 85Blends Pro",
            subtitle: "Take your E85 experience even further.",
            bulletPoints: [
                "Intelligent Trip Planning",
                "Advanced Fuel Analytics",
                "Station Price Alerts",
                "Unlimited Vehicles",
                "Cloud Sync Ready"
            ]
        )
    ]

    var body: some View {
        ZStack {
            AppTheme.Colors.oledBackground
                .ignoresSafeArea()

            Circle()
                .fill(AppTheme.Colors.primaryGreen.opacity(0.14))
                .frame(width: 320, height: 320)
                .blur(radius: 70)
                .offset(x: 120, y: -240)

            Circle()
                .fill(AppTheme.Colors.stationYellow.opacity(0.08))
                .frame(width: 240, height: 240)
                .blur(radius: 70)
                .offset(x: -140, y: 300)

            VStack(alignment: .leading, spacing: 24) {
                header

                progressSection

                if currentStep == 1 {
                    vehicleSetupCard
                } else if isTabSelectionStep {
                    tabSelectionCard
                } else if isDisclaimerStep {
                    disclaimerAcknowledgementCard
                } else if isProStep {
                    proIntroCard
                } else {
                    messageCard(step: steps[currentStep])
                }

                Spacer()

                footerActions
            }
            .padding(24)
        }
        .keyboardDoneToolbar()
        .dismissKeyboardOnTap()
        .sheet(isPresented: $isShowingFullDisclaimer) {
            NavigationStack {
                DisclaimerView()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GETTING STARTED")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text("85Blends")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("Your ethanol toolkit, set up in under a minute")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Step \(currentStep + 1) of \(steps.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(Array(steps.indices), id: \.self) { index in
                    Capsule()
                        .fill(index <= currentStep ? AppTheme.Colors.accentGreen : AppTheme.Colors.border)
                        .frame(height: 8)
                }
            }
        }
    }

    private func messageCard(step: OnboardingStep) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("STEP \(currentStep + 1)")
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.Colors.textMuted)

            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AppTheme.Colors.softGreenBackground.opacity(0.72),
                                AppTheme.Colors.stationYellow.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text(step.emoji)
                    .font(.system(size: 36))
            }
            .frame(width: 72, height: 72)

            Text(step.title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text(step.subtitle)
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            if step.bulletPoints.isEmpty == false {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(step.bulletPoints, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.Colors.accentGreen)
                                .padding(.top, 2)

                            Text(bullet)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var vehicleSetupCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("STEP \(currentStep + 1)")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                HStack(spacing: 10) {
                    Text(steps[currentStep].emoji)
                        .font(.system(size: 36))

                    Text("OPTIONAL")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.Colors.accentGreen)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppTheme.Colors.accentGreen.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(steps[currentStep].title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(steps[currentStep].subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                OnboardingStringField(title: "Nickname", text: $draft.nickname)
                OnboardingStringField(title: "Make", text: $draft.make)
                OnboardingStringField(title: "Model", text: $draft.model)
                OnboardingDoubleField(title: "Tank Size (gallons)", value: $draft.tankSizeGallons)
                OnboardingToggleRow(title: "Flex Fuel Vehicle", isOn: $draft.isFlexFuel)

                Text("All details can be edited later in Garage.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private var footerActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isProStep {
                proFooterActions
            } else {
                standardFooterActions
            }
        }
    }

    // Final onboarding step. Both actions finish onboarding — neither opens a paywall or
    // purchase flow. Pro can always be explored later from the More tab.
    private var proFooterActions: some View {
        VStack(spacing: 12) {
            Button {
                completeOnboarding()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppTheme.Colors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                completeOnboarding()
            } label: {
                Text("Explore Pro Later")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var standardFooterActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isDisclaimerStep, let disclaimerGuidanceMessage {
                Text(disclaimerGuidanceMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.stationYellow)
            }

            HStack(spacing: 12) {
                if isDisclaimerStep == false {
                    Button("Skip") {
                        resetOptionalTabsToDefault()
                        currentStep = disclaimerStepIndex
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Spacer()

                if currentStep > 0 {
                    Button("Back") {
                        currentStep -= 1
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Button(currentStep == steps.count - 1 ? "Start Blending" : "Continue") {
                    handlePrimaryAction()
                }
                .font(.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary.opacity(continueButtonEnabled ? 1 : 0.6))
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(continueButtonEnabled ? AppTheme.Colors.accentGreen : AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            continueButtonEnabled ? AppTheme.Colors.accentGreen : AppTheme.Colors.border,
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func completeOnboarding() {
        guard canFinishOnboarding else { return }

        if shouldCreateVehicle {
            if vehicles.isEmpty == false {
                for vehicle in vehicles {
                    vehicle.isActive = false
                    vehicle.updatedAt = .now
                }
            }

            let vehicle = VehicleProfile(
                nickname: draft.nickname,
                year: draft.year,
                make: draft.make,
                model: draft.model,
                trim: draft.trim,
                tankSizeGallons: draft.tankSizeGallons,
                currentOdometer: draft.currentOdometer,
                defaultTargetEthanolPercent: draft.defaultTargetEthanolPercent,
                defaultCurrentEthanolPercent: draft.defaultCurrentEthanolPercent,
                defaultPumpEthanolPercent: draft.defaultPumpEthanolPercent,
                gasEthanolPercent: draft.gasEthanolPercent,
                requiredOctane: draft.requiredOctane,
                isFlexFuel: draft.isFlexFuel,
                isActive: true,
                createdAt: .now,
                updatedAt: .now
            )

            modelContext.insert(vehicle)
            do {
                try modelContext.save()
            } catch {
                #if DEBUG
                print("[85Blends] OnboardingView: vehicle save failed:", error)
                #endif
            }
        }

        hasAcknowledgedDisclaimer = true
        disclaimerAcknowledgedAt = Date.now.timeIntervalSince1970
        AppHaptics.success()
        hasCompletedOnboarding = true
    }

    private var disclaimerAcknowledgementCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("STEP \(currentStep + 1)")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text(steps[currentStep].emoji)
                    .font(.system(size: 36))

                Text(steps[currentStep].title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(steps[currentStep].subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                VStack(alignment: .leading, spacing: 10) {
                    safetyPoint("Blend and octane calculations are estimates — always verify actual ethanol content and fuel quality.")
                    safetyPoint("Vehicle compatibility, tuning, warranty, emissions, and legal compliance are your responsibility.")
                    safetyPoint("85Blends is not professional mechanical, legal, financial, or regulatory advice.")
                }
                .padding(.top, 4)

                Toggle(isOn: $disclaimerState.acknowledged) {
                    Text("I understand these calculations are estimates and I am responsible for verifying fuel compatibility.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                .tint(AppTheme.Colors.accentGreen)
                .padding(14)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            disclaimerNeedsHighlight ? AppTheme.Colors.stationYellow : AppTheme.Colors.border,
                            lineWidth: disclaimerNeedsHighlight ? 1.6 : 1
                        )
                )
                .shadow(
                    color: disclaimerNeedsHighlight ? AppTheme.Colors.stationYellow.opacity(0.22) : .clear,
                    radius: disclaimerNeedsHighlight ? 12 : 0
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .animation(.easeInOut(duration: 0.22), value: disclaimerNeedsHighlight)
                .onChange(of: disclaimerState.acknowledged) { _, newValue in
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

                Text("Built for the ethanol community.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private var tabSelectionCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("STEP \(currentStep + 1)")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text(steps[currentStep].emoji)
                    .font(.system(size: 36))

                Text(steps[currentStep].title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(steps[currentStep].subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                onboardingTabToggleCard(
                    title: "Garage",
                    description: "Save vehicles, tank sizes, odometer, and calculator defaults.",
                    systemImage: "car.fill",
                    tint: AppTheme.Colors.accentGreen,
                    isOn: $showGarageTab
                )
                onboardingTabToggleCard(
                    title: "Reminders",
                    description: "Track oil changes, service intervals, dates, and mileage-based tasks.",
                    systemImage: "bell.badge.fill",
                    tint: AppTheme.Colors.stationYellow,
                    isOn: $showRemindersTab
                )
                Text("Calculator, Stations, and More always stay visible. Theme, blend defaults, and preferred maps app can be changed anytime in More \u{2192} Preferences.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    // Final onboarding screen — a natural, no-pressure introduction to 85Blends Pro.
    // Purely informational: there is no purchase flow or paywall here.
    private var proIntroCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("STEP \(currentStep + 1)")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(AppTheme.Colors.stationYellow.opacity(0.16))

                    Image(systemName: "crown.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                }
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

                Text(steps[currentStep].title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(steps[currentStep].subtitle)
                    .font(.title3)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(steps[currentStep].bulletPoints, id: \.self) { benefit in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AppTheme.Colors.stationYellow)
                                .padding(.top, 1)
                                .accessibilityHidden(true)

                            Text(benefit)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 2)

                Text("No purchase required to continue — you can explore Pro anytime from the More tab.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(AppTheme.Colors.stationYellow.opacity(0.30), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private var disclaimerNeedsHighlight: Bool {
        disclaimerGuidanceMessage != nil && disclaimerState.acknowledged == false
    }

    private func safetyPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.accentYellow)
                .padding(.top, 1)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    private var disclaimerStepIndex: Int {
        steps.count - 2
    }

    private var proStepIndex: Int {
        steps.count - 1
    }

    private var isProStep: Bool {
        currentStep == proStepIndex
    }

    private var isDisclaimerStep: Bool {
        currentStep == disclaimerStepIndex
    }

    private var isTabSelectionStep: Bool {
        currentStep == tabSelectionStepIndex
    }

    private var canFinishOnboarding: Bool {
        disclaimerState.allAcknowledged
    }

    private var continueButtonEnabled: Bool {
        isDisclaimerStep ? canFinishOnboarding : true
    }

    private func handlePrimaryAction() {
        // The disclaimer is no longer the last step — it gates advancing to the Pro intro,
        // which is where onboarding actually completes (via proFooterActions).
        if isDisclaimerStep, canFinishOnboarding == false {
            guideToFirstMissingAcknowledgement()
            return
        }
        currentStep += 1
    }

    private func resetOptionalTabsToDefault() {
        showGarageTab = true
        showRemindersTab = true
    }

    private func guideToFirstMissingAcknowledgement() {
        disclaimerGuidanceMessage = "Please acknowledge the safety note to continue."
    }

    private var shouldCreateVehicle: Bool {
        let baselineDraft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)

        let hasIdentityInput = [
            draft.nickname,
            draft.make,
            draft.model
        ].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

        let hasCustomizedDefaults =
            draft.tankSizeGallons != baselineDraft.tankSizeGallons ||
            draft.isFlexFuel != baselineDraft.isFlexFuel

        return hasIdentityInput || hasCustomizedDefaults
    }

    private var tabSelectionStepIndex: Int {
        steps.count - 3
    }
}

#Preview {
    OnboardingView()
        .modelContainer(for: VehicleProfile.self, inMemory: true)
}

private struct OnboardingStep {
    let emoji: String
    let title: String
    let subtitle: String
    let bulletPoints: [String]

    init(emoji: String, title: String, subtitle: String, bulletPoints: [String] = []) {
        self.emoji = emoji
        self.title = title
        self.subtitle = subtitle
        self.bulletPoints = bulletPoints
    }
}

private struct DisclaimerAcknowledgementState {
    var acknowledged = false
    var allAcknowledged: Bool { acknowledged }
}

private struct OnboardingStringField: View {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, text: $text)
                .keyboardType(keyboard)
                .foregroundStyle(AppTheme.Colors.textPrimary)
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
}

private struct OnboardingDoubleField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, value: $value, format: .number)
                .keyboardType(.decimalPad)
                .foregroundStyle(AppTheme.Colors.textPrimary)
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
}

private struct OnboardingToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .tint(AppTheme.Colors.accentGreen)
        .padding(14)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension OnboardingView {
    func onboardingTabToggleCard(
        title: String,
        description: String,
        systemImage: String,
        tint: Color,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(AppTheme.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(AppTheme.Colors.accentGreen)
        }
        .padding(16)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

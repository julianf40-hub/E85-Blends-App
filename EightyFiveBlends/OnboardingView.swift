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
    @AppStorage(AppPreferenceKey.showGearTab) private var showGearTab = true

    @State private var currentStep = 0
    @State private var draft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)
    @State private var disclaimerState = DisclaimerAcknowledgementState()
    @State private var isShowingFullDisclaimer = false
    @State private var highlightedMissingAcknowledgementID: DisclaimerAcknowledgementID?
    @State private var disclaimerGuidanceMessage: String?

    private let steps: [OnboardingStep] = [
        .init(
            title: "Welcome to 85Blends",
            subtitle: "Build cleaner ethanol routines with a local-first app for blend planning, saved stations, and vehicle-specific fuel tracking."
        ),
        .init(
            title: "Set up your vehicle",
            subtitle: "Start with the core details your calculator and logs will use every day."
        ),
        .init(
            title: "Calculate smarter blends",
            subtitle: "Use your tank size, fuel assumptions, and target ethanol content to get a faster, more consistent starting estimate."
        ),
        .init(
            title: "Track fuel logs and reminders",
            subtitle: "Save fill-ups, monitor costs, and stay ahead of maintenance with reminders tied to your vehicle."
        ),
        .init(
            title: "Choose your tabs",
            subtitle: "Pick which optional tabs should be visible from day one."
        ),
        .init(
            title: "Acknowledge safety notes",
            subtitle: "Review and accept the key warnings before entering the app."
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
            Text("FIRST-LAUNCH SETUP")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text("85Blends")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("First-launch setup")
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

            Text(step.title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text(step.subtitle)
                .font(.title3)
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

    private var vehicleSetupCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("STEP \(currentStep + 1)")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text(steps[currentStep].title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(steps[currentStep].subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                OnboardingStringField(title: "Nickname", text: $draft.nickname)
                OnboardingStringField(title: "Year", text: $draft.year, keyboard: .numberPad)
                OnboardingStringField(title: "Make", text: $draft.make)
                OnboardingStringField(title: "Model", text: $draft.model)
                OnboardingStringField(title: "Trim", text: $draft.trim)
                OnboardingDoubleField(title: "Tank Size Gallons", value: $draft.tankSizeGallons)
                OnboardingIntField(title: "Current Odometer", value: $draft.currentOdometer)
                OnboardingDoubleField(title: "Required Octane", value: $draft.requiredOctane)
                OnboardingDoubleField(title: "Default Target Ethanol %", value: $draft.defaultTargetEthanolPercent)
                OnboardingDoubleField(title: "Default Current Ethanol %", value: $draft.defaultCurrentEthanolPercent)
                OnboardingDoubleField(title: "Default Pump Ethanol %", value: $draft.defaultPumpEthanolPercent)
                OnboardingDoubleField(title: "Gas Ethanol %", value: $draft.gasEthanolPercent)
                OnboardingToggleRow(title: "Flex Fuel Vehicle", isOn: $draft.isFlexFuel)
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

                Button(currentStep == steps.count - 1 ? "Finish" : "Continue") {
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
            try? modelContext.save()
        }

        hasAcknowledgedDisclaimer = true
        disclaimerAcknowledgedAt = Date.now.timeIntervalSince1970
        AppHaptics.success()
        hasCompletedOnboarding = true
    }

    private var disclaimerAcknowledgementCard: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("STEP \(currentStep + 1)")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text(steps[currentStep].title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text(steps[currentStep].subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)

                    disclaimerAcknowledgementRow(
                        id: .estimates,
                        title: "I understand blend and octane calculations are estimates only.",
                        isOn: $disclaimerState.estimatesAcknowledged
                    )
                    disclaimerAcknowledgementRow(
                        id: .fuelQuality,
                        title: "I understand I am responsible for verifying actual ethanol content and fuel quality.",
                        isOn: $disclaimerState.fuelQualityAcknowledged
                    )
                    disclaimerAcknowledgementRow(
                        id: .vehicleResponsibility,
                        title: "I understand vehicle compatibility, tuning, warranty, emissions, and legal compliance are my responsibility.",
                        isOn: $disclaimerState.vehicleResponsibilityAcknowledged
                    )
                    disclaimerAcknowledgementRow(
                        id: .advice,
                        title: "I understand 85Blends is not professional mechanical, legal, financial, or regulatory advice.",
                        isOn: $disclaimerState.adviceAcknowledged
                    )

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
            .onChange(of: highlightedMissingAcknowledgementID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var tabSelectionCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("STEP \(currentStep + 1)")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

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
                onboardingTabToggleCard(
                    title: "Gear",
                    description: "View recommended ethanol tools, accessories, sponsor links, and future gear picks.",
                    systemImage: "wrench.and.screwdriver.fill",
                    tint: AppTheme.Colors.accentGreen,
                    isOn: $showGearTab
                )

                Text("Calculator, Stations, and More always stay visible. You can change these later in More → Preferences.")
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

    private func disclaimerAcknowledgementRow(
        id: DisclaimerAcknowledgementID,
        title: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .tint(AppTheme.Colors.accentGreen)
        .padding(14)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    highlightedMissingAcknowledgementID == id ? AppTheme.Colors.stationYellow : AppTheme.Colors.border,
                    lineWidth: highlightedMissingAcknowledgementID == id ? 1.6 : 1
                )
        )
        .shadow(
            color: highlightedMissingAcknowledgementID == id ? AppTheme.Colors.stationYellow.opacity(0.22) : .clear,
            radius: highlightedMissingAcknowledgementID == id ? 12 : 0
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(highlightedMissingAcknowledgementID == id ? 1.015 : 1)
        .animation(.easeInOut(duration: 0.22), value: highlightedMissingAcknowledgementID == id)
        .id(id)
        .onChange(of: isOn.wrappedValue) { _, newValue in
            if newValue, highlightedMissingAcknowledgementID == id {
                highlightedMissingAcknowledgementID = nil
            }

            if disclaimerState.allAcknowledged {
                disclaimerGuidanceMessage = nil
                highlightedMissingAcknowledgementID = nil
            }
        }
    }

    private var disclaimerStepIndex: Int {
        steps.count - 1
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
        if currentStep == steps.count - 1 {
            guard canFinishOnboarding else {
                guideToFirstMissingAcknowledgement()
                return
            }
            completeOnboarding()
        } else {
            currentStep += 1
        }
    }

    private func resetOptionalTabsToDefault() {
        showGarageTab = true
        showRemindersTab = true
        showGearTab = true
    }

    private func guideToFirstMissingAcknowledgement() {
        disclaimerGuidanceMessage = "Please review the remaining required safety note."
        highlightedMissingAcknowledgementID = firstMissingAcknowledgementID
    }

    private var firstMissingAcknowledgementID: DisclaimerAcknowledgementID? {
        if disclaimerState.estimatesAcknowledged == false { return .estimates }
        if disclaimerState.fuelQualityAcknowledged == false { return .fuelQuality }
        if disclaimerState.vehicleResponsibilityAcknowledged == false { return .vehicleResponsibility }
        if disclaimerState.adviceAcknowledged == false { return .advice }
        return nil
    }

    private var shouldCreateVehicle: Bool {
        let baselineDraft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)

        let hasIdentityInput = [
            draft.nickname,
            draft.year,
            draft.make,
            draft.model,
            draft.trim
        ].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

        let hasCustomizedDefaults =
            draft.tankSizeGallons != baselineDraft.tankSizeGallons ||
            draft.currentOdometer != baselineDraft.currentOdometer ||
            draft.requiredOctane != baselineDraft.requiredOctane ||
            draft.defaultTargetEthanolPercent != baselineDraft.defaultTargetEthanolPercent ||
            draft.defaultCurrentEthanolPercent != baselineDraft.defaultCurrentEthanolPercent ||
            draft.defaultPumpEthanolPercent != baselineDraft.defaultPumpEthanolPercent ||
            draft.gasEthanolPercent != baselineDraft.gasEthanolPercent ||
            draft.isFlexFuel != baselineDraft.isFlexFuel

        return hasIdentityInput || hasCustomizedDefaults
    }

    private var tabSelectionStepIndex: Int {
        steps.count - 2
    }
}

#Preview {
    OnboardingView()
        .modelContainer(for: VehicleProfile.self, inMemory: true)
}

private struct OnboardingStep {
    let title: String
    let subtitle: String
}

private struct DisclaimerAcknowledgementState {
    var estimatesAcknowledged = false
    var fuelQualityAcknowledged = false
    var vehicleResponsibilityAcknowledged = false
    var adviceAcknowledged = false

    var allAcknowledged: Bool {
        estimatesAcknowledged &&
            fuelQualityAcknowledged &&
            vehicleResponsibilityAcknowledged &&
            adviceAcknowledged
    }
}

private enum DisclaimerAcknowledgementID: Hashable {
    case estimates
    case fuelQuality
    case vehicleResponsibility
    case advice
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

private struct OnboardingIntField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, value: $value, format: .number)
                .keyboardType(.numberPad)
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

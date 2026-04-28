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

    @State private var currentStep = 0
    @State private var draft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)

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
                } else {
                    messageCard(step: steps[currentStep])
                }

                Spacer()

                footerActions
            }
            .padding(24)
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
        HStack(spacing: 12) {
            Button("Skip") {
                hasCompletedOnboarding = true
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
                if currentStep == steps.count - 1 {
                    completeOnboarding()
                } else {
                    currentStep += 1
                }
            }
            .font(.headline)
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(AppTheme.Colors.accentGreen)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func completeOnboarding() {
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
        AppHaptics.success()
        hasCompletedOnboarding = true
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

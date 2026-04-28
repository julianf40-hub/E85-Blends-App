//
//  AddEditVehicleView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct AddEditVehicleView: View {
    @Environment(\.dismiss) private var dismiss

    let vehicle: VehicleProfile?
    let existingVehiclesCount: Int
    let onSave: (VehicleDraft) -> Void

    @State private var draft: VehicleDraft

    @MainActor
    init(
        vehicle: VehicleProfile?,
        existingVehiclesCount: Int,
        onSave: @escaping (VehicleDraft) -> Void
    ) {
        self.vehicle = vehicle
        self.existingVehiclesCount = existingVehiclesCount
        self.onSave = onSave
        _draft = State(initialValue: VehicleDraft(vehicle: vehicle, existingVehiclesCount: existingVehiclesCount))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formCard
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationTitle(vehicle == nil ? "Add Vehicle" : "Edit Vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.Colors.accentGreen)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                title: vehicle == nil ? "New Vehicle" : "Edit Vehicle",
                subtitle: "Save a profile for calculator defaults, fuel logs, and reminders."
            )

            StringInputField(title: "Nickname", text: $draft.nickname)
            identityFields
            metricsFields
            defaultsFields
            togglesSection
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var identityFields: some View {
        Group {
            StringInputField(title: "Year", text: $draft.year, keyboard: .numberPad)
            StringInputField(title: "Make", text: $draft.make)
            StringInputField(title: "Model", text: $draft.model)
            StringInputField(title: "Trim", text: $draft.trim)
        }
    }

    private var metricsFields: some View {
        Group {
            DoubleInputField(title: "Tank Size Gallons", value: $draft.tankSizeGallons, keyboard: .decimalPad)
            IntInputField(title: "Current Odometer", value: $draft.currentOdometer, keyboard: .numberPad)
            DoubleInputField(title: "Required Octane", value: $draft.requiredOctane, keyboard: .decimalPad)
        }
    }

    private var defaultsFields: some View {
        Group {
            SectionHeader(
                title: "Calculator Defaults",
                subtitle: "Used to prefill your blend setup on the calculator tab."
            )

            DoubleInputField(title: "Default Target Ethanol %", value: $draft.defaultTargetEthanolPercent, keyboard: .decimalPad)
            DoubleInputField(title: "Default Current Ethanol %", value: $draft.defaultCurrentEthanolPercent, keyboard: .decimalPad)
            DoubleInputField(title: "Default Pump Ethanol %", value: $draft.defaultPumpEthanolPercent, keyboard: .decimalPad)
            DoubleInputField(title: "Gas Ethanol %", value: $draft.gasEthanolPercent, keyboard: .decimalPad)
        }
    }

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToggleRow(title: "Flex Fuel Vehicle", isOn: $draft.isFlexFuel)
            ToggleRow(
                title: existingVehiclesCount == 0 ? "Active Vehicle (first vehicle auto-activates)" : "Set As Active Vehicle",
                isOn: $draft.isActive
            )
        }
    }
}

struct VehicleDraft {
    var nickname: String
    var year: String
    var make: String
    var model: String
    var trim: String
    var tankSizeGallons: Double
    var currentOdometer: Int
    var requiredOctane: Double
    var defaultTargetEthanolPercent: Double
    var defaultCurrentEthanolPercent: Double
    var defaultPumpEthanolPercent: Double
    var gasEthanolPercent: Double
    var isFlexFuel: Bool
    var isActive: Bool

    @MainActor
    init(vehicle: VehicleProfile?, existingVehiclesCount: Int) {
        nickname = vehicle?.nickname ?? ""
        year = vehicle?.year ?? ""
        make = vehicle?.make ?? ""
        model = vehicle?.model ?? ""
        trim = vehicle?.trim ?? ""
        tankSizeGallons = vehicle?.tankSizeGallons ?? 16
        currentOdometer = vehicle?.currentOdometer ?? 0
        requiredOctane = vehicle?.requiredOctane ?? 91
        defaultTargetEthanolPercent = vehicle?.defaultTargetEthanolPercent ?? 30
        defaultCurrentEthanolPercent = vehicle?.defaultCurrentEthanolPercent ?? 10
        defaultPumpEthanolPercent = vehicle?.defaultPumpEthanolPercent ?? 85
        gasEthanolPercent = vehicle?.gasEthanolPercent ?? 10
        isFlexFuel = vehicle?.isFlexFuel ?? false
        isActive = vehicle?.isActive ?? (existingVehiclesCount == 0)
    }
}

private struct StringInputField: View {
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

private struct IntInputField: View {
    let title: String
    @Binding var value: Int
    var keyboard: UIKeyboardType = .numberPad

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, value: $value, format: .number)
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

private struct DoubleInputField: View {
    let title: String
    @Binding var value: Double
    var keyboard: UIKeyboardType = .decimalPad

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, value: $value, format: .number)
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

private struct ToggleRow: View {
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

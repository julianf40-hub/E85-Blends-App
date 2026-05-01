//
//  AddEditFuelLogView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct AddEditFuelLogView: View {
    @Environment(\.dismiss) private var dismiss

    let entry: FuelLogEntry?
    let initialDraft: FuelLogDraft?
    let onSave: (FuelLogDraft) -> Void

    @State private var draft: FuelLogDraft

    @MainActor
    init(
        entry: FuelLogEntry?,
        initialDraft: FuelLogDraft? = nil,
        onSave: @escaping (FuelLogDraft) -> Void
    ) {
        self.entry = entry
        self.initialDraft = initialDraft
        self.onSave = onSave
        _draft = State(initialValue: FuelLogDraft(entry: entry, seed: initialDraft))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formCard
                }
                .padding(16)
            }
            .dismissKeyboardOnTap()
            .background(AppTheme.Colors.charcoal)
            .navigationTitle(entry == nil ? "Add Fill-Up" : "Edit Fill-Up")
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
        .keyboardDoneToolbar()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                title: entry == nil ? "New Fill-Up" : "Edit Fill-Up",
                subtitle: "Fuel totals are stored locally and blend outputs remain estimates."
            )

            DatePicker(
                "Date",
                selection: $draft.date,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .tint(AppTheme.Colors.accentGreen)
            .foregroundStyle(AppTheme.Colors.textPrimary)

            FuelStringInputField(title: "Vehicle Name", text: $draft.vehicleName)
            FuelStringInputField(title: "Station Name", text: $draft.stationName)
            FuelIntInputField(title: "Odometer", value: $draft.odometer)
            FuelDoubleInputField(title: "Target Blend Percent", value: $draft.targetBlendPercent)
            FuelDoubleInputField(title: "Final Blend Percent", value: $draft.finalBlendPercent)
            FuelDoubleInputField(title: "E85 Gallons", value: $draft.e85Gallons)
            FuelDoubleInputField(title: "Gas Gallons", value: $draft.gasGallons)
            FuelDoubleInputField(title: "E85 Price Per Gallon", value: $draft.e85PricePerGallon)
            FuelDoubleInputField(title: "Gas Price Per Gallon", value: $draft.gasPricePerGallon)

            SectionHeader(
                title: "Computed Values",
                subtitle: "Calculated from the gallons and price inputs below."
            )

            ComputedFuelValueRow(title: "Gallons Added", value: String(format: "%.2f", draft.computedGallonsAdded))
            ComputedFuelValueRow(title: "Total Cost", value: "$\(String(format: "%.2f", draft.computedTotalCost))")
            ComputedFuelValueRow(
                title: "MPG",
                value: draft.mpg > 0 ? String(format: "%.1f", draft.mpg) : "Calculated on save"
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Notes")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                TextField("Optional notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(4, reservesSpace: true)
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct FuelLogDraft {
    var date: Date
    var vehicleName: String
    var stationName: String
    var odometer: Int
    var targetBlendPercent: Double
    var finalBlendPercent: Double
    var e85Gallons: Double
    var gasGallons: Double
    var e85PricePerGallon: Double
    var gasPricePerGallon: Double
    var mpg: Double
    var notes: String

    var computedGallonsAdded: Double {
        e85Gallons + gasGallons
    }

    var computedTotalCost: Double {
        (e85Gallons * e85PricePerGallon) + (gasGallons * gasPricePerGallon)
    }

    init(
        date: Date,
        vehicleName: String,
        stationName: String,
        odometer: Int,
        targetBlendPercent: Double,
        finalBlendPercent: Double,
        e85Gallons: Double,
        gasGallons: Double,
        e85PricePerGallon: Double,
        gasPricePerGallon: Double,
        mpg: Double,
        notes: String
    ) {
        self.date = date
        self.vehicleName = vehicleName
        self.stationName = stationName
        self.odometer = odometer
        self.targetBlendPercent = targetBlendPercent
        self.finalBlendPercent = finalBlendPercent
        self.e85Gallons = e85Gallons
        self.gasGallons = gasGallons
        self.e85PricePerGallon = e85PricePerGallon
        self.gasPricePerGallon = gasPricePerGallon
        self.mpg = mpg
        self.notes = notes
    }

    @MainActor
    init(entry: FuelLogEntry?, seed: FuelLogDraft? = nil) {
        if let entry {
            date = entry.date
            vehicleName = entry.vehicleName
            stationName = entry.stationName
            odometer = entry.odometer
            targetBlendPercent = entry.targetBlendPercent
            finalBlendPercent = entry.finalBlendPercent
            e85Gallons = entry.e85Gallons
            gasGallons = entry.gasGallons
            e85PricePerGallon = entry.e85PricePerGallon
            gasPricePerGallon = entry.gasPricePerGallon
            mpg = entry.mpg
            notes = entry.notes
        } else if let seed {
            self = seed
        } else {
            date = .now
            vehicleName = ""
            stationName = ""
            odometer = 0
            targetBlendPercent = 30
            finalBlendPercent = 30
            e85Gallons = 0
            gasGallons = 0
            e85PricePerGallon = 0
            gasPricePerGallon = 0
            mpg = 0
            notes = ""
        }
    }
}

private struct FuelStringInputField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, text: $text)
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

private struct FuelIntInputField: View {
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

private struct FuelDoubleInputField: View {
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

private struct ComputedFuelValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .padding(14)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

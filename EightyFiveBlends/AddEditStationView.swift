//
//  AddEditStationView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

struct AddEditStationView: View {
    @Environment(\.dismiss) private var dismiss

    let station: FuelStation?
    let onSave: (StationDraft) -> Void

    @State private var draft: StationDraft

    @MainActor
    init(station: FuelStation?, onSave: @escaping (StationDraft) -> Void) {
        self.station = station
        self.onSave = onSave
        _draft = State(initialValue: StationDraft(station: station))
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
            .navigationTitle(station == nil ? "Add Station" : "Edit Station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.Colors.charcoal, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
                title: station == nil ? "New Station" : "Edit Station",
                subtitle: "Saved stations stay local until live search is added."
            )

            StationStringField(title: "Name", text: $draft.name)
            StationStringField(title: "Address", text: $draft.address)
            StationStringField(title: "City", text: $draft.city)
            StationStringField(title: "State", text: $draft.state)
            StationStringField(title: "Zip Code", text: $draft.zipCode)
            StationDoubleField(title: "Last Known E85 Price", value: $draft.lastKnownE85Price)

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

            Toggle(isOn: $draft.isFavorite) {
                Text("Favorite Station")
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 8)
    }
}

struct StationDraft {
    var name: String
    var address: String
    var city: String
    var state: String
    var zipCode: String
    var lastKnownE85Price: Double
    var notes: String
    var isFavorite: Bool

    @MainActor
    init(station: FuelStation?) {
        name = station?.name ?? ""
        address = station?.address ?? ""
        city = station?.city ?? ""
        state = station?.state ?? ""
        zipCode = station?.zipCode ?? ""
        lastKnownE85Price = station?.lastKnownE85Price ?? 0
        notes = station?.notes ?? ""
        isFavorite = station?.isFavorite ?? false
    }
}

private struct StationStringField: View {
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

private struct StationDoubleField: View {
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

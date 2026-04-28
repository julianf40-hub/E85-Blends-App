//
//  FuelLogView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData

struct FuelLogView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FuelLogEntry.date, order: .reverse)
    private var entries: [FuelLogEntry]
    @Query(filter: #Predicate<VehicleProfile> { $0.isActive == true })
    private var activeVehicles: [VehicleProfile]

    @State private var sheetContext: FuelLogSheetContext?
    @State private var entryPendingDeletion: FuelLogEntry?

    let initialDraft: FuelLogDraft?

    init(initialDraft: FuelLogDraft? = nil) {
        self.initialDraft = initialDraft
    }

    private var activeVehicle: VehicleProfile? {
        activeVehicles.first
    }

    private var totalSpent: Double {
        entries.reduce(0) { $0 + $1.totalCost }
    }

    private var averageMPG: Double {
        let validEntries = entries.filter { $0.mpg > 0 }
        guard validEntries.isEmpty == false else { return 0 }
        return validEntries.reduce(0) { $0 + $1.mpg } / Double(validEntries.count)
    }

    private var averageBlend: Double {
        guard entries.isEmpty == false else { return 0 }
        return entries.reduce(0) { $0 + $1.finalBlendPercent } / Double(entries.count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    summaryCard
                    entriesSection
                }
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationBarHidden(true)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .sheet(item: $sheetContext) { context in
            AddEditFuelLogView(entry: context.entry, initialDraft: context.draft) { draft in
                saveLog(from: draft, editing: context.entry)
            }
        }
        .onAppear {
            if let initialDraft {
                sheetContext = .add(initialDraft)
            }
        }
        .alert("Delete Fill-Up?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .destructive) {
                confirmDeletion()
            }
            Button("Cancel", role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: {
            Text("This fill-up entry will be removed from your log history.")
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TRACKING")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text("Fuel Log")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("Track spend, blends, and mileage over time.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Spacer()

            Button {
                sheetContext = .add(FuelLogStore.prefillDraft(from: activeVehicle))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("Add Fill-Up")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AppTheme.Colors.accentGreen)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                title: "Summary",
                subtitle: "Costs and blend estimates are based on your logged fill-ups."
            )

            HStack(spacing: 12) {
                summaryMetric(title: "Total Spent", value: "$\(String(format: "%.2f", totalSpent))")
                summaryMetric(title: "Average MPG", value: averageMPG > 0 ? String(format: "%.1f", averageMPG) : "--")
            }

            HStack(spacing: 12) {
                summaryMetric(title: "Average Blend", value: entries.isEmpty ? "--" : String(format: "E%.1f", averageBlend))
                summaryMetric(title: "Total Fill-Ups", value: "\(entries.count)")
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

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "History",
                subtitle: "Newest fill-ups first."
            )

            if entries.isEmpty {
                emptyStateCard
            } else {
                ForEach(entries) { entry in
                    FuelLogRowCard(
                        entry: entry,
                        editAction: { sheetContext = .edit(entry) },
                        deleteAction: { entryPendingDeletion = entry }
                    )
                }
            }
        }
    }

    private var emptyStateCard: some View {
        EmptyStateView(
            title: "No fill-ups logged yet.",
            message: "Add your first fill-up to start tracking costs, blend history, and mileage.",
            systemImage: "fuelpump"
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { entryPendingDeletion != nil },
            set: { isPresented in
                if isPresented == false {
                    entryPendingDeletion = nil
                }
            }
        )
    }

    private func saveLog(from draft: FuelLogDraft, editing entry: FuelLogEntry?) {
        FuelLogStore.save(
            draft: draft,
            editing: entry,
            entries: entries,
            activeVehicle: activeVehicle,
            modelContext: modelContext
        )
    }

    private func confirmDeletion() {
        guard let entryPendingDeletion else { return }
        modelContext.delete(entryPendingDeletion)
        try? modelContext.save()
        self.entryPendingDeletion = nil
        AppHaptics.warning()
    }

    private func summaryMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(metricColor(for: title))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func metricColor(for title: String) -> Color {
        switch title {
        case "Total Spent":
            AppTheme.Colors.primaryGreen
        case "Average Blend":
            AppTheme.Colors.stationYellow
        default:
            AppTheme.Colors.textPrimary
        }
    }

}

#Preview {
    FuelLogView()
        .modelContainer(for: [FuelLogEntry.self, VehicleProfile.self], inMemory: true)
}

private struct FuelLogSheetContext: Identifiable {
    let id = UUID()
    let entry: FuelLogEntry?
    let draft: FuelLogDraft?

    static func add(_ draft: FuelLogDraft? = nil) -> FuelLogSheetContext {
        FuelLogSheetContext(entry: nil, draft: draft)
    }

    static func edit(_ entry: FuelLogEntry) -> FuelLogSheetContext {
        FuelLogSheetContext(entry: entry, draft: nil)
    }
}

private struct FuelLogRowCard: View {
    let entry: FuelLogEntry
    let editAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "fuelpump.fill")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                        .frame(width: 40, height: 40)
                        .background(AppTheme.Colors.primaryGreen.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.vehicleName.isEmpty ? "Unknown Vehicle" : entry.vehicleName)
                            .font(.headline)
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text("$\(String(format: "%.2f", entry.totalCost))")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.accentGreen)

                    Text("E\(String(format: "%.1f", entry.finalBlendPercent))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppTheme.Colors.gasOrange.opacity(0.16))
                        .clipShape(Capsule())
                }
            }

            if entry.stationName.isEmpty == false {
                Text(entry.stationName)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            HStack(spacing: 18) {
                metric(title: "Blend", value: "E\(String(format: "%.1f", entry.finalBlendPercent))")
                metric(title: "Gallons", value: String(format: "%.2f", entry.gallonsAdded))
                metric(title: "MPG", value: entry.mpg > 0 ? String(format: "%.1f", entry.mpg) : "--")
                metric(title: "ODO", value: "\(entry.odometer)")
            }

            if entry.notes.isEmpty == false {
                Text(entry.notes)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            HStack(spacing: 10) {
                Button(action: editAction) {
                    Text("Edit")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AppTheme.Colors.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button(action: deleteAction) {
                    Text("Delete")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.95, green: 0.47, blue: 0.44))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppTheme.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AppTheme.Colors.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
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

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
    }
}

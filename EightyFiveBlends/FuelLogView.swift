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
    @Query(sort: \FuelStation.updatedAt, order: .reverse)
    private var stations: [FuelStation]

    @State private var sheetContext: FuelLogSheetContext?
    @State private var entryPendingDeletion: FuelLogEntry?
    @State private var communityReportContext: FuelLogCommunityReportContext?
    @State private var communityReportMessage: String?
    @State private var isSubmittingCommunityPrice = false

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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                summaryCard
                entriesSection
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .navigationTitle("Fuel Log")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheetContext) { context in
            AddEditFuelLogView(entry: context.entry, initialDraft: context.draft) { draft in
                saveLog(from: draft, editing: context.entry)
            }
        }
        .sheet(item: $communityReportContext) { context in
            FuelLogCommunityReportSheet(
                context: context,
                isSubmitting: isSubmittingCommunityPrice,
                reportAction: { submitCommunityPriceReport(for: context) },
                cancelAction: { communityReportContext = nil }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
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
        .alert("Fuel Log", isPresented: communityReportMessageBinding) {
            Button("OK", role: .cancel) {
                communityReportMessage = nil
            }
        } message: {
            Text(communityReportMessage ?? "")
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
        let outcome = FuelLogStore.save(
            draft: draft,
            editing: entry,
            entries: entries,
            activeVehicle: activeVehicle,
            modelContext: modelContext
        )

        guard outcome.shouldOfferCommunityPriceReport else { return }

        let station = matchedStation(for: outcome)
        communityReportContext = FuelLogCommunityReportContext(
            stationName: outcome.stationName,
            e85PricePerGallon: outcome.e85PricePerGallon,
            fillUpDate: outcome.fillUpDate,
            streetAddress: station?.address ?? outcome.linkedStation?.address ?? "",
            city: station?.city ?? outcome.linkedStation?.city ?? "",
            state: station?.state ?? outcome.linkedStation?.state ?? "",
            zipCode: station?.zipCode ?? outcome.linkedStation?.zipCode ?? "",
            latitude: station?.latitude ?? outcome.linkedStation?.latitude,
            longitude: station?.longitude ?? outcome.linkedStation?.longitude
        )
    }

    private func matchedStation(for outcome: FuelLogSaveOutcome) -> FuelStation? {
        let normalizedName = normalizedStationText(outcome.stationName)
        guard normalizedName.isEmpty == false else { return nil }
        return stations.first(where: { normalizedStationText($0.name) == normalizedName }) ?? outcome.linkedStation
    }

    private func submitCommunityPriceReport(for context: FuelLogCommunityReportContext) {
        guard isSubmittingCommunityPrice == false else { return }

        isSubmittingCommunityPrice = true

        Task {
            defer {
                Task { @MainActor in
                    isSubmittingCommunityPrice = false
                }
            }

            do {
                let service = try CommunityPriceService()
                let normalizedStationKey = normalizedStationKey(for: context)

                let station = try await service.upsertCommunityStation(
                    normalizedStationKey: normalizedStationKey,
                    name: context.stationName,
                    streetAddress: context.optionalStreetAddress,
                    city: context.optionalCity,
                    state: context.optionalState,
                    zip: context.optionalZipCode,
                    latitude: context.latitude,
                    longitude: context.longitude
                )

                _ = try await service.submitPriceReport(
                    normalizedStationKey: normalizedStationKey,
                    stationID: station.id,
                    price: context.e85PricePerGallon,
                    reportedAt: context.fillUpDate
                )

                await MainActor.run {
                    communityReportContext = nil
                    communityReportMessage = "Community E85 price reported."
                    AppHaptics.success()
                }
            } catch {
                await MainActor.run {
                    communityReportContext = nil
                    if let serviceError = error as? CommunityPriceServiceError,
                       case .notConfigured = serviceError {
                        communityReportMessage = "Community price sync is not configured yet."
                    } else {
                        communityReportMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func normalizedStationKey(for context: FuelLogCommunityReportContext) -> String {
        let components = [
            normalizedStationText(context.stationName),
            normalizedStationText(context.streetAddress),
            normalizedStationText(context.city),
            normalizedStationText(context.state),
            normalizedStationText(context.zipCode)
        ]
        .filter { $0.isEmpty == false }

        return components.joined(separator: "|")
    }

    private func normalizedStationText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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

    private var communityReportMessageBinding: Binding<Bool> {
        Binding(
            get: { communityReportMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    communityReportMessage = nil
                }
            }
        )
    }

}

#Preview {
    FuelLogView()
        .modelContainer(for: [FuelLogEntry.self, VehicleProfile.self, FuelStation.self], inMemory: true)
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

private struct FuelLogCommunityReportContext: Identifiable {
    let id = UUID()
    let stationName: String
    let e85PricePerGallon: Double
    let fillUpDate: Date
    let streetAddress: String
    let city: String
    let state: String
    let zipCode: String
    let latitude: Double?
    let longitude: Double?

    var optionalStreetAddress: String? {
        streetAddress.isEmpty ? nil : streetAddress
    }

    var optionalCity: String? {
        city.isEmpty ? nil : city
    }

    var optionalState: String? {
        state.isEmpty ? nil : state
    }

    var optionalZipCode: String? {
        zipCode.isEmpty ? nil : zipCode
    }
}

private struct FuelLogCommunityReportSheet: View {
    let context: FuelLogCommunityReportContext
    let isSubmitting: Bool
    let reportAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Report this E85 price?")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text("Community-reported. Verify at pump.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        reportRow(title: "Station", value: context.stationName)
                        reportRow(title: "E85 Price", value: "\(formattedPrice)/gal")
                        reportRow(title: "Fill-Up Date", value: context.fillUpDate.formatted(date: .abbreviated, time: .shortened))
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
                .padding(16)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationTitle("Report E85 Price")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now", action: cancelAction)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .disabled(isSubmitting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(action: reportAction) {
                        if isSubmitting {
                            ProgressView()
                                .tint(AppTheme.Colors.accentGreen)
                        } else {
                            Text("Report Price")
                                .foregroundStyle(AppTheme.Colors.accentGreen)
                        }
                    }
                    .disabled(isSubmitting)
                }
            }
        }
    }

    private func reportRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
    }

    private var formattedPrice: String {
        String(format: "$%.2f", context.e85PricePerGallon)
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

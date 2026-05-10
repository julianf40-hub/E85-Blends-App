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
    @State private var saveErrorMessage: String?

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

    private var totalGallons: Double {
        entries.reduce(0) { $0 + $1.gallonsAdded }
    }

    private var averageCostPerGallon: Double {
        guard totalGallons > 0 else { return 0 }
        return totalSpent / totalGallons
    }

    private var totalMilesDriven: Int {
        let vehicleGroups = Dictionary(grouping: entries.filter { $0.odometer > 0 }, by: \.vehicleName)
        var totalMiles = 0
        for (_, vehicleEntries) in vehicleGroups {
            let odometers = vehicleEntries.map(\.odometer)
            if let maxOdo = odometers.max(), let minOdo = odometers.min(), maxOdo > minOdo {
                totalMiles += maxOdo - minOdo
            }
        }
        return totalMiles
    }

    private var costPerMile: Double? {
        guard totalMilesDriven > 0, totalSpent > 0 else { return nil }
        return totalSpent / Double(totalMilesDriven)
    }

    private var mostUsedStation: String? {
        let stationNames = entries.compactMap { name in
            let trimmed = name.stationName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard stationNames.isEmpty == false else { return nil }
        let counts = Dictionary(grouping: stationNames, by: { $0.lowercased() })
        guard let topKey = counts.max(by: { $0.value.count < $1.value.count })?.key else { return nil }
        return stationNames.first(where: { $0.lowercased() == topKey })
    }

    private var averageE85Price: Double {
        let validEntries = entries.filter { $0.e85PricePerGallon > 0 }
        guard validEntries.isEmpty == false else { return 0 }
        return validEntries.reduce(0) { $0 + $1.e85PricePerGallon } / Double(validEntries.count)
    }

    private var mostRecentBlend: Double? {
        entries.first?.finalBlendPercent
    }

    private var thisMonthSpend: Double {
        let calendar = Calendar.current
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: .now)) else { return 0 }
        return entries.filter { $0.date >= startOfMonth }.reduce(0) { $0 + $1.totalCost }
    }

    private var thisMonthFillUps: Int {
        let calendar = Calendar.current
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: .now)) else { return 0 }
        return entries.filter { $0.date >= startOfMonth }.count
    }

    private var last30DaysSpend: Double {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) else { return 0 }
        return entries.filter { $0.date >= cutoff }.reduce(0) { $0 + $1.totalCost }
    }

    private var recentMPG: Double? {
        let valid = Array(entries.filter { $0.mpg > 0 }.prefix(3))
        guard valid.count >= 2 else { return nil }
        return valid.reduce(0) { $0 + $1.mpg } / Double(valid.count)
    }

    private var recentAverageBlend: Double? {
        let recent = Array(entries.prefix(3))
        guard recent.isEmpty == false else { return nil }
        return recent.reduce(0) { $0 + $1.finalBlendPercent } / Double(recent.count)
    }

    private var recentE85Price: Double? {
        let valid = Array(entries.filter { $0.e85PricePerGallon > 0 }.prefix(3))
        guard valid.isEmpty == false else { return nil }
        return valid.reduce(0) { $0 + $1.e85PricePerGallon } / Double(valid.count)
    }

    private var fuelingFrequencyDays: Int? {
        let sortedDates = entries.map(\.date).sorted()
        guard sortedDates.count >= 2,
              let first = sortedDates.first,
              let last = sortedDates.last else { return nil }
        let totalDays = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
        guard totalDays > 0 else { return nil }
        return totalDays / (sortedDates.count - 1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                summaryCard
                if entries.isEmpty == false {
                    insightsCard
                    trendsCard
                }
                entriesSection
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .navigationTitle("Fuel Log")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheetContext) { context in
            AddEditFuelLogView(entry: context.entry, initialDraft: context.draft) { draft in
                try saveLog(from: draft, editing: context.entry)
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
            .interactiveDismissDisabled(isSubmittingCommunityPrice)
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
        .alert(communityReportAlertTitle, isPresented: communityReportMessageBinding) {
            Button("OK", role: .cancel) {
                communityReportMessage = nil
            }
        } message: {
            Text(communityReportMessage ?? "")
        }
        .alert("Save Error", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
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

            HStack(spacing: 12) {
                summaryMetric(
                    title: "Avg Cost/Gal",
                    value: averageCostPerGallon > 0 ? String(format: "$%.2f", averageCostPerGallon) : "--"
                )
                summaryMetric(
                    title: "Cost/Mile",
                    value: costPerMile.map { String(format: "$%.2f", $0) } ?? "--"
                )
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
            title: "No Fill-Ups Yet",
            message: "Log your first fill-up to start tracking ethanol prices, blend history, and mileage over time.",
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

    private func saveLog(from draft: FuelLogDraft, editing entry: FuelLogEntry?) throws {
        let outcome = try FuelLogStore.save(
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
                    communityReportMessage = thankYouCommunityReportMessage
                    AppHaptics.success()
                }
            } catch {
                await MainActor.run {
                    communityReportContext = nil
                    if let serviceError = error as? CommunityPriceServiceError,
                       case .notConfigured = serviceError {
                        communityReportMessage = "Community price reporting is not available right now. Your fill-up was saved locally."
                    } else {
                        communityReportMessage = "Couldn’t reach community price reporting. Your fill-up was saved locally."
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
        do {
            try modelContext.save()
            AppHaptics.warning()
        } catch {
            #if DEBUG
            print("[85Blends] FuelLogView: entry deletion save failed:", error)
            #endif
            saveErrorMessage = "Couldn't delete entry. Please try again."
        }
        self.entryPendingDeletion = nil
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

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "Insights",
                subtitle: "Quick highlights from your fill-up history."
            )

            insightRow(
                icon: "fuelpump",
                text: "You have logged \(entries.count) fill-up\(entries.count == 1 ? "" : "s")."
            )

            if let mostRecentBlend {
                insightRow(
                    icon: "drop.fill",
                    text: "Most recent blend: E\(String(format: "%.0f", mostRecentBlend))",
                    accent: AppTheme.Colors.stationYellow
                )
            }

            if let mostUsedStation {
                insightRow(
                    icon: "mappin.circle.fill",
                    text: "Most used station: \(mostUsedStation)",
                    accent: AppTheme.Colors.stationYellow
                )
            }

            if averageE85Price > 0 {
                insightRow(
                    icon: "dollarsign.circle.fill",
                    text: "Average E85 price: \(String(format: "$%.2f", averageE85Price))/gal",
                    accent: AppTheme.Colors.primaryGreen
                )
            }

            if costPerMile == nil && entries.count < 2 {
                insightRow(
                    icon: "info.circle",
                    text: "Log more fill-ups to unlock cost-per-mile tracking.",
                    accent: AppTheme.Colors.textMuted
                )
            } else if costPerMile == nil {
                insightRow(
                    icon: "info.circle",
                    text: "Need odometer history to calculate cost per mile.",
                    accent: AppTheme.Colors.textMuted
                )
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

    private func insightRow(icon: String, text: String, accent: Color = AppTheme.Colors.textSecondary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(accent)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    private var trendsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "Recent Trends",
                subtitle: "Based on your most recent fill-ups."
            )

            HStack(spacing: 12) {
                trendMetric(
                    title: "This Month",
                    value: thisMonthFillUps > 0 ? String(format: "$%.2f", thisMonthSpend) : "--",
                    subtitle: thisMonthFillUps > 0 ? "\(thisMonthFillUps) fill-up\(thisMonthFillUps == 1 ? "" : "s")" : "No fill-ups this month",
                    accent: AppTheme.Colors.primaryGreen
                )
                trendMetric(
                    title: "Last 30 Days",
                    value: last30DaysSpend > 0 ? String(format: "$%.2f", last30DaysSpend) : "--",
                    subtitle: nil,
                    accent: AppTheme.Colors.primaryGreen
                )
            }

            HStack(spacing: 12) {
                trendMetric(
                    title: "Recent MPG",
                    value: recentMPG.map { String(format: "%.1f", $0) } ?? "--",
                    subtitle: recentMPG == nil ? "Need more fill-ups" : "Last 3 entries",
                    accent: AppTheme.Colors.textPrimary
                )
                trendMetric(
                    title: "Recent Blend",
                    value: recentAverageBlend.map { String(format: "E%.0f", $0) } ?? "--",
                    subtitle: recentAverageBlend != nil ? "Last 3 entries" : nil,
                    accent: AppTheme.Colors.stationYellow
                )
            }

            if let recentE85Price {
                insightRow(
                    icon: "dollarsign.circle.fill",
                    text: "Recent E85 price: \(String(format: "$%.2f", recentE85Price))/gal (last 3)",
                    accent: AppTheme.Colors.primaryGreen
                )
            }

            if let fuelingFrequencyDays {
                insightRow(
                    icon: "calendar.badge.clock",
                    text: "About every \(fuelingFrequencyDays) day\(fuelingFrequencyDays == 1 ? "" : "s")",
                    accent: AppTheme.Colors.stationYellow
                )
            } else if entries.count < 2 {
                insightRow(
                    icon: "calendar.badge.clock",
                    text: "Log more fill-ups to see fueling frequency.",
                    accent: AppTheme.Colors.textMuted
                )
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

    private func trendMetric(title: String, value: String, subtitle: String?, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(value == "--" ? AppTheme.Colors.textMuted : accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metricColor(for title: String) -> Color {
        switch title {
        case "Total Spent", "Avg Cost/Gal", "Cost/Mile":
            AppTheme.Colors.primaryGreen
        case "Average Blend":
            AppTheme.Colors.stationYellow
        default:
            AppTheme.Colors.textPrimary
        }
    }

    private var communityReportAlertTitle: String {
        communityReportMessage == thankYouCommunityReportMessage ? "Thank You! 🙌" : "Fuel Log"
    }

    private var thankYouCommunityReportMessage: String {
        "Your E85 price report is live and helps other drivers in your area find the best price."
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

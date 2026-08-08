//
//  CostCalculatorView.swift
//  EightyFiveBlends
//
//  "Compare Fuel Cost" — reachable from a Calculator entry card (Simple and Normal App
//  Experience Mode alike) and from More. Both open this exact view; there is no second,
//  duplicated calculator. Gallons/cost math comes from BlendCostMath.result(...) (shared, pure,
//  unit-tested) rather than a private reimplementation. Tank size and fuel prices auto-populate
//  read-only from the active vehicle and its most recent fuel log entries — see
//  FuelPriceLookup.swift — and nothing here ever writes to VehicleProfile, FuelLogEntry, or any
//  other stored data; this screen only reads.
//
//  Internal type/file name kept as CostCalculatorView (unchanged from before this pass) — only
//  the user-facing title changed, avoiding churn across the one other call site (MoreView).
//

import SwiftUI
import SwiftData

private enum BlendStrategy: String, CaseIterable, Identifiable {
    case e30 = "E30"
    case e50 = "E50"
    case e70 = "E70"
    case e85 = "E85"
    case custom = "Custom"

    var id: String { rawValue }

    var ethanolPercent: Double? {
        switch self {
        case .e30: return 30
        case .e50: return 50
        case .e70: return 70
        case .e85: return 85
        case .custom: return nil
        }
    }

    var tierLabel: String {
        switch self {
        case .e30: return "Daily / Range"
        case .e50: return "Balanced"
        case .e70: return "Performance"
        case .e85: return "Max Ethanol"
        case .custom: return "Custom"
        }
    }
}

private struct BlendCostResult {
    let ethanolPercent: Double
    let label: String
    let tierLabel: String
    let e85Gallons: Double
    let gasGallons: Double
    let tankCost: Double
    let savingsVsGasOnly: Double
}

struct CostCalculatorView: View {
    @Query(filter: #Predicate<VehicleProfile> { $0.isActive == true })
    private var activeVehicles: [VehicleProfile]
    @Query(sort: \FuelLogEntry.date, order: .reverse)
    private var fuelLogEntries: [FuelLogEntry]

    @State private var gallons = ""
    @State private var e85Price = ""
    @State private var gasPrice = ""
    @State private var selectedStrategy: BlendStrategy = .e85
    @State private var customBlendPercent: Double = 40
    @State private var didPrefill = false

    private var activeVehicle: VehicleProfile? { activeVehicles.first }
    private var gallonsValue: Double { Double(gallons) ?? 0 }
    private var e85PriceValue: Double { Double(e85Price) ?? 0 }
    private var gasPriceValue: Double { Double(gasPrice) ?? 0 }

    private var e85Ethanol: Double { activeVehicle?.defaultPumpEthanolPercent ?? 85 }
    private var gasEthanol: Double { activeVehicle?.gasEthanolPercent ?? 10 }

    private var selectedEthanolPercent: Double {
        selectedStrategy.ethanolPercent ?? customBlendPercent
    }

    private var hasBasicInputs: Bool {
        gallonsValue > 0 && e85PriceValue > 0 && gasPriceValue > 0
    }

    private var gasTankCost: Double { gallonsValue * gasPriceValue }

    private func blendResult(for ethanolPercent: Double, tierLabel: String) -> BlendCostResult? {
        guard let math = BlendCostMath.result(
            totalGallons: gallonsValue,
            targetEthanolPercent: ethanolPercent,
            e85EthanolPercent: e85Ethanol,
            gasEthanolPercent: gasEthanol,
            e85PricePerGallon: e85PriceValue,
            gasPricePerGallon: gasPriceValue
        ) else { return nil }

        return BlendCostResult(
            ethanolPercent: math.ethanolPercent,
            label: "E\(Int(math.ethanolPercent.rounded()))",
            tierLabel: tierLabel,
            e85Gallons: math.e85Gallons,
            gasGallons: math.gasGallons,
            tankCost: math.totalCost,
            savingsVsGasOnly: gasTankCost - math.totalCost
        )
    }

    private var selectedBlendResult: BlendCostResult? {
        guard hasBasicInputs else { return nil }
        return blendResult(for: selectedEthanolPercent, tierLabel: selectedStrategy.tierLabel)
    }

    private var comparisonBlends: [(strategy: BlendStrategy, result: BlendCostResult)] {
        [BlendStrategy.e30, .e50, .e70, .e85].compactMap { strategy in
            guard let pct = strategy.ethanolPercent,
                  let result = blendResult(for: pct, tierLabel: strategy.tierLabel) else { return nil }
            return (strategy, result)
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                tankSizeCard
                pricesCard
                blendStrategyCard

                if hasBasicInputs {
                    estimateAssumptionCard

                    if let result = selectedBlendResult {
                        selectedResultCard(result)
                    } else {
                        impossibleBlendCard
                    }

                    if comparisonBlends.isEmpty == false {
                        comparisonSection
                    }
                } else {
                    missingInputsCard
                }

                disclaimerCard
            }
            .padding(16)
        }
        .dismissKeyboardOnTap()
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("Compare Fuel Cost")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneToolbar()
        .onAppear {
            guard didPrefill == false else { return }
            didPrefill = true
            prefillFromActiveVehicleAndFuelLog()
        }
    }

    // Read-only initialization of the input fields — never writes to VehicleProfile,
    // FuelLogEntry, or any other stored data. Tank size only prefills from a vehicle with a
    // genuinely set (> 0) tank size; prices only prefill from the most recent fuel log entry for
    // this exact vehicle with a valid (finite, positive, plausible) recorded price. Anything not
    // found is left blank for manual entry rather than guessed. The user can freely overwrite
    // any prefilled value.
    private func prefillFromActiveVehicleAndFuelLog() {
        if let vehicle = activeVehicle, vehicle.tankSizeGallons > 0, gallons.isEmpty {
            gallons = formatInput(vehicle.tankSizeGallons)
        }

        guard let vehicleName = activeVehicle?.nickname, vehicleName.isEmpty == false else { return }

        if e85Price.isEmpty,
           let price = FuelPriceLookup.mostRecentValidPrice(
               in: fuelLogEntries, vehicleName: vehicleName, price: { $0.e85PricePerGallon }
           ) {
            e85Price = formatInput(price)
        }

        if gasPrice.isEmpty,
           let price = FuelPriceLookup.mostRecentValidPrice(
               in: fuelLogEntries, vehicleName: vehicleName, price: { $0.gasPricePerGallon }
           ) {
            gasPrice = formatInput(price)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BLEND COST COMPARISON")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text("Compare Fuel Cost")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("See what different ethanol blends cost compared to gasoline.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    // MARK: - Input Cards

    private var tankSizeCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Tank Size",
                    subtitle: activeVehicle.map { "Prefilled from \($0.nickname.isEmpty ? "active vehicle" : $0.nickname)." }
                        ?? "No active vehicle — enter your tank size manually."
                )
                costInputField(title: "Gallons", text: $gallons, placeholder: "15.5")
            }
        }
    }

    private var pricesCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Fuel Prices", subtitle: "Prefilled from your most recent fill-up when available — edit anytime.")
                costInputField(title: "E85 Price per Gallon", text: $e85Price, placeholder: "2.89")
                costInputField(title: "Gas Price per Gallon", text: $gasPrice, placeholder: "3.49")
            }
        }
    }

    private var blendStrategyCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Blend Strategy", subtitle: "Choose a target blend to compare against gasoline.")

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(BlendStrategy.allCases) { strategy in
                        let isSelected = selectedStrategy == strategy
                        Button {
                            AppHaptics.selection()
                            selectedStrategy = strategy
                        } label: {
                            Text(strategy.rawValue)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(isSelected ? AppTheme.Colors.charcoal : AppTheme.Colors.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.border, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if selectedStrategy == .custom, gasEthanol < e85Ethanol {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Target Ethanol: E\(Int(customBlendPercent.rounded()))")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.Colors.textMuted)

                        Slider(value: $customBlendPercent, in: gasEthanol...e85Ethanol, step: 5)
                            .tint(AppTheme.Colors.primaryGreen)
                    }
                }

                // Ethanol-content accuracy: E50/E70 name a target ethanol PERCENTAGE, not a
                // volumetric gasoline/E85 split — and E85 pump fuel itself isn't always exactly
                // 85% ethanol (see e85Ethanol above, which uses the vehicle's own recorded
                // value). Stated once here rather than repeated per chip.
                Text("Blends are target ethanol content, not a volumetric gasoline/E85 split.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var estimateAssumptionCard: some View {
        InfoCard(
            title: "What This Estimates",
            message: "Estimated cost to fill an empty \(tankSizeDisplayText) tank to the selected blend.",
            systemImage: "info.circle"
        )
    }

    private var tankSizeDisplayText: String {
        gallons.isEmpty ? "" : "\(formatInput(gallonsValue)) gal"
    }

    // MARK: - Selected Result

    private func selectedResultCard(_ result: BlendCostResult) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "\(result.label) Result", subtitle: result.tierLabel)

            HStack(spacing: 12) {
                resultMetric(title: "Gas-only cost", value: String(format: "$%.2f", gasTankCost), accent: AppTheme.Colors.gasOrange)
                resultMetric(title: "\(result.label) cost", value: String(format: "$%.2f", result.tankCost), accent: AppTheme.Colors.primaryGreen)
            }

            HStack(spacing: 12) {
                resultMetric(title: "E85 gallons", value: String(format: "%.1f", result.e85Gallons), accent: AppTheme.Colors.primaryGreen)
                resultMetric(title: "Gas gallons", value: String(format: "%.1f", result.gasGallons), accent: AppTheme.Colors.gasOrange)
            }

            savingsMessageView(result)
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

    private func savingsMessageView(_ result: BlendCostResult) -> some View {
        let saves = result.savingsVsGasOnly > 0
        let amount = abs(result.savingsVsGasOnly)

        return Text(saves
             ? "\(result.label) costs about \(String(format: "$%.2f", amount)) less than filling with gasoline only."
             : "\(result.label) costs about \(String(format: "$%.2f", amount)) more than filling with gasoline only.")
            .font(.title3.weight(.bold))
            .foregroundStyle(saves ? AppTheme.Colors.primaryGreen : AppTheme.Colors.warningRed)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(saves ? AppTheme.Colors.softGreenBackground.opacity(0.6) : AppTheme.Colors.warningRed.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(saves ? AppTheme.Colors.primaryGreen.opacity(0.5) : AppTheme.Colors.warningRed.opacity(0.4), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var impossibleBlendCard: some View {
        WarningCard(
            title: "Blend Not Possible",
            message: "E\(Int(selectedEthanolPercent.rounded())) cannot be reached with E\(Int(e85Ethanol.rounded())) pump fuel and E\(Int(gasEthanol.rounded())) gasoline."
        )
    }

    // MARK: - Comparison Section

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Blend Comparison", subtitle: "All common blends at current prices.")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(comparisonBlends, id: \.strategy) { item in
                    comparisonCard(strategy: item.strategy, result: item.result)
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

    private func comparisonCard(strategy: BlendStrategy, result: BlendCostResult) -> some View {
        let isSelected = selectedStrategy == strategy
        let saves = result.savingsVsGasOnly > 0

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(result.label)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.textPrimary)

                Spacer()

                if isSelected {
                    badgeView("Selected", color: AppTheme.Colors.primaryGreen)
                }
            }

            Text(result.tierLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.Colors.accentYellow)

            Text(String(format: "$%.2f", result.tankCost))
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(String(format: "%.1f gal E85 \u{00B7} %.1f gal gas", result.e85Gallons, result.gasGallons))
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(saves
                 ? String(format: "$%.2f less than gas-only", abs(result.savingsVsGasOnly))
                 : String(format: "$%.2f more than gas-only", abs(result.savingsVsGasOnly)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(saves ? AppTheme.Colors.primaryGreen : AppTheme.Colors.warningRed)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AppTheme.Colors.softGreenBackground.opacity(0.5) : AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? AppTheme.Colors.primaryGreen.opacity(0.6) : AppTheme.Colors.border, lineWidth: isSelected ? 1.2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func badgeView(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(AppTheme.Colors.charcoal)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color)
            .clipShape(Capsule())
    }

    // MARK: - Missing & Disclaimer

    private var missingInputsCard: some View {
        EmptyStateView(
            title: "Enter Values Above",
            message: "Fill in tank size, E85 price, and gas price to see your cost comparison.",
            systemImage: "dollarsign.circle"
        )
    }

    private var disclaimerCard: some View {
        WarningCard(
            title: "Estimates Only",
            message: "Actual cost depends on real pump prices, ethanol content, and tank fill amount."
        )
    }

    // MARK: - Helpers

    private func costInputField(title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(placeholder, text: text)
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

    private func resultMetric(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
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

    private func formatInput(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.1f", value)
    }
}

#Preview {
    NavigationStack {
        CostCalculatorView()
    }
    .modelContainer(for: [VehicleProfile.self, FuelLogEntry.self], inMemory: true)
}

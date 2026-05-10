//
//  CostCalculatorView.swift
//  EightyFiveBlends
//

import SwiftUI
import SwiftData

private enum BlendStrategy: String, CaseIterable, Identifiable {
    case e30 = "E30"
    case e50 = "E50"
    case e60 = "E60"
    case e85 = "E85"
    case custom = "Custom"

    var id: String { rawValue }

    var ethanolPercent: Double? {
        switch self {
        case .e30: return 30
        case .e50: return 50
        case .e60: return 60
        case .e85: return 85
        case .custom: return nil
        }
    }

    var tierLabel: String {
        switch self {
        case .e30: return "Daily / Range"
        case .e50: return "Balanced"
        case .e60: return "Performance"
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
    let estimatedRange: Double?
    let costPerMile: Double?
    let savingsPerTank: Double
}

struct CostCalculatorView: View {
    @Query(filter: #Predicate<VehicleProfile> { $0.isActive == true })
    private var activeVehicles: [VehicleProfile]

    @State private var gallons = ""
    @State private var e85Price = ""
    @State private var gasPrice = ""
    @State private var gasMPG = ""
    @State private var selectedGasGrade = "91"
    @State private var mpgLossPercent = 25
    @State private var selectedStrategy: BlendStrategy = .e85
    @State private var customBlendPercent: Double = 40
    @State private var didPrefill = false

    private let gasGrades = ["87", "89", "91", "93"]
    private let mpgLossOptions = [15, 20, 25, 30, 35]

    private var activeVehicle: VehicleProfile? { activeVehicles.first }
    private var gallonsValue: Double { Double(gallons) ?? 0 }
    private var e85PriceValue: Double { Double(e85Price) ?? 0 }
    private var gasPriceValue: Double { Double(gasPrice) ?? 0 }
    private var gasMPGValue: Double { Double(gasMPG) ?? 0 }

    private var e85Ethanol: Double { activeVehicle?.defaultPumpEthanolPercent ?? 85 }
    private var gasEthanol: Double { activeVehicle?.gasEthanolPercent ?? 10 }

    private var selectedEthanolPercent: Double {
        selectedStrategy.ethanolPercent ?? customBlendPercent
    }

    private var selectedBlendLabel: String {
        "E\(Int(selectedEthanolPercent.rounded()))"
    }

    private var hasBasicInputs: Bool {
        gallonsValue > 0 && e85PriceValue > 0 && gasPriceValue > 0
    }

    private var hasRangeInputs: Bool {
        hasBasicInputs && gasMPGValue > 0
    }

    private var gasTankCost: Double { gallonsValue * gasPriceValue }

    private var gasRange: Double? {
        gasMPGValue > 0 ? gasMPGValue * gallonsValue : nil
    }

    private var gasCostPerMile: Double? {
        guard let r = gasRange, r > 0 else { return nil }
        return gasTankCost / r
    }

    private func blendResult(for ethanolPercent: Double, tierLabel: String) -> BlendCostResult? {
        let delta = e85Ethanol - gasEthanol
        guard delta > 0 else { return nil }

        let fraction = (ethanolPercent - gasEthanol) / delta
        guard fraction >= 0, fraction <= 1 else { return nil }

        let e85Gal = gallonsValue * fraction
        let gasGal = gallonsValue * (1 - fraction)
        let cost = e85Gal * e85PriceValue + gasGal * gasPriceValue

        let scaledLoss = Double(mpgLossPercent) / 100.0 * fraction
        let blendMultiplier = 1 - scaledLoss

        let range: Double?
        let cpm: Double?
        if gasMPGValue > 0, blendMultiplier > 0 {
            let r = gasMPGValue * blendMultiplier * gallonsValue
            range = r
            cpm = r > 0 ? cost / r : nil
        } else {
            range = nil
            cpm = nil
        }

        let savings: Double
        if blendMultiplier > 0, gasMPGValue > 0 {
            savings = gasTankCost - cost / blendMultiplier
        } else {
            savings = gasTankCost - cost
        }

        return BlendCostResult(
            ethanolPercent: ethanolPercent,
            label: "E\(Int(ethanolPercent.rounded()))",
            tierLabel: tierLabel,
            e85Gallons: e85Gal,
            gasGallons: gasGal,
            tankCost: cost,
            estimatedRange: range,
            costPerMile: cpm,
            savingsPerTank: savings
        )
    }

    private var selectedBlendResult: BlendCostResult? {
        guard hasBasicInputs else { return nil }
        return blendResult(for: selectedEthanolPercent, tierLabel: selectedStrategy.tierLabel)
    }

    private var comparisonBlends: [(strategy: BlendStrategy, result: BlendCostResult)] {
        [BlendStrategy.e30, .e50, .e60, .e85].compactMap { strategy in
            guard let pct = strategy.ethanolPercent,
                  let result = blendResult(for: pct, tierLabel: strategy.tierLabel) else { return nil }
            return (strategy, result)
        }
    }

    private var cheapestPerMileStrategy: BlendStrategy? {
        comparisonBlends
            .filter { $0.result.costPerMile != nil }
            .min { ($0.result.costPerMile ?? .infinity) < ($1.result.costPerMile ?? .infinity) }?
            .strategy
    }

    private var bestRangeStrategy: BlendStrategy? {
        comparisonBlends
            .filter { $0.result.estimatedRange != nil }
            .max { ($0.result.estimatedRange ?? 0) < ($1.result.estimatedRange ?? 0) }?
            .strategy
    }

    private var breakEvenE85Price: Double? {
        guard hasRangeInputs else { return nil }
        let delta = e85Ethanol - gasEthanol
        guard delta > 0 else { return nil }

        let fraction = (selectedEthanolPercent - gasEthanol) / delta
        guard fraction > 0, fraction <= 1 else { return nil }

        let e85Gal = gallonsValue * fraction
        let gasGal = gallonsValue * (1 - fraction)
        let scaledLoss = Double(mpgLossPercent) / 100.0 * fraction
        let blendMultiplier = 1 - scaledLoss
        guard blendMultiplier > 0, e85Gal > 0 else { return nil }

        let price = gasPriceValue * (blendMultiplier * gallonsValue - gasGal) / e85Gal
        return price > 0 ? price : nil
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                tankSizeCard
                pricesCard
                gasGradeCard
                gasMPGCard
                mpgLossCard
                blendStrategyCard

                if hasBasicInputs {
                    if let result = selectedBlendResult {
                        selectedResultCard(result)
                    } else {
                        impossibleBlendCard
                    }

                    if comparisonBlends.isEmpty == false {
                        comparisonSection
                    }

                    if let breakEven = breakEvenE85Price {
                        breakEvenCard(breakEven)
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
        .navigationTitle("Cost Calculator")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneToolbar()
        .onAppear {
            guard didPrefill == false else { return }
            didPrefill = true
            if let vehicle = activeVehicle, gallons.isEmpty {
                gallons = formatInput(vehicle.tankSizeGallons)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BLEND COST COMPARISON")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text("Blend vs Gas")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("Compare blend cost, range, and savings against gasoline.")
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
                )
                costInputField(title: "Gallons", text: $gallons, placeholder: "15.5")
            }
        }
    }

    private var pricesCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Fuel Prices", subtitle: "Enter current pump prices near you.")
                costInputField(title: "E85 Price per Gallon", text: $e85Price, placeholder: "2.89")
                costInputField(title: "Gas Price per Gallon", text: $gasPrice, placeholder: "3.49")
            }
        }
    }

    private var gasGradeCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Gas Grade", subtitle: "Label only: calculations use the gas price you enter.")

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(gasGrades, id: \.self) { grade in
                        let isSelected = selectedGasGrade == grade
                        Button {
                            AppHaptics.selection()
                            selectedGasGrade = grade
                        } label: {
                            Text(grade)
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
            }
        }
    }

    private var gasMPGCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Gasoline MPG Estimate", subtitle: "Your typical MPG on gasoline. Enables range and cost-per-mile estimates.")
                costInputField(title: "MPG on Gas", text: $gasMPG, placeholder: "25")
            }
        }
    }

    private var mpgLossCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "E85 MPG Loss", subtitle: "E85 typically reduces fuel economy 15-35%. Loss is scaled for partial blends.")

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(mpgLossOptions, id: \.self) { option in
                        let isSelected = mpgLossPercent == option
                        Button {
                            AppHaptics.selection()
                            mpgLossPercent = option
                        } label: {
                            Text("\(option)%")
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
            }
        }
    }

    // MARK: - Selected Result

    private func selectedResultCard(_ result: BlendCostResult) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                title: "\(result.label) Result",
                subtitle: "\(result.tierLabel) \u{2014} adjusted for \(scaledLossLabel(for: result.ethanolPercent)) MPG loss."
            )

            HStack(spacing: 12) {
                resultMetric(title: "Gas tank cost", value: String(format: "$%.2f", gasTankCost), accent: AppTheme.Colors.gasOrange)
                resultMetric(title: "\(result.label) tank cost", value: String(format: "$%.2f", result.tankCost), accent: AppTheme.Colors.primaryGreen)
            }

            HStack(spacing: 12) {
                resultMetric(title: "E85 gallons", value: String(format: "%.1f", result.e85Gallons), accent: AppTheme.Colors.primaryGreen)
                resultMetric(title: "Gas gallons", value: String(format: "%.1f", result.gasGallons), accent: AppTheme.Colors.gasOrange)
            }

            if let gasR = gasRange, let blendR = result.estimatedRange {
                HStack(spacing: 12) {
                    resultMetric(title: "Gas range", value: String(format: "%.0f mi", gasR), accent: AppTheme.Colors.gasOrange)
                    resultMetric(title: "\(result.label) range", value: String(format: "%.0f mi", blendR), accent: AppTheme.Colors.primaryGreen)
                }
            }

            if let gasCPM = gasCostPerMile, let blendCPM = result.costPerMile {
                HStack(spacing: 12) {
                    resultMetric(title: "Gas \u{00A2}/mile", value: String(format: "%.1f\u{00A2}", gasCPM * 100), accent: AppTheme.Colors.gasOrange)
                    resultMetric(title: "\(result.label) \u{00A2}/mile", value: String(format: "%.1f\u{00A2}", blendCPM * 100), accent: AppTheme.Colors.primaryGreen)
                }
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
        let saves = result.savingsPerTank > 0
        let amount = abs(result.savingsPerTank)

        return VStack(alignment: .leading, spacing: 6) {
            Text(saves
                 ? "\(result.label) saves about \(String(format: "$%.2f", amount)) per tank."
                 : "Gas may be cheaper by about \(String(format: "$%.2f", amount)) per tank.")
                .font(.title3.weight(.bold))
                .foregroundStyle(saves ? AppTheme.Colors.primaryGreen : AppTheme.Colors.warningRed)

            Text(gasMPGValue > 0
                 ? "Compared over the same driving distance at \(scaledLossLabel(for: result.ethanolPercent)) MPG loss."
                 : "Enter gasoline MPG above to compare over the same driving distance.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
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
        let isCheapest = cheapestPerMileStrategy == strategy
        let isBestRange = bestRangeStrategy == strategy
        let saves = result.savingsPerTank > 0

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

            if let range = result.estimatedRange {
                Text(String(format: "%.0f mi", range))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            if let cpm = result.costPerMile {
                Text(String(format: "%.1f\u{00A2}/mi", cpm * 100))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Text(saves
                 ? String(format: "Saves $%.2f", abs(result.savingsPerTank))
                 : String(format: "+$%.2f", abs(result.savingsPerTank)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(saves ? AppTheme.Colors.primaryGreen : AppTheme.Colors.warningRed)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if isCheapest || isBestRange {
                HStack(spacing: 4) {
                    if isCheapest {
                        badgeView("Cheapest", color: AppTheme.Colors.primaryGreen)
                    }
                    if isBestRange {
                        badgeView("Best Range", color: AppTheme.Colors.rangeBlue)
                    }
                }
            }
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

    // MARK: - Break-Even

    private func breakEvenCard(_ price: Double) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(
                    title: "Break-Even E85 Price",
                    subtitle: "E85 needs to be under this price for \(selectedBlendLabel) to beat gas per mile."
                )

                Text(String(format: "$%.2f", price))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.stationYellow)

                Text("per gallon at \(scaledLossLabel(for: selectedEthanolPercent)) MPG loss vs \(selectedGasGrade)-octane at \(String(format: "$%.2f", gasPriceValue))")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                Text("E85 needs to be under \(String(format: "$%.2f", price))/gal to break even.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
            }
        }
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
            message: "Actual MPG depends on tune, ethanol content, driving style, and vehicle setup."
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

    private func scaledLossLabel(for ethanolPercent: Double) -> String {
        let delta = e85Ethanol - gasEthanol
        guard delta > 0 else { return "0%" }
        let fraction = (ethanolPercent - gasEthanol) / delta
        let scaledLoss = Double(mpgLossPercent) * fraction
        return String(format: "%.0f%%", scaledLoss)
    }

    private func formatInput(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.1f", value)
    }
}

#Preview {
    NavigationStack {
        CostCalculatorView()
    }
    .modelContainer(for: VehicleProfile.self, inMemory: true)
}

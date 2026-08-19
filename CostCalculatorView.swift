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

    // Pump Ethanol / Gas Ethanol are app-level "remembered" preferences now, not vehicle
    // properties (audit item 14) — resolved via the exact same centralized functions Calculator
    // and At The Pump use, so all three screens can never disagree.
    private var e85Ethanol: Double { PumpEthanolResolution.resolve(remembered: RememberedFuelPreferenceStore.rememberedPumpEthanolPercent()) }
    private var gasEthanol: Double { GasEthanolResolution.resolve(remembered: RememberedFuelPreferenceStore.rememberedGasEthanolPercent()) }

    private var selectedEthanolPercent: Double {
        selectedStrategy.ethanolPercent ?? customBlendPercent
    }

    private var hasBasicInputs: Bool {
        gallonsValue > 0 && e85PriceValue > 0 && gasPriceValue > 0
    }

    private var gasTankCost: Double { gallonsValue * gasPriceValue }

    // MARK: - Break-even

    // The maximum E85 pump price at which E85 still ties gasoline on cost-per-mile, using
    // FuelCostBreakEvenMath.e85MPGLossBenchmark. Depends only on the entered gas price —
    // never on the currently selected blend, so it stays a stable reference point as the
    // user switches between E30/E50/E70/E85/Custom above.
    private var e85PriceCeiling: Double? {
        FuelCostBreakEvenMath.e85PriceCeiling(gasolinePricePerGallon: gasPriceValue)
    }

    // Whether E85, at its current entered price, or gasoline is the better cost-per-mile
    // value right now. Always compares the entered E85 price against e85PriceCeiling — not
    // the selected blend's own math (see FuelCostBreakEvenMath's header comment for why
    // those two calculations must stay separate).
    private var breakEvenVerdict: FuelCostBreakEvenMath.Verdict? {
        guard let ceiling = e85PriceCeiling else { return nil }
        return FuelCostBreakEvenMath.verdict(currentE85PricePerGallon: e85PriceValue, ceiling: ceiling)
    }

    // How much MPG the given blend (typically the currently selected one) could lose at
    // today's entered prices before gasoline becomes cheaper per mile. Unlike
    // e85PriceCeiling, this DOES change with the selected blend, since it's derived from
    // that blend's own already-computed fill cost.
    private func maxAffordableMPGLossFraction(_ result: BlendCostResult) -> Double? {
        FuelCostBreakEvenMath.maxAffordableMPGLossFraction(blendFillCost: result.tankCost, gasOnlyFillCost: gasTankCost)
    }

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

                        if let ceiling = e85PriceCeiling, let verdict = breakEvenVerdict {
                            breakEvenCard(ceiling: ceiling, verdict: verdict, selectedResult: result)
                        }
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

    // MARK: - Break-Even Card

    // Answers the headline question this feature adds: "how expensive can E85 get before
    // gasoline is the better cost-per-mile value?" — plus, right below it, how much MPG the
    // currently selected blend could lose at today's prices before the same thing happens.
    // Color/heading are driven entirely by breakEvenVerdict (E85 price vs. e85PriceCeiling),
    // never by the selected blend's own numbers, so this card stays a stable answer to "is
    // E85 worth it right now" no matter which blend is being compared above it.
    private func breakEvenCard(
        ceiling: Double,
        verdict: FuelCostBreakEvenMath.Verdict,
        selectedResult: BlendCostResult
    ) -> some View {
        let accent = breakEvenAccentColor(verdict)
        let mpgLossFraction = maxAffordableMPGLossFraction(selectedResult)

        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Break-Even")

            Text(breakEvenHeadline(verdict))
                .font(.headline.weight(.bold))
                .foregroundStyle(accent)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                breakEvenRow(label: "E85 price ceiling", value: formattedPricePerGallon(ceiling))
                breakEvenRowDivider
                breakEvenRow(label: "Current E85", value: formattedPricePerGallon(e85PriceValue))
                breakEvenRowDivider
                breakEvenRow(label: "MPG break-even", value: mpgBreakEvenText(mpgLossFraction))
            }
            .padding(.horizontal, 14)
            .background(AppTheme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )

            Text(breakEvenHelperText(verdict, ceiling: ceiling))
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(breakEvenCardBackground(verdict))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(accent.opacity(verdict == .approximatelyEqual ? 0.35 : 0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // Combines label + value into one VoiceOver swipe ("E85 price ceiling, three dollars
    // and ninety cents per gallon") instead of two disconnected ones. The verdict itself is
    // always stated in words in breakEvenHeadline (a separate, normally-read Text above),
    // never communicated by color alone.
    private func breakEvenRow(label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .monospacedDigit()
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var breakEvenRowDivider: some View {
        Divider().overlay(AppTheme.Colors.borderColor)
    }

    private func breakEvenAccentColor(_ verdict: FuelCostBreakEvenMath.Verdict) -> Color {
        switch verdict {
        case .e85Better: return AppTheme.Colors.primaryGreen
        case .approximatelyEqual: return AppTheme.Colors.textPrimary
        case .gasolineBetter: return AppTheme.Colors.gasOrange
        }
    }

    private func breakEvenCardBackground(_ verdict: FuelCostBreakEvenMath.Verdict) -> Color {
        switch verdict {
        case .e85Better: return AppTheme.Colors.softGreenBackground.opacity(0.6)
        case .approximatelyEqual: return AppTheme.Colors.surfaceElevated
        case .gasolineBetter: return AppTheme.Colors.gasOrange.opacity(0.1)
        }
    }

    private func breakEvenHeadline(_ verdict: FuelCostBreakEvenMath.Verdict) -> String {
        switch verdict {
        case .e85Better: return "E85 is the better value at current prices."
        case .approximatelyEqual: return "About break-even per mile."
        case .gasolineBetter: return "Gasoline is the better value at current prices."
        }
    }

    private func breakEvenHelperText(_ verdict: FuelCostBreakEvenMath.Verdict, ceiling: Double) -> String {
        switch verdict {
        case .e85Better, .approximatelyEqual:
            return "Above \(formattedPricePerGallon(ceiling)), gasoline becomes the better cost-per-mile value using a \(Int((FuelCostBreakEvenMath.e85MPGLossBenchmark * 100).rounded()))% MPG-loss benchmark."
        case .gasolineBetter:
            return "E85 would need to be \(formattedPricePerGallon(ceiling)) or less to beat gasoline using a \(Int((FuelCostBreakEvenMath.e85MPGLossBenchmark * 100).rounded()))% MPG-loss benchmark."
        }
    }

    // Presentation only — the pure fraction comes from FuelCostBreakEvenMath, kept free of
    // display formatting. A negative fraction means the blend's fill already costs more than
    // gas-only at equal MPG, so there's no "loss allowance" to state (section 16: never
    // render a negative percentage as if it were one).
    private func mpgBreakEvenText(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        if fraction >= 0 {
            return "≤\(formattedPercent(fraction)) loss"
        }
        return "Gas cheaper at equal MPG"
    }

    private func formattedPricePerGallon(_ value: Double) -> String {
        String(format: "$%.2f/gal", value)
    }

    private func formattedPercent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
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

            // Current-price MPG break-even for THIS blend specifically (not the global E85
            // price ceiling shown above in breakEvenCard) — how much MPG this blend could
            // lose at today's prices before gasoline wins per mile.
            Text("Break-even: \(mpgBreakEvenText(FuelCostBreakEvenMath.maxAffordableMPGLossFraction(blendFillCost: result.tankCost, gasOnlyFillCost: gasTankCost)))")
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textMuted)
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
            message: "Actual cost per mile depends on pump prices, ethanol content, your vehicle's fuel economy, and actual fill amount. The E85 price ceiling above uses a general MPG-loss benchmark, not your vehicle's measured fuel economy."
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

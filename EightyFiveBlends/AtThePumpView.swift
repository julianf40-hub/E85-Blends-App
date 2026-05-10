//
//  AtThePumpView.swift
//  EightyFiveBlends
//
//  Created by Codex on 5/2/26.
//

import SwiftUI

struct AtThePumpView: View {
    let activeVehicle: VehicleProfile?
    let nearestStation: FuelStation?
    let locationAccessDenied: Bool
    let logFillUpAction: (BlendCalculator.Result) -> Void
    let closeAction: () -> Void

    @State private var tankSizeGallons: Double
    @State private var currentFuelLevelPercent: Double
    @State private var currentFuelEthanolPercent: Double
    @State private var targetEthanolPercent: Double
    @State private var e85EthanolPercent: Double
    @State private var gasEthanolPercent: Double
    @State private var e85Octane: Double
    @State private var gasOctane: Double
    @State private var currentEthanolInput: String
    @State private var isBlendGuideExpanded = true

    init(
        initialTankSizeGallons: Double,
        initialCurrentFuelLevelPercent: Double,
        initialCurrentFuelEthanolPercent: Double,
        initialTargetEthanolPercent: Double,
        initialE85EthanolPercent: Double,
        initialGasEthanolPercent: Double,
        initialE85Octane: Double,
        initialGasOctane: Double,
        activeVehicle: VehicleProfile?,
        nearestStation: FuelStation?,
        locationAccessDenied: Bool,
        logFillUpAction: @escaping (BlendCalculator.Result) -> Void,
        closeAction: @escaping () -> Void
    ) {
        self.activeVehicle = activeVehicle
        self.nearestStation = nearestStation
        self.locationAccessDenied = locationAccessDenied
        self.logFillUpAction = logFillUpAction
        self.closeAction = closeAction

        let resolvedTankSize = activeVehicle?.tankSizeGallons ?? initialTankSizeGallons
        let resolvedCurrentEthanol = activeVehicle?.defaultCurrentEthanolPercent ?? initialCurrentFuelEthanolPercent
        let resolvedTargetEthanol = activeVehicle?.defaultTargetEthanolPercent ?? initialTargetEthanolPercent
        let resolvedPumpEthanol = activeVehicle?.defaultPumpEthanolPercent ?? initialE85EthanolPercent
        let resolvedGasEthanol = activeVehicle?.gasEthanolPercent ?? initialGasEthanolPercent
        let resolvedGasOctane = activeVehicle?.requiredOctane ?? initialGasOctane

        _tankSizeGallons = State(initialValue: resolvedTankSize)
        _currentFuelLevelPercent = State(initialValue: initialCurrentFuelLevelPercent)
        _currentFuelEthanolPercent = State(initialValue: resolvedCurrentEthanol)
        _targetEthanolPercent = State(initialValue: resolvedTargetEthanol)
        _e85EthanolPercent = State(initialValue: resolvedPumpEthanol)
        _gasEthanolPercent = State(initialValue: resolvedGasEthanol)
        _e85Octane = State(initialValue: initialE85Octane)
        _gasOctane = State(initialValue: resolvedGasOctane)
        _currentEthanolInput = State(initialValue: AtThePumpView.formatInput(resolvedCurrentEthanol))
    }

    private var activeVehicleDisplayName: String {
        guard let activeVehicle else {
            return "No Vehicle Selected"
        }

        let vehicleName = activeVehicle.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return vehicleName.isEmpty ? "Unnamed Active Vehicle" : vehicleName
    }

    private var calculation: BlendCalculator.Result {
        BlendCalculator.calculate(
            input: .init(
                tankSizeGallons: tankSizeGallons,
                currentFuelLevelPercent: currentFuelLevelPercent,
                currentFuelEthanolPercent: currentFuelEthanolPercent,
                targetEthanolPercent: targetEthanolPercent,
                e85EthanolPercent: e85EthanolPercent,
                gasEthanolPercent: gasEthanolPercent,
                e85Octane: e85Octane,
                gasOctane: gasOctane
            )
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    vehicleCard
                    targetBlendCard
                    fuelLevelCard
                    currentEthanolCard
                    blendResultCard
                    pumpStepsCard
                    stationContextCard
                    safetyDisclaimer
                    actionButtons
                }
                .padding(16)
            }
            .dismissKeyboardOnTap()
            .background(AppTheme.Colors.charcoal)
            .navigationBarHidden(true)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .keyboardDoneToolbar()
    }

    private var headerCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("AT THE PUMP")
                    .font(.caption.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text("At the Pump")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(nearestStation.map { "At: \($0.name)" } ?? "Quick blend guidance while you fuel")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    private var vehicleCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Vehicle", subtitle: nil)

                Text(activeVehicleDisplayName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(activeVehicle == nil ? "Add or activate a vehicle in Garage to personalize pump mode." : "Using this Garage profile for pump mode.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    private var targetBlendCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isBlendGuideExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TARGET BLEND")
                                .font(.caption.weight(.bold))
                                .tracking(1.2)
                                .foregroundStyle(AppTheme.Colors.textMuted)

                            Text(isBlendGuideExpanded ? "Tap a guided tier to apply the pump-friendly target." : "Selected: \(selectedBlendLabel) \(selectedBlendTierTitle)")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.Colors.textSecondary)

                            if isBlendGuideExpanded == false {
                                Text("Tap to change")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(AppTheme.Colors.textMuted)
                            }
                        }

                        Spacer()

                        Image(systemName: isBlendGuideExpanded ? "chevron.up" : "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                .buttonStyle(.plain)

                if isBlendGuideExpanded {
                    Text("Tap a tier to apply")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    ForEach(pumpBlendTiers) { tier in
                        PumpBlendGuideRow(
                            tier: tier,
                            isActive: activeBlendTier?.id == tier.id,
                            selectedBlendValue: Int(targetEthanolPercent.rounded())
                        ) { selectedValue in
                            applyBlendSelection(selectedValue)
                        }
                    }
                } else {
                    collapsedBlendSummary
                }
            }
        }
    }

    private var fuelLevelCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Current Fuel Level", subtitle: "Current level: \(Int(currentFuelLevelPercent.rounded()))%")

                PumpPresetGrid(
                    items: [
                        .init(label: "Empty", value: 0),
                        .init(label: "1/4", value: 25),
                        .init(label: "1/2", value: 50),
                        .init(label: "3/4", value: 75),
                    ],
                    selectedValue: Int(currentFuelLevelPercent.rounded())
                ) { value in
                    currentFuelLevelPercent = Double(value)
                }
            }
        }
    }

    private var currentEthanolCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Current Ethanol %", subtitle: "Use E10 if you are unsure, or enter your ethanol test result.")

                PumpPresetGrid(
                    items: [
                        .init(label: "E10", value: 10),
                        .init(label: "E20", value: 20),
                        .init(label: "E30", value: 30),
                        .init(label: "E50", value: 50),
                        .init(label: "E70", value: 70),
                        .init(label: "E85", value: 85),
                    ],
                    selectedValue: Int(currentFuelEthanolPercent.rounded())
                ) { value in
                    setCurrentEthanol(Double(value))
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Manual Input")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.Colors.textMuted)

                        HStack(spacing: 10) {
                            TextField("10", text: $currentEthanolInput)
                                .keyboardType(.decimalPad)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .onChange(of: currentEthanolInput) { _, newValue in
                                    updateCurrentEthanol(from: newValue)
                                }

                            Text("%")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .background(AppTheme.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(AppTheme.Colors.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var blendResultCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Blend Result", subtitle: "Large numbers for quick pump-side reference.")

                HStack(spacing: 12) {
                    pumpMetricCard(title: "E85 gallons", value: String(format: "%.2f", calculation.e85Gallons), accent: AppTheme.Colors.primaryGreen)
                    pumpMetricCard(title: "Gas gallons", value: String(format: "%.2f", calculation.gasGallons), accent: AppTheme.Colors.gasOrange)
                }

                HStack(spacing: 12) {
                    compactMetricCard(title: "Final ethanol", value: String(format: "%.1f%%", calculation.finalEthanolPercent))
                    compactMetricCard(title: "Total to add", value: String(format: "%.2f gal", calculation.totalGallonsToAdd))
                }
            }
        }
    }

    private var pumpStepsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Pump Steps", subtitle: "Follow these in order.")

                pumpStep(number: 1, title: "Add E85 first", detail: "\(String(format: "%.2f", calculation.e85Gallons)) gallons")
                pumpStep(number: 2, title: "Top off with gas", detail: "\(String(format: "%.2f", calculation.gasGallons)) gallons")
                pumpStep(number: 3, title: "Log this fill-up", detail: "Save station, blend, and mileage")
            }
        }
    }

    private var stationContextCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Station Context", subtitle: nil)

                if let nearestStation {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(nearestStation.name)
                            .font(.headline)
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        if nearestStation.lastKnownE85Price > 0 {
                            Text(String(format: "Saved E85 price: $%.2f/gal", nearestStation.lastKnownE85Price))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.primaryGreen)
                        } else {
                            Text("No saved E85 price on this station yet.")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }

                        Text("Last updated \(formattedDate(nearestStation.lastUpdated))")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textMuted)
                    }
                } else {
                    Text(locationAccessDenied ? "Location Access Turned Off" : "No Nearby Station Detected")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text(locationAccessDenied ? "Enable location in Settings to detect nearby saved stations automatically." : "Save stations with coordinates in the Stations tab so they can be detected automatically next time.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
    }

    private var safetyDisclaimer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.Colors.accentYellow)
                .font(.subheadline)

            Text("Estimate only. Verify pump ethanol content and fuel compatibility.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.accentYellow.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            PrimaryButton(title: "Log This Fill-Up") {
                AppHaptics.selection()
                logFillUpAction(calculation)
            }

            SecondaryButton(title: "Close") {
                closeAction()
            }
        }
    }

    private var pumpBlendTiers: [PumpBlendTier] {
        [
            .init(
                range: "E20-E30",
                title: "Daily / Range",
                octane: "91-94 oct",
                description: "Best range with a modest ethanol bump.",
                rangeDots: 4,
                powerDots: 1,
                preferredBlend: 30
            ),
            .init(
                range: "E40-E50",
                title: "Balanced",
                octane: "95-98 oct",
                description: "A strong middle ground for street use.",
                rangeDots: 3,
                powerDots: 3,
                preferredBlend: 50
            ),
            .init(
                range: "E60-E70",
                title: "Performance",
                octane: "99-102 oct",
                description: "Higher ethanol for harder driving.",
                rangeDots: 2,
                powerDots: 4,
                preferredBlend: 70,
                alternateBlend: 60
            ),
            .init(
                range: "E85",
                title: "Highest Blend",
                octane: "105+ oct",
                description: "Highest common pump blend with the shortest range.",
                rangeDots: 1,
                powerDots: 5,
                preferredBlend: 85
            ),
        ]
    }

    private var activeBlendTier: PumpBlendTier? {
        let blend = Int(targetEthanolPercent.rounded())
        return pumpBlendTiers.first { $0.matches(blend: blend) }
    }

    private var selectedBlendLabel: String {
        "E\(Int(targetEthanolPercent.rounded()))"
    }

    private var selectedBlendTierTitle: String {
        activeBlendTier?.title ?? "Custom"
    }

    private var selectedBlendTierRange: String {
        activeBlendTier?.range ?? selectedBlendLabel
    }

    private var collapsedBlendSummary: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedBlendTierTitle)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("\(selectedBlendLabel) • \(selectedBlendTierRange)")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Spacer()

            Text("Tap to change")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func applyBlendSelection(_ selectedValue: Int) {
        AppHaptics.impact()
        targetEthanolPercent = Double(selectedValue)
        withAnimation(.easeInOut(duration: 0.22)) {
            isBlendGuideExpanded = false
        }
    }

    private func setCurrentEthanol(_ value: Double) {
        currentFuelEthanolPercent = value
        currentEthanolInput = Self.formatInput(value)
    }

    private func updateCurrentEthanol(from value: String) {
        let cleanedValue = value.filter { "0123456789.".contains($0) }

        if cleanedValue != value {
            currentEthanolInput = cleanedValue
            return
        }

        guard cleanedValue.isEmpty == false, let parsedValue = Double(cleanedValue) else {
            return
        }

        currentFuelEthanolPercent = parsedValue
    }

    private func fuelLevelTitle(for value: Int) -> String {
        switch value {
        case 0:
            return "Empty"
        case 25:
            return "1/4"
        case 50:
            return "1/2"
        case 75:
            return "3/4"
        default:
            return "\(value)%"
        }
    }

    private func pumpMetricCard(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text(value)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(accent.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func compactMetricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func pumpStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline.weight(.bold))
                .foregroundStyle(AppTheme.Colors.charcoal)
                .frame(width: 34, height: 34)
                .background(AppTheme.Colors.primaryGreen)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(detail)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func formatInput(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }

        return String(format: "%.1f", value)
    }
}
private struct PumpPresetItem: Identifiable {
    let label: String
    let value: Int

    var id: Int { value }
}

private struct PumpPresetGrid: View {
    let items: [PumpPresetItem]
    let selectedValue: Int
    let action: (Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                let isSelected = item.value == selectedValue

                Button {
                    AppHaptics.selection()
                    action(item.value)
                } label: {
                    Text(item.label)
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
                .accessibilityLabel("Set target blend to \(item.label)")
            }
        }
    }
}

private struct PumpBlendTier: Identifiable {
    let range: String
    let title: String
    let octane: String
    let description: String
    let rangeDots: Int
    let powerDots: Int
    let preferredBlend: Int
    var alternateBlend: Int? = nil

    var id: String { range }

    func matches(blend: Int) -> Bool {
        switch range {
        case "E20-E30":
            return blend == 20 || blend == 30
        case "E40-E50":
            return blend == 40 || blend == 50
        case "E60-E70":
            return blend == 60 || blend == 70
        case "E85":
            return blend == 85
        default:
            return false
        }
    }
}

private struct PumpBlendGuideRow: View {
    let tier: PumpBlendTier
    let isActive: Bool
    let selectedBlendValue: Int
    let applyAction: (Int) -> Void

    var body: some View {
        Button {
            applyAction(tier.preferredBlend)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tier.range)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isActive ? AppTheme.Colors.primaryGreen : AppTheme.Colors.textMuted)

                        Text(tier.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text(tier.octane)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.accentYellow)
                    }

                    Spacer()

                    if isActive {
                        Text("Active")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AppTheme.Colors.softGreenBackground)
                            .clipShape(Capsule())
                    }
                }

                Text(tier.description)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(2)

                HStack(spacing: 16) {
                    indicatorRow(title: "Range", filledDots: tier.rangeDots)
                    indicatorRow(title: "Power", filledDots: tier.powerDots)
                }

                if let alternateBlend = tier.alternateBlend {
                    HStack(spacing: 8) {
                        miniBlendButton("E60", value: 60)
                        miniBlendButton("E70", value: alternateBlend)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? AppTheme.Colors.softGreenBackground.opacity(0.78) : AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isActive ? AppTheme.Colors.primaryGreen.opacity(0.75) : AppTheme.Colors.borderColor, lineWidth: isActive ? 1.2 : 1)
            )
            .shadow(color: isActive ? AppTheme.Colors.primaryGreen.opacity(0.12) : .clear, radius: 10, y: 4)
            .scaleEffect(isActive ? 1.01 : 1)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PumpBlendGuideButtonStyle(isActive: isActive))
        .accessibilityLabel("Apply \(tier.title), \(tier.range)")
        .animation(.spring(response: 0.28, dampingFraction: 0.74), value: isActive)
    }

    private func indicatorRow(title: String, filledDots: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            HStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(index < filledDots ? (title == "Range" ? AppTheme.Colors.rangeBlue : AppTheme.Colors.powerRed) : AppTheme.Colors.borderColor)
                        .frame(width: 8, height: 8)
                }
            }
        }
    }

    private func miniBlendButton(_ title: String, value: Int) -> some View {
        let isSelected = selectedBlendValue == value

        return Button {
            applyAction(value)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? AppTheme.Colors.charcoal : AppTheme.Colors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? AppTheme.Colors.primaryGreen : AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set target blend to \(title)")
    }
}

private struct PumpBlendGuideButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.992 : 1)
            .opacity(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.01 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.74), value: isActive)
    }
}

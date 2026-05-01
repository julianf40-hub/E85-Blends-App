//
//  CalculatorView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData

struct CalculatorView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppPreferenceKey.defaultTargetBlend) private var preferredDefaultTargetBlend = BlendPreferenceOption.e30.rawValue
    @Query(filter: #Predicate<VehicleProfile> { $0.isActive == true })
    private var activeVehicles: [VehicleProfile]
    @Query(sort: \FuelLogEntry.date, order: .reverse)
    private var fuelLogEntries: [FuelLogEntry]

    @State private var selectedBlend = "E50"
    @State private var isGuideExpanded = false
    @State private var isAdvancedExpanded = false
    @State private var isInstructionsExpanded = false
    @State private var tankSize = "15.5"
    @State private var currentLevel = "25"
    @State private var currentFuelEthanol = "20"
    @State private var targetFuelEthanol = "50"
    @State private var e85Ethanol = "82"
    @State private var e85Octane = "105"
    @State private var gasEthanol = "10"
    @State private var gasOctane = "91"
    @State private var blendName = ""
    @State private var loadedDefaultsKey = ""
    @State private var calculatorFuelLogDraft: FuelLogDraft?
    @State private var infoMessage: String?

    private var fallbackDefaults: CalculatorDefaults {
        CalculatorDefaults(
            nickname: "No Vehicle Selected",
            tankSizeGallons: 16,
            targetEthanolPercent: preferredTargetBlendValue,
            currentEthanolPercent: 10,
            pumpEthanolPercent: 85,
            gasEthanolPercent: 10,
            gasOctane: 91
        )
    }

    private var activeVehicle: VehicleProfile? {
        activeVehicles.first
    }

    private var activeVehicleKey: String {
        guard let activeVehicle else {
            return "no-vehicle"
        }

        return [
            activeVehicle.nickname,
            String(activeVehicle.createdAt.timeIntervalSinceReferenceDate),
            String(activeVehicle.updatedAt.timeIntervalSinceReferenceDate),
            String(activeVehicle.tankSizeGallons),
            String(activeVehicle.defaultTargetEthanolPercent),
            String(activeVehicle.defaultCurrentEthanolPercent),
            String(activeVehicle.defaultPumpEthanolPercent),
            String(activeVehicle.gasEthanolPercent),
            String(activeVehicle.requiredOctane),
        ].joined(separator: "|")
    }

    private var headerNickname: String {
        guard let activeVehicle, activeVehicle.nickname.isEmpty == false else {
            return fallbackDefaults.nickname
        }

        return activeVehicle.nickname
    }

    private var showsVehicleHint: Bool {
        activeVehicle == nil
    }

    private var calculation: BlendCalculator.Result {
        BlendCalculator.calculate(
            input: .init(
                tankSizeGallons: doubleValue(from: tankSize),
                currentFuelLevelPercent: doubleValue(from: currentLevel),
                currentFuelEthanolPercent: doubleValue(from: currentFuelEthanol),
                targetEthanolPercent: doubleValue(from: targetFuelEthanol),
                e85EthanolPercent: doubleValue(from: e85Ethanol),
                gasEthanolPercent: doubleValue(from: gasEthanol),
                e85Octane: doubleValue(from: e85Octane),
                gasOctane: doubleValue(from: gasOctane)
            )
        )
    }

    private var preferredTargetBlendValue: Double {
        Double(preferredDefaultTargetBlend.dropFirst()) ?? 30
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection

                    if showsVehicleHint {
                        vehicleHintCard
                    }

                    TargetBlendSelector(
                        options: ["E20", "E30", "E40", "E50", "E60", "E85"],
                        selectedBlend: $selectedBlend,
                        targetFuelEthanol: $targetFuelEthanol
                    )

                    ExpandableSection(
                        title: "Blend Guide",
                        subtitle: "Range vs Power",
                        isExpanded: $isGuideExpanded
                    ) {
                        BlendGuideSection(
                            selectedBlend: $selectedBlend,
                            targetFuelEthanol: $targetFuelEthanol
                        )
                    }

                    TankInputSection(
                        tankSize: $tankSize,
                        currentLevel: $currentLevel,
                        currentFuelEthanol: $currentFuelEthanol,
                        targetFuelEthanol: $targetFuelEthanol
                    )

                    ExpandableSection(
                        title: "Show Advanced Settings",
                        subtitle: nil,
                        isExpanded: $isAdvancedExpanded
                    ) {
                        AdvancedSettingsSection(
                            e85Ethanol: $e85Ethanol,
                            e85Octane: $e85Octane,
                            gasEthanol: $gasEthanol,
                            gasOctane: $gasOctane
                        )
                    }

                    if let warningMessage = calculation.warningMessage {
                        WarningCard(title: "Blend Warning", message: warningMessage)
                    }

                    BlendResultCard(result: calculation)

                    BottomActionsSection(
                        blendName: $blendName,
                        saveBlendAction: {
                            AppHaptics.selection()
                            infoMessage = "Saved custom blend presets can be added in a future update."
                        },
                        findStationAction: {
                            AppHaptics.selection()
                            infoMessage = "Use the Stations tab to manage saved E85 stops until live search is added."
                        }
                    )

                    ExpandableSection(
                        title: "Pump Instructions",
                        subtitle: nil,
                        isExpanded: $isInstructionsExpanded
                    ) {
                        PumpInstructionsSection(result: calculation)
                    }

                    PrimaryButton(title: "+ Log This Fill-Up") {
                        calculatorFuelLogDraft = FuelLogStore.prefillDraft(from: calculation, vehicle: activeVehicle)
                    }
                }
                .padding(16)
            }
            .dismissKeyboardOnTap()
            .background(AppTheme.Colors.charcoal)
            .navigationBarHidden(true)
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .keyboardDoneToolbar()
        .onAppear {
            applyDefaultsIfNeeded(for: activeVehicleKey)
        }
        .onChange(of: activeVehicleKey) { _, newValue in
            applyDefaultsIfNeeded(for: newValue)
        }
        .onChange(of: preferredDefaultTargetBlend) { _, _ in
            if activeVehicle == nil {
                loadedDefaultsKey = ""
                applyDefaultsIfNeeded(for: activeVehicleKey)
            }
        }
        .sheet(isPresented: calculatorFuelLogSheetBinding) {
            if let calculatorFuelLogDraft {
                AddEditFuelLogView(entry: nil, initialDraft: calculatorFuelLogDraft) { draft in
                    FuelLogStore.save(
                        draft: draft,
                        editing: nil,
                        entries: fuelLogEntries,
                        activeVehicle: activeVehicle,
                        modelContext: modelContext
                    )
                    self.calculatorFuelLogDraft = nil
                }
            }
        }
        .alert("Coming Soon", isPresented: infoAlertBinding) {
            Button("OK", role: .cancel) {
                infoMessage = nil
            }
        } message: {
            Text(infoMessage ?? "")
        }
    }

    private func doubleValue(from string: String) -> Double {
        Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private var calculatorFuelLogSheetBinding: Binding<Bool> {
        Binding(
            get: { calculatorFuelLogDraft != nil },
            set: { isPresented in
                if isPresented == false {
                    calculatorFuelLogDraft = nil
                }
            }
        )
    }

    private var infoAlertBinding: Binding<Bool> {
        Binding(
            get: { infoMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    infoMessage = nil
                }
            }
        )
    }

    private func formatted(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }

        return String(format: "%.1f", value)
    }

    private func nearestBlendChip(for value: Double) -> String {
        let options = [20.0, 30.0, 40.0, 50.0, 60.0, 85.0]
        let nearest = options.min { abs($0 - value) < abs($1 - value) } ?? 30
        return "E\(Int(nearest))"
    }

    @MainActor
    private func applyDefaultsIfNeeded(for key: String) {
        guard loadedDefaultsKey != key else {
            return
        }

        let defaults = activeVehicle.map(CalculatorDefaults.init(vehicle:)) ?? fallbackDefaults

        tankSize = formatted(defaults.tankSizeGallons)
        targetFuelEthanol = formatted(defaults.targetEthanolPercent)
        currentFuelEthanol = formatted(defaults.currentEthanolPercent)
        e85Ethanol = formatted(defaults.pumpEthanolPercent)
        gasEthanol = formatted(defaults.gasEthanolPercent)
        gasOctane = formatted(defaults.gasOctane)
        selectedBlend = nearestBlendChip(for: defaults.targetEthanolPercent)
        loadedDefaultsKey = key
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BLEND TOOL")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text("E85 Calculator")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(headerNickname)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            Spacer()

            Button {
                AppHaptics.selection()
                infoMessage = "Pump-specific station lookup and route tools can be added in a later update."
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "fuelpump.fill")
                    Text("Pump")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AppTheme.Colors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var vehicleHintCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "car.circle")
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.accentYellow)

            Text("Add a vehicle in Garage to auto-fill your calculator defaults.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

}

#Preview {
    CalculatorView()
        .modelContainer(for: [VehicleProfile.self, FuelLogEntry.self], inMemory: true)
}

private struct CalculatorDefaults {
    let nickname: String
    let tankSizeGallons: Double
    let targetEthanolPercent: Double
    let currentEthanolPercent: Double
    let pumpEthanolPercent: Double
    let gasEthanolPercent: Double
    let gasOctane: Double

    init(
        nickname: String,
        tankSizeGallons: Double,
        targetEthanolPercent: Double,
        currentEthanolPercent: Double,
        pumpEthanolPercent: Double,
        gasEthanolPercent: Double,
        gasOctane: Double
    ) {
        self.nickname = nickname
        self.tankSizeGallons = tankSizeGallons
        self.targetEthanolPercent = targetEthanolPercent
        self.currentEthanolPercent = currentEthanolPercent
        self.pumpEthanolPercent = pumpEthanolPercent
        self.gasEthanolPercent = gasEthanolPercent
        self.gasOctane = gasOctane
    }

    init(vehicle: VehicleProfile) {
        nickname = vehicle.nickname.isEmpty ? "No Vehicle Selected" : vehicle.nickname
        tankSizeGallons = vehicle.tankSizeGallons > 0 ? vehicle.tankSizeGallons : 16
        targetEthanolPercent = vehicle.defaultTargetEthanolPercent
        currentEthanolPercent = vehicle.defaultCurrentEthanolPercent
        pumpEthanolPercent = vehicle.defaultPumpEthanolPercent
        gasEthanolPercent = vehicle.gasEthanolPercent
        gasOctane = vehicle.requiredOctane
    }
}

private struct TargetBlendSelector: View {
    let options: [String]
    @Binding var selectedBlend: String
    @Binding var targetFuelEthanol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Target Blend")
                .font(.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(options, id: \.self) { blend in
                        Button {
                            AppHaptics.selection()
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                                selectedBlend = blend
                                targetFuelEthanol = String(blend.dropFirst())
                            }
                        } label: {
                            Text(blend)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(
                                    selectedBlend == blend
                                    ? AppTheme.Colors.textPrimary
                                    : AppTheme.Colors.textSecondary
                                )
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    selectedBlend == blend
                                    ? AppTheme.Colors.primaryGreen
                                    : AppTheme.Colors.cardBackground
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(
                                            selectedBlend == blend
                                            ? AppTheme.Colors.primaryGreen.opacity(0.95)
                                            : AppTheme.Colors.borderColor,
                                            lineWidth: 1
                                        )
                                )
                                .scaleEffect(selectedBlend == blend ? 1.04 : 1)
                                .opacity(selectedBlend == blend ? 1 : 0.88)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: selectedBlend)
                    }
                }
            }
        }
    }
}

private struct TankInputSection: View {
    @Binding var tankSize: String
    @Binding var currentLevel: String
    @Binding var currentFuelEthanol: String
    @Binding var targetFuelEthanol: String

    var body: some View {
        CalculatorCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tank Info")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                inputRow(title: "Tank Size", value: $tankSize, suffix: "gal", keyboard: .decimalPad)
                inputRow(title: "Current Level (%)", value: $currentLevel, suffix: "%", keyboard: .decimalPad)

                HStack(spacing: 10) {
                    quickLevelButton("E", value: "0")
                    quickLevelButton("1/4", value: "25")
                    quickLevelButton("1/2", value: "50")
                    quickLevelButton("3/4", value: "75")
                }

                inputRow(title: "Current Fuel Ethanol %", value: $currentFuelEthanol, suffix: "%", keyboard: .decimalPad)
                inputRow(title: "Target Ethanol %", value: $targetFuelEthanol, suffix: "%", keyboard: .decimalPad)
            }
        }
    }

    private func inputRow(title: String, value: Binding<String>, suffix: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            HStack {
                TextField("", text: value)
                    .keyboardType(keyboard)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(suffix)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
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

    private func quickLevelButton(_ title: String, value: String) -> some View {
        Button {
            currentLevel = value
        } label: {
            Text(title)
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
    }
}

private struct BlendResultCard: View {
    let result: BlendCalculator.Result

    var body: some View {
        CalculatorCard {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("\(result.blendLabel)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(AppTheme.Colors.primaryGreen.opacity(0.22))
                        .clipShape(Capsule())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Blend Result")
                            .font(.headline)
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        Text("Estimated using your current tank and fuel assumptions.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                HStack(spacing: 14) {
                    metricTile(title: "E85 gallons", value: String(format: "%.2f", result.e85Gallons), accent: AppTheme.Colors.primaryGreen)
                    metricTile(title: "Gas gallons", value: String(format: "%.2f", result.gasGallons), accent: AppTheme.Colors.gasOrange)
                    metricTile(title: "Estimated octane", value: String(format: "%.1f", result.estimatedOctane), accent: AppTheme.Colors.primaryGreen)
                }

                Divider()
                    .overlay(AppTheme.Colors.border)

                HStack(alignment: .top) {
                    detailMetric(title: "Final ethanol %", value: String(format: "%.1f%%", result.finalEthanolPercent))
                    Spacer()
                    detailMetric(title: "Total gallons to add", value: String(format: "%.2f gal", result.totalGallonsToAdd))
                }
            }
            .padding(2)
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(AppTheme.Colors.elevatedCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(AppTheme.Colors.primaryGreen.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func metricTile(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .minimumScaleFactor(0.8)
                .lineLimit(1)

            Rectangle()
                .fill(accent.opacity(0.75))
                .frame(width: 28, height: 3)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 16)
        .background(AppTheme.Colors.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func detailMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
    }
}

private struct BottomActionsSection: View {
    @Binding var blendName: String
    let saveBlendAction: () -> Void
    let findStationAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button(action: saveBlendAction) {
                    Label("Save Blend", systemImage: "bookmark.fill")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(AppTheme.Colors.primaryGreen.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(AppTheme.Colors.primaryGreen.opacity(0.8), lineWidth: 1.2)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(ScalePressButtonStyle())

                Button(action: findStationAction) {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill")
                        Text("Find Station")
                    }
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppTheme.Colors.gasOrange.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.Colors.gasOrange.opacity(0.9), lineWidth: 1.2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(ScalePressButtonStyle())
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name this blend (optional, e.g. Track Day E50)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                TextField("Track Day E50", text: $blendName)
                    .textInputAutocapitalization(.words)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

private struct BlendGuideSection: View {
    @Binding var selectedBlend: String
    @Binding var targetFuelEthanol: String

    private let tiers: [BlendGuideTier] = [
        .init(
            range: "E20-E30",
            title: "Daily / Range",
            octane: "91-94 oct",
            description: "Best range with a modest ethanol bump.",
            rangeDots: 4,
            powerDots: 1
        ),
        .init(
            range: "E40-E50",
            title: "Balanced",
            octane: "95-98 oct",
            description: "A strong middle ground for street use.",
            rangeDots: 3,
            powerDots: 3
        ),
        .init(
            range: "E60-E70",
            title: "Performance",
            octane: "99-102 oct",
            description: "Higher ethanol for harder driving.",
            rangeDots: 2,
            powerDots: 4
        ),
        .init(
            range: "E85",
            title: "Highest Blend",
            octane: "105+ oct",
            description: "Highest common pump blend with the shortest range.",
            rangeDots: 1,
            powerDots: 5
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tap a tier to apply")
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textMuted)

            ForEach(tiers) { tier in
                BlendGuideRow(
                    tier: tier,
                    isActive: tier.contains(blend: selectedBlend),
                    applyAction: { applyTier(tier) }
                )
            }
        }
    }

    private func applyTier(_ tier: BlendGuideTier) {
        let blend = tier.preferredBlend
        AppHaptics.impact()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.74)) {
            selectedBlend = blend
            targetFuelEthanol = String(blend.dropFirst())
        }
    }
}

private struct BlendGuideRow: View {
    let tier: BlendGuideTier
    let isActive: Bool
    let applyAction: () -> Void

    var body: some View {
        Button(action: applyAction) {
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
        .buttonStyle(BlendGuideTierButtonStyle(isActive: isActive))
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
}

private struct AdvancedSettingsSection: View {
    @Binding var e85Ethanol: String
    @Binding var e85Octane: String
    @Binding var gasEthanol: String
    @Binding var gasOctane: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fuel Properties")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            SettingsInputRow(title: "E85 Ethanol %", value: $e85Ethanol, suffix: "%")
            SettingsInputRow(title: "Gas Ethanol %", value: $gasEthanol, suffix: "%")
            SettingsInputRow(title: "E85 Octane", value: $e85Octane, suffix: "oct")
            SettingsInputRow(title: "Gas Octane", value: $gasOctane, suffix: "oct")

            VStack(alignment: .leading, spacing: 10) {
                Text("Quick Octane")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                HStack(spacing: 10) {
                    octaneButton("87")
                    octaneButton("89")
                    octaneButton("91")
                    octaneButton("93")
                }
            }
        }
    }

    private func octaneButton(_ value: String) -> some View {
        Button {
            gasOctane = value
        } label: {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(gasOctane == value ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(gasOctane == value ? AppTheme.Colors.gasOrange.opacity(0.22) : AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(gasOctane == value ? AppTheme.Colors.gasOrange : AppTheme.Colors.borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct PumpInstructionsSection: View {
    let result: BlendCalculator.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PumpInstructionStep(
                step: "Step 1",
                title: "Fill calculated gallons of E85 first",
                detail: "Start with \(String(format: "%.2f", result.e85Gallons)) gallons of E85 to anchor the blend."
            )

            PumpInstructionStep(
                step: "Step 2",
                title: "Top off with calculated gallons of gas",
                detail: "Add \(String(format: "%.2f", result.gasGallons)) gallons of pump gas to finish the mix."
            )

            PumpInstructionStep(
                step: "Step 3",
                title: "Result blend and octane",
                detail: "\(result.blendLabel) at roughly \(String(format: "%.1f", result.estimatedOctane)) octane with \(String(format: "%.2f", result.totalGallonsToAdd)) gallons added."
            )
        }
    }
}

private struct PumpInstructionStep: View {
    let step: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(step == "Step 1" ? AppTheme.Colors.primaryGreen : (step == "Step 2" ? AppTheme.Colors.gasOrange : AppTheme.Colors.stationYellow))
                .frame(width: 38, height: 38)
                .overlay(
                    Text(String(step.suffix(1)))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.black)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ScalePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct SettingsInputRow: View {
    let title: String
    @Binding var value: String
    let suffix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            HStack {
                TextField("", text: $value)
                    .keyboardType(.decimalPad)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(suffix)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct BlendGuideTier: Identifiable {
    let id = UUID()
    let range: String
    let title: String
    let octane: String
    let description: String
    let rangeDots: Int
    let powerDots: Int

    var preferredBlend: String {
        switch range {
        case "E20-E30":
            "E30"
        case "E40-E50":
            "E50"
        case "E60-E70":
            "E60"
        case "E85":
            "E85"
        default:
            "E30"
        }
    }

    func contains(blend: String) -> Bool {
        switch blend {
        case "E20", "E30":
            return range == "E20-E30"
        case "E40", "E50":
            return range == "E40-E50"
        case "E60":
            return range == "E60-E70"
        case "E85":
            return range == "E85"
        default:
            return false
        }
    }
}

private struct BlendGuideTierButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.04 : 0))
            )
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ExpandableSection<Content: View>: View {
    let title: String
    let subtitle: String?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        CalculatorCard {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let subtitle {
                                Text("\(title) — \(subtitle)")
                                    .font(.headline)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                            } else {
                                Text(title)
                                    .font(.headline)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                            }
                        }

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                if isExpanded {
                    content
                }
            }
        }
    }
}

private struct CalculatorCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.elevatedCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

//
//  AtThePumpView.swift
//  EightyFiveBlends
//
//  Created by Codex on 5/2/26.
//

import CoreLocation
import SwiftUI
import UIKit

struct AtThePumpView: View {
    /// What the user says is coming out of the pump hose today.
    enum PumpFuelOption: Int {
        case e85 = 0
        case gas = 1
        case custom = 2
    }

    let activeVehicle: VehicleProfile?
    /// Manually opened Pump Mode's station-context resolution — see
    /// `PumpModeStationContextState`/`PumpStationContextResolver`. Automatic-prompt and
    /// notification-driven opens settle this to `.matched` immediately (before the sheet
    /// is even presented); a manual open starts at `.resolving` and transitions once a
    /// fresh, bounded location fix has been resolved (see the `.onChange` in `body`).
    let stationContext: PumpModeStationContextState
    let locationAccessDenied: Bool
    /// Final blend from the newest fuel log for the active vehicle, if any — the
    /// smartest available default for "what's in the tank right now".
    let lastLoggedBlendPercent: Double?
    /// Fuel level restored from the last visit, if any — drives the "last used level"
    /// hint so we never imply the app knows the real gauge reading.
    private let restoredFuelLevelPercent: Double?
    /// Applies the user's choice from the ambiguous-candidate picker for this session only.
    let selectAmbiguousCandidateAction: (PumpStationContextCandidate) -> Void
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
    // Collapsed by default so the education content doesn't push the fuel inputs
    // below the fold — pump-side users need inputs and the answer first.
    @State private var isBlendGuideExpanded = false
    @State private var isBudgetExpanded = false

    // Phase 2 input state
    @State private var pumpFuelSelection: PumpFuelOption = .e85
    // "Max E85" target: track the intent, not just the number, so the target follows
    // the pump's E85 content if the user adjusts it afterwards.
    @State private var isMaxE85Selected = false
    @State private var isCustomFuelLevelVisible = false

    // Partial Fill state
    @State private var isPartialFillEnabled = false
    @State private var targetFuelLevelPercent: Double = 100
    @State private var e85PriceInput: String = ""
    @State private var gasPriceInput: String = ""
    @State private var budgetInput: String = ""
    /// True once the user has manually typed into the E85 price field — once set, a later
    /// station-context resolution must never silently overwrite what they typed.
    @State private var e85PriceUserEdited = false

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
        stationContext: PumpModeStationContextState,
        locationAccessDenied: Bool,
        lastLoggedBlendPercent: Double? = nil,
        selectAmbiguousCandidateAction: @escaping (PumpStationContextCandidate) -> Void,
        logFillUpAction: @escaping (BlendCalculator.Result) -> Void,
        closeAction: @escaping () -> Void
    ) {
        self.activeVehicle = activeVehicle
        self.stationContext = stationContext
        self.locationAccessDenied = locationAccessDenied
        self.lastLoggedBlendPercent = lastLoggedBlendPercent
        self.selectAmbiguousCandidateAction = selectAmbiguousCandidateAction
        self.logFillUpAction = logFillUpAction
        self.closeAction = closeAction

        // Saved last-visit setup (UI memory). Values are range-validated so a stale or
        // corrupt preference can never produce an out-of-range calculation.
        let saved = AtThePumpView.savedSetup()

        let resolvedTankSize = activeVehicle?.tankSizeGallons ?? initialTankSizeGallons
        // Precedence for "what's in the tank": last logged blend beats the vehicle's
        // static default, which beats whatever the calculator screen had typed in.
        // Saved setup deliberately never feeds this value.
        let resolvedCurrentEthanol = lastLoggedBlendPercent
            ?? activeVehicle?.defaultCurrentEthanolPercent
            ?? initialCurrentFuelEthanolPercent
        // Pump content: last visit beats generic defaults — the same pump usually
        // dispenses the same fuel next week. When restoring into Custom mode, clamp to
        // the Custom slider's range so the slider position and the math can't disagree.
        var resolvedPumpEthanol = saved.pumpE85Content
            ?? activeVehicle?.defaultPumpEthanolPercent
            ?? initialE85EthanolPercent
        if saved.fuelType == .custom {
            resolvedPumpEthanol = min(max(resolvedPumpEthanol, 50), 95)
        }
        // Target: "Max E85" intent is restored against today's pump content; otherwise
        // last visit's number, then the vehicle preference, then the calculator value.
        let resolvedTargetEthanol = saved.targetIsMaxE85
            ? resolvedPumpEthanol
            : (saved.targetBlend ?? activeVehicle?.defaultTargetEthanolPercent ?? initialTargetEthanolPercent)
        let resolvedFuelLevel = saved.fuelLevel ?? initialCurrentFuelLevelPercent
        let resolvedGasEthanol = activeVehicle?.gasEthanolPercent ?? initialGasEthanolPercent
        let resolvedGasOctane = activeVehicle?.requiredOctane ?? initialGasOctane

        restoredFuelLevelPercent = saved.fuelLevel

        _tankSizeGallons = State(initialValue: resolvedTankSize)
        _currentFuelLevelPercent = State(initialValue: resolvedFuelLevel)
        _currentFuelEthanolPercent = State(initialValue: resolvedCurrentEthanol)
        _targetEthanolPercent = State(initialValue: resolvedTargetEthanol)
        _e85EthanolPercent = State(initialValue: resolvedPumpEthanol)
        _gasEthanolPercent = State(initialValue: resolvedGasEthanol)
        _e85Octane = State(initialValue: initialE85Octane)
        _gasOctane = State(initialValue: resolvedGasOctane)
        _currentEthanolInput = State(initialValue: AtThePumpView.formatInput(resolvedCurrentEthanol))
        _pumpFuelSelection = State(initialValue: saved.fuelType)
        _isMaxE85Selected = State(initialValue: saved.targetIsMaxE85)

        // Pre-fill E85 price if a station context is already known at presentation time
        // (auto-prompt/notification opens resolve synchronously before the sheet
        // appears). A manually opened session usually starts at `.resolving` and picks
        // this up later via the `.onChange(of: stationContext)` in `body`, once a fresh
        // fix has actually been resolved — see `PumpStationContextResolver`.
        if case .matched(let candidate) = stationContext, let price = candidate.e85Price, price > 0 {
            _e85PriceInput = State(initialValue: String(format: "%.2f", price))
        }
    }

    // MARK: - Last setup memory

    private struct SavedPumpSetup {
        var targetBlend: Double?
        var targetIsMaxE85: Bool
        var pumpE85Content: Double?
        var fuelLevel: Double?
        var fuelType: PumpFuelOption
    }

    /// Reads and range-validates the last At the Pump setup from UserDefaults.
    private static func savedSetup() -> SavedPumpSetup {
        let defaults = UserDefaults.standard

        func validated(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            guard let value = defaults.object(forKey: key) as? Double,
                  value.isFinite,
                  range.contains(value) else {
                return nil
            }
            return value
        }

        let fuelType = (defaults.object(forKey: AppPreferenceKey.lastPumpFuelType) as? Int)
            .flatMap(PumpFuelOption.init(rawValue:)) ?? .e85
        let pumpContent = validated(AppPreferenceKey.lastPumpE85Content, 40...98)

        return SavedPumpSetup(
            targetBlend: validated(AppPreferenceKey.lastPumpTargetBlend, 5...98),
            // Max E85 intent only makes sense alongside a valid saved pump content.
            targetIsMaxE85: (defaults.object(forKey: AppPreferenceKey.lastPumpTargetIsMaxE85) as? Bool ?? false) && pumpContent != nil,
            pumpE85Content: pumpContent,
            fuelLevel: validated(AppPreferenceKey.lastPumpFuelLevel, 0...100),
            fuelType: fuelType
        )
    }

    private func persistLastPumpSetup() {
        let defaults = UserDefaults.standard
        defaults.set(targetEthanolPercent, forKey: AppPreferenceKey.lastPumpTargetBlend)
        defaults.set(isMaxE85Selected, forKey: AppPreferenceKey.lastPumpTargetIsMaxE85)
        defaults.set(e85EthanolPercent, forKey: AppPreferenceKey.lastPumpE85Content)
        defaults.set(currentFuelLevelPercent, forKey: AppPreferenceKey.lastPumpFuelLevel)
        defaults.set(pumpFuelSelection.rawValue, forKey: AppPreferenceKey.lastPumpFuelType)
    }

    private var isUsingRestoredFuelLevel: Bool {
        guard let restoredFuelLevelPercent else {
            return false
        }

        return abs(currentFuelLevelPercent - restoredFuelLevelPercent) < 0.05
    }

    // MARK: - Derived values

    private var activeVehicleDisplayName: String {
        guard let activeVehicle else {
            return "No Vehicle Selected"
        }

        let vehicleName = activeVehicle.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return vehicleName.isEmpty ? "Unnamed Active Vehicle" : vehicleName
    }

    private var calculationInput: BlendCalculator.Input {
        .init(
            tankSizeGallons: tankSizeGallons,
            currentFuelLevelPercent: currentFuelLevelPercent,
            currentFuelEthanolPercent: currentFuelEthanolPercent,
            targetEthanolPercent: targetEthanolPercent,
            e85EthanolPercent: e85EthanolPercent,
            gasEthanolPercent: gasEthanolPercent,
            e85Octane: e85Octane,
            gasOctane: gasOctane,
            targetFuelLevelPercent: isPartialFillEnabled ? targetFuelLevelPercent : nil
        )
    }

    private var calculation: BlendCalculator.Result {
        // "91" pump fuel means no E85 is going in — project where a gas-only fill
        // lands instead of solving for the target blend.
        if pumpFuelSelection == .gas {
            return BlendCalculator.gasOnlyFill(input: calculationInput)
        }

        return BlendCalculator.calculate(input: calculationInput)
    }

    // Chip highlighting: -1 selects the trailing "Custom"/"Max E85" chip; a value that
    // matches no chip leaves the row unselected.
    private var fuelLevelChipSelection: Int {
        if isCustomFuelLevelVisible {
            return -1
        }

        // A non-preset value with the custom slider hidden selects nothing — matching
        // the Custom chip here would highlight a control whose input isn't on screen.
        let level = Int(currentFuelLevelPercent.rounded())
        return [0, 25, 50, 75, 100].contains(level) ? level : Int.min
    }

    private var targetBlendChipSelection: Int {
        if isMaxE85Selected {
            return -1
        }

        let target = Int(targetEthanolPercent.rounded())
        return [30, 50, 60, 70].contains(target) ? target : Int.min
    }

    private var isUsingLastLoggedBlend: Bool {
        guard let lastLoggedBlendPercent else {
            return false
        }

        return abs(currentFuelEthanolPercent - lastLoggedBlendPercent) < 0.05
    }

    private var partialFillGallonsToAdd: Double {
        let currentGal = tankSizeGallons * currentFuelLevelPercent / 100
        let targetGal  = tankSizeGallons * targetFuelLevelPercent / 100
        return max(0, targetGal - currentGal)
    }

    private var currentFuelGallonsDisplay: Double {
        tankSizeGallons * currentFuelLevelPercent / 100
    }

    private var targetFuelGallonsDisplay: Double {
        tankSizeGallons * targetFuelLevelPercent / 100
    }

    private var estimatedFuelCost: Double? {
        guard isPartialFillEnabled, calculation.warningMessage == nil else { return nil }

        let result = calculation
        guard result.totalGallonsToAdd > 0.005 else { return nil }

        // Only require a price for fuel that is actually being added, so E85-only and
        // 91-only fills can estimate cost without an irrelevant second price.
        let e85Price = Double(e85PriceInput) ?? 0
        let gasPrice = Double(gasPriceInput) ?? 0

        if result.e85Gallons > 0.005, e85Price <= 0 { return nil }
        if result.gasGallons > 0.005, gasPrice <= 0 { return nil }

        return result.e85Gallons * e85Price + result.gasGallons * gasPrice
    }

    private var budgetExceeded: Bool {
        guard let cost = estimatedFuelCost,
              let budget = Double(budgetInput), budget > 0 else { return false }
        return cost > budget
    }

    private var isPartialFillSameLevel: Bool {
        isPartialFillEnabled &&
        Int(currentFuelLevelPercent.rounded()) == Int(targetFuelLevelPercent.rounded())
    }

    /// Wraps `$e85PriceInput` so only a genuine TextField edit (the user actually typing)
    /// marks `e85PriceUserEdited` — a programmatic auto-fill from station-context
    /// resolution assigns `e85PriceInput` directly and never goes through this binding's
    /// setter, so it can never be mistaken for a user edit.
    private var e85PriceInputBinding: Binding<String> {
        Binding(
            get: { e85PriceInput },
            set: { newValue in
                e85PriceInput = newValue
                e85PriceUserEdited = true
            }
        )
    }

    // True whenever current level is at 100% — target slider must not render to avoid a stride crash.
    private var currentLevelIsFull: Bool {
        Int(currentFuelLevelPercent.rounded()) >= 100
    }

    // True when the calculator could not produce a valid blend. When set, the numeric
    // result/summary must be neutralized so we never show 0.00 (or a stale "To Add")
    // as if it were a valid recommendation.
    //
    // The same-level case (target == current, including a 100% full tank) is excluded:
    // it already has dedicated, clearer UI (the `isPartialFillSameLevel` hint and the
    // full-tank static bar), and the calculator's "tank is already full" message reads
    // as misleading at partial levels. This guard keeps the new warning card focused on
    // genuinely unreachable/invalid blends (e.g. E10 → E85).
    private var hasBlendWarning: Bool {
        calculation.warningMessage != nil && !isPartialFillSameLevel
    }

    // Placeholder shown in place of numeric values when a blend warning is active.
    private let neutralizedValue = "—"

    // MARK: - Hero instruction state

    // Short label for the gas side of the mix, e.g. "91" — beginners recognize the
    // octane button on the pump more readily than the word "gasoline".
    private var gasPumpLabel: String {
        "\(Int(gasOctane.rounded()))"
    }

    // Tank (or partial-fill target) can't take more fuel, so there is nothing to pump.
    private var isNothingToPumpState: Bool {
        currentLevelIsFull || isPartialFillSameLevel
    }

    // The user's tank blend already sits within a couple points of the target, so the
    // fill is maintenance rather than a correction worth explaining.
    private var isAlreadyCloseToTarget: Bool {
        abs(currentFuelEthanolPercent - targetEthanolPercent) <= 2
    }

    private var canLogFillUp: Bool {
        !isNothingToPumpState && !hasBlendWarning
    }

    // The one dominant instruction the screen exists to answer. Nil while a blend
    // warning is showing — the warning card is the headline in that state.
    private var heroHeadline: String? {
        if isNothingToPumpState {
            return currentLevelIsFull ? "Your tank is full — nothing to pump" : "Nothing to add yet — raise your target level"
        }

        guard hasBlendWarning == false else {
            return nil
        }

        let e85 = calculation.e85Gallons
        let gas = calculation.gasGallons

        if calculation.guidanceMessage != nil || (e85 > 0.005 && gas <= 0.005) {
            return String(format: "Pump E85 only — %.1f gallons", e85)
        }

        if gas > 0.005 && e85 <= 0.005 {
            return String(format: "Add %.1f gallons of %@", gas, gasPumpLabel)
        }

        return String(format: "Add %.1f gal E85 + %.1f gal %@", e85, gas, gasPumpLabel)
    }

    private var heroSubtitle: String? {
        if isNothingToPumpState {
            return nil
        }

        if calculation.guidanceMessage != nil {
            return String(format: "This gives you the highest blend available from this pump — about E%.0f.", calculation.finalEthanolPercent)
        }

        // The target blend doesn't apply to a gas-only fill, so skip the
        // "already close to target" framing in that mode.
        if isAlreadyCloseToTarget, pumpFuelSelection != .gas {
            return "You're already close to E\(Int(targetEthanolPercent.rounded())) — this fill keeps you there."
        }

        // Note: estimatedOctane describes the ADDED fuel only, not the whole tank —
        // don't present it as the resulting tank octane here.
        return String(format: "Lands you at about E%.0f.", calculation.finalEthanolPercent)
    }

    // Compact echo of the instruction for the sticky bottom bar.
    private var stickyBarText: String {
        if hasBlendWarning {
            return "Fix the blend warning to continue"
        }
        return heroHeadline ?? "Adjust your fuel details above"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    vehicleCard
                    targetBlendCard
                    fuelLevelCard
                    partialFillCard
                    currentEthanolCard
                    pumpFuelCard
                    blendWarningCard
                    heroResultCard
                    blendResultCard
                    budgetWarningCard
                    if canLogFillUp {
                        pumpStepsCard
                    }
                    stationContextCard
                    safetyDisclaimer
                    actionButtons
                }
                .padding(16)
            }
            .dismissKeyboardOnTap()
            .background(AppTheme.Colors.charcoal)
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) {
                stickyActionBar
            }
            .onChange(of: e85EthanolPercent) { _, newValue in
                // "Max E85" means "as high as this pump goes" — keep the target glued
                // to the pump content if the user adjusts it via Custom.
                if isMaxE85Selected {
                    targetEthanolPercent = newValue
                }
                persistLastPumpSetup()
            }
            .onChange(of: targetEthanolPercent) { _, _ in persistLastPumpSetup() }
            .onChange(of: currentFuelLevelPercent) { _, _ in persistLastPumpSetup() }
            .onChange(of: pumpFuelSelection) { _, _ in persistLastPumpSetup() }
            .onChange(of: isMaxE85Selected) { _, _ in persistLastPumpSetup() }
            .onChange(of: stationContext) { _, newValue in
                // A manual open typically starts at `.resolving`; once resolution
                // completes (possibly seconds later, after a fresh location fix), prefill
                // the price the same way `init` does for an already-known station —
                // but only if the user hasn't already typed their own price in the
                // meantime.
                guard case .matched(let candidate) = newValue,
                      let price = candidate.e85Price, price > 0,
                      e85PriceUserEdited == false else {
                    return
                }
                e85PriceInput = String(format: "%.2f", price)
            }
        }
        .background(AppTheme.Colors.charcoal.ignoresSafeArea())
        .keyboardDoneToolbar()
    }

    // MARK: - Hero result / sticky bar

    @ViewBuilder
    private var heroResultCard: some View {
        if let headline = heroHeadline {
            AppCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("WHAT TO PUMP")
                        .font(.caption.weight(.bold))
                        .tracking(1.3)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text(headline)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(canLogFillUp ? AppTheme.Colors.primaryGreen : AppTheme.Colors.textPrimary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(3)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.15), value: headline)

                    if let subtitle = heroSubtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var stickyActionBar: some View {
        VStack(spacing: 10) {
            Text(stickyBarText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(canLogFillUp ? AppTheme.Colors.textPrimary : AppTheme.Colors.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.15), value: stickyBarText)

            PrimaryButton(title: canLogFillUp ? "Log This Fill-Up" : "Review Inputs") {
                guard canLogFillUp else { return }
                AppHaptics.selection()
                logFillUpAction(calculation)
            }
            .disabled(!canLogFillUp)
            .opacity(canLogFillUp ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.15), value: canLogFillUp)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(
            AppTheme.Colors.charcoal
                .opacity(0.97)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(AppTheme.Colors.border)
                        .frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Header / vehicle

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

                Text(headerStationSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    private var headerStationSubtitle: String {
        if case .matched(let candidate) = stationContext {
            return "At: \(candidate.name)"
        }
        return "Quick blend guidance while you fuel"
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

    // MARK: - Target blend

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

                // 91/gas-only is a projection mode: the target doesn't drive the math,
                // so make that explicit instead of leaving live-looking dead chips.
                if pumpFuelSelection == .gas {
                    Text("Target blend is ignored while pumping \(gasPumpLabel) only — this mode estimates where a gas top-off lands. Switch Pump Fuel back to E85 or Custom to blend toward a target.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Always-visible quick chips — the guided tiers below are education,
                // these are the one-tap picks. "Max E85" targets whatever this pump's
                // E85 actually contains rather than a hard 85.
                PumpPresetGrid(
                    items: [
                        .init(label: "E30", value: 30),
                        .init(label: "E50", value: 50),
                        .init(label: "E60", value: 60),
                        .init(label: "E70", value: 70),
                        .init(label: "Max E85", value: -1),
                    ],
                    selectedValue: targetBlendChipSelection,
                    accessibilitySubject: "target blend"
                ) { value in
                    AppHaptics.impact()
                    if value == -1 {
                        isMaxE85Selected = true
                        targetEthanolPercent = e85EthanolPercent
                    } else {
                        isMaxE85Selected = false
                        targetEthanolPercent = Double(value)
                    }
                }
                // Dim but don't clear: the selection resumes untouched when the user
                // switches back to E85/Custom pump fuel.
                .opacity(pumpFuelSelection == .gas ? 0.35 : 1)
                .allowsHitTesting(pumpFuelSelection != .gas)
                .animation(.easeInOut(duration: 0.2), value: pumpFuelSelection)

                Group {
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
                .opacity(pumpFuelSelection == .gas ? 0.35 : 1)
                .allowsHitTesting(pumpFuelSelection != .gas)
            }
        }
    }

    // MARK: - Fuel level (existing)

    private var fuelLevelCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Current Fuel Level", subtitle: "Current level: \(Int(currentFuelLevelPercent.rounded()))%")

                if isUsingRestoredFuelLevel {
                    Text("Starting from your last used level — set it to match today's gauge.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                PumpPresetGrid(
                    items: [
                        .init(label: "Empty", value: 0),
                        .init(label: "1/4", value: 25),
                        .init(label: "1/2", value: 50),
                        .init(label: "3/4", value: 75),
                        .init(label: "Full", value: 100),
                        .init(label: "Custom", value: -1),
                    ],
                    selectedValue: fuelLevelChipSelection,
                    accessibilitySubject: "fuel level"
                ) { value in
                    if value == -1 {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isCustomFuelLevelVisible = true
                        }
                        return
                    }

                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCustomFuelLevelVisible = false
                    }
                    applyFuelLevel(Double(value))
                }

                if isCustomFuelLevelVisible {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Custom Level")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Text("\(Int(currentFuelLevelPercent.rounded()))%")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AppTheme.Colors.primaryGreen)
                                .contentTransition(.numericText())
                                .animation(.easeInOut(duration: 0.15), value: currentFuelLevelPercent)
                        }

                        Slider(value: $currentFuelLevelPercent, in: 0...100, step: 1)
                            .tint(AppTheme.Colors.primaryGreen)
                            .onChange(of: currentFuelLevelPercent) { _, newValue in
                                if isPartialFillEnabled, targetFuelLevelPercent < newValue {
                                    targetFuelLevelPercent = newValue
                                }
                            }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func applyFuelLevel(_ value: Double) {
        currentFuelLevelPercent = value
        if isPartialFillEnabled, targetFuelLevelPercent < currentFuelLevelPercent {
            targetFuelLevelPercent = currentFuelLevelPercent
        }
    }

    // MARK: - Partial Fill

    private var partialFillCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Partial Fill", subtitle: nil)

                Toggle(isOn: $isPartialFillEnabled) {
                    Text("I'm not filling to full")
                        .font(.body.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                .tint(AppTheme.Colors.primaryGreen)
                .onChange(of: isPartialFillEnabled) { _, enabled in
                    if !enabled {
                        targetFuelLevelPercent = 100
                    }
                }

                if isPartialFillEnabled {
                    Text("Calculate blends for partial refills and top-offs instead of assuming a full tank.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Current Level
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Current Level")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Text("\(Int(currentFuelLevelPercent.rounded()))% · \(String(format: "%.1f", currentFuelGallonsDisplay)) gal")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AppTheme.Colors.primaryGreen)
                                .contentTransition(.numericText())
                                .animation(.easeInOut(duration: 0.15), value: currentFuelLevelPercent)
                        }

                        Slider(value: $currentFuelLevelPercent, in: 0...100, step: 1)
                            .tint(AppTheme.Colors.primaryGreen)
                            .onChange(of: currentFuelLevelPercent) { _, newVal in
                                if newVal >= 100 {
                                    targetFuelLevelPercent = 100
                                } else if targetFuelLevelPercent < newVal {
                                    targetFuelLevelPercent = newVal
                                }
                            }

                        fuelLevelTickLabels

                        fuelLevelChipRow(
                            values: [
                                .init(label: "Empty", value: 0),
                                .init(label: "1/4", value: 25),
                                .init(label: "1/2", value: 50),
                                .init(label: "3/4", value: 75),
                                .init(label: "Full", value: 100),
                            ],
                            selectedValue: Int(currentFuelLevelPercent.rounded()),
                            disabledBelow: nil,
                            accentColor: AppTheme.Colors.primaryGreen
                        ) { value in
                            currentFuelLevelPercent = Double(value)
                            if Double(value) >= 100 {
                                targetFuelLevelPercent = 100
                            } else if targetFuelLevelPercent < currentFuelLevelPercent {
                                targetFuelLevelPercent = currentFuelLevelPercent
                            }
                        }
                    }

                    // Target Level
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Target Level")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Text("\(Int(targetFuelLevelPercent.rounded()))% · \(String(format: "%.1f", targetFuelGallonsDisplay)) gal")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(currentLevelIsFull ? AppTheme.Colors.textMuted : AppTheme.Colors.accentYellow)
                                .contentTransition(.numericText())
                                .animation(.easeInOut(duration: 0.15), value: targetFuelLevelPercent)
                        }

                        if currentLevelIsFull {
                            // Static full-tank bar — slider omitted to avoid zero-stride crash
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(AppTheme.Colors.border)
                                    .frame(height: 4)
                                Capsule()
                                    .fill(AppTheme.Colors.textMuted.opacity(0.45))
                                    .frame(maxWidth: .infinity, maxHeight: 4)
                            }
                            .padding(.vertical, 10)

                            Text("Tank is already full. Lower the current level to calculate a partial fill.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Slider(
                                value: $targetFuelLevelPercent,
                                in: currentFuelLevelPercent...100,
                                step: 1
                            )
                            .tint(AppTheme.Colors.accentYellow)

                            HStack {
                                Text(fuelLevelLabel(for: currentFuelLevelPercent))
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.textMuted)
                                Spacer()
                                Text("Full")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.textMuted)
                            }

                            fuelLevelChipRow(
                                values: [
                                    .init(label: "1/4", value: 25),
                                    .init(label: "1/2", value: 50),
                                    .init(label: "3/4", value: 75),
                                    .init(label: "Full", value: 100),
                                ],
                                selectedValue: Int(targetFuelLevelPercent.rounded()),
                                disabledBelow: Int(currentFuelLevelPercent.rounded()),
                                accentColor: AppTheme.Colors.accentYellow
                            ) { value in
                                targetFuelLevelPercent = Double(value)
                            }
                        }
                    }

                    if isPartialFillSameLevel {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.circle")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.Colors.textMuted)
                            Text("Increase your target fuel level to calculate a refill.")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Fill summary chips
                    HStack(spacing: 10) {
                        partialInfoChip(
                            label: "Current",
                            value: "\(Int(currentFuelLevelPercent.rounded()))%"
                        )
                        partialInfoChip(
                            label: "Target",
                            value: "\(Int(targetFuelLevelPercent.rounded()))%"
                        )
                        partialInfoChip(
                            label: "To Add",
                            value: hasBlendWarning ? neutralizedValue : String(format: "%.2f gal", partialFillGallonsToAdd)
                        )
                    }

                    // Budget section — collapsed behind a disclosure so three price fields
                    // don't dominate the screen for users who never set a budget.
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isBudgetExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Text("OPTIONAL BUDGET LIMIT")
                                    .font(.caption.weight(.bold))
                                    .tracking(1.2)
                                    .foregroundStyle(AppTheme.Colors.textMuted)

                                Spacer()

                                Image(systemName: isBudgetExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isBudgetExpanded ? "Collapse budget limit" : "Expand budget limit")

                        if isBudgetExpanded {
                            HStack(spacing: 8) {
                                priceInputField(label: "E85 $/gal", text: e85PriceInputBinding, hint: "3.49")
                                priceInputField(label: "Gas $/gal", text: $gasPriceInput, hint: "3.99")
                                priceInputField(label: "Budget $", text: $budgetInput, hint: "20")
                            }
                        }

                        if let cost = estimatedFuelCost {
                            Text(String(format: "Estimated cost: $%.2f", cost))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(budgetExceeded ? AppTheme.Colors.gasOrange : AppTheme.Colors.primaryGreen)
                                .contentTransition(.numericText())
                                .animation(.easeInOut(duration: 0.15), value: cost)
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPartialFillEnabled)
    }

    @ViewBuilder
    private var blendWarningCard: some View {
        if hasBlendWarning, let warningMessage = calculation.warningMessage {
            WarningCard(title: "Blend Warning", message: warningMessage)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        // The E85-only guidance state is rendered by heroResultCard, which owns the
        // dominant "what to pump" instruction for all valid results.
    }

    @ViewBuilder
    private var budgetWarningCard: some View {
        if budgetExceeded, let cost = estimatedFuelCost, let budget = Double(budgetInput) {
            WarningCard(
                title: "Budget Exceeded",
                message: String(
                    format: "Estimated cost $%.2f exceeds your $%.2f budget. Lower your target fill level or reduce ethanol content.",
                    cost,
                    budget
                )
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Current ethanol

    private var currentEthanolCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Current Ethanol %", subtitle: "Use E10 if you are unsure, or enter your ethanol test result.")

                if isUsingLastLoggedBlend, let lastLoggedBlendPercent {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption)
                        Text("Using your last logged blend: E\(Int(lastLoggedBlendPercent.rounded()))")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
                }

                PumpPresetGrid(
                    items: [
                        .init(label: "E10", value: 10),
                        .init(label: "E20", value: 20),
                        .init(label: "E30", value: 30),
                        .init(label: "E50", value: 50),
                        .init(label: "E70", value: 70),
                        .init(label: "E85", value: 85),
                    ],
                    selectedValue: Int(currentFuelEthanolPercent.rounded()),
                    accessibilitySubject: "current blend"
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

    // MARK: - Pump fuel

    private var pumpFuelCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Pump Fuel", subtitle: "Confirm what you're pumping today.")

                PumpPresetGrid(
                    items: [
                        .init(label: "E85", value: PumpFuelOption.e85.rawValue),
                        .init(label: gasPumpLabel, value: PumpFuelOption.gas.rawValue),
                        .init(label: "Custom", value: PumpFuelOption.custom.rawValue),
                    ],
                    selectedValue: pumpFuelSelection.rawValue,
                    accessibilitySubject: "pump fuel"
                ) { value in
                    guard let option = PumpFuelOption(rawValue: value) else {
                        return
                    }

                    withAnimation(.easeInOut(duration: 0.2)) {
                        pumpFuelSelection = option
                    }

                    if option == .custom {
                        // Keep the slider range sane if a vehicle default sits outside it.
                        e85EthanolPercent = min(max(e85EthanolPercent, 50), 95)
                    }
                }

                switch pumpFuelSelection {
                case .e85:
                    Text(e85EthanolPercent >= 84.5
                         ? "Assuming this pump's E85 tests at E\(Int(e85EthanolPercent.rounded())). Tap Custom if your station posts a different blend — it varies by station and season."
                         : "Using E\(Int(e85EthanolPercent.rounded())) for today's pump fuel. Tap Custom to adjust.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .gas:
                    Text("Pumping \(gasPumpLabel) octane gas only — about E\(Int(gasEthanolPercent.rounded())). The result shows where this fill lands your blend.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .custom:
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Pump E85 Content")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Text("E\(Int(e85EthanolPercent.rounded()))")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AppTheme.Colors.primaryGreen)
                                .contentTransition(.numericText())
                                .animation(.easeInOut(duration: 0.15), value: e85EthanolPercent)
                        }

                        Slider(value: $e85EthanolPercent, in: 50...95, step: 1)
                            .tint(AppTheme.Colors.primaryGreen)
                            .accessibilityLabel("Pump E85 ethanol content")

                        Text("E85 pumps often test anywhere from E70 to E85 depending on season.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - Blend result

    private var blendResultCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Blend Result", subtitle: "Large numbers for quick pump-side reference.")

                HStack(spacing: 12) {
                    pumpMetricCard(title: "E85 gallons", value: hasBlendWarning ? neutralizedValue : String(format: "%.2f", calculation.e85Gallons), accent: AppTheme.Colors.primaryGreen)
                    pumpMetricCard(title: "Gas gallons", value: hasBlendWarning ? neutralizedValue : String(format: "%.2f", calculation.gasGallons), accent: AppTheme.Colors.gasOrange)
                }

                HStack(spacing: 12) {
                    compactMetricCard(title: "Final ethanol", value: hasBlendWarning ? neutralizedValue : String(format: "%.1f%%", calculation.finalEthanolPercent))
                    compactMetricCard(
                        title: isPartialFillEnabled ? "Gallons To Add" : "Total to add",
                        value: hasBlendWarning ? neutralizedValue : String(format: "%.2f gal", calculation.totalGallonsToAdd)
                    )
                }

                if isPartialFillEnabled {
                    VStack(alignment: .leading, spacing: 0) {
                        partialSummaryRow(
                            label: "Current",
                            value: "\(Int(currentFuelLevelPercent.rounded()))% · \(String(format: "%.1f", currentFuelGallonsDisplay)) gal",
                            a11yLabel: "Current Level, \(Int(currentFuelLevelPercent.rounded())) percent, \(String(format: "%.1f", currentFuelGallonsDisplay)) gallons"
                        )
                        Divider().padding(.vertical, 6)
                        partialSummaryRow(
                            label: "Target",
                            value: "\(Int(targetFuelLevelPercent.rounded()))% · \(String(format: "%.1f", targetFuelGallonsDisplay)) gal",
                            a11yLabel: "Target Level, \(Int(targetFuelLevelPercent.rounded())) percent, \(String(format: "%.1f", targetFuelGallonsDisplay)) gallons"
                        )
                        Divider().padding(.vertical, 6)
                        partialSummaryRow(
                            label: "Add",
                            value: hasBlendWarning ? neutralizedValue : String(format: "%.2f gal", partialFillGallonsToAdd),
                            isAccent: true,
                            a11yLabel: hasBlendWarning ? "Fuel to add unavailable until the blend warning is resolved" : "Fuel To Add, \(String(format: "%.1f", partialFillGallonsToAdd)) gallons"
                        )
                    }
                    .padding(14)
                    .background(AppTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    // MARK: - Pump steps

    private var pumpStepsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Pump Steps", subtitle: "Follow these in order.")

                // Single-fuel fills get one clean step — never "Top off with gas 0.00 gallons".
                if calculation.gasGallons <= 0.005 {
                    pumpStep(number: 1, title: "Pump E85 only", detail: "\(String(format: "%.2f", calculation.e85Gallons)) gallons")
                    pumpStep(number: 2, title: "Log this fill-up", detail: "Save station, blend, and mileage")
                } else if calculation.e85Gallons <= 0.005 {
                    pumpStep(number: 1, title: "Pump \(gasPumpLabel) only", detail: "\(String(format: "%.2f", calculation.gasGallons)) gallons")
                    pumpStep(number: 2, title: "Log this fill-up", detail: "Save station, blend, and mileage")
                } else {
                    pumpStep(number: 1, title: "Pump this much E85 first", detail: "\(String(format: "%.2f", calculation.e85Gallons)) gallons")
                    pumpStep(number: 2, title: "Then this much \(gasPumpLabel)", detail: "\(String(format: "%.2f", calculation.gasGallons)) gallons")
                    pumpStep(number: 3, title: "Log this fill-up", detail: "Save station, blend, and mileage")
                }
            }
        }
    }

    // MARK: - Station context

    private var stationContextCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Station Context", subtitle: nil)

                if locationAccessDenied {
                    stationContextMessage(
                        title: "Location Access Turned Off",
                        message: "Enable location in Settings to detect nearby saved stations automatically.",
                        showsSettingsButton: true
                    )
                } else {
                    switch stationContext {
                    case .resolving:
                        stationContextResolvingView
                    case .matched(let candidate):
                        stationContextMatchedView(candidate)
                    case .noMatch:
                        stationContextMessage(
                            title: "No Nearby E85 Station Found",
                            message: "No saved or recently discovered E85 station was close enough to identify automatically."
                        )
                    case .locationUnavailable:
                        stationContextMessage(
                            title: "Location Unavailable",
                            message: "We couldn't get a location fix just now. Move outdoors or try again in a moment."
                        )
                    case .preciseLocationRequired:
                        stationContextMessage(
                            title: "Precise Location Needed",
                            message: "Turn on Precise Location to identify the E85 station you're visiting.",
                            showsSettingsButton: true
                        )
                    case .ambiguous(let candidates):
                        stationContextAmbiguousView(candidates)
                    }
                }
            }
        }
    }

    private var stationContextResolvingView: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(AppTheme.Colors.primaryGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text("Finding Nearby Station")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Getting a more accurate location…")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    private func stationContextMatchedView(_ candidate: PumpStationContextCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.name)
                .font(.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary)

            if let price = candidate.e85Price, price > 0 {
                Text(String(format: "Saved E85 price: $%.2f/gal", price))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
            } else {
                Text("No saved E85 price on this station yet.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            if let address = candidate.address, address.isEmpty == false {
                Text(address)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }

            // Live results are never silently saved or favorited — this line exists
            // purely so the user understands where the match came from.
            if candidate.source == .live {
                Text("Detected from nearby search results")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }
        }
    }

    private func stationContextAmbiguousView(_ candidates: [PumpStationContextAmbiguousCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose Your Station")
                .font(.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("Multiple E85 stations are nearby. Select the station for this fill-up.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            VStack(spacing: 8) {
                ForEach(candidates) { entry in
                    Button {
                        AppHaptics.selection()
                        selectAmbiguousCandidateAction(entry.candidate)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.candidate.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                                if let address = entry.candidate.address, address.isEmpty == false {
                                    Text(address)
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.Colors.textMuted)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(formattedDistance(entry.distanceMeters))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(AppTheme.Colors.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Your selection applies to this fill-up only.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
    }

    private func stationContextMessage(title: String, message: String, showsSettingsButton: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            if showsSettingsButton {
                Button {
                    openSystemSettings()
                } label: {
                    Text("Open Settings")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.Colors.primaryGreen)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func formattedDistance(_ meters: CLLocationDistance) -> String {
        let feet = meters * 3.28084
        if feet < 1000 {
            return "\(Int(feet.rounded())) ft"
        }
        return String(format: "%.1f mi", meters / 1609.34)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Safety / actions

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
        // "Log This Fill-Up" lives in the sticky bottom bar so it is always reachable;
        // only the close action remains inline at the end of the scroll.
        SecondaryButton(title: "Close") {
            closeAction()
        }
    }

    // MARK: - Blend guide data

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
        isMaxE85Selected ? "Max E85" : "E\(Int(targetEthanolPercent.rounded()))"
    }

    private var selectedBlendTierTitle: String {
        if isMaxE85Selected {
            return "Highest Blend"
        }
        return activeBlendTier?.title ?? "Custom"
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

    // MARK: - Helper views

    private var fuelLevelTickLabels: some View {
        HStack {
            Text("Empty")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
            Spacer()
            Text("1/4")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
            Spacer()
            Text("1/2")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
            Spacer()
            Text("3/4")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
            Spacer()
            Text("Full")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
    }

    private func partialInfoChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textMuted)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .contentTransition(.numericText())
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

    private func priceInputField(label: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 3) {
                Text("$")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                TextField(hint, text: text)
                    .keyboardType(.decimalPad)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(AppTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity)
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

    // MARK: - Helpers

    private func fuelLevelLabel(for percent: Double) -> String {
        let val = Int(percent.rounded())
        switch val {
        case 0:   return "Empty"
        case 25:  return "1/4 Tank"
        case 50:  return "1/2 Tank"
        case 75:  return "3/4 Tank"
        case 100: return "Full"
        default:  return "\(val)%"
        }
    }

    private func fuelLevelChipRow(
        values: [PumpPresetItem],
        selectedValue: Int,
        disabledBelow: Int?,
        accentColor: Color,
        action: @escaping (Int) -> Void
    ) -> some View {
        let chipColumns = [GridItem(.adaptive(minimum: 58), spacing: 8)]
        return LazyVGrid(columns: chipColumns, spacing: 8) {
            ForEach(values) { chip in
                let isSelected = chip.value == selectedValue
                let isDisabled = disabledBelow.map { chip.value < $0 } ?? false
                Button {
                    guard chip.value != selectedValue else { return }
                    AppHaptics.impact()
                    action(chip.value)
                } label: {
                    Text(chip.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            isSelected ? AppTheme.Colors.charcoal :
                            isDisabled ? AppTheme.Colors.textMuted :
                                         AppTheme.Colors.textPrimary
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isSelected ? accentColor : AppTheme.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(isSelected ? accentColor : AppTheme.Colors.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(isDisabled ? 0.35 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityLabel("Set level to \(chip.label)")
                .accessibilityAddTraits(isDisabled ? .isStaticText : [])
            }
        }
    }

    private func partialSummaryRow(
        label: String,
        value: String,
        isAccent: Bool = false,
        a11yLabel: String? = nil
    ) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(isAccent ? .subheadline.weight(.semibold) : .subheadline.weight(.bold))
                .foregroundStyle(isAccent ? AppTheme.Colors.primaryGreen : AppTheme.Colors.textPrimary)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel ?? "\(label), \(value)")
    }

    private func applyBlendSelection(_ selectedValue: Int) {
        AppHaptics.impact()
        // Tier picks are explicit numeric targets (including a literal E85), so they
        // replace any "Max E85" intent.
        isMaxE85Selected = false
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

    private static func formatInput(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }

        return String(format: "%.1f", value)
    }
}

// MARK: - Private sub-views

private struct PumpPresetItem: Identifiable {
    let label: String
    let value: Int

    var id: Int { value }
}

private struct PumpPresetGrid: View {
    let items: [PumpPresetItem]
    let selectedValue: Int
    /// What the chips set, for VoiceOver — e.g. "fuel level" → "Set fuel level to 1/2".
    let accessibilitySubject: String
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
                .accessibilityLabel("Set \(accessibilitySubject) to \(item.label)")
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
                        miniBlendButton("E\(alternateBlend)", value: alternateBlend)
                        miniBlendButton("E\(tier.preferredBlend)", value: tier.preferredBlend)
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

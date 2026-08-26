//
//  OnboardingView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VehicleProfile.createdAt, order: .forward)
    private var vehicles: [VehicleProfile]

    @AppStorage(AppPreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppPreferenceKey.hasAcknowledgedDisclaimer) private var hasAcknowledgedDisclaimer = false
    @AppStorage(AppPreferenceKey.disclaimerAcknowledgedAt) private var disclaimerAcknowledgedAt = 0.0
    @AppStorage(AppPreferenceKey.showGarageTab) private var showGarageTab = true
    @AppStorage(AppPreferenceKey.showRemindersTab) private var showRemindersTab = true
    // Default (.normal, i.e. this key absent) is exactly the safe fallback required if a user
    // somehow reaches completeOnboarding() without tapping either choice on tabSelectionCard.
    @AppStorage(AppPreferenceKey.appExperienceMode) private var appExperienceModeRaw = AppExperienceMode.normal.rawValue

    private var appExperienceMode: AppExperienceMode {
        .resolved(from: appExperienceModeRaw)
    }

    @State private var currentStep = 0
    @State private var draft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)
    @State private var disclaimerState = DisclaimerAcknowledgementState()
    @State private var isShowingFullDisclaimer = false
    @State private var disclaimerGuidanceMessage: String?
    @State private var vehicleSaveErrorMessage: String?

    private let steps: [OnboardingStep] = [
        // 0: Welcome
        .init(
            emoji: "🚗",
            title: "Welcome to 85Blends",
            subtitle: "E85 = up to 85% ethanol. Calculate blends, find E85 stations, and keep your ethanol fueling organized.",
            bulletPoints: [
                "Blend Calculator & At the Pump mode",
                "Nearby E85 Stations & community pricing",
                "Fuel Logs, MPG trends & cost tracking",
                "Garage, Reminders & cost comparisons"
            ]
        ),
        // 1: Vehicle setup (optional form — body routes here via currentStep == 1)
        .init(
            emoji: "🔧",
            title: "Add Your Vehicle",
            subtitle: "Optional — add your vehicle to personalize blend defaults. You can skip this and add it later in Garage."
        ),
        // 2: Feature overview
        .init(
            emoji: "⛽",
            title: "Fuel with Confidence",
            subtitle: "Calculate blends, estimate costs, and quickly find nearby E85 stations.",
            bulletPoints: [
                "Blend Calculator — E30, E50, E60, or E85 in seconds.",
                "At the Pump mode for one-handed fueling guidance.",
                "Nearby E85 stations with community-reported prices.",
                "Fuel Log with MPG, spend, and trend tracking.",
                "Cost Calculator to compare blends vs gasoline."
            ]
        ),
        // 3: App Experience + tab selection (tabSelectionStepIndex)
        .init(
            emoji: "🎨",
            title: "Choose Your Experience",
            subtitle: "Pick how much of 85Blends you want to see day to day. You can change this anytime in Settings."
        ),
        // 4: Disclaimer (disclaimerStepIndex)
        .init(
            emoji: "🔥",
            title: "Ready to Blend?",
            subtitle: "Track fuel, find stations, add your vehicle, and make every fill-up smarter."
        ),
        // 5: 85Blends Pro intro (proStepIndex) — informational only, no paywall or purchase flow.
        // 85Blends 2.3.0 release-blocker fix: this list previously repeated ProUpgradeView's
        // same inaccurate claims (Advanced Fuel Analytics, Station Price Alerts, Unlimited
        // Vehicles, Cloud Sync Ready are not genuinely delivered-and-Pro-exclusive today — see
        // ProUpgradeView.swift). Trimmed to benefits that are actually true and shipping today;
        // not replaced with invented substitutes. 85Blends 2.3.1: added Ad-Free Experience,
        // genuinely implemented and validated on a real device — see ProUpgradeView.swift's
        // majorBenefits comment for the same evidence.
        .init(
            emoji: "👑",
            title: "Unlock 85Blends Pro",
            subtitle: "Take your E85 experience even further.",
            bulletPoints: [
                "Intelligent Trip Planning with E85 fuel stops along the way",
                "Ad-Free Experience throughout 85Blends",
                "Unlimited Vehicles in your Garage",
                "Save and revisit your favorite trips"
            ]
        )
    ]

    var body: some View {
        ZStack {
            AppTheme.Colors.oledBackground
                .ignoresSafeArea()

            Circle()
                .fill(AppTheme.Colors.primaryGreen.opacity(0.14))
                .frame(width: 320, height: 320)
                .blur(radius: 70)
                .offset(x: 120, y: -240)

            Circle()
                .fill(AppTheme.Colors.stationYellow.opacity(0.08))
                .frame(width: 240, height: 240)
                .blur(radius: 70)
                .offset(x: -140, y: 300)

            VStack(alignment: .leading, spacing: 24) {
                header

                progressSection

                if currentStep == 1 {
                    vehicleSetupCard
                } else if isTabSelectionStep {
                    tabSelectionCard
                } else if isDisclaimerStep {
                    disclaimerAcknowledgementCard
                } else if isProStep {
                    proIntroCard
                } else {
                    messageCard(step: steps[currentStep])
                }

                Spacer()

                footerActions
            }
            .padding(24)
        }
        .keyboardDoneToolbar()
        .dismissKeyboardOnTap()
        .sheet(isPresented: $isShowingFullDisclaimer) {
            NavigationStack {
                DisclaimerView()
            }
        }
        .alert("Save Error", isPresented: Binding(
            get: { vehicleSaveErrorMessage != nil },
            set: { if !$0 { vehicleSaveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { vehicleSaveErrorMessage = nil }
        } message: {
            Text(vehicleSaveErrorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GETTING STARTED")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.Colors.textMuted)

            Text("85Blends")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("Your ethanol toolkit, set up in under a minute")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Step \(currentStep + 1) of \(steps.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(Array(steps.indices), id: \.self) { index in
                    Capsule()
                        .fill(index <= currentStep ? AppTheme.Colors.accentGreen : AppTheme.Colors.border)
                        .frame(height: 8)
                }
            }
        }
    }

    private func messageCard(step: OnboardingStep) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("STEP \(currentStep + 1)")
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.Colors.textMuted)

            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AppTheme.Colors.softGreenBackground.opacity(0.72),
                                AppTheme.Colors.stationYellow.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text(step.emoji)
                    .font(.system(size: 36))
            }
            .frame(width: 72, height: 72)

            Text(step.title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text(step.subtitle)
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            if step.bulletPoints.isEmpty == false {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(step.bulletPoints, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.Colors.accentGreen)
                                .padding(.top, 2)

                            Text(bullet)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var vehicleSetupCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("STEP \(currentStep + 1)")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                HStack(spacing: 10) {
                    Text(steps[currentStep].emoji)
                        .font(.system(size: 36))

                    Text("OPTIONAL")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.Colors.accentGreen)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppTheme.Colors.accentGreen.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(steps[currentStep].title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(steps[currentStep].subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                OnboardingStringField(title: "Nickname", text: $draft.nickname)
                OnboardingStringField(title: "Make", text: $draft.make)
                OnboardingStringField(title: "Model", text: $draft.model)
                // Tank Size is optional — showsZeroAsBlank presents an unset (0) value as a
                // blank field with an "Optional" placeholder rather than a literal "0", which
                // previously read as an intentional zero-gallon tank. The persisted 0-is-unset
                // representation (VehicleDraft.tankSizeGallons) is unchanged — this is display
                // only. See OnboardingDoubleField below.
                OnboardingDoubleField(title: "Tank Size (gallons)", value: $draft.tankSizeGallons, showsZeroAsBlank: true)
                OnboardingToggleRow(title: "Flex Fuel Vehicle", isOn: $draft.isFlexFuel)

                Text("All details can be edited later in Garage.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var footerActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isProStep {
                proFooterActions
            } else {
                standardFooterActions
            }
        }
    }

    // Final onboarding step. Both actions finish onboarding — neither opens a paywall or
    // purchase flow. Pro can always be explored later from the More tab.
    private var proFooterActions: some View {
        VStack(spacing: 12) {
            Button {
                completeOnboarding()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppTheme.Colors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                completeOnboarding()
            } label: {
                Text("Explore Pro Later")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var standardFooterActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isDisclaimerStep, let disclaimerGuidanceMessage {
                Text(disclaimerGuidanceMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.stationYellow)
            }

            HStack(spacing: 12) {
                if isDisclaimerStep == false {
                    Button("Skip") {
                        resetOptionalTabsToDefault()
                        currentStep = disclaimerStepIndex
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Spacer()

                if currentStep > 0 {
                    Button("Back") {
                        currentStep -= 1
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Button(currentStep == steps.count - 1 ? "Start Blending" : "Continue") {
                    handlePrimaryAction()
                }
                .font(.headline)
                // Disabled state reads as clearly disabled (not washed out/broken): a visible,
                // more-than-hairline border plus legible (not too-faint) label text — never the
                // same green as enabled, so it's never mistaken for tappable-and-ready.
                .foregroundStyle(AppTheme.Colors.textPrimary.opacity(continueButtonEnabled ? 1 : 0.7))
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(continueButtonEnabled ? AppTheme.Colors.accentGreen : AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            continueButtonEnabled ? AppTheme.Colors.accentGreen : AppTheme.Colors.textMuted.opacity(0.5),
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func completeOnboarding() {
        guard canFinishOnboarding else { return }

        if shouldCreateVehicle {
            // 85Blends 2.3.0: Unlimited Vehicles is a real, enforced Pro entitlement now (see
            // VehicleCreationPolicy) — normally moot here, since onboarding only runs once
            // before any vehicle exists, but `vehicles` can already be non-empty in a real edge
            // case: a fresh install (hasCompletedOnboarding is a local, unsynced flag, so it
            // resets on reinstall) whose CloudKit sync brings in an existing vehicle from a
            // previous install/device before or during this screen. Silently skip creating a
            // redundant vehicle from the onboarding draft rather than interrupting first-run
            // onboarding with a paywall prompt — the synced vehicle(s) stay untouched and
            // visible, and the user can still add another later via Garage, where the standard
            // upgrade prompt applies.
            let canCreate = VehicleCreationPolicy.canAddVehicle(
                currentCount: vehicles.count,
                freeLimit: SubscriptionManager.freeVehicleLimit,
                canAccessUnlimitedVehicles: SubscriptionManager.shared.canAccessUnlimitedVehicles
            )

            if canCreate {
                if vehicles.isEmpty == false {
                    for vehicle in vehicles {
                        vehicle.isActive = false
                        vehicle.updatedAt = .now
                    }
                }

                // Onboarding's simplified vehicle card never shows Preferred Ethanol Target, so
                // draft.preferredEthanolTargetPercent is always nil here — no hidden E30 (or any
                // other) vehicle-specific target is silently created just because VehicleDraft used
                // to default this to E30 pre-2.3.0. Legacy default*/gasEthanolPercent fields are
                // intentionally omitted — they take VehicleProfile's own persistence-compatible
                // defaults and are never read as a preference for a new-semantics vehicle.
                let vehicle = VehicleProfile(
                    nickname: draft.nickname,
                    year: draft.year,
                    make: draft.make,
                    model: draft.model,
                    trim: draft.trim,
                    tankSizeGallons: draft.tankSizeGallons,
                    currentOdometer: draft.currentOdometer,
                    requiredOctane: draft.requiredOctane,
                    isFlexFuel: draft.isFlexFuel,
                    isActive: true,
                    createdAt: .now,
                    updatedAt: .now,
                    preferredEthanolTargetPercent: draft.preferredEthanolTargetPercent,
                    calculatorPreferenceSemanticsVersion: VehiclePreferenceSemantics.current
                )

                modelContext.insert(vehicle)
                do {
                    try modelContext.save()
                } catch {
                    #if DEBUG
                    print("[85Blends] OnboardingView: vehicle save failed:", error)
                    #endif
                    vehicleSaveErrorMessage = "Couldn't save your vehicle. Please try again."
                    return
                }
            }
        }

        hasAcknowledgedDisclaimer = true
        disclaimerAcknowledgedAt = Date.now.timeIntervalSince1970
        AppHaptics.success()
        hasCompletedOnboarding = true
    }

    private var disclaimerAcknowledgementCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("STEP \(currentStep + 1)")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text(steps[currentStep].emoji)
                    .font(.system(size: 36))

                Text(steps[currentStep].title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(steps[currentStep].subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                VStack(alignment: .leading, spacing: 10) {
                    safetyPoint("Blend and octane calculations are estimates — always verify actual ethanol content and fuel quality.")
                    safetyPoint("Vehicle compatibility, tuning, warranty, emissions, and legal compliance are your responsibility.")
                    safetyPoint("85Blends is not professional mechanical, legal, financial, or regulatory advice.")
                }
                .padding(.top, 4)

                Toggle(isOn: $disclaimerState.acknowledged) {
                    Text("I understand these calculations are estimates and I am responsible for verifying fuel compatibility.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                .tint(AppTheme.Colors.accentGreen)
                .padding(14)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            disclaimerNeedsHighlight ? AppTheme.Colors.stationYellow : AppTheme.Colors.border,
                            lineWidth: disclaimerNeedsHighlight ? 1.6 : 1
                        )
                )
                .shadow(
                    color: disclaimerNeedsHighlight ? AppTheme.Colors.stationYellow.opacity(0.22) : .clear,
                    radius: disclaimerNeedsHighlight ? 12 : 0
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .animation(.easeInOut(duration: 0.22), value: disclaimerNeedsHighlight)
                .onChange(of: disclaimerState.acknowledged) { _, newValue in
                    if newValue {
                        disclaimerGuidanceMessage = nil
                    }
                }

                Button {
                    isShowingFullDisclaimer = true
                } label: {
                    HStack {
                        Text("View full disclaimer")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(14)
                    .background(AppTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Text("Built for the ethanol community.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private var tabSelectionCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("STEP \(currentStep + 1)")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text(steps[currentStep].emoji)
                    .font(.system(size: 36))

                Text(steps[currentStep].title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(steps[currentStep].subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                VStack(spacing: 10) {
                    ForEach(AppExperienceMode.allCases) { mode in
                        onboardingExperienceModeCard(mode)
                    }
                }

                // Garage/Reminders visibility is a Normal Mode customization — Simple Mode
                // always shows just Calculator, Stations, and More, so these toggles would be
                // meaningless there. Their stored values are untouched either way.
                if appExperienceMode == .normal {
                    onboardingTabToggleCard(
                        title: "Garage",
                        description: "Save vehicles, tank sizes, odometer, and calculator defaults.",
                        systemImage: "car.fill",
                        tint: AppTheme.Colors.accentGreen,
                        isOn: $showGarageTab
                    )
                    onboardingTabToggleCard(
                        title: "Reminders",
                        description: "Track oil changes, service intervals, dates, and mileage-based tasks.",
                        systemImage: "bell.badge.fill",
                        tint: AppTheme.Colors.stationYellow,
                        isOn: $showRemindersTab
                    )
                    Text("Calculator, Stations, and More always stay visible. Theme, blend defaults, and preferred maps app can be changed anytime in More \u{2192} Preferences.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                } else {
                    Text("Calculator, Stations, and More are the core of Simple Mode. Switch to Normal anytime in More \u{2192} Preferences to unlock Garage, Fuel Log, Reminders, Trip Planner, and more.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    // Final onboarding screen — a natural, no-pressure introduction to 85Blends Pro.
    // Purely informational: there is no purchase flow or paywall here.
    private var proIntroCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("STEP \(currentStep + 1)")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(AppTheme.Colors.stationYellow.opacity(0.16))

                    Image(systemName: "crown.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                }
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

                Text(steps[currentStep].title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(steps[currentStep].subtitle)
                    .font(.title3)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(steps[currentStep].bulletPoints, id: \.self) { benefit in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AppTheme.Colors.stationYellow)
                                .padding(.top, 1)
                                .accessibilityHidden(true)

                            Text(benefit)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 2)

                Text("No purchase required to continue — you can explore Pro anytime from the More tab.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(AppTheme.Colors.stationYellow.opacity(0.30), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private var disclaimerNeedsHighlight: Bool {
        disclaimerGuidanceMessage != nil && disclaimerState.acknowledged == false
    }

    private func safetyPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.accentYellow)
                .padding(.top, 1)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    private var disclaimerStepIndex: Int {
        steps.count - 2
    }

    private var proStepIndex: Int {
        steps.count - 1
    }

    private var isProStep: Bool {
        currentStep == proStepIndex
    }

    private var isDisclaimerStep: Bool {
        currentStep == disclaimerStepIndex
    }

    private var isTabSelectionStep: Bool {
        currentStep == tabSelectionStepIndex
    }

    private var canFinishOnboarding: Bool {
        disclaimerState.allAcknowledged
    }

    private var continueButtonEnabled: Bool {
        isDisclaimerStep ? canFinishOnboarding : true
    }

    private func handlePrimaryAction() {
        // The disclaimer is no longer the last step — it gates advancing to the Pro intro,
        // which is where onboarding actually completes (via proFooterActions).
        if isDisclaimerStep, canFinishOnboarding == false {
            guideToFirstMissingAcknowledgement()
            return
        }
        currentStep += 1
    }

    private func resetOptionalTabsToDefault() {
        showGarageTab = true
        showRemindersTab = true
    }

    private func guideToFirstMissingAcknowledgement() {
        disclaimerGuidanceMessage = "Please acknowledge the safety note to continue."
    }

    private var shouldCreateVehicle: Bool {
        let baselineDraft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)

        let hasIdentityInput = [
            draft.nickname,
            draft.make,
            draft.model
        ].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

        let hasCustomizedDefaults =
            draft.tankSizeGallons != baselineDraft.tankSizeGallons ||
            draft.isFlexFuel != baselineDraft.isFlexFuel

        return hasIdentityInput || hasCustomizedDefaults
    }

    private var tabSelectionStepIndex: Int {
        steps.count - 3
    }
}

#Preview {
    OnboardingView()
        .modelContainer(for: VehicleProfile.self, inMemory: true)
}

private struct OnboardingStep {
    let emoji: String
    let title: String
    let subtitle: String
    let bulletPoints: [String]

    init(emoji: String, title: String, subtitle: String, bulletPoints: [String] = []) {
        self.emoji = emoji
        self.title = title
        self.subtitle = subtitle
        self.bulletPoints = bulletPoints
    }
}

private struct DisclaimerAcknowledgementState {
    var acknowledged = false
    var allAcknowledged: Bool { acknowledged }
}

private struct OnboardingStringField: View {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            TextField(title, text: $text)
                .keyboardType(keyboard)
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

private struct OnboardingDoubleField: View {
    let title: String
    @Binding var value: Double
    // When true, a value <= 0 displays as a blank field with `placeholder` rather than the
    // literal digit "0" — for genuinely optional numeric fields (Tank Size) where 0 means "not
    // entered," not a real, meaningful zero. Defaults to false so this preserves its prior
    // behavior for any other numeric field. Mirrors AddEditVehicleView.swift's
    // TankSizeInputField, which already solves this exact problem on the full Edit Vehicle form.
    var showsZeroAsBlank: Bool = false
    var placeholder: String = "Optional"

    private var blankWhenZeroBinding: Binding<String> {
        Binding(
            get: { value > 0 ? formatted(value) : "" },
            set: { newText in
                let trimmed = newText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    value = 0
                } else if let parsed = Double(trimmed) {
                    value = parsed
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Group {
                if showsZeroAsBlank {
                    TextField(placeholder, text: blankWhenZeroBinding)
                } else {
                    TextField(title, value: $value, format: .number)
                }
            }
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

    private func formatted(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.1f", value)
    }
}

private struct OnboardingToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
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
}

private extension OnboardingView {
    @ViewBuilder
    func onboardingExperienceModeCard(_ mode: AppExperienceMode) -> some View {
        let isSelected = appExperienceMode == mode

        Button {
            appExperienceModeRaw = mode.rawValue
            AppHaptics.selection()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Text(mode.displayName)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Spacer(minLength: 12)

                    // Selection state is never color-only: the glyph itself changes, and the
                    // border weight changes too, so it reads correctly without relying on hue.
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isSelected ? AppTheme.Colors.accentGreen : AppTheme.Colors.textMuted)
                        .accessibilityHidden(true)
                }

                Text(mode.onboardingHeadline)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Wrapped across rows of up to 3 chips rather than forced into one HStack —
                // Normal Mode's 5 bullets (Calculator, Stations, Garage, Reminders, More) were
                // cramming into a single row on-device, which compressed "Calculator" and
                // "Reminders" into an awkward mid-word wrap inside their capsules. chipRows(for:)
                // is plain array chunking (no custom Layout/reusable flow system needed); Simple
                // Mode's 2 bullets naturally collapse to a single row via the same chunking. This
                // block is purely decorative reinforcement of the sentence above
                // (mode.onboardingHeadline already fully describes the mode, both visually and
                // via the card's combined accessibilityLabel below), hence accessibilityHidden.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(chipRows(for: mode.onboardingFeatureBullets), id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(row, id: \.self) { feature in
                                chip(feature)
                            }
                        }
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? AppTheme.Colors.softGreenBackground
                    : AppTheme.Colors.surface
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        isSelected ? AppTheme.Colors.accentGreen : AppTheme.Colors.border,
                        lineWidth: isSelected ? 1.6 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(mode.displayName) mode. \(mode.onboardingHeadline) Includes \(mode.onboardingFeatureBullets.joined(separator: ", "))."
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Splits `bullets` into rows of up to 3, preserving order — e.g. 5 items become a 3-then-2
    /// split, 2 items stay a single row. Plain array chunking, not a layout system: it decides
    /// row *membership*, while the HStack/VStack pairing in onboardingExperienceModeCard does
    /// the actual layout.
    func chipRows(for bullets: [String]) -> [[String]] {
        stride(from: 0, to: bullets.count, by: 3).map {
            Array(bullets[$0..<min($0 + 3, bullets.count)])
        }
    }

    /// The onboarding feature-chip visual style, factored out so onboardingExperienceModeCard's
    /// two-row layout and any future call site share one definition. lineLimit(1) +
    /// fixedSize(horizontal:) keep a label from ever wrapping/hyphenating inside its capsule
    /// under space pressure — deliberately not a shrinking font or minimumScaleFactor, so labels
    /// stay fully legible at every Dynamic Type size rather than getting harder to read.
    func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppTheme.Colors.surface)
            .clipShape(Capsule())
    }

    func onboardingTabToggleCard(
        title: String,
        description: String,
        systemImage: String,
        tint: Color,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(AppTheme.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(AppTheme.Colors.accentGreen)
        }
        .padding(14)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

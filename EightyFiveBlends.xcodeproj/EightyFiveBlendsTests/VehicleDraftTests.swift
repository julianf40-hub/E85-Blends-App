//
//  VehicleDraftTests.swift
//  EightyFiveBlendsTests
//
//  Tests for VehicleDraft's 85Blends 2.3.0 Garage-simplification behavior: Preferred Ethanol
//  Target creation/legacy-transition semantics and Tank Size optionality. VehicleDraft is the
//  actual type AddEditVehicleView/GarageView/OnboardingView all construct and save through — not
//  a duplicate reimplementation — so passing tests here directly verify production behavior.
//
//  Note: like every other file in this directory, this is not currently wired into a test target
//  in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a test target
//  is added. Written to compile and pass once one exists.
//
//  Scope note: GarageView.saveVehicle actually transitioning a vehicle's
//  calculatorPreferenceSemanticsVersion to `.current` on save, and OnboardingView's vehicle
//  construction, are SwiftData/SwiftUI-coupled orchestration outside a bare VehicleDraft's reach
//  (same class of gap already documented in VehicleActivationTests/VehicleOdometerPolicyTests) —
//  verified by direct code inspection (GarageView.swift's saveVehicle, OnboardingView.swift's
//  completeOnboarding) rather than a unit test; see the manual validation checklist in the final
//  report.

import Testing
@testable import EightyFiveBlends

@MainActor
struct VehicleDraftTests {

    // MARK: - Creation semantics (brand-new vehicle, vehicle == nil)

    @Test("A brand-new vehicle draft has no Preferred Ethanol Target — never a hidden E30 or any other percentage")
    func newDraft_hasNoPreferredTarget() {
        let draft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)
        #expect(draft.preferredEthanolTargetPercent == nil)
    }

    @Test("A brand-new vehicle draft has no Tank Size — never a guessed 16-gallon placeholder")
    func newDraft_hasNoTankSize() {
        let draft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)
        #expect(draft.tankSizeGallons == 0)
    }

    @Test("A brand-new vehicle draft's sane, permissive defaults are otherwise unchanged")
    func newDraft_otherDefaultsUnchanged() {
        let draft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)
        #expect(draft.requiredOctane == 91)
        #expect(draft.currentOdometer == 0)
        #expect(draft.isFlexFuel == false)
    }

    @Test("The first vehicle ever created auto-activates; a subsequent one does not")
    func newDraft_activeDefaultsToFirstVehicleOnly() {
        #expect(VehicleDraft(vehicle: nil, existingVehiclesCount: 0).isActive)
        #expect(VehicleDraft(vehicle: nil, existingVehiclesCount: 1).isActive == false)
    }

    // MARK: - Legacy vehicle (calculatorPreferenceSemanticsVersion == 0)

    @Test("Opening a legacy vehicle for edit presents its legacy target as the starting Preferred Ethanol Target")
    func legacyVehicle_presentsLegacyTargetAsStartingValue() {
        let vehicle = VehicleProfile(defaultTargetEthanolPercent: 45)
        let draft = VehicleDraft(vehicle: vehicle, existingVehiclesCount: 1)
        #expect(draft.preferredEthanolTargetPercent == 45)
    }

    // MARK: - New-semantics vehicle (calculatorPreferenceSemanticsVersion >= 1)

    @Test("Opening a new-semantics vehicle with a set target presents that target, not the frozen legacy field")
    func newSemanticsVehicle_presentsItsOwnTarget() {
        let vehicle = VehicleProfile(
            defaultTargetEthanolPercent: 45, // frozen legacy value — must NOT be shown
            preferredEthanolTargetPercent: 60,
            calculatorPreferenceSemanticsVersion: 1
        )
        let draft = VehicleDraft(vehicle: vehicle, existingVehiclesCount: 1)
        #expect(draft.preferredEthanolTargetPercent == 60)
    }

    @Test("Opening a new-semantics vehicle with a cleared (nil) target presents nil — it does not re-seed from the legacy field")
    func newSemanticsVehicle_clearedTarget_staysNil() {
        let vehicle = VehicleProfile(
            defaultTargetEthanolPercent: 45, // frozen legacy value — must NOT resurrect as the preference
            calculatorPreferenceSemanticsVersion: 1
        )
        #expect(vehicle.preferredEthanolTargetPercent == nil)
        let draft = VehicleDraft(vehicle: vehicle, existingVehiclesCount: 1)
        #expect(draft.preferredEthanolTargetPercent == nil)
    }

    @Test("Opening a new-semantics vehicle with an explicit E0 target presents 0, not nil")
    func newSemanticsVehicle_explicitZeroTarget_presentsZero() {
        let vehicle = VehicleProfile(preferredEthanolTargetPercent: 0, calculatorPreferenceSemanticsVersion: 1)
        let draft = VehicleDraft(vehicle: vehicle, existingVehiclesCount: 1)
        #expect(draft.preferredEthanolTargetPercent == 0)
    }

    @Test("Clearing a legacy vehicle's presented target before saving produces a real nil, not a re-seeded legacy value")
    func legacyVehicle_clearedTargetBeforeSave_staysNil() {
        let vehicle = VehicleProfile(defaultTargetEthanolPercent: 45)
        var draft = VehicleDraft(vehicle: vehicle, existingVehiclesCount: 1)
        #expect(draft.preferredEthanolTargetPercent == 45) // starting value, per legacyVehicle_presentsLegacyTargetAsStartingValue

        draft.preferredEthanolTargetPercent = nil // user deliberately clears the field
        draft.normalizeForSave()

        #expect(draft.preferredEthanolTargetPercent == nil)
        // GarageView.saveVehicle then writes this nil straight to
        // vehicle.preferredEthanolTargetPercent and bumps calculatorPreferenceSemanticsVersion to
        // .current — it never falls back to re-reading the frozen defaultTargetEthanolPercent.
        // That write path itself is SwiftData-coupled orchestration verified by code inspection
        // (see this file's header), not something a bare VehicleDraft test can observe further.
    }

    // MARK: - Existing vehicle's Tank Size

    @Test("Opening an existing vehicle with no tank size set presents a blank (0) Tank Size, not a guessed 16")
    func existingVehicle_unsetTankSize_presentsBlank() {
        let vehicle = VehicleProfile(tankSizeGallons: 0)
        let draft = VehicleDraft(vehicle: vehicle, existingVehiclesCount: 1)
        #expect(draft.tankSizeGallons == 0)
    }

    @Test("Opening an existing vehicle with a real tank size presents it unchanged")
    func existingVehicle_realTankSize_presentsUnchanged() {
        let vehicle = VehicleProfile(tankSizeGallons: 18.5)
        let draft = VehicleDraft(vehicle: vehicle, existingVehiclesCount: 1)
        #expect(draft.tankSizeGallons == 18.5)
    }

    // MARK: - normalizeForSave()

    @Test("normalizeForSave clamps an out-of-range Preferred Ethanol Target into 0...100")
    func normalizeForSave_clampsOutOfRangeTarget() {
        var draft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)
        draft.preferredEthanolTargetPercent = 150
        draft.normalizeForSave()
        #expect(draft.preferredEthanolTargetPercent == 100)

        draft.preferredEthanolTargetPercent = -20
        draft.normalizeForSave()
        #expect(draft.preferredEthanolTargetPercent == 0)
    }

    @Test("normalizeForSave leaves a nil Preferred Ethanol Target as nil — never coerced to 0 or any other value")
    func normalizeForSave_leavesNilTargetAsNil() {
        var draft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)
        #expect(draft.preferredEthanolTargetPercent == nil)
        draft.normalizeForSave()
        #expect(draft.preferredEthanolTargetPercent == nil)
    }

    @Test("normalizeForSave leaves a valid in-range Preferred Ethanol Target, including explicit E0, unchanged")
    func normalizeForSave_leavesValidTargetUnchanged() {
        var draft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)
        draft.preferredEthanolTargetPercent = 0
        draft.normalizeForSave()
        #expect(draft.preferredEthanolTargetPercent == 0)
    }

    @Test("normalizeForSave still floors Tank Size, Odometer, and Octane at 0 — unaffected by this feature")
    func normalizeForSave_stillFloorsOtherNumericFields() {
        var draft = VehicleDraft(vehicle: nil, existingVehiclesCount: 0)
        draft.tankSizeGallons = -5
        draft.currentOdometer = -100
        draft.requiredOctane = -10
        draft.normalizeForSave()
        #expect(draft.tankSizeGallons == 0)
        #expect(draft.currentOdometer == 0)
        #expect(draft.requiredOctane == 0)
    }
}

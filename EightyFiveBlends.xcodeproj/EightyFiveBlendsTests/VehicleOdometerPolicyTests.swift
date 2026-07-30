//
//  VehicleOdometerPolicyTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision rules behind REM-P1-003 (odometer regression protection):
//  whether a routine vehicle edit's entered odometer is a regression, and what value should
//  actually be persisted. These functions are the actual rules GarageView.saveVehicle and
//  AddEditVehicleView call — not a duplicate reimplementation — so passing tests here directly
//  verify production behavior.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//
//  Scenario D from the task's required test list — confirming GarageView.saveVehicle and
//  AddEditVehicleView actually call VehicleOdometerPolicy — is a call-site fact verified by
//  direct code inspection (GarageView.swift:216-219, AddEditVehicleView.swift's
//  isOdometerRegression/Save .disabled), not something a pure unit test can observe. A pure
//  helper test can only prove the rule itself is correct, never that the SwiftUI/SwiftData save
//  flow around it behaves correctly end to end — see the manual validation checklist in the
//  final report for that.

import Testing
@testable import EightyFiveBlends

struct VehicleOdometerPolicyTests {

    // MARK: A. New vehicle (no "existing" value — covered at the call site, not here)
    //
    // VehicleOdometerPolicy is only ever consulted by AddEditVehicleView/GarageView when
    // `vehicle != nil` (an existing vehicle is being edited); a new vehicle's currentOdometer is
    // written directly from the draft with no regression comparison, exactly as required. There
    // is no "existing: nil" case for this pure function to model — see isOdometerRegression in
    // AddEditVehicleView, which returns false outright when `vehicle == nil`.

    @Test("Zero is a valid starting odometer relative to any existing reading of zero")
    func isRegression_zeroRequestedAgainstZeroExisting_isFalse() {
        #expect(VehicleOdometerPolicy.isRegression(existing: 0, requested: 0) == false)
    }

    // MARK: B. Existing vehicle

    @Test("A requested odometer below the existing reading is a regression")
    func isRegression_belowExisting_isTrue() {
        #expect(VehicleOdometerPolicy.isRegression(existing: 149024, requested: 149023))
    }

    @Test("A requested odometer equal to the existing reading is not a regression")
    func isRegression_equalToExisting_isFalse() {
        #expect(VehicleOdometerPolicy.isRegression(existing: 149024, requested: 149024) == false)
    }

    @Test("A requested odometer above the existing reading is not a regression")
    func isRegression_aboveExisting_isFalse() {
        #expect(VehicleOdometerPolicy.isRegression(existing: 149024, requested: 149025) == false)
    }

    @Test("A regression resolves to the existing (unchanged) odometer")
    func resolvedOdometerForRoutineEdit_regression_keepsExisting() {
        #expect(VehicleOdometerPolicy.resolvedOdometerForRoutineEdit(existing: 149024, requested: 149023) == 149024)
    }

    @Test("An equal request resolves to the same value")
    func resolvedOdometerForRoutineEdit_equal_resolvesToSameValue() {
        #expect(VehicleOdometerPolicy.resolvedOdometerForRoutineEdit(existing: 149024, requested: 149024) == 149024)
    }

    @Test("A higher request resolves to the requested (higher) value")
    func resolvedOdometerForRoutineEdit_higher_resolvesToRequested() {
        #expect(VehicleOdometerPolicy.resolvedOdometerForRoutineEdit(existing: 149024, requested: 150500) == 150500)
    }

    @Test("resolvedOdometerForRoutineEdit is equivalent to max(existing, requested) and can never decrease")
    func resolvedOdometerForRoutineEdit_isEquivalentToMax_neverDecreases() {
        let cases: [(existing: Int, requested: Int)] = [
            (149024, 149023), (149024, 149024), (149024, 150000), (0, 5000), (200000, 1)
        ]
        for testCase in cases {
            let result = VehicleOdometerPolicy.resolvedOdometerForRoutineEdit(existing: testCase.existing, requested: testCase.requested)
            #expect(result == max(testCase.existing, testCase.requested))
            #expect(result >= testCase.existing)
        }
    }

    // MARK: C. Large values / overflow safety

    @Test("Large valid Int values are compared and resolved without overflow")
    func largeValues_noOverflow() {
        let large = 999_999_999
        let larger = 1_000_000_000
        #expect(VehicleOdometerPolicy.isRegression(existing: large, requested: larger) == false)
        #expect(VehicleOdometerPolicy.isRegression(existing: larger, requested: large))
        #expect(VehicleOdometerPolicy.resolvedOdometerForRoutineEdit(existing: larger, requested: large) == larger)
        #expect(VehicleOdometerPolicy.resolvedOdometerForRoutineEdit(existing: large, requested: larger) == larger)
    }
}

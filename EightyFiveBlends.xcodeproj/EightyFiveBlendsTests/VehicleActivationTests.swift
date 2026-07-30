//
//  VehicleActivationTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision rules behind REM-P1-002 (zero-active-vehicle protection):
//  whether a vehicle edit should be corrected back to active, and whether a view scoped to
//  "the active vehicle" should fall back to showing every vehicle instead. These functions are
//  the actual rules GarageView.saveVehicle and RemindersView.matchesVehicleFilter call — not a
//  duplicate reimplementation — so passing tests here directly verify production behavior.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//
//  Scenarios 1, 2, 3, 5, and 6 from the task's required test list (who ends up active/inactive
//  across create/switch/delete flows) are NOT covered here: that orchestration lives in
//  GarageView's private, SwiftData- and @Query-coupled methods (saveVehicle, setActiveVehicle,
//  clearActiveFlag, confirmDeletion), which cannot be exercised outside a live SwiftUI view
//  hierarchy without SwiftUI test-hosting infrastructure (e.g. ViewInspector) this repo does
//  not have. Writing a test that re-implements that orchestration against a bare ModelContext
//  would test a copy of the logic, not the real code path, so none was added — see the manual
//  validation checklist in the final report instead.

import Testing
@testable import EightyFiveBlends

struct VehicleActivationTests {

    // MARK: - shouldKeepActive (Scenario 4: deactivating the only active vehicle)

    @Test("Turning off the only active vehicle's Active flag is corrected back to active")
    func shouldKeepActive_onlyActiveVehicleTurnedOff_isTrue() {
        let result = VehicleActivation.shouldKeepActive(
            editedVehicleIsActive: true,
            requestedActive: false,
            anyOtherVehicleIsActive: false
        )
        #expect(result)
    }

    @Test("Turning off an active vehicle's Active flag proceeds normally when another vehicle is already active")
    func shouldKeepActive_anotherVehicleAlreadyActive_isFalse() {
        let result = VehicleActivation.shouldKeepActive(
            editedVehicleIsActive: true,
            requestedActive: false,
            anyOtherVehicleIsActive: true
        )
        #expect(result == false)
    }

    @Test("Editing an already-inactive vehicle without changing its Active flag is not affected")
    func shouldKeepActive_editingInactiveVehicle_isFalse() {
        let result = VehicleActivation.shouldKeepActive(
            editedVehicleIsActive: false,
            requestedActive: false,
            anyOtherVehicleIsActive: true
        )
        #expect(result == false)
    }

    @Test("Setting a vehicle active is never overridden, regardless of other vehicles")
    func shouldKeepActive_settingActive_isAlwaysFalse() {
        #expect(VehicleActivation.shouldKeepActive(editedVehicleIsActive: false, requestedActive: true, anyOtherVehicleIsActive: false) == false)
        #expect(VehicleActivation.shouldKeepActive(editedVehicleIsActive: true, requestedActive: true, anyOtherVehicleIsActive: true) == false)
    }

    // MARK: - shouldFallBackToAllVehicles (Scenarios 7 and 8: Reminders filter fallback)

    @Test("No active vehicle but other vehicles exist falls back to showing everything")
    func shouldFallBackToAllVehicles_noActiveVehicleButVehiclesExist_isTrue() {
        let result = VehicleActivation.shouldFallBackToAllVehicles(hasActiveVehicle: false, hasAnyVehicle: true)
        #expect(result)
    }

    @Test("An active vehicle with zero matching reminders does not fall back (Scenario 8)")
    func shouldFallBackToAllVehicles_activeVehicleExists_isFalse() {
        let result = VehicleActivation.shouldFallBackToAllVehicles(hasActiveVehicle: true, hasAnyVehicle: true)
        #expect(result == false)
    }

    @Test("No vehicles at all does not fall back — there is nothing to fall back to")
    func shouldFallBackToAllVehicles_noVehiclesAtAll_isFalse() {
        let result = VehicleActivation.shouldFallBackToAllVehicles(hasActiveVehicle: false, hasAnyVehicle: false)
        #expect(result == false)
    }

    @Test("Having an active vehicle while somehow also having no vehicles is not a fallback case")
    func shouldFallBackToAllVehicles_activeVehicleNoVehicles_isFalse() {
        // Not a reachable real-world state, but the function must stay false-by-default rather
        // than fall back whenever hasActiveVehicle is true, regardless of hasAnyVehicle.
        let result = VehicleActivation.shouldFallBackToAllVehicles(hasActiveVehicle: true, hasAnyVehicle: false)
        #expect(result == false)
    }
}

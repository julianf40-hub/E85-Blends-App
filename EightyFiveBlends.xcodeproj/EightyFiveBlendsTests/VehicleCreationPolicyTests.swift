//
//  VehicleCreationPolicyTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision rule behind 85Blends 2.3.0's first real Pro entitlement: Free
//  users may create up to SubscriptionManager.freeVehicleLimit vehicles, Pro users unlimited.
//  This is the actual rule GarageView.addVehicleManagementButton, GarageView.saveVehicle, and
//  OnboardingView.completeOnboarding all call — not a duplicate reimplementation — so passing
//  tests here directly verify production behavior.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//
//  What a pure unit test can and cannot prove: these cases confirm the eligibility rule itself
//  is correct for every combination the task specifies. They cannot observe that GarageView/
//  OnboardingView actually call this function at the right moments, that editing an existing
//  vehicle never reaches it, or that CloudKit/downgrade/delete scenarios behave correctly end to
//  end in the running app — those are call-site facts verified by direct code inspection (see
//  the final report) and the manual TestFlight validation matrix, not something this file tests.

import Testing
@testable import EightyFiveBlends

struct VehicleCreationPolicyTests {

    // MARK: A. Free tier

    @Test("Free, 0 vehicles → eligible")
    func free_zeroVehicles_isEligible() {
        #expect(VehicleCreationPolicy.canAddVehicle(currentCount: 0, freeLimit: 1, canAccessUnlimitedVehicles: false))
    }

    @Test("Free, 1 vehicle (at the limit) → not eligible")
    func free_oneVehicle_isNotEligible() {
        #expect(VehicleCreationPolicy.canAddVehicle(currentCount: 1, freeLimit: 1, canAccessUnlimitedVehicles: false) == false)
    }

    @Test("Free, 2 vehicles (grandfathered above the limit) → not eligible")
    func free_twoVehicles_isNotEligible() {
        #expect(VehicleCreationPolicy.canAddVehicle(currentCount: 2, freeLimit: 1, canAccessUnlimitedVehicles: false) == false)
    }

    @Test("Free, many grandfathered vehicles → still not eligible (never negative/overflow behavior)")
    func free_manyVehicles_isNotEligible() {
        #expect(VehicleCreationPolicy.canAddVehicle(currentCount: 50, freeLimit: 1, canAccessUnlimitedVehicles: false) == false)
    }

    // MARK: B. Pro tier — always eligible regardless of count

    @Test("Pro, 0 vehicles → eligible")
    func pro_zeroVehicles_isEligible() {
        #expect(VehicleCreationPolicy.canAddVehicle(currentCount: 0, freeLimit: 1, canAccessUnlimitedVehicles: true))
    }

    @Test("Pro, 1 vehicle → eligible")
    func pro_oneVehicle_isEligible() {
        #expect(VehicleCreationPolicy.canAddVehicle(currentCount: 1, freeLimit: 1, canAccessUnlimitedVehicles: true))
    }

    @Test("Pro, 50 vehicles → still eligible — no artificial numerical ceiling for Pro")
    func pro_manyVehicles_isEligible() {
        #expect(VehicleCreationPolicy.canAddVehicle(currentCount: 50, freeLimit: 1, canAccessUnlimitedVehicles: true))
    }

    // MARK: C. Boundary re-derivation — eligibility recomputes correctly as count changes,
    // exactly matching the delete-then-recheck sequence in the task's required test matrix
    // (3 → 2 → 1 → 0, blocked the whole way until back to 0).

    @Test("Free eligibility recomputes correctly as a grandfathered count is deleted down to zero")
    func free_deletingDownToZero_becomesEligibleOnlyAtZero() {
        let freeLimit = 1
        let countsAfterEachDelete = [3, 2, 1, 0]
        for count in countsAfterEachDelete {
            let isEligible = VehicleCreationPolicy.canAddVehicle(currentCount: count, freeLimit: freeLimit, canAccessUnlimitedVehicles: false)
            #expect(isEligible == (count < freeLimit))
        }
    }

    @Test("Eligibility is a pure function of the current inputs, not a stale cached flag — same count, same result, every time")
    func sameInputs_alwaysProduceSameResult() {
        let first = VehicleCreationPolicy.canAddVehicle(currentCount: 1, freeLimit: 1, canAccessUnlimitedVehicles: false)
        let second = VehicleCreationPolicy.canAddVehicle(currentCount: 1, freeLimit: 1, canAccessUnlimitedVehicles: false)
        #expect(first == second)
        #expect(first == false)
    }
}

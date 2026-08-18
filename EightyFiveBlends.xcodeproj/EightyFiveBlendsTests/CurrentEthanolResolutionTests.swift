//
//  CurrentEthanolResolutionTests.swift
//  EightyFiveBlendsTests
//
//  Tests for FuelPreferenceResolution.CurrentEthanolResolution — Current Ethanol is tank/fill
//  *state* under 85Blends 2.3.0 (sourced from Fuel Log history), never a vehicle-permanent
//  property. Shared by CalculatorView and AtThePumpView so the two screens can never disagree.
//
//  Note: like every other file in this directory, this is not currently wired into a test target
//  in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a test target
//  is added. Written to compile and pass once one exists.
//
//  Scope note: "switching vehicles does not leak the previous vehicle's current ethanol value"
//  is an architectural guarantee of the CALLER (CalculatorView.lastLoggedBlendForActiveVehicle
//  re-derives from the active vehicle's own fuel log entries on every recompute, and this
//  function only ever accepts an already-vehicle-scoped optional) rather than something this
//  pure function itself can demonstrate in isolation — see the manual validation checklist in
//  the final report for that end-to-end guarantee.

import Testing
@testable import EightyFiveBlends

struct CurrentEthanolResolutionTests {

    @Test("A valid latest logged blend is used as-is")
    func validLoggedBlend_isUsed() {
        #expect(CurrentEthanolResolution.resolve(latestLoggedBlendPercent: 42) == 42)
    }

    @Test("No logged blend falls back to E10")
    func noLoggedBlend_fallsBackToE10() {
        #expect(CurrentEthanolResolution.resolve(latestLoggedBlendPercent: nil) == 10)
    }

    @Test("An explicit E0 logged blend is honored, not treated as absent")
    func explicitZeroLoggedBlend_isHonored() {
        #expect(CurrentEthanolResolution.resolve(latestLoggedBlendPercent: 0) == 0)
    }

    @Test("An out-of-range or non-finite logged blend is treated as invalid and falls back to E10")
    func invalidLoggedBlend_fallsBackToE10() {
        #expect(CurrentEthanolResolution.resolve(latestLoggedBlendPercent: -5) == 10)
        #expect(CurrentEthanolResolution.resolve(latestLoggedBlendPercent: 150) == 10)
        #expect(CurrentEthanolResolution.resolve(latestLoggedBlendPercent: .nan) == 10)
        #expect(CurrentEthanolResolution.resolve(latestLoggedBlendPercent: .infinity) == 10)
    }
}

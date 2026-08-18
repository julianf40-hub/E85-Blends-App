//
//  LatestValidFuelLogBlendTests.swift
//  EightyFiveBlendsTests
//
//  Tests for FuelPreferenceResolution.LatestValidFuelLogBlend — the corrective-pass fix for the
//  Current Ethanol history scan that used to filter with `finalBlendPercent > 0`, silently
//  discarding legitimate E0 (pure gasoline) fuel log entries. The correct validity check is
//  `finite && 0...100`, matching every other ethanol-percent validity check in the app.
//
//  Note: like every other file in this directory, this is not currently wired into a test target
//  in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a test target
//  is added. Written to compile and pass once one exists.
//
//  `entries` arrays below are constructed in the exact order the function assumes — newest
//  first, matching the real `@Query(sort: \FuelLogEntry.date, order: .reverse)` this feeds from
//  in CalculatorView — so array position (not the `date` field, which is left at its default) is
//  what determines "newest" in these tests.

import Testing
@testable import EightyFiveBlends

struct LatestValidFuelLogBlendTests {

    @Test("A unique vehicle's newest valid entry (E40) is used")
    func uniqueVehicle_latestValidEntry_e40() {
        let entries = [FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 40)]
        #expect(LatestValidFuelLogBlend.resolve(entries: entries, vehicleName: "Truck") == 40)
    }

    @Test("Explicit E0 is preserved as the resolved value, not skipped as if absent")
    func uniqueVehicle_latestValidEntry_explicitE0() {
        let entries = [FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 0)]
        #expect(LatestValidFuelLogBlend.resolve(entries: entries, vehicleName: "Truck") == 0)
    }

    // MARK: - Decision: an invalid newest entry is skipped in favor of the next valid one
    //
    // FuelLogDraft.normalizeForSave() already clamps finalBlendPercent to 0...100 on every save
    // through this app's own UI, so an out-of-range value can only arise from data that predates
    // that guarantee or from some other future corruption — not a normal occurrence. Given that,
    // skipping a single bad historical row in favor of otherwise-good, more-recent-than-nothing
    // history is the least surprising behavior: it keeps Current Ethanol working normally for a
    // user whose data is otherwise fine, rather than punishing them with a full fallback to E10
    // over one bad row. This mirrors the original code's evident intent (its `> 0` check was
    // clearly trying to skip "not a real value" entries) with the correct validity predicate.

    @Test("An out-of-range newest entry is skipped in favor of the next valid historical entry")
    func invalidNewestEntry_skipsToNextValidEntry() {
        let entries = [
            FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 150), // newest, invalid
            FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 55),  // next, valid
        ]
        #expect(LatestValidFuelLogBlend.resolve(entries: entries, vehicleName: "Truck") == 55)
    }

    @Test("A non-finite newest entry is skipped in favor of the next valid historical entry")
    func nonFiniteNewestEntry_skipsToNextValidEntry() {
        let entries = [
            FuelLogEntry(vehicleName: "Truck", finalBlendPercent: .nan),
            FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 30),
        ]
        #expect(LatestValidFuelLogBlend.resolve(entries: entries, vehicleName: "Truck") == 30)
    }

    @Test("A negative newest entry is skipped in favor of the next valid historical entry")
    func negativeNewestEntry_skipsToNextValidEntry() {
        let entries = [
            FuelLogEntry(vehicleName: "Truck", finalBlendPercent: -5),
            FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 20),
        ]
        #expect(LatestValidFuelLogBlend.resolve(entries: entries, vehicleName: "Truck") == 20)
    }

    @Test("All-invalid history for a vehicle resolves to nil (caller falls back to E10)")
    func allInvalidHistory_resolvesToNil() {
        let entries = [
            FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 150),
            FuelLogEntry(vehicleName: "Truck", finalBlendPercent: -1),
        ]
        #expect(LatestValidFuelLogBlend.resolve(entries: entries, vehicleName: "Truck") == nil)
    }

    @Test("No matching log at all resolves to nil")
    func noMatchingLog_resolvesToNil() {
        #expect(LatestValidFuelLogBlend.resolve(entries: [], vehicleName: "Truck") == nil)
    }

    @Test("Switching vehicles: another vehicle's (even newer) history never resolves for this vehicle")
    func differentVehicleHistory_neverLeaks() {
        let entries = [
            FuelLogEntry(vehicleName: "Sedan", finalBlendPercent: 85), // newest overall, but a different vehicle
            FuelLogEntry(vehicleName: "Truck", finalBlendPercent: 40),
        ]
        #expect(LatestValidFuelLogBlend.resolve(entries: entries, vehicleName: "Truck") == 40)
        #expect(LatestValidFuelLogBlend.resolve(entries: entries, vehicleName: "Sedan") == 85)
    }
}

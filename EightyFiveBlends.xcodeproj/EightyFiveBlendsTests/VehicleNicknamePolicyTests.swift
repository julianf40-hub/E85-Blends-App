//
//  VehicleNicknamePolicyTests.swift
//  EightyFiveBlendsTests
//
//  Tests for VehicleNicknamePolicy — the actual save-time validation rules AddEditVehicleView's
//  Save button and GarageView.saveVehicle's defensive guard both call, not a duplicate
//  reimplementation. Part of the 85Blends 2.3.0 release-blocker fix (vehicle nickname identity
//  safety).
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//

import Testing
@testable import EightyFiveBlends

struct VehicleNicknamePolicyTests {

    // MARK: - normalizedForSave / isBlank

    @Test("Trims leading/trailing whitespace and newlines, nothing else")
    func normalizedForSave_trimsWhitespace() {
        #expect(VehicleNicknamePolicy.normalizedForSave("  Charger  ") == "Charger")
        #expect(VehicleNicknamePolicy.normalizedForSave("\nCharger\t") == "Charger")
        #expect(VehicleNicknamePolicy.normalizedForSave("The Charger") == "The Charger") // internal whitespace untouched
    }

    @Test("An empty string is blank")
    func isBlank_empty_isTrue() {
        #expect(VehicleNicknamePolicy.isBlank(""))
    }

    @Test("A whitespace-only string is blank")
    func isBlank_whitespaceOnly_isTrue() {
        #expect(VehicleNicknamePolicy.isBlank("   "))
        #expect(VehicleNicknamePolicy.isBlank("\t\n"))
    }

    @Test("A real name is not blank")
    func isBlank_realName_isFalse() {
        #expect(VehicleNicknamePolicy.isBlank("Charger") == false)
    }

    // MARK: - conflicts(candidate:excluding:among:) / validationError — creating a new vehicle

    @Test("A normal unique nickname among other vehicles is allowed")
    func newVehicle_uniqueNickname_isAllowed() {
        let existing: [(id: Int, nickname: String)] = [(1, "Charger"), (2, "Sedan")]
        #expect(VehicleNicknamePolicy.conflicts(candidate: "Truck", excluding: nil, among: existing) == false)
        #expect(VehicleNicknamePolicy.validationError(for: "Truck", excluding: nil, among: existing) == nil)
    }

    @Test("An exact duplicate nickname is rejected")
    func newVehicle_exactDuplicate_isRejected() {
        let existing: [(id: Int, nickname: String)] = [(1, "Charger")]
        #expect(VehicleNicknamePolicy.conflicts(candidate: "Charger", excluding: nil, among: existing))
        #expect(VehicleNicknamePolicy.validationError(for: "Charger", excluding: nil, among: existing) == "Another vehicle already uses this nickname.")
    }

    @Test("A case-only duplicate nickname is rejected")
    func newVehicle_caseOnlyDuplicate_isRejected() {
        let existing: [(id: Int, nickname: String)] = [(1, "Charger")]
        #expect(VehicleNicknamePolicy.conflicts(candidate: "charger", excluding: nil, among: existing))
        #expect(VehicleNicknamePolicy.conflicts(candidate: "CHARGER", excluding: nil, among: existing))
    }

    @Test("A surrounding-whitespace duplicate nickname is rejected")
    func newVehicle_surroundingWhitespaceDuplicate_isRejected() {
        let existing: [(id: Int, nickname: String)] = [(1, "Charger")]
        #expect(VehicleNicknamePolicy.conflicts(candidate: " Charger ", excluding: nil, among: existing))
        #expect(VehicleNicknamePolicy.conflicts(candidate: "Charger", excluding: nil, among: [(1, " Charger ")]))
    }

    @Test("A blank candidate is rejected with the blank-specific message, checked before conflicts")
    func newVehicle_blankCandidate_isRejectedAsBlank() {
        let existing: [(id: Int, nickname: String)] = [(1, "Charger")]
        #expect(VehicleNicknamePolicy.validationError(for: "   ", excluding: nil, among: existing) == "Enter a vehicle nickname.")
    }

    // MARK: - Editing an existing vehicle

    @Test("Editing a vehicle without changing its unique nickname is allowed (excluded from its own conflict check)")
    func editVehicle_unchangedNickname_isAllowed() {
        let existing: [(id: Int, nickname: String)] = [(1, "Charger"), (2, "Sedan")]
        #expect(VehicleNicknamePolicy.conflicts(candidate: "Charger", excluding: 1, among: existing) == false)
        #expect(VehicleNicknamePolicy.validationError(for: "Charger", excluding: 1, among: existing) == nil)
    }

    @Test("Renaming a vehicle into another existing vehicle's nickname is rejected")
    func editVehicle_renameIntoAnotherVehiclesName_isRejected() {
        let existing: [(id: Int, nickname: String)] = [(1, "Charger"), (2, "Sedan")]
        #expect(VehicleNicknamePolicy.conflicts(candidate: "Sedan", excluding: 1, among: existing))
        #expect(VehicleNicknamePolicy.validationError(for: "Sedan", excluding: 1, among: existing) == "Another vehicle already uses this nickname.")
    }

    @Test("Renaming a vehicle to a genuinely new, unique nickname is allowed")
    func editVehicle_renameToNewUniqueName_isAllowed() {
        let existing: [(id: Int, nickname: String)] = [(1, "Charger"), (2, "Sedan")]
        #expect(VehicleNicknamePolicy.conflicts(candidate: "Wagon", excluding: 1, among: existing) == false)
    }

    @Test("Renaming a vehicle to blank is rejected")
    func editVehicle_renameToBlank_isRejected() {
        let existing: [(id: Int, nickname: String)] = [(1, "Charger"), (2, "Sedan")]
        #expect(VehicleNicknamePolicy.validationError(for: "", excluding: 1, among: existing) == "Enter a vehicle nickname.")
    }

    @Test("A different vehicle's DIFFERENT nickname never blocks an unrelated save")
    func otherDifferentNicknames_doNotBlock() {
        let existing: [(id: Int, nickname: String)] = [(1, "Charger"), (2, "Sedan"), (3, "Wagon")]
        #expect(VehicleNicknamePolicy.validationError(for: "Truck", excluding: nil, among: existing) == nil)
    }
}

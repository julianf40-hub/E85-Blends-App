//
//  VehicleNicknameResolutionTests.swift
//  EightyFiveBlendsTests
//
//  Tests for VehicleNicknameResolution — the actual runtime lookup RemindersView.vehicleProfile
//  (for:) and its write-path caller (completeReminder's odometer advance) call to resolve a
//  reminder's stored vehicle name back to a VehicleProfile, not a duplicate reimplementation.
//  Part of the 85Blends 2.3.0 release-blocker fix: existing users may already have duplicate
//  vehicle nicknames from before VehicleNicknamePolicy prevented new ones, so this is the runtime
//  fail-safe for that legacy data.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//

import Testing
@testable import EightyFiveBlends

struct VehicleNicknameResolutionTests {

    // MARK: - uniqueMatch(nickname:among:)

    @Test("Zero vehicle matches resolves to nil, not a guessed vehicle")
    func uniqueMatch_zeroMatches_isNil() {
        let sedan = VehicleProfile(nickname: "Sedan")
        let result = VehicleNicknameResolution.uniqueMatch(nickname: "Charger", among: [sedan])
        #expect(result == nil)
    }

    @Test("Exactly one match resolves to that vehicle")
    func uniqueMatch_oneMatch_resolves() {
        let charger = VehicleProfile(nickname: "Charger")
        let sedan = VehicleProfile(nickname: "Sedan")
        let result = VehicleNicknameResolution.uniqueMatch(nickname: "Charger", among: [charger, sedan])
        #expect(result === charger)
    }

    @Test("Two or more matches (ambiguous) resolves to nil — never an arbitrary pick")
    func uniqueMatch_duplicateMatches_isNilNotArbitrary() {
        let charger1 = VehicleProfile(nickname: "Charger")
        let charger2 = VehicleProfile(nickname: "Charger")
        let result = VehicleNicknameResolution.uniqueMatch(nickname: "Charger", among: [charger1, charger2])
        #expect(result == nil)
    }

    @Test("The ambiguous path never arbitrarily picks the first-inserted vehicle, regardless of list order")
    func uniqueMatch_ambiguousPath_neverPicksFirstRegardlessOfOrder() {
        let charger1 = VehicleProfile(nickname: "Charger")
        let charger2 = VehicleProfile(nickname: "Charger")
        let sedan = VehicleProfile(nickname: "Sedan")

        let forward = VehicleNicknameResolution.uniqueMatch(nickname: "Charger", among: [charger1, charger2, sedan])
        let reversed = VehicleNicknameResolution.uniqueMatch(nickname: "Charger", among: [charger2, charger1, sedan])

        #expect(forward == nil)
        #expect(reversed == nil)
    }

    @Test("Three or more matches also resolves to nil")
    func uniqueMatch_threeMatches_isNil() {
        let vehicles = (0..<3).map { _ in VehicleProfile(nickname: "Charger") }
        let result = VehicleNicknameResolution.uniqueMatch(nickname: "Charger", among: vehicles)
        #expect(result == nil)
    }

    @Test("An empty vehicle list resolves to nil")
    func uniqueMatch_emptyList_isNil() {
        #expect(VehicleNicknameResolution.uniqueMatch(nickname: "Charger", among: []) == nil)
    }

    // MARK: - isAmbiguous(nickname:among:)

    @Test("Zero matches is not ambiguous — a legitimate 'no vehicle by this name' outcome")
    func isAmbiguous_zeroMatches_isFalse() {
        let sedan = VehicleProfile(nickname: "Sedan")
        #expect(VehicleNicknameResolution.isAmbiguous(nickname: "Charger", among: [sedan]) == false)
    }

    @Test("One match is not ambiguous")
    func isAmbiguous_oneMatch_isFalse() {
        let charger = VehicleProfile(nickname: "Charger")
        #expect(VehicleNicknameResolution.isAmbiguous(nickname: "Charger", among: [charger]) == false)
    }

    @Test("Two or more matches IS ambiguous")
    func isAmbiguous_twoOrMoreMatches_isTrue() {
        let charger1 = VehicleProfile(nickname: "Charger")
        let charger2 = VehicleProfile(nickname: "Charger")
        #expect(VehicleNicknameResolution.isAmbiguous(nickname: "Charger", among: [charger1, charger2]))
    }

    @Test("Matching is exact-string, not case-insensitive — differently-cased names never register as ambiguous with each other")
    func isAmbiguous_matchingIsCaseSensitive() {
        let charger = VehicleProfile(nickname: "Charger")
        let lowercase = VehicleProfile(nickname: "charger")
        #expect(VehicleNicknameResolution.isAmbiguous(nickname: "Charger", among: [charger, lowercase]) == false)
    }
}

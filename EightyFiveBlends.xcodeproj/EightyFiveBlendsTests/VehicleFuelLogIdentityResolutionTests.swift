//
//  VehicleFuelLogIdentityResolutionTests.swift
//  EightyFiveBlendsTests
//
//  Tests for FuelPreferenceResolution.VehicleFuelLogIdentityResolution — the corrective-pass
//  safety rule deciding whether a vehicle's nickname is safe to use with the legacy
//  FuelLogEntry.vehicleName == VehicleProfile.nickname relationship for Current Ethanol
//  resolution. Garage allows blank and duplicate nicknames, so this exists purely to prevent a
//  naive name match from silently pulling in a different vehicle's fuel log history.
//
//  Note: like every other file in this directory, this is not currently wired into a test target
//  in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a test target
//  is added. Written to compile and pass once one exists.
//
//  Documented matching semantics: exact, untrimmed string equality — the SAME comparison
//  FuelLogEntry.vehicleName is already matched with everywhere else in the app
//  (GarageView.propagateVehicleRename's `#Predicate { $0.vehicleName == oldName }`). Trimming is
//  used ONLY to detect a blank/whitespace-only nickname, never to normalize the match itself —
//  two nicknames differing only by case or internal whitespace are deliberately NOT treated as
//  duplicates, since they are not duplicates from the real Fuel Log relationship's point of view.

import Testing
@testable import EightyFiveBlends

struct VehicleFuelLogIdentityResolutionTests {

    // MARK: - isBlank

    @Test("An empty string is blank")
    func isBlank_empty_isTrue() {
        #expect(VehicleFuelLogIdentityResolution.isBlank(""))
    }

    @Test("A whitespace-only string (spaces, tabs, newlines) is blank")
    func isBlank_whitespaceOnly_isTrue() {
        #expect(VehicleFuelLogIdentityResolution.isBlank("   "))
        #expect(VehicleFuelLogIdentityResolution.isBlank("\t\n"))
        #expect(VehicleFuelLogIdentityResolution.isBlank(" \n \t "))
    }

    @Test("A real name, even with surrounding whitespace, is not blank")
    func isBlank_realName_isFalse() {
        #expect(VehicleFuelLogIdentityResolution.isBlank("Truck") == false)
        #expect(VehicleFuelLogIdentityResolution.isBlank("  Truck  ") == false)
    }

    // MARK: - isSafeFuelLogVehicleName(_:among:)

    @Test("A unique, non-empty nickname among other names is safe")
    func isSafe_uniqueName_isTrue() {
        #expect(VehicleFuelLogIdentityResolution.isSafeFuelLogVehicleName("Truck", among: ["Truck", "Sedan"]))
    }

    @Test("An empty nickname is never safe, regardless of the rest of the list")
    func isSafe_emptyName_isFalse() {
        #expect(VehicleFuelLogIdentityResolution.isSafeFuelLogVehicleName("", among: ["", "Sedan"]) == false)
    }

    @Test("A whitespace-only nickname is never safe")
    func isSafe_whitespaceOnlyName_isFalse() {
        #expect(VehicleFuelLogIdentityResolution.isSafeFuelLogVehicleName("   ", among: ["   ", "Sedan"]) == false)
    }

    @Test("A nickname duplicated by another saved vehicle is unsafe (ambiguous)")
    func isSafe_duplicateName_isFalse() {
        #expect(VehicleFuelLogIdentityResolution.isSafeFuelLogVehicleName("Truck", among: ["Truck", "Truck"]) == false)
    }

    @Test("Another vehicle with a DIFFERENT nickname does not invalidate this one")
    func isSafe_otherDifferentNicknames_doNotInvalidate() {
        #expect(VehicleFuelLogIdentityResolution.isSafeFuelLogVehicleName("Truck", among: ["Truck", "Sedan", "Wagon"]))
    }

    @Test("A single-vehicle garage's nickname is trivially safe")
    func isSafe_singleVehicle_isTrue() {
        #expect(VehicleFuelLogIdentityResolution.isSafeFuelLogVehicleName("Truck", among: ["Truck"]))
    }

    @Test("Matching is exact-string, not case-insensitive — differently-cased names are not duplicates")
    func isSafe_matchingIsCaseSensitive() {
        #expect(VehicleFuelLogIdentityResolution.isSafeFuelLogVehicleName("Truck", among: ["Truck", "truck"]))
    }

    @Test("Matching does not trim for comparison — internal/trailing whitespace differences are not duplicates")
    func isSafe_matchingDoesNotNormalizeWhitespace() {
        #expect(VehicleFuelLogIdentityResolution.isSafeFuelLogVehicleName("Truck", among: ["Truck", "Truck "]))
    }

    // MARK: - safeFuelLogVehicleName(for:among:) — VehicleProfile convenience overload

    @Test("A unique vehicle among others returns its nickname")
    func safeFuelLogVehicleName_uniqueVehicle_returnsNickname() {
        let truck = VehicleProfile(nickname: "Truck")
        let sedan = VehicleProfile(nickname: "Sedan")
        let result = VehicleFuelLogIdentityResolution.safeFuelLogVehicleName(for: truck, among: [truck, sedan])
        #expect(result == "Truck")
    }

    @Test("A vehicle with a blank nickname returns nil")
    func safeFuelLogVehicleName_blankNickname_returnsNil() {
        let unnamed = VehicleProfile(nickname: "")
        let result = VehicleFuelLogIdentityResolution.safeFuelLogVehicleName(for: unnamed, among: [unnamed])
        #expect(result == nil)
    }

    @Test("A vehicle whose nickname is duplicated by another saved vehicle returns nil")
    func safeFuelLogVehicleName_duplicateNickname_returnsNil() {
        let truck1 = VehicleProfile(nickname: "Truck")
        let truck2 = VehicleProfile(nickname: "Truck")
        let result = VehicleFuelLogIdentityResolution.safeFuelLogVehicleName(for: truck1, among: [truck1, truck2])
        #expect(result == nil)
    }

    @Test("A duplicate on an inactive vehicle still invalidates the active vehicle's nickname")
    func safeFuelLogVehicleName_duplicateOnInactiveVehicle_stillUnsafe() {
        let active = VehicleProfile(nickname: "Truck", isActive: true)
        let inactiveDuplicate = VehicleProfile(nickname: "Truck", isActive: false)
        let result = VehicleFuelLogIdentityResolution.safeFuelLogVehicleName(for: active, among: [active, inactiveDuplicate])
        #expect(result == nil)
    }
}

//
//  StationsNativeAdPlacementTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure placement rule behind the Free Classic Stations list's repeating native
//  ad slots (StationsView.StationsNativeAdPlacement) — the actual functions
//  stationRowsWithNativeAd calls, not duplicate reimplementations, so passing tests here
//  directly verify production behavior. Pins the count formula (floor((stationCount - 1) / 3)),
//  the "never a trailing ad" rule, Pro/entitlement-pending zero-ad gating, and that every ad
//  slot's id is independent of station id.
//

import Testing
@testable import EightyFiveBlends

struct StationsNativeAdPlacementTests {

    // MARK: - adSlotCount formula (Free, entitlement resolved)

    @Test("Ad-slot count matches floor((stationCount - 1) / 3) for every documented station count", arguments: [
        (0, 0), (1, 0), (2, 0), (3, 0),
        (4, 1), (5, 1), (6, 1),
        (7, 2), (8, 2), (9, 2),
        (10, 3), (11, 3), (12, 3),
        (13, 4)
    ])
    func adSlotCount_freeUser_matchesFormula(stationCount: Int, expectedAdCount: Int) {
        #expect(StationsNativeAdPlacement.adSlotCount(
            stationCount: stationCount,
            isProUser: false,
            isEntitlementResolutionPending: false
        ) == expectedAdCount)
    }

    // MARK: - Pro / entitlement-pending zero-ad gating

    @Test("Pro users always get zero ad slots, regardless of station count")
    func adSlotCount_proUser_isAlwaysZero() {
        for stationCount in [0, 1, 4, 10, 13, 50] {
            #expect(StationsNativeAdPlacement.adSlotCount(
                stationCount: stationCount,
                isProUser: true,
                isEntitlementResolutionPending: false
            ) == 0)
        }
    }

    @Test("Pending initial entitlement resolution always gets zero ad slots, regardless of station count")
    func adSlotCount_entitlementPending_isAlwaysZero() {
        for stationCount in [0, 1, 4, 10, 13, 50] {
            #expect(StationsNativeAdPlacement.adSlotCount(
                stationCount: stationCount,
                isProUser: false,
                isEntitlementResolutionPending: true
            ) == 0)
        }
    }

    // MARK: - Row ordering

    @Test("4 stations: one ad after the first group of 3, none trailing")
    func rows_fourStations_ordering() {
        let ids = ["s1", "s2", "s3", "s4"]
        let rows = StationsNativeAdPlacement.rows(stationIDs: ids, isProUser: false, isEntitlementResolutionPending: false)
        #expect(rows.map(\.id) == ["s1", "s2", "s3", "stations-native-ad-slot-0", "s4"])
    }

    @Test("7 stations: two ads, one after each complete group of 3")
    func rows_sevenStations_ordering() {
        let ids = (1...7).map { "s\($0)" }
        let rows = StationsNativeAdPlacement.rows(stationIDs: ids, isProUser: false, isEntitlementResolutionPending: false)
        #expect(rows.map(\.id) == [
            "s1", "s2", "s3", "stations-native-ad-slot-0",
            "s4", "s5", "s6", "stations-native-ad-slot-1",
            "s7"
        ])
    }

    @Test("10 stations: three ads, none trailing")
    func rows_tenStations_ordering() {
        let ids = (1...10).map { "s\($0)" }
        let rows = StationsNativeAdPlacement.rows(stationIDs: ids, isProUser: false, isEntitlementResolutionPending: false)
        #expect(rows.map(\.id) == [
            "s1", "s2", "s3", "stations-native-ad-slot-0",
            "s4", "s5", "s6", "stations-native-ad-slot-1",
            "s7", "s8", "s9", "stations-native-ad-slot-2",
            "s10"
        ])
    }

    @Test("13 stations: four ads, last station has no ad after it")
    func rows_thirteenStations_ordering() {
        let ids = (1...13).map { "s\($0)" }
        let rows = StationsNativeAdPlacement.rows(stationIDs: ids, isProUser: false, isEntitlementResolutionPending: false)
        #expect(rows.map(\.id) == [
            "s1", "s2", "s3", "stations-native-ad-slot-0",
            "s4", "s5", "s6", "stations-native-ad-slot-1",
            "s7", "s8", "s9", "stations-native-ad-slot-2",
            "s10", "s11", "s12", "stations-native-ad-slot-3",
            "s13"
        ])
    }

    @Test("3 stations: no ad — the list must never end with an ad")
    func rows_threeStations_noTrailingAd() {
        let ids = ["s1", "s2", "s3"]
        let rows = StationsNativeAdPlacement.rows(stationIDs: ids, isProUser: false, isEntitlementResolutionPending: false)
        #expect(rows.map(\.id) == ["s1", "s2", "s3"])
    }

    @Test("Pro users see plain station rows with no ad markers at all, even at counts that would otherwise get ads")
    func rows_proUser_noAdRows() {
        let ids = (1...13).map { "s\($0)" }
        let rows = StationsNativeAdPlacement.rows(stationIDs: ids, isProUser: true, isEntitlementResolutionPending: false)
        #expect(rows.map(\.id) == ids)
    }

    @Test("Pending entitlement resolution sees plain station rows with no ad markers at all")
    func rows_entitlementPending_noAdRows() {
        let ids = (1...13).map { "s\($0)" }
        let rows = StationsNativeAdPlacement.rows(stationIDs: ids, isProUser: false, isEntitlementResolutionPending: true)
        #expect(rows.map(\.id) == ids)
    }

    // MARK: - Ad identity independent of station identity

    @Test("Ad slot ids depend only on logical position, not on which station ids are adjacent")
    func rows_adSlotIdentity_isIndependentOfStationIDs() {
        let originalOrder = ["a", "b", "c", "d", "e", "f", "g"]
        let reordered = ["g", "f", "e", "d", "c", "b", "a"]

        let rowsOriginal = StationsNativeAdPlacement.rows(stationIDs: originalOrder, isProUser: false, isEntitlementResolutionPending: false)
        let rowsReordered = StationsNativeAdPlacement.rows(stationIDs: reordered, isProUser: false, isEntitlementResolutionPending: false)

        let adIDsOriginal = rowsOriginal.compactMap { row -> String? in
            if case .nativeAd = row { return row.id }
            return nil
        }
        let adIDsReordered = rowsReordered.compactMap { row -> String? in
            if case .nativeAd = row { return row.id }
            return nil
        }

        #expect(adIDsOriginal == ["stations-native-ad-slot-0", "stations-native-ad-slot-1"])
        #expect(adIDsOriginal == adIDsReordered)
    }
}

//
//  CommunityPriceParityTests.swift
//  EightyFiveBlendsTests
//
//  2.4.0 Stations readability refinement — CommunityPriceParity.matches(local:community:)
//  (StationsView.swift) decides whether StationRowCard's community supporting line says
//  "Community confirmed" instead of repeating an identical dollar amount. It compares through
//  the same "$%.2f" formatting already used to display each price, never raw Double equality,
//  so two values that round to the same displayed price (e.g. 2.789 and 2.79, both "$2.79")
//  are correctly treated as matching even though they aren't bit-for-bit equal.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct CommunityPriceParityTests {
    @Test("Identical prices match")
    func matches_identicalPrices() {
        #expect(CommunityPriceParity.matches(local: 3.89, community: 3.89) == true)
    }

    @Test("Prices that round to the same displayed cents match, even with extra precision")
    func matches_sameDisplayedCentsWithFloatingPointNoise() {
        // 3.8901 -> "$3.89", same as 3.89 itself.
        #expect(CommunityPriceParity.matches(local: 3.8901, community: 3.89) == true)
        // The task's own example: 2.789 and 2.79 both render as $2.79.
        #expect(CommunityPriceParity.matches(local: 2.789, community: 2.79) == true)
    }

    @Test("Genuinely different displayed prices do not match")
    func matches_differentDisplayedPrices() {
        #expect(CommunityPriceParity.matches(local: 3.89, community: 3.79) == false)
        // Close, but rounds to a different cent value ($3.89 vs $3.90) — still a real
        // difference the user would see at the pump, so it must not be collapsed away.
        #expect(CommunityPriceParity.matches(local: 3.891, community: 3.899) == false)
    }

    @Test("Comparison is symmetric")
    func matches_isSymmetric() {
        #expect(CommunityPriceParity.matches(local: 3.89, community: 3.79) == CommunityPriceParity.matches(local: 3.79, community: 3.89))
        #expect(CommunityPriceParity.matches(local: 2.789, community: 2.79) == CommunityPriceParity.matches(local: 2.79, community: 2.789))
    }
}

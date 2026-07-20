//
//  StationDataValidationTests.swift
//  EightyFiveBlendsTests
//
//  Tests for centralized station price/coordinate/timestamp validation and freshness rules.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct StationDataValidationTests {

    // MARK: - Price

    @Test("A normal positive price is valid")
    func isValidPrice_normalValue_isValid() {
        #expect(StationDataValidation.isValidPrice(3.49))
    }

    @Test("Zero, negative, NaN, and infinite prices are invalid")
    func isValidPrice_zeroNegativeOrNonFinite_isInvalid() {
        #expect(StationDataValidation.isValidPrice(0) == false)
        #expect(StationDataValidation.isValidPrice(-1.25) == false)
        #expect(StationDataValidation.isValidPrice(.nan) == false)
        #expect(StationDataValidation.isValidPrice(.infinity) == false)
    }

    @Test("A clearly impossible price above the plausible ceiling is invalid")
    func isValidPrice_impossiblyHigh_isInvalid() {
        #expect(StationDataValidation.isValidPrice(999.99) == false)
        #expect(StationDataValidation.isValidPrice(StationDataValidation.maximumPlausiblePricePerGallon) == true)
        #expect(StationDataValidation.isValidPrice(StationDataValidation.maximumPlausiblePricePerGallon + 0.01) == false)
    }

    // MARK: - Coordinates

    @Test("A real-world coordinate is valid")
    func isValidCoordinate_realWorld_isValid() {
        #expect(StationDataValidation.isValidCoordinate(latitude: 39.9612, longitude: -82.9988))
    }

    @Test("Out-of-range latitude or longitude is invalid")
    func isValidCoordinate_outOfRange_isInvalid() {
        #expect(StationDataValidation.isValidCoordinate(latitude: 95, longitude: 0) == false)
        #expect(StationDataValidation.isValidCoordinate(latitude: 0, longitude: 200) == false)
        #expect(StationDataValidation.isValidCoordinate(latitude: -95, longitude: -200) == false)
    }

    @Test("NaN or infinite coordinates are invalid")
    func isValidCoordinate_nonFinite_isInvalid() {
        #expect(StationDataValidation.isValidCoordinate(latitude: .nan, longitude: 0) == false)
        #expect(StationDataValidation.isValidCoordinate(latitude: 0, longitude: .infinity) == false)
    }

    @Test("Null Island (0, 0) is rejected as an unset placeholder, not a real station")
    func isValidCoordinate_nullIsland_isInvalid() {
        #expect(StationDataValidation.isValidCoordinate(latitude: 0, longitude: 0) == false)
    }

    @Test("A coordinate exactly on the equator or prime meridian (but not both) is valid")
    func isValidCoordinate_onAxisButNotOrigin_isValid() {
        #expect(StationDataValidation.isValidCoordinate(latitude: 0, longitude: 45))
        #expect(StationDataValidation.isValidCoordinate(latitude: 45, longitude: 0))
    }

    // MARK: - Timestamps

    @Test("A recent timestamp is valid")
    func isValidTimestamp_recent_isValid() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = now.addingTimeInterval(-3600)
        #expect(StationDataValidation.isValidTimestamp(recent, asOf: now))
    }

    @Test("A timestamp far in the future is invalid")
    func isValidTimestamp_farFuture_isInvalid() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(3600)
        #expect(StationDataValidation.isValidTimestamp(future, asOf: now) == false)
    }

    @Test("A timestamp within the clock-skew tolerance window is still valid")
    func isValidTimestamp_withinToleranceWindow_isValid() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let slightlyAhead = now.addingTimeInterval(60)
        #expect(StationDataValidation.isValidTimestamp(slightlyAhead, asOf: now))
    }

    @Test("An uninitialized epoch-zero timestamp is invalid")
    func isValidTimestamp_epochZero_isInvalid() {
        #expect(StationDataValidation.isValidTimestamp(Date(timeIntervalSince1970: 0)) == false)
        #expect(StationDataValidation.isValidTimestamp(Date(timeIntervalSince1970: -100)) == false)
    }

    // MARK: - Freshness tiers

    @Test("Price freshness moves through fresh, check-price, and stale tiers at the day thresholds")
    func priceFreshnessTier_thresholds() {
        #expect(StationDataValidation.priceFreshnessTier(hasPrice: false, daysSinceUpdate: 0) == .noPrice)
        #expect(StationDataValidation.priceFreshnessTier(hasPrice: true, daysSinceUpdate: 0) == .fresh)
        #expect(StationDataValidation.priceFreshnessTier(hasPrice: true, daysSinceUpdate: 7) == .fresh)
        #expect(StationDataValidation.priceFreshnessTier(hasPrice: true, daysSinceUpdate: 8) == .checkPrice)
        #expect(StationDataValidation.priceFreshnessTier(hasPrice: true, daysSinceUpdate: 14) == .checkPrice)
        #expect(StationDataValidation.priceFreshnessTier(hasPrice: true, daysSinceUpdate: 15) == .stale)
    }

    @Test("isStale respects a custom threshold")
    func isStale_customThreshold() {
        #expect(StationDataValidation.isStale(daysSince: 5, thresholdDays: 3))
        #expect(StationDataValidation.isStale(daysSince: 2, thresholdDays: 3) == false)
    }

    // MARK: - daysSince

    @Test("daysSince never returns a negative value even for a future-dated timestamp")
    func daysSince_futureTimestamp_clampsToZero() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let future = calendar.date(from: DateComponents(year: 2026, month: 6, day: 5))!
        #expect(StationDataValidation.daysSince(future, asOf: now, calendar: calendar) == 0)
    }

    // MARK: - Duplicate names

    @Test("Duplicate names are detected regardless of casing or surrounding whitespace")
    func isDuplicateName_caseAndWhitespaceInsensitive() {
        #expect(StationDataValidation.isDuplicateName("Shell", "  shell  "))
        #expect(StationDataValidation.isDuplicateName("Kum & Go", "KUM & GO"))
    }

    @Test("Different station names are not duplicates")
    func isDuplicateName_differentNames_isFalse() {
        #expect(StationDataValidation.isDuplicateName("Shell", "Speedway") == false)
    }

    @Test("Two empty names are never considered duplicates of each other")
    func isDuplicateName_bothEmpty_isFalse() {
        #expect(StationDataValidation.isDuplicateName("", "   ") == false)
    }
}

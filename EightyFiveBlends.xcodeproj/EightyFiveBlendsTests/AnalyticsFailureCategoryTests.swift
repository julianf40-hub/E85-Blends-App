//
//  AnalyticsFailureCategoryTests.swift
//  EightyFiveBlendsTests
//
//  Exhaustively exercises AnalyticsFailureCategory.category(for:) (AnalyticsEvent.swift) against
//  every CommunityPriceServiceError case plus the non-CommunityPriceServiceError fallback — the
//  complete input space that function's switch can ever see from savePriceUpdate's catch block
//  (StationsView.swift). Confirms every possible output is a short, stable, bounded string that
//  satisfies the live `e85_analytics_failure_category_shape` CHECK constraint
//  (supabase/migrations/20260909101440_limit_e85_analytics_failure_category.sql: a string,
//  1-128 characters) and never embeds an error's raw associated data.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private struct SomeOtherError: Error {}

struct AnalyticsFailureCategoryTests {
    private static let dbShapeRange = 1...128

    @Test("Every CommunityPriceServiceError case, and the non-CommunityPriceServiceError fallback, map to a distinct stable string")
    func category_coversEveryKnownError() {
        #expect(AnalyticsFailureCategory.category(for: CommunityPriceServiceError.notConfigured) == "not_configured")
        #expect(AnalyticsFailureCategory.category(for: CommunityPriceServiceError.invalidBaseURL) == "invalid_base_url")
        #expect(AnalyticsFailureCategory.category(for: CommunityPriceServiceError.invalidResponse) == "invalid_response")
        #expect(AnalyticsFailureCategory.category(for: CommunityPriceServiceError.stationLookupFailed) == "station_lookup_failed")
        #expect(
            AnalyticsFailureCategory.category(
                for: CommunityPriceServiceError.requestFailed(statusCode: 500, message: "boom")
            ) == "request_failed"
        )

        // Anything that isn't a CommunityPriceServiceError at all (a plain URLError, a decoding
        // error, or any other Swift Error) — the fallback savePriceUpdate's catch block would
        // hit for a genuine network failure.
        #expect(AnalyticsFailureCategory.category(for: URLError(.timedOut)) == "network_error")
        #expect(AnalyticsFailureCategory.category(for: SomeOtherError()) == "network_error")
    }

    @Test("requestFailed's raw statusCode and message are never embedded in the emitted category")
    func category_neverLeaksRequestFailedAssociatedData() {
        let category = AnalyticsFailureCategory.category(
            for: CommunityPriceServiceError.requestFailed(
                statusCode: 503,
                message: "https://example.invalid/secret-station-endpoint?lat=39.0&lon=-104.0"
            )
        )

        #expect(category == "request_failed")
        #expect(category.contains("503") == false)
        #expect(category.contains("secret-station-endpoint") == false)
        #expect(category.contains("lat=") == false)
    }

    @Test(
        "Every possible category satisfies the DB's non-empty, <=128-character shape constraint",
        arguments: [
            AnalyticsFailureCategory.category(for: CommunityPriceServiceError.notConfigured),
            AnalyticsFailureCategory.category(for: CommunityPriceServiceError.invalidBaseURL),
            AnalyticsFailureCategory.category(for: CommunityPriceServiceError.requestFailed(statusCode: 500, message: "x")),
            AnalyticsFailureCategory.category(for: CommunityPriceServiceError.invalidResponse),
            AnalyticsFailureCategory.category(for: CommunityPriceServiceError.stationLookupFailed),
            AnalyticsFailureCategory.category(for: URLError(.notConnectedToInternet)),
        ]
    )
    func category_matchesDatabaseShapeConstraint(_ category: String) {
        #expect(Self.dbShapeRange.contains(category.count))
    }
}

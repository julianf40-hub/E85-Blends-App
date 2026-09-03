//
//  CommunityPriceValidation.swift
//  EightyFiveBlends
//
//  Pure decision logic behind Community E85 Price Reporting's client-side price bound. Kept
//  independent of SwiftUI/SwiftData/StationsView — mirroring CommunityPriceEligibility.swift's
//  own separation of pure rules from the view that calls them (see that file's header) — so the
//  actual rule StationsView.savePriceUpdate depends on is directly unit-testable. See
//  EightyFiveBlendsTests/CommunityPriceValidationTests.swift.
//
//  2.3.2 public-release-readiness fix: StationsView previously only rejected a price that failed
//  to parse as a Double, or parsed to zero or less (`Double(trimmedPrice), parsedPrice > 0`).
//  That accepted `$999`, `$0.50`, and — because Swift's `Double.init?(String)` parses the literal
//  strings "nan"/"inf"/"infinity" — even non-finite values a user could type directly into the
//  field. Production Supabase enforces `price >= 1.00 AND price <= 8.00` on `e85_price_reports`
//  via both an RLS WITH CHECK and a table CHECK constraint (see
//  docs/PRE_RELEASE_SUPABASE_CHECKLIST.md) — a report outside that bound was always going to be
//  rejected server-side, just silently/confusingly, and a "Save Locally" price never went to the
//  server at all, so an absurd local-only price could sit uncaught in a FuelStation's own
//  lastKnownE85Price and skew Trip Planner's cost estimates. This file makes the client-side rule
//  match the server bound exactly, so the user gets an immediate, specific message instead of a
//  silent server-side rejection (or an uncaught bad local value). The server bound is the source
//  of truth; `minimumValidPrice`/`maximumValidPrice` below must only ever be changed to match a
//  future server-side change, never diverge from it independently.
//

import Foundation

enum CommunityPriceValidation {
    /// Matches production Supabase's live bound on `e85_price_reports.price` exactly.
    static let minimumValidPrice = 1.00
    static let maximumValidPrice = 8.00

    /// Parses and validates a user-typed E85 price string. Returns the parsed price only if it
    /// is a genuine finite number within `[minimumValidPrice, maximumValidPrice]`; returns `nil`
    /// for blank, whitespace-only, malformed, non-finite (`NaN`/`Infinity` — see this file's
    /// header for why that's a real, reachable input, not a hypothetical), or out-of-range input.
    static func parseValidPrice(from rawInput: String) -> Double? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let parsed = Double(trimmed),
            parsed.isFinite,
            parsed >= minimumValidPrice,
            parsed <= maximumValidPrice
        else {
            return nil
        }
        return parsed
    }
}

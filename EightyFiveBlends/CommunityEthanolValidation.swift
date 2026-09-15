//
//  CommunityEthanolValidation.swift
//  EightyFiveBlends
//
//  Pure decision logic behind Community Ethanol % Reporting's client-side bounds. Kept
//  independent of SwiftUI/SwiftData/StationsView — mirroring CommunityPriceValidation.swift's
//  own separation of a pure rule from the view that calls it — so the actual rule StationsView
//  will depend on is directly unit-testable. See
//  EightyFiveBlendsTests/CommunityEthanolValidationTests.swift.
//
//  Two independent, deliberately separate concerns live here:
//  - Hard validity (`parseValidPercentage`): any finite percentage from 0 through 100 is a
//    physically meaningful ethanol content and is accepted — unlike price, there is no server
//    bound narrower than the full physical range, so this only has to guard against blank,
//    malformed, and non-finite input. Swift's `Double.init?(String)` parses the literal strings
//    "nan"/"inf"/"infinity" successfully (see CommunityPriceValidation.swift's own header for the
//    same reachable-input gotcha), so those are rejected explicitly rather than assumed away.
//  - Expected-range classification (`requiresConfirmation`): 51-83% is the range a genuine E85
//    pump is expected to read. A value outside that band but still inside 0-100 is never
//    rejected — it's a real, if unusual, reading (e.g. a misread pump sticker, or a blend outside
//    typical seasonal formulations) — it only has to clear a separate user confirmation before
//    being submitted. This function never touches, and is never touched by, the hard-validity
//    bound above.
//
//  Accepted values are normalized to at most one decimal place (`normalizedToOneDecimalPlace`) —
//  enough precision to preserve a real reading (e.g. a pump sticker printed as "83.7%"), without
//  storing spurious extra digits a hand-typed measurement was never actually precise to. Never
//  rounded to a whole percentage — that would silently discard a meaningful decimal a user
//  actually entered.
//

import Foundation

enum CommunityEthanolValidation {
    /// The full physically meaningful range for an ethanol percentage. Unlike
    /// `CommunityPriceValidation`'s price bound, this is not a narrower server-enforced business
    /// rule — it's simply "a percentage," so the only values rejected here are ones that
    /// couldn't be a percentage at all.
    static let minimumValidPercentage = 0.0
    static let maximumValidPercentage = 100.0

    /// The range a genuine E85 pump is expected to read. Values outside this band remain valid
    /// (see `requiresConfirmation`) — this is a confirmation threshold, never a rejection bound.
    static let expectedRangeLowerBound = 51.0
    static let expectedRangeUpperBound = 83.0

    /// Parses and validates a user-typed ethanol percentage string. Returns the parsed value,
    /// normalized to at most one decimal place, only if it is a genuine finite number within
    /// `[minimumValidPercentage, maximumValidPercentage]`; returns `nil` for blank,
    /// whitespace-only, malformed, or non-finite (`NaN`/`Infinity`) input.
    ///
    /// Says nothing about whether the value falls inside the expected E85 range — see
    /// `requiresConfirmation` for that separate, non-rejecting classification.
    static func parseValidPercentage(from rawInput: String) -> Double? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let parsed = Double(trimmed),
            parsed.isFinite,
            parsed >= minimumValidPercentage,
            parsed <= maximumValidPercentage
        else {
            return nil
        }
        return normalizedToOneDecimalPlace(parsed)
    }

    /// Rounds to the nearest tenth. Never collapses a real decimal reading to a whole percentage.
    static func normalizedToOneDecimalPlace(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    /// Whether `percentage` falls outside the expected E85 range (`expectedRangeLowerBound`...
    /// `expectedRangeUpperBound`) and should therefore require the user to explicitly confirm
    /// before it is submitted. Expects an already-validated percentage (typically the output of
    /// `parseValidPercentage`) — this performs no validity checking of its own, only range
    /// classification, so hard validity and expected-range classification can never be conflated
    /// into one rule.
    static func requiresConfirmation(forPercentage percentage: Double) -> Bool {
        (expectedRangeLowerBound...expectedRangeUpperBound).contains(percentage) == false
    }
}

//
//  StationDataValidation.swift
//  EightyFiveBlends
//
//  Centralized, pure validation and freshness rules for saved fuel stations and community
//  price reports. Kept independent of SwiftUI/SwiftData so it can be unit tested directly,
//  and so "is this price/coordinate/timestamp sane" isn't reimplemented at each call site.
//

import Foundation

nonisolated enum StationDataValidation {
    // MARK: - Price

    /// A price at or above this is treated as an implausible entry (e.g. a typo like $999)
    /// rather than a real pump price, so it's rejected instead of silently stored. Matches the
    /// sane-range ceiling already documented for community price reports in
    /// docs/PRE_RELEASE_SUPABASE_CHECKLIST.md, so the client and the recommended server-side
    /// CHECK constraint agree on what counts as a plausible price.
    static let maximumPlausiblePricePerGallon = 15.0

    /// A saved/reported price must be a finite, positive, plausible dollar amount. Zero and
    /// negative prices are treated as "no price," not a real value.
    static func isValidPrice(_ price: Double) -> Bool {
        price.isFinite && price > 0 && price <= maximumPlausiblePricePerGallon
    }

    // MARK: - Coordinates

    /// A valid station coordinate must be finite and within real latitude/longitude ranges.
    /// (0, 0) — "Null Island" — is never a real station location; it almost always indicates
    /// unset or corrupted data, so it's rejected rather than treated as a real point.
    static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite else { return false }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return false }
        return latitude != 0 || longitude != 0
    }

    // MARK: - Timestamps

    /// A valid report/update timestamp must be after the Unix epoch (rules out an
    /// uninitialized `Date(timeIntervalSince1970: 0)` slipping in as if it were real) and not
    /// meaningfully in the future (small tolerance for clock skew between devices).
    static func isValidTimestamp(
        _ date: Date,
        asOf: Date = .now,
        futureToleranceSeconds: TimeInterval = 300
    ) -> Bool {
        guard date.timeIntervalSince1970 > 0 else { return false }
        return date.timeIntervalSince(asOf) <= futureToleranceSeconds
    }

    // MARK: - Community ethanol reports

    /// The percentage range a genuine E85 pump is expected to read. A report outside this band
    /// is still physically possible (see CommunityEthanolValidation's own 0...100 hard-validity
    /// bound) and is never rejected outright — it only needs extra confirmation/context before
    /// being shown. Single source of truth for both: CommunityEthanolValidation.requiresConfirmation
    /// uses it to decide when the main app needs that confirmation, and (via the widget
    /// extension's own dual-compilation of this file) NearbyE85Ethanol.validated(...) uses the
    /// exact same range to decide widget eligibility — the two call sites intentionally differ in
    /// what they DO with an out-of-range value (warn-and-still-show vs. omit-for-lack-of-space),
    /// never in what counts as "expected" in the first place.
    static let expectedE85EthanolRange: ClosedRange<Double> = 51.0...83.0

    // MARK: - Freshness

    /// Whole calendar days between `date` and `asOf`, clamped to zero so a clock-skewed
    /// future timestamp can't produce a negative "days since" figure.
    static func daysSince(_ date: Date, asOf: Date = .now, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let now = calendar.startOfDay(for: asOf)
        return max(calendar.dateComponents([.day], from: start, to: now).day ?? 0, 0)
    }

    static func isStale(daysSince days: Int, thresholdDays: Int = 14) -> Bool {
        days > thresholdDays
    }

    enum PriceFreshness: Equatable {
        case noPrice
        case fresh
        case checkPrice
        case stale
    }

    /// Mirrors the app's existing 7/14-day freshness tiers (fresh / check price / stale) as a
    /// single pure function instead of the same day-count thresholds being reimplemented at
    /// every place a station or price report is displayed.
    static func priceFreshnessTier(hasPrice: Bool, daysSinceUpdate days: Int) -> PriceFreshness {
        guard hasPrice else { return .noPrice }
        if days <= 7 { return .fresh }
        if days <= 14 { return .checkPrice }
        return .stale
    }

    // MARK: - Duplicate identification

    /// A normalized key for matching station names regardless of whitespace/casing
    /// differences, mirroring the case-insensitive matching already used when linking a
    /// fuel-log entry to a saved station.
    static func normalizedNameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when two station names are the same real-world station after normalization.
    /// Two empty names are never considered duplicates of each other.
    static func isDuplicateName(_ nameA: String, _ nameB: String) -> Bool {
        let keyA = normalizedNameKey(nameA)
        guard keyA.isEmpty == false else { return false }
        return keyA == normalizedNameKey(nameB)
    }
}

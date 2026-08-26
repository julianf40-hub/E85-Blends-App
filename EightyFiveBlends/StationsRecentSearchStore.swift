//
//  StationsRecentSearchStore.swift
//  EightyFiveBlends
//
//  Stations instant-loading foundation (2.3.2, PR A) — a small, session-scoped, in-memory
//  cache of the most recent CURRENT-LOCATION live-station search, so Stations can render a
//  compatible recent result set immediately on appearance instead of waiting for a fresh
//  Core Location fix + NREL network round trip every time. See the 2.3.2 architecture audit
//  for the full root-cause trace: the ~10-15s real-device delay is dominated by a cold,
//  high-accuracy (kCLLocationAccuracyNearestTenMeters) one-shot location fix, not by the
//  network call itself.
//
//  DELIBERATELY SEPARATE from RecentLiveStationCache (Pump Mode's own cache): that type
//  stores a lightweight subset of fields for a completely different purpose (recognizing a
//  station the user recently drove to, for up to 6 hours, for manual Pump Mode's
//  station-context resolution) and must not be repurposed for Stations' own display needs —
//  its 6-hour lifetime and "wholesale replace" semantics are tuned for Pump Mode's question,
//  not Stations'. This store is Stations-only; StationsView continues to write BOTH caches
//  independently from the same successful fetch (see StationsView.fetchLiveStations) — this
//  store is additive, never a replacement for the existing RecentLiveStationCache write.
//
//  This store owns only reusable session data + freshness/compatibility decisions. It does
//  NOT make network requests, own map camera state, own SwiftUI UI state, own community
//  pricing, or own Pro entitlement — StationsView continues to orchestrate all search/network
//  behavior exactly as before; this store is a passive, injectable record of the last
//  successful current-location search.
//
//  In-memory only — deliberately not persisted across app relaunch (no SwiftData, no
//  CloudKit, no UserDefaults, no schema migration). Injected once at the App level via
//  .environment(...), exactly like RecentLiveStationCache, so it survives StationsView being
//  recreated and survives ordinary tab switching within one app session, but does not survive
//  a full relaunch — that's an explicitly out-of-scope goal for this foundation.
//

import CoreLocation
import Foundation

/// One completed current-location live-station search, with enough metadata to later decide
/// whether it's still usable for a new appearance of Stations. Deliberately does NOT include
/// price/community data — those have their own, separate refresh lifecycle in StationsView
/// (see refreshCommunityPricePreviews()) and are intentionally left out of this cache to avoid
/// a second, competing source of truth for community pricing.
struct StationsSearchSnapshot: Equatable {
    let stations: [LiveFuelStation]
    let center: StationCoordinate
    let radiusMiles: Double
    let fetchedAt: Date
}

/// Pure, directly-testable freshness/compatibility rules for StationsSearchSnapshot — kept
/// independent of the @Observable store below, mirroring
/// CommunityPriceEligibility/AppExperienceNavigation's existing separation of pure decision
/// logic from the stateful/SwiftUI-facing types that consume it.
enum StationsRecentSearchCompatibility: Equatable {
    /// Usable immediately, no refresh strictly required yet (still inside the automatic
    /// refresh cooldown window).
    case fresh(StationsSearchSnapshot)
    /// Usable immediately, but old enough that a quiet background refresh is worthwhile.
    case staleButUsable(StationsSearchSnapshot)
    /// Wrong radius, wrong location, or too old even to show as stale-but-usable — must not
    /// be hydrated as if it were a valid nearby-search result.
    case incompatible
    /// No snapshot has ever been recorded this session.
    case none
}

/// Stations-only location-freshness policy — separate from, and never applied to, Pump
/// Mode's own staleness rules (PumpStationContextResolver's 120s/50m gates, which remain
/// completely untouched). Answers a much less strict question than that resolver does: is an
/// existing foreground fix recent enough that Stations (or the app-foreground prewarm that
/// feeds it) can skip requesting a brand new one right now?
enum StationsLocationFreshness {
    /// Deliberately shorter than StationsRecentSearchStore's freshness/staleness windows
    /// below, so "reuse this coordinate" can never itself be the reason stale-looking nearby
    /// results get shown — it only ever skips a redundant GPS wait, never widens what counts
    /// as an acceptable station-result snapshot.
    static let maximumCoordinateAgeForReuse: TimeInterval = 3 * 60

    static func isCoordinateRecentEnough(fixTimestamp: Date?, now: Date) -> Bool {
        guard let fixTimestamp else { return false }
        return now.timeIntervalSince(fixTimestamp) <= maximumCoordinateAgeForReuse
    }
}

@MainActor
@Observable
final class StationsRecentSearchStore {
    /// Mirrors StationsView's own (pre-existing) automatic-search cooldown window — kept as
    /// the single, named source of truth Stations already defined
    /// (StationsView.autoNearbySearchCooldown); a StationsSearchSnapshot at or under this age
    /// is considered "fresh" (no refresh strictly needed yet), matching the existing product
    /// behavior of not re-fetching within 5 minutes of the last current-location search.
    static let freshnessWindow: TimeInterval = 5 * 60

    /// Upper bound past which a same-session snapshot is no longer shown at all, even as
    /// "stale-but-usable." Deliberately NOT borrowed from RecentLiveStationCache's 6-hour Pump
    /// Mode lifetime — that value answers "did the user see this station at all on this trip,"
    /// a much more permissive question than "is this still a reasonable nearby-stations
    /// result to show as if current." Chosen as 6x freshnessWindow: long enough to survive a
    /// normal few-minutes app-background/multitasking gap without a visible regression to the
    /// pre-cache "wait for a fresh search" experience, short enough that showing this data as
    /// an immediate render is very unlikely to be meaningfully wrong.
    static let staleButUsableCeiling: TimeInterval = 30 * 60

    private(set) var snapshot: StationsSearchSnapshot?

    /// Timestamp of the last current-location search ATTEMPT (stamped at request start, not
    /// on success) — mirrors StationsView's previous view-local `lastNearbySearchDate` exactly,
    /// just relocated here so it survives Stations view-state churn instead of resetting on
    /// every StationsView recreation. Stamped regardless of success/failure so a failing/
    /// offline search still suppresses automatic re-trigger spam, exactly as before.
    private(set) var lastCurrentLocationSearchAt: Date?

    /// Records that a current-location search attempt began — see doc comment above for why
    /// this is attempt-based, not success-based. Never called for typed-location searches —
    /// StationsView guards this at the call site, same as it always guarded
    /// `lastNearbySearchDate`.
    func recordCurrentLocationSearchAttempt(at date: Date) {
        lastCurrentLocationSearchAt = date
    }

    /// Records a SUCCESSFUL current-location search's full result set for later hydration.
    /// Deliberately accepts (and correctly caches) an empty `stations` array — a successful
    /// search that legitimately found nothing nearby is a valid, cacheable snapshot distinct
    /// from a failed search (which never calls this method at all, leaving any previous good
    /// snapshot untouched — see StationsView.fetchLiveStations's catch branch).
    func recordCurrentLocationSearchResult(
        stations: [LiveFuelStation],
        center: StationCoordinate,
        radiusMiles: Double,
        fetchedAt: Date
    ) {
        snapshot = StationsSearchSnapshot(
            stations: stations,
            center: center,
            radiusMiles: radiusMiles,
            fetchedAt: fetchedAt
        )
    }

    /// Whether the current snapshot (if any) may be hydrated immediately for a new Stations
    /// appearance. Conservative by design:
    /// - `radiusMiles` must match the snapshot's radius EXACTLY. No subset/superset reuse
    ///   across radii is implemented here — a wrong-radius result set must never be presented
    ///   as if it were the requested one.
    /// - `coordinate` is the user's current best-known location, if any. When `nil` (location
    ///   unavailable), a recent same-session snapshot may still be shown as stale-but-usable —
    ///   it is still gated by `staleButUsableCeiling` and reported as `.staleButUsable`, never
    ///   `.fresh`, since without a current coordinate there is no way to confirm the user
    ///   hasn't materially moved.
    func compatibleSnapshot(
        near coordinate: StationCoordinate?,
        radiusMiles: Double,
        now: Date
    ) -> StationsRecentSearchCompatibility {
        guard let snapshot else { return .none }
        guard snapshot.radiusMiles == radiusMiles else { return .incompatible }

        let age = now.timeIntervalSince(snapshot.fetchedAt)
        guard age <= Self.staleButUsableCeiling else { return .incompatible }

        guard let coordinate else {
            // No current coordinate to confirm the user hasn't moved (location unavailable,
            // denied, or not yet resolved) -- NEVER classify as `.fresh` here, regardless of
            // age, since that would present this snapshot as fully current with zero location
            // confirmation. Still gated by `staleButUsableCeiling` above.
            return .staleButUsable(snapshot)
        }

        let distance = Self.distanceMeters(snapshot.center, coordinate)
        guard distance <= Self.compatibilityRadiusMeters(forSearchRadiusMiles: radiusMiles) else {
            return .incompatible
        }

        return age <= Self.freshnessWindow ? .fresh(snapshot) : .staleButUsable(snapshot)
    }

    private static func distanceMeters(_ lhs: StationCoordinate, _ rhs: StationCoordinate) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }

    /// How far the user may have moved from a snapshot's search center before it's no longer
    /// treated as describing "here" — scaled to the search radius so a small 10 mi search
    /// (where a mile of drift meaningfully changes what's nearby) is much more sensitive than
    /// a 100 mi search (where the same mile is noise), but capped so even a very large search
    /// radius doesn't let genuinely substantial travel (a new city) pass as "still compatible."
    /// A simple, explicit, radius-scaled-and-capped rule: 15% of the search radius, floored at
    /// 500m (so ordinary GPS/geocoding jitter on a small-radius search never falsely
    /// invalidates an otherwise-good cache hit) and capped at 8km (so even a 100 mi search
    /// radius doesn't treat a real, multi-mile relocation as "no movement at all").
    private static func compatibilityRadiusMeters(forSearchRadiusMiles radiusMiles: Double) -> CLLocationDistance {
        let metersPerMile = 1609.34
        let scaled = radiusMiles * metersPerMile * 0.15
        return min(max(scaled, 500), 8_000)
    }
}

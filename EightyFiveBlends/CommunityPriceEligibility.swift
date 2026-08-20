//
//  CommunityPriceEligibility.swift
//  EightyFiveBlends
//
//  Pure decision logic behind Community E85 Price Reporting eligibility and station-key
//  resolution. Kept independent of SwiftUI/SwiftData/StationsView — mirroring
//  AppExperienceNavigation/WhatsNewPresentation/PumpStationContextResolver's separation of pure
//  rules from the views that call them — so the actual rule StationsView depends on is directly
//  unit-testable. See EightyFiveBlendsTests/CommunityPriceEligibilityTests.swift.
//
//  Community price reporting was previously gated on how a station was DISCOVERED (a station
//  found via Nearby Search could "Save & Report"; the identical physical station reached
//  through Saved Stations could only "Save Locally") rather than on whether the station carries
//  enough information to be safely identified/resolved server-side. That was an unintentional
//  implementation gap — see the removed TODO this file replaces in StationsView.swift — not a
//  deliberate product rule: the exact same name/address/city/state/zip data already drives the
//  community price DISPLAY that saved stations show ("Community E85 · Reported X days ago"), so
//  a station that can already show a community price should generally also be able to report
//  one. This file is that shared "does this station carry enough identifying information" logic
//  — but the DISPLAY rule (CommunityStationKey.normalizedKey, "any single field present") and
//  the REPORTING rule (CommunityPriceEligibility.canReport, "genuine location data required")
//  are deliberately NOT identical: a mismatch on read is a minor UI inaccuracy, a mismatch on
//  write pollutes a shared community record with an ambiguous or misattributed station. See
//  CommunityPriceEligibility.canReport's own doc comment for why a bare name (e.g. "Chevron",
//  "Unknown Station") is enough for the former but not the latter.
//
//  THIRD PASS (Community Station Identity Foundation — Price Alerts prerequisite): the Station
//  Price Alerts architecture audit found that CommunityStationKey.normalizedKey, while itself a
//  single correct implementation, had been independently REIMPLEMENTED a second time in
//  FuelLogView with different blank-field handling (fixed-position join here vs. filter-then-join
//  there) — the same station data could resolve to two different `community_stations` rows
//  depending only on which screen reported it. Separately, normalizedKey never took coordinates
//  at all, so two distinct, real, coordinate-only stations sharing a name and lacking address
//  data could collide on the identical key. `canonicalKey` below fixes both: it is now the ONE
//  identity function every Community Pricing read AND write call site uses (FuelLogView's
//  reimplementation is removed, not merely left in parallel — see StationsView.swift and
//  FuelLogView.swift), and it folds a rounded coordinate into the key precisely when — and only
//  when — the address alone isn't enough to disambiguate, mirroring canReport's own
//  address-vs-coordinate reasoning via the shared `hasSufficientAddress` helper so the two rules
//  can never silently drift apart again. `normalizedKey` itself is untouched and still backs
//  `canonicalKey`'s address-sufficient and final-fallback branches unchanged, so every
//  already-written, properly-addressed `community_stations` row remains discoverable under the
//  identical key it already has. See EightyFiveBlendsTests/CommunityPriceEligibilityTests.swift.
//

import Foundation

/// Builds the normalized station key `CommunityPriceService` uses to resolve/upsert a
/// `community_stations` row (`normalized_key` in Supabase) and that StationsView already uses
/// to look up a station's existing community price for display. Extracted here, unchanged, so
/// it has exactly one implementation shared by both call sites and is independently testable.
enum CommunityStationKey {
    /// Case/diacritic-folded, whitespace-trimmed form of a single field, used to build a stable
    /// key regardless of capitalization or accent differences between two reports of the same
    /// physical station.
    static func normalizedText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Whether street/city/state/zip together carry enough locality information to safely pin
    /// one physical station on their own. This is the exact rule `CommunityPriceEligibility.
    /// canReport` used to compute inline (as a private `hasSufficientLocality` local) and that
    /// `canonicalKey` below now also needs — extracted here, once, so reporting eligibility and
    /// identity-key construction share a single definition of "enough address" and can never
    /// silently diverge into two different answers for the same station data. A street address
    /// alone (no zip, no city+state pair) does NOT count — many different cities/states share
    /// street names like "Main St" — and neither does a zip or a city/state pair with no street.
    static func hasSufficientAddress(streetAddress: String, city: String, state: String, zip: String) -> Bool {
        let hasStreetAddress = normalizedText(streetAddress).isEmpty == false
        let hasZip = normalizedText(zip).isEmpty == false
        let hasCityAndState = normalizedText(city).isEmpty == false && normalizedText(state).isEmpty == false
        return hasStreetAddress && (hasZip || hasCityAndState)
    }

    /// The station's identity key, or `nil` if every field is blank (nothing to key on at all).
    /// Deliberately requires only that *some* identifying field is present — not that every
    /// field is — since a station may legitimately be missing an address or coordinates while
    /// still having a usable name, exactly as StationsView already tolerates for display.
    ///
    /// Kept exactly as originally shipped — unchanged by the third-pass work above — because
    /// `canonicalKey` below reuses this, unmodified, for both of its non-coordinate branches;
    /// changing this function's own output would silently reshuffle every existing
    /// `community_stations` row's key. Prefer `canonicalKey` at every real call site; this is now
    /// an internal building block, still exposed because EightyFiveBlendsTests exercises it
    /// directly.
    static func normalizedKey(
        name: String,
        streetAddress: String,
        city: String,
        state: String,
        zip: String
    ) -> String? {
        let components = [name, streetAddress, city, state, zip].map(normalizedText)
        guard components.contains(where: { $0.isEmpty == false }) else {
            return nil
        }
        return components.joined(separator: "|")
    }

    /// Coordinate precision used only by `canonicalKey`'s coordinate branch below (address data
    /// is insufficient AND a real coordinate pair is available). ~0.001° ≈ 111 meters (≈365 ft)
    /// at the equator — a deliberate middle ground, not an arbitrary default:
    ///   - Coarse enough to absorb everyday GPS/geocoding disagreement between two readings of
    ///     the SAME pump. Consumer GPS accuracy is commonly 5-10m and routinely worse under a
    ///     pump-island overhang; AFDC's own geocoded pin for a station and a live on-device fix
    ///     taken while fueling can easily disagree by tens of meters without being different
    ///     stations at all.
    ///   - Fine enough that two genuinely distinct stations — even same-brand competitors
    ///     directly across a street from each other — will almost always round to different
    ///     buckets: a typical arterial road plus curb cuts puts facing competitors on the order
    ///     of 40-150m apart, center to center, safely outside one 111m cell in the common case.
    /// This is a documented tradeoff, not a guarantee — two stations sharing one large
    /// travel-plaza lot could still collide at this precision. That residual risk is accepted
    /// here rather than "solved": going coarser would worsen the far more common
    /// same-station-fragments-on-GPS-jitter problem this fix exists to prevent, and eliminating
    /// the risk entirely needs a real per-station identifier (see the AFDC/federal station-ID
    /// discussion in the Community Station Identity Foundation final report), which is out of
    /// scope here.
    private static let coordinateKeyScale: Double = 1000 // 3 decimal places ≈ 111m

    /// Deterministic, locale-independent text for one rounded coordinate value. Formats the
    /// SCALED INTEGER rather than a rounded `Double`, so this never depends on `Double`'s
    /// string-formatting behavior (shortest-round-trip representation is safe here in practice,
    /// but this sidesteps the question entirely) and never depends on locale — `Int`
    /// interpolation has no decimal separator to vary between devices.
    private static func coordinateKeyComponent(_ value: Double) -> String {
        String(Int((value * coordinateKeyScale).rounded()))
    }

    /// THE canonical station-identity key — every Community Pricing read AND write call site
    /// (StationsView and FuelLogView alike) must funnel through this one function. Mirrors
    /// `CommunityPriceEligibility.canReport`'s own address-vs-coordinate reasoning via
    /// `hasSufficientAddress` so eligibility and identity can never disagree about which signal
    /// actually disambiguates a station:
    ///
    /// 1. A sufficient address (see `hasSufficientAddress`) is primary and, when present, is the
    ///    ENTIRE key — coordinates are ignored even if also present, so a well-addressed
    ///    station's key never shifts just because two reports carried slightly different GPS
    ///    fixes. This reproduces `normalizedKey`'s existing address-based output exactly, so
    ///    every already-written `community_stations` row keyed on a real address stays
    ///    discoverable under the identical key, unchanged.
    /// 2. Otherwise, a real (both-present) coordinate pair becomes the disambiguating signal
    ///    instead of the (mostly blank) address fields — `name` plus a rounded coordinate pair,
    ///    address fields dropped entirely rather than mixed in, since an insufficient address's
    ///    text is exactly what this branch exists to route around; keeping it would risk
    ///    reintroducing the same inconsistent-blank-field fragmentation this fix removes. This is
    ///    what stops two same-named, address-less stations from colliding regardless of how far
    ///    apart they actually are.
    /// 3. Otherwise (no sufficient address, no real coordinates), falls back to `normalizedKey`'s
    ///    original, more permissive "any single field present" behavior, unchanged.
    ///    `CommunityPriceEligibility.canReport` already refuses to let this branch's degenerate
    ///    identity back a NEW write (see its own doc comment), so this branch only ever serves
    ///    the DISPLAY/read path, exactly as before: a legacy bare-name station can still resolve
    ///    whatever community price was already written for it, even though it can no longer
    ///    report a new one.
    static func canonicalKey(
        name: String,
        streetAddress: String,
        city: String,
        state: String,
        zip: String,
        latitude: Double?,
        longitude: Double?
    ) -> String? {
        if hasSufficientAddress(streetAddress: streetAddress, city: city, state: state, zip: zip) {
            return normalizedKey(name: name, streetAddress: streetAddress, city: city, state: state, zip: zip)
        }

        if let latitude, let longitude {
            let coordinateComponent = "\(coordinateKeyComponent(latitude)),\(coordinateKeyComponent(longitude))"
            return [normalizedText(name), coordinateComponent].joined(separator: "|")
        }

        return normalizedKey(name: name, streetAddress: streetAddress, city: city, state: state, zip: zip)
    }
}

/// Whether a station has enough identifying information to safely report an E85 price to the
/// community feed.
enum CommunityPriceEligibility {
    /// Navigation history (Nearby Search vs. Saved Stations vs. anywhere else a station surfaces)
    /// is deliberately NOT a parameter here — it was the previous, incorrect gating condition and
    /// must never factor into this rule again. Eligibility is purely a function of the station's
    /// own data.
    ///
    /// This is intentionally STRICTER than `CommunityStationKey.normalizedKey`'s "any single
    /// field present" rule: a station's NAME ALONE is never sufficient here, even though a
    /// name-only station can still build a normalized key and is still perfectly fine to use for
    /// DISPLAY (looking up whether a sparse local station happens to match an existing community
    /// price — a wrong/missed match there is just a minor UI inaccuracy). Reporting is a WRITE
    /// that can create or attach to a shared `community_stations` row every user of the app may
    /// see, so it requires genuine location-bearing information — not just a name, however
    /// specific that name looks.
    ///
    /// A single location field alone is ALSO not sufficient — city, state, or zip in isolation
    /// (e.g. city == "Phoenix", state == "AZ", or a bare zip code) narrows a search area, not a
    /// single physical pump, and neither does a street address with no locality context at all
    /// (many different cities/states share street names like "Main St"). The rule instead
    /// requires either:
    /// - a real (both-present) coordinate pair, which pins one physical point directly, or
    /// - a street address PLUS enough locality context to disambiguate it: a zip code, or a
    ///   city+state pair together (city or state alone doesn't count).
    ///
    /// Two real, already-shipped station-creation paths make this distinction necessary, not
    /// theoretical:
    /// - `LiveFuelStation.init(from:)` (NRELStationService.swift) falls back to the literal
    ///   string `"Unknown Station"` whenever NREL supplies no name for a result; NREL records can
    ///   also lack a usable street address/city/state/zip, and a missing coordinate is
    ///   represented as `0`/`0`, which `StationPriceUpdateContext.live(_:)` already normalizes to
    ///   `nil` before eligibility is ever checked.
    /// - `FuelLogStore.updateStationIfNeeded` (FuelLogStore.swift) creates a brand-new
    ///   `FuelStation` from nothing but a fuel-log entry's typed station name and price whenever
    ///   that name doesn't already match a saved station — address/city/state/zipCode all take
    ///   `FuelStation`'s `""` default, latitude/longitude stay `nil`. That station is reachable
    ///   from Update Price exactly like any other saved station.
    /// A genuine Nearby-search result and a properly-addressed manual station both carry their
    /// street address, city, state, zip, and coordinates together as one unit (see
    /// `saveLiveStation`/`upsertLocalStation` in StationsView.swift, which copy the full source
    /// record rather than a subset), so this stricter rule does not regress legitimate reporting
    /// — only the genuinely ambiguous partial-identity cases above lose eligibility.
    static func canReport(
        name: String,
        streetAddress: String,
        city: String,
        state: String,
        zip: String,
        latitude: Double?,
        longitude: Double?
    ) -> Bool {
        let hasValidCoordinate = latitude != nil && longitude != nil

        // Third pass: this was previously four inline local lets duplicating exactly what
        // CommunityStationKey.canonicalKey now also needs to decide whether to use an address or
        // a coordinate for identity. Extracted to CommunityStationKey.hasSufficientAddress so
        // eligibility and identity-key construction share one definition and can't drift apart —
        // behavior here is unchanged; this is a pure refactor, not a new rule.
        let hasSufficientAddress = CommunityStationKey.hasSufficientAddress(
            streetAddress: streetAddress, city: city, state: state, zip: zip
        )

        return hasValidCoordinate || hasSufficientAddress
    }
}

import Foundation
import os

// Value-only boundary: the extension never opens SwiftData or CloudKit. Its only network use is
// the bounded NLR station search in NearbyE85WidgetRefreshCoordinator, run by the manual refresh
// AppIntent and by the throttled, timeline-driven automatic refresh (NearbyE85AutomaticRefresh).
nonisolated enum NearbyE85Configuration {
    static let kind = "NearbyE85"
    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "NearbyE85AppGroup") as? String
    }
    static var urlScheme: String {
        Bundle.main.object(forInfoDictionaryKey: "NearbyE85URLScheme") as? String ?? "e85blends"
    }
}

nonisolated struct NearbyE85Price: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case saved, community }
    let dollarsPerGallon: Double
    let reportedAt: Date?
    let source: Source

    static func validated(_ amount: Double?, reportedAt: Date?, source: Source, now: Date) -> Self? {
        guard let amount, StationDataValidation.isValidPrice(amount) else { return nil }
        return Self(dollarsPerGallon: amount,
                    reportedAt: reportedAt.flatMap { StationDataValidation.isValidTimestamp($0, asOf: now) ? $0 : nil },
                    source: source)
    }

    func status(at date: Date) -> String {
        guard let reportedAt else { return "Age unknown" }
        let days = StationDataValidation.daysSince(reportedAt, asOf: date)
        switch StationDataValidation.priceFreshnessTier(hasPrice: true, daysSinceUpdate: days) {
        case .stale: return "Stale · \(days)d ago"
        case .checkPrice: return "Check price · \(days)d ago"
        case .fresh: return days == 0 ? "Reported today" : "Reported \(days)d ago"
        case .noPrice: return "No price reported"
        }
    }

    /// 85Blends 2.4.1 Phase 2F — whether this price is fresh enough to show as a standalone map
    /// badge (no station-list context, no freshness caption next to it — the map badge is just
    /// a bare dollar amount, so an 8-day-old "check price" or 78-day-old "stale" figure shown
    /// there with no age indicator would read as more current than it is). The station list and
    /// Small widget are untouched by this — they keep showing every tier via `status(at:)`
    /// above, including stale ones, always paired with that caption.
    ///
    /// Reuses `StationDataValidation.priceFreshnessTier` — the exact same 7/14-day thresholds
    /// and `daysSince` calendar-day math `status(at:)` already uses — so the map badge can never
    /// disagree with what the station list/Small widget would say about the same price.
    ///
    /// A missing `reportedAt` can't be confirmed fresh, so it's treated as not-fresh here (never
    /// defaults to showing the badge on missing evidence) — the same "unknown must never read as
    /// the most favorable state" rule this codebase applies elsewhere (e.g. AdManager's pending-
    /// entitlement case, NearbyE85WidgetAccessCopy's `.unknown` neutrality).
    func isFreshEnoughForMapBadge(at date: Date) -> Bool {
        guard let reportedAt else { return false }
        let days = StationDataValidation.daysSince(reportedAt, asOf: date)
        return StationDataValidation.priceFreshnessTier(hasPrice: true, daysSinceUpdate: days) == .fresh
    }
}

/// The latest qualifying RECENT COMMUNITY REPORT of a station's ethanol percentage — not a
/// vetted, verified, or consensus figure, and not a claim about the station's actual pump
/// composition. This is exactly what CommunityPriceService.fetchLatestEthanolReport(...) returns
/// today: the single most recently submitted community report for the station (Supabase query
/// orders by `reported_at.desc,created_at.desc` with `limit=1` — no aggregation across multiple
/// reports). `validated(...)` is the only way to construct one, and only does so once that one
/// report also clears three additional, independent bars before the widget will show it: a
/// physically valid percentage, a timestamp that passes StationDataValidation's own timestamp
/// validation (so it isn't meaningfully in the future — small clock-skew tolerance included, see
/// StationDataValidation.isValidTimestamp), and current/recent — never stale — per the same
/// 14-day calendar-day threshold the main app already uses before showing a community ethanol
/// reading (see StationDataValidation.isStale/daysSince, and StationsView.swift's
/// CommunityEthanolPreview/communityPriceIsStale). Widget UI never has to re-check any of this
/// itself — only `!= nil`.
nonisolated struct NearbyE85Ethanol: Codable, Equatable, Sendable {
    let percentage: Double
    let reportedAt: Date

    static func validated(percentage: Double?, reportedAt: Date?, now: Date, maxAgeDays: Int = 14) -> Self? {
        guard let percentage, percentage.isFinite, percentage >= 0, percentage <= 100,
              // StationDataValidation.expectedE85EthanolRange is the single source of truth this
              // shares with CommunityEthanolValidation.requiresConfirmation's own "expected E85
              // range" band in the main app (StationDataValidation.swift is dual-compiled into
              // both the app and this widget extension target, so this is a genuine shared
              // reference, not a duplicated literal). A percentage outside that band is a
              // legitimate, unrejected report in the main app, but only ever shown there behind an
              // explicit user-facing confirmation/disclaimer — room the widget doesn't have.
              // Rather than inventing separate widget warning UI, an out-of-range report is simply
              // not eligible for the widget at all for this release.
              StationDataValidation.expectedE85EthanolRange.contains(percentage),
              let reportedAt, StationDataValidation.isValidTimestamp(reportedAt, asOf: now),
              !StationDataValidation.isStale(daysSince: StationDataValidation.daysSince(reportedAt, asOf: now),
                                             thresholdDays: maxAgeDays)
        else { return nil }
        return Self(percentage: percentage, reportedAt: reportedAt)
    }

    /// "E78", "E72.5" — mirrors StationsView.swift's `e85EthanolLabelText` formatting exactly
    /// (one decimal place, no trailing ".0" for a whole-number reading) so the same percentage
    /// reads identically between the main app and the widget. Duplicated rather than shared:
    /// that helper is private to StationsView.swift, which isn't part of the widget extension's
    /// compilation graph — see this file's own "value-only boundary" header.
    var labelText: String {
        let normalized = (percentage * 10).rounded() / 10
        if normalized == normalized.rounded() {
            return "E\(Int(normalized))"
        }
        return "E\(String(format: "%.1f", normalized))"
    }

    /// "Reported E78" — the Large widget's badge text. Always carries the "Reported" prefix on
    /// screen, not just in VoiceOver: a bare percentage in an otherwise-authoritative-looking
    /// capsule reads too easily as a claim about the station's actual pump composition, when this
    /// is only ever a single most-recent community report (see this struct's own header). Kept
    /// here, not inlined at the call site, so the exact on-screen wording rule is directly
    /// testable independent of rendering.
    var badgeText: String { "Reported \(labelText)" }

    /// "Today", "1d ago", "3d ago" — the compact on-screen freshness wording, mirroring
    /// NearbyE85Price.status(at:)'s own style.
    func agoText(at date: Date) -> String {
        let days = StationDataValidation.daysSince(reportedAt, asOf: date)
        return days == 0 ? "Today" : "\(days)d ago"
    }

    /// "updated today", "updated 1 day ago" — the fuller VoiceOver phrasing, distinct from
    /// `agoText`'s compact on-screen abbreviation.
    func accessibilityAgeText(at date: Date) -> String {
        let days = StationDataValidation.daysSince(reportedAt, asOf: date)
        if days == 0 { return "updated today" }
        return "updated \(days) day\(days == 1 ? "" : "s") ago"
    }
}

nonisolated struct NearbyE85Station: Codable, Equatable, Identifiable, Sendable {
    let id: String // Existing canonical community station key, never LiveFuelStation's random UUID.
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let distanceMiles: Double
    var price: NearbyE85Price?
    // Optional, defaulted — matches the userLatitude/userLongitude precedent below: every
    // existing call site (production and tests) keeps compiling unchanged, and an old cached
    // snapshot with no "ethanol" key still decodes (Codable synthesizes decodeIfPresent for an
    // Optional stored property regardless of the default value).
    var ethanol: NearbyE85Ethanol? = nil
}

nonisolated struct NearbyE85Snapshot: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case ready, noStations, permissionRequired }
    static let schemaVersion = 1
    static let staleAfter: TimeInterval = 60 * 60
    static let expiresAfter: TimeInterval = 24 * 60 * 60
    let version: Int
    let state: State
    let stations: [NearbyE85Station]
    let radiusMiles: Double
    let updatedAt: Date // Successful station search time; reading/enriching the cache never advances it.
    let locationAt: Date?
    // Only present when the search fix that produced `stations` is known; the medium widget's
    // map needs the user's own point, not just distances relative to it.
    var userLatitude: Double? = nil
    var userLongitude: Double? = nil
    // 85Blends 2.4.1 — when the station catalogue actually read NLR for this answer (earlier than `updatedAt`
    // for a proxy cache hit). Provenance only: freshness, expiry and labels stay on the local `updatedAt` and
    // `locationAt`. Optional, so snapshots written before this field decode unchanged (nil).
    var sourceFetchedAt: Date? = nil

    static func make(stations: [NearbyE85Station], radiusMiles: Double, updatedAt: Date, locationAt: Date,
                      userLatitude: Double? = nil, userLongitude: Double? = nil, sourceFetchedAt: Date? = nil) -> Self {
        var seen = Set<String>()
        let nearest = stations.filter {
            !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            StationDataValidation.isValidCoordinate(latitude: $0.latitude, longitude: $0.longitude) &&
            $0.distanceMiles.isFinite && $0.distanceMiles >= 0 && $0.distanceMiles <= radiusMiles
        }.sorted {
            $0.distanceMiles == $1.distanceMiles ? $0.id < $1.id : $0.distanceMiles < $1.distanceMiles
        }.filter { seen.insert($0.id).inserted }.prefix(3)
        let validUser = userLatitude.flatMap { lat in userLongitude.map { lon in (lat, lon) } }
            .flatMap { StationDataValidation.isValidCoordinate(latitude: $0.0, longitude: $0.1) ? $0 : nil }
        return Self(version: schemaVersion, state: nearest.isEmpty ? .noStations : .ready,
                    stations: Array(nearest), radiusMiles: radiusMiles, updatedAt: updatedAt, locationAt: locationAt,
                    userLatitude: validUser?.0, userLongitude: validUser?.1,
                    sourceFetchedAt: sourceFetchedAt.flatMap { $0 <= updatedAt ? $0 : nil })
    }

    static func permissionRequired(at date: Date) -> Self {
        Self(version: schemaVersion, state: .permissionRequired, stations: [], radiusMiles: 25, updatedAt: date, locationAt: nil)
    }

    func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(locationAt ?? updatedAt) >= Self.staleAfter || date.timeIntervalSince(updatedAt) >= Self.staleAfter
    }

    func isValid(at date: Date) -> Bool {
        guard version == Self.schemaVersion,
              StationDataValidation.isValidTimestamp(updatedAt, asOf: date),
              // Optional catalogue provenance: when present it must be a valid time no later than the search itself,
              // so a corrupt/future value can never win a same-query replacement decision. Missing (legacy) is fine.
              sourceFetchedAt.map({ StationDataValidation.isValidTimestamp($0, asOf: date) && $0 <= updatedAt }) ?? true,
              radiusMiles.isFinite, radiusMiles > 0, radiusMiles <= 100,
              stations.count <= 3,
              Set(stations.map(\.id)).count == stations.count else { return false }
        if state == .permissionRequired {
            return stations.isEmpty && locationAt == nil && userLatitude == nil && userLongitude == nil
        }
        guard let locationAt, StationDataValidation.isValidTimestamp(locationAt, asOf: date),
              date.timeIntervalSince(locationAt) < Self.expiresAfter,
              date.timeIntervalSince(updatedAt) < Self.expiresAfter,
              (state == .ready) == !stations.isEmpty else { return false }
        switch (userLatitude, userLongitude) {
        case (nil, nil): break
        case let (lat?, lon?): guard StationDataValidation.isValidCoordinate(latitude: lat, longitude: lon) else { return false }
        default: return false
        }
        return stations.allSatisfy { station in
            !station.id.isEmpty && station.id.count <= 1024 && !station.name.isEmpty && station.name.count <= 256 &&
            station.address.count <= 1024 &&
            StationDataValidation.isValidCoordinate(latitude: station.latitude, longitude: station.longitude) &&
            station.distanceMiles.isFinite && station.distanceMiles >= 0 && station.distanceMiles <= radiusMiles &&
            (station.price.map { price in
                StationDataValidation.isValidPrice(price.dollarsPerGallon) &&
                (price.reportedAt.map { StationDataValidation.isValidTimestamp($0, asOf: date) } ?? true)
            } ?? true) &&
            // Deliberately just the hard physical bound (0...100), not NearbyE85Ethanol.
            // validated(...)'s narrower StationDataValidation.expectedE85EthanolRange
            // display-eligibility band: this is a structural "is the stored data well-formed"
            // check, not today's display policy, exactly like the price check above never
            // re-derives saved-vs-community sourcing either. Failing isValid(at:) discards the
            // WHOLE snapshot (see NearbyE85Cache.read), so conflating the two would risk hiding
            // an otherwise-fine station over one out-of-range ethanol field — a future change to
            // the expected-range policy should never need to touch this.
            (station.ethanol.map { ethanol in
                ethanol.percentage.isFinite && ethanol.percentage >= 0 && ethanol.percentage <= 100 &&
                StationDataValidation.isValidTimestamp(ethanol.reportedAt, asOf: date)
            } ?? true)
        }
    }

    /// The user's own point for the medium widget's map, when the search that produced
    /// `stations` recorded one.
    var userCoordinate: (latitude: Double, longitude: Double)? {
        guard let userLatitude, let userLongitude else { return nil }
        return (userLatitude, userLongitude)
    }
}

nonisolated struct NearbyE85Cache {
    let fileURL: URL?
    init(fileURL: URL?) { self.fileURL = fileURL }
    init() {
        fileURL = NearbyE85Configuration.appGroup.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }?.appendingPathComponent("NearbyE85/snapshot-v1.json")
    }

    // 85Blends 2.4.1 performance audit (Phase 2A) — signposts/logs below are purely
    // observational (see NearbyE85Diagnostics's own no-PII rule); none of them change this
    // function's control flow, return value, or the bytes it reads/writes.
    //
    // Reads are deliberately NOT file-coordinated: atomic replacement already guarantees a
    // reader sees one whole snapshot, and leaving reads uncoordinated means `update` can re-read
    // inside its own coordinated write without a nested same-path coordination (deadlock risk).
    func read(now: Date = .now) -> NearbyE85Snapshot? {
        let signpostState = NearbyE85Diagnostics.begin("Cache.read")
        defer { NearbyE85Diagnostics.end("Cache.read", signpostState) }
        guard let fileURL, let value = Self.decode(at: fileURL, now: now) else {
            NearbyE85Diagnostics.logger.debug("Cache.read: no valid snapshot")
            return nil
        }
        return value
    }

    private static func decode(at url: URL, now: Date) -> NearbyE85Snapshot? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(NearbyE85Snapshot.self, from: data),
              value.isValid(at: now) else { return nil }
        NearbyE85Diagnostics.logger.debug("Cache.read: ok bytes=\(data.count, privacy: .public)")
        return value
    }

    enum UpdateResult: Equatable { case written, unchanged, rejected }

    // Writers: the app (NearbyE85Publisher) and the widget extension's own refresh
    // (NearbyE85WidgetRefreshCoordinator). EVERY write goes through `update`, which holds one
    // cross-process NSFileCoordinator write lock on the snapshot file across read → decide →
    // replace, so a writer's precondition is always evaluated against the bytes it is about to
    // replace — no lost updates between processes. (Atomic replacement alone only prevents torn
    // bytes, not lost updates.) No private-container fallback: missing entitlements must never
    // look like successful sharing.
    @discardableResult
    func write(_ snapshot: NearbyE85Snapshot, now: Date = .now) throws -> Bool {
        try update(now: now) { _ in snapshot } == .written
    }

    /// Coordinated compare-and-write. `make` receives the latest valid snapshot read INSIDE the
    /// coordinated section and returns the snapshot to store, or nil to reject the write (the
    /// file is left untouched). Unchanged content is never rewritten.
    func update(now: Date = .now, _ make: (NearbyE85Snapshot?) throws -> NearbyE85Snapshot?) throws -> UpdateResult {
        let signpostState = NearbyE85Diagnostics.begin("Cache.write")
        defer { NearbyE85Diagnostics.end("Cache.write", signpostState) }
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        var directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)

        var coordinationError: NSError?
        var result: Result<UpdateResult, Error> = .success(.rejected)
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: fileURL, options: .forReplacing,
                                                         error: &coordinationError) { url in
            result = Result {
                let latest = Self.decode(at: url, now: now)
                guard let snapshot = try make(latest) else {
                    NearbyE85Diagnostics.logger.debug("Cache.write: precondition rejected")
                    return .rejected
                }
                guard snapshot.isValid(at: now) else { throw CocoaError(.fileWriteInvalidFileName) }
                if latest == snapshot {
                    NearbyE85Diagnostics.logger.debug("Cache.write: unchanged, skipped")
                    return .unchanged
                }
                let data = try JSONEncoder().encode(snapshot)
                guard data.count <= 65_536 else { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                NearbyE85Diagnostics.logger.debug("Cache.write: ok bytes=\(data.count, privacy: .public)")
                return .written
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}

/// Two distinct, non-overlapping widget-originated intents — deliberately not a single
/// "station" route with ambiguous meaning: `.stations` always just opens the Stations tab,
/// `.directions` always means "skip straight to turn-by-turn," never a detail screen. The
/// station identifier travels in a query item (not a path segment) so it round-trips exactly
/// even when it contains characters like `/`, `?`, `#`, or `&` — canonical community station
/// keys aren't guaranteed to avoid those.
nonisolated enum NearbyE85DeepLink {
    enum Destination: Equatable { case stations, directions(stationID: String) }

    static func stationsURL(scheme: String = NearbyE85Configuration.urlScheme) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "stations"
        return parts.url!
    }

    static func directionsURL(stationID: String, scheme: String = NearbyE85Configuration.urlScheme) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "directions"
        parts.path = "/station"
        parts.queryItems = [URLQueryItem(name: "id", value: stationID)]
        return parts.url!
    }

    static func parse(_ url: URL, scheme: String = NearbyE85Configuration.urlScheme) -> Destination? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == scheme,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return nil }
        switch parts.host {
        case "stations":
            guard parts.path.isEmpty, (parts.queryItems ?? []).isEmpty else { return nil }
            return .stations
        case "directions":
            guard parts.path == "/station", let items = parts.queryItems, items.count == 1,
                  items[0].name == "id", let id = items[0].value, !id.isEmpty, id.count <= 1024 else { return nil }
            return .directions(stationID: id)
        default:
            return nil
        }
    }
}

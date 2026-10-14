import Foundation

/// 85Blends 2.4.1 — the App-Group-shared signal that the Nearby E85 widget's cached station
/// cluster is no longer geographically relevant: the user moved far enough that every
/// previously-published station fell outside the ORIGINAL search radius (see
/// NearbyE85LocationRefreshCoordinator.reposition's own `nil` return), not merely "the data is
/// old." This is deliberately independent of both `NearbyE85Snapshot` (the cached stations
/// themselves — this file never changes that schema) and `NearbyE85WidgetAccessStatus` (Pro
/// entitlement) — a geographically-stale cache and an expired subscription are two completely
/// different reasons the widget might not show live station data, and must never be conflated.
///
/// AUTHORITY: the MAIN APP is the sole writer — `NearbyE85LocationRefreshCoordinator.handle`
/// marks this `true` the moment an accepted, in-range-quality location fix proves the cache is
/// out of area; `NearbyE85Publisher.publish` clears it the moment ANY fresh, authoritative
/// snapshot is published (a real Stations search succeeding, or a reposition succeeding again
/// after the user travels back into range). A failed/no-op search publishes nothing and
/// therefore never touches this store, so this flag can never be falsely cleared by a search
/// that didn't actually produce a usable result. The WIDGET EXTENSION only ever reads.
///
/// PRIVACY: stores only a boolean and a timestamp — no coordinate, no distance, no station
/// identity. `determinedAt` is refreshed on every repeated out-of-area fix so the age-based
/// expiry below stays anchored to the most recent evidence, not the first.
nonisolated struct NearbyE85AreaRelevanceState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let isOutOfArea: Bool
    let determinedAt: Date

    init(isOutOfArea: Bool, determinedAt: Date) {
        self.init(version: Self.currentVersion, isOutOfArea: isOutOfArea, determinedAt: determinedAt)
    }

    /// Explicit-version form — used by `Codable` decoding and by tests that deliberately write
    /// an unrecognised version to prove `NearbyE85AreaRelevanceStore.read()` rejects it.
    init(version: Int, isOutOfArea: Bool, determinedAt: Date) {
        self.version = version
        self.isOutOfArea = isOutOfArea
        self.determinedAt = determinedAt
    }

    /// What every failed/missing/corrupt read resolves to — never "out of area" by default.
    static let inArea = NearbyE85AreaRelevanceState(isOutOfArea: false, determinedAt: .distantPast)
}

/// App-Group-backed persistence, same injectable-`UserDefaults` shape as
/// `NearbyE85RefreshRequestStore`/`NearbyE85WidgetAccessStore` — testable without the real App
/// Group entitlement. Never throws, never crashes on bad data: every failure path reads as
/// `.inArea`, which the rest of the system already treats as "render normally."
nonisolated struct NearbyE85AreaRelevanceStore {
    static let key = "NearbyE85AreaRelevanceStateV1"

    let defaults: UserDefaults?

    init(defaults: UserDefaults? = NearbyE85Configuration.appGroup.flatMap { UserDefaults(suiteName: $0) }) {
        self.defaults = defaults
    }

    /// `.inArea` whenever the App Group is unavailable, nothing has been written yet, the
    /// stored bytes aren't decodable, or the version isn't exactly `currentVersion`.
    func read() -> NearbyE85AreaRelevanceState {
        guard let defaults, let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(NearbyE85AreaRelevanceState.self, from: data),
              state.version == NearbyE85AreaRelevanceState.currentVersion else {
            return .inArea
        }
        return state
    }

    /// Records that the cache is (still) out of area as of `date`, always refreshing
    /// `determinedAt` even on a repeated call. Returns whether the widget-VISIBLE boolean
    /// actually flipped false->true — `false` on every subsequent call while already marked
    /// out of area, so a caller (NearbyE85LocationRefreshCoordinator) can skip a timeline
    /// reload that would re-render an identical shell.
    @discardableResult
    func markOutOfArea(at date: Date) -> Bool {
        let wasInArea = read().isOutOfArea == false
        let wrote = write(NearbyE85AreaRelevanceState(isOutOfArea: true, determinedAt: date))
        return wasInArea && wrote
    }

    /// Removes the persisted payload, so reads return `.inArea` again. Returns whether the
    /// widget-VISIBLE status actually changed — `false` when nothing was stored, the App Group
    /// is unavailable, or only an undecodable payload (which already read as `.inArea`) was
    /// removed — so a caller can skip a reload that would re-render an identical shell.
    /// Undecodable bytes are still removed either way.
    @discardableResult
    func clear() -> Bool {
        guard let defaults else { return false }
        let wasVisible = read().isOutOfArea
        defaults.removeObject(forKey: Self.key)
        return wasVisible
    }

    @discardableResult
    private func write(_ state: NearbyE85AreaRelevanceState) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }
}

/// The pure, testable rule for whether the out-of-area signal should still be shown right now.
nonisolated enum NearbyE85AreaRelevance {
    /// Mirrors `NearbyE85Snapshot.expiresAfter`: past that age, the underlying cached snapshot
    /// has independently expired too (`NearbyE85Snapshot.isValid`), so there is nothing left
    /// for this signal to usefully comment on — it is dropped rather than shown indefinitely.
    /// Negative elapsed time (a clock-skew/future timestamp, which should never happen in
    /// practice) is treated as "not out of area" rather than indefinitely true, mirroring
    /// `NearbyE85RefreshFeedback.isRefreshing`'s identical guard.
    static func isCurrentlyOutOfArea(state: NearbyE85AreaRelevanceState, now: Date) -> Bool {
        guard state.isOutOfArea else { return false }
        let elapsed = now.timeIntervalSince(state.determinedAt)
        return elapsed >= 0 && elapsed < NearbyE85Snapshot.expiresAfter
    }
}

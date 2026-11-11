import Foundation
import CoreLocation
#if NEARBY_WIDGET_TESTING
@testable import EightyFiveBlends
#endif

// 85Blends 2.4.1 — the widget's own bounded refresh, so the refresh button works with the app
// fully closed. NearbyE85RefreshIntent.perform() awaits `refresh()` to completion before
// returning: one-shot location (widget authorization checked first) → a genuinely new NLR
// nearby-E85 search around that fix → merge with cached price/ethanol by canonical station
// identity → atomic App Group cache write. Every stage has its own deadline inside a
// whole-operation deadline; any failure leaves the cached snapshot untouched and records a
// specific outcome in NearbyE85RefreshStatusStore instead.

/// A validated-at-the-edge Core Location fix, as plain values.
nonisolated struct NearbyE85LocationFix: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let timestamp: Date
}

/// One NLR search result, reduced to what the widget needs.
nonisolated struct NearbyE85SearchResult: Equatable, Sendable {
    let name: String
    let address: String
    let city: String
    let state: String
    let zip: String
    let latitude: Double
    let longitude: Double
    let distanceMiles: Double
}

@MainActor protocol NearbyE85LocationFixing: AnyObject {
    /// The app's ordinary location permission AND the user's widget-location choice
    /// (`CLLocationManager.isAuthorizedForWidgetUpdates`). Never requests either.
    func isAuthorizedForWidgetUpdates() -> Bool
    func requestFix() async throws -> NearbyE85LocationFix
}

/// One catalogue answer: exact in-radius results plus when the catalogue actually fetched them from NLR
/// (earlier than now for a cached/stale proxy answer — never relabeled as a fresh fetch).
nonisolated struct NearbyE85SearchResponse: Equatable, Sendable {
    let results: [NearbyE85SearchResult]
    let sourceFetchedAt: Date
    /// False when the catalogue couldn't confirm complete coverage: the results are real but possibly not all.
    let coverageComplete: Bool
    /// Present when the catalogue served a STALE fallback (rate limit, upstream failure, timeout…): the stations are
    /// usable and keep their original source time, but the refresh itself did not succeed.
    var warning: StationCatalogueWarning? = nil
}

@MainActor protocol NearbyE85StationSearching {
    /// Throws `NLRServiceError.partialCoverage` when coverage is incomplete AND nothing is in radius.
    func search(latitude: Double, longitude: Double, radiusMiles: Double, limit: Int) async throws -> NearbyE85SearchResponse
}

enum NearbyE85WidgetRefreshError: Error, Equatable {
    case timedOut, permissionDenied, locationUnavailable
    /// The catalogue answered with a stale fallback that has nothing in radius: the refresh failed for this reason,
    /// and the empty list must never replace a useful cached snapshot as an authoritative "no stations".
    case catalogueUnavailable(StationCatalogueWarning)
}

@MainActor
final class NearbyE85WidgetRefreshCoordinator {
    nonisolated struct Limits: Sendable {
        var total: TimeInterval = 20
        var location: TimeInterval = 10
        var search: TimeInterval = 10
        /// A fix older than this is a cached fix from some earlier moment, not "where I am now".
        var maxFixAge: TimeInterval = 120
        var maxFixAccuracyMeters: Double = 1_000
        var defaultRadiusMiles: Double = 25
        var searchLimit = 20
    }

    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    /// The extension process's one coordinator, so repeated taps within one process share a
    /// single in-flight attempt instead of stacking network work.
    static let shared = NearbyE85WidgetRefreshCoordinator(location: NearbyE85CoreLocationFixer(),
                                                          search: NearbyE85ProxyStationSearch())

    private let location: NearbyE85LocationFixing
    private let searcher: NearbyE85StationSearching
    private let cache: NearbyE85Cache
    private let statusStore: NearbyE85RefreshStatusStore
    private let requestStore: NearbyE85RefreshRequestStore
    private let areaRelevanceStore: NearbyE85AreaRelevanceStore
    private let now: () -> Date
    private let sleep: Sleeper
    let limits: Limits
    /// The shared attempt plus how many callers are still waiting on it. The attempt is only
    /// cancelled once every waiter has been cancelled — one caller can never cancel work another
    /// caller still awaits.
    private var inFlight: (task: Task<NearbyE85RefreshStatus.Outcome, Never>, waiters: Int)?

    init(location: NearbyE85LocationFixing, search: NearbyE85StationSearching,
         cache: NearbyE85Cache = NearbyE85Cache(), statusStore: NearbyE85RefreshStatusStore = NearbyE85RefreshStatusStore(),
         requestStore: NearbyE85RefreshRequestStore = NearbyE85RefreshRequestStore(),
         areaRelevanceStore: NearbyE85AreaRelevanceStore = NearbyE85AreaRelevanceStore(),
         now: @escaping () -> Date = { .now },
         sleep: @escaping Sleeper = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
         limits: Limits = Limits()) {
        self.location = location
        self.searcher = search
        self.cache = cache
        self.statusStore = statusStore
        self.requestStore = requestStore
        self.areaRelevanceStore = areaRelevanceStore
        self.now = now
        self.sleep = sleep
        self.limits = limits
    }

    /// Runs (or joins) one bounded refresh and returns only once it has fully finished, so the
    /// caller's timeline reload sees the final cache/status.
    func refresh() async -> NearbyE85RefreshStatus.Outcome {
        let task: Task<NearbyE85RefreshStatus.Outcome, Never>
        if let current = inFlight {
            task = current.task
            inFlight = (task, current.waiters + 1)
        } else {
            task = Task {
                let outcome = await self.run()
                self.inFlight = nil
                return outcome
            }
            inFlight = (task, 1)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: {
            Task { @MainActor in self.waiterCancelled(task) }
        }
    }

    private func waiterCancelled(_ task: Task<NearbyE85RefreshStatus.Outcome, Never>) {
        guard let current = inFlight, current.task == task else { return }
        let remaining = current.waiters - 1
        inFlight = (task, remaining)
        if remaining <= 0 { task.cancel() }
    }

    private func run() async -> NearbyE85RefreshStatus.Outcome {
        var status = statusStore.begin(at: now())
        let attemptID = status.attemptID
        let progress = Progress()
        let outcome: NearbyE85RefreshStatus.Outcome
        do {
            outcome = try await withDeadline(limits.total) {
                try await self.work(attemptID: attemptID, startedAt: status.attemptStartedAt, progress: progress)
            }
        } catch {
            outcome = Self.outcome(for: error)
        }
        status.locationFixAt = progress.locationFixAt
        status.stationsFetchedAt = progress.stationsFetchedAt
        status.outcome = outcome
        status.finishedAt = now()
        // Explicit stale-completion rejection: a newer attempt owns the status now.
        guard statusStore.finish(status) else { return .superseded }
        // The app-open fallback is only redundant once the widget actually published a fresh
        // search (stations or a genuine "no stations"); on any failure the pending request is
        // intentionally kept so opening the app still retries.
        if outcome == .updated { requestStore.clear() }
        NearbyE85Diagnostics.logger.debug("WidgetRefresh: outcome=\(outcome.rawValue, privacy: .public)")
        return outcome
    }

    /// Per-attempt timestamps recorded as stages complete, so a later-stage failure still reports
    /// how far the attempt got (e.g. a fix was obtained but the search timed out).
    private final class Progress {
        var locationFixAt: Date?
        var stationsFetchedAt: Date?
    }

    private func work(attemptID: UUID, startedAt: Date, progress: Progress) async throws -> NearbyE85RefreshStatus.Outcome {
        guard location.isAuthorizedForWidgetUpdates() else { return .widgetLocationNotAuthorized }

        let fix = try await withDeadline(limits.location) { try await self.location.requestFix() }
        let fixAt = now()
        guard StationDataValidation.isValidCoordinate(latitude: fix.latitude, longitude: fix.longitude),
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= limits.maxFixAccuracyMeters,
              StationDataValidation.isValidTimestamp(fix.timestamp, asOf: fixAt),
              fixAt.timeIntervalSince(fix.timestamp) <= limits.maxFixAge else { return .locationUnavailable }
        progress.locationFixAt = fix.timestamp

        let radius = cache.read(now: fixAt).flatMap { $0.state == .permissionRequired ? nil : $0.radiusMiles }
            ?? limits.defaultRadiusMiles
        let response = try await withDeadline(limits.search) {
            try await self.searcher.search(latitude: fix.latitude, longitude: fix.longitude,
                                           radiusMiles: radius, limit: self.limits.searchLimit)
        }
        try Task.checkCancellation()
        let results = response.results
        // Three separate clocks: `fetchedAt` = when THIS device's search completed (the snapshot's updatedAt, which
        // drives labels/staleness/expiry); `sourceFetchedAt` = when the catalogue actually read NLR (provenance,
        // older for a proxy cache hit, never re-dated); the fix's own timestamp stays `locationAt`.
        let fetchedAt = now()
        let sourceFetchedAt = min(fetchedAt, response.sourceFetchedAt)
        progress.stationsFetchedAt = fetchedAt

        guard statusStore.isCurrent(attemptID) else { return .superseded }
        // The precondition runs INSIDE the cache's cross-process coordinated write, against the
        // exact snapshot it would replace: a snapshot the app (or another attempt) wrote after
        // this attempt began, or one from a newer fix, wins outright — even at the same location,
        // since the app's write may carry richer saved/community pricing. Otherwise price/ethanol
        // are merged from that same latest snapshot, never from an earlier read.
        // Catalogue source ages are only comparable for the SAME query (same coarse cell and radius bucket): there an
        // older catalogue answer never replaces newer cached station data. Across areas, ordering is decided only by
        // the attempt generation and the coordinated write above, never by catalogue age.
        let written = try cache.update(now: fetchedAt) { latest -> NearbyE85Snapshot? in
            if let latest, latest.updatedAt >= startedAt || (latest.locationAt.map { $0 > fix.timestamp } ?? false) {
                return nil
            }
            if let latest, let cachedSource = latest.sourceFetchedAt, cachedSource > sourceFetchedAt,
               Self.isSameCatalogueQuery(latest, latitude: fix.latitude, longitude: fix.longitude, radiusMiles: radius) {
                return nil
            }
            guard statusStore.isCurrent(attemptID) else { return nil }
            return Self.snapshot(from: results, fix: fix, radiusMiles: radius, fetchedAt: fetchedAt, cached: latest,
                                 sourceFetchedAt: sourceFetchedAt)
        }
        guard written != .rejected else { return .superseded }
        _ = areaRelevanceStore.clear()
        // Useful stale or partial results are published, but the attempt still reports what really happened, so the
        // specific notice shows and the app-open fallback request stays pending (only .updated clears it).
        if let warning = response.warning { return Self.outcome(for: warning) }
        return response.coverageComplete ? .updated : .coverageIncomplete
    }

    /// Pure: NLR results → a widget snapshot. Station identity is the same canonical community
    /// key StationsView publishes under. A station keeps its cached price/ethanol only when the
    /// canonical id matches, with the original report dates untouched (re-validated against
    /// today's rules, never re-dated). New stations carry no price — the widget never invents one.
    /// `fetchedAt` is this device's search time (cached reports are re-validated against it); `sourceFetchedAt`
    /// is the catalogue's NLR read time, stored as provenance only.
    static func snapshot(from results: [NearbyE85SearchResult], fix: NearbyE85LocationFix, radiusMiles: Double,
                                     fetchedAt: Date, cached: NearbyE85Snapshot?, sourceFetchedAt: Date? = nil) -> NearbyE85Snapshot {
        let previous = Dictionary((cached?.stations ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let userLocation = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        let stations = results.compactMap { result -> NearbyE85Station? in
            // NLR's missing-coordinate sentinel is 0/0 — same normalization as StationsView.
            let lat: Double? = result.latitude == 0 ? nil : result.latitude
            let lon: Double? = result.longitude == 0 ? nil : result.longitude
            guard let lat, let lon,
                  let key = CommunityStationKey.canonicalKey(name: result.name, streetAddress: result.address, city: result.city,
                                                             state: result.state, zip: result.zip, latitude: lat, longitude: lon)
            else { return nil }
            let old = previous[key]
            let price = old?.price.flatMap {
                NearbyE85Price.validated($0.dollarsPerGallon, reportedAt: $0.reportedAt, source: $0.source, now: fetchedAt)
            }
            let ethanol = old?.ethanol.flatMap {
                NearbyE85Ethanol.validated(percentage: $0.percentage, reportedAt: $0.reportedAt, now: fetchedAt)
            }
            let distance = userLocation.distance(from: CLLocation(latitude: lat, longitude: lon)) / 1_609.344
            return NearbyE85Station(id: key, name: result.name,
                                   address: [result.address, result.city, result.state, result.zip].filter { !$0.isEmpty }.joined(separator: ", "),
                                   latitude: lat, longitude: lon, distanceMiles: distance, price: price, ethanol: ethanol)
        }
        return .make(stations: stations, radiusMiles: radiusMiles, updatedAt: fetchedAt, locationAt: fix.timestamp,
                     userLatitude: fix.latitude, userLongitude: fix.longitude, sourceFetchedAt: sourceFetchedAt)
    }

    /// Pure: whether `snapshot` answered the same catalogue query (same 0.05° cell and radius bucket).
    nonisolated static func isSameCatalogueQuery(_ snapshot: NearbyE85Snapshot, latitude: Double, longitude: Double, radiusMiles: Double) -> Bool {
        guard let lat = snapshot.userLatitude, let lon = snapshot.userLongitude,
              let cached = StationCatalogueCells.cell(latitude: lat, longitude: lon),
              let current = StationCatalogueCells.cell(latitude: latitude, longitude: longitude) else { return false }
        return cached == current
            && StationCatalogueCells.bucket(forRadiusMiles: snapshot.radiusMiles) == StationCatalogueCells.bucket(forRadiusMiles: radiusMiles)
    }

    /// A stale-fallback warning's honest outcome: never `.updated`.
    nonisolated static func outcome(for warning: StationCatalogueWarning) -> NearbyE85RefreshStatus.Outcome {
        switch warning.code {
        case .rateLimited: return .rateLimited
        case .timeout: return .timedOut
        case .busy, .upstreamFailed, .upstreamTooLarge, .invalidResponse, .unavailable: return .networkFailed
        }
    }

    nonisolated static func outcome(for error: Error) -> NearbyE85RefreshStatus.Outcome {
        switch error {
        case NearbyE85WidgetRefreshError.timedOut: return .timedOut
        case NearbyE85WidgetRefreshError.catalogueUnavailable(let warning): return outcome(for: warning)
        case NLRServiceError.partialCoverage: return .coverageIncomplete
        case NLRServiceError.rateLimited: return .rateLimited
        case NearbyE85WidgetRefreshError.permissionDenied: return .locationPermissionDenied
        case NearbyE85WidgetRefreshError.locationUnavailable: return .locationUnavailable
        case is CancellationError: return .cancelled
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .offline
            case .timedOut: return .timedOut
            case .cancelled: return .cancelled
            default: return .networkFailed
            }
        case let error as CLError:
            return error.code == .denied ? .locationPermissionDenied : .locationUnavailable
        default: return .networkFailed
        }
    }

    /// Races `operation` against `seconds`; whichever finishes first wins and the other is
    /// cancelled, so no child work outlives this call.
    private func withDeadline<T>(_ seconds: TimeInterval, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let sleep = self.sleep
        return try await withThrowingTaskGroup(of: Optional<T>.self) { group in
            group.addTask { @MainActor in try await operation() }
            group.addTask {
                try await sleep(seconds)
                throw NearbyE85WidgetRefreshError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw NearbyE85WidgetRefreshError.timedOut }
            return value
        }
    }
}

// MARK: - Automatic (timeline-driven) refresh

/// 85Blends 2.4.1 — the extension's AUTOMATIC refresh, run from NearbyE85Provider.getTimeline for
/// an eligible Pro timeline only. Separate from the manual Reload path: it never marks the
/// app-open pending-request fallback, and it reuses the same coordinator (deadlines, single-flight,
/// stale-attempt rejection, coordinated cache write). WidgetKit's reload budget is respected by a
/// persisted App Group throttle: an attempt runs only when the cache is missing/stale/expired or
/// provably out of area AND no attempt (automatic or manual) started within `minInterval`. This
/// never promises a background cadence — it only decides what to do when WidgetKit asks.
nonisolated enum NearbyE85AutomaticRefresh {
    /// Keeps back-to-back invocations (reloads, multiple families, repeated failures) from
    /// re-searching; shorter than the timeline's 30-minute `.after` so a due cache isn't skipped twice.
    static let minInterval: TimeInterval = 15 * 60

    /// Pure due policy. `snapshot` is the cache as read (nil when missing or invalid/expired).
    static func isDue(access: NearbyE85WidgetAccessStatus, locationAuthorized: Bool, snapshot: NearbyE85Snapshot?,
                      areaRelevance: NearbyE85AreaRelevanceState, lastAutomaticAttemptAt: Date?,
                      status: NearbyE85RefreshStatus?, now: Date) -> Bool {
        guard access.permitsWidgetInteraction, locationAuthorized else { return false }
        if NearbyE85RefreshFeedback.isRefreshing(status: status, now: now) { return false }
        let lastAttempt = [lastAutomaticAttemptAt, status?.attemptStartedAt].compactMap { $0 }.max()
        if let lastAttempt {
            let elapsed = now.timeIntervalSince(lastAttempt)
            // A future timestamp (clock skew) never blocks forever; only a recent past attempt throttles.
            if elapsed >= 0 && elapsed < minInterval { return false }
        }
        guard let snapshot, snapshot.state != .permissionRequired else { return true }
        return snapshot.isStale(at: now) || NearbyE85AreaRelevance.isCurrentlyOutOfArea(state: areaRelevance, now: now)
    }

    /// Decides, records the attempt time (before any work, so a killed extension still throttles),
    /// then awaits the coordinator. Returns whether an attempt ran. Nothing here touches the
    /// pending manual-refresh request.
    @MainActor @discardableResult
    static func runIfDue(access: NearbyE85WidgetAccessStatus, now: Date,
                         locationAuthorized: () -> Bool,
                         cache: NearbyE85Cache, statusStore: NearbyE85RefreshStatusStore,
                         areaRelevanceStore: NearbyE85AreaRelevanceStore, attemptStore: NearbyE85AutomaticRefreshStore,
                         refresh: () async -> NearbyE85RefreshStatus.Outcome) async -> Bool {
        // Access first: a non-Pro timeline does no location, network, or cache work at all.
        guard access.permitsWidgetInteraction, locationAuthorized() else { return false }
        guard isDue(access: access, locationAuthorized: true, snapshot: cache.read(now: now),
                    areaRelevance: areaRelevanceStore.read(), lastAutomaticAttemptAt: attemptStore.lastAttemptDate(),
                    status: statusStore.read(), now: now) else { return false }
        attemptStore.markAttempted(at: now)
        let outcome = await refresh()
        NearbyE85Diagnostics.logger.debug("AutomaticRefresh: outcome=\(outcome.rawValue, privacy: .public)")
        return true
    }
}

/// The automatic refresh's own throttle clock — separate from the manual pending-request flag and
/// from every location/station/report timestamp.
nonisolated struct NearbyE85AutomaticRefreshStore {
    static let key = "NearbyE85LastAutomaticRefreshAttemptAt"

    let defaults: UserDefaults?

    init(defaults: UserDefaults? = NearbyE85Configuration.appGroup.flatMap { UserDefaults(suiteName: $0) }) {
        self.defaults = defaults
    }

    func lastAttemptDate() -> Date? {
        guard let defaults, let raw = defaults.object(forKey: Self.key) as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    func markAttempted(at date: Date) {
        defaults?.set(date.timeIntervalSinceReferenceDate, forKey: Self.key)
    }
}

// MARK: - Live implementations (extension only; tests inject fakes)

/// One-shot `requestLocation()` wrapper. The manager and its delegate stay retained on the main
/// actor until exactly one result resolves the request — a fix, an error, or cancellation
/// (timeouts cancel via the coordinator's deadline) — after which location updates are stopped
/// and both are released. Each request carries its own token, so a late cancellation or delegate
/// callback for an earlier request can never resolve a later one.
@MainActor
final class NearbyE85CoreLocationFixer: NSObject, NearbyE85LocationFixing, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var pending: (id: UUID, continuation: CheckedContinuation<NearbyE85LocationFix, Error>)?

    func isAuthorizedForWidgetUpdates() -> Bool { Self.widgetLocationAuthorized() }

    /// The one rule both the refresh and NearbyE85Provider's privacy gate use.
    static func widgetLocationAuthorized() -> Bool {
        let manager = CLLocationManager()
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return false }
        return manager.isAuthorizedForWidgetUpdates
    }

    func requestFix() async throws -> NearbyE85LocationFix {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancelled before anything was installed: never start Core Location at all.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard self.pending == nil else {
                    continuation.resume(throwing: NearbyE85WidgetRefreshError.locationUnavailable)
                    return
                }
                self.pending = (id, continuation)
                let manager = CLLocationManager()
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                self.manager = manager
                manager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor in self.resolve(id: id, .failure(CancellationError())) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.max(by: { $0.timestamp < $1.timestamp }) else { return }
        let fix = NearbyE85LocationFix(latitude: latest.coordinate.latitude, longitude: latest.coordinate.longitude,
                                       horizontalAccuracy: latest.horizontalAccuracy, timestamp: latest.timestamp)
        Task { @MainActor in self.resolveCurrent(from: manager, .success(fix)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let mapped: Error = (error as? CLError)?.code == .denied
            ? NearbyE85WidgetRefreshError.permissionDenied : NearbyE85WidgetRefreshError.locationUnavailable
        Task { @MainActor in self.resolveCurrent(from: manager, .failure(mapped)) }
    }

    private func resolveCurrent(from manager: CLLocationManager, _ result: Result<NearbyE85LocationFix, Error>) {
        guard manager === self.manager, let id = pending?.id else { return }
        resolve(id: id, result)
    }

    private func resolve(id: UUID, _ result: Result<NearbyE85LocationFix, Error>) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        pending.continuation.resume(with: result)
    }
}

/// The shared station-catalogue proxy client (NRELStationService.swift, compiled into both targets) on an
/// ephemeral session. Transport is bounded at 9 s — inside the coordinator's 10 s search stage — and the
/// widget's own Info.plist supplies only the public Supabase URL and publishable key.
@MainActor
struct NearbyE85ProxyStationSearch: NearbyE85StationSearching {
    func search(latitude: Double, longitude: Double, radiusMiles: Double, limit: Int) async throws -> NearbyE85SearchResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = NLRStationService.transportTimeout
        configuration.timeoutIntervalForResource = NLRStationService.transportTimeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let result = try await NLRStationService(session: session)
            .search(latitude: latitude, longitude: longitude, radiusMiles: radiusMiles, limit: limit)
        return try Self.response(from: result)
    }

    /// Pure: an EMPTY answer is authoritative only when it is complete AND a successful refresh. Empty + stale
    /// fallback (any warning, complete or not) throws the real failure; empty + incomplete throws partial coverage.
    /// Either way nothing is published, so the useful cached snapshot stays. Non-empty answers are kept, marked.
    nonisolated static func response(from result: StationCatalogueSearchResult) throws -> NearbyE85SearchResponse {
        if result.stations.isEmpty, let warning = result.warning { throw NearbyE85WidgetRefreshError.catalogueUnavailable(warning) }
        if result.stations.isEmpty && !result.coverageComplete { throw NLRServiceError.partialCoverage }
        return NearbyE85SearchResponse(results: result.stations.map {
            NearbyE85SearchResult(name: $0.name, address: $0.address, city: $0.city, state: $0.state, zip: $0.zip,
                                  latitude: $0.latitude, longitude: $0.longitude, distanceMiles: $0.distanceMiles)
        }, sourceFetchedAt: result.sourceFetchedAt, coverageComplete: result.coverageComplete, warning: result.warning)
    }
}

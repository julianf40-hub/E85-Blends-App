import Foundation

/// A one-shot "please refresh when you get the chance" flag — the app-open FALLBACK for a widget
/// manual refresh. NearbyE85RefreshIntent marks it on every Pro tap, then awaits its own bounded
/// extension refresh (NearbyE85WidgetRefreshCoordinator: widget-authorized one-shot location →
/// new nearby search → coordinated cache write). That refresh clears this flag only after it
/// actually published; on any failure (permission, location, network, timeout) the flag is kept,
/// and the main app consumes it the next time it becomes active — see EightyFiveBlendsApp's
/// scenePhase handling.
///
/// Deliberately minimal — a single App-Group-shared timestamp, not a second general settings
/// system. Mirrors NearbyE85MapZoomStore's injectable-UserDefaults shape for the same reason:
/// testable without the real App Group entitlement or a live widget host.
nonisolated struct NearbyE85RefreshRequestStore {
    static let key = "NearbyE85PendingManualRefreshRequestedAt"

    let defaults: UserDefaults?

    init(defaults: UserDefaults? = NearbyE85Configuration.appGroup.flatMap { UserDefaults(suiteName: $0) }) {
        self.defaults = defaults
    }

    /// When the most recent manual refresh tap happened, or nil if none is pending (never
    /// requested, already consumed, or the App Group is unavailable).
    func pendingRequestDate() -> Date? {
        guard let defaults, let raw = defaults.object(forKey: Self.key) as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    func markRequested(at date: Date) {
        defaults?.set(date.timeIntervalSinceReferenceDate, forKey: Self.key)
    }

    /// Cleared by the widget's own refresh after a successful publish, or consumed exactly once
    /// by the app-active handler regardless of whether a fresh location was actually obtainable
    /// there — a request that couldn't be fulfilled this launch isn't retried indefinitely; the
    /// ordinary significant-location-change/foreground-movement paths remain the primary way the
    /// widget stays current.
    func clear() {
        defaults?.removeObject(forKey: Self.key)
    }
}

/// Pure, testable refresh-control feedback rules. Two sources, in priority order:
/// - 85Blends 2.4.1: the widget's own refresh status (`isRefreshing(status:now:)`,
///   `notice(status:now:)` in the extension below) — the spinner shows while that awaited
///   extension refresh is actually in flight and clears on completion, with a specific notice
///   for a failed attempt.
/// - 85Blends 2.4.0 (legacy fallback, used only when no refresh status exists): request-age
///   timing (`isRefreshing(requestedAt:now:)`), which can only ever say "a refresh was recently
///   requested."
/// Neither ever claims new data arrived — that remains entirely up to whether a new
/// NearbyE85Snapshot was actually published — and neither touches station or report timestamps.
nonisolated enum NearbyE85RefreshFeedback {
    /// Legacy request-age window, used only when no widget refresh status exists: long enough
    /// to be noticed on a glance back at the Home Screen after tapping refresh, short enough
    /// that the control never looks permanently "stuck".
    static let window: TimeInterval = 8

    /// True when `requestedAt` (the most recent manual-refresh tap, from
    /// `NearbyE85RefreshRequestStore.pendingRequestDate()`) is recent enough, relative to `now`,
    /// that the refresh control should still show its in-progress appearance. `now` is normally
    /// a specific timeline entry's own `date` (not wall-clock time), so this produces the correct
    /// answer for every entry a single timeline computation schedules. Negative elapsed time
    /// (a clock-skew/future timestamp, which should never happen in practice) is treated as "not
    /// refreshing" rather than indefinitely true.
    static func isRefreshing(requestedAt: Date?, now: Date) -> Bool {
        guard let requestedAt else { return false }
        let elapsed = now.timeIntervalSince(requestedAt)
        return elapsed >= 0 && elapsed < window
    }
}

/// 85Blends 2.4.1 — the outcome of the most recent widget-initiated refresh attempt, written by
/// NearbyE85WidgetRefreshCoordinator (widget extension) and read by NearbyE85Provider. Keeps four
/// clocks strictly separate so nothing is ever relabeled as fresher than it is:
/// - `attemptStartedAt`: when the tap's refresh began (drives only the in-progress spinner),
/// - `locationFixAt`: the accepted Core Location fix's own timestamp (never the attempt time),
/// - `stationsFetchedAt`: when a station search actually succeeded,
/// - each station's own price/ethanol `reportedAt`, which lives in the snapshot and is never
///   touched by this type at all.
nonisolated struct NearbyE85RefreshStatus: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case inProgress, updated
        case widgetLocationNotAuthorized, locationPermissionDenied, locationUnavailable
        case offline, networkFailed, timedOut, cancelled, superseded
        /// The catalogue couldn't confirm coverage and nothing was in radius: unknown, not "no stations".
        case coverageIncomplete
        /// The station catalogue is rate limited; any stations shown are its saved (stale) answer.
        case rateLimited
    }
    let attemptID: UUID
    let attemptStartedAt: Date
    var outcome: Outcome
    var finishedAt: Date? = nil
    var locationFixAt: Date? = nil
    var stationsFetchedAt: Date? = nil
}

/// App-Group-shared store for NearbyE85RefreshStatus: one small JSON file next to the snapshot
/// cache, NOT UserDefaults — UserDefaults gives no cross-process compare-and-swap and no promise
/// that another process's read sees a just-made write. Each attempt is identified by a fresh UUID,
/// so two processes starting at once can never share an identity. `begin` and `finish`'s
/// check-then-write run under an exclusive `flock` on a sibling lock file, and every write is an
/// atomic replace (write temp + rename), so: (1) an older attempt's finish can never interleave
/// with a newer attempt's begin in another process, and (2) the identity check inside the lock
/// reads the file itself, which always reflects the last completed rename by any process — the
/// lock's release happens-before the next holder's read. Readers outside the lock always see one
/// whole status. The cache write is guarded separately by NearbyE85Cache's coordinated update.
nonisolated struct NearbyE85RefreshStatusStore {
    static let maxBytes = 4_096

    /// nil when the App Group container is unavailable: reads return nil and writes do nothing.
    let fileURL: URL?
    /// Test-only seam between `finish`'s identity check and its write.
    let beforeFinishWrite: (@Sendable () -> Void)?

    init(fileURL: URL? = NearbyE85Configuration.appGroup.flatMap {
             FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
         }?.appendingPathComponent("NearbyE85/refresh-status-v1.json"),
         beforeFinishWrite: (@Sendable () -> Void)? = nil) {
        self.fileURL = fileURL
        self.beforeFinishWrite = beforeFinishWrite
    }

    func read() -> NearbyE85RefreshStatus? {
        guard let fileURL,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxBytes,
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(NearbyE85RefreshStatus.self, from: data)
    }

    /// Starts a new attempt under a fresh identity; any older in-flight attempt becomes stale.
    func begin(at date: Date, attemptID: UUID = UUID()) -> NearbyE85RefreshStatus {
        let status = NearbyE85RefreshStatus(attemptID: attemptID, attemptStartedAt: date, outcome: .inProgress)
        // Fails closed: without the lock nothing is written (the caller's attempt then simply
        // isn't current, so its finish is rejected and no newer generation can be clobbered).
        _ = withLock { write(status) }
        return status
    }

    func isCurrent(_ attemptID: UUID) -> Bool { read()?.attemptID == attemptID }

    /// Records a finished attempt only if it is still the current attempt; a stale attempt's
    /// completion is rejected and leaves the newer attempt's status untouched. Returns whether
    /// it was recorded.
    @discardableResult
    func finish(_ status: NearbyE85RefreshStatus) -> Bool {
        withLock {
            guard isCurrent(status.attemptID) else { return false }
            beforeFinishWrite?()
            return write(status)
        } ?? false
    }

    /// Exclusive advisory lock on `<status file>.lock`, shared by every process and every store
    /// instance using the same status file. Held only around a small file read/replace, never
    /// across async work. Returns nil WITHOUT running `body` when there is no status file or the
    /// lock can't be created/opened/acquired: status mutation never happens unlocked.
    private func withLock<T>(_ body: () -> T) -> T? {
        guard let fileURL else { return nil }
        let lockURL = fileURL.appendingPathExtension("lock")
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    @discardableResult
    private func write(_ status: NearbyE85RefreshStatus) -> Bool {
        guard let fileURL, let data = try? JSONEncoder().encode(status), data.count <= Self.maxBytes else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }
}

nonisolated extension NearbyE85RefreshFeedback {
    /// Upper bound on how long an `.inProgress` status may show the spinner. Longer than the
    /// coordinator's whole-operation deadline, so it only ever matters when the extension was
    /// terminated mid-attempt and never recorded a final outcome.
    static let maxInFlight: TimeInterval = 30
    /// How long a failure notice stays visible after the attempt finished.
    static let noticeLifetime: TimeInterval = 30 * 60

    /// Completion-based in-progress rule: true only while an attempt is actually in flight.
    static func isRefreshing(status: NearbyE85RefreshStatus?, now: Date) -> Bool {
        guard let status, status.outcome == .inProgress else { return false }
        let elapsed = now.timeIntervalSince(status.attemptStartedAt)
        return elapsed >= 0 && elapsed < maxInFlight
    }

    /// Short, specific copy for the most recent failed attempt; nil when there's nothing to say
    /// (success, still running, superseded/cancelled, or too old to be relevant). Cached
    /// stations are never hidden because of this — it's an annotation on top of them.
    static func notice(status: NearbyE85RefreshStatus?, now: Date) -> String? {
        guard let status, let finishedAt = status.finishedAt,
              now.timeIntervalSince(finishedAt) >= 0, now.timeIntervalSince(finishedAt) < noticeLifetime else { return nil }
        switch status.outcome {
        case .widgetLocationNotAuthorized: return "Widget location off"
        case .locationPermissionDenied: return "Location access off"
        case .locationUnavailable: return "Couldn't get location"
        case .offline: return "Offline · showing saved"
        case .networkFailed: return "Couldn't reach stations"
        case .timedOut: return "Refresh timed out"
        case .coverageIncomplete: return "Couldn't confirm stations"
        case .rateLimited: return "Search busy · showing saved"
        case .inProgress, .updated, .cancelled, .superseded: return nil
        }
    }
}

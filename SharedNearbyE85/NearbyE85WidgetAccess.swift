import Foundation

// 85Blends 2.4.0 — Nearby E85 widget Pro gate: the App-Group-shared MIRROR of widget access.
//
// AUTHORITY INVARIANT (read this before touching anything in this file):
//   • RevenueCat's `CustomerInfo.entitlements["pro"]?.isActive` — surfaced through
//     `RevenueCatSubscriptionService.revenueCatIsPro` and read by `SubscriptionManager.isPro` /
//     `canAccessNearbyE85Widget` — is the ONLY real subscription entitlement authority in 85Blends.
//   • The value persisted here is NOT a second authority. It is a derived, app-written copy of the
//     most recent authoritative answer, published so the widget extension (which has no RevenueCat
//     SDK, no network access worth relying on, and no `SubscriptionManager`) can render the right
//     shell without ever making an entitlement decision of its own.
//   • The MAIN APP is the sole writer (see `NearbyE85WidgetAccessPublisher`). The WIDGET EXTENSION
//     only ever reads. Nothing in this file imports RevenueCat, StoreKit, or WidgetKit.
//   • `.unknown` means exactly "no authoritative answer has been mirrored yet" — a fresh install, a
//     corrupt/missing value, an App Group that isn't available. It is NEVER treated as Free: the
//     widget renders a neutral "verify" state, never a "locked"/"upgrade" one, and the app's own
//     deep-link gate holds rather than presenting the paywall — see `NearbyE85WidgetEntitlementRoute`.
//   • A FAILED RevenueCat refresh never reaches this store at all: `NearbyE85WidgetAccessPublisher.
//     mirroredStatus(...)` returns nil (publish nothing) unless a real CustomerInfo has been applied
//     (`SubscriptionManager.hasAuthoritativeProStatus`) or the Developer Pro Override is active.
//   • The app never WRITES `.unknown`. The one path that takes a mirror back to `.unknown` is
//     `clear()`, used only by the DEBUG/INTERNAL-only `NearbyE85WidgetAccessPublisher.
//     resetDebugForcedMirror` when a Developer Pro Override is switched Off before any authoritative
//     answer exists — a forced `.pro`/`.free` must not keep advertising itself once the override that
//     produced it is gone. That path is compiled out of App Store builds entirely.
//   • Contents are deliberately minimal: a schema version, a three-way status, and the time it was
//     written. No RevenueCat App User ID, no customer/reporter identifier, no product ID, no plan, no
//     price, no receipt — nothing that identifies a person or describes a purchase.

/// What the widget extension is allowed to render, as last mirrored by the app.
nonisolated enum NearbyE85WidgetAccessStatus: String, Codable, Equatable, Sendable {
    /// Nothing authoritative has ever been mirrored (or the mirror is missing/corrupt). NOT Free.
    case unknown
    /// The most recent authoritative RevenueCat answer was "no active `pro` entitlement."
    case free
    /// The most recent authoritative RevenueCat answer was "active `pro` entitlement."
    case pro

    /// True only for `.pro` — the single rule every widget-side interactive surface (refresh/zoom
    /// AppIntents, map/row deep links, station data loading) consults. `.unknown` and `.free` are
    /// both non-interactive; they differ only in what neutral shell the widget shows.
    var permitsWidgetInteraction: Bool { self == .pro }
}

/// The exact payload persisted in the App Group. Versioned so a future shape change can be rejected
/// cleanly (→ `.unknown`) by an older widget binary instead of being misread.
nonisolated struct NearbyE85WidgetAccessState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let status: NearbyE85WidgetAccessStatus
    let updatedAt: Date

    init(status: NearbyE85WidgetAccessStatus, updatedAt: Date) {
        self.init(version: Self.currentVersion, status: status, updatedAt: updatedAt)
    }

    /// Explicit-version form — used by `Codable` decoding and by tests that deliberately write an
    /// unrecognised version to prove `NearbyE85WidgetAccessStore.read()` rejects it.
    init(version: Int, status: NearbyE85WidgetAccessStatus, updatedAt: Date) {
        self.version = version
        self.status = status
        self.updatedAt = updatedAt
    }

    /// What every failed/missing read resolves to. `updatedAt` is `.distantPast` so it can never be
    /// mistaken for a real, recent mirror write.
    static let unknown = NearbyE85WidgetAccessState(status: .unknown, updatedAt: .distantPast)
}

/// App-Group-backed persistence for `NearbyE85WidgetAccessState`. Same injectable-`UserDefaults`
/// shape as `NearbyE85MapZoomStore`/`NearbyE85RefreshRequestStore`, for the same reason: testable
/// without the real App Group entitlement or a live widget host. Never throws, never crashes on bad
/// data — every failure path is `.unknown`, which the rest of the system already treats as "hold,
/// don't decide," never as Free.
nonisolated struct NearbyE85WidgetAccessStore {
    static let key = "NearbyE85WidgetAccessStateV1"

    let defaults: UserDefaults?

    init(defaults: UserDefaults? = NearbyE85Configuration.appGroup.flatMap { UserDefaults(suiteName: $0) }) {
        self.defaults = defaults
    }

    /// `.unknown` whenever the App Group is unavailable, nothing has been written yet, the stored
    /// bytes aren't a decodable state, the status raw value is unrecognised, or the version is not
    /// exactly `NearbyE85WidgetAccessState.currentVersion`.
    func read() -> NearbyE85WidgetAccessState {
        guard let defaults, let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(NearbyE85WidgetAccessState.self, from: data),
              state.version == NearbyE85WidgetAccessState.currentVersion else {
            return .unknown
        }
        return state
    }

    /// App-only. Returns `false` (and stores nothing) when the App Group is unavailable — the widget
    /// then keeps reading `.unknown`, which is the correct honest answer for that situation, and the
    /// publisher skips its timeline reload since nothing the widget can see has changed.
    @discardableResult
    func write(_ state: NearbyE85WidgetAccessState) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }

    /// Removes the persisted payload, so reads return `.unknown` again. Returns whether the widget-
    /// VISIBLE status actually changed — `true` only if a decodable `.pro`/`.free` was removed; `false`
    /// when nothing was stored, the App Group is unavailable, or only an undecodable payload (which
    /// already read as `.unknown`) was removed — so a caller can skip a timeline reload that would
    /// re-render an identical shell. Undecodable bytes are still removed either way.
    @discardableResult
    func clear() -> Bool {
        guard let defaults else { return false }
        let wasVisible = read().status != .unknown
        defaults.removeObject(forKey: Self.key)
        return wasVisible
    }
}

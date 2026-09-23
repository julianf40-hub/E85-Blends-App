import Foundation
import WidgetKit

/// 85Blends 2.4.0 — the app-side (and ONLY) writer of the Nearby E85 widget's access mirror.
///
/// Reads the authoritative answer from `SubscriptionManager` (itself derived from RevenueCat — see
/// SharedNearbyE85/NearbyE85WidgetAccess.swift's AUTHORITY INVARIANT), copies it into the App
/// Group via `NearbyE85WidgetAccessStore`, and asks WidgetKit to reload the widget's timelines —
/// but only when the widget-visible value actually changed. Wired from EightyFiveBlendsApp's body
/// via `.onChange(of:initial:)` over `mirroredStatus(for:)` into `sync(previous:current:)`, so it
/// runs on launch (covers a fresh install / first launch after updating to 2.4.0, where the mirror
/// doesn't exist yet), on every successful CustomerInfo application
/// (`RevenueCatSubscriptionService.apply(_:)` is what changes `revenueCatIsPro`/
/// `customerInfoLastUpdatedAt`), on purchase/restore (both go through `apply`), and on every
/// Developer Pro Override change in Internal/Debug builds. It deliberately does NOT hook into
/// RevenueCatSubscriptionService itself: that service must stay unaware of SubscriptionManager and
/// of the widget, so there is no singleton init cycle to reason about.
///
/// Mirrors NearbyE85Publisher's shape (a `@MainActor enum` with injectable I/O seams) rather than
/// introducing a new singleton or observer object.
@MainActor
enum NearbyE85WidgetAccessPublisher {
    /// The single pure rule for what the app is allowed to mirror right now — `nil` means "nothing
    /// authoritative to mirror" (see `transition(previous:current:)` for what that then means).
    ///
    /// - `nil` unless a REAL CustomerInfo has been applied this process
    ///   (`hasAuthoritativeProStatus`) or the Developer Pro Override is forcing a value. This is
    ///   what makes a failed RevenueCat refresh incapable of overwriting a previously-mirrored
    ///   `.pro` with `.free`: a failure changes neither input (see
    ///   `RevenueCatSubscriptionService.refreshCustomerInfoNow()`'s catch block, which never touches
    ///   `customerInfoLastUpdatedAt` or `revenueCatIsPro`), so nothing is published.
    /// - Otherwise exactly `.pro`/`.free` from `isPro` — the app never writes `.unknown`; that value
    ///   only ever arises on the READ side (missing/corrupt mirror, no App Group), or from the
    ///   DEBUG/INTERNAL-only reset below.
    /// - The override case exists so Internal/Debug "Force Pro"/"Force Free" affect the widget
    ///   immediately, exactly as they affect every in-app gate, even before RevenueCat has answered.
    nonisolated static func mirroredStatus(isPro: Bool, hasAuthoritativeProStatus: Bool,
                                           isDebugProOverrideActive: Bool) -> NearbyE85WidgetAccessStatus? {
        guard hasAuthoritativeProStatus || isDebugProOverrideActive else { return nil }
        return isPro ? .pro : .free
    }

    /// `mirroredStatus(...)` fed from the live `SubscriptionManager`. The Developer Pro Override
    /// doesn't exist in App Store builds (`#if DEBUG || INTERNAL_BUILD`), so this is the one place
    /// that conditional is resolved for both this publisher and the deep-link gate.
    static func mirroredStatus(for manager: SubscriptionManager) -> NearbyE85WidgetAccessStatus? {
        #if DEBUG || INTERNAL_BUILD
        let isDebugProOverrideActive = manager.isDebugProOverrideActive
        #else
        let isDebugProOverrideActive = false
        #endif
        return mirroredStatus(isPro: manager.canAccessNearbyE85Widget,
                              hasAuthoritativeProStatus: manager.hasAuthoritativeProStatus,
                              isDebugProOverrideActive: isDebugProOverrideActive)
    }

    /// What one observed change of `mirroredStatus` (previous → current) means for the App Group.
    nonisolated enum MirrorTransition: Equatable {
        /// Publish nothing; whatever is already mirrored stays. In App Store builds this is the ONLY
        /// response to a `nil` status (cold launch before RevenueCat answers, or a failed refresh).
        case hold
        /// Mirror this authoritative (or override-forced) value — a no-op if it's already mirrored.
        case publish(NearbyE85WidgetAccessStatus)
        #if DEBUG || INTERNAL_BUILD
        /// DEBUG/INTERNAL only. The status just went from a value back to `nil`. Since
        /// `hasAuthoritativeProStatus` is forward-only (never returns to false — see
        /// SubscriptionManager), the only way that can happen is a Developer Pro Override being
        /// switched Off while RevenueCat still hasn't answered — so whatever is mirrored right now
        /// was forced by that override and no longer applies. Remove it, so the widget reads
        /// `.unknown` (the neutral "verify" shell) rather than a stale Force Pro/Force Free result,
        /// until a real answer arrives. Compiled out of App Store builds: production can never take
        /// a mirror back to `.unknown`.
        case resetDebugForcedMirror
        #endif
    }

    nonisolated static func transition(previous: NearbyE85WidgetAccessStatus?,
                                       current: NearbyE85WidgetAccessStatus?) -> MirrorTransition {
        if let current { return .publish(current) }
        #if DEBUG || INTERNAL_BUILD
        if previous != nil { return .resetDebugForcedMirror }
        #endif
        return .hold
    }

    /// The `.onChange(of:initial:)` entry point (see EightyFiveBlendsApp): applies
    /// `transition(previous:current:)` to the store. On the initial call `previous == current`, so a
    /// launch can only ever `publish` (idempotent) or `hold`, never reset. Returns whether the widget-
    /// visible mirror changed (and therefore whether a timeline reload was requested).
    @discardableResult
    static func sync(previous: NearbyE85WidgetAccessStatus?, current: NearbyE85WidgetAccessStatus?,
                     store: NearbyE85WidgetAccessStore = NearbyE85WidgetAccessStore(),
                     now: Date = .now,
                     reloadTimelines: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: NearbyE85Configuration.kind) }) -> Bool {
        switch transition(previous: previous, current: current) {
        case .hold:
            return false
        case .publish(let status):
            return publish(status, store: store, now: now, reloadTimelines: reloadTimelines)
        #if DEBUG || INTERNAL_BUILD
        case .resetDebugForcedMirror:
            return resetDebugForcedMirror(store: store, reloadTimelines: reloadTimelines)
        #endif
        }
    }

    /// Writes `status` to the App Group and reloads the widget's timelines — ONLY if `status`
    /// differs from what is already mirrored AND the write actually landed. Returns whether
    /// anything was published. Re-confirming an unchanged status (e.g. every foreground refresh for
    /// a stable Pro subscriber) is a complete no-op: no write, no `updatedAt` churn, and no reload
    /// request spent against WidgetKit's budget for a re-render that would be identical. Likewise
    /// when the App Group is unavailable: nothing the widget can see changed, so nothing reloads.
    @discardableResult
    static func publish(_ status: NearbyE85WidgetAccessStatus,
                        store: NearbyE85WidgetAccessStore = NearbyE85WidgetAccessStore(),
                        now: Date = .now,
                        reloadTimelines: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: NearbyE85Configuration.kind) }) -> Bool {
        guard store.read().status != status else { return false }
        guard store.write(NearbyE85WidgetAccessState(status: status, updatedAt: now)) else { return false }
        reloadTimelines()
        return true
    }

    #if DEBUG || INTERNAL_BUILD
    /// See `MirrorTransition.resetDebugForcedMirror`. Reloads only if `clear()` reports the widget-
    /// visible status actually changed (a `.pro`/`.free` was removed) — clearing an already-missing or
    /// undecodable mirror spends no reload.
    @discardableResult
    static func resetDebugForcedMirror(store: NearbyE85WidgetAccessStore = NearbyE85WidgetAccessStore(),
                                       reloadTimelines: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: NearbyE85Configuration.kind) }) -> Bool {
        guard store.clear() else { return false }
        reloadTimelines()
        return true
    }
    #endif
}

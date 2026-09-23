//
//  NearbyE85WidgetRouting.swift
//  EightyFiveBlends
//
//  Pure decision step for a parsed Nearby E85 widget deep link — no UIApplication/UIKit side
//  effects, so the routing decision itself (as opposed to actually handing off to a map app or
//  switching tabs) is directly unit testable. ContentView.openPendingWidgetLink() resolves an
//  Outcome here, then performs it: this keeps ContentView's own code a thin dispatcher rather
//  than duplicating "which station, which map app, what if it's missing" decisions inline.
//

import Foundation

@MainActor
enum NearbyE85WidgetRouting {
    enum Outcome: Equatable {
        /// `.stations`, or a `.directions` request that resolved to nothing actionable (station
        /// no longer in the cache, or the widget wasn't authorized) — the tab switch that
        /// already happened in ContentView before this was resolved is the whole result.
        case switchToStations
        /// Hand off directly to the user's preferred map app — no intermediate screen.
        case openDirections(MapsRoutingDestination)
        /// The station exists but lacks enough location info for a direct handoff (should be
        /// unreachable in practice — snapshot stations are coordinate-validated at publish time
        /// — but a corrupted/stale cache shouldn't crash or silently no-op instead of showing
        /// something useful).
        case showStationDetail(NearbyE85Station, NearbyE85Snapshot)
    }

    static func resolve(_ destination: NearbyE85DeepLink.Destination, snapshot: NearbyE85Snapshot?,
                         isAuthorized: Bool) -> Outcome {
        switch destination {
        case .stations:
            return .switchToStations
        case .directions(let stationID):
            guard isAuthorized, let snapshot, let station = snapshot.stations.first(where: { $0.id == stationID }) else {
                return .switchToStations
            }
            let mapsDestination = MapsRoutingDestination(
                name: station.name, streetAddress: station.address, city: "", state: "", zip: "",
                latitude: station.latitude, longitude: station.longitude)
            guard mapsDestination.coordinate != nil || mapsDestination.addressQuery != nil else {
                return .showStationDetail(station, snapshot)
            }
            return .openDirections(mapsDestination)
        }
    }
}

/// 85Blends 2.4.0 Nearby E85 widget Pro gate — the pure, app-side decision ContentView makes
/// BEFORE it consumes a widget deep link (`openPendingWidgetLink()`). Reads the authoritative
/// entitlement (via `SubscriptionManager`, never the App Group mirror — the mirror is for the
/// widget extension only; see SharedNearbyE85/NearbyE85WidgetAccess.swift's header). Derived from
/// the exact same rule the mirror itself is published from (`NearbyE85WidgetAccessPublisher.
/// mirroredStatus`), so the widget's shell and the app's response to a tap on it can never
/// disagree about what "Pro", "Free", and "not yet known" mean.
nonisolated enum NearbyE85WidgetEntitlementRoute: Equatable {
    /// No authoritative answer yet (cold launch before RevenueCat's first CustomerInfo, or a
    /// launch where every fetch so far failed). ContentView keeps the pending URL and re-runs
    /// this decision when the entitlement inputs change — it never presents the paywall on the
    /// strength of "unknown," and never drops a Pro user's tap.
    case waitForEntitlement
    /// Pro (RevenueCat-confirmed, or Developer Override "Force Pro"): perform the widget's
    /// ordinary route (`NearbyE85WidgetRouting.resolve`) exactly as before this gate existed.
    case allowWidgetRoute
    /// Confirmed Free (a real CustomerInfo with no active `pro`, or "Force Free"): consume the
    /// URL and present the single 85Blends Pro paywall (`ProUpgradeView`, `.modal`) instead.
    case presentProPaywall

    static func resolve(mirroredStatus: NearbyE85WidgetAccessStatus?) -> Self {
        switch mirroredStatus {
        case nil, .unknown: return .waitForEntitlement
        case .pro: return .allowWidgetRoute
        case .free: return .presentProPaywall
        }
    }

    /// Plain-value form (unit-tested in NearbyE85WidgetProGateTests) — `isPro` is
    /// `SubscriptionManager.canAccessNearbyE85Widget`, the other two are the same inputs
    /// `NearbyE85WidgetAccessPublisher.mirroredStatus` takes.
    static func resolve(isPro: Bool, hasAuthoritativeProStatus: Bool, isDebugProOverrideActive: Bool) -> Self {
        resolve(mirroredStatus: NearbyE85WidgetAccessPublisher.mirroredStatus(
            isPro: isPro, hasAuthoritativeProStatus: hasAuthoritativeProStatus,
            isDebugProOverrideActive: isDebugProOverrideActive))
    }

    @MainActor
    static func resolve(for manager: SubscriptionManager) -> Self {
        resolve(mirroredStatus: NearbyE85WidgetAccessPublisher.mirroredStatus(for: manager))
    }
}

/// 85Blends 2.4.0 Pro gate — the pending-URL half of `ContentView.openPendingWidgetLink()`: given the
/// URL currently pending (if any) and the entitlement route, decides what happens to that URL on
/// THIS attempt. Pure, so the whole lifecycle is unit-testable (NearbyE85WidgetProGateTests): tap →
/// held while the entitlement is unknown → RevenueCat answers → the SAME URL is retried → consumed
/// exactly once, as either the ordinary widget route or the paywall. There is deliberately no
/// timer, counter, or retry loop here: ContentView re-attempts only from its existing trigger points
/// plus `.onChange(of: widgetEntitlementRoute)`, which fires on a route CHANGE, never on a plain
/// body re-evaluation.
nonisolated enum NearbyE85WidgetLinkGate {
    enum Action: Equatable {
        /// Nothing to do this attempt: either nothing is pending, or the entitlement isn't known yet
        /// — in which case `Step.pendingURL` is the SAME URL, still pending for a later attempt.
        case hold
        /// Consumed — present the 85Blends Pro paywall; no widget route is performed.
        case presentPaywall
        /// Consumed — perform the ordinary `NearbyE85WidgetRouting` outcome for the URL.
        case route
    }

    struct Step: Equatable {
        /// What ContentView stores back into `pendingWidgetURL`: unchanged while held, `nil` once
        /// consumed. This is the single point at which a widget URL is ever consumed.
        let pendingURL: URL?
        let action: Action
    }

    static func advance(pendingURL: URL?, route: NearbyE85WidgetEntitlementRoute) -> Step {
        guard let pendingURL else { return Step(pendingURL: nil, action: .hold) }
        switch route {
        case .waitForEntitlement: return Step(pendingURL: pendingURL, action: .hold)
        case .presentProPaywall: return Step(pendingURL: nil, action: .presentPaywall)
        case .allowWidgetRoute: return Step(pendingURL: nil, action: .route)
        }
    }
}

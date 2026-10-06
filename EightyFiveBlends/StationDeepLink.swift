//
//  StationDeepLink.swift
//  EightyFiveBlends
//
//  The navigation foundation for "open this station by its stable backend UUID" — what a Price
//  Alert notification tap needs. It extends the architecture the app already has rather than
//  adding a second one: a pending route held until the UI can act on it and consumed exactly once
//  (the same shape as ContentView's widget-link handling, NearbyE85WidgetLinkGate), handed to the
//  Stations tab through a small observable request object (the same shape as
//  PriceContributionPresentationRequest). There is no new navigation stack and no new screen.
//
//  Deliberately NOT built on NearbyE85DeepLink: that type is compiled into the widget extension,
//  its `Destination` is closed, and every URL passing through ContentView's widget path is held
//  behind the Pro/entitlement gate — none of which applies to a Price Alert tap.
//
//  Pure Foundation + Observation, so the whole lifecycle is unit-testable. See
//  EightyFiveBlendsTests/StationDeepLinkTests.swift.
//

import Foundation
import Observation

nonisolated enum AppRoute: Equatable, Sendable {
    /// Open the station the community backend knows by this UUID (`community_stations.id`).
    /// The UUID is the ONLY lookup key — never a name, address or coordinate.
    case station(communityStationID: UUID)
}

/// Decides, each time ContentView asks, whether a pending route may be acted on yet. Pure, so the
/// pending-route lifecycle (held while the UI is busy → consumed exactly once) is tested instead of
/// implied by view code. Mirrors NearbyE85WidgetLinkGate.
nonisolated enum StationLinkGate {
    enum Action: Equatable, Sendable {
        /// Nothing to do this attempt: nothing is pending, or the UI is not ready — in which case
        /// `Step.pending` is the SAME route, still pending for a later attempt.
        case hold
        /// Consumed — bring this station into view.
        case openStation(communityStationID: UUID)
    }

    struct Step: Equatable, Sendable {
        /// What the caller stores back as the pending route: unchanged while held, `nil` once
        /// consumed. This is the single point at which a route is ever consumed.
        let pending: AppRoute?
        let action: Action
    }

    /// The UI conditions mirror the ones ContentView's widget-link handling already waits for, so
    /// a notification tap never lands on top of onboarding, a What's New sheet, or the required
    /// ad-consent flow. There is deliberately no timer, counter or retry here: the caller re-asks
    /// only when one of those conditions changes.
    static func advance(
        pending: AppRoute?,
        hasCompletedOnboarding: Bool,
        isShowingWhatsNew: Bool,
        isConsentResolutionPending: Bool
    ) -> Step {
        guard let pending else { return Step(pending: nil, action: .hold) }
        guard hasCompletedOnboarding, isShowingWhatsNew == false, isConsentResolutionPending == false else {
            return Step(pending: pending, action: .hold)
        }
        switch pending {
        case .station(let communityStationID):
            return Step(pending: nil, action: .openStation(communityStationID: communityStationID))
        }
    }
}

/// Finds the saved station a route refers to. The match is by `communityStationID` alone.
nonisolated enum StationDeepLinkResolver {
    /// Index of the first saved station carrying `communityStationID`, or `nil` if none does
    /// (never saved on this device, deleted, or its UUID was discarded after an edit). The
    /// caller's list is already ordered most-recently-updated first, so if a duplicate ever
    /// exists the freshest one wins.
    static func firstMatchIndex(for communityStationID: UUID, in savedStationIDs: [UUID?]) -> Int? {
        savedStationIDs.firstIndex { $0 == communityStationID }
    }
}

/// The two-stage hand-off from "a notification was tapped" to "the Stations tab is showing that
/// station": the router submits an `inbound` route; ContentView drains it once the UI is ready,
/// which publishes a `focus` for StationsView to take. Purely transient, in-memory state — never
/// persisted. Same coordination style as PriceContributionPresentationRequest.
@MainActor
@Observable
final class StationDeepLinkRequest {
    static let shared = StationDeepLinkRequest()

    /// A route that has arrived but not yet been acted on. Survives a cold start (the router
    /// delivers it before any view exists) until ContentView drains it.
    private(set) var inbound: AppRoute?
    /// A station the Stations tab should bring into view. Consumed by `takeFocus()`.
    private(set) var focus: UUID?

    init() {}

    /// Called by the notification router. Re-submitting the route that is already pending is a
    /// no-op, so a duplicate delivery of one tap cannot be acted on twice.
    func submit(_ route: AppRoute) {
        if inbound != route {
            inbound = route
        }
    }

    /// One drain attempt, made by ContentView whenever a condition it depends on may have changed.
    /// Returns the station ContentView should now bring into view (switching to the Stations tab),
    /// or `nil` when there is nothing to do yet. Calling it again right away returns `nil`: the
    /// route is consumed exactly once, so repeated calls cannot loop or navigate twice.
    @discardableResult
    func drain(
        hasCompletedOnboarding: Bool,
        isShowingWhatsNew: Bool,
        isConsentResolutionPending: Bool
    ) -> UUID? {
        let step = StationLinkGate.advance(
            pending: inbound,
            hasCompletedOnboarding: hasCompletedOnboarding,
            isShowingWhatsNew: isShowingWhatsNew,
            isConsentResolutionPending: isConsentResolutionPending
        )
        if inbound != step.pending {
            inbound = step.pending
        }
        switch step.action {
        case .hold:
            return nil
        case .openStation(let communityStationID):
            focus = communityStationID
            return communityStationID
        }
    }

    /// Consume-once read for the Stations tab: returns the station to bring into view and clears
    /// it, so nothing can re-apply it later.
    func takeFocus() -> UUID? {
        guard let pending = focus else { return nil }
        focus = nil
        return pending
    }
}

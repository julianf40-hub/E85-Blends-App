//
//  StationDeepLinkTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts iOS foundation — the stable-ID station route: AppRoute, the pure consume-once gate
//  (StationLinkGate), saved-station resolution by UUID (StationDeepLinkResolver) and the
//  observable hand-off object (StationDeepLinkRequest). All pure Foundation/Observation, so the
//  whole pending-route lifecycle is tested here rather than implied by ContentView's shape.
//  Mirrors NearbyE85WidgetProGateTests' approach to NearbyE85WidgetLinkGate.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct StationDeepLinkTests {
    private let stationID = UUID(uuidString: "738574C5-E64F-40D8-AD6D-21025B412505")!
    private let otherStationID = UUID(uuidString: "BE3216DD-23BB-41C1-AB00-1E6920A4BCF3")!

    private var route: AppRoute { .station(communityStationID: stationID) }

    // MARK: - Route creation

    @Test("A stable station UUID from a Price Alert tap creates the station route")
    func stationUUID_createsExpectedRoute() {
        let payload = AppNotificationPayload.priceAlert(PriceAlertNotificationPayload(stationID: stationID, observedPrice: 3.19))

        #expect(AppNotificationDisposition.resolve(payload, isDefaultAction: true) == .route(.station(communityStationID: stationID)))
        #expect(route == .station(communityStationID: stationID))
        #expect(route != .station(communityStationID: otherStationID))
    }

    @Test("A malformed or unrecognized notification produces no route")
    func malformedRoute_doesNotNavigate() {
        let ignored: [AppNotificationPayload] = [
            .malformedPriceAlert(.missingStationID),
            .malformedPriceAlert(.invalidStationID),
            .unrecognized,
        ]
        for payload in ignored {
            #expect(AppNotificationDisposition.resolve(payload, isDefaultAction: true) == .ignore)
        }
    }

    // MARK: - Resolution by UUID only

    @Test("A saved station is found by its community UUID")
    func resolver_findsSavedStationByUUID() {
        let saved: [UUID?] = [nil, otherStationID, stationID, nil]

        #expect(StationDeepLinkResolver.firstMatchIndex(for: stationID, in: saved) == 2)
        #expect(StationDeepLinkResolver.firstMatchIndex(for: otherStationID, in: saved) == 1)
    }

    @Test("A station the device does not know fails gracefully: no match, no crash")
    func resolver_unknownStationFailsGracefully() {
        #expect(StationDeepLinkResolver.firstMatchIndex(for: stationID, in: []) == nil)
        #expect(StationDeepLinkResolver.firstMatchIndex(for: stationID, in: [nil, nil]) == nil)
        #expect(StationDeepLinkResolver.firstMatchIndex(for: stationID, in: [otherStationID]) == nil)
    }

    @Test("Saved stations that never learned a UUID can never match a route")
    func resolver_stationsWithoutUUIDNeverMatch() {
        // The lookup key is the UUID alone: a station with no UUID cannot be matched by name,
        // address or position, however similar it looks.
        #expect(StationDeepLinkResolver.firstMatchIndex(for: stationID, in: [nil]) == nil)
    }

    @Test("If a duplicate ever exists, the first (most recently updated) saved station wins")
    func resolver_duplicatesResolveToFirst() {
        #expect(StationDeepLinkResolver.firstMatchIndex(for: stationID, in: [otherStationID, stationID, stationID]) == 1)
    }

    // MARK: - Gate

    @Test("Nothing pending: nothing happens")
    func gate_nothingPending() {
        let step = StationLinkGate.advance(
            pending: nil, hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false)

        #expect(step == StationLinkGate.Step(pending: nil, action: .hold))
    }

    @Test("A route is held, unchanged, while onboarding, What's New or ad consent is in the way")
    func gate_holdsWhileUIIsBusy() {
        let busy: [(onboarded: Bool, whatsNew: Bool, consentPending: Bool)] = [
            (false, false, false),
            (true, true, false),
            (true, false, true),
            (false, true, true),
        ]
        for state in busy {
            let step = StationLinkGate.advance(
                pending: route,
                hasCompletedOnboarding: state.onboarded,
                isShowingWhatsNew: state.whatsNew,
                isConsentResolutionPending: state.consentPending
            )
            #expect(step == StationLinkGate.Step(pending: route, action: .hold), "must hold for \(state)")
        }
    }

    @Test("When the UI is ready the route is consumed and the station opened")
    func gate_consumesWhenReady() {
        let step = StationLinkGate.advance(
            pending: route, hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false)

        #expect(step == StationLinkGate.Step(pending: nil, action: .openStation(communityStationID: stationID)))
    }

    // MARK: - Request lifecycle: consume once, no loop, no duplicate navigation

    @Test("A cold-start route is held until the UI is ready, then opens the station exactly once")
    func request_coldStartLifecycle() {
        let request = StationDeepLinkRequest()

        // The router delivers the tap before any view exists.
        request.submit(route)
        #expect(request.inbound == route)

        // Onboarding / What's New / consent in the way: held, however many times it is asked.
        for _ in 0..<3 {
            #expect(request.drain(hasCompletedOnboarding: false, isShowingWhatsNew: false, isConsentResolutionPending: false) == nil)
        }
        #expect(request.inbound == route)
        #expect(request.focus == nil)

        // The UI becomes ready: consumed, station published for the Stations tab.
        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == stationID)
        #expect(request.inbound == nil)
        #expect(request.focus == stationID)
    }

    @Test("Draining again after consumption does nothing — no loop, no second navigation")
    func request_repeatedDrainDoesNotNavigateTwice() {
        let request = StationDeepLinkRequest()
        request.submit(route)

        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == stationID)
        _ = request.takeFocus()

        for _ in 0..<5 {
            #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == nil)
        }
        #expect(request.inbound == nil)
        #expect(request.focus == nil)
    }

    @Test("A duplicate delivery of the same tap while it is pending coalesces into one navigation")
    func request_duplicateSubmissionCoalesces() {
        let request = StationDeepLinkRequest()

        request.submit(route)
        request.submit(route)

        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == stationID)
        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == nil)
    }

    @Test("A genuinely new tap after the first was handled is handled too")
    func request_laterTapIsNotSwallowed() {
        let request = StationDeepLinkRequest()

        request.submit(route)
        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == stationID)
        _ = request.takeFocus()

        request.submit(route)
        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == stationID)
    }

    @Test("The newest of two different pending routes wins")
    func request_newestRouteWins() {
        let request = StationDeepLinkRequest()

        request.submit(route)
        request.submit(.station(communityStationID: otherStationID))

        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == otherStationID)
        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == nil)
    }

    @Test("The focus is consumed once by the Stations tab and cannot be re-applied")
    func request_focusIsConsumedOnce() {
        let request = StationDeepLinkRequest()
        request.submit(route)
        _ = request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false)

        #expect(request.takeFocus() == stationID)
        #expect(request.takeFocus() == nil)
    }

    @Test("With nothing submitted, draining and taking focus never navigate")
    func request_idleNeverNavigates() {
        let request = StationDeepLinkRequest()

        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == nil)
        #expect(request.takeFocus() == nil)
        #expect(request.inbound == nil)
        #expect(request.focus == nil)
    }
}

//
//  PriceAlertsNavigationTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts UI (Phase 3B) — the notification-tap navigation foundation (AppNotificationPayload,
//  StationDeepLinkRequest) still works exactly as before, runs once without looping, and names the
//  SAME station identity the Price Alert bell and sheet use: `community_stations.id`.
//
//  Phase 3B changes none of the navigation files; this ties the two halves together so a change to
//  either side that broke the hand-off would fail here. The router class itself
//  (AppNotificationRouter, which needs UserNotifications) is covered by AppNotificationRouterTests.
//
//  Pure value logic plus the Phase 3A fakes. No network, no Keychain, no UI.
//

import Foundation
import Testing
@testable import EightyFiveBlends

private let tappedStationID = PriceAlertsStack.stationID(7)

/// The userInfo iOS hands the delegate for a worker-sent Price Alert (see AppNotificationPayload).
private func priceAlertUserInfo(station: UUID) -> [AnyHashable: Any] {
    [
        "aps": ["alert": ["title": "Price drop", "body": "Corner Pump is now $3.19"], "sound": "default"],
        "type": "price_alert",
        "station_id": station.uuidString.lowercased(),
        "observed_price": 3.19,
    ]
}

struct PriceAlertsNavigationTests {
    @Test("A Price Alert tap routes to its station once; a duplicate delivery or a repeated drain cannot navigate twice")
    func tap_routesOnce() throws {
        let request = StationDeepLinkRequest()
        let payload = AppNotificationPayload.classify(priceAlertUserInfo(station: tappedStationID))
        let disposition = AppNotificationDisposition.resolve(payload, isDefaultAction: true)
        guard case .route(let route) = disposition else {
            Issue.record("a Price Alert tap should route, got \(disposition)")
            return
        }

        request.submit(route)
        request.submit(route)   // the same tap delivered twice
        let first = request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false)
        let second = request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false)

        #expect(first == tappedStationID)
        #expect(second == nil)
        #expect(request.takeFocus() == tappedStationID)
        #expect(request.takeFocus() == nil)
        #expect(request.inbound == nil)
    }

    @Test("The station a notification names is the station the Price Alert sheet is keyed by")
    func notificationIdentity_isTheSheetsIdentity() async throws {
        let stack = PriceAlertsStack(push: .registered(FakePushState.token(1)))
        let payload = AppNotificationPayload.classify(priceAlertUserInfo(station: tappedStationID))
        guard case .priceAlert(let alert) = payload else {
            Issue.record("expected a Price Alert payload, got \(payload)")
            return
        }

        // Bringing the tapped station into view and opening its alert use the one identity.
        let target = try #require(PriceAlertStationTarget(communityStationID: alert.stationID, name: "Corner Pump"))
        let model = PriceAlertsStationModel(target: target, service: stack.service)
        await model.load()
        await model.save()

        #expect(target.communityStationID == tappedStationID)
        let sent = try #require(stack.transport.lastRequest("set_alert")?.json["station_id"] as? String)
        #expect(sent == tappedStationID.uuidString.lowercased())
        #expect(stack.service.alerts.map(\.alert.stationID) == [tappedStationID])
    }

    @Test("Malformed or unrelated payloads open nothing: no route, so no station and no sheet")
    func malformedPayloads_openNothing() {
        let request = StationDeepLinkRequest()
        let payloads: [[AnyHashable: Any]] = [
            ["type": "price_alert"],                                   // no station
            ["type": "price_alert", "station_id": "not-a-uuid"],       // not a UUID
            ["type": "price_alert", "station_id": 42],                 // wrong type
            ["type": "something_else", "station_id": tappedStationID.uuidString],
            [:],
        ]
        for userInfo in payloads {
            let disposition = AppNotificationDisposition.resolve(AppNotificationPayload.classify(userInfo), isDefaultAction: true)
            #expect(disposition == .ignore)
        }
        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == nil)
    }

    @Test("A route is held, not lost, while onboarding or What's New is up, and then still consumed exactly once")
    func route_isHeldThenConsumedOnce() {
        let request = StationDeepLinkRequest()
        request.submit(.station(communityStationID: tappedStationID))

        #expect(request.drain(hasCompletedOnboarding: false, isShowingWhatsNew: false, isConsentResolutionPending: false) == nil)
        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: true, isConsentResolutionPending: false) == nil)
        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == tappedStationID)
        #expect(request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false) == nil)
    }
}

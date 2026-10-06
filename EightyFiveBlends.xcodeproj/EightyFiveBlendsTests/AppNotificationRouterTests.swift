//
//  AppNotificationRouterTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts iOS foundation — AppNotificationRouter, the app's single
//  UNUserNotificationCenterDelegate. Everything decision-bearing is pure and covered in
//  AppNotificationPayloadTests.swift; this file covers the thin layer that performs the decision
//  and the invariant the whole design rests on: exactly one delegate, installed at launch.
//
//  The test target is app-hosted, so by the time these run the real EightyFiveBlendsApp.init() has
//  already executed — including AutomaticPumpDetectionService.attach(to:), which installs the
//  router. A system `UNNotificationResponse` cannot be constructed in a unit test, so the
//  delegate callbacks themselves are exercised on device; `apply(_:)` takes the already-made
//  decision and is what these tests drive.
//
//  Suite is serialized: it touches process-wide singletons (the notification center, the router,
//  StationDeepLinkRequest.shared), and restores whatever it changes.
//

import Foundation
import Testing
import UserNotifications
@testable import EightyFiveBlends

@Suite(.serialized)
struct AppNotificationRouterTests {
    private let stationID = UUID(uuidString: "738574C5-E64F-40D8-AD6D-21025B412505")!

    /// Leaves the shared hand-off object empty, so tests cannot affect each other or the host app.
    private func clearSharedRequest() {
        let request = StationDeepLinkRequest.shared
        request.drain(hasCompletedOnboarding: true, isShowingWhatsNew: false, isConsentResolutionPending: false)
        _ = request.takeFocus()
    }

    // MARK: - One delegate, installed at launch

    @Test("After launch the router is the notification center's delegate — nothing displaced it")
    func router_isTheOnlyDelegateAfterLaunch() {
        // Nothing here installs it: launch already did. If another object ever assigns itself as
        // the delegate, it displaces the router and this fails.
        #expect(UNUserNotificationCenter.current().delegate === AppNotificationRouter.shared)
    }

    @Test("Automatic Pump Detection handed its tap handling to the router at launch")
    func pumpDetection_isWiredIntoTheRouter() {
        #expect(AppNotificationRouter.shared.pumpArrivalHandler != nil)
    }

    @Test("Installing again is harmless and keeps the router as the delegate")
    func install_isIdempotent() {
        AppNotificationRouter.shared.installAsNotificationCenterDelegate()
        AppNotificationRouter.shared.installAsNotificationCenterDelegate()

        #expect(UNUserNotificationCenter.current().delegate === AppNotificationRouter.shared)
    }

    // MARK: - Performing a decision

    @Test("A route decision is submitted for ContentView to drain")
    func apply_route_submitsTheRoute() {
        clearSharedRequest()
        defer { clearSharedRequest() }

        AppNotificationRouter.shared.apply(.route(.station(communityStationID: stationID)))

        #expect(StationDeepLinkRequest.shared.inbound == .station(communityStationID: stationID))
    }

    @Test("A pump decision reaches the registered handler with the station record id, once")
    func apply_forward_callsPumpHandler() {
        let router = AppNotificationRouter.shared
        let original = router.pumpArrivalHandler
        defer { router.pumpArrivalHandler = original }

        var received: [String] = []
        router.pumpArrivalHandler = { received.append($0) }

        router.apply(.forwardToPumpDetection(stationRecordID: "station:shell|39.96000|-83.00000"))

        #expect(received == ["station:shell|39.96000|-83.00000"])
    }

    @Test("An ignore decision does nothing at all")
    func apply_ignore_doesNothing() {
        clearSharedRequest()
        let router = AppNotificationRouter.shared
        let original = router.pumpArrivalHandler
        defer { router.pumpArrivalHandler = original }

        var pumpCalls = 0
        router.pumpArrivalHandler = { _ in pumpCalls += 1 }

        router.apply(.ignore)

        #expect(pumpCalls == 0)
        #expect(StationDeepLinkRequest.shared.inbound == nil)
    }

    @Test("A pump decision with no handler registered is harmless")
    func apply_forward_withoutHandlerIsHarmless() {
        let router = AppNotificationRouter.shared
        let original = router.pumpArrivalHandler
        defer { router.pumpArrivalHandler = original }
        router.pumpArrivalHandler = nil

        router.apply(.forwardToPumpDetection(stationRecordID: "station:shell"))

        #expect(StationDeepLinkRequest.shared.inbound == nil)
    }
}

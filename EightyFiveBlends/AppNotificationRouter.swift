//
//  AppNotificationRouter.swift
//  EightyFiveBlends
//
//  The app's ONE UNUserNotificationCenterDelegate. `UNUserNotificationCenter.delegate` is a single
//  slot: two objects each assigning themselves would silently displace one another, and the loser
//  would stop receiving every tap. Before this file the only delegate was
//  AutomaticPumpDetectionService, which dropped any notification that was not its own — so a Price
//  Alert tap would have vanished. Everything now enters here:
//
//    - AppNotificationPayload (pure) classifies the notification's `userInfo`;
//    - AppNotificationDisposition (pure) decides what a tap should do;
//    - this class only performs that decision:
//        .route                  -> StationDeepLinkRequest (ContentView drains it once the UI is ready)
//        .forwardToPumpDetection -> AutomaticPumpDetectionService, via `pumpArrivalHandler`
//        .ignore                 -> nothing
//
//  Behavior that was already shipped is preserved exactly: a notification shown while the app is in
//  the foreground still presents as a banner with sound in the list (what the pump delegate did for
//  every notification), and a tap on an arrival notification still reaches
//  `AutomaticPumpDetectionService.handleNotificationOpened`, which still sets
//  `pendingDetectedStation`. Malformed or unknown payloads are ignored — they cannot crash, and
//  they cannot navigate.
//
//  Installation is idempotent and cheap: `installAsNotificationCenterDelegate()` is called from
//  AutomaticPumpDetectionService.attach(to:) during App.init (the same early moment the old
//  delegate assignment happened, so a notification that launches the app is never missed) and again
//  from AppDelegate.application(_:didFinishLaunchingWithOptions:). Nothing else in the app may
//  assign `UNUserNotificationCenter.current().delegate`.
//

import Foundation
import UserNotifications

@MainActor
final class AppNotificationRouter: NSObject {
    static let shared = AppNotificationRouter()

    /// Set by AutomaticPumpDetectionService.attach(to:). Receives the `stationRecordID` of a tapped
    /// Automatic Pump Detection arrival notification. Explicitly `@MainActor`: the router only ever
    /// calls it from `apply(_:)`, which is main-actor, and the service's handler touches
    /// main-actor state — stating that in the type removes any reliance on closure-isolation inference.
    var pumpArrivalHandler: (@MainActor (String) -> Void)?

    private override init() {
        super.init()
    }

    /// Makes this object the notification center's delegate. Safe to call any number of times.
    func installAsNotificationCenterDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Performs a decision made by `AppNotificationDisposition.resolve`.
    func apply(_ disposition: AppNotificationDisposition) {
        switch disposition {
        case .route(let route):
            StationDeepLinkRequest.shared.submit(route)
        case .forwardToPumpDetection(let stationRecordID):
            pumpArrivalHandler?(stationRecordID)
        case .ignore:
            break
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppNotificationRouter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Notification ARRIVES while the app is in the foreground. Unchanged from the pump
        // delegate this replaces, which presented every notification this way: show it plainly
        // rather than silently dropping it. A Price Alert shown here is acted on only if the user
        // then taps it (see didReceive below) — merely arriving never navigates.
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Classification and the decision are pure and `nonisolated`, so they run here, off the
        // main actor where the system delivers this callback, before hopping to it to act. Only
        // the small Sendable decision crosses the hop — never the raw `userInfo`.
        let payload = AppNotificationPayload.classify(response.notification.request.content.userInfo)
        let isDefaultAction = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let disposition = AppNotificationDisposition.resolve(payload, isDefaultAction: isDefaultAction)

        // Nothing to perform (an unrecognized or malformed payload, or a non-default action on a
        // Price Alert): finish now instead of queueing a main-actor hop that has no work to do.
        if disposition == .ignore {
            completionHandler()
            return
        }

        Task { @MainActor [weak self] in
            self?.apply(disposition)
            completionHandler()
        }
    }
}

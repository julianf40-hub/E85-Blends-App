//
//  AppDelegate.swift
//  EightyFiveBlends
//
//  A deliberately minimal UIApplicationDelegate, attached with `@UIApplicationDelegateAdaptor` in
//  EightyFiveBlendsApp. SwiftUI has no native hook for the APNs registration callbacks —
//  `didRegisterForRemoteNotificationsWithDeviceToken` and
//  `didFailToRegisterForRemoteNotificationsWithError` are delivered only to a
//  UIApplicationDelegate — so this adaptor is the smallest thing that can receive them. Nothing else
//  lives here: no app startup work moved, nothing else changed hands.
//
//  Launch behavior is unchanged for every existing user: this file does not ask for notification
//  permission and does not call `registerForRemoteNotifications()`. See PushRegistrationService.
//
//  One thing is forwarded beyond the token itself (2.4.1): when the OS delivers a token the app was
//  not already holding, Price Alerts is told, so a rotated token reaches the backend without waiting
//  for the next time the app becomes active. See the callback below for why that is loop-free.
//

import Foundation
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Already done during App.init via AutomaticPumpDetectionService.attach(to:); repeated
        // here so the router is the notification delegate however launch unfolds. Idempotent.
        AppNotificationRouter.shared.installAsNotificationCenterDelegate()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let push = PushRegistrationService.shared
        let previousToken = push.currentToken
        push.handleDeviceToken(deviceToken)

        // 85Blends 2.4.1 Price Alerts. The OS answers EVERY registerForRemoteNotifications() with the
        // current token — including the one the app-active reconcile makes — so only a token that
        // differs from the one held (or the first) is news. Reacting to an unchanged one would let a
        // reconcile's own OS request start the next reconcile. And that reconcile
        // (reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered) does not ask the OS for
        // anything, does nothing at all for an install that never turned notifications on, never
        // prompts, and runs on a Task so this callback returns at once.
        guard PushTokenChange.isNewToken(previous: previousToken, current: push.currentToken) else { return }
        Task {
            _ = await PriceAlertsService.shared.reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered()
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushRegistrationService.shared.handleRegistrationFailure(error)
    }
}

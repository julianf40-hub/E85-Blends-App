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
        PushRegistrationService.shared.handleDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushRegistrationService.shared.handleRegistrationFailure(error)
    }
}

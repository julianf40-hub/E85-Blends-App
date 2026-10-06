//
//  UIKitPushRegistrationSystem.swift
//  EightyFiveBlends
//
//  The production implementation of PushRegistrationSystem — the only place the push-registration
//  foundation touches UserNotifications and UIKit. Deliberately free of decisions: every branch
//  worth testing lives in PushRegistrationService, which is exercised against a fake. This file
//  only translates three system calls.
//
//  Permission handling mirrors the pattern AutomaticPumpDetectionService already uses
//  (`notificationSettings()` first; prompt only when `.notDetermined`), so the two features agree
//  about what has already been asked. The prompt requests only `.alert` and `.sound` — all a Price
//  Alert push uses (see price-alerts-worker `sendApns`: `aps.alert` + `sound`). If the user already
//  answered a prompt raised by Automatic Pump Detection, `requestAuthorization` is never reached.
//

import UIKit
import UserNotifications

final class UIKitPushRegistrationSystem: PushRegistrationSystem {
    func authorizationStatus() async -> PushAuthorizationStatus {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            // An unknown future status is never treated as permission to prompt or register.
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

extension PushRegistrationService {
    /// The app's single registration service. Nothing reads or drives it at launch; the
    /// AppDelegate forwards the two APNs callbacks to it and a later Price Alerts flow decides
    /// when to ask for permission.
    static let shared = PushRegistrationService(system: UIKitPushRegistrationSystem())
}

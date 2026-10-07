//
//  PushRegistrationService+PriceAlerts.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). Lets the Price Alerts device
//  registrar read and drive the existing PushRegistrationService through a narrow protocol, so the
//  registrar can be tested against a fake while production uses the real service unchanged.
//  PushRegistrationService itself is not modified: its permission, token-capture and no-persistence
//  rules (see its header) are exactly what this builds on.
//

import Foundation

extension PushRegistrationService: PriceAlertsPushStateProviding {
    var pushState: PushRegistrationState {
        state
    }
}

/// Whether an APNs token callback delivered a token this process was not already holding.
///
/// The AppDelegate asks this to decide whether to re-register with Price Alerts. It must be a real
/// change, because the OS calls back with the SAME token every time `registerForRemoteNotifications()`
/// is called — including the call the app-active reconcile makes on every foreground. If an unchanged
/// token started a reconcile, that reconcile's own OS request would produce another callback, and
/// another reconcile: a loop. Only a token that differs from the one held (or the first one) is news.
nonisolated enum PushTokenChange {
    static func isNewToken(previous: PushDeviceToken?, current: PushDeviceToken?) -> Bool {
        guard let current else { return false }
        return current != previous
    }
}

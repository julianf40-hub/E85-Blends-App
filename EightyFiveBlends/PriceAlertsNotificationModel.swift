//
//  PriceAlertsNotificationModel.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts UI (Phase 3B). The state behind the "Notifications" card shown in the
//  Price Alert sheet and on the Price Alerts overview. Foundation + Observation only.
//
//  USER-INITIATED, ALWAYS. The ONLY thing here that starts notification registration — and with it the
//  system permission prompt, if the person was never asked — is `turnOnNotifications()`, and only a
//  button tap calls that. Opening a screen, loading alerts, saving one and turning one off never do:
//  a person who allowed notifications for another feature (pump arrival alerts) must not be silently
//  registered for Price Alerts just because they looked at a station. (No SwiftUI file calls
//  UNUserNotificationCenter or registerForRemoteNotifications either; this goes through
//  PriceAlertsService.enablePushDelivery(), which goes through PushRegistrationService.)
//
//  NO COPY OF THE STATE. What the card shows is derived, every time, from the service's most recent
//  registration outcome (the person's own attempt, or the app-level reconcile when the app became
//  active) plus the local record that this device registered before. When the app foregrounds after the
//  person switched notifications off in Settings, the reconcile's outcome flips the card with no help
//  from this class.
//

import Foundation
import Observation

@MainActor
@Observable
final class PriceAlertsNotificationModel {
    private let service: any PriceAlertsServing

    /// An opt-in started from this model is in flight (so the card shows progress and cannot be
    /// tapped twice).
    private(set) var isEnabling = false

    init(service: any PriceAlertsServing) {
        self.service = service
    }

    var presentation: PriceAlertsNotificationPresentation {
        PriceAlertsNotificationPresentation.make(
            isEnabling: isEnabling,
            lastOutcome: service.lastDeviceRegistrationOutcome,
            hasRegisteredDevice: service.hasRegisteredDevice
        )
    }

    /// The person tapped "Turn On Notifications" (or "Try Again"). Asks for permission only if they
    /// were never asked, waits briefly for the OS token and registers it. The outcome lands in the
    /// service and `presentation` follows. A second tap while this runs does nothing.
    func turnOnNotifications() async {
        guard isEnabling == false else { return }
        isEnabling = true
        defer { isEnabling = false }
        _ = await service.enablePushDelivery()
    }
}

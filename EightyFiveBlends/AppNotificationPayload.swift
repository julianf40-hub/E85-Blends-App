//
//  AppNotificationPayload.swift
//  EightyFiveBlends
//
//  Pure decision step for every notification the app can receive: what is this payload, and what
//  should tapping it do? Kept free of UserNotifications/UIKit so the whole decision is directly
//  unit-testable — AppNotificationRouter (the app's single UNUserNotificationCenterDelegate) only
//  feeds it `userInfo` and performs the result. See
//  EightyFiveBlendsTests/AppNotificationPayloadTests.swift.
//
//  THE PRICE ALERT PAYLOAD IS THE BACKEND'S CONTRACT, NOT A GUESS. It is exactly what
//  supabase/functions/price-alerts-worker/index.ts `sendApns` sends:
//
//      { "aps": { "alert": { "title", "body" }, "sound": "default" },
//        "type": "price_alert",
//        "station_id": "<community_stations.id UUID string>",
//        "observed_price": <JSON number> }
//
//  Notably there is NO `alert_id` — the worker does not send one — so nothing here requires or
//  looks for it. `station_id` is the only field a tap needs; `observed_price` is informational
//  and optional. (The Android/FCM `data` map carries the same keys, with `observed_price` as a
//  string; the parser tolerates that too.) If the worker's payload ever changes, change this file
//  and its tests together.
//
//  The other payload recognized is the app's own Automatic Pump Detection arrival notification
//  (AutomaticPumpDetectionService.scheduleArrivalNotification). Its key/value literals are defined
//  here ONCE and that service builds its `userInfo` from the same constants, so the notification
//  it schedules and the router that handles its tap cannot drift apart. They must also stay equal
//  to the strings already shipped: a notification delivered by an earlier build can still be tapped
//  after an update.
//

import Foundation

/// A recognized, usable Price Alert payload.
nonisolated struct PriceAlertNotificationPayload: Equatable, Sendable {
    /// `community_stations.id` — the only stable identity a Price Alert has. Never derived from a
    /// name, address or coordinate.
    let stationID: UUID
    /// The price that triggered the alert, when the payload carried a usable one. Informational.
    let observedPrice: Double?
}

/// Why a payload that CLAIMS to be a Price Alert cannot be acted on.
nonisolated enum PriceAlertPayloadIssue: Equatable, Sendable {
    case missingStationID
    case invalidStationID
}

nonisolated enum AppNotificationPayload: Equatable, Sendable {
    /// `type == "price_alert"` with a valid `station_id`.
    case priceAlert(PriceAlertNotificationPayload)
    /// `type == "price_alert"` but unusable. Must never navigate anywhere and must never crash.
    case malformedPriceAlert(PriceAlertPayloadIssue)
    /// The app's own Automatic Pump Detection arrival notification.
    case automaticPumpDetection(stationRecordID: String)
    /// Anything else: another notification, an unknown `type`, no `type`, no payload at all.
    case unrecognized

    // MARK: Keys and values

    static let typeKey = "type"

    static let priceAlertTypeValue = "price_alert"
    static let priceAlertStationIDKey = "station_id"
    static let priceAlertObservedPriceKey = "observed_price"

    // Must stay byte-identical to what earlier builds already scheduled.
    static let pumpArrivalTypeValue = "automaticPumpDetection"
    static let pumpArrivalStationRecordIDKey = "stationRecordID"

    // MARK: Classification

    /// Classifies a notification's `userInfo`. Total: every input — empty, wrong types, NSNull,
    /// nested garbage — maps to a case without trapping.
    ///
    /// Called from the notification-center delegate callbacks, which the system delivers off the
    /// main actor, hence `nonisolated` on the enclosing type.
    static func classify(_ userInfo: [AnyHashable: Any]) -> AppNotificationPayload {
        guard let type = userInfo[typeKey] as? String else {
            return .unrecognized
        }

        if type == priceAlertTypeValue {
            return classifyPriceAlert(userInfo)
        }

        if type == pumpArrivalTypeValue {
            // Same rule the pump delegate always applied: both the type and the station record id
            // must be present, otherwise the notification is ignored.
            guard let stationRecordID = userInfo[pumpArrivalStationRecordIDKey] as? String else {
                return .unrecognized
            }
            return .automaticPumpDetection(stationRecordID: stationRecordID)
        }

        return .unrecognized
    }

    private static func classifyPriceAlert(_ userInfo: [AnyHashable: Any]) -> AppNotificationPayload {
        guard let rawStationID = userInfo[priceAlertStationIDKey] else {
            return .malformedPriceAlert(.missingStationID)
        }
        // `UUID(uuidString:)` is the whole validation: it accepts upper- or lower-case canonical
        // 8-4-4-4-12 hex and nothing else (no trimming, no braces, no "close enough").
        guard let stationIDText = rawStationID as? String, let stationID = UUID(uuidString: stationIDText) else {
            return .malformedPriceAlert(.invalidStationID)
        }
        return .priceAlert(
            PriceAlertNotificationPayload(
                stationID: stationID,
                observedPrice: observedPrice(from: userInfo[priceAlertObservedPriceKey])
            )
        )
    }

    /// `observed_price` is informational, so anything unusable is simply `nil` — it never
    /// invalidates an otherwise good payload. APNs sends a JSON number; FCM's `data` map sends a
    /// string.
    private static func observedPrice(from value: Any?) -> Double? {
        let parsed: Double?
        switch value {
        case let number as Double:
            parsed = number
        case let number as Int:
            parsed = Double(number)
        case let text as String:
            parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            parsed = nil
        }
        guard let price = parsed, price.isFinite, price > 0 else { return nil }
        return price
    }
}

/// What the router should DO with a classified notification — the pure half of handling a tap.
nonisolated enum AppNotificationDisposition: Equatable, Sendable {
    /// Navigate. Today only Price Alerts produce a route.
    case route(AppRoute)
    /// Hand the tap to Automatic Pump Detection, exactly as its own delegate always did.
    case forwardToPumpDetection(stationRecordID: String)
    /// Do nothing: unrecognized, malformed, or not a plain tap.
    case ignore

    /// - Parameter isDefaultAction: whether the user tapped the notification itself (as opposed to
    ///   a custom action button or a dismissal). A Price Alert only navigates on a plain tap. The
    ///   pump notification ignores this on purpose — it never registered custom actions, and its
    ///   existing behavior is preserved exactly.
    static func resolve(_ payload: AppNotificationPayload, isDefaultAction: Bool) -> AppNotificationDisposition {
        switch payload {
        case .priceAlert(let alert):
            guard isDefaultAction else { return .ignore }
            return .route(.station(communityStationID: alert.stationID))
        case .automaticPumpDetection(let stationRecordID):
            return .forwardToPumpDetection(stationRecordID: stationRecordID)
        case .malformedPriceAlert, .unrecognized:
            return .ignore
        }
    }
}

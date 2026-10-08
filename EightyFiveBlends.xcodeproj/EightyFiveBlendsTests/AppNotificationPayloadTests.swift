//
//  AppNotificationPayloadTests.swift
//  EightyFiveBlendsTests
//
//  Price Alerts iOS foundation — the pure classification of a notification's `userInfo`
//  (AppNotificationPayload) and the decision of what a tap should do (AppNotificationDisposition).
//  AppNotificationRouter, the UNUserNotificationCenterDelegate that feeds these, is deliberately
//  thin and is covered by AppNotificationRouterTests.swift.
//
//  The Price Alert fixtures below are the exact shape supabase/functions/price-alerts-worker/
//  index.ts `sendApns` builds: top-level `type`, `station_id` and `observed_price` next to `aps`,
//  and NO `alert_id`. If that worker contract changes, these tests must change with it.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct AppNotificationPayloadTests {
    private let stationID = UUID(uuidString: "738574C5-E64F-40D8-AD6D-21025B412505")!

    /// The userInfo iOS hands the delegate for a worker-sent Price Alert.
    private func workerPriceAlert(
        stationID: Any? = "738574c5-e64f-40d8-ad6d-21025b412505",
        observedPrice: Any? = 3.19
    ) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "E85 price dropped", "body": "Shell dropped to $3.19/gal."], "sound": "default"],
            "type": "price_alert",
        ]
        if let stationID { userInfo["station_id"] = stationID }
        if let observedPrice { userInfo["observed_price"] = observedPrice }
        return userInfo
    }

    /// Delegate callbacks are delivered off the main actor, so classification must be callable
    /// from a nonisolated context. This helper only compiles if it is.
    private nonisolated func classifyFromDelegateContext(_ userInfo: [AnyHashable: Any]) -> AppNotificationPayload {
        AppNotificationPayload.classify(userInfo)
    }

    // MARK: - Valid Price Alert

    @Test("A worker-sent Price Alert payload parses into its station and price")
    func validPriceAlert_parses() {
        let payload = classifyFromDelegateContext(workerPriceAlert())

        #expect(payload == .priceAlert(PriceAlertNotificationPayload(stationID: stationID, observedPrice: 3.19)))
    }

    @Test("The station UUID parses in the case Postgres emits and in upper case alike")
    func validStationUUID_parsesCaseInsensitively() {
        let lower = classifyFromDelegateContext(workerPriceAlert(stationID: stationID.uuidString.lowercased()))
        let upper = classifyFromDelegateContext(workerPriceAlert(stationID: stationID.uuidString.uppercased()))

        #expect(lower == upper)
        #expect(lower == .priceAlert(PriceAlertNotificationPayload(stationID: stationID, observedPrice: 3.19)))
    }

    @Test("A Price Alert needs nothing beyond type and station_id — in particular no alert_id")
    func priceAlert_requiresOnlyTypeAndStationID() {
        let minimal: [AnyHashable: Any] = ["type": "price_alert", "station_id": stationID.uuidString]

        #expect(classifyFromDelegateContext(minimal) == .priceAlert(PriceAlertNotificationPayload(stationID: stationID, observedPrice: nil)))
        #expect(workerPriceAlert()["alert_id"] == nil)
    }

    @Test("observed_price is informational: numbers and numeric strings parse, anything else is dropped without failing the alert")
    func observedPrice_isTolerantAndNeverInvalidatesTheAlert() {
        func price(_ value: Any?) -> Double?? {
            guard case .priceAlert(let alert) = classifyFromDelegateContext(workerPriceAlert(observedPrice: value)) else { return .none }
            return .some(alert.observedPrice)
        }

        #expect(price(3.19) == .some(3.19))
        #expect(price(3) == .some(3.0))
        #expect(price("3.19") == .some(3.19))
        #expect(price(" 3.19 ") == .some(3.19))
        // Unusable prices leave the alert itself intact, with no price.
        #expect(price("cheap") == .some(nil))
        #expect(price(-1.0) == .some(nil))
        #expect(price(0.0) == .some(nil))
        #expect(price(Double.nan) == .some(nil))
        #expect(price(Double.infinity) == .some(nil))
        #expect(price(["nested": 1]) == .some(nil))
        #expect(price(nil) == .some(nil))
    }

    // MARK: - Malformed UUID

    @Test("A malformed station_id is rejected as malformed, never routed")
    func malformedStationUUID_isRejectedSafely() {
        let malformed: [Any] = [
            "not-a-uuid",
            "",
            "   ",
            "738574c5e64f40d8ad6d21025b412505",             // no hyphens
            "{738574c5-e64f-40d8-ad6d-21025b412505}",        // braces
            " 738574c5-e64f-40d8-ad6d-21025b412505",         // leading space
            "738574c5-e64f-40d8-ad6d-21025b41250",           // one character short
            "738574c5-e64f-40d8-ad6d-21025b4125055",         // one character long
            "ZZZZZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZZZZZZZZZ",         // right shape, not hex
            12345,
            ["738574c5-e64f-40d8-ad6d-21025b412505"],
            NSNull(),
        ]

        for value in malformed {
            #expect(
                classifyFromDelegateContext(workerPriceAlert(stationID: value)) == .malformedPriceAlert(.invalidStationID),
                "station_id \(String(describing: value)) must be rejected"
            )
            #expect(
                AppNotificationDisposition.resolve(classifyFromDelegateContext(workerPriceAlert(stationID: value)), isDefaultAction: true) == .ignore
            )
        }
    }

    // MARK: - Wrong type / missing fields

    @Test("Any other notification type is ignored, not mistaken for a Price Alert")
    func wrongType_isUnrecognized() {
        for type in ["price_alert_v2", "PRICE_ALERT", "Price_Alert", "price-alert", "priceAlert", "", " price_alert", "other"] {
            let userInfo: [AnyHashable: Any] = ["type": type, "station_id": stationID.uuidString]
            #expect(classifyFromDelegateContext(userInfo) == .unrecognized, "type \(type) must not be recognized")
        }
        // A non-string type is not a type at all.
        #expect(classifyFromDelegateContext(["type": 7, "station_id": stationID.uuidString]) == .unrecognized)
        #expect(classifyFromDelegateContext(["type": NSNull(), "station_id": stationID.uuidString]) == .unrecognized)
    }

    @Test("Missing fields are handled without trapping")
    func missingFields_areHandledSafely() {
        // No payload at all, or no type: not ours.
        #expect(classifyFromDelegateContext([:]) == .unrecognized)
        #expect(classifyFromDelegateContext(["station_id": stationID.uuidString]) == .unrecognized)
        #expect(classifyFromDelegateContext(["aps": ["alert": "hi"]]) == .unrecognized)
        // A Price Alert that lost its station is malformed, not silently dropped as "unrecognized".
        #expect(classifyFromDelegateContext(["type": "price_alert"]) == .malformedPriceAlert(.missingStationID))
        #expect(classifyFromDelegateContext(["type": "price_alert", "observed_price": 3.19]) == .malformedPriceAlert(.missingStationID))
    }

    // MARK: - Existing, unrelated notifications are unaffected

    @Test("The Automatic Pump Detection arrival notification still classifies exactly as its own delegate did")
    func pumpArrival_isRecognizedUnchanged() {
        let userInfo: [AnyHashable: Any] = ["type": "automaticPumpDetection", "stationRecordID": "station:shell|39.96000|-83.00000"]

        #expect(classifyFromDelegateContext(userInfo) == .automaticPumpDetection(stationRecordID: "station:shell|39.96000|-83.00000"))
    }

    @Test("A pump notification missing its station record id is ignored, as it always was")
    func pumpArrival_withoutRecordIDIsIgnored() {
        #expect(classifyFromDelegateContext(["type": "automaticPumpDetection"]) == .unrecognized)
        #expect(classifyFromDelegateContext(["type": "automaticPumpDetection", "stationRecordID": 5]) == .unrecognized)
    }

    @Test("The pump notification's keys are the literals earlier builds already shipped")
    func pumpArrival_keysArePinnedToShippedValues() {
        // A notification delivered by an earlier build can still be tapped after an update, so
        // these may never change.
        #expect(AppNotificationPayload.typeKey == "type")
        #expect(AppNotificationPayload.pumpArrivalTypeValue == "automaticPumpDetection")
        #expect(AppNotificationPayload.pumpArrivalStationRecordIDKey == "stationRecordID")
    }

    @Test("Phase 3C: the worker now also sends payment_type — an additive key that changes nothing about parsing or routing")
    func paymentTypeKey_isIgnoredAndHarmless() {
        for paymentType in ["cash", "credit", "same_for_both", "unknown", "something_new"] {
            var withPaymentType = workerPriceAlert()
            withPaymentType["payment_type"] = paymentType

            let payload = classifyFromDelegateContext(withPaymentType)

            #expect(payload == .priceAlert(PriceAlertNotificationPayload(stationID: stationID, observedPrice: 3.19)), "\(paymentType)")
            #expect(AppNotificationDisposition.resolve(payload, isDefaultAction: true) == .route(.station(communityStationID: stationID)))
        }
        // …and a payload from an older worker, without it, is exactly what it was.
        #expect(workerPriceAlert()["payment_type"] == nil)
    }

    @Test("The Price Alert keys are the worker's contract")
    func priceAlertKeys_matchTheBackendContract() {
        #expect(AppNotificationPayload.priceAlertTypeValue == "price_alert")
        #expect(AppNotificationPayload.priceAlertStationIDKey == "station_id")
        #expect(AppNotificationPayload.priceAlertObservedPriceKey == "observed_price")
    }

    // MARK: - Disposition

    @Test("A plain tap on a Price Alert routes to its station")
    func tapOnPriceAlert_routesToStation() {
        let payload = classifyFromDelegateContext(workerPriceAlert())

        #expect(AppNotificationDisposition.resolve(payload, isDefaultAction: true) == .route(.station(communityStationID: stationID)))
    }

    @Test("Only a plain tap navigates: a custom action or dismissal of a Price Alert does nothing")
    func nonDefaultAction_doesNotNavigate() {
        let payload = classifyFromDelegateContext(workerPriceAlert())

        #expect(AppNotificationDisposition.resolve(payload, isDefaultAction: false) == .ignore)
    }

    @Test("A tap on a pump notification is forwarded to Automatic Pump Detection regardless of action, as before")
    func tapOnPumpNotification_isForwarded() {
        let payload = AppNotificationPayload.automaticPumpDetection(stationRecordID: "station:shell")

        #expect(AppNotificationDisposition.resolve(payload, isDefaultAction: true) == .forwardToPumpDetection(stationRecordID: "station:shell"))
        #expect(AppNotificationDisposition.resolve(payload, isDefaultAction: false) == .forwardToPumpDetection(stationRecordID: "station:shell"))
    }

    @Test("Unrecognized and malformed payloads are ignored")
    func unrecognizedAndMalformed_areIgnored() {
        #expect(AppNotificationDisposition.resolve(.unrecognized, isDefaultAction: true) == .ignore)
        #expect(AppNotificationDisposition.resolve(.malformedPriceAlert(.missingStationID), isDefaultAction: true) == .ignore)
        #expect(AppNotificationDisposition.resolve(.malformedPriceAlert(.invalidStationID), isDefaultAction: true) == .ignore)
    }
}

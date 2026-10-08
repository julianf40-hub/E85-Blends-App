//
//  PriceAlertsOverviewModel.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts UI (Phase 3B). The state behind the central "Price Alerts" screen
//  (More → Station Price Alerts): every alert the server holds for this installation, and the
//  notification card. Foundation + Observation only.
//
//  DELIBERATELY THIN. The screen lists alerts and opens the same Price Alert sheet for one; changing
//  an alert and turning it off happen THERE, through PriceAlertsStationModel, so there is exactly one
//  implementation of saving, validation, confirmation and error handling. Rows are derived, on every
//  read, from the service's list — the server's — so a change made in the sheet shows here with no
//  signalling between the two, and nothing here can disagree with the server.
//
//  LEGACY ALERTS (Phase 3C.1). An alert the server holds with no payment type (made before Cash and Credit prices were
//  reported separately) gets a "Payment type needed" banner with an Edit action on its row, and the list gets one
//  explanation ("Choose Your Price Type") above it. Both are computed from the server's list on every read — there is no
//  local flag to fall out of step — and neither writes anything: Edit opens the same sheet, whose Save is the only write.
//

import Foundation
import Observation

@MainActor
@Observable
final class PriceAlertsOverviewModel {
    nonisolated enum Phase: Equatable {
        case resolvingEntitlement
        case proRequired
        case loading
        case loadFailed(PriceAlertsUserMessage)
        /// Loaded, and the person has no alerts.
        case empty
        case list
    }

    /// One alert, ready to show: the station it watches and what it watches for.
    nonisolated struct Row: Identifiable, Equatable, Sendable {
        let id: UUID
        let target: PriceAlertStationTarget
        let alertTitle: String
        /// Which price the alert watches and how big a drop it waits for: "Credit price · 10¢ drop".
        let watchText: String
        /// True for an alert made before payment types existed: it has no price chosen yet.
        let needsPaymentChoice: Bool
        /// The "Payment type needed" banner and its Edit action; `nil` for an alert that already watches Cash or Credit.
        let paymentChoiceBanner: PriceAlertPaymentChoiceBanner?
        let latestPriceText: String?
        private let watchSpokenText: String

        init(listing: PriceAlertListing) {
            let target = PriceAlertStationTarget(listing: listing)
            self.target = target
            id = target.communityStationID
            alertTitle = PriceAlertSummary(alert: listing.alert).title
            let watch = PriceAlertWatch(alert: listing.alert)
            watchText = watch.shortText
            watchSpokenText = watch.spokenText
            needsPaymentChoice = watch.needsPaymentChoice
            paymentChoiceBanner = watch.needsPaymentChoice ? PriceAlertPaymentChoiceBanner(stationName: target.name) : nil
            latestPriceText = Self.latestPriceText(for: listing)
        }

        var accessibilityLabel: String {
            var parts = [target.name, "Alert: \(alertTitle)", watchSpokenText]
            if let paymentChoiceBanner { parts.append("\(paymentChoiceBanner.title). \(paymentChoiceBanner.message)") }
            if let latestPriceText { parts.append(latestPriceText) }
            return parts.joined(separator: ", ")
        }

        /// What VoiceOver says a tap on the row does.
        var accessibilityHint: String {
            needsPaymentChoice ? PriceAlertPaymentMigrationCopy.editAccessibilityHint : "Opens this alert so you can change it or turn it off."
        }

        /// The newest price the alert is actually judged against — NEVER the other payment type's price.
        /// - An alert that watches Cash or Credit shows only its own price stream, and says so when that
        ///   stream has no report yet (it does not fall back to the unfiltered latest price, which may be
        ///   the other method's).
        /// - An alert made before payment types existed keeps showing the latest community price, as it
        ///   always did, without claiming a method for it.
        static func latestPriceText(for listing: PriceAlertListing) -> String? {
            let payment = listing.alert.paymentType
            if payment.isSpecified {
                guard let price = listing.latestComparablePrice else {
                    return "No \(payment.title) price reported yet"
                }
                let amount = PriceAlertPriceInput.displayText(for: price)
                if listing.latestComparablePaymentType == .sameForBoth {
                    return "Latest price \(amount), reported as the same for cash and credit"
                }
                return "Latest \(payment.title) price \(amount)"
            }
            if let comparable = listing.latestComparablePrice {
                return "Latest community price \(PriceAlertPriceInput.displayText(for: comparable)), payment type not specified"
            }
            return listing.latestPrice.map {
                "Latest community price \(PriceAlertPriceInput.displayText(for: $0))"
            }
        }
    }

    /// The "Notifications" card's model.
    let notifications: PriceAlertsNotificationModel

    private let service: any PriceAlertsServing
    private var isLoading = false
    private var hasAttemptedLoad = false
    private var hasLoadedBefore: Bool

    init(service: any PriceAlertsServing) {
        self.service = service
        notifications = PriceAlertsNotificationModel(service: service)
        hasLoadedBefore = service.listState == .loaded
    }

    var entitlement: PriceAlertsEntitlement {
        service.entitlement
    }

    var rows: [Row] {
        service.alerts.map { Row(listing: $0) }
    }

    /// How many of the listed alerts have no payment type yet.
    var alertsNeedingPaymentChoice: Int {
        rows.filter(\.needsPaymentChoice).count
    }

    /// The explanation shown once above the list when at least one alert needs a price type. Read from the server's list
    /// on every access; `nil` when none does, and whenever the list is not what the screen is showing (a Free person sees
    /// the Pro card, a checking entitlement is not Free, a failed load shows its error).
    var paymentChoicePrompt: PriceAlertPaymentChoicePrompt? {
        guard phase == .list, alertsNeedingPaymentChoice > 0 else { return nil }
        return PriceAlertPaymentChoicePrompt(settingsNote: nil, referenceNote: nil)
    }

    var phase: Phase {
        switch service.entitlement {
        case .unresolved:
            return .resolvingEntitlement
        case .inactive:
            return .proRequired
        case .active:
            if hasLoadedBefore { return listPhase }
            if isLoading || hasAttemptedLoad == false { return .loading }
            switch service.listState {
            case .loaded: return listPhase
            case .failed(let error): return .loadFailed(PriceAlertsUserMessage(error: error))
            case .idle, .loading: return .loading
            }
        }
    }

    /// The list could not be refreshed, though an earlier one is showing. `nil` otherwise.
    var refreshWarning: PriceAlertsUserMessage? {
        switch phase {
        case .list, .empty:
            if case .failed(let error) = service.listState {
                return PriceAlertsUserMessage(error: error)
            }
            return nil
        case .resolvingEntitlement, .proRequired, .loading, .loadFailed:
            return nil
        }
    }

    private var listPhase: Phase {
        service.alerts.isEmpty ? .empty : .list
    }

    /// Reads the alerts from the server. Safe to call again — a call made while one runs does nothing.
    func load() async {
        guard service.entitlement == .active, isLoading == false else { return }
        isLoading = true
        hasAttemptedLoad = true
        await service.refreshAlerts()
        isLoading = false
        if service.listState == .loaded {
            hasLoadedBefore = true
        }
    }
}

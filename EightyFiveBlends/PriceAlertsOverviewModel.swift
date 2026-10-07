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
        let latestPriceText: String?

        init(listing: PriceAlertListing) {
            let target = PriceAlertStationTarget(listing: listing)
            self.target = target
            id = target.communityStationID
            alertTitle = PriceAlertSummary(alert: listing.alert).title
            latestPriceText = listing.latestPrice.map {
                "Latest community price \(PriceAlertPriceInput.displayText(for: $0))"
            }
        }

        var accessibilityLabel: String {
            var parts = [target.name, "Alert: \(alertTitle)"]
            if let latestPriceText { parts.append(latestPriceText) }
            return parts.joined(separator: ", ")
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

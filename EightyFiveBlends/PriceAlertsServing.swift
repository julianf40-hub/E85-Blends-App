//
//  PriceAlertsServing.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts UI (Phase 3B). The slice of PriceAlertsService the Price Alerts
//  screens' models use, as a protocol, so a model's behavior can be tested against a fake that stops
//  and fails on command. PriceAlertsService conforms unchanged: every requirement below is a member it
//  already has. Nothing here adds behavior.
//
//  Deliberately ABSENT from the seam: `disablePushDelivery()` and `refreshServerStatus()`. No Price
//  Alerts screen turns delivery off (turning an alert off must never unregister the device) or needs
//  the server's diagnostics, and leaving them out makes that a compile-time fact for the models.
//

import Foundation

protocol PriceAlertsServing: AnyObject {
    var entitlement: PriceAlertsEntitlement { get }
    var alerts: [PriceAlertListing] { get }
    var listState: PriceAlertsService.ListState { get }
    var lastDeviceRegistrationOutcome: PriceAlertsDeviceRegistrationOutcome? { get }
    var hasRegisteredDevice: Bool { get }

    func refreshAlerts() async

    @discardableResult
    func createAlert(
        communityStationID: UUID?,
        rule: PriceAlertRule,
        preferences: PriceAlertPreferences,
        paymentType: PriceAlertPayment?
    ) async throws -> PriceAlert

    @discardableResult
    func updateAlert(
        _ existing: PriceAlert,
        rule: PriceAlertRule?,
        preferences: PriceAlertPreferences?,
        paymentType: PriceAlertPayment?
    ) async throws -> PriceAlert

    func deleteAlert(communityStationID: UUID?) async throws

    @discardableResult
    func enablePushDelivery() async -> PriceAlertsDeviceRegistrationOutcome
}

extension PriceAlertsService: PriceAlertsServing {}

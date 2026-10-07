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

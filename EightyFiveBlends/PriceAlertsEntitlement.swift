//
//  PriceAlertsEntitlement.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). How Price Alerts asks "is this user
//  allowed to configure alerts?" — without owning any entitlement logic.
//
//  SubscriptionManager remains the single source of truth for Pro (its own header says every gate
//  routes through `isPro`); this file adds no purchase, restore or RevenueCat behavior and no second
//  copy of the rule. The live adapter (SubscriptionManagerEntitlementProvider, in
//  PriceAlertsLiveDependencies.swift) just reads `canAccessStationAlerts` — the feature-level gate
//  that already exists for exactly this feature — plus `hasAuthoritativeProStatus`.
//
//  THREE ANSWERS, NOT TWO. A false `isPro` cannot tell "RevenueCat said Free" from "RevenueCat has not
//  answered yet (or its fetch failed)". Acting on the second as if it were the first would tell a
//  paying subscriber to upgrade, so the unknown case is its own value, `.unresolved` — the same rule
//  Refer & Earn already follows (SubscriptionManager.hasAuthoritativeProStatus).
//
//  WHAT THE GATE COVERS AND WHAT IT DELIBERATELY DOES NOT
//    - Gated on the client: creating or changing an alert (`set_alert`), and creating a NEW
//      installation (which exists only to serve alerts).
//    - Never gated: listing and deleting alerts, and keeping an existing device registration current.
//      A subscriber whose Pro lapses keeps seeing and can still remove their alerts; nothing is
//      deleted, disabled or unregistered because of a lapse, on the device or on the server. When Pro
//      returns, the same alert rows and the same installation simply resume — nothing is re-created.
//    - The BACKEND is authoritative. This gate is a courtesy that spares a Free user a pointless
//      request (and spares the server a pointless installation); `set_alert` is re-checked
//      server-side, and so is every send.
//

import Foundation

nonisolated enum PriceAlertsEntitlement: Equatable, Sendable {
    /// The user has Pro.
    case active
    /// RevenueCat has answered and the user does not have Pro.
    case inactive
    /// No authoritative answer yet this launch.
    case unresolved
}

protocol PriceAlertsEntitlementProviding: Sendable {
    var entitlement: PriceAlertsEntitlement { get }
}

nonisolated enum PriceAlertsEntitlementPolicy {
    /// Applied to creating/changing an alert and to creating an installation.
    /// - Throws: `proRequired` for `.inactive`, `entitlementUnresolved` for `.unresolved`.
    static func authorizeWrite(_ entitlement: PriceAlertsEntitlement) throws {
        switch entitlement {
        case .active:
            return
        case .inactive:
            throw PriceAlertsServiceError.proRequired
        case .unresolved:
            throw PriceAlertsServiceError.entitlementUnresolved
        }
    }
}

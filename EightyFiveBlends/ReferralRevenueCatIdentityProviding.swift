//
//  ReferralRevenueCatIdentityProviding.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — iOS referral client foundation, correctness hardening pass. Narrow boundary
//  around the RevenueCat App User ID so ReferralManager — not EightyFiveBlendsApp/SwiftUI — owns
//  fetching it. Before this pass, startup code read
//  RevenueCatSubscriptionService.shared.currentRevenueCatAppUserID directly and passed the raw
//  value into ReferralManager.bootstrapIfNeeded(revenueCatAppUserID:); that meant any FUTURE
//  manual-retry UI would either need to know the raw RevenueCat identity itself or duplicate
//  startup's own orchestration. Now the App layer calls only
//  `await ReferralManager.shared.bootstrapIfNeeded()` — no raw identity ever crosses into
//  EightyFiveBlendsApp.swift or any SwiftUI view.
//
//  The real (unmasked) App User ID this returns must never be logged, displayed, persisted outside
//  a transient HTTPS bootstrap request body, or sent to analytics — see
//  RevenueCatSubscriptionService.currentRevenueCatAppUserID's own header for the same rule at its
//  source, which this provider forwards unchanged.
//

import Foundation

protocol ReferralRevenueCatIdentityProviding: Sendable {
    /// `nil` until RevenueCat has actually configured this launch (see
    /// RevenueCatSubscriptionService.currentRevenueCatAppUserID) — callers must not synthesize a
    /// placeholder while waiting, and must treat `nil` as "try again later," never as a signal to
    /// invent or reuse some other identifier.
    @MainActor
    func currentAppUserID() -> String?
}

struct LiveReferralRevenueCatIdentityProvider: ReferralRevenueCatIdentityProviding {
    @MainActor
    func currentAppUserID() -> String? {
        RevenueCatSubscriptionService.shared.currentRevenueCatAppUserID
    }
}

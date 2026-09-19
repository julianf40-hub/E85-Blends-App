//
//  ReferralRevenueEnvironmentProviding.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — iOS referral client foundation. Determines whether this install is running in
//  the App Store SANDBOX or PRODUCTION environment — required by referral-api's `bootstrap`
//  action (revenuecat_environment) BEFORE any purchase, since a referral attribution must be
//  applied before the qualifying purchase happens (see referral-api's own task spec).
//
//  This deliberately does NOT use RevenueCat's `EntitlementInfo.isSandbox` (see
//  RevenueCatSubscriptionService.isSandboxEnvironment): that field is only populated once an
//  entitlement RECORD exists, which requires a purchase attempt to have already happened — exactly
//  what referral bootstrap must run before. It also deliberately does NOT infer environment from
//  `#if DEBUG`, the bundle receipt filename, or Pro status: TestFlight builds are Release
//  configuration (never DEBUG) but ARE sandbox — any of those would misclassify a TestFlight
//  installation as PRODUCTION.
//
//  StoreKit 2's `AppTransaction` is the authoritative source used instead: it reflects this
//  app's own original download/install environment and is available from first launch, on any
//  build channel, with no purchase required — introduced in iOS 16.0, well within this app's
//  minimum deployment targets (17.6 App Store / 26.4 Internal — see CLAUDE.md), so no
//  availability fallback is needed.
//

import Foundation
import StoreKit

protocol ReferralRevenueEnvironmentProviding: Sendable {
    /// `nil` only when no authoritative signal could be obtained this call (e.g. AppTransaction
    /// genuinely unreachable) — callers must treat that as "try again later," never guess.
    func currentEnvironment() async -> ReferralRevenueEnvironment?
}

struct StoreKitReferralRevenueEnvironmentProvider: ReferralRevenueEnvironmentProviding {
    func currentEnvironment() async -> ReferralRevenueEnvironment? {
        guard let result = try? await AppTransaction.shared else { return nil }

        let transaction: AppTransaction
        switch result {
        case .verified(let value):
            transaction = value
        case .unverified(let value, _):
            // The device's own reported environment is still meaningful even when the JWS
            // signature itself couldn't be locally verified — this is an environment label used
            // to route referral attribution timing, not a purchase/entitlement grant, so the
            // stricter `.verified`-only bar that money-relevant decisions require doesn't apply.
            transaction = value
        }

        switch transaction.environment {
        case .production:
            return .production
        case .sandbox, .xcode:
            return .sandbox
        default:
            return nil
        }
    }
}

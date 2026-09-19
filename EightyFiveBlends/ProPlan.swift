//
//  ProPlan.swift
//  EightyFiveBlends
//

import Foundation

/// 85Blends 2.4.0 — the three shipping 85Blends Pro subscription plans. All three grant the exact
/// same, pre-existing RevenueCat `pro` entitlement (see RevenueCatSubscriptionService.
/// proEntitlementID) — there is no per-plan feature difference and no per-plan entitlement. This
/// type only ever describes PLAN IDENTITY/PRICING METADATA; it is never itself an entitlement or
/// purchase-authority source (see SubscriptionManager.isPro's own header for why that stays
/// unchanged by this feature).
///
/// Deliberately excludes `com.85blends.subscription.quarterly` — a legacy product that remains
/// attached to `pro` but lives only in a separate, non-`default` RevenueCat offering
/// (`pro_240_draft`) that this app never queries. `ProPlan.allCases` is the complete, authoritative
/// list of every product ID the shipping paywall may ever resolve or purchase — see
/// RevenueCatSubscriptionService.resolvePackage(...), which independently validates every
/// resolved package's product ID against exactly one of these three, regardless of what RevenueCat
/// happens to return.
enum ProPlan: String, CaseIterable, Identifiable, Sendable {
    case monthly
    case threeMonth
    case annual

    var id: String { rawValue }

    /// The Apple App Store product ID this plan must resolve to. The ONLY three product IDs the
    /// shipping app ever recognizes.
    var productID: String {
        switch self {
        case .monthly: "com.85blends.subscription.monthly"
        case .threeMonth: "com.85blends.subscription.threemonth"
        case .annual: "com.85blends.subscription.annual"
        }
    }

    /// Marketing title for the paywall's plan picker.
    var title: String {
        switch self {
        case .monthly: "Monthly"
        case .threeMonth: "3 Months"
        case .annual: "Annual"
        }
    }

    /// Marketing price shown before the RevenueCat package loads (or if it never does) — display
    /// only, exactly mirroring the pre-2.4.0 single-plan `SubscriptionManager.fallbackDisplayPrice`
    /// this replaces. Once a real package loads, its localized price is always preferred — see
    /// SubscriptionManager.displayPrice(for:).
    var fallbackDisplayPrice: String {
        switch self {
        case .monthly: "$3.99"
        case .threeMonth: "$9.99"
        case .annual: "$24.99"
        }
    }

    /// Natural-language billing-period suffix ("month" / "3 months" / "year") used only before a
    /// real StoreProduct has loaded — see ProUpgradeView.billingPeriodSuffix(for:), which prefers
    /// the real product's own `subscriptionPeriod` once available.
    var fallbackBillingPeriodLabel: String {
        switch self {
        case .monthly: "month"
        case .threeMonth: "3 months"
        case .annual: "year"
        }
    }

    /// How many whole months this plan's billing period represents. Used only to compute an
    /// "equivalent per month" display figure from a REAL loaded price — never to fabricate a
    /// marketing price on its own. See ProUpgradeView.equivalentMonthlyLine(for:).
    var billingPeriodInMonths: Int {
        switch self {
        case .monthly: 1
        case .threeMonth: 3
        case .annual: 12
        }
    }

    /// 85Blends 2.4.0 three-plan paywall — deterministic default-selection fallback, in
    /// preference order (best value first), among only the plans currently available to
    /// purchase. `nil` when none are available — the paywall falls back to its existing
    /// load-error/retry experience in that case, independent of which plan happens to be
    /// selected. Pure and directly testable (no SubscriptionManager/RevenueCat dependency) so the
    /// fallback order itself is verifiable without constructing real package-availability state.
    static func preferredDefault(among availablePlans: Set<ProPlan>) -> ProPlan? {
        for plan in [ProPlan.annual, .threeMonth, .monthly] where availablePlans.contains(plan) {
            return plan
        }
        return nil
    }

    /// Pure "price ÷ billing months" arithmetic for the paywall's "≈ $X.XX/month" line — see
    /// ProUpgradeView.equivalentMonthlyLine(for:), the only call site, which always passes a REAL
    /// loaded `StoreProduct.price` here, never `fallbackDisplayPrice` (a flat marketing string
    /// this function was never meant to parse — see that property's own header). `Decimal`, not
    /// `Double`, so e.g. $24.99 / 12 stays the exact value (2.0825) instead of picking up binary
    /// floating-point error — the same reasoning StoreProduct.price itself is a `Decimal` for.
    /// `nil` for Monthly (nothing to compare a 1-month plan against) and, defensively, for any
    /// plan whose own billing period isn't more than one month — not reachable today since every
    /// case's `billingPeriodInMonths` is a positive literal, but this keeps the function total
    /// rather than leaning on that invariant silently.
    static func equivalentMonthlyAmount(price: Decimal, plan: ProPlan) -> Decimal? {
        guard plan.billingPeriodInMonths > 1 else { return nil }
        return price / Decimal(plan.billingPeriodInMonths)
    }
}

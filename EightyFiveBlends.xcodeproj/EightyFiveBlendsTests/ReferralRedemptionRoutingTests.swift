//
//  ReferralRedemptionRoutingTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.0 Sandbox redemption fix. Focused tests for the pure helpers behind
//  ReferralRewardRedemptionSheet's Sandbox-vs-Production redemption route, its return
//  reconciliation sequence + non-sensitive sync diagnostics, and the confirmation-copy duplication
//  fix ("...after the free month after the free month...") found during live TestFlight testing.
//  Nothing here touches StoreKit, RevenueCat, the network, or the live singletons — the sheet's
//  own side effects are injected as closures (see `reconcileAfterRedemption(sync:refresh:)`).
//

import Testing
import Foundation
@testable import EightyFiveBlends

struct ReferralRedemptionRoutingTests {
    // MARK: - A / F. Production-vs-Sandbox route decision

    @Test("A SANDBOX bootstrap environment routes to the native in-app redemption sheet")
    func route_sandbox_isNativeSheet() {
        #expect(ReferralPresentation.redemptionRoute(environment: .sandbox) == .sandboxNativeSheet)
    }

    @Test("A PRODUCTION bootstrap environment keeps the existing external App Store URL route")
    func route_production_isAppStoreURL() {
        #expect(ReferralPresentation.redemptionRoute(environment: .production) == .appStoreURL)
    }

    @Test("An unknown (nil) environment never assumes Sandbox — it takes the pre-existing production route")
    func route_unknown_isAppStoreURL() {
        #expect(ReferralPresentation.redemptionRoute(environment: nil) == .appStoreURL)
    }

    @Test("Sandbox helper copy never mentions or embeds a code")
    func sandboxHelpText_isStaticAndCodeFree() {
        let text = ReferralPresentation.sandboxRedemptionHelpText
        #expect(text.isEmpty == false)
        #expect(text.contains("Sandbox"))
        #expect(text.contains("copied"))
    }

    // MARK: - D. Return reconciliation: sync, then ALWAYS refresh; failure is never fabricated

    @Test("Reconciliation calls sync first, then refresh, and reports .completed on a successful sync")
    func reconcile_successfulSync_syncThenRefresh() async {
        let order = OrderRecorder()
        let outcome = await ReferralPresentation.reconcileAfterRedemption(
            sync: { await order.record("sync"); return true },
            refresh: { await order.record("refresh") }
        )
        #expect(outcome == .completed)
        #expect(await order.events == ["sync", "refresh"])
    }

    @Test("A failed sync still runs the referral refresh afterward and reports only .failed — never a fulfilled/redeemed state")
    func reconcile_failedSync_stillRefreshes() async {
        let order = OrderRecorder()
        let outcome = await ReferralPresentation.reconcileAfterRedemption(
            sync: { await order.record("sync"); return false },
            refresh: { await order.record("refresh") }
        )
        #expect(outcome == .failed)
        #expect(await order.events == ["sync", "refresh"])
    }

    @Test("Reconciliation never reads or mutates reward status — an issued code stays exactly as the backend reported it")
    func reconcile_doesNotTouchIssuedCode() async {
        let issued = ReferralStatus(
            referralCode: "ABCD2345",
            qualifiedReferrals: 5,
            pendingReferrals: 0,
            earnedMonthsAvailable: 0,
            fulfilledMonths: 0,
            nextMilestoneNumber: 2,
            nextRewardAt: 10,
            referralsNeeded: 5,
            canApplyReferralCode: true,
            referredByCode: nil,
            referredStatus: nil,
            issuedRewardProductID: "com.85blends.subscription.monthly",
            issuedRewardOfferReferenceName: "REFERRAL_REWARD_MONTHLY_1M_FREE",
            issuedRewardCode: "SANDBOXCODE1",
            issuedRewardExpiresAtRaw: "2026-12-31T00:00:00.000Z",
            issuedRewardNeedsRefresh: false
        )
        let before = issued
        _ = await ReferralPresentation.reconcileAfterRedemption(sync: { false }, refresh: {})
        #expect(issued == before)
        #expect(issued.issuedRewardCode == "SANDBOXCODE1")
        #expect(issued.fulfilledMonths == 0)
        #expect(
            ReferralPresentation.rewardCardState(
                earnedMonthsAvailable: issued.earnedMonthsAvailable,
                issuedRewardCode: issued.issuedRewardCode,
                issuedRewardNeedsRefresh: issued.issuedRewardNeedsRefresh
            ) == .issuedCode
        )
    }

    // MARK: - D. Sync diagnostics copy — neutral, non-sensitive, never a redemption verdict

    @Test("Sync state copy is nil when idle and neutral/non-sensitive otherwise")
    func syncMessage_perState() {
        #expect(ReferralPresentation.redemptionSyncMessage(for: .idle) == nil)
        #expect(ReferralPresentation.redemptionSyncMessage(for: .syncing) == "Checking redemption…")
        #expect(ReferralPresentation.redemptionSyncMessage(for: .completed) == "Redemption is still awaiting confirmation.")
        #expect(
            ReferralPresentation.redemptionSyncMessage(for: .failed)
                == "We couldn't refresh the purchase yet. Your reward code is still safe. Try again shortly."
        )
    }

    @Test("Sync copy never claims success or failure of the redemption itself")
    func syncMessage_neverClaimsRedemptionOutcome() {
        for state in [ReferralPresentation.RedemptionSyncState.syncing, .completed, .failed] {
            let message = ReferralPresentation.redemptionSyncMessage(for: state) ?? ""
            let lowered = message.lowercased()
            #expect(lowered.contains("redemption failed") == false)
            #expect(lowered.contains("redeemed successfully") == false)
            #expect(lowered.contains("fulfilled") == false)
        }
    }

    // MARK: - E. Confirmation copy — exactly one "after the free month", no hardcoded price

    @Test("Monthly confirmation copy is the exact target sentence with a single 'after the free month'")
    func confirmationCopy_monthly_exact() {
        let copy = ReferralPresentation.redemptionConfirmationCopy(displayPrice: "$3.99", billingPeriodLabel: ProPlan.monthly.fallbackBillingPeriodLabel)
        #expect(copy == "You'll receive 1 month of 85Blends Pro free. After the free month, this subscription renews at $3.99/month unless cancelled.")
        #expect(occurrences(of: "after the free month", in: copy) == 1)
    }

    @Test("3-Month confirmation copy has exactly one 'after the free month'")
    func confirmationCopy_threeMonth_single() {
        let copy = ReferralPresentation.redemptionConfirmationCopy(displayPrice: "$9.99", billingPeriodLabel: ProPlan.threeMonth.fallbackBillingPeriodLabel)
        #expect(copy == "You'll receive 1 month of 85Blends Pro free. After the free month, this subscription renews at $9.99/3 months unless cancelled.")
        #expect(occurrences(of: "after the free month", in: copy) == 1)
    }

    @Test("Annual confirmation copy has exactly one 'after the free month'")
    func confirmationCopy_annual_single() {
        let copy = ReferralPresentation.redemptionConfirmationCopy(displayPrice: "$24.99", billingPeriodLabel: ProPlan.annual.fallbackBillingPeriodLabel)
        #expect(copy == "You'll receive 1 month of 85Blends Pro free. After the free month, this subscription renews at $24.99/year unless cancelled.")
        #expect(occurrences(of: "after the free month", in: copy) == 1)
    }

    @Test("Confirmation copy carries the exact display price it is given — no price is hardcoded in the formatter")
    func confirmationCopy_usesPassedInPriceOnly() {
        let copy = ReferralPresentation.redemptionConfirmationCopy(displayPrice: "€7,77", billingPeriodLabel: "month")
        #expect(copy.contains("€7,77/month"))
        for plan in ProPlan.allCases {
            #expect(copy.contains(plan.fallbackDisplayPrice) == false)
        }
    }

    @Test("renewalPriceLine (plan picker rows) is unchanged and still ends with 'after the free month'")
    func renewalPriceLine_unchanged() {
        #expect(ReferralPresentation.renewalPriceLine(displayPrice: "$3.99", billingPeriodLabel: "month") == "$3.99/month after the free month")
        #expect(ReferralPresentation.renewalPrice(displayPrice: "$3.99", billingPeriodLabel: "month") == "$3.99/month")
    }

    // MARK: - Helpers

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.lowercased().components(separatedBy: needle.lowercased()).count - 1
    }
}

/// Records the order side effects ran in, across `await` boundaries, without any timing dependence.
private actor OrderRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

//
//  ReferralAwareProPurchaseCoordinator.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — Refer & Earn paywall integration. Orchestrates the ONE ordering guarantee
//  referral attribution requires at the point of purchase: a referral code must be backend-
//  confirmed BEFORE the qualifying paid Pro purchase begins (see referral-api's own task spec).
//
//  This type owns NEITHER RevenueCat purchasing NOR referral application — it takes both as
//  injected closures and only orchestrates the CALL ORDER between them. In production,
//  `applyReferralCode` is exactly `ReferralManager.shared.applyReferralCode(_:)` and `purchase` is
//  exactly `{ await SubscriptionManager.shared.purchasePro(selectedPlan) }` — ProUpgradeView still
//  owns supplying those closures and reading their owning managers' own @Observable state
//  (purchaseState, loadState) to render the UI; this coordinator never touches either manager
//  directly, and is fully testable with plain local closures (see
//  ReferralAwareProPurchaseCoordinatorTests.swift) with no ReferralManager/SubscriptionManager/
//  RevenueCat/network dependency at all.
//
//  @MainActor because both real closures it's given in production are themselves @MainActor
//  (ReferralManager and SubscriptionManager are both @MainActor @Observable) — this avoids any
//  cross-actor Sendable-closure complexity for what is, in practice, always a paywall-UI-driven
//  call.
//

import Foundation

@MainActor
enum ReferralAwareProPurchaseCoordinator {
    enum Outcome: Equatable, Sendable {
        /// Purchase was started — either no code was present, or a valid code applied and was
        /// backend-confirmed first.
        case purchased
        /// A non-empty code failed local format validation (see
        /// ReferralPresentation.referralCodeIsValid) — neither apply nor purchase ran.
        case invalidCode
        /// `applyReferralCode` threw — purchase never ran. `message` is the same safe,
        /// non-sensitive copy ReferralPresentation.userFacingMessage(for:) already produces for
        /// the standalone Refer & Earn sheet — never a raw backend string, error description, or
        /// OSStatus.
        case applyFailed(message: String)
        /// `applyReferralCode` returned normally, but the returned authoritative status's own
        /// `referredByCode` didn't match the code that was actually submitted — purchase never
        /// ran. A defense-in-depth safety net: this should not be reachable given a well-behaved
        /// backend, but a purchase must never proceed on an unconfirmed attribution regardless.
        case confirmationMismatch
    }

    /// - Parameters:
    ///   - normalizedCode: Already trimmed+uppercased (see
    ///     `ReferralPresentation.normalizedReferralCode`) — an empty string means "no code," and
    ///     purchases immediately with no referral step at all. Entirely IGNORED whenever
    ///     `alreadyAppliedCode` is non-empty (see that parameter's own header) — this is what lets
    ///     a stale, hidden paywall text field never re-trigger an apply call.
    ///   - alreadyAppliedCode: The backend's own authoritative `ReferralStatus.referredByCode` for
    ///     this installation, if any — e.g. from an apply that already succeeded earlier this
    ///     paywall session (a first purchase attempt that was cancelled in Apple's own StoreKit
    ///     sheet, for instance). One referrer for life is immutable, so once this is non-empty it
    ///     WINS unconditionally: `normalizedCode` is never read, `applyReferralCode` is never
    ///     called again, and `purchase` runs immediately — regardless of whether `normalizedCode`
    ///     happens to be the same code, a different valid code, or malformed. The paywall's own
    ///     code-entry field is hidden once this is non-empty, but hidden state must never be
    ///     allowed to silently drive purchasing decisions.
    ///   - applyReferralCode: In production, exactly `ReferralManager.shared.applyReferralCode(_:)`
    ///     — awaited to completion, and its result checked, before `purchase` is ever invoked.
    ///     Never called at all when `alreadyAppliedCode` is non-empty.
    ///   - purchase: In production, exactly the paywall's existing
    ///     `SubscriptionManager.shared.purchasePro(selectedPlan)` call — invoked at most once, and
    ///     only after a non-empty NEW code has been backend-confirmed, or immediately for a blank
    ///     code or an already-applied one.
    static func purchase(
        normalizedCode: String,
        alreadyAppliedCode: String?,
        applyReferralCode: (String) async throws -> ReferralStatus,
        purchase: () async -> Void
    ) async -> Outcome {
        // Backend attribution state always wins over local/hidden UI state — see this
        // parameter's own header. Checked FIRST, before normalizedCode is read at all.
        if let alreadyAppliedCode, alreadyAppliedCode.isEmpty == false {
            await purchase()
            return .purchased
        }

        guard normalizedCode.isEmpty == false else {
            await purchase()
            return .purchased
        }

        guard ReferralPresentation.referralCodeIsValid(normalizedCode) else {
            return .invalidCode
        }

        let status: ReferralStatus
        do {
            status = try await applyReferralCode(normalizedCode)
        } catch let error as ReferralServiceError {
            return .applyFailed(message: ReferralPresentation.userFacingMessage(for: error))
        } catch {
            // Never reachable from the real ReferralManager.applyReferralCode(_:), which only ever
            // throws ReferralServiceError — kept as a safe, non-leaking fallback in case a future
            // caller injects a closure that throws something else.
            return .applyFailed(message: ReferralPresentation.userFacingMessage(for: .network(error.localizedDescription)))
        }

        guard status.referredByCode == normalizedCode else {
            return .confirmationMismatch
        }

        await purchase()
        return .purchased
    }
}

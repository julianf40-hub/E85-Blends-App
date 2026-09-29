//
//  ReferralPresentation.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — Refer & Earn UI. Pure, UI-only presentation helpers for ReferEarnView and
//  ReferralCodeEntrySheet — code format validation, progress-ratio formatting, entry-section
//  state, applied-status copy, error copy, and share text. Nothing here talks to
//  URLSession/Keychain/RevenueCat/Supabase, and nothing here computes referral
//  qualification/reward/milestone truth — nextRewardAt/referralsNeeded/canApplyReferralCode/
//  earnedMonthsAvailable/fulfilledMonths always come straight from ReferralManager's own
//  backend-sourced ReferralStatus. See that type's own "BACKEND STATUS IS AUTHORITATIVE" header.
//
//  Matches the codebase's existing plain-enum-namespace convention (AppHaptics, AppStoreDestination)
//  — no instances, only static pure functions/values.
//

import Foundation

enum ReferralPresentation {
    // MARK: - Referral code format validation

    /// The exact 32-character alphabet referral-api's codes are drawn from — digits 2-9 and
    /// A-Z minus I/O, chosen upstream specifically to avoid characters easily confused with each
    /// other (0/O, 1/I) when read aloud or handwritten. Mirrors
    /// supabase/functions/_shared/referral-api-validation.ts's own format exactly, for immediate
    /// client-side UX only — the backend remains the authoritative validator.
    static let referralCodeAlphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    static let referralCodeLength = 8

    /// Trims surrounding whitespace and uppercases — the one normalization this feature ever
    /// applies to user-entered text, applied identically here and by
    /// ReferralAPIService.applyCode(_:credential:) (see that method's own comment). Never any
    /// other transformation — an invalid code is never silently rewritten into a different one.
    static func normalizedReferralCode(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// UX-only format check (length + alphabet) — controls the Apply button's enabled state
    /// alone. The backend re-validates authoritatively regardless of this result; a client bug
    /// here can only ever make the button too strict or too lax, never bypass a real check.
    /// Normalizes internally first, so lowercase input and incidental surrounding whitespace are
    /// tolerated exactly like they are before submission.
    static func referralCodeIsValid(_ raw: String) -> Bool {
        let normalized = normalizedReferralCode(raw)
        guard normalized.count == referralCodeLength else { return false }
        return normalized.allSatisfy { referralCodeAlphabet.contains($0) }
    }

    // MARK: - Progress (visual formatting only — never qualification/reward truth)

    /// Visual-only position within the fixed 5-referral reward cycle, derived from the server's
    /// own authoritative `referralsNeeded` — see this feature's own task spec: "This is UI
    /// formatting only. Do not use this value to determine rewards/qualification/availability/
    /// milestones/redemption." Defensively clamped to [0, 5] so an unexpected server value (a
    /// future backend change, a transient decode of a partial/legacy shape) can never render a
    /// nonsensical negative or >5 progress bar — it only ever affects this bar's own appearance.
    static func progressInCurrentCycle(referralsNeeded: Int) -> Int {
        max(0, min(referralsCycleLength, referralsCycleLength - referralsNeeded))
    }

    static let referralsCycleLength = 5

    /// The "N more qualified referrals needed" / "1 more..." copy underneath the progress bar.
    /// Pluralizes correctly; clamps a negative/out-of-range value to a safe, still-truthful
    /// "ready" message rather than ever printing something like "-2 more referrals needed."
    static func referralsNeededCopy(_ referralsNeeded: Int) -> String {
        let clamped = max(0, referralsNeeded)
        if clamped == 0 {
            return "You're ready for your next free month!"
        }
        return clamped == 1
            ? "1 more qualified referral needed"
            : "\(clamped) more qualified referrals needed"
    }

    // MARK: - Entry section state (Phase 12)

    /// Whether the "Have a referral code?" entry prompt should be offered, and if not, why —
    /// UX/copy selection only. The backend remains authoritative on whether an apply_code call
    /// actually succeeds regardless of what this returns; this exists purely so the view never
    /// shows an entry field the backend would certainly reject.
    enum EntryEligibility: Equatable, Sendable {
        /// Show the entry prompt/button — free-or-Pro-eligible-either-way installation with no
        /// code applied yet.
        case allowed
        /// RevenueCat's initial entitlement fetch hasn't resolved yet, so `isCurrentlyPro` is
        /// provisional and cannot yet be trusted either way — a real Pro subscriber can briefly
        /// read as `false` during cold-launch resolution. Never fall through to `.allowed` or
        /// `.blockedAlreadyPro` while this is true; both would risk either hiding entry from an
        /// eligible Free user or, worse, letting an existing Pro subscriber apply a code they
        /// should never be offered.
        case waitingForSubscriptionStatus
        /// `isEntitlementResolutionPending` is already `false` (the first resolution *attempt*
        /// finished), but no real CustomerInfo result has ever been successfully applied this
        /// process — i.e. that attempt FAILED (or no SDK key was configured). See
        /// `SubscriptionManager.hasAuthoritativeProStatus`'s own header: a failed first fetch
        /// still reaches `.resolved` on purpose (so the rest of the app doesn't hang), which means
        /// `isCurrentlyPro == false` here could just as easily mean "we never got a real answer"
        /// as "confirmed Free." Distinct from `.waitingForSubscriptionStatus` because there is
        /// nothing actively in flight to wait for — the UI should offer a retry instead of a
        /// spinner.
        case subscriptionStatusUnavailable
        /// Already Pro — referral codes must be applied BEFORE the qualifying purchase, so
        /// entry is intentionally withheld once the user is already subscribed.
        case blockedAlreadyPro
        /// Backend reports this installation cannot apply a code, for any other reason. In
        /// practice this coincides with a code already being applied (see
        /// `hasAppliedReferralCode(referredByCode:)`, which callers should check FIRST — see
        /// that function's own header) — kept as its own case so an entry field is never shown
        /// even in a state this client doesn't fully recognize.
        case blockedCannotApply
    }

    /// UX gating only — the backend remains authoritative on whether an apply_code call actually
    /// succeeds. Decision order: the backend's own `canApplyReferralCode` first, then whether
    /// resolution is still in flight (`isEntitlementResolutionPending`), then whether a resolution
    /// attempt that finished actually produced a real answer (`hasAuthoritativeProStatus`), and
    /// only once both of those hold does `isCurrentlyPro` get trusted. Skipping the
    /// `hasAuthoritativeProStatus` check would let a FAILED first fetch (which also sets
    /// `isEntitlementResolutionPending = false`, by design — see
    /// `SubscriptionManager.isInitialEntitlementResolutionPending`'s own header) be misread as a
    /// confirmed Free result.
    static func entryEligibility(
        canApplyReferralCode: Bool,
        isCurrentlyPro: Bool,
        isEntitlementResolutionPending: Bool,
        hasAuthoritativeProStatus: Bool
    ) -> EntryEligibility {
        guard canApplyReferralCode else { return .blockedCannotApply }
        if isEntitlementResolutionPending { return .waitingForSubscriptionStatus }
        guard hasAuthoritativeProStatus else { return .subscriptionStatusUnavailable }
        return isCurrentlyPro ? .blockedAlreadyPro : .allowed
    }

    /// Whether the immutable "applied" state (Phase 17) must be shown instead of ANY code-entry
    /// UI — true exactly when a code has already been recorded for this installation. Checked
    /// BEFORE `entryEligibility` by the view: one referrer for life is immutable, so this alone
    /// is enough to rule out ever showing an entry field, independent of `canApplyReferralCode`.
    static func hasAppliedReferralCode(referredByCode: String?) -> Bool {
        referredByCode != nil
    }

    /// Whether a malformed, non-empty LOCAL referral code should actually disable the paywall's
    /// purchase CTA — structurally `false` whenever `backendAppliedReferralCode` is non-empty,
    /// never merely assumed unreachable in practice. Mirrors
    /// `ReferralAwareProPurchaseCoordinator.purchase`'s own `alreadyAppliedCode` precedence
    /// (backend attribution wins unconditionally over local input — same code, a different valid
    /// code, or malformed input alike) at the UI-gating layer: once this installation already has
    /// a confirmed referral, the CTA must never stay disabled because of stale, hidden local text
    /// field state the user can no longer even edit.
    static func shouldBlockPurchaseForReferralInput(
        backendAppliedReferralCode: String?,
        normalizedReferralCode: String
    ) -> Bool {
        guard (backendAppliedReferralCode ?? "").isEmpty else {
            return false
        }
        return normalizedReferralCode.isEmpty == false && referralCodeIsValid(normalizedReferralCode) == false
    }

    // MARK: - Applied referral status copy (Phase 17)

    struct AppliedStatusPresentation: Equatable, Sendable {
        let title: String
        let body: String
    }

    /// Maps the backend's raw `referred_status` string to safe, friendly copy — the raw value is
    /// NEVER interpolated into UI text, including for an unrecognized/nil value (see this
    /// feature's own task spec: "Do not print raw status strings").
    static func appliedStatusPresentation(_ referredStatus: String?) -> AppliedStatusPresentation {
        switch referredStatus {
        case "pending":
            AppliedStatusPresentation(
                title: "Pending",
                body: "Your code is applied. It will qualify only after an eligible paid Pro purchase is confirmed."
            )
        case "qualified":
            AppliedStatusPresentation(
                title: "Qualified",
                body: "This referral has been confirmed."
            )
        case "reversed":
            AppliedStatusPresentation(
                title: "Reversed",
                body: "This referral is no longer qualified."
            )
        default:
            AppliedStatusPresentation(
                title: "Applied",
                body: "Your referral code has been saved."
            )
        }
    }

    // MARK: - Error copy (Phase 16) — never a raw backend string, OSStatus, or error description

    /// The single place ReferEarnView/ReferralCodeEntrySheet turn a thrown error from
    /// `ReferralManager.refresh()`/`applyReferralCode(_:)` into copy a user can read. Every known
    /// case is covered explicitly; anything this function doesn't recognize falls through to the
    /// same safe "temporarily unavailable" copy every other infrastructure-level failure gets —
    /// never `error.localizedDescription`, an OSStatus, or a raw backend code string.
    static func userFacingMessage(for error: ReferralServiceError) -> String {
        switch error {
        case .api(let apiError):
            return userFacingMessage(for: apiError)
        case .credentialUnavailable, .notConfigured, .network, .decoding, .invalidResponse:
            return temporarilyUnavailableMessage
        }
    }

    static func userFacingMessage(for apiError: ReferralAPIError) -> String {
        switch apiError.userFacing {
        case .invalidCode:
            "That referral code isn't valid."
        case .codeNotFound:
            "We couldn't find that referral code."
        case .selfReferral:
            "You can't use your own referral code."
        case .alreadyApplied:
            "A referral code has already been applied to this installation."
        case .identityConflict:
            "We couldn't verify your account right now. Please try again, or contact support if this continues."
        case .rateLimited:
            "Too many attempts. Try again shortly."
        case .temporarilyUnavailable:
            temporarilyUnavailableMessage
        }
    }

    /// Generic copy for the referral progress screen's own load/refresh failure card — distinct
    /// wording from the apply-sheet's inline error, matched to this feature's own task spec.
    static let referralProgressUnavailableTitle = "Referral progress unavailable"
    static let referralProgressUnavailableBody =
        "We couldn't load your referral progress right now. Your referral identity is still saved safely on this device."

    private static let temporarilyUnavailableMessage = "Referral service is temporarily unavailable. Try again."

    // MARK: - Diagnostic support codes (privacy-safe — never raw backend/error content)

    /// Stable, non-sensitive support codes for the referral progress screen's own error card —
    /// lets support identify WHICH typed failure occurred on a real device without ever seeing a
    /// raw backend string, an HTTP status/body, `error.localizedDescription`, an OSStatus, or any
    /// installation/participant/attribution/reward identifier. Pure and deterministic: the same
    /// `ReferralServiceError` case always maps to the same code. Deliberately never reads
    /// `.network(String)`'s associated string or `.api(.unrecognized(code:statusCode:))`'s
    /// associated values — both collapse to one fixed code each (REF-NETWORK, REF-API-OTHER)
    /// regardless of what they actually contain, so this can never become a second channel for
    /// leaking arbitrary error content through a "support code."
    static func diagnosticCode(for error: ReferralServiceError) -> String {
        switch error {
        case .notConfigured: "REF-CONFIG"
        case .credentialUnavailable: "REF-KEYCHAIN"
        case .network: "REF-NETWORK"
        case .decoding: "REF-DECODE"
        case .invalidResponse: "REF-RESPONSE"
        case .api(let apiError): diagnosticCode(for: apiError)
        }
    }

    static func diagnosticCode(for apiError: ReferralAPIError) -> String {
        switch apiError {
        case .invalidAPIKey: "REF-API-KEY"
        case .invalidInstallationCredentials: "REF-INSTALL-AUTH"
        case .invalidRequestBody: "REF-API-BODY"
        case .unknownAction: "REF-API-ACTION"
        case .invalidReferralCode: "REF-CODE-FORMAT"
        case .referralCodeNotFound: "REF-CODE-NOTFOUND"
        case .selfReferralNotAllowed: "REF-SELF"
        case .referralAlreadyApplied: "REF-ALREADY"
        case .revenueCatIdentityConflict: "REF-RC-CONFLICT"
        case .rateLimited: "REF-RATE"
        case .serviceUnavailable: "REF-SERVICE"
        case .internalError: "REF-INTERNAL"
        case .revenueCatLookupFailed: "REF-RC-LOOKUP"
        case .environmentUnresolvable: "REF-ENV-UNRESOLVED"
        case .unrecognized: "REF-API-OTHER"
        }
    }

    /// The optional "Copy Support Code" button's clipboard text — public app metadata
    /// (version/build, already shown in AboutView.swift) plus the diagnostic code above, and
    /// nothing else. `appVersion`/`buildNumber` are passed in rather than read from `Bundle.main`
    /// here, keeping this pure/directly-testable — see this file's own header on why nothing here
    /// performs I/O of any kind.
    static func supportCodeCopyText(diagnosticCode: String, appVersion: String, buildNumber: String) -> String {
        """
        85Blends Refer & Earn
        Support code: \(diagnosticCode)
        App version: \(appVersion)
        Build: \(buildNumber)
        """
    }

    // MARK: - Reward redemption (85Blends 2.4.0 Referral Reward Redemption)

    /// Defensive dual-format ISO 8601 parse for `ReferralStatus.issuedRewardExpiresAtRaw` — tries
    /// with fractional seconds first (what this feature's own backend actually emits, via
    /// JavaScript's `Date.prototype.toISOString()`), then falls back to the plain form, so this
    /// never depends on exactly which subset of ISO 8601 the backend happens to produce. Returns
    /// `nil` for `nil`/malformed input — never guessed, and never crashes.
    static func parseISO8601Date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// "1 Free Month Ready" / "2 Free Months Ready" — the reward card headline this feature's task
    /// spec calls for, pluralized correctly.
    static func rewardCardHeadline(earnedMonthsAvailable: Int) -> String {
        earnedMonthsAvailable == 1 ? "1 Free Month Ready" : "\(earnedMonthsAvailable) Free Months Ready"
    }

    /// 85Blends 2.4.0 third correctness hardening pass. Refer & Earn's reward card/redemption sheet
    /// has THREE distinct backend-driven states, not one — `earnedMonthsAvailable > 0` is never
    /// sufficient on its own: the moment `claim_reward` succeeds, the reward's own status becomes
    /// `issued` and `earnedMonthsAvailable` correctly drops to 0 (it's no longer "available to
    /// claim" — see `buildReferralStatusResponse`'s own doc comment), yet the user still needs an
    /// entry point back to the sheet to see/copy/redeem the code they just claimed. Likewise, an
    /// issued code that expires unused before the client ever calls `claim_reward` again produces
    /// `earnedMonthsAvailable == 0 && issuedRewardCode == nil` — with no signal at all, EVERY client
    /// entry point capable of recovering the reward would disappear, stranding it permanently even
    /// though the backend's own `claim_referral_reward` already knows how to recover it (void the
    /// dead code, revalidate, reissue or revoke). `issuedRewardNeedsRefresh` closes that gap. Order
    /// matters: a live issued code always wins over a stale `earnedMonthsAvailable` (structurally
    /// they're never both meaningfully true at once, but a live code is the more specific, more
    /// actionable state either way).
    enum RewardCardState: Equatable, Sendable {
        /// One or more rewards are `earned` and unclaimed — the normal "go claim it" state.
        case earned(count: Int)
        /// A reward already has a LIVE, unexpired issued Apple code — reopen the sheet to see/copy/
        /// redeem it, never re-claim.
        case issuedCode
        /// A reward is `issued` but its code has expired — the ONLY remaining way back to the
        /// backend's own expiration-revalidation logic is calling `claim_reward` again.
        case needsRefresh
    }

    /// Returns `nil` when there is nothing at all for the reward card to show — no fields threaded
    /// through beyond the three backend-sourced primitives this already needs, matching this file's
    /// existing "pass primitives, not the whole model" convention (see `entryEligibility` above).
    static func rewardCardState(
        earnedMonthsAvailable: Int,
        issuedRewardCode: String?,
        issuedRewardNeedsRefresh: Bool
    ) -> RewardCardState? {
        if issuedRewardCode != nil { return .issuedCode }
        if earnedMonthsAvailable > 0 { return .earned(count: earnedMonthsAvailable) }
        if issuedRewardNeedsRefresh { return .needsRefresh }
        return nil
    }

    /// The reward card's headline for each state — "1 Free Month Ready" reuses
    /// `rewardCardHeadline(earnedMonthsAvailable:)` above; the other two states are never about an
    /// available-to-claim count, so they get their own fixed copy.
    static func rewardCardHeadline(for state: RewardCardState) -> String {
        switch state {
        case .earned(let count): rewardCardHeadline(earnedMonthsAvailable: count)
        case .issuedCode: "Free Month Ready to Redeem"
        case .needsRefresh: "Free Month Needs Refresh"
        }
    }

    /// The reward card's subtitle for each state — never the raw Apple code or expiration itself
    /// (that lives inside the redemption sheet only).
    static func rewardCardSubtitle(for state: RewardCardState) -> String {
        switch state {
        case .earned: "Tap to redeem your free month."
        case .issuedCode: "You have a code ready in the App Store."
        case .needsRefresh: "Tap to refresh your referral reward."
        }
    }

    /// The pre-claim confirmation disclosure this feature's task spec requires ("Before requesting
    /// claim_reward, show a clear confirmation") — `displayPrice`/`billingPeriodLabel` are always
    /// REAL, currently loaded values from SubscriptionManager.displayPrice(for:)/ProPlan, never a
    /// hardcoded duplicate (see this feature's task spec: "Do not claim these prices from duplicated
    /// hardcoded data").
    ///
    /// 85Blends 2.4.0 Sandbox redemption fix — composes from `renewalPrice(...)` (the bare
    /// "$3.99/month" fragment), NOT `renewalPriceLine(...)`: live TestFlight testing showed the
    /// previous version wrapped the full renewal LINE (which already ends in "after the free
    /// month") in a sentence that itself begins "After the free month, ..." — producing
    /// "...renews at $3.99/month after the free month unless cancelled." with the phrase twice.
    /// The exact target wording is asserted by ReferralPresentationTests.
    static func redemptionConfirmationCopy(displayPrice: String, billingPeriodLabel: String) -> String {
        let price = renewalPrice(displayPrice: displayPrice, billingPeriodLabel: billingPeriodLabel)
        return "You'll receive 1 month of 85Blends Pro free. After the free month, this subscription renews at \(price) unless cancelled."
    }

    /// "$3.99/month" — the bare price-per-period fragment both `renewalPriceLine` (plan picker rows)
    /// and `redemptionConfirmationCopy` (confirmation dialog) build on, so the two can never drift
    /// apart on how a price and period are joined. Built from REAL, currently loaded
    /// SubscriptionManager values, never a second hardcoded price table. `billingPeriodLabel`
    /// mirrors ProPlan.fallbackBillingPeriodLabel's own wording ("month" / "3 months" / "year").
    static func renewalPrice(displayPrice: String, billingPeriodLabel: String) -> String {
        "\(displayPrice)/\(billingPeriodLabel)"
    }

    /// "$3.99/month after the free month" style renewal line for the plan picker rows — the one
    /// place this suffix belongs (the row has no surrounding sentence to say it). Unchanged output
    /// from before the Sandbox redemption fix; see `redemptionConfirmationCopy` for why the
    /// confirmation dialog deliberately does NOT reuse this.
    static func renewalPriceLine(displayPrice: String, billingPeriodLabel: String) -> String {
        "\(renewalPrice(displayPrice: displayPrice, billingPeriodLabel: billingPeriodLabel)) after the free month"
    }

    /// Safe, user-facing copy for every `ReferralClaimRewardResponse.claimStatus` value — never the
    /// raw backend string (same "never print raw status strings" discipline as
    /// `appliedStatusPresentation` above). `nil` for `"claimed"`, which the view handles as its own
    /// success state rather than an informational message.
    static func claimStatusMessage(_ claimStatus: String) -> String? {
        switch claimStatus {
        case "claimed":
            nil
        case "no_eligible_reward":
            "You don't have a free month available to redeem right now."
        case "no_code_available":
            "We're temporarily out of redemption codes for this plan. Please check back soon — your reward is still saved."
        case "legacy_or_unsupported_product_active", "invalid_product":
            "We couldn't match your current plan to a supported reward. Please contact support."
        case "outstanding_reward_exists":
            "You already have a redemption in progress. Finish that one first."
        // 85Blends 2.4.0 Referral Reward Redemption, second correctness hardening pass: the
        // previously-issued code for this reward expired unused, and a fresh recount found the
        // milestone itself no longer justified (the referrer's qualified-referral count has since
        // dropped) — no replacement code exists to issue. Distinct from "temporarily unavailable":
        // this outcome is not retryable, so it gets its own explanatory copy rather than the
        // generic fallback below.
        case "expired_no_longer_qualified":
            "Your previous redemption code expired, and this reward is no longer available since your qualified referral count has since changed."
        case "invalid_participant":
            temporarilyUnavailableMessage
        default:
            temporarilyUnavailableMessage
        }
    }

    // MARK: - Redemption route + return reconciliation (85Blends 2.4.0 Sandbox redemption fix)

    /// Which redemption path ReferralRewardRedemptionSheet offers for an issued code. Live
    /// TestFlight testing (Build 216) established that Apple's EXTERNAL redemption URL
    /// (`AppStoreDestination.redeemOfferCode(_:)` → apps.apple.com/redeem?ctx=offercodes...) rejects
    /// a Sandbox one-time-use Offer Code ("Cannot Redeem Code — The code entered is not valid"),
    /// while the very same code redeems correctly through Apple's Sandbox path. Sandbox/TestFlight
    /// installations therefore get StoreKit's in-app system redemption sheet
    /// (`View.offerCodeRedemption(isPresented:onCompletion:)`, iOS 16+) instead; PRODUCTION keeps the
    /// exact pre-existing external URL behavior, byte-for-byte.
    enum RedemptionRoute: Equatable, Sendable {
        /// The unchanged production path — open Apple's pre-filled external App Store redemption URL.
        case appStoreURL
        /// Sandbox/TestFlight only — present StoreKit's native in-app Offer Code redemption sheet
        /// (the user pastes the code; StoreKit never accepts it programmatically).
        case sandboxNativeSheet
    }

    /// `environment` is `ReferralManager.bootstrappedEnvironment` — the exact, VERIFIED
    /// `AppTransaction`-derived SANDBOX/PRODUCTION value this installation's most recent successful
    /// `bootstrap` call sent the backend, i.e. the same value the backend then tagged this very
    /// issued code with (`private.referral_client_installations.current_environment` →
    /// `claim_referral_reward(p_environment)`). Never DEBUG, the bundle receipt filename, a build
    /// number, or a TestFlight guess — see ReferralRevenueEnvironmentProviding.swift's header.
    ///
    /// `nil` ("unknown") deliberately routes to the PRODUCTION path — the pre-existing behavior —
    /// never to the Sandbox sheet: Sandbox UI must never be shown to a real production user on the
    /// strength of a missing signal. In practice `nil` is unreachable at the point this is consulted
    /// (an issued code only ever appears in a `.loaded` status, which requires the bootstrap that
    /// records the environment to have already succeeded this process), but it is handled
    /// explicitly rather than assumed away.
    static func redemptionRoute(environment: ReferralRevenueEnvironment?) -> RedemptionRoute {
        environment == .sandbox ? .sandboxNativeSheet : .appStoreURL
    }

    /// Sandbox-only helper copy shown under the native-sheet button. Never contains the code itself.
    static let sandboxRedemptionHelpText =
        "Testing with an Apple Sandbox account. Your code has been copied so you can paste it into Apple's redemption sheet."

    /// The small, NON-SENSITIVE outcome of the post-redemption RevenueCat reconciliation
    /// (`SubscriptionManager.syncAfterExternalRedemption()`'s own Bool) — enough for the sheet to
    /// distinguish "sync ran fine but no webhook has confirmed anything yet" from "sync itself
    /// couldn't run," which Build 216 (which discarded that Bool) could not. Carries no error
    /// payload by construction: a failed sync is represented by a bare case, never by
    /// `error.localizedDescription`, an App User ID, a transaction id, or any RevenueCat detail.
    /// NEVER a redemption/fulfillment state — `.completed` means the sync call succeeded, nothing
    /// more; fulfillment remains exclusively the backend/webhook's to report via ReferralStatus.
    enum RedemptionSyncState: Equatable, Sendable {
        case idle
        case syncing
        case completed
        case failed
    }

    /// Neutral copy for each sync state. `.completed` still reads as "awaiting confirmation" on
    /// purpose: this line is only ever shown while the backend still reports the code as issued, so
    /// a successful sync has not (yet) changed anything the user can see. `.failed` explicitly
    /// reassures that the code is intact — a failed sync must never read as a failed redemption.
    static func redemptionSyncMessage(for state: RedemptionSyncState) -> String? {
        switch state {
        case .idle: nil
        case .syncing: "Checking redemption…"
        case .completed: "Redemption is still awaiting confirmation."
        case .failed: "We couldn't refresh the purchase yet. Your reward code is still safe. Try again shortly."
        }
    }

    /// The return-from-redemption reconciliation sequence, with its two side effects injected so
    /// the ORDER and UNCONDITIONALITY are directly testable: `sync` first, then `refresh` ALWAYS —
    /// a failed sync never skips the referral refresh (the backend/webhook may have confirmed the
    /// redemption regardless of whether this device's own RevenueCat sync succeeded). Returns only
    /// `.completed`/`.failed` from `sync`'s Bool; never inspects, invents, or caches any reward
    /// state — the caller re-reads `ReferralManager.shared.loadState` after `refresh` for that.
    /// `@MainActor` because both real closures call `@MainActor`-isolated singletons
    /// (SubscriptionManager/ReferralManager) and the only caller is a SwiftUI view.
    @MainActor
    static func reconcileAfterRedemption(
        sync: () async -> Bool,
        refresh: () async -> Void
    ) async -> RedemptionSyncState {
        let synced = await sync()
        await refresh()
        return synced ? .completed : .failed
    }

    // MARK: - Share text (Phase 9)

    /// Never includes the installation ID, RevenueCat App User ID, installation secret, or any
    /// backend-private identifier — structurally impossible, since this function's only input is
    /// the user's own public referral code.
    static func shareText(code: String) -> String {
        """
        I use 85Blends to find E85 and compare fuel costs.

        Download 85Blends:
        \(AppStoreDestination.share.absoluteString)

        Use my referral code \(code) before subscribing to 85Blends Pro.
        """
    }
}

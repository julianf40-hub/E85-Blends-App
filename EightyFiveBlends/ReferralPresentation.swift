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

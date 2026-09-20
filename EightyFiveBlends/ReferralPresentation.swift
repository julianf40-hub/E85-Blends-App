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

    static func entryEligibility(canApplyReferralCode: Bool, isCurrentlyPro: Bool) -> EntryEligibility {
        guard canApplyReferralCode else { return .blockedCannotApply }
        return isCurrentlyPro ? .blockedAlreadyPro : .allowed
    }

    /// Whether the immutable "applied" state (Phase 17) must be shown instead of ANY code-entry
    /// UI — true exactly when a code has already been recorded for this installation. Checked
    /// BEFORE `entryEligibility` by the view: one referrer for life is immutable, so this alone
    /// is enough to rule out ever showing an entry field, independent of `canApplyReferralCode`.
    static func hasAppliedReferralCode(referredByCode: String?) -> Bool {
        referredByCode != nil
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

//
//  ReferEarnView.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — Refer & Earn UI. Available to every user, Free and Pro alike (see
//  MoreView.swift's own placement — never wrapped in an appExperienceMode/isProUser gate).
//  ReferralManager.shared is the ONLY referral-state authority this screen (or
//  ReferralCodeEntrySheet) ever reads — no URLSession, Keychain, RevenueCat App User ID, or direct
//  Supabase access here, and no local qualification/reward computation: every number shown comes
//  straight from the backend's own ReferralStatus. Reward redemption is intentionally not
//  implemented here — see Phase 20 of this feature's own task spec.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ReferEarnView: View {
    // Deliberately NOT injected via a default parameter value (`= .shared`) — both
    // ReferralManager and SubscriptionManager are @MainActor-isolated singletons, and a default
    // argument expression is not guaranteed to inherit a struct's own initializer isolation (see
    // RevenueCatSubscriptionService.swift's own header for the exact same issue previously hit in
    // this codebase). Every reference below reads `.shared` directly from inside `body`/its own
    // computed properties, which are already @MainActor-isolated via View's own protocol
    // requirement — no default-parameter-expression ambiguity possible.
    @State private var isShowingCodeEntry = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                content
            }
            .padding(16)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("Refer & Earn")
        .navigationBarTitleDisplayMode(.inline)
        // Both the initial load and pull-to-refresh go through the exact same
        // ReferralManager.refresh() — there is no second networking layer here, and no separate
        // bootstrap call: refresh() already guarantees bootstrap-first ordering (see that
        // method's own header).
        .refreshable {
            await ReferralManager.shared.refresh()
        }
        .task {
            await ReferralManager.shared.refresh()
        }
        .sheet(isPresented: $isShowingCodeEntry) {
            ReferralCodeEntrySheet()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "gift.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .frame(width: 48, height: 48)
                    .background(AppTheme.Colors.stationYellow.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("REFER & EARN")
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text("Earn Free Pro")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
            }

            Text("Share 85Blends with friends. Every 5 qualified paid referrals earns you 1 free month of 85Blends Pro.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch ReferralManager.shared.loadState {
        case .idle, .loading:
            loadingSection
        case .failed:
            errorSection
        case .loaded(let status):
            // Both read from SubscriptionManager (never RevenueCatSubscriptionService/Purchases
            // directly) — the feature-facing subscription authority. SubscriptionManager is
            // @Observable, so once RevenueCat's initial entitlement fetch resolves, this view
            // re-renders automatically with no manual refresh needed.
            ReferEarnLoadedContent(
                status: status,
                isProUser: SubscriptionManager.shared.isProUser,
                isEntitlementResolutionPending: SubscriptionManager.shared.isInitialEntitlementResolutionPending,
                hasAuthoritativeProStatus: SubscriptionManager.shared.hasAuthoritativeProStatus,
                onEnterCode: {
                    AppHaptics.selection()
                    isShowingCodeEntry = true
                }
            )
        }
    }

    private var loadingSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(AppTheme.Colors.accentGreen)
            Text("Loading your referral progress…")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .accessibilityElement(children: .combine)
    }

    private var errorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            WarningCard(
                title: ReferralPresentation.referralProgressUnavailableTitle,
                message: ReferralPresentation.referralProgressUnavailableBody,
                systemImage: "wifi.exclamationmark"
            )

            SecondaryButton(title: "Try Again") {
                Task { await ReferralManager.shared.refresh() }
            }
        }
    }
}

/// The fully-loaded referral screen content — deliberately a standalone view taking a plain
/// `ReferralStatus`/`Bool` rather than reading `ReferralManager` itself, so it's previewable with
/// sample data without constructing a real manager (which would need real Keychain/StoreKit/
/// RevenueCat-backed dependencies) — see this feature's own task spec on previews.
struct ReferEarnLoadedContent: View {
    let status: ReferralStatus
    let isProUser: Bool
    /// True while RevenueCat's initial entitlement fetch hasn't resolved yet — see
    /// `SubscriptionManager.isInitialEntitlementResolutionPending`'s own header. `isProUser` alone
    /// can't distinguish "confirmed Free" from "not resolved yet," so this is threaded through
    /// separately and takes priority in `referredBySection` below.
    let isEntitlementResolutionPending: Bool
    /// True only once a real CustomerInfo result has actually been applied this process — see
    /// `SubscriptionManager.hasAuthoritativeProStatus`'s own header. Resolution finishing
    /// (`isEntitlementResolutionPending == false`) does NOT imply this: a failed first fetch also
    /// ends the resolution window, on purpose, without ever producing a real answer. Checked right
    /// after `isEntitlementResolutionPending` in `referredBySection` below, before `isProUser` is
    /// ever trusted.
    let hasAuthoritativeProStatus: Bool
    let onEnterCode: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            referralCodeCard
            progressCard
            earnedMonthsBanner
            statsSection
            referredBySection
            howItWorksCard
        }
    }

    // MARK: My Referral Code

    private var referralCodeCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("MY REFERRAL CODE")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text(status.referralCode)
                    .font(.system(.title, design: .monospaced).weight(.bold))
                    .tracking(6)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityLabel("Your referral code is \(spelledOutCode)")

                HStack(spacing: 12) {
                    Button(action: copyCode) {
                        HStack(spacing: 6) {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            Text(didCopy ? "Copied" : "Copy Code")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AppTheme.Colors.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy referral code")

                    ShareLink(item: ReferralPresentation.shareText(code: status.referralCode)) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.Colors.primaryGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .accessibilityLabel("Share your referral code")
                }
            }
        }
    }

    private var spelledOutCode: String {
        status.referralCode.map { String($0) }.joined(separator: " ")
    }

    private func copyCode() {
        #if os(iOS)
        UIPasteboard.general.string = status.referralCode
        #endif
        AppHaptics.success()
        withAnimation { didCopy = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { didCopy = false }
        }
    }

    // MARK: Progress

    private var progressCard: some View {
        let progress = ReferralPresentation.progressInCurrentCycle(referralsNeeded: status.referralsNeeded)
        let total = ReferralPresentation.referralsCycleLength

        return AppCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("PROGRESS TO NEXT FREE MONTH")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Text("\(progress) / \(total) qualified")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                ProgressView(value: Double(progress), total: Double(total))
                    .tint(AppTheme.Colors.accentGreen)
                    .accessibilityLabel("Referral progress")
                    .accessibilityValue("\(progress) of \(total) qualified referrals")

                Text(ReferralPresentation.referralsNeededCopy(status.referralsNeeded))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    // MARK: Earned months (display only — no redemption)

    @ViewBuilder
    private var earnedMonthsBanner: some View {
        if status.earnedMonthsAvailable > 0 {
            HStack(spacing: 12) {
                Image(systemName: "gift.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(earnedMonthsHeadline)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text("Reward redemption is coming in a future update.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(AppTheme.Colors.stationYellow.opacity(0.14))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.Colors.stationYellow.opacity(0.4), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(earnedMonthsHeadline)
        }
    }

    private var earnedMonthsHeadline: String {
        status.earnedMonthsAvailable == 1
            ? "1 free month earned"
            : "\(status.earnedMonthsAvailable) free months earned"
    }

    // MARK: Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                statTile(title: "Qualified", value: status.qualifiedReferrals, tint: AppTheme.Colors.accentGreen)
                statTile(title: "Pending", value: status.pendingReferrals, tint: AppTheme.Colors.stationYellow)
                statTile(title: "Free Months Earned", value: status.earnedMonthsAvailable, tint: AppTheme.Colors.accentGreen)
                statTile(title: "Rewards Used", value: status.fulfilledMonths, tint: AppTheme.Colors.textMuted)
            }

            Text("Pending referrals are waiting for a qualifying paid Pro purchase or backend verification.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
    }

    private func statTile(title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(value)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: Referred-by / entry (Phase 12/17/18)

    @ViewBuilder
    private var referredBySection: some View {
        // Applied-referral state always wins, independent of entitlement-resolution state — one
        // referrer for life is immutable, so a still-resolving Pro status can never replace this
        // card once a code is actually on record (Phase 6 of this pass's own task spec).
        if ReferralPresentation.hasAppliedReferralCode(referredByCode: status.referredByCode) {
            appliedReferralCard
        } else {
            switch ReferralPresentation.entryEligibility(
                canApplyReferralCode: status.canApplyReferralCode,
                isCurrentlyPro: isProUser,
                isEntitlementResolutionPending: isEntitlementResolutionPending,
                hasAuthoritativeProStatus: hasAuthoritativeProStatus
            ) {
            case .allowed:
                entryPromptCard
            case .waitingForSubscriptionStatus:
                checkingProStatusCard
            case .subscriptionStatusUnavailable:
                subscriptionStatusUnavailableCard
            case .blockedAlreadyPro:
                InfoCard(
                    title: "You're already subscribed to 85Blends Pro",
                    message: "Referral codes must be entered before the qualifying paid Pro purchase.",
                    systemImage: "crown.fill"
                )
            case .blockedCannotApply:
                // Defensive fallback — see ReferralPresentation.EntryEligibility's own header on
                // why this is not expected to be reachable in practice.
                InfoCard(
                    title: "Referral code entry isn't available",
                    message: "This installation can't apply a referral code right now."
                )
            }
        }
    }

    /// Neutral, non-error state shown while RevenueCat's initial entitlement fetch is still
    /// resolving — never the entry prompt (would risk letting an existing Pro subscriber apply a
    /// code) and never the "already Pro" warning (would risk wrongly telling an actual Free user
    /// they're blocked). No retry action — this clears itself the moment SubscriptionManager
    /// resolves, since `ReferEarnLoadedContent` re-renders automatically (it's driven by an
    /// @Observable read in ReferEarnView's own body).
    private var checkingProStatusCard: some View {
        AppCard {
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .tint(AppTheme.Colors.textMuted)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Checking Pro status")
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    Text("We're checking your 85Blends Pro status before allowing a referral code to be applied.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Checking Pro status. We're checking your 85Blends Pro status before allowing a referral code to be applied.")
    }

    /// Shown when the first resolution attempt has already finished
    /// (`isEntitlementResolutionPending == false`) but never actually produced a real answer
    /// (`hasAuthoritativeProStatus == false`) — i.e. that attempt failed. Distinct from
    /// `checkingProStatusCard` above: nothing is in flight here, so a spinner would be
    /// misleading — this offers an explicit retry instead. The retry calls ONLY
    /// `SubscriptionManager.shared.refreshProStatus()` (itself a thin wrapper around
    /// RevenueCat's existing manual-refresh path) — no purchase, no restore, no alert, and no
    /// referral-backend call; a successful refresh updates `@Observable` state and this card
    /// naturally gives way to either the entry prompt or the "already Pro" warning.
    private var subscriptionStatusUnavailableCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            WarningCard(
                title: "Unable to verify Pro status",
                message: "We need to verify your 85Blends Pro status before a referral code can be applied.",
                systemImage: "exclamationmark.triangle.fill"
            )

            SecondaryButton(title: "Try Again") {
                Task { await SubscriptionManager.shared.refreshProStatus() }
            }
        }
    }

    private var appliedReferralCard: some View {
        let presentation = ReferralPresentation.appliedStatusPresentation(status.referredStatus)
        return AppCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("REFERRAL CODE APPLIED")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                if let referredByCode = status.referredByCode {
                    Text(referredByCode)
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .tracking(3)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }

                HStack(spacing: 8) {
                    statusBadgeIcon
                    Text(presentation.title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }

                Text(presentation.body)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusBadgeIcon: some View {
        let (systemImage, color): (String, Color) = {
            switch status.referredStatus {
            case "qualified": return ("checkmark.circle.fill", AppTheme.Colors.accentGreen)
            case "reversed": return ("xmark.circle.fill", AppTheme.Colors.warningRed)
            default: return ("clock.fill", AppTheme.Colors.stationYellow)
            }
        }()
        return Image(systemName: systemImage)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private var entryPromptCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Have a referral code?")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                // Timing note (Phase 18) — placed directly before the entry action itself, never
                // implying a code entered after purchase can retroactively qualify.
                Text("Referral codes must be applied before the qualifying paid Pro purchase.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                SecondaryButton(title: "Enter Referral Code", action: onEnterCode)
            }
        }
    }

    // MARK: How It Works

    private var howItWorksCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("HOW IT WORKS")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                howItWorksStep(number: 1, text: "Share your code")
                howItWorksStep(number: 2, text: "Your friend enters it before subscribing to Pro")
                howItWorksStep(number: 3, text: "Their eligible paid Pro purchase is verified")
                howItWorksStep(number: 4, text: "Every 5 qualified referrals earns you 1 free month")

                Text("Refunded purchases may affect referral qualification.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }
        }
    }

    private func howItWorksStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.Colors.charcoal)
                .frame(width: 24, height: 24)
                .background(AppTheme.Colors.accentGreen)
                .clipShape(Circle())
                .accessibilityHidden(true)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }
}

// MARK: - Previews (sample data only — never the real ReferralManager; see this file's header)

private func previewStatus(
    referralCode: String = "ABCD2345",
    qualifiedReferrals: Int = 2,
    pendingReferrals: Int = 1,
    earnedMonthsAvailable: Int = 0,
    fulfilledMonths: Int = 0,
    nextMilestoneNumber: Int = 1,
    nextRewardAt: Int = 5,
    referralsNeeded: Int = 3,
    canApplyReferralCode: Bool = true,
    referredByCode: String? = nil,
    referredStatus: String? = nil
) -> ReferralStatus {
    ReferralStatus(
        referralCode: referralCode,
        qualifiedReferrals: qualifiedReferrals,
        pendingReferrals: pendingReferrals,
        earnedMonthsAvailable: earnedMonthsAvailable,
        fulfilledMonths: fulfilledMonths,
        nextMilestoneNumber: nextMilestoneNumber,
        nextRewardAt: nextRewardAt,
        referralsNeeded: referralsNeeded,
        canApplyReferralCode: canApplyReferralCode,
        referredByCode: referredByCode,
        referredStatus: referredStatus
    )
}

#Preview("New Free user") {
    ScrollView {
        ReferEarnLoadedContent(
            status: previewStatus(qualifiedReferrals: 0, pendingReferrals: 0, referralsNeeded: 5),
            isProUser: false,
            isEntitlementResolutionPending: false,
            hasAuthoritativeProStatus: true,
            onEnterCode: {}
        )
        .padding(16)
    }
    .background(AppTheme.Colors.charcoal)
}

#Preview("Pro user — entry unavailable") {
    ScrollView {
        ReferEarnLoadedContent(
            status: previewStatus(qualifiedReferrals: 0, pendingReferrals: 0, referralsNeeded: 5),
            isProUser: true,
            isEntitlementResolutionPending: false,
            hasAuthoritativeProStatus: true,
            onEnterCode: {}
        )
        .padding(16)
    }
    .background(AppTheme.Colors.charcoal)
}

#Preview("Checking Pro status") {
    ScrollView {
        ReferEarnLoadedContent(
            status: previewStatus(qualifiedReferrals: 0, pendingReferrals: 0, referralsNeeded: 5),
            isProUser: false,
            isEntitlementResolutionPending: true,
            hasAuthoritativeProStatus: false,
            onEnterCode: {}
        )
        .padding(16)
    }
    .background(AppTheme.Colors.charcoal)
}

#Preview("Unable to verify Pro status") {
    ScrollView {
        ReferEarnLoadedContent(
            status: previewStatus(qualifiedReferrals: 0, pendingReferrals: 0, referralsNeeded: 5),
            isProUser: false,
            isEntitlementResolutionPending: false,
            hasAuthoritativeProStatus: false,
            onEnterCode: {}
        )
        .padding(16)
    }
    .background(AppTheme.Colors.charcoal)
}

#Preview("Multiple earned months") {
    ScrollView {
        ReferEarnLoadedContent(
            status: previewStatus(qualifiedReferrals: 12, pendingReferrals: 2, earnedMonthsAvailable: 2, fulfilledMonths: 1, referralsNeeded: 3),
            isProUser: false,
            isEntitlementResolutionPending: false,
            hasAuthoritativeProStatus: true,
            onEnterCode: {}
        )
        .padding(16)
    }
    .background(AppTheme.Colors.charcoal)
}

#Preview("Applied — pending") {
    ScrollView {
        ReferEarnLoadedContent(
            status: previewStatus(canApplyReferralCode: false, referredByCode: "WXYZ6789", referredStatus: "pending"),
            isProUser: false,
            isEntitlementResolutionPending: false,
            hasAuthoritativeProStatus: true,
            onEnterCode: {}
        )
        .padding(16)
    }
    .background(AppTheme.Colors.charcoal)
}

#Preview("Applied — qualified") {
    ScrollView {
        ReferEarnLoadedContent(
            status: previewStatus(canApplyReferralCode: false, referredByCode: "WXYZ6789", referredStatus: "qualified"),
            isProUser: false,
            isEntitlementResolutionPending: false,
            hasAuthoritativeProStatus: true,
            onEnterCode: {}
        )
        .padding(16)
    }
    .background(AppTheme.Colors.charcoal)
}

#Preview("Applied — reversed") {
    ScrollView {
        ReferEarnLoadedContent(
            status: previewStatus(canApplyReferralCode: false, referredByCode: "WXYZ6789", referredStatus: "reversed"),
            isProUser: false,
            isEntitlementResolutionPending: false,
            hasAuthoritativeProStatus: true,
            onEnterCode: {}
        )
        .padding(16)
    }
    .background(AppTheme.Colors.charcoal)
}

#Preview("Live (real ReferralManager)") {
    NavigationStack {
        ReferEarnView()
    }
}

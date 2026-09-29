//
//  ReferralRewardRedemptionSheet.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 Referral Reward Redemption. The real redemption experience presented from
//  ReferEarnView's earned-months reward card — replaces the old
//  "Reward redemption is coming in a future update." placeholder entirely.
//
//  BACKEND IS AUTHORITATIVE (this feature's task spec, Phase 1): this sheet never decides whether
//  the user owns a reward, which product an active subscriber's code is for, or whether a
//  redemption has actually been fulfilled — every one of those comes from a
//  ReferralManager.shared.claimReward(requestedProductID:) response or a subsequent
//  ReferralManager.shared.refresh(). In particular, this sheet NEVER locally marks a reward
//  fulfilled: only a real webhook-confirmed redemption ever clears `issuedRewardCode`/increments
//  `fulfilledMonths` (see ReferralManager's own "BACKEND STATUS IS AUTHORITATIVE" header) — tapping
//  "Redeem in App Store" only opens Apple's own redemption sheet and refreshes state on return; it
//  never assumes that tap succeeded.
//
//  SANDBOX/TESTFLIGHT REDEMPTION PATH (85Blends 2.4.0 Sandbox redemption fix): live TestFlight
//  testing showed Apple's external `apps.apple.com/redeem?ctx=offercodes` URL rejects a Sandbox
//  one-time-use Offer Code, while the same code redeems fine through Apple's Sandbox path. When —
//  and only when — this installation's own verified bootstrap environment is SANDBOX (see
//  `ReferralPresentation.redemptionRoute(environment:)` and `ReferralManager.bootstrappedEnvironment`),
//  the primary action instead copies the issued code to the pasteboard and presents StoreKit's
//  native in-app redemption sheet (`View.offerCodeRedemption(isPresented:onCompletion:)`, iOS 16+;
//  StoreKit never accepts a code programmatically, so the tester pastes it). PRODUCTION behavior is
//  unchanged. Both paths run the SAME return reconciliation (`syncAfterExternalRedemption()` then
//  `ReferralManager.shared.refresh()`, via `ReferralPresentation.reconcileAfterRedemption`) and
//  neither ever locally marks anything redeemed/fulfilled — the webhook remains the only authority.
//
//  Mirrors ReferralCodeEntrySheet.swift's established conventions: reads ReferralManager.shared /
//  SubscriptionManager.shared directly (never injected via a default parameter — both are
//  @MainActor-isolated singletons; see ReferEarnView.swift's own header for why), confirms before
//  ever calling the backend, and never dismisses on a claim outcome other than the user's own
//  explicit "Close" — the code (once issued) must stay visible until the user is done with it.
//

import StoreKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ReferralRewardRedemptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// Free/Expired-user plan choice only — never consulted for an active Pro subscriber (see
    /// ReferralClaimRewardRequest's own header: the backend ignores it in that case regardless).
    @State private var selectedPlan: ProPlan?
    @State private var isShowingConfirmation = false
    @State private var isClaiming = false
    /// Set only from a thrown ReferralServiceError, or a non-"claimed" backend claim outcome — see
    /// `claim()`. Always safe, user-facing copy (ReferralPresentation), never a raw backend string.
    @State private var claimMessage: String?
    /// True once this session has tapped "Redeem in App Store" for the CURRENTLY issued code —
    /// reset whenever the issued code itself changes (a fresh claim, or fulfillment clearing it) —
    /// see the `onChange` below. Purely local UI state: the backend has no way to know whether the
    /// user actually tapped through to the App Store, only whether a webhook later confirms
    /// redemption (see this feature's own task spec, Phase 6: "Until webhook confirmation arrives,
    /// show a neutral state... Do not show failure just because RevenueCat has not processed the
    /// transaction yet.").
    @State private var hasStartedRedemption = false
    @State private var didCopyCode = false
    /// Sandbox/TestFlight only — drives StoreKit's own `offerCodeRedemption(isPresented:)` sheet.
    /// Never becomes `true` on the production route (see `redemptionRoute`).
    @State private var isPresentingSandboxRedemptionSheet = false
    /// Small, non-sensitive outcome of the most recent return reconciliation — see
    /// `ReferralPresentation.RedemptionSyncState`. Reset whenever the issued code changes. Never a
    /// redemption/fulfillment state (a failed sync leaves the code issued and visible).
    @State private var syncState: ReferralPresentation.RedemptionSyncState = .idle

    private var status: ReferralStatus? {
        if case .loaded(let loadedStatus) = ReferralManager.shared.loadState {
            return loadedStatus
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let status {
                        content(for: status)
                    } else {
                        ProgressView()
                            .tint(AppTheme.Colors.accentGreen)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppTheme.Colors.charcoal)
            .navigationTitle("Redeem Free Month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isClaiming)
                }
            }
        }
        .interactiveDismissDisabled(isClaiming)
        .onChange(of: status?.issuedRewardCode) { _, _ in
            hasStartedRedemption = false
            syncState = .idle
        }
        // Return-from-App-Store refresh (this feature's task spec, Phase 6) — only fires when THIS
        // sheet actually sent the user to the App Store this session; an unrelated background/
        // foreground cycle (e.g. the user just switched to another app and back) never triggers an
        // extra referral-backend/RevenueCat call it didn't need to make.
        //
        // syncAfterExternalRedemption() — NOT refreshProStatus()/refreshCustomerInfoNow() — is the
        // correct reconciliation call here: an Offer Code redeemed through the EXTERNAL App Store
        // redemption URL creates a subscription transaction this app's own RevenueCat SDK instance
        // never directly observed, and RevenueCat's own documented flow for exactly this situation
        // is `syncPurchases()` (see RevenueCatSubscriptionService.syncAfterExternalRedemption()'s
        // own header), not a plain CustomerInfo refresh (which only re-reads RevenueCat's existing
        // cached/server state — it does not itself prompt RevenueCat to go sync anything new from
        // the App Store) and not `restorePurchases()` (user-facing restore semantics/UI this
        // automatic return-from-redemption path must never trigger). Its own result is never
        // treated as success/failure here — a failed sync is still followed by the SAME
        // ReferralManager refresh below, and this sheet's own UI stays in its existing neutral
        // "pending confirmation" state regardless (see issuedCodeSection) until the backend/webhook
        // actually confirms fulfillment — never a locally-fabricated fulfilled state either way.
        //
        // Sandbox redemption fix: the Bool this discards was the one signal that could tell "sync ran
        // but RevenueCat emitted no webhook" apart from "sync itself failed" during live testing — it
        // now feeds `syncState` (neutral copy only; see ReferralPresentation.redemptionSyncMessage).
        // Skipped while a reconciliation is already in flight so the native Sandbox sheet's own
        // completion callback (below) and a scene re-activation for the same dismissal can't run it
        // twice back to back.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, hasStartedRedemption, isPresentingSandboxRedemptionSheet == false else { return }
            Task { await reconcileAfterRedemption() }
        }
        // Sandbox/TestFlight only (see this file's header). StoreKit itself flips `isPresented`
        // back to false on dismissal, then calls `onCompletion`; the result is deliberately NOT
        // inspected — a thrown presentation error, a cancelled sheet, and a successful redemption
        // all lead to the exact same neutral reconciliation, never a locally-decided outcome.
        .offerCodeRedemption(isPresented: $isPresentingSandboxRedemptionSheet) { _ in
            Task { await reconcileAfterRedemption() }
        }
        .confirmationDialog(
            currentClaimMode == .refresh ? "Refresh your reward?" : "Redeem your free month?",
            isPresented: $isShowingConfirmation,
            titleVisibility: .visible
        ) {
            Button(buttonTitle(for: currentClaimMode ?? .newClaim)) {
                Task { await claim() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    /// Recomputed from `status` rather than captured `@State` at the moment the confirmation was
    /// requested — no network call happens between opening the confirmation and the user's answer,
    /// so `status` cannot have changed underneath it, and this keeps the dialog's own copy in sync
    /// with `content(for:)` above by construction rather than a second, independently-tracked flag.
    private var currentClaimMode: ClaimMode? {
        guard let status else { return nil }
        switch cardState(for: status) {
        case .earned: return .newClaim
        case .needsRefresh: return .refresh
        case .issuedCode, nil: return nil
        }
    }

    // MARK: - Content

    /// 85Blends 2.4.0 third correctness hardening pass — the SAME `ReferralPresentation.rewardCardState`
    /// ReferEarnView's own card uses, so the sheet's content and the card that opened it can never
    /// disagree about which of the three states applies. `nil` (nothing to redeem) is the one case
    /// this sheet still handles itself, below.
    private func cardState(for status: ReferralStatus) -> ReferralPresentation.RewardCardState? {
        ReferralPresentation.rewardCardState(
            earnedMonthsAvailable: status.earnedMonthsAvailable,
            issuedRewardCode: status.issuedRewardCode,
            issuedRewardNeedsRefresh: status.issuedRewardNeedsRefresh
        )
    }

    @ViewBuilder
    private func content(for status: ReferralStatus) -> some View {
        switch cardState(for: status) {
        case .issuedCode:
            issuedCodeSection(status: status)
        case .earned:
            eligibilitySection(mode: .newClaim)
        case .needsRefresh:
            eligibilitySection(mode: .refresh)
        case nil:
            // Defensive — ReferEarnView only ever presents this sheet while `rewardCardState` is
            // non-nil; a fulfillment (or a no-longer-qualified revocation from a refresh attempt)
            // confirmed while this sheet happened to already be open lands here instead, and is
            // exactly the state to show — including any explanatory `claimMessage` from that same
            // refresh attempt (see `claim()`).
            fulfilledOrNothingToRedeemSection
        }
    }

    /// Distinguishes claiming a fresh reward from refreshing one whose issued code already expired
    /// — both ultimately call the SAME `ReferralManager.shared.claimReward(requestedProductID:)`;
    /// `private.claim_referral_reward` alone decides what actually happens (reissue vs. revoke —
    /// see this file's own header, "BACKEND IS AUTHORITATIVE"). This enum only ever picks COPY.
    private enum ClaimMode {
        case newClaim
        case refresh
    }

    private func eligibilitySection(mode: ClaimMode) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(headline(for: mode))
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            if mode == .refresh {
                Text("Your previous code expired unused. We'll check whether your reward is still available and issue a new code if so.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            if let claimMessage {
                WarningCard(title: "Redemption unavailable", message: claimMessage, systemImage: "exclamationmark.triangle.fill")
            }

            if isActiveProSubscriber {
                activeSubscriberCard(mode: mode)
            } else {
                planPickerCard(mode: mode)
            }
        }
    }

    private func headline(for mode: ClaimMode) -> String {
        switch mode {
        case .newClaim: ReferralPresentation.rewardCardHeadline(earnedMonthsAvailable: status?.earnedMonthsAvailable ?? 0)
        case .refresh: "Refresh Your Reward"
        }
    }

    private func buttonTitle(for mode: ClaimMode) -> String {
        switch mode {
        case .newClaim: "Redeem Free Month"
        case .refresh: "Refresh Reward"
        }
    }

    private var isActiveProSubscriber: Bool {
        SubscriptionManager.shared.hasAuthoritativeProStatus && SubscriptionManager.shared.isProUser
    }

    private func activeSubscriberCard(mode: ClaimMode) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Apply 1 free month to your current 85Blends Pro plan.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                redeemButton(title: buttonTitle(for: mode), isEnabled: true) {
                    isShowingConfirmation = true
                }
            }
        }
    }

    private func planPickerCard(mode: ClaimMode) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose a plan for your free month:")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                ForEach(ProPlan.allCases) { plan in
                    planRow(plan)
                }

                redeemButton(title: buttonTitle(for: mode), isEnabled: selectedPlan != nil) {
                    isShowingConfirmation = true
                }
            }
        }
    }

    private func planRow(_ plan: ProPlan) -> some View {
        let isSelected = selectedPlan == plan
        return Button {
            AppHaptics.selection()
            selectedPlan = plan
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(ReferralPresentation.renewalPriceLine(
                        displayPrice: SubscriptionManager.shared.displayPrice(for: plan),
                        billingPeriodLabel: plan.fallbackBillingPeriodLabel
                    ))
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppTheme.Colors.accentGreen : AppTheme.Colors.textMuted)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(isSelected ? AppTheme.Colors.accentGreen.opacity(0.12) : AppTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? AppTheme.Colors.accentGreen : AppTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(plan.title), \(SubscriptionManager.shared.displayPrice(for: plan)) after the free month")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func redeemButton(title: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            AppHaptics.selection()
            action()
        } label: {
            Group {
                if isClaiming {
                    ProgressView().tint(AppTheme.Colors.textPrimary)
                } else {
                    Text(title).font(.headline)
                }
            }
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isEnabled ? AppTheme.Colors.primaryGreen : AppTheme.Colors.primaryGreen.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false || isClaiming)
        .accessibilityLabel(isClaiming ? "Redeeming" : title)
    }

    private var confirmationMessage: String {
        if currentClaimMode == .refresh {
            return "We'll check whether your reward is still available and issue a new code if so. If it's no longer available, we'll let you know."
        }
        if isActiveProSubscriber {
            // No specific renewal price shown here — this app has no backend-authoritative signal
            // for WHICH of the three plans an active subscriber is currently on (see
            // SubscriptionManager.swift's own header: it exposes only a plan-agnostic `isPro`, by
            // design). Never guessing a number is safer than fabricating a possibly-wrong one — see
            // this feature's own task spec: "Do not claim these prices from duplicated hardcoded
            // data."
            return "You'll receive 1 month of 85Blends Pro free. After the free month, your subscription renews at its normal price unless cancelled."
        }
        guard let selectedPlan else {
            return "You'll receive 1 month of 85Blends Pro free."
        }
        return ReferralPresentation.redemptionConfirmationCopy(
            displayPrice: SubscriptionManager.shared.displayPrice(for: selectedPlan),
            billingPeriodLabel: selectedPlan.fallbackBillingPeriodLabel
        )
    }

    // MARK: - Issued code

    /// SANDBOX → native in-app sheet; PRODUCTION (or, defensively, unknown) → the unchanged
    /// external App Store URL. See ReferralPresentation.redemptionRoute(environment:).
    private var redemptionRoute: ReferralPresentation.RedemptionRoute {
        ReferralPresentation.redemptionRoute(environment: ReferralManager.shared.bootstrappedEnvironment)
    }

    private func issuedCodeSection(status: ReferralStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if hasStartedRedemption {
                InfoCard(
                    title: "Redemption pending confirmation",
                    message: "We'll update your referral progress automatically once the App Store confirms your redemption.",
                    systemImage: "clock.fill"
                )
                if let syncMessage = ReferralPresentation.redemptionSyncMessage(for: syncState) {
                    Text(syncMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .accessibilityLabel(syncMessage)
                }
            }

            AppCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("YOUR CODE")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.Colors.textMuted)

                    Text(status.issuedRewardCode ?? "")
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .tracking(3)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .accessibilityLabel("Your redemption code")

                    if let expiresAt = ReferralPresentation.parseISO8601Date(status.issuedRewardExpiresAtRaw) {
                        Text("Expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textMuted)
                    }

                    HStack(spacing: 12) {
                        Button(action: copyCode) {
                            HStack(spacing: 6) {
                                Image(systemName: didCopyCode ? "checkmark" : "doc.on.doc")
                                Text(didCopyCode ? "Copied" : "Copy Code")
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
                        .accessibilityLabel("Copy redemption code")

                        switch redemptionRoute {
                        case .appStoreURL:
                            redemptionActionButton(title: "Redeem in App Store", action: openRedemptionURL)
                        case .sandboxNativeSheet:
                            redemptionActionButton(title: "Redeem Sandbox Offer", action: presentSandboxRedemptionSheet)
                        }
                    }

                    if redemptionRoute == .sandboxNativeSheet {
                        Text(ReferralPresentation.sandboxRedemptionHelpText)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textMuted)
                    }
                }
            }
        }
    }

    private func redemptionActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.Colors.primaryGreen)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var fulfilledOrNothingToRedeemSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Surfaces a one-time explanatory message from a JUST-COMPLETED refresh attempt that
            // landed here (e.g. `expired_no_longer_qualified` — the reward is gone, not merely
            // "nothing new yet") — see `claim()` and `ReferralPresentation.claimStatusMessage(_:)`.
            // `claimMessage` is never set outside a `claim()` call, so this never shows stale copy
            // for a user who simply opened the sheet with nothing to redeem.
            if let claimMessage {
                WarningCard(title: "Reward update", message: claimMessage, systemImage: "info.circle.fill")
            }

            InfoCard(
                title: "You're all set",
                message: "There's nothing to redeem right now. Keep referring friends to earn your next free month.",
                systemImage: "checkmark.circle.fill"
            )
        }
    }

    // MARK: - Actions

    private func claim() async {
        claimMessage = nil
        isClaiming = true
        defer { isClaiming = false }

        do {
            let response = try await ReferralManager.shared.claimReward(
                requestedProductID: isActiveProSubscriber ? nil : selectedPlan?.productID
            )
            if response.claimStatus == "claimed" {
                AppHaptics.success()
            } else {
                AppHaptics.warning()
                claimMessage = ReferralPresentation.claimStatusMessage(response.claimStatus)
            }
        } catch let error as ReferralServiceError {
            AppHaptics.warning()
            claimMessage = ReferralPresentation.userFacingMessage(for: error)
        } catch {
            AppHaptics.warning()
            claimMessage = ReferralPresentation.userFacingMessage(for: .network(error.localizedDescription))
        }
    }

    /// PRODUCTION route — unchanged: the pre-filled external App Store redemption URL.
    private func openRedemptionURL() {
        guard let code = status?.issuedRewardCode, let url = AppStoreDestination.redeemOfferCode(code) else { return }
        AppHaptics.selection()
        hasStartedRedemption = true
        openURL(url) { accepted in
            if accepted == false {
                claimMessage = "Unable to open the App Store right now. You can still copy your code and redeem it manually."
            }
        }
    }

    /// SANDBOX route (see this file's header). Copies the already-issued code to the pasteboard
    /// FIRST — StoreKit's sheet cannot be handed a code — then presents it. Nothing about the
    /// reward changes locally here; only `ReferralManager.shared.refresh()` (via
    /// `reconcileAfterRedemption()` on dismissal) can ever change what this sheet shows next.
    private func presentSandboxRedemptionSheet() {
        guard status?.issuedRewardCode != nil else { return }
        copyCode()
        hasStartedRedemption = true
        isPresentingSandboxRedemptionSheet = true
    }

    /// Shared by both routes — `sync` then ALWAYS `refresh`, via the pure, tested
    /// `ReferralPresentation.reconcileAfterRedemption`. `syncState` is the only thing this stores,
    /// and it is diagnostics copy only: a `.failed` sync leaves the issued code exactly as it was.
    private func reconcileAfterRedemption() async {
        guard syncState != .syncing else { return }
        syncState = .syncing
        syncState = await ReferralPresentation.reconcileAfterRedemption(
            sync: { await SubscriptionManager.shared.syncAfterExternalRedemption() },
            refresh: { await ReferralManager.shared.refresh() }
        )
    }

    private func copyCode() {
        guard let code = status?.issuedRewardCode else { return }
        #if os(iOS)
        UIPasteboard.general.string = code
        #endif
        AppHaptics.success()
        withAnimation { didCopyCode = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { didCopyCode = false }
        }
    }
}

#Preview {
    ReferralRewardRedemptionSheet()
}

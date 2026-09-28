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
//  Mirrors ReferralCodeEntrySheet.swift's established conventions: reads ReferralManager.shared /
//  SubscriptionManager.shared directly (never injected via a default parameter — both are
//  @MainActor-isolated singletons; see ReferEarnView.swift's own header for why), confirms before
//  ever calling the backend, and never dismisses on a claim outcome other than the user's own
//  explicit "Close" — the code (once issued) must stay visible until the user is done with it.
//

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
    @State private var hasOpenedRedemptionURL = false
    @State private var didCopyCode = false

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
            hasOpenedRedemptionURL = false
        }
        // Return-from-App-Store refresh (this feature's task spec, Phase 6) — only fires when THIS
        // sheet actually sent the user to the App Store this session; an unrelated background/
        // foreground cycle (e.g. the user just switched to another app and back) never triggers an
        // extra referral-backend/RevenueCat call it didn't need to make.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, hasOpenedRedemptionURL else { return }
            Task {
                await SubscriptionManager.shared.refreshProStatus()
                await ReferralManager.shared.refresh()
            }
        }
        .confirmationDialog(
            "Redeem your free month?",
            isPresented: $isShowingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Redeem Free Month") {
                Task { await claim() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for status: ReferralStatus) -> some View {
        if status.issuedRewardCode != nil {
            issuedCodeSection(status: status)
        } else if status.earnedMonthsAvailable > 0 {
            eligibilitySection
        } else {
            // Defensive — ReferEarnView only ever presents this sheet while earnedMonthsAvailable
            // > 0 or a code is already issued; a fulfillment confirmed while this sheet happened to
            // already be open lands here instead (earnedMonthsAvailable dropped, no issued code
            // remains) and is exactly the success state to show.
            fulfilledOrNothingToRedeemSection
        }
    }

    private var eligibilitySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(ReferralPresentation.rewardCardHeadline(earnedMonthsAvailable: status?.earnedMonthsAvailable ?? 0))
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            if let claimMessage {
                WarningCard(title: "Redemption unavailable", message: claimMessage, systemImage: "exclamationmark.triangle.fill")
            }

            if isActiveProSubscriber {
                activeSubscriberCard
            } else {
                planPickerCard
            }
        }
    }

    private var isActiveProSubscriber: Bool {
        SubscriptionManager.shared.hasAuthoritativeProStatus && SubscriptionManager.shared.isProUser
    }

    private var activeSubscriberCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Apply 1 free month to your current 85Blends Pro plan.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                redeemButton(title: "Redeem Free Month", isEnabled: true) {
                    isShowingConfirmation = true
                }
            }
        }
    }

    private var planPickerCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose a plan for your free month:")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                ForEach(ProPlan.allCases) { plan in
                    planRow(plan)
                }

                redeemButton(title: "Redeem Free Month", isEnabled: selectedPlan != nil) {
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
        let renewalLine = ReferralPresentation.renewalPriceLine(
            displayPrice: SubscriptionManager.shared.displayPrice(for: selectedPlan),
            billingPeriodLabel: selectedPlan.fallbackBillingPeriodLabel
        )
        return ReferralPresentation.redemptionConfirmationCopy(renewalPriceLine: renewalLine)
    }

    // MARK: - Issued code

    private func issuedCodeSection(status: ReferralStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if hasOpenedRedemptionURL {
                InfoCard(
                    title: "Redemption pending confirmation",
                    message: "We'll update your referral progress automatically once the App Store confirms your redemption.",
                    systemImage: "clock.fill"
                )
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

                        Button(action: openRedemptionURL) {
                            Text("Redeem in App Store")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(AppTheme.Colors.primaryGreen)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Redeem in App Store")
                    }
                }
            }
        }
    }

    private var fulfilledOrNothingToRedeemSection: some View {
        InfoCard(
            title: "You're all set",
            message: "There's nothing to redeem right now. Keep referring friends to earn your next free month.",
            systemImage: "checkmark.circle.fill"
        )
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

    private func openRedemptionURL() {
        guard let code = status?.issuedRewardCode, let url = AppStoreDestination.redeemOfferCode(code) else { return }
        AppHaptics.selection()
        hasOpenedRedemptionURL = true
        openURL(url) { accepted in
            if accepted == false {
                claimMessage = "Unable to open the App Store right now. You can still copy your code and redeem it manually."
            }
        }
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

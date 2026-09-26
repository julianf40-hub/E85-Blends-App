//
//  ProUpgradeView.swift
//  EightyFiveBlends
//
//  The single 85Blends Pro paywall for the whole app. Presented as a native sheet from
//  Pro lock cards and soft-limit banners, and pushed from the More screen. There is
//  intentionally only ONE paywall so the Pro experience stays consistent everywhere.
//
//  85Blends 2.4.0 RevenueCatUI integration — this view is a thin shell around RevenueCatUI's
//  hosted `PaywallView` (the published "85Blends Pro · 2.4.0" paywall paired with the `default`
//  offering in the RevenueCat dashboard). This file continues to own everything RevenueCatUI must
//  never decide on its own:
//    - whether a paywall should be shown at all (an existing subscriber never sees `PaywallView`
//      — see `body` below)
//    - referral pre-purchase attribution (`referralCard` + the `.onPurchaseInitiated` interceptor)
//    - entitlement authority (still exclusively `SubscriptionManager`/`RevenueCatSubscriptionService`
//      — RevenueCatUI never touches `pro` directly; see that type's own "KEY AUTHORITY INVARIANT")
//    - presentation/routing (`presentationMode`, every existing call site is unchanged)
//    - post-purchase state bookkeeping (`SubscriptionManager.setPurchaseState`, mirroring the
//      exact same transitions `purchase(_:)`/`restorePurchases()` already produce)
//  RevenueCatUI owns paywall rendering, package selection, purchase UI, restore UI, and the
//  remote paywall content itself — this file never duplicates that in SwiftUI.
//

import SwiftUI
import RevenueCat
import RevenueCatUI

enum ProPresentationMode {
    case pushed
    case modal
}

struct ProUpgradeView: View {
    @Environment(\.dismiss) private var dismiss

    let presentationMode: ProPresentationMode

    init(presentationMode: ProPresentationMode = .pushed) {
        self.presentationMode = presentationMode
    }

    private var manager: SubscriptionManager { SubscriptionManager.shared }

    // 85Blends 2.4.0 — Refer & Earn pre-purchase attribution. Referral attribution must happen
    // BEFORE the qualifying paid Pro purchase (see ReferralAwareProPurchaseCoordinator.swift's own
    // header) — this is the paywall's own compact code-entry path, distinct from (and never a
    // replacement for) the standalone ReferralCodeEntrySheet under More -> Refer & Earn.
    @State private var referralCodeInput = ""
    @State private var isShowingReferralConfirmation = false
    /// Snapshot of the code the confirmation dialog is actually asking about — taken once, when
    /// the dialog is raised, so a later async gap can never read a since-changed `referralCodeInput`
    /// (the field is disabled the moment this dialog is up, but this avoids relying on that alone).
    @State private var pendingReferralCodeForConfirmation = ""
    /// The RevenueCatUI purchase-flow resume callback captured while the confirmation dialog is
    /// up. Type-erased to a plain closure deliberately — see `handlePurchaseInitiated`'s header.
    @State private var pendingPurchaseResume: ((Bool) -> Void)?
    /// True only while the referral-first purchase sequence (apply, then let RevenueCatUI proceed)
    /// is actually running — see `handlePurchaseInitiated`'s own re-entrancy guard.
    @State private var isApplyingReferralBeforePurchase = false
    /// Safe, non-sensitive copy from ReferralPresentation.userFacingMessage(for:) only — never a
    /// raw backend string, error description, or OSStatus. Cleared whenever the code field changes
    /// or a new purchase attempt begins.
    @State private var referralErrorMessage: String?
    /// Snapshot of `manager.isProUser` taken the moment RevenueCatUI's restore flow starts, so the
    /// resulting message can distinguish a fresh restore from "already active" — mirrors
    /// `restorePurchases()`'s own `wasProBefore` snapshot.
    @State private var restoreWasProBefore = false

    private var referralManager: ReferralManager { ReferralManager.shared }

    /// Trim+uppercase only — see ReferralPresentation.normalizedReferralCode's own header. Shared
    /// validation/normalization semantics with ReferralCodeEntrySheet; never a second validator.
    private var normalizedReferralCode: String {
        ReferralPresentation.normalizedReferralCode(referralCodeInput)
    }

    /// True only when the user has typed something non-empty that fails the shared format check —
    /// a blank field is never "invalid," it just means no referral is being requested. Used only
    /// for the inline warning text under the (already-hidden-once-applied) text field itself.
    private var hasInvalidNonEmptyReferralCode: Bool {
        normalizedReferralCode.isEmpty == false && ReferralPresentation.referralCodeIsValid(normalizedReferralCode) == false
    }

    /// The backend's own authoritative attribution for this installation, if any — reads ONLY
    /// `referralManager.loadState`, never `referralCodeInput`/`normalizedReferralCode`. Once a
    /// purchase attempt applies a code (e.g. a first attempt the user then cancels), this stays
    /// non-nil for the rest of the paywall session even though the local text field is hidden and
    /// never cleared — so it, not the stale hidden field, must be what future purchase attempts
    /// consult. See `ReferralAwareProPurchaseCoordinator.purchase`'s own `alreadyAppliedCode`
    /// header for why this always wins over local UI state, unconditionally.
    private var backendAppliedReferralCode: String? {
        guard case .loaded(let status) = referralManager.loadState else {
            return nil
        }
        guard
            let code = status.referredByCode,
            ReferralPresentation.hasAppliedReferralCode(referredByCode: status.referredByCode)
        else {
            return nil
        }
        return code
    }

    var body: some View {
        Group {
            if manager.isProUser {
                proActiveContent
            } else {
                freePaywallContent
            }
        }
        .navigationTitle("85Blends Pro")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentationMode == .modal {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .task {
            // Wait for any in-progress startup offering fetch to settle before we try.
            // Without this yield + loop, our call hits the loadOfferings() in-flight guard and
            // silently no-ops while EightyFiveBlendsApp's launch `.task` (RevenueCatSubscription
            // Service.configureIfNeeded()) is still loading — leaving the paywall permanently on
            // the error state if that startup load fails.
            await Task.yield()
            while manager.isLoadingProducts {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Load (or re-fetch for freshness) on every paywall presentation — this is also what
            // populates `manager.defaultOffering`, which RevenueCatUI's PaywallView renders below.
            await manager.loadProducts()
        }
        // Starts in PARALLEL with the offering load above, via a second top-level `.task`, never
        // gating it: a person must still be able to purchase WITHOUT a referral code even if the
        // referral service itself is unavailable. Referral availability only actually blocks
        // anything when the person is actively trying to USE a code — see
        // handlePurchaseInitiated(resume:). Exactly the same ReferralManager.refresh() the
        // standalone Refer & Earn screen already calls — no second networking layer.
        .task {
            await referralManager.refresh()
        }
        // Centralized paywall-presentation signal for the App Store review-request system (see
        // SubscriptionManager.isPaywallPresented's header). Purely a presentation flag; never
        // touches entitlement or purchasing state.
        .onAppear { manager.setPaywallPresented(true) }
        .onDisappear { manager.setPaywallPresented(false) }
        .confirmationDialog(
            "Apply referral code?",
            isPresented: $isShowingReferralConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply & Continue") {
                let code = pendingReferralCodeForConfirmation
                let resume = pendingPurchaseResume
                pendingPurchaseResume = nil
                Task {
                    await runReferralAwarePurchase(normalizedReferralCode: code, alreadyAppliedCode: nil, resume: resume ?? { _ in })
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPurchaseResume?(false)
                pendingPurchaseResume = nil
            }
        } message: {
            Text("Apply \(pendingReferralCodeForConfirmation) before subscribing?\n\nReferral codes can't be changed after they're applied.")
        }
    }

    // MARK: - Free user: referral entry + RevenueCatUI hosted paywall

    @ViewBuilder
    private var freePaywallContent: some View {
        VStack(spacing: 0) {
            referralCard
                .padding(16)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, alignment: .center)

            if let offering = manager.defaultOffering, manager.hasUnexpectedProductInDefaultOffering == false {
                PaywallView(offering: offering)
                    .onPurchaseInitiated { _, resume in
                        // Type-erased immediately to a plain `(Bool) -> Void` so nothing else in
                        // this file needs to name RevenueCatUI's own resume-action type — see
                        // handlePurchaseInitiated's own header.
                        let proceed: (Bool) -> Void = { shouldProceed in
                            if shouldProceed {
                                resume()
                            } else {
                                resume(shouldProceed: false)
                            }
                        }
                        Task { @MainActor in
                            await handlePurchaseInitiated(resume: proceed)
                        }
                    }
                    .onPurchaseStarted { _ in
                        manager.setPurchaseState(.purchasing)
                    }
                    .onPurchaseCompleted { customerInfo in
                        manager.setPurchaseState(SubscriptionManager.state(forPurchaseOutcome: RevenueCatSubscriptionService.purchaseOutcome(
                            userCancelled: false,
                            isProEntitlementActiveAfterPurchase: RevenueCatSubscriptionService.isProEntitlementActive(
                                entitlementIsActive: customerInfo.entitlements[RevenueCatSubscriptionService.proEntitlementID]?.isActive
                            )
                        )))
                    }
                    .onPurchaseCancelled {
                        manager.setPurchaseState(SubscriptionManager.state(forPurchaseOutcome: .cancelled))
                    }
                    .onPurchaseFailure { error in
                        manager.setPurchaseState(SubscriptionManager.state(forPurchaseOutcome: .failed(error.localizedDescription)))
                    }
                    .onRestoreStarted {
                        // The raw RevenueCat entitlement, not `manager.isProUser` — mirrors
                        // SubscriptionManager.restorePurchases()'s own snapshot: a Developer
                        // Force Pro/Force Free override (Internal/Debug only) must never distort
                        // restore messaging.
                        restoreWasProBefore = RevenueCatSubscriptionService.shared.revenueCatIsPro
                        manager.setPurchaseState(.restoring)
                    }
                    .onRestoreCompleted { customerInfo in
                        let isActive = RevenueCatSubscriptionService.isProEntitlementActive(
                            entitlementIsActive: customerInfo.entitlements[RevenueCatSubscriptionService.proEntitlementID]?.isActive
                        )
                        manager.setPurchaseState(SubscriptionManager.state(
                            forRestoreOutcome: isActive ? .proActive : .noActivePro,
                            wasProBefore: restoreWasProBefore
                        ))
                    }
                    .onRestoreFailure { error in
                        manager.setPurchaseState(SubscriptionManager.state(
                            forRestoreOutcome: .failed(error.localizedDescription),
                            wasProBefore: restoreWasProBefore
                        ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                offeringUnavailableView
            }

            legalDisclosureFooter
                .padding(16)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(AppTheme.Colors.charcoal)
    }

    /// Shown only while `manager.defaultOffering` hasn't loaded (or failed to). Once it loads,
    /// RevenueCatUI's own hosted paywall takes over rendering entirely — this is never shown
    /// alongside it. Still offers Restore Purchases (going straight through
    /// `SubscriptionManager.restorePurchases()`, not RevenueCatUI, which isn't shown in this
    /// branch) — the old custom paywall kept Restore visible in every paywall state, including
    /// while offerings had failed to load (e.g. a reinstall with a real subscription hitting this
    /// screen on a flaky connection), and that App-Review-driven guarantee must not regress just
    /// because the offering itself failed to fetch.
    @ViewBuilder
    private var offeringUnavailableView: some View {
        VStack(spacing: 16) {
            if manager.isLoadingProducts || !manager.hasAttemptedProductLoad {
                statusRow(icon: "arrow.triangle.2.circlepath", text: "Loading subscription…", color: AppTheme.Colors.textSecondary, spinning: true)
            } else {
                statusRow(
                    icon: "wifi.exclamationmark",
                    text: "Subscriptions are temporarily unavailable. Check your connection and try again.",
                    color: AppTheme.Colors.textSecondary
                )

                Button {
                    Task { await manager.loadProducts() }
                } label: {
                    Text("Try Again")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            purchaseStateRow

            Divider()
                .background(AppTheme.Colors.border)
                .padding(.vertical, 2)

            restoreButton(disabled: manager.purchaseState == .purchasing || manager.purchaseState == .restoring)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Referral Code (85Blends 2.4.0 — Refer & Earn pre-purchase attribution)
    //
    // Free users only — an existing Pro subscriber never sees any part of this card, not even a
    // "checking eligibility" spinner (this whole card only renders inside `freePaywallContent`,
    // itself only reachable when `manager.isProUser` is false — see `body`).

    @ViewBuilder
    private var referralCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Referral Code", subtitle: "Optional — have a friend's code? Enter it before subscribing.")

            referralCardContent

            Text("Referral codes can't be added after the qualifying paid Pro purchase.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Mirrors ReferEarnView's own `content` switch over the SAME ReferralLoadState — never a
    /// second referral network/state layer. `.idle`/`.loading` render identically, matching that
    /// screen's own convention.
    @ViewBuilder
    private var referralCardContent: some View {
        switch referralManager.loadState {
        case .idle, .loading:
            statusRow(icon: "arrow.triangle.2.circlepath", text: "Checking referral eligibility…", color: AppTheme.Colors.textSecondary, spinning: true)
        case .waitingForRevenueCatIdentity:
            referralPreparationRow(text: "Finishing referral setup…")
        case .waitingForStoreEnvironment:
            referralPreparationRow(text: "Verifying the App Store environment for referrals…")
        case .failed(let error):
            referralUnavailableRow(error: error)
        case .loaded(let status):
            referralLoadedContent(status: status)
        }
    }

    private func referralPreparationRow(text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow(icon: "arrow.triangle.2.circlepath", text: text, color: AppTheme.Colors.textSecondary, spinning: true)
            referralRetryButton { await referralManager.refresh() }
        }
    }

    /// Never a raw backend string, error description, or OSStatus — only the same REF-XXXXX
    /// diagnostic support code already shown on the standalone Refer & Earn screen (see
    /// ReferralPresentation.diagnosticCode(for:)'s own header).
    private func referralUnavailableRow(error: ReferralServiceError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow(icon: "exclamationmark.circle.fill", text: "Referral setup temporarily unavailable", color: AppTheme.Colors.textSecondary)
            Text("Support code: \(ReferralPresentation.diagnosticCode(for: error))")
                .font(.caption2.monospaced())
                .foregroundStyle(AppTheme.Colors.textMuted)
            referralRetryButton { await referralManager.refresh() }
        }
    }

    private func referralRetryButton(action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text("Try Again")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.stationYellow)
        }
        .buttonStyle(.plain)
    }

    /// Applied-code state always takes precedence, independent of Pro-entitlement-resolution
    /// state — checked FIRST, exactly like ReferEarnView's own referredBySection, before ever
    /// consulting entryEligibility below.
    @ViewBuilder
    private func referralLoadedContent(status: ReferralStatus) -> some View {
        if ReferralPresentation.hasAppliedReferralCode(referredByCode: status.referredByCode) {
            appliedReferralRow(status: status)
        } else {
            // Reuses the EXACT SAME entryEligibility this feature's standalone Refer & Earn screen
            // already uses — including its own hardening against a still-resolving or
            // never-resolved RevenueCat entitlement fetch being misread as confirmed Free/Pro (see
            // SubscriptionManager.hasAuthoritativeProStatus's own header). Never a second, paywall-
            // specific eligibility rule.
            switch ReferralPresentation.entryEligibility(
                canApplyReferralCode: status.canApplyReferralCode,
                isCurrentlyPro: manager.isProUser,
                isEntitlementResolutionPending: manager.isInitialEntitlementResolutionPending,
                hasAuthoritativeProStatus: manager.hasAuthoritativeProStatus
            ) {
            case .allowed:
                referralCodeField
            case .waitingForSubscriptionStatus:
                statusRow(icon: "arrow.triangle.2.circlepath", text: "Checking Pro status…", color: AppTheme.Colors.textSecondary, spinning: true)
            case .subscriptionStatusUnavailable:
                VStack(alignment: .leading, spacing: 6) {
                    statusRow(icon: "exclamationmark.triangle.fill", text: "Unable to verify Pro status", color: AppTheme.Colors.textSecondary)
                    referralRetryButton { await SubscriptionManager.shared.refreshProStatus() }
                }
            case .blockedAlreadyPro:
                // Structurally unreachable from this call site — this whole card only renders
                // inside `freePaywallContent`, itself only reachable when `manager.isProUser` is
                // false, and `isCurrentlyPro` here is that exact same value read in the same
                // render pass. Handled for switch exhaustiveness only.
                EmptyView()
            case .blockedCannotApply:
                EmptyView()
            }
        }
    }

    private func appliedReferralRow(status: ReferralStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.primaryGreen)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Referral code applied")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                if let code = status.referredByCode {
                    Text(code)
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Exactly ReferralPresentation's shared normalization/validation — see
    /// normalizedReferralCode/hasInvalidNonEmptyReferralCode above. Never a second validator, per
    /// this feature's own task spec ("Do not duplicate a second validator").
    private var referralCodeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Referral code (optional)", text: $referralCodeInput)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .tracking(2)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .keyboardType(.asciiCapable)
                .disabled(isApplyingReferralBeforePurchase)
                .onChange(of: referralCodeInput) { _, newValue in
                    let normalized = ReferralPresentation.normalizedReferralCode(newValue)
                    referralCodeInput = String(normalized.prefix(ReferralPresentation.referralCodeLength))
                    referralErrorMessage = nil
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(AppTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Referral code, optional")
                .accessibilityHint("Enter an 8 character referral code, or leave blank")

            if hasInvalidNonEmptyReferralCode {
                Text(ReferralPresentation.userFacingMessage(for: .api(.invalidReferralCode)))
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.warningRed)
            }

            if let referralErrorMessage {
                Text(referralErrorMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.warningRed)
            }
        }
    }

    // MARK: - Purchase interception (85Blends 2.4.0 RevenueCatUI integration)
    //
    // RevenueCatUI's hosted paywall owns package selection and the purchase button itself, but a
    // purchase must never bypass required referral attribution — see this feature's own
    // "load-bearing" referral-before-purchase ordering requirement (ReferralAwareProPurchaseCoordinator
    // .swift's header). `.onPurchaseInitiated` pauses RevenueCatUI's purchase flow until `resume`
    // is called, which is exactly enough to run the same coordinator this app used with its old
    // custom paywall — only its `purchase` closure changes meaning, from "call
    // SubscriptionManager.purchasePro directly" to "let RevenueCatUI's own button proceed," so the
    // referral ordering guarantee is identical either way.

    /// `resume`'s real type is RevenueCatUI's own resume-action type, which this file never names —
    /// the call site above type-erases it to this plain closure immediately, so nothing here (or
    /// in tests) needs to depend on that SDK-internal type at all.
    private func handlePurchaseInitiated(resume: @escaping (Bool) -> Void) async {
        guard isApplyingReferralBeforePurchase == false else {
            resume(false)
            return
        }
        guard manager.purchaseState != .purchasing, manager.purchaseState != .restoring else {
            resume(false)
            return
        }
        // A prior purchase-initiated call is still waiting on the confirmation dialog's answer —
        // never overwrite its captured `resume` (which would orphan that earlier RevenueCatUI
        // purchase-flow instance) just because a second intent arrived before the user answered.
        guard isShowingReferralConfirmation == false else {
            resume(false)
            return
        }

        let alreadyAppliedCode = backendAppliedReferralCode
        let codeToSubmit = normalizedReferralCode

        // Exactly the same precedence rule the pre-RevenueCatUI paywall's CTA used to disable
        // itself with (ReferralPresentation.shouldBlockPurchaseForReferralInput) — never a second,
        // ad hoc reimplementation of this gate. A purchase must never proceed on an unconfirmed/
        // invalid code just because RevenueCatUI's own purchase button doesn't know about this
        // app's referral-validity gate.
        guard ReferralPresentation.shouldBlockPurchaseForReferralInput(
            backendAppliedReferralCode: alreadyAppliedCode,
            normalizedReferralCode: codeToSubmit
        ) == false else {
            // The inline warning under referralCodeField is already visible regardless, but the
            // tap otherwise produces no feedback at all inside RevenueCatUI's own paywall — a
            // haptic at least confirms the tap was seen and intentionally refused.
            AppHaptics.warning()
            resume(false)
            return
        }

        // Backend attribution state always wins over local/hidden UI state — see
        // `backendAppliedReferralCode`'s own header. Checked FIRST, before any typed input.
        if let alreadyAppliedCode, alreadyAppliedCode.isEmpty == false {
            await runReferralAwarePurchase(normalizedReferralCode: "", alreadyAppliedCode: alreadyAppliedCode, resume: resume)
            return
        }

        guard codeToSubmit.isEmpty == false else {
            await runReferralAwarePurchase(normalizedReferralCode: "", alreadyAppliedCode: nil, resume: resume)
            return
        }

        // A blank field or an already-applied code purchases immediately (handled above) — a
        // fresh, valid, non-empty code always confirms first: referral codes are immutable once
        // applied, so the user must explicitly opt in to spending that one-time attribution before
        // the purchase runs.
        pendingReferralCodeForConfirmation = codeToSubmit
        pendingPurchaseResume = resume
        isShowingReferralConfirmation = true
    }

    /// The load-bearing ordering guarantee this whole feature exists for — see
    /// ReferralAwareProPurchaseCoordinator.swift's own header. Re-entrancy-guarded so a double tap
    /// can never start two applies or two purchases.
    private func runReferralAwarePurchase(
        normalizedReferralCode: String,
        alreadyAppliedCode: String?,
        resume: @escaping (Bool) -> Void
    ) async {
        // Mirrors the old beginPurchase(normalizedReferralCode:)'s own re-entrancy guard, which
        // lived in this shared worker rather than only in its dispatchers — this function has two
        // call sites now (handlePurchaseInitiated directly, and the confirmation dialog's "Apply &
        // Continue" button below), and both must be protected identically.
        guard isApplyingReferralBeforePurchase == false else {
            resume(false)
            return
        }
        isApplyingReferralBeforePurchase = true
        referralErrorMessage = nil
        defer { isApplyingReferralBeforePurchase = false }

        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: normalizedReferralCode,
            alreadyAppliedCode: alreadyAppliedCode,
            applyReferralCode: { code in try await ReferralManager.shared.applyReferralCode(code) },
            purchase: { resume(true) }
        )

        switch outcome {
        case .purchased:
            break // resume(true) already called by the coordinator's own `purchase` closure above.
        case .invalidCode:
            // Structurally shouldn't be reachable — handlePurchaseInitiated already blocks an
            // invalid code before this function is ever called — kept as a safe no-op rather than
            // ever silently proceeding with the purchase on an invalid code.
            resume(false)
        case .applyFailed(let message):
            resume(false)
            AppHaptics.warning()
            referralErrorMessage = message
        case .confirmationMismatch:
            resume(false)
            AppHaptics.warning()
            referralErrorMessage = ReferralPresentation.userFacingMessage(for: .invalidResponse)
        }
    }

    // MARK: - Existing Pro subscriber
    //
    // RevenueCatUI's hosted paywall is never shown to an existing subscriber — mirrors the old
    // custom paywall's exact same branch (see `body`), satisfying "existing subscriber should not
    // be asked to repurchase."

    private var proActiveContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                activeProRow
                purchaseStateRow

                // Restore stays visible even when already Pro, as App Review expects. Tapping
                // while Pro just re-verifies and confirms active status. This goes straight
                // through SubscriptionManager.restorePurchases() (not RevenueCatUI, which isn't
                // shown in this branch at all) — the exact same call/state path this file used
                // before the RevenueCatUI integration.
                Divider()
                    .background(AppTheme.Colors.border)
                    .padding(.vertical, 2)

                restoreButton(disabled: manager.purchaseState == .purchasing || manager.purchaseState == .restoring)

                legalDisclosureFooter
            }
            .padding(16)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(AppTheme.Colors.charcoal)
    }

    // MARK: - Legal disclosure
    //
    // App Store Guideline 3.1.2 requires auto-renewable subscription terms and Terms of Use /
    // Privacy Policy links to be disclosed at the point of purchase. This is deliberately kept
    // even though RevenueCatUI's own hosted "85Blends Pro · 2.4.0" paywall template may already
    // include equivalent copy — that template's exact content is RevenueCat dashboard state this
    // diff cannot see or verify, so this app-owned footer stays as a guaranteed fallback rather
    // than trusting dashboard content alone for an App Review requirement. No longer tied to a
    // single selected plan the way the pre-RevenueCatUI paywall's footerNote was (RevenueCatUI, not
    // this file, now owns plan selection) — each plan's own price is already shown in RevenueCatUI's
    // package rows above, so this stays deliberately plan-agnostic.

    private var legalDisclosureFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("85Blends Pro is an auto-renewable subscription. Payment is charged to your Apple ID at purchase confirmation. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Cancel anytime in App Store settings.")
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            legalLinksRow
        }
    }

    private var legalLinksRow: some View {
        HStack(spacing: 16) {
            // Standard Apple EULA — used because the app has no custom Terms of Use.
            if let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
                Link("Terms of Use", destination: termsURL)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
            }

            // In-app privacy screen (already shipped under More → Privacy).
            NavigationLink {
                PrivacyView()
            } label: {
                Text("Privacy Policy")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
            }

            Spacer(minLength: 0)
        }
    }

    private var activeProRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.primaryGreen)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("You have 85Blends Pro. Thanks for your support!")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Your subscription helps fund continued development and new features.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.Colors.primaryGreen.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var purchaseStateRow: some View {
        switch manager.purchaseState {
        case .purchasing:
            statusRow(icon: "arrow.triangle.2.circlepath", text: "Processing your purchase…", color: AppTheme.Colors.textSecondary, spinning: true)
        case .restoring:
            statusRow(icon: "arrow.triangle.2.circlepath", text: "Restoring purchases…", color: AppTheme.Colors.textSecondary, spinning: true)
        case .succeeded:
            EmptyView() // Purchase success is reflected by the active-Pro row above.
        case .restored:
            statusRow(icon: "checkmark.seal.fill", text: "85Blends Pro restored.", color: AppTheme.Colors.primaryGreen)
        case .info(let msg):
            statusRow(icon: "info.circle.fill", text: msg, color: AppTheme.Colors.textSecondary)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 4) {
                statusRow(icon: "exclamationmark.circle.fill", text: "Something went wrong.", color: AppTheme.Colors.warningRed)
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .idle:
            EmptyView()
        }
    }

    private func statusRow(icon: String, text: String, color: Color, spinning: Bool = false) -> some View {
        HStack(spacing: 8) {
            if spinning {
                ProgressView()
                    .tint(color)
                    .scaleEffect(0.85)
            } else {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func restoreButton(disabled: Bool) -> some View {
        Button {
            Task { await manager.restorePurchases() }
        } label: {
            Text("Restore Purchases")
                .font(.caption.weight(.medium))
                .foregroundStyle(disabled ? AppTheme.Colors.textMuted.opacity(0.5) : AppTheme.Colors.textMuted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

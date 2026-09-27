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
//    - referral pre-purchase attribution (`compactReferralRow` + `referralCodeEntrySheet`
//      + the `.onPurchaseInitiated` interceptor)
//    - entitlement authority (still exclusively `SubscriptionManager`/`RevenueCatSubscriptionService`
//      — RevenueCatUI never touches `pro` directly; see that type's own "KEY AUTHORITY INVARIANT")
//    - presentation/routing (`presentationMode`, every existing call site is unchanged)
//    - post-purchase state bookkeeping (`SubscriptionManager.setPurchaseState`, mirroring the
//      exact same transitions `purchase(_:)`/`restorePurchases()` already produce)
//  RevenueCatUI owns paywall rendering, package selection, purchase UI, restore UI, and the
//  remote paywall content itself — this file never duplicates that in SwiftUI.
//
//  85Blends 2.4.0 paywall-layout refinement — the referral affordance above `PaywallView` is
//  deliberately a single compact row, not a card: RevenueCatUI's hosted content (headline,
//  benefits, plans, CTA) must be visible as high on the first screen as practical, and the app's
//  own tab bar is hidden for the same reason (see `body`'s `.toolbar(.hidden, for: .tabBar)`).
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
    /// 85Blends 2.4.0 real-device confirmation-UI polish — governs whether
    /// `referralConfirmationOverlay`'s entrance/exit animates with a scale component at all (see
    /// that view's own header); a plain fade is kept either way rather than disabling animation
    /// entirely, per Phase 7's "respect Reduce Motion where practical."
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// 85Blends 2.4.0 paywall-layout refinement — the compact referral row's "Add Code" affordance
    /// presents the actual code-entry UI in this sheet instead of inline, so the main paywall stays
    /// short enough that Pro's benefits/plans/CTA are visible without scrolling. See
    /// `referralCodeEntrySheet`'s own header.
    @State private var isShowingReferralCodeSheet = false
    /// Snapshot of `referralCodeInput` taken when the sheet opens, so "Cancel" can discard whatever
    /// was typed THIS sheet session without affecting a code typed in an earlier session (or
    /// already-applied backend state, which this never touches either way).
    @State private var referralCodeInputSnapshotBeforeSheet = ""

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

    /// True once the user has typed something non-empty that PASSES the shared format check but
    /// hasn't been backend-confirmed yet (`backendAppliedReferralCode` is what answers "has the
    /// backend actually confirmed this" — this property never claims that on its own). Drives the
    /// compact row's "Ready to apply" state so the user gets some acknowledgement their code was
    /// accepted, without ever implying it's permanently applied before the backend says so.
    private var hasValidPendingReferralCode: Bool {
        normalizedReferralCode.isEmpty == false && ReferralPresentation.referralCodeIsValid(normalizedReferralCode)
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
        ZStack {
            Group {
                if manager.isProUser {
                    proActiveContent
                } else {
                    freePaywallContent
                }
            }
            // 85Blends 2.4.0 real-device confirmation-UI polish — while the custom referral
            // confirmation overlay below is up, the paywall/RevenueCatUI content underneath must
            // be neither interactable (already true structurally: the overlay's full-bleed scrim
            // sits on top in z-order and consumes any tap within its bounds) nor VoiceOver-
            // reachable (NOT true for free — SwiftUI's accessibility tree isn't purely z-order-
            // based, so this is required explicitly) — otherwise VoiceOver focus could land on
            // RevenueCatUI's own purchase CTA behind the modal.
            .accessibilityHidden(isShowingReferralConfirmation)

            referralConfirmationOverlay
        }
        .navigationTitle("85Blends Pro")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentationMode == .modal {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        // The referral confirmation overlay below is app-owned UI, not a true
                        // system-modal presentation — unlike the `.confirmationDialog` it
                        // replaced, it cannot itself block a sibling toolbar button. Disabled
                        // explicitly so Close can never tear down this view (and silently orphan
                        // RevenueCatUI's paused purchase-flow `resume`) while the user is still
                        // mid-confirmation.
                        .disabled(isShowingReferralConfirmation)
                }
            }
        }
        // 85Blends 2.4.0 paywall-layout refinement — a focused purchase screen shouldn't compete
        // with the app's own tab bar for vertical space. Only affects a `.pushed` presentation
        // (e.g. More → 85Blends Pro), which lives inside its tab's own NavigationStack and would
        // otherwise keep the tab bar visible at the bottom by default; a safe no-op under `.modal`
        // (`.sheet`) presentation, since there's no tab bar in that presentation context to hide.
        // Standard SwiftUI API (iOS 16+), well under this project's 17.6/26.4 deployment targets.
        // Restores automatically on Back/dismiss — this modifier only affects this view's own
        // lifetime, never the tab bar's persistent state.
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $isShowingReferralCodeSheet) {
            referralCodeEntrySheet
        }
        // A CustomerInfo update (restore, family sharing, a purchase completed on another device)
        // can flip isProUser to true while this sheet happens to be open — `body`'s Group already
        // switches away from freePaywallContent to proActiveContent on its own, but a `.sheet` is a
        // separate presentation layer that switch alone does not dismiss. An already-Pro user must
        // never be left mid-referral-entry, so force it closed here.
        .onChange(of: manager.isProUser) { _, isPro in
            if isPro {
                isShowingReferralCodeSheet = false
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
        // A plain, declarative animation tied to the state value itself — every state change that
        // shows/hides the overlay (Cancel, Apply & Continue, or a future call site) picks it up
        // automatically, with no risk of a call site forgetting to wrap its own state change in
        // `withAnimation`. `nil` under Reduce Motion disables the transition's motion entirely
        // rather than merely shortening it (Phase 7's "respect Reduce Motion where practical").
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isShowingReferralConfirmation)
    }

    // MARK: - Referral confirmation overlay (85Blends 2.4.0 real-device confirmation-UI polish)
    //
    // Replaces a previous `.confirmationDialog` (a native action sheet on iPhone) with a custom,
    // centered, opaque modal card — the system action sheet read as "translucent... visually
    // disconnected" against RevenueCatUI's own polished hosted paywall on real devices. This is
    // presentation ONLY: `confirmReferralApplication()`/`cancelReferralConfirmation()` below run
    // the EXACT SAME two code paths the old dialog's two buttons ran (see the diff this replaced),
    // just with an explicit `isShowingReferralConfirmation = false` where SwiftUI's own
    // `confirmationDialog(isPresented:)` used to dismiss itself automatically on any button tap.
    // Nothing about `handlePurchaseInitiated`/`runReferralAwarePurchase`/
    // `ReferralAwareProPurchaseCoordinator` changed at all.
    //
    // KNOWN RESIDUAL GAP (present before this change too, not introduced by it): a true
    // system-modal presentation (the `.confirmationDialog` this replaces, and the app's own
    // `.sheet`-based `referralCodeEntrySheet`, which uses `.interactiveDismissDisabled()`) blocks
    // ALL other interaction, including a NavigationStack's interactive edge-swipe-back gesture and
    // an enclosing `.sheet`'s own swipe-to-dismiss — neither of which any plain SwiftUI overlay can
    // intercept, since both are UIKit-level gestures on a sibling layer this view doesn't own. The
    // toolbar Close button is explicitly disabled above while this overlay is up (the one such path
    // this view DOES own), but the edge-swipe-back gesture and an outer call site's own `.sheet`
    // swipe-to-dismiss are not blocked here, and could tear this view down mid-confirmation,
    // orphaning RevenueCatUI's paused purchase-flow `resume`. Tracked separately, not fixed here —
    // fixing it would mean disabling `UINavigationController.interactivePopGestureRecognizer`
    // and/or adding `.interactiveDismissDisabled()` at every outer call site that presents this
    // view modally, both bigger changes than this presentation-only polish pass.

    /// Full-bleed dim scrim + centered card, shown only while `isShowingReferralConfirmation` is
    /// true. Tapping the scrim cancels — the same outcome a swipe-to-dismiss on the old
    /// `confirmationDialog` already had, so this isn't a new dismissal path, just the same one on
    /// a different presentation surface.
    @ViewBuilder
    private var referralConfirmationOverlay: some View {
        if isShowingReferralConfirmation {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .onTapGesture { cancelReferralConfirmation() }

                referralConfirmationCard
                    .padding(.horizontal, 24)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
            .accessibilityAddTraits(.isModal)
            // The system `.confirmationDialog` this replaced supported VoiceOver's standard
            // two-finger-scrub "escape" gesture to dismiss for free (any true modal presentation
            // does); a custom overlay does not get this automatically, so it's wired explicitly —
            // same outcome as Cancel, matching escape's usual "back out, don't confirm" semantics.
            .accessibilityAction(.escape) { cancelReferralConfirmation() }
        }
    }

    /// Opaque — never translucent/glass — matching this file's own established card language
    /// (`AppTheme.Colors.surfaceElevated`, the same surface `compactReferralAddCodeRow`/
    /// `activeProRow`/etc. already use), so it reads as intentionally part of 85Blends rather than
    /// a generic system alert. Sized to grow vertically with Dynamic Type rather than clipping —
    /// no fixed height anywhere in this view.
    private var referralConfirmationCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "gift.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .accessibilityHidden(true)

                Text("Apply referral code?")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                (
                    Text("Use referral code ")
                        + Text(pendingReferralCodeForConfirmation).fontWeight(.semibold)
                        + Text(" before subscribing?\n\nThis code will be linked to your account and can't be changed after it's applied.")
                )
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button {
                    confirmReferralApplication()
                } label: {
                    Text("Apply & Continue")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(AppTheme.Colors.stationYellow)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    cancelReferralConfirmation()
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .frame(maxWidth: 330)
        .background(AppTheme.Colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
        .accessibilityElement(children: .contain)
    }

    /// Exactly the old `confirmationDialog`'s "Apply & Continue" button body, plus the explicit
    /// dismissal that modifier used to handle on its own. `runReferralAwarePurchase` (unchanged) is
    /// what actually runs the coordinator, checks the backend result, and calls `resume` — this
    /// function only ever calls it once, from one call site.
    private func confirmReferralApplication() {
        let code = pendingReferralCodeForConfirmation
        let resume = pendingPurchaseResume
        pendingPurchaseResume = nil
        isShowingReferralConfirmation = false
        Task {
            await runReferralAwarePurchase(normalizedReferralCode: code, alreadyAppliedCode: nil, resume: resume ?? { _ in })
        }
    }

    /// Exactly the old `confirmationDialog`'s "Cancel" button body, plus the explicit dismissal —
    /// resumes RevenueCatUI's paused purchase flow with `false` (never starts StoreKit) and never
    /// touches referral state at all.
    private func cancelReferralConfirmation() {
        pendingPurchaseResume?(false)
        pendingPurchaseResume = nil
        isShowingReferralConfirmation = false
    }

    // MARK: - Free user: referral entry + RevenueCatUI hosted paywall

    @ViewBuilder
    private var freePaywallContent: some View {
        // 85Blends 2.4.0 real-device layout follow-up — every point here is vertical budget taken
        // away from RevenueCatUI's own hosted content below, which owns its own internal scrolling
        // and cannot be told to compress (see compactReferralRowChrome's header for why the
        // template's own spacing/sizing isn't something this file can adjust). Kept as tight as a
        // still-tappable, still-readable row allows: no top padding at all (the row's own 12pt
        // vertical chrome padding is enough visual separation from the nav bar), tighter VStack
        // spacing than before.
        VStack(spacing: 4) {
            compactReferralRow
                .padding(.horizontal, 16)
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
                        // Apply this authoritative, already-resolved CustomerInfo IMMEDIATELY —
                        // exactly like SubscriptionManager.purchase(_:) does for its own purchase
                        // call — so revenueCatIsPro/isProUser/hasAuthoritativeProStatus and the
                        // widget entitlement mirror update synchronously, never waiting on
                        // customerInfoStream's own timing. See applyAuthoritativeCustomerInfo(_:)'s
                        // own header.
                        RevenueCatSubscriptionService.shared.applyAuthoritativeCustomerInfo(customerInfo)
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
                        // Apply this authoritative, already-resolved CustomerInfo IMMEDIATELY —
                        // exactly like SubscriptionManager.restorePurchases() does for its own
                        // restore call — so revenueCatIsPro/isProUser/hasAuthoritativeProStatus and
                        // the widget entitlement mirror update synchronously, never waiting on
                        // customerInfoStream's own timing. See applyAuthoritativeCustomerInfo(_:)'s
                        // own header.
                        RevenueCatSubscriptionService.shared.applyAuthoritativeCustomerInfo(customerInfo)
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
    /// because the offering itself failed to fetch. Also carries its own `legalDisclosureFooter` —
    /// unlike the PaywallView branch above, RevenueCatUI's hosted paywall (which already includes
    /// its own recurring-subscription disclosure, Restore, and Terms/Privacy links) isn't shown
    /// here at all, so this fallback state needs its own copy of that disclosure.
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

            legalDisclosureFooter
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Referral Code (85Blends 2.4.0 — Refer & Earn pre-purchase attribution)
    //
    // Free users only — an existing Pro subscriber never sees any part of this row, not even a
    // "checking eligibility" spinner (this whole row only renders inside `freePaywallContent`,
    // itself only reachable when `manager.isProUser` is false — see `body`).
    //
    // 85Blends 2.4.0 paywall-layout refinement — this used to be a large, always-expanded card with
    // the text field inline. Referral is an OPTIONAL affordance and must not visually compete with
    // RevenueCatUI's hosted paywall for the user's first-screen attention, so it's now a single
    // compact row; tapping it (when a code can actually be entered) presents the real entry UI —
    // unchanged normalization/validation/errors, just relocated — in `referralCodeEntrySheet`
    // below. The state machine itself (the switch over `referralManager.loadState` and
    // `ReferralPresentation.entryEligibility`) is byte-for-byte the same as before; only how each
    // case renders changed.

    /// Mirrors ReferEarnView's own `content` switch over the SAME ReferralLoadState — never a
    /// second referral network/state layer. `.idle`/`.loading` render identically, matching that
    /// screen's own convention.
    @ViewBuilder
    private var compactReferralRow: some View {
        switch referralManager.loadState {
        case .idle, .loading:
            compactReferralStatusRow(icon: "arrow.triangle.2.circlepath", text: "Checking referral eligibility…", spinning: true)
        case .waitingForRevenueCatIdentity:
            // Mirrors the old referralPreparationRow(text:) exactly: a spinner AND a retry
            // action together, since this state (unlike .idle/.loading just above) can persist
            // indefinitely if identity/environment resolution stalls, and previously offered a
            // manual escape hatch rather than only ever waiting.
            compactReferralRetryRow(
                icon: "arrow.triangle.2.circlepath",
                text: "Finishing referral setup…",
                spinning: true,
                action: { await referralManager.refresh() }
            )
        case .waitingForStoreEnvironment:
            // Same reasoning as .waitingForRevenueCatIdentity just above.
            compactReferralRetryRow(
                icon: "arrow.triangle.2.circlepath",
                text: "Verifying App Store environment…",
                spinning: true,
                action: { await referralManager.refresh() }
            )
        case .failed(let error):
            // Never a raw backend string, error description, or OSStatus — only the same
            // REF-XXXXX diagnostic support code already shown on the standalone Refer & Earn
            // screen (see ReferralPresentation.diagnosticCode(for:)'s own header), folded into one
            // line to stay compact.
            compactReferralRetryRow(
                icon: "exclamationmark.circle.fill",
                text: "Referral setup unavailable (\(ReferralPresentation.diagnosticCode(for: error)))",
                action: { await referralManager.refresh() }
            )
        case .loaded(let status):
            // Applied-code state always takes precedence, independent of Pro-entitlement-
            // resolution state — checked FIRST, exactly like ReferEarnView's own
            // referredBySection, before ever consulting entryEligibility below.
            if ReferralPresentation.hasAppliedReferralCode(referredByCode: status.referredByCode) {
                compactReferralAppliedRow(code: status.referredByCode)
            } else {
                // Reuses the EXACT SAME entryEligibility this feature's standalone Refer & Earn
                // screen already uses — including its own hardening against a still-resolving or
                // never-resolved RevenueCat entitlement fetch being misread as confirmed Free/Pro
                // (see SubscriptionManager.hasAuthoritativeProStatus's own header). Never a second,
                // paywall-specific eligibility rule.
                switch ReferralPresentation.entryEligibility(
                    canApplyReferralCode: status.canApplyReferralCode,
                    isCurrentlyPro: manager.isProUser,
                    isEntitlementResolutionPending: manager.isInitialEntitlementResolutionPending,
                    hasAuthoritativeProStatus: manager.hasAuthoritativeProStatus
                ) {
                case .allowed:
                    compactReferralAddCodeRow
                case .waitingForSubscriptionStatus:
                    compactReferralStatusRow(icon: "arrow.triangle.2.circlepath", text: "Checking Pro status…", spinning: true)
                case .subscriptionStatusUnavailable:
                    compactReferralRetryRow(
                        icon: "exclamationmark.triangle.fill",
                        text: "Unable to verify Pro status",
                        action: { await SubscriptionManager.shared.refreshProStatus() }
                    )
                case .blockedAlreadyPro:
                    // Structurally unreachable from this call site — this whole row only renders
                    // inside `freePaywallContent`, itself only reachable when `manager.isProUser`
                    // is false, and `isCurrentlyPro` here is that exact same value read in the
                    // same render pass. Handled for switch exhaustiveness only.
                    EmptyView()
                case .blockedCannotApply:
                    EmptyView()
                }
            }
        }
    }

    /// Common chrome (padding/min-height/background/corner radius) shared by every compact
    /// referral row below, so a future visual tweak (radius, padding) is one edit instead of four.
    /// Each row adds its own optional border `.overlay` on top, since that varies by row (none for
    /// informational rows, tinted for add-code/applied).
    private func compactReferralRowChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .background(AppTheme.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Three sub-states, none of them a second referral state machine — all still driven by
    /// `referralCodeInput`/`hasValidPendingReferralCode`/`isApplyingReferralBeforePurchase`, the
    /// same state `handlePurchaseInitiated` itself reads:
    ///   - applying: a plain, non-tappable status row while the referral-first purchase sequence
    ///     is actually running (see `isApplyingReferralBeforePurchase`'s own header) — one clear,
    ///     app-owned "what's happening" signal near the row the user just interacted with,
    ///     alongside whatever RevenueCatUI's own paused purchase button shows.
    ///   - pending: a validly-formatted, not-yet-backend-confirmed code shows "Ready to apply" —
    ///     never "applied," since only `backendAppliedReferralCode` (which this never reads) can
    ///     claim that.
    ///   - default: the original "Have a referral code? Add Code" affordance.
    /// Tapping the row (pending or default) opens `referralCodeEntrySheet`. Carries the invalid-
    /// code/apply-failure warnings directly beneath it — exactly like the old inline text field
    /// always did — since those only ever apply while this row (not a loading/applied/error row)
    /// is what's showing. Suppressed while `referralCodeEntrySheet` itself is open (it shows the
    /// identical text right next to the field already), so the same warning never appears twice at
    /// once through the sheet's own `.medium` detent, which leaves this row visible behind it.
    @ViewBuilder
    private var compactReferralAddCodeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isApplyingReferralBeforePurchase {
                compactReferralRowChrome {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(AppTheme.Colors.textSecondary)
                            .scaleEffect(0.85)
                        Text("Applying referral code…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Spacer(minLength: 8)
                    }
                }
            } else {
                Button {
                    referralCodeInputSnapshotBeforeSheet = referralCodeInput
                    isShowingReferralCodeSheet = true
                } label: {
                    compactReferralRowChrome {
                        if hasValidPendingReferralCode {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.Colors.stationYellow)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(normalizedReferralCode)
                                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                                        .foregroundStyle(AppTheme.Colors.textPrimary)
                                    Text("Ready to apply")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.Colors.textSecondary)
                                }

                                Spacer(minLength: 8)

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.Colors.textMuted)
                            }
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: "gift.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.Colors.stationYellow)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)

                                Text("Have a referral code?")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(AppTheme.Colors.textPrimary)

                                Spacer(minLength: 8)

                                HStack(spacing: 2) {
                                    Text("Add Code")
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.stationYellow)
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                hasValidPendingReferralCode ? AppTheme.Colors.stationYellow.opacity(0.4) : AppTheme.Colors.border,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(
                    hasValidPendingReferralCode
                        ? "Opens a sheet to review or change the referral code"
                        : "Opens a sheet to enter an optional referral code before subscribing"
                )
            }

            if isShowingReferralCodeSheet == false && isApplyingReferralBeforePurchase == false {
                if hasInvalidNonEmptyReferralCode {
                    Text(ReferralPresentation.userFacingMessage(for: .api(.invalidReferralCode)))
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.warningRed)
                        .padding(.horizontal, 4)
                }

                if let referralErrorMessage {
                    Text(referralErrorMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.warningRed)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private func compactReferralAppliedRow(code: String?) -> some View {
        compactReferralRowChrome {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.primaryGreen)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text(code.map { "Referral \($0) applied" } ?? "Referral code applied")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Spacer(minLength: 8)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.Colors.primaryGreen.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    /// Reuses the file's own existing `statusRow` (same icon/spinner/text layout `purchaseStateRow`
    /// and `offeringUnavailableView` already use) rather than a second copy of that logic — this
    /// only adds the compact row's own card chrome around it.
    private func compactReferralStatusRow(icon: String, text: String, spinning: Bool = false) -> some View {
        compactReferralRowChrome {
            statusRow(icon: icon, text: text, color: AppTheme.Colors.textSecondary, spinning: spinning)
        }
    }

    private func compactReferralRetryRow(icon: String, text: String, spinning: Bool = false, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            compactReferralRowChrome {
                // Same .caption sizing as statusRow (reused by compactReferralStatusRow just
                // above) and the old referralRetryButton's own "Try Again" — these two rows render
                // in the same on-screen slot as referral setup resolves, so they must match in
                // size or the row visibly jumps between states.
                HStack(spacing: 8) {
                    if spinning {
                        ProgressView()
                            .tint(AppTheme.Colors.textSecondary)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Text(text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text("Try Again")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// 85Blends 2.4.0 paywall-layout refinement — the actual referral-code entry UI, unchanged from
    /// before except that it now lives in a sheet (opened from `compactReferralAddCodeRow`)
    /// instead of always-inline. `referralCodeField` below is the SAME view/state/validation this
    /// screen always used — never a second validator — so a code typed here is immediately the
    /// same `referralCodeInput`/`normalizedReferralCode` `handlePurchaseInitiated` already reads at
    /// purchase time; dismissing this sheet (via "Done") does not clear or otherwise touch that
    /// state, so the code remains available to the purchase-intercept gate exactly as before.
    private var referralCodeEntrySheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Optional — have a friend's code? Enter it before subscribing.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                referralCodeField

                Text("Referral codes can't be added after the qualifying paid Pro purchase.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.charcoal)
            .navigationTitle("Referral Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Discard whatever was (or wasn't) typed THIS sheet session only — never
                        // touches backend-applied state, which this sheet never had authority over
                        // anyway.
                        referralCodeInput = referralCodeInputSnapshotBeforeSheet
                        isShowingReferralCodeSheet = false
                    }
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isShowingReferralCodeSheet = false
                    }
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                }
            }
        }
        .presentationDetents([.medium])
        // Without this, a swipe-down dismissal sets isShowingReferralCodeSheet = false directly,
        // bypassing Cancel's revert-to-snapshot entirely and silently keeping whatever was typed —
        // as if Done had been tapped instead, contradicting Cancel's own guarantee above. Forcing
        // Cancel/Done as the only two exits keeps that guarantee real regardless of how the user
        // tries to leave.
        .interactiveDismissDisabled()
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
    // Privacy Policy links to be disclosed at the point of purchase. The published RevenueCat
    // paywall ("85Blends Pro · 2.4.0") already carries its own recurring-subscription disclosure,
    // Restore Purchases, Terms of Use, and Privacy Policy — RevenueCatUI's `PaywallView` is the
    // single source of truth for that content whenever it's actually on screen, so this view is
    // deliberately NEVER shown directly under/alongside it (see `freePaywallContent`, which shows
    // `PaywallView` XOR `offeringUnavailableView`, never both). It's used only in the two states
    // where RevenueCatUI's own paywall — and therefore its own legal footer — isn't rendered at
    // all: `offeringUnavailableView` (offering still loading or failed to load) and
    // `proActiveContent` (existing subscriber, no paywall shown either way). No longer tied to a
    // single selected plan the way the pre-RevenueCatUI paywall's footerNote was (RevenueCatUI, not
    // this file, owns plan selection whenever it's shown) — deliberately plan-agnostic.

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

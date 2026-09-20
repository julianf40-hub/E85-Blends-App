//
//  ProUpgradeView.swift
//  EightyFiveBlends
//
//  The single 85Blends Pro paywall for the whole app. Presented as a native sheet from
//  Pro lock cards and soft-limit banners, and pushed from the More screen. There is
//  intentionally only ONE paywall so the Pro experience stays consistent everywhere.
//

import SwiftUI
import RevenueCat

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

    // 85Blends 2.4.0 three-plan paywall. Defaults to Annual (best value) and is corrected at
    // most once, in applyDefaultPlanSelectionIfNeeded(), to the best available plan once real
    // package availability is known — mirroring this codebase's established "apply once, never
    // re-arm" idiom. hasUserManuallySelectedPlan exists separately so that correction can never
    // clobber a plan the person already tapped themselves while the initial load was still in
    // flight (the paywall's rows are tappable immediately, before .task's load even settles).
    @State private var selectedPlan: ProPlan = .annual
    @State private var hasAppliedDefaultPlanSelection = false
    @State private var hasUserManuallySelectedPlan = false

    // 85Blends 2.4.0 — Refer & Earn pre-purchase attribution. Referral attribution must happen
    // BEFORE the qualifying paid Pro purchase (see ReferralAwareProPurchaseCoordinator.swift's own
    // header) — this is the paywall's own compact code-entry path, distinct from (and never a
    // replacement for) the standalone ReferralCodeEntrySheet under More -> Refer & Earn.
    @State private var referralCodeInput = ""
    @State private var isShowingReferralConfirmation = false
    /// True only while the referral-first purchase sequence (apply, then purchase) is actually
    /// running — see beginPurchase(normalizedReferralCode:)'s own re-entrancy guard. Folded into
    /// `isWorking` in actionsSection alongside RevenueCat purchasing/restoring.
    @State private var isApplyingReferralBeforePurchase = false
    /// Safe, non-sensitive copy from ReferralPresentation.userFacingMessage(for:) only — never a
    /// raw backend string, error description, or OSStatus. Cleared whenever the code field changes
    /// or a new purchase attempt begins.
    @State private var referralErrorMessage: String?

    private var referralManager: ReferralManager { ReferralManager.shared }

    /// Trim+uppercase only — see ReferralPresentation.normalizedReferralCode's own header. Shared
    /// validation/normalization semantics with ReferralCodeEntrySheet; never a second validator.
    private var normalizedReferralCode: String {
        ReferralPresentation.normalizedReferralCode(referralCodeInput)
    }

    /// True only when the user has typed something non-empty that fails the shared format check —
    /// a blank field is never "invalid," it just means no referral is being requested.
    private var hasInvalidNonEmptyReferralCode: Bool {
        normalizedReferralCode.isEmpty == false && ReferralPresentation.referralCodeIsValid(normalizedReferralCode) == false
    }

    /// The backend's own authoritative attribution for this installation, if any — reads ONLY
    /// `referralManager.loadState`, never `referralCodeInput`/`normalizedReferralCode`. Once a
    /// purchase attempt applies a code (e.g. a first attempt the user then cancels in Apple's own
    /// StoreKit sheet), this stays non-nil for the rest of the paywall session even though the
    /// local text field is hidden and never cleared — so it, not the stale hidden field, must be
    /// what future Unlock taps consult. See `ReferralAwareProPurchaseCoordinator.purchase`'s own
    /// `alreadyAppliedCode` header for why this always wins over local UI state, unconditionally.
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

    // Benefit list — 85Blends 2.3.0 paywall content refresh, extended in 2.3.1 to add Ad-Free
    // Experience. Split into two tiers so a quick scan reads "headline value" vs "everything
    // else included," rather than one flat list of equally-weighted bullets:
    //   - majorBenefits get full visual treatment (icon badge, headline-weight title). Trip
    //     Planning is genuinely implemented today and gated behind isProUser (see
    //     ProFeatureGate/TripPlannerView). Ad-Free Experience is genuinely implemented and
    //     validated on a real device as of 2.3.1 — AdManager.isAdsEnabled reads
    //     SubscriptionManager.shared.isProUser directly, and NativeAdView never even constructs
    //     an ad request when that's false (see AdManager.swift/NativeAdView.swift) — a zero-ad-
    //     request guarantee, not "load then hide." Unlimited Vehicles is genuinely implemented
    //     and validated as of 2.3.0 (see VehicleCreationPolicy/SubscriptionManager.
    //     canAccessUnlimitedVehicles) — no longer a Coming Soon item.
    //   - supportingBenefits render compactly underneath. Save & Revisit Routes intentionally
    //     never says "sync," "backed up," or "available across devices" — Saved Trips
    //     (SavedTripStore) are device-local today, not CloudKit-synced.
    // Cloud Sync itself is never listed here — it's unconditional for every user, Free and Pro
    // alike (see SubscriptionManager.swift, GarageView.swift, and CLAUDE.md's Cloud Sync
    // product-policy note), so it is not Pro benefit content.
    private let majorBenefits: [(icon: String, title: String, detail: String)] = [
        ("map.fill", "Intelligent E85 Trip Planning", "Plan complete routes around E85 availability, reserve targets, and backup fuel options."),
        ("sparkles", "Ad-Free Experience", "Enjoy 85Blends without ads while your Pro subscription is active."),
        ("car.fill", "Unlimited Vehicles", "Add and manage your entire garage with 85Blends Pro."),
    ]

    private let supportingBenefits: [(icon: String, title: String, detail: String)] = [
        ("arrow.triangle.turn.up.right.diamond.fill", "E85 Stops Along Your Route", "Find ethanol stops that make sense for your actual trip, not just what's nearby."),
        ("bookmark.fill", "Save & Revisit Routes", "Save useful trips and quickly plan them again later."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                planPickerCard
                referralCard
                benefitsCard
                comingSoonCard

                // Mutually exclusive with activeProRow inside actionsSection below: a Pro
                // subscriber already sees a thank-you/support card there, so showing this too
                // would be a redundant second "support us" message. A free user sees exactly
                // one of the two, never both.
                if !manager.isProUser {
                    supportCard
                }

                actionsSection
                footerNote
            }
            .padding(16)
            // Cap content width on iPad so it doesn't stretch awkwardly on wide displays.
            // The outer frame centers the capped block within the scroll view's full width.
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(AppTheme.Colors.charcoal)
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
            // Load (or re-fetch for freshness) on every paywall presentation.
            await manager.loadProducts()
            applyDefaultPlanSelectionIfNeeded()
        }
        // 85Blends 2.4.0 — starts in PARALLEL with the product/offering load above, via a second
        // top-level `.task`, never gating it: a person must still be able to purchase WITHOUT a
        // referral code even if the referral service itself is unavailable. Referral availability
        // only actually blocks anything when the person is actively trying to USE a code — see
        // beginPurchase(normalizedReferralCode:). Exactly the same ReferralManager.refresh() the
        // standalone Refer & Earn screen already calls — no second networking layer.
        .task {
            await referralManager.refresh()
        }
        // 85Blends 2.4.0 — centralized paywall-presentation signal for the App Store
        // review-request system (see SubscriptionManager.isPaywallPresented's header). Reporting
        // this here, rather than at each of the four call sites that present this view, means
        // every current and future paywall entry point is covered automatically. Fires
        // identically for both `.modal` (sheet) and `.pushed` (NavigationLink) presentation —
        // onAppear/onDisappear are called by SwiftUI either way. Purely a presentation flag;
        // never touches entitlement or purchasing state.
        .onAppear { manager.setPaywallPresented(true) }
        .onDisappear { manager.setPaywallPresented(false) }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "crown.fill")
                    .font(.system(.title, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
                    .accessibilityHidden(true)

                Text("85Blends Pro")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }

            Text("Drive farther. Plan smarter. Fuel with confidence.")
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Plan Picker

    private var planPickerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Choose Your Plan", subtitle: "Every plan unlocks everything in 85Blends Pro.")

            VStack(spacing: 10) {
                ForEach(ProPlan.allCases) { plan in
                    planRow(plan)
                }
            }

            Text("Cancel anytime.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.stationYellow.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// One selectable row per `ProPlan`. Annual always carries the "BEST VALUE" badge —
    /// unconditionally, never tied to whether it's the current selection — and Monthly/3-Month
    /// are never visually diminished to make room for it. A plan whose package failed to
    /// resolve (see SubscriptionManager.canPurchase(_:)) is dimmed and labeled "Unavailable
    /// right now" instead of a price, so it's never presented as purchasable — but the row stays
    /// tappable so a person can still see it selected (and see exactly why the purchase button
    /// below is disabled) rather than the row silently doing nothing.
    private func planRow(_ plan: ProPlan) -> some View {
        let isSelected = selectedPlan == plan
        let isUnavailable = manager.hasAttemptedProductLoad && !manager.isLoadingProducts && !manager.canPurchase(plan)

        return Button {
            AppHaptics.selection()
            selectedPlan = plan
            hasUserManuallySelectedPlan = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? AppTheme.Colors.stationYellow : AppTheme.Colors.textMuted)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(plan.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        if plan == .annual {
                            Text("BEST VALUE")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppTheme.Colors.stationYellow)
                                .clipShape(Capsule())
                        }
                    }

                    if isUnavailable {
                        Text("Unavailable right now")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textMuted)
                    } else {
                        Text("\(manager.displayPrice(for: plan)) / \(billingPeriodSuffix(for: plan))")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)

                        if let equivalentLine = equivalentMonthlyLine(for: plan) {
                            Text(equivalentLine)
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textMuted)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isUnavailable ? 0.55 : 1)
            .background(isSelected ? AppTheme.Colors.stationYellow.opacity(0.12) : AppTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? AppTheme.Colors.stationYellow.opacity(0.6) : AppTheme.Colors.border, lineWidth: isSelected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        // 85Blends 2.4.0 — disabled while the referral-first purchase sequence is running, so the
        // selected plan can't change out from under an in-flight apply/purchase (Phase 14 of this
        // feature's own task spec).
        .disabled(isApplyingReferralBeforePurchase)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Natural-language billing-period suffix for a plan row's price line ("month" / "3 months" /
    /// "year"). Prefers the real loaded StoreProduct's own subscriptionPeriod — same API this
    /// file's existing subscriptionPeriodLabel(for:) already reads for the unlock button's
    /// subtitle — and falls back to the plan's flat marketing label only before a package loads.
    private func billingPeriodSuffix(for plan: ProPlan) -> String {
        guard let product = manager.storeProduct(for: plan), let period = product.subscriptionPeriod else {
            return plan.fallbackBillingPeriodLabel
        }
        switch period.unit {
        case .month: return period.value == 1 ? "month" : "\(period.value) months"
        case .year: return period.value == 1 ? "year" : "\(period.value) years"
        case .week: return period.value == 1 ? "week" : "\(period.value) weeks"
        case .day: return period.value == 1 ? "day" : "\(period.value) days"
        @unknown default: return plan.fallbackBillingPeriodLabel
        }
    }

    /// "≈ $X.XX/month" line for 3-Month/Annual rows (`nil` for Monthly — see
    /// ProPlan.equivalentMonthlyAmount). Requires a REAL loaded StoreProduct: the arithmetic runs
    /// on `product.price` (a `Decimal`, never a parsed `localizedPriceString`), and the result is
    /// formatted with that SAME product's own `priceFormatter` — the exact `NumberFormatter`
    /// `localizedPriceString` itself uses — so the equivalent amount always renders in the
    /// product's actual storefront currency/locale, never a hardcoded U.S.-style fallback. `nil`
    /// whenever a real product hasn't loaded yet, or lacks enough currency metadata to format
    /// safely (no `priceFormatter`, or it fails to produce a string) — the row simply omits the
    /// line rather than ever risk showing a wrong or misleading currency.
    private func equivalentMonthlyLine(for plan: ProPlan) -> String? {
        guard let product = manager.storeProduct(for: plan),
              let amount = ProPlan.equivalentMonthlyAmount(price: product.price, plan: plan),
              let formatter = product.priceFormatter,
              let formatted = formatter.string(from: NSDecimalNumber(decimal: amount))
        else { return nil }
        return "≈ \(formatted)/month"
    }

    /// Called once, from `body`'s `.task`, right after the first `loadProducts()` call settles.
    /// Leaves the Annual default alone whenever Annual is actually purchasable (the common case),
    /// and never runs at all once the person has tapped a row themselves — see
    /// hasUserManuallySelectedPlan's own header for why that guard has to be separate from this
    /// one. Only steps in when Annual itself failed to resolve, moving the selection to the
    /// best available plan per ProPlan.preferredDefault(among:) so the CTA isn't left pointed at
    /// a plan nobody can actually buy.
    private func applyDefaultPlanSelectionIfNeeded() {
        guard !hasAppliedDefaultPlanSelection, !hasUserManuallySelectedPlan else { return }
        hasAppliedDefaultPlanSelection = true

        guard !manager.canPurchase(selectedPlan) else { return }

        let availablePlans = Set(ProPlan.allCases.filter { manager.canPurchase($0) })
        if let bestAvailable = ProPlan.preferredDefault(among: availablePlans) {
            selectedPlan = bestAvailable
        }
    }

    // MARK: - Referral Code (85Blends 2.4.0 — Refer & Earn pre-purchase attribution)
    //
    // Free users only — an existing Pro subscriber never sees any part of this card, not even a
    // "checking eligibility" spinner (see Phase 7 of this feature's own task spec: "EXISTING PRO
    // USER: No referral-code entry field"). `manager.isProUser` is read once here AND passed as
    // the exact same value into `entryEligibility` below, so the two can never disagree about
    // whether the user is Pro within a single render pass.

    @ViewBuilder
    private var referralCard: some View {
        if !manager.isProUser {
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
                // inside `if !manager.isProUser` above, and `isCurrentlyPro` here is that exact
                // same value read in the same render pass. Handled for switch exhaustiveness only.
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

    /// The load-bearing ordering guarantee this whole feature exists for — see
    /// ReferralAwareProPurchaseCoordinator.swift's own header. Re-entrancy-guarded so a double tap
    /// (on the CTA, or on "Apply & Continue" in the confirmation dialog) can never start two
    /// applies or two purchases: the guard-check-then-set below has no `await` in between, so on
    /// @MainActor's serial executor the first call to actually run always claims the flag before a
    /// second overlapping call gets a chance to observe it as false.
    ///
    /// `backendAppliedReferralCode` is snapshotted HERE, at the start of the purchase action —
    /// not read fresh mid-flight — so this one purchase attempt is judged against one consistent
    /// view of backend attribution state, exactly like `normalizedReferralCode` is already
    /// snapshotted by callers before this function is invoked.
    private func beginPurchase(normalizedReferralCode: String) async {
        guard isApplyingReferralBeforePurchase == false else { return }
        guard manager.purchaseState != .purchasing, manager.purchaseState != .restoring else { return }

        let alreadyAppliedCode = backendAppliedReferralCode

        isApplyingReferralBeforePurchase = true
        referralErrorMessage = nil
        defer { isApplyingReferralBeforePurchase = false }

        let outcome = await ReferralAwareProPurchaseCoordinator.purchase(
            normalizedCode: normalizedReferralCode,
            alreadyAppliedCode: alreadyAppliedCode,
            applyReferralCode: { code in try await ReferralManager.shared.applyReferralCode(code) },
            purchase: { await manager.purchasePro(selectedPlan) }
        )

        switch outcome {
        case .purchased:
            break // SubscriptionManager.purchaseState already reflects the purchase outcome.
        case .invalidCode:
            // Structurally shouldn't be reachable — the CTA is already disabled whenever
            // hasInvalidNonEmptyReferralCode is true — kept as a safe no-op rather than ever
            // silently purchasing anyway on an invalid code.
            break
        case .applyFailed(let message):
            AppHaptics.warning()
            referralErrorMessage = message
        case .confirmationMismatch:
            AppHaptics.warning()
            referralErrorMessage = ReferralPresentation.userFacingMessage(for: .invalidResponse)
        }
    }

    // MARK: - Benefits

    private var benefitsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "What's Included", subtitle: "Available now with 85Blends Pro.")

            VStack(alignment: .leading, spacing: 16) {
                ForEach(majorBenefits, id: \.title) { benefit in
                    majorBenefitRow(benefit)
                }
            }

            Divider()
                .background(AppTheme.Colors.border)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(supportingBenefits, id: \.title) { benefit in
                    supportingBenefitRow(benefit)
                }
            }
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

    /// Full visual treatment — icon badge, headline-weight title — for the headline benefits
    /// in `majorBenefits` (Trip Planning, Ad-Free Experience, Unlimited Vehicles).
    private func majorBenefitRow(_ benefit: (icon: String, title: String, detail: String)) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.stationYellow.opacity(0.16))
                    .frame(width: 40, height: 40)

                Image(systemName: benefit.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.stationYellow)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(benefit.title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(benefit.detail)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Compact treatment — small inline icon, no badge — for supporting benefits that round
    /// out the headline value above without competing with it for attention.
    private func supportingBenefitRow(_ benefit: (icon: String, title: String, detail: String)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: benefit.icon)
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(benefit.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(benefit.detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Coming soon

    // A separate, visually secondary card so a quick scan never mistakes a roadmap item for a
    // current entitlement. Reuses ProShellRow — the same muted "Coming soon" capsule already
    // shipped in StationsView's and MoreView's Coming Soon sections for these exact two
    // features — rather than inventing a new visual language for the same concept. No CTA
    // button (there is nothing to unlock yet) and no date/version promise, per product policy;
    // "Planned for future 85Blends updates." is deliberately non-committal.
    private var comingSoonCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Coming Soon to Pro", subtitle: "Planned for future 85Blends updates.")

            VStack(alignment: .leading, spacing: 14) {
                ProShellRow(
                    icon: "chart.bar.fill",
                    title: "Advanced Fuel Analytics",
                    detail: "Deeper insights into fuel economy, costs, and trends."
                )

                Divider()
                    .background(AppTheme.Colors.border)

                ProShellRow(
                    icon: "bell.badge.fill",
                    title: "Station Price Alerts",
                    detail: "Keep track of fuel prices at stations you care about."
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One elevation step flatter than benefitsCard (surface vs. surfaceElevated) — a
        // deliberate, subtle visual demotion so this card reads as secondary to What's
        // Included even before either section header is read.
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Support 85Blends

    /// Compact, visually distinct funding note for Free users — not a feature bullet, so it
    /// uses a smaller corner radius and a plain single-line layout instead of the icon-badge +
    /// title/detail structure benefitsCard uses for actual entitlements. Pro subscribers never
    /// see this; they see the equivalent message folded into activeProRow instead (see the
    /// mutual-exclusivity comment at this view's only call site, in `body`).
    private var supportCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.stationYellow)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text("Your Pro subscription helps support continued development, new features, and ongoing improvements to 85Blends.")
                .font(.footnote)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        // 85Blends 2.4.0 — accounts for BOTH RevenueCat purchasing/restoring AND the referral
        // pre-apply step (Phase 14 of this feature's own task spec), so the CTA/Continue/Restore
        // row stays disabled for the whole referral-first purchase sequence, not just the final
        // RevenueCat call.
        let isWorking = manager.purchaseState == .purchasing || manager.purchaseState == .restoring || isApplyingReferralBeforePurchase

        VStack(spacing: 12) {
            if manager.isProUser {
                activeProRow
            } else {
                // The CTA is disabled until the SELECTED plan's real RevenueCat package is
                // loaded, so it never looks tappable when there's nothing to buy for that plan
                // (offline / product missing). The blanket "subscriptions unavailable" note
                // below is reserved for when EVERY plan has failed to resolve — a single
                // unavailable plan is already communicated by that row's own "Unavailable right
                // now" label in planRow, so it doesn't also need this global message. Also
                // disabled while a non-empty typed referral code fails local format validation —
                // never silently ignore an invalid code and purchase anyway.
                unlockButton(disabled: isWorking || !manager.canPurchase(selectedPlan) || hasInvalidNonEmptyReferralCode)

                if !manager.anyPlanPurchasable {
                    availabilityNote
                }

                continueFreeButton(disabled: isWorking)
            }

            purchaseStateRow

            // Restore stays visible in every paywall state (including when already Pro), as
            // App Review expects. Tapping while Pro just re-verifies and confirms active status.
            Divider()
                .background(AppTheme.Colors.border)
                .padding(.vertical, 2)

            restoreButton(disabled: isWorking)
        }
    }

    /// Shown when no purchasable product is available.
    /// Shows a loading indicator until the first fetch has completed; only then surfaces
    /// the error + retry so the user never sees "unavailable" before any attempt is made.
    @ViewBuilder
    private var availabilityNote: some View {
        if manager.isLoadingProducts || !manager.hasAttemptedProductLoad {
            statusRow(icon: "arrow.triangle.2.circlepath", text: "Loading subscription…", color: AppTheme.Colors.textSecondary, spinning: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    icon: "wifi.exclamationmark",
                    text: "Subscriptions are temporarily unavailable. Check your connection and try again.",
                    color: AppTheme.Colors.textSecondary
                )

                Button {
                    Task { await manager.loadProducts() }
                } label: {
                    Text("Try Again")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.stationYellow)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A blank referral field purchases immediately — no gate, no dialog. A non-empty one always
    /// confirms first: referral codes are immutable once applied (see
    /// ReferralAwareProPurchaseCoordinator's own header), so the user must explicitly opt in to
    /// spending that one-time attribution before the purchase runs, per this feature's own
    /// "load-bearing" referral-before-purchase ordering requirement. Backend attribution state
    /// (`backendAppliedReferralCode`) is checked FIRST, before the local text field at all: once
    /// this installation already has a confirmed referral — even from an earlier purchase attempt
    /// the user then cancelled in Apple's own StoreKit sheet — the confirmation dialog must never
    /// reappear, and a stale, hidden `referralCodeInput` must never re-trigger another apply call
    /// or block a legitimate purchase retry.
    private func unlockButton(disabled: Bool) -> some View {
        Button {
            if backendAppliedReferralCode != nil {
                // Already immutably attributed — purchase directly. beginPurchase snapshots
                // backendAppliedReferralCode itself and the coordinator ignores normalizedCode
                // entirely whenever that snapshot is non-empty, so what's passed here never
                // matters — see ReferralAwareProPurchaseCoordinator.purchase's own header.
                Task { await beginPurchase(normalizedReferralCode: "") }
            } else if normalizedReferralCode.isEmpty {
                Task { await beginPurchase(normalizedReferralCode: "") }
            } else {
                isShowingReferralConfirmation = true
            }
        } label: {
            VStack(spacing: 3) {
                if isApplyingReferralBeforePurchase {
                    ProgressView()
                        .tint(.black)
                } else {
                    Text("Unlock 85Blends Pro")
                        .font(.headline)
                        .foregroundStyle(.black)
                    // Show subscription title, duration, and price once the package is loaded
                    // so the user knows exactly what they're buying before tapping.
                    if let product = manager.storeProduct(for: selectedPlan) {
                        Text("\(product.localizedTitle) · \(subscriptionPeriodLabel(for: product)) · \(product.localizedPriceString)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.black.opacity(0.7))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(AppTheme.Colors.stationYellow)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .confirmationDialog(
            "Apply referral code?",
            isPresented: $isShowingReferralConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply & Continue") {
                let code = normalizedReferralCode
                Task { await beginPurchase(normalizedReferralCode: code) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apply \(normalizedReferralCode) before subscribing?\n\nReferral codes can't be changed after they're applied.")
        }
    }

    private func subscriptionPeriodLabel(for product: StoreProduct) -> String {
        guard let period = product.subscriptionPeriod else { return "Monthly" }
        switch period.unit {
        case .month: return period.value == 1 ? "Monthly" : "\(period.value)-Month"
        case .year:  return period.value == 1 ? "Yearly"  : "\(period.value)-Year"
        case .week:  return period.value == 1 ? "Weekly"  : "\(period.value)-Week"
        case .day:   return period.value == 1 ? "Daily"   : "\(period.value)-Day"
        @unknown default: return "Monthly"
        }
    }

    private func continueFreeButton(disabled: Bool) -> some View {
        Button {
            AppHaptics.selection()
            dismiss()
        } label: {
            Text("Continue with Free Version")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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

                // The Free-user equivalent of this line lives in supportCard — the two are
                // mutually exclusive (see body), so this is the only "supports development"
                // message a subscriber sees.
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

    // MARK: - Footer

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("85Blends Pro is a \(billingChargeDescription(for: selectedPlan)) auto-renewable subscription. Payment is charged to your Apple ID at purchase confirmation. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Cancel anytime in App Store settings.")
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.textMuted)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            legalLinksRow
        }
    }

    /// The only part of footerNote's auto-renewal sentence that varies by plan — everything
    /// else in that sentence is preserved verbatim regardless of selection. Prefers the real
    /// loaded price (via SubscriptionManager.displayPrice(for:), which itself already falls back
    /// to ProPlan.fallbackDisplayPrice before a package loads) so this disclosure is never out of
    /// sync with what unlockButton's own subtitle and planRow's price line show.
    private func billingChargeDescription(for plan: ProPlan) -> String {
        let price = manager.displayPrice(for: plan)
        switch plan {
        case .monthly: return "\(price)/month"
        case .threeMonth: return "\(price) every 3 months"
        case .annual: return "\(price)/year"
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
}

//
//  ContentView.swift
//  EightyFiveBlends
//
//  Created by Julian FIgueroa on 4/27/26.
//

import SwiftUI
import SwiftData
import StoreKit

/// 85Blends 2.4.0 review-request audit fix — the review-request system's own conflicting-
/// presentation check, pulled out as a pure function so it's directly unit-testable (mirrors
/// ReviewRequestEligibility/PendingPriceContributionEligibility/NearbyE85IconButtonInteractivity's
/// own pattern of isolating a decision from the SwiftUI state that feeds it). Not folded into
/// ReviewRequestEligibility itself, which is deliberately independent of any specific app-state
/// shape — this one exists precisely because it IS ContentView's own specific state shape.
///
/// `hasActivePriceContribution` is the fix: the post-navigation price-contribution banner
/// (`ContentView.activePriceContribution`) was missing from this check entirely before this
/// audit. Same-activation arbitration was already correct (ContentView's scenePhase handler
/// checks the price-contribution prompt first and short-circuits review for that activation
/// when it wins), but a banner already on screen from an EARLIER activation was invisible to
/// this check — so a later, separate `.active` transition could invoke Apple's system
/// review-request sheet while 85Blends' own banner was still visibly on screen underneath it.
/// Two concrete, ordinary paths reach this: (1) a second Directions tap to a different
/// reportable station replaces the pending contribution in the store while the first one's
/// banner is still showing, and the user returns from the second handoff too quickly (under 2
/// minutes) for the new contribution to be presentable yet; (2) the user never acts on a shown
/// banner and it ages past its 6-hour expiry, which clears the persisted store but — before
/// this audit — never cleared the `activePriceContribution` state actually driving the banner
/// on screen. See `attemptPendingPriceContributionPromptIfNeeded()`'s expiry branch for the
/// matching fix that keeps that banner from lingering indefinitely once this check starts
/// deferring to it.
enum ReviewRequestConflictingPresentation {
    static func isPresent(
        isShowingWhatsNew: Bool,
        hasWidgetStation: Bool,
        hasPendingWidgetURL: Bool,
        hasActivePriceContribution: Bool
    ) -> Bool {
        isShowingWhatsNew || hasWidgetStation || hasPendingWidgetURL || hasActivePriceContribution
    }
}

struct ContentView: View {
    // Internal (not private) so AppExperienceNavigation's pure tab-visibility/selection rules —
    // and their tests — can reference ContentView.Tab directly.
    enum Tab: Hashable {
        case calculator, stations, garage, reminders, more
    }

    @AppStorage(AppPreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppPreferenceKey.showGarageTab) private var showGarageTab = true
    @AppStorage(AppPreferenceKey.showRemindersTab) private var showRemindersTab = true
    // Absence of this key (pre-App-Experience-Mode installs) resolves to .normal via
    // AppExperienceMode.resolved(from:) — existing users never lose a tab on update.
    @AppStorage(AppPreferenceKey.appExperienceMode) private var appExperienceModeRaw = AppExperienceMode.normal.rawValue
    @AppStorage(AppPreferenceKey.lastPresentedWhatsNewVersion) private var lastPresentedWhatsNewVersion = ""
    @Environment(AutomaticPumpDetectionService.self) private var pumpDetectionService
    // 85Blends 2.4.0 review-request system — see attemptAutomaticReviewRequestIfNeeded() below.
    // Read independently from EightyFiveBlendsApp's own scenePhase handling (which owns session
    // COUNTING via ReviewRequestManager); this one only decides whether it's a calm moment to
    // actually invoke the review-request API.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    // Stations is the default launch tab (2.3.2) — the initial selection only; this is never
    // persisted/remembered (no @AppStorage, no last-tab memory), so every fresh ContentView
    // still starts here regardless of what was last viewed. Explicit navigation still overrides
    // it: the Automatic Pump Detection notification handler below still routes to .calculator,
    // and AppExperienceNavigation.resolvedSelection's invalid-tab-after-a-mode-switch fallback
    // (a separate concern from the startup default) still redirects to .calculator too.
    @State private var widgetStation: NearbyE85Station?
    @State private var widgetSnapshot: NearbyE85Snapshot?
    @State private var pendingWidgetURL: URL?
    // 85Blends 2.4.0 Nearby E85 widget Pro gate — set only by openPendingWidgetLink() when the
    // entitlement route resolves to .presentProPaywall (a CONFIRMED Free user tapped the widget).
    // Presents the single existing 85Blends Pro paywall; ProUpgradeView's own onAppear/
    // onDisappear already report it via SubscriptionManager.isPaywallPresented, so the
    // review-request and price-contribution prompts below stay suppressed while it's up with
    // no extra wiring here.
    @State private var isShowingWidgetProPaywall = false
    // 85Blends 2.4.0 post-navigation price-contribution prompt — set only at the exact moment
    // attemptPendingPriceContributionPromptIfNeeded() below decides to show the banner; never
    // bound continuously to PendingPriceContributionStore.shared.current, mirroring how
    // isShowingWhatsNew/widgetStation are likewise plain @State flipped at one decision point
    // rather than a reactively-observed external store.
    @State private var activePriceContribution: PendingPriceContribution?
    // Pre-commit fix (validation pass) — guards price_report_prompt_shown against duplicate
    // impressions for the same contribution; see recordPromptShownIfNeeded(for:) below.
    @State private var lastPromptShownContribution: PendingPriceContribution?
    @Environment(StationLocationManager.self) private var widgetLocationManager
    @State private var selectedTab: Tab = .stations
    @State private var isShowingWhatsNew = false
    @State private var hasEvaluatedWhatsNewEligibility = false
    // Snapshotted once, synchronously, from the raw persisted value at the moment this view is
    // first created — deliberately NOT read via @AppStorage/.onChange, whose relative firing
    // order against .onAppear on a newly-mounted view isn't something to depend on. This makes
    // "did onboarding complete during this exact launch" a plain, deterministic comparison
    // instead of a race between two SwiftUI update-cycle callbacks.
    @State private var wasOnboardingAlreadyCompleteAtLaunch = UserDefaults.standard.bool(
        forKey: AppPreferenceKey.hasCompletedOnboarding
    )

    private var appExperienceMode: AppExperienceMode {
        .resolved(from: appExperienceModeRaw)
    }

    private var visibleTabs: [Tab] {
        AppExperienceNavigation.visibleTabs(
            mode: appExperienceMode,
            showGarageTab: showGarageTab,
            showRemindersTab: showRemindersTab
        )
    }

    /// 85Blends 2.4.0 Nearby E85 widget Pro gate — the authoritative (SubscriptionManager-derived,
    /// never App-Group-mirror-derived) decision for a pending widget deep link. Read inside `body`
    /// via `.onChange(of:)` below so a tap that arrived before RevenueCat answered is re-evaluated
    /// the moment it does, instead of being dropped or paywalled on an unknown entitlement.
    private var widgetEntitlementRoute: NearbyE85WidgetEntitlementRoute {
        .resolve(for: SubscriptionManager.shared)
    }

    // True only when onboarding transitioned from incomplete to complete during this same
    // launch — i.e. a brand-new (or onboarding-reset) user finishing onboarding just now. False
    // for every other case, including an existing user who completed onboarding in some past
    // session, however long ago. See WhatsNewPresentation.shouldPresent(...).
    private var onboardingJustCompletedThisLaunch: Bool {
        hasCompletedOnboarding && wasOnboardingAlreadyCompleteAtLaunch == false
    }

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                TabView(selection: $selectedTab) {
                    // isActiveTab drives CalculatorView's foreground GPS-polling lifecycle — see
                    // that struct's own isActiveTab comment. TabView keeps every child mounted
                    // regardless of selection, so this is the only reliable signal for "is
                    // Calculator actually the one on screen right now."
                    CalculatorView(isActiveTab: selectedTab == .calculator)
                    .tabItem {
                        Label("Calculator", systemImage: "fuelpump")
                    }
                    .tag(Tab.calculator)

                    StationsView()
                        .tabItem {
                            Label("Stations", systemImage: "mappin.and.ellipse")
                        }
                        .tag(Tab.stations)

                    // Rendered tab membership is driven by the same visibleTabs computed
                    // property the mode-switch redirect below uses, rather than re-deriving
                    // "appExperienceMode == .normal && showGarageTab" inline here — one source
                    // of truth (AppExperienceNavigation.visibleTabs) instead of two copies of
                    // the same rule that could silently drift apart. Normal Mode honors the
                    // user's existing Garage/Reminders tab preferences exactly as before; Simple
                    // Mode shows only Calculator, Stations, and More, regardless of those
                    // preferences — they're never read, or mutated, while in Simple Mode.
                    if visibleTabs.contains(.garage) {
                        GarageView()
                            .tabItem {
                                Label("Garage", systemImage: "car.fill")
                            }
                            .tag(Tab.garage)
                    }

                    if visibleTabs.contains(.reminders) {
                        RemindersView()
                            .tabItem {
                                Label("Reminders", systemImage: "bell.badge")
                            }
                            .tag(Tab.reminders)
                    }

                    MoreView()
                        .tabItem {
                            Label("More", systemImage: "ellipsis.circle.fill")
                        }
                        .tag(Tab.more)
                }
                .tint(AppTheme.Colors.primaryGreen)
                // A tapped Automatic Pump Detection notification resolves to a pending
                // station on the service; switch to Calculator so its own existing sheet
                // machinery (see CalculatorView) can present Pump Mode for it. Calculator is
                // present in every App Experience Mode, so this is always a valid destination —
                // if a future change ever targets a different tab here, it must first go
                // through AppExperienceNavigation.resolvedSelection like the mode-switch
                // handler below does.
                .onChange(of: pumpDetectionService.pendingDetectedStation) { _, newValue in
                    if newValue != nil {
                        selectedTab = .calculator
                    }
                }
                // Switching App Experience Mode can hide the tab currently on screen (e.g.
                // viewing Garage, then switching to Simple Mode). Redirect deliberately rather
                // than relying on undefined TabView behavior when its selection tag disappears.
                .onChange(of: appExperienceModeRaw) {
                    selectedTab = AppExperienceNavigation.resolvedSelection(
                        current: selectedTab,
                        visibleTabs: visibleTabs
                    )
                }
                // Attached to the TabView branch itself (not the outer Group), so this can only
                // ever run once onboarding is complete and the normal app interface is active —
                // structurally, not just by a runtime check, satisfying "never over active
                // onboarding." Not tied to any specific tab, so this works identically in
                // Simple and Normal App Experience Mode.
                .onAppear {
                    attemptWhatsNewPresentation()
                }
                // AdManager's UMP consent gathering (see its own header/gatherConsent()) can
                // still be in flight when this view first appears, and may present a raw UIKit
                // consent form on the same window a SwiftUI `.sheet` would use — see
                // WhatsNewPresentation.shouldPresent's isRequiredConsentPresentationPending
                // guard. Re-attempting here, once AdManager reports consent resolution is no
                // longer pending, is what turns that guard's "not yet" into an actual
                // presentation later in the same launch, without ever presenting over required
                // consent UI.
                .onChange(of: AdManager.shared.isInitialConsentResolutionPending) { _, _ in
                    if pendingWidgetURL != nil { openPendingWidgetLink() }
                    else { attemptWhatsNewPresentation() }
                }
                // 85Blends 2.4.0 review-request system — the "next calm foreground moment"
                // this feature waits for. A successful Directions launch typically backgrounds
                // 85Blends for the external maps app handoff, so the return-to-.active
                // transition that follows is a natural, already-instrumented point to check —
                // never fired synchronously from the Directions tap itself. See
                // attemptAutomaticReviewRequestIfNeeded() below for the full safety gate.
                //
                // 85Blends 2.4.0 price-contribution prompt — deliberately evaluated FIRST on
                // the exact same transition: if a pending contribution becomes eligible and
                // safe to show, this activation shows the banner and skips the review-request
                // attempt entirely for THIS activation only. ReviewRequestManager's own
                // persisted state (session count, engagement eligibility, etc.) is never
                // touched by that skip, so review-request eligibility is simply re-evaluated
                // normally on a later qualifying activation — it is never permanently
                // suppressed. Price information is time-sensitive; the review request can wait.
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        if attemptPendingPriceContributionPromptIfNeeded() == false {
                            attemptAutomaticReviewRequestIfNeeded()
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let activePriceContribution {
                        PendingPriceContributionBannerView(
                            stationName: activePriceContribution.stationName,
                            onReportPrice: { handleReportPriceTapped(for: activePriceContribution) },
                            onNotNow: { handleNotNowTapped(for: activePriceContribution) }
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        // The real "shown" boundary — see recordPromptShownIfNeeded(for:)'s own
                        // doc comment. Fires only once this view has actually been asked to
                        // appear, never merely because activePriceContribution was assigned.
                        .onAppear {
                            recordPromptShownIfNeeded(for: activePriceContribution)
                        }
                    }
                }
                .sheet(
                    isPresented: $isShowingWhatsNew,
                    onDismiss: {
                        // Fires for every dismissal path — the Continue button and a
                        // swipe-away alike — so either one reliably records the version as
                        // shown and neither leaves the sheet re-appearing on a later launch.
                        lastPresentedWhatsNewVersion = WhatsNewPresentation.versionToPersistOnDismiss(
                            currentAppVersion: ReleaseNotes.currentAppVersion
                        )
                        openPendingWidgetLink()
                    }
                ) {
                    WhatsNewView(onContinue: { isShowingWhatsNew = false })
                }
            } else {
                OnboardingView()
            }
        }
        .onOpenURL { url in
            guard NearbyE85DeepLink.parse(url) != nil else { return }
            pendingWidgetURL = url
            openPendingWidgetLink()
        }
        .onChange(of: hasCompletedOnboarding) { _, completed in
            if completed { openPendingWidgetLink() }
        }
        // A widget tap held at .waitForEntitlement (see openPendingWidgetLink) is retried here as
        // soon as the entitlement inputs change — typically RevenueCat's first CustomerInfo of the
        // launch arriving a moment after the deep link did. No-op when nothing is pending.
        .onChange(of: widgetEntitlementRoute) { _, _ in
            if pendingWidgetURL != nil { openPendingWidgetLink() }
        }
        .sheet(item: $widgetStation) { station in
            if let snapshot = widgetSnapshot { NearbyE85StationView(station: station, snapshot: snapshot) }
        }
        // Same presentation ProFeatureLockView already uses for every other Pro gate — one
        // paywall, one presentation style; nothing widget-specific is rendered here.
        .sheet(isPresented: $isShowingWidgetProPaywall) {
            NavigationStack { ProUpgradeView(presentationMode: .modal) }
        }
    }

    private func openPendingWidgetLink() {
        guard hasCompletedOnboarding, let url = pendingWidgetURL,
              let destination = NearbyE85DeepLink.parse(url) else { return }
        selectedTab = .stations
        hasEvaluatedWhatsNewEligibility = true
        guard !AdManager.shared.isInitialConsentResolutionPending else { return }
        if isShowingWhatsNew {
            isShowingWhatsNew = false
            return // Present after its onDismiss; never compete with an existing sheet.
        }
        // 85Blends 2.4.0 Nearby E85 widget Pro gate. Evaluated AFTER the onboarding/consent/
        // What's New guards above (so the paywall never competes with those either) and BEFORE
        // the URL is consumed, so an unresolved entitlement keeps the tap pending rather than
        // dropping it. Every widget tap — a locked Small/Medium/Large shell, the neutral "verify"
        // shell, or a real Pro map/row/directions link — lands here; only a Pro user proceeds to
        // the ordinary route below, and only a CONFIRMED Free user sees the paywall. The pure
        // NearbyE85WidgetLinkGate owns the pending-URL lifecycle (held intact vs consumed exactly
        // once) so that lifecycle is unit-tested rather than implied by this function's shape.
        let gate = NearbyE85WidgetLinkGate.advance(pendingURL: url, route: widgetEntitlementRoute)
        pendingWidgetURL = gate.pendingURL // Same URL while held; nil once consumed — the one consumption point.
        switch gate.action {
        case .hold:
            return // .onChange(of: widgetEntitlementRoute) retries once RevenueCat answers.
        case .presentPaywall:
            isShowingWidgetProPaywall = true // The paywall IS this tap's outcome; no widget route.
            return
        case .route:
            break
        }
        switch NearbyE85WidgetRouting.resolve(destination, snapshot: NearbyE85Cache().read(),
                                              isAuthorized: widgetLocationManager.isAuthorizedForUserLocation) {
        case .switchToStations:
            break // selectedTab = .stations above is the entire result.
        case .openDirections(let mapsDestination):
            // One action, start to finish: no detail screen, no intermediate 85Blends UI beyond
            // the Stations tab already selected underneath.
            MapsRoutingHelper.openDirections(to: mapsDestination)
        case .showStationDetail(let station, let snapshot):
            widgetSnapshot = snapshot
            widgetStation = station
        }
    }

    /// Called from `.onAppear` and again from the consent-pending `.onChange` above — safe to
    /// call multiple times in a launch. The fresh-onboarder bookkeeping below only ever persists
    /// state (never presents anything), so it always runs on the first call regardless of
    /// consent timing; only the actual `isShowingWhatsNew` decision waits on consent resolution,
    /// via `hasEvaluatedWhatsNewEligibility` staying `false` until that decision is actually made
    /// — so a call that returns early because consent is still pending leaves this method free to
    /// run again later in the same launch, exactly once, once consent resolution completes.
    private func attemptWhatsNewPresentation() {
        guard hasEvaluatedWhatsNewEligibility == false else { return }

        // 85Blends 2.3.0 release-blocker fix: a brand-new user who just finished onboarding
        // this launch has already been introduced to the current app (shouldPresent already
        // suppresses What's New for them THIS launch via onboardingJustCompletedThisLaunch) —
        // but without this, lastPresentedWhatsNewVersion stays empty, so launch #2 would
        // incorrectly show What's New for the version they onboarded under. Record that version
        // as already handled, at this same deterministic onboarding-completion transition,
        // reusing the exact persistence semantics a normal dismissal already uses (see
        // WhatsNewPresentation.versionToPersistOnDismiss). A future version upgrade remains
        // eligible normally — this only ever records the CURRENT version. Idempotent, so it's
        // harmless if this method runs again before the actual decision below succeeds.
        if onboardingJustCompletedThisLaunch {
            lastPresentedWhatsNewVersion = WhatsNewPresentation.versionToPersistOnDismiss(
                currentAppVersion: ReleaseNotes.currentAppVersion
            )
        }

        let isConsentPending = AdManager.shared.isInitialConsentResolutionPending
        guard isConsentPending == false else {
            // Leave hasEvaluatedWhatsNewEligibility false so the .onChange above gets a real
            // second attempt once consent resolution completes.
            return
        }

        hasEvaluatedWhatsNewEligibility = true
        isShowingWhatsNew = WhatsNewPresentation.shouldPresent(
            currentAppVersion: ReleaseNotes.currentAppVersion,
            lastPresentedVersion: lastPresentedWhatsNewVersion,
            hasCompletedOnboarding: hasCompletedOnboarding,
            onboardingJustCompletedThisLaunch: onboardingJustCompletedThisLaunch,
            isRequiredConsentPresentationPending: isConsentPending
        )
    }

    /// 85Blends 2.4.0 App Store review-request system. Called only on a return to `.active`
    /// (never synchronously from a Directions tap or any other user action) — see this method's
    /// call site above. Building `hasConflictingPresentation` from What's New, the widget detail
    /// sheet, any not-yet-resolved widget deep link, AND the price-contribution banner means this
    /// never competes with any of ContentView's other existing presentations, on top of the
    /// onboarding/consent/paywall/purchase checks — see `ReviewRequestConflictingPresentation`'s
    /// own header for exactly which gap this last term closes and why.
    /// `ReviewRequestManager.attemptReviewRequestIfAppropriate` is the only place engagement
    /// eligibility + cooldown are actually evaluated; this method only supplies the
    /// presentation-safety half of the gate and, if both pass, is the one place in the app that
    /// invokes the system review-request action.
    private func attemptAutomaticReviewRequestIfNeeded() {
        let hasConflictingPresentation = ReviewRequestConflictingPresentation.isPresent(
            isShowingWhatsNew: isShowingWhatsNew,
            hasWidgetStation: widgetStation != nil,
            hasPendingWidgetURL: pendingWidgetURL != nil,
            hasActivePriceContribution: activePriceContribution != nil
        )
        let isSafeToPresent = ReviewRequestEligibility.isSafeToPresent(
            hasCompletedOnboarding: hasCompletedOnboarding,
            isConsentResolutionPending: AdManager.shared.isInitialConsentResolutionPending,
            hasConflictingPresentation: hasConflictingPresentation,
            isPaywallPresented: SubscriptionManager.shared.isPaywallPresented,
            isPurchaseActive: SubscriptionManager.shared.purchaseState != .idle,
            isAppActive: scenePhase == .active
        )

        guard ReviewRequestManager.shared.attemptReviewRequestIfAppropriate(
            isSafeToPresent: isSafeToPresent,
            currentVersion: ReleaseNotes.currentAppVersion
        ) else { return }

        requestReview()
    }

    /// 85Blends 2.4.0 price-contribution prompt. Called only on a return to `.active`, BEFORE
    /// attemptAutomaticReviewRequestIfNeeded() — see this method's call site above for the
    /// arbitration this ordering implements. Returns `true` exactly when the banner was shown
    /// this activation (so the caller skips the review-request attempt for it), `false`
    /// otherwise. `hasConflictingPresentation` here deliberately has no term for this banner
    /// itself (unlike attemptAutomaticReviewRequestIfNeeded()'s own, which does — see
    /// `ReviewRequestConflictingPresentation`'s header): a presentation can't meaningfully
    /// conflict with itself. It otherwise means this prompt never competes with any of
    /// ContentView's other existing presentations either — but it has no visibility into
    /// StationsView's own private sheet state (e.g. a Classic station's StationPriceUpdateSheet
    /// already open for something else); the banner is a non-modal `.safeAreaInset`, so such a
    /// sheet already structurally covers/obscures it, and this method does not need to know it
    /// exists to get that protection. An expired contribution is discarded here rather than left
    /// to linger silently forever — see the expiry branch below for why that discard now clears
    /// more than just the persisted store.
    @discardableResult
    private func attemptPendingPriceContributionPromptIfNeeded() -> Bool {
        let now = Date.now
        guard let pending = PendingPriceContributionStore.shared.current else { return false }

        if PendingPriceContributionEligibility.isExpired(pending, now: now) {
            PendingPriceContributionStore.shared.clear()
            // 85Blends 2.4.0 review-request audit fix — also clear the @State actually driving
            // the banner, not just the persisted store. Without this, a banner nobody ever acted
            // on would keep rendering indefinitely past its own expiry (a stale, meaningless
            // prompt) AND — now that attemptAutomaticReviewRequestIfNeeded() correctly defers to
            // activePriceContribution being non-nil — would permanently block the automatic
            // review request too. This is a no-op if activePriceContribution is already nil or
            // already showing something else.
            activePriceContribution = nil
            return false
        }

        let hasConflictingPresentation = isShowingWhatsNew || widgetStation != nil || pendingWidgetURL != nil
        guard PendingPriceContributionEligibility.shouldPresent(
            pending: pending,
            now: now,
            hasCompletedOnboarding: hasCompletedOnboarding,
            isConsentResolutionPending: AdManager.shared.isInitialConsentResolutionPending,
            hasConflictingPresentation: hasConflictingPresentation,
            isPaywallPresented: SubscriptionManager.shared.isPaywallPresented,
            isPurchaseActive: SubscriptionManager.shared.purchaseState != .idle,
            isAppActive: scenePhase == .active
        ) else {
            return false
        }

        // Pre-commit fix (validation pass) — deliberately does NOT fire
        // price_report_prompt_shown here. Setting this @State only means "the banner is
        // about to be asked to render" — it says nothing about whether it actually appeared
        // on screen. The event now fires from the banner's own `.onAppear` (see
        // recordPromptShownIfNeeded(for:) and its call site in body), the real visibility
        // boundary a "shown" impression should mean.
        activePriceContribution = pending
        return true
    }

    /// "Report Price" — hides the banner, switches to the Stations tab, and hands the
    /// contribution to StationsView (see PriceContributionPresentationRequest) to open the
    /// compact reporter for it. Deliberately does NOT clear PendingPriceContributionStore
    /// here: the contribution stays pending until reporting reaches a terminal state (success,
    /// a genuine failure, or the user cancelling the sheet) — see
    /// StationsView.savePriceUpdate/handlePriceUpdateCancel.
    ///
    /// Pre-commit fix (validation pass) — the user can tap "Report Price" from any tab, and a
    /// `.sheet` presented from a TabView child that isn't the currently selected/visible tab is
    /// not reliable. `selectedTab = .stations` is set in the SAME synchronous call as the
    /// presentation request, deliberately without any added yield/delay: this exact shape —
    /// one shared piece of state changing, a tab switch AND a sibling view's own reaction both
    /// following from it in the same SwiftUI update pass — is already the proven, shipped
    /// pattern this app uses for Automatic Pump Detection (ContentView's own
    /// `.onChange(of: pumpDetectionService.pendingDetectedStation)` switches to `.calculator` at
    /// the same moment CalculatorView's independent `.onChange` of that identical value opens
    /// Pump Mode — see CalculatorView.swift:367-369). No new coordinator was introduced; this
    /// reuses the existing `selectedTab`/`Tab` mechanism already on this view.
    private func handleReportPriceTapped(for contribution: PendingPriceContribution) {
        activePriceContribution = nil
        selectedTab = .stations
        PriceContributionPresentationRequest.shared.pendingRequest = contribution
    }

    /// The real "the user could actually see this" boundary for price_report_prompt_shown —
    /// called from the banner's own `.onAppear` (see body), never from the moment
    /// `activePriceContribution` is merely assigned. Guarded by `lastPromptShownContribution`
    /// (compared via PendingPriceContribution's own Equatable conformance, which includes
    /// `directionsOpenedAt`) so repeated body evaluations, a Dynamic Type change, or any other
    /// unrelated re-render can never re-fire an impression for the SAME contribution — while a
    /// genuinely new contribution (a different station, or the same station on a later visit)
    /// still correctly counts as its own new impression. If presentation was ever unsafe, this
    /// is simply never called at all (the banner never mounts), so no impression is recorded
    /// for a prompt the user could never see.
    private func recordPromptShownIfNeeded(for contribution: PendingPriceContribution) {
        guard lastPromptShownContribution != contribution else { return }
        lastPromptShownContribution = contribution
        AnalyticsService.track(.priceReportPromptShown, properties: AnalyticsEventProperties(entryPoint: .other))
    }

    /// "Not Now" — hides the banner and consumes the contribution immediately so this exact
    /// navigation event is never shown again (no cooldown/tombstone system; one pending
    /// navigation event is enough).
    private func handleNotNowTapped(for contribution: PendingPriceContribution) {
        activePriceContribution = nil
        PendingPriceContributionStore.shared.clear()
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [
                VehicleProfile.self,
                FuelLogEntry.self,
                MaintenanceReminder.self,
                ReminderCompletionRecord.self,
                FuelStation.self,
            ],
            inMemory: true
        )
}

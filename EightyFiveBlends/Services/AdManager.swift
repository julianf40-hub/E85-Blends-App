//
//  AdManager.swift
//  EightyFiveBlends
//
//  AdMob Phase 1 added SDK bootstrap only — initialization and state tracking, no ad unit ID,
//  no ad request. AdMob Phase 2 (below, `NativePlacement`) adds the ad unit ID configuration for
//  85Blends' two native placements; the actual loading/rendering code lives in
//  Components/NativeAdView.swift, which reads `NativePlacement.adUnitID` from here rather than
//  hardcoding an ad unit ID at either call site — this file stays the one place both the SDK
//  config and the ad unit ID config live, mirroring how RevenueCatSubscriptionService.swift is
//  scoped to "configure the SDK and expose its state," not to any one paywall screen.
//
//  NO INTERRUPTIVE ADVERTISING — standing product/UX decision, not a Phase 1 scoping choice:
//  85Blends will not show interstitial, full-screen, timed, forced-dismiss, or app-open ads,
//  ever. Ads are optional native placements embedded into existing scrolling content only, at
//  two approved locations — Calculator's bottom-of-scroll and an inline Stations placement — and
//  a user must always be able to keep using the app without waiting on an ad. Nothing in
//  AdManager should ever gain interstitial preload/present methods; if future sponsored-content
//  work replaces network ads, this same non-interruptive principle still applies.
//
//  PATTERN: this intentionally mirrors RevenueCatSubscriptionService.swift's shape —
//  @MainActor @Observable singleton, an explicit ConfigurationState instead of a bare Bool,
//  idempotent configureIfNeeded(), and failures captured into a diagnostics-only property
//  rather than thrown or surfaced to the user. Consistency here matters: this is the second
//  third-party SDK this app configures at launch, and it should look like the first one to
//  whoever reads both side by side.
//
//  INITIALIZATION TIMING: configureIfNeeded() is called from EightyFiveBlendsApp's launch
//  `.task`, exactly where RevenueCatSubscriptionService.shared.configureIfNeeded() is called —
//  never from EightyFiveBlendsApp.init(). That init() already carries one deliberate, documented
//  exception (synchronous AutomaticPumpDetectionService wiring, because a background region
//  callback needs it before the first view mounts). Ad SDK startup has no equivalent hard
//  requirement to run before first frame, so it stays on the same async, non-blocking path
//  RevenueCat already uses rather than adding a second reason to slow down cold launch. See
//  EightyFiveBlendsApp.swift's own header/init() comment for the full reasoning.
//
//  AD UNIT CONFIGURATION: Info.plist's GADApplicationIdentifier is the real 85Blends AdMob App ID
//  (`ca-app-pub-2011940670640942~8655578112`) — not Google's sample App ID. (An earlier draft of
//  this comment claimed otherwise; corrected during the 2.3.2 public-release-readiness pass —
//  Info.plist itself was already correct, only this comment was stale.) `NativePlacement.adUnitID`
//  below requests Google's public sample Native Advanced ad unit ID only for Debug/Internal
//  builds; Release requests the real, placement-specific 85Blends ad unit ID — see
//  `NativePlacement`.
//
//  PRIVACY-FIRST AD CONFIGURATION (2.3.2 release-readiness pass): ads support the Free tier, but
//  85Blends does not introduce tracking merely to improve ad personalization. Three things
//  enforce that here:
//  1. Publisher First-Party ID is explicitly disabled (`setPublisherFirstPartyIDEnabled(false)`)
//     in `configureIfNeeded()` below.
//  2. Google's User Messaging Platform (UMP) SDK gathers the user's consent choice (EEA/UK
//     Transparency & Consent Framework, plus supported US state privacy signals) before any ad
//     is ever requested — see `gatherConsent()`. `MobileAds.shared.start()` itself is gated on
//     `ConsentInformation.shared.canRequestAds`, matching Google's own documented integration
//     pattern, so the SDK never starts ad-serving before consent is known.
//  3. `canRequestAds` below is the single, centralized ad-readiness gate every placement must
//     pass: Pro status, entitlement-resolution-pending, and UMP consent all have to clear before
//     a native ad is requested anywhere in the app. See Components/NativeAdView.swift's `.task`,
//     the only other place this file's ad-readiness state is read — no placement duplicates any
//     part of this decision itself.
//
//  PRO AWARENESS: `isAdsEnabled` below reads SubscriptionManager.shared directly — the same
//  single entitlement source every other Pro gate in this app reads (see SubscriptionManager.
//  swift's own header). `canRequestAds` builds on it, adding the entitlement-resolution-pending
//  check (mirrors StationsView's `isInitialEntitlementResolutionPending` gate — see
//  SubscriptionManager.isInitialEntitlementResolutionPending's header for why a pending read must
//  never be treated as "definitely Free") and UMP consent. Every ad-related Pro/consent check
//  should funnel through `canRequestAds`, never re-derive its own combination of these checks.
//

import Foundation
import Observation
import GoogleMobileAds
import UserMessagingPlatform
import UIKit
import os

// TEMPORARY — production/TestFlight diagnostics for the "native ads not appearing"
// investigation. Every use of this logger below is marked TEMPORARY and must be removed,
// alongside this declaration, once the root cause is confirmed and fixed — see the matching,
// more detailed comment on Components/NativeAdView.swift's own diagnostics logger (same
// os.Logger-not-print, `privacy: .public`, and `#if !DEBUG` (Internal + Release, not local
// Debug) reasoning applies here). Declared separately from NativeAdView.swift's instance,
// deliberately, so either file's diagnostics block can be deleted independently without a
// cross-file dependency to worry about.
#if !DEBUG
private let admobDiagnosticsLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.e85blends.app.ios",
    category: "AdMobDiagnostics"
)
#endif

@MainActor
@Observable
final class AdManager {
    static let shared = AdManager()

    // MARK: - Configuration state

    enum ConfigurationState: Equatable {
        case notConfigured
        case configuring
        case configured
    }

    private(set) var configurationState: ConfigurationState = .notConfigured

    var isConfigured: Bool { configurationState == .configured }

    /// Diagnostics only — mirrors RevenueCatSubscriptionService.lastErrorDescription. The Google
    /// Mobile Ads SDK's own start(completionHandler:) is non-throwing (adapter init failures are
    /// reported per-adapter in the returned status, not as a hard failure of the SDK as a
    /// whole), so this is populated defensively and is never surfaced as a user-facing alert,
    /// banner, or error state anywhere in the app — a failed/partial ad SDK init must never
    /// block or degrade any core 85Blends feature.
    private(set) var lastErrorDescription: String?

    /// Per-adapter initialization status from the SDK, kept for internal diagnostics only (e.g.
    /// a future Internal-build diagnostics card, matching how SubscriptionManager already
    /// exposes debugEntitlementStatus for the same purpose). Never read by any user-facing view.
    private(set) var lastInitializationStatus: InitializationStatus?

    // MARK: - Pro awareness (foundation only — no ad request/load/present exists yet)

    /// Whether ads are allowed to be requested/loaded/shown for the current user. Reads
    /// `SubscriptionManager.shared.isProUser` directly — the exact same singleton and property
    /// every existing Pro gate in this app already reads (see ProFeatureGate.isUnlocked in
    /// ProFeatureLockView.swift) — so there is exactly one place in the whole app that decides
    /// Pro status, never a second one invented here. `SubscriptionManager` is itself
    /// `@Observable`, so this recomputes automatically as entitlement changes (purchase,
    /// restore, expiration, or the Internal/Debug override) — no caching, no polling.
    ///
    /// Nothing in AdManager calls this yet — no ad request exists in Phase 1 — but future
    /// native-ad placement code (Calculator bottom-of-scroll, Stations inline — see this file's
    /// header; no interstitials, ever) should gate on this rather than reading
    /// SubscriptionManager directly a second time, so every ad-related Pro check funnels
    /// through one named, documented property.
    var isAdsEnabled: Bool {
        SubscriptionManager.shared.isProUser == false
    }

    // MARK: - Advertising consent (UMP)

    /// True until this session's first UMP consent-gathering attempt (success or failure)
    /// completes. Mirrors `SubscriptionManager.isInitialEntitlementResolutionPending`'s shape and
    /// purpose: while this is true, `canRequestAds` is always false, so no placement can render
    /// an ad decision before this app even knows whether it's allowed to ask Google for one.
    private(set) var isInitialConsentResolutionPending = true

    /// Set from `ConsentInformation.shared.canRequestAds` once `gatherConsent()` completes.
    /// Stored (rather than read live from the SDK on every access) so this `@Observable` class
    /// actually publishes a change when consent resolves — a plain computed property reading an
    /// external singleton's mutable state would not trigger SwiftUI observation the way a tracked
    /// stored property does. Defaults to `false`, matching `ConsentInformation`'s own default
    /// before any request has been made this session.
    private(set) var consentAllowsAdRequests = false

    /// Whether Preferences/About should show a "Privacy Options" entry point. Read live from
    /// `ConsentInformation.shared` rather than cached — unlike `consentAllowsAdRequests`, this
    /// only gates a Settings row's visibility, never an ad-loading decision, so there's no
    /// reactivity requirement strong enough to justify caching it (by the time anyone opens
    /// Preferences, `gatherConsent()` has long since run). Deliberately untyped here (no
    /// `PrivacyOptionsRequirementStatus`-shaped stored property) so this file never has to name
    /// that enum's exact declared type — only compare against `.required`, which Swift resolves
    /// by inference regardless of the SDK's exact naming for it.
    var isPrivacyOptionsEntryPointRequired: Bool {
        ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }

    /// The single, centralized ad-readiness gate — see this file's header. Reads the three live
    /// singleton-backed flags and hands them to `canRequestAds(isAdsEnabled:isEntitlementResolutionPending:consentAllowsAdRequests:)`
    /// below, which is where the actual decision rule lives — split out the same way
    /// `errorDescription(forAdapterStates:)` already is, so the rule itself is directly
    /// unit-testable with plain Bool values, without mocking SubscriptionManager/
    /// ConsentInformation.
    var canRequestAds: Bool {
        Self.canRequestAds(
            isAdsEnabled: isAdsEnabled,
            isEntitlementResolutionPending: SubscriptionManager.shared.isInitialEntitlementResolutionPending,
            consentAllowsAdRequests: consentAllowsAdRequests
        )
    }

    /// Pure decision rule behind `canRequestAds` above. Every one of these three checks must
    /// independently allow ads before any placement may request one:
    /// - `isAdsEnabled`: the user isn't Pro (Pro never sees ads, full stop).
    /// - `isEntitlementResolutionPending` is `false` (mirrors StationsView's own gate — a pending
    ///   read must never be treated as "definitely Free").
    /// - `consentAllowsAdRequests`: UMP consent has been gathered and allows an ad request.
    static func canRequestAds(
        isAdsEnabled: Bool,
        isEntitlementResolutionPending: Bool,
        consentAllowsAdRequests: Bool
    ) -> Bool {
        isAdsEnabled && isEntitlementResolutionPending == false && consentAllowsAdRequests
    }

    private init() {
        // Real SDK configuration happens once from app startup (see EightyFiveBlendsApp.swift's
        // launch `.task`), not here — same reasoning as RevenueCatSubscriptionService.init()'s
        // own comment: an explicit app-lifecycle hook is preferred over a side effect in this
        // singleton's lazy init.
    }

    // MARK: - Configuration

    /// Idempotent — safe to call once from app startup, and safe to call again (a no-op) if
    /// something ever calls it a second time. Never throws: a missing/misconfigured
    /// GADApplicationIdentifier or a failed adapter is captured into `lastErrorDescription` /
    /// `lastInitializationStatus` for diagnostics only, never surfaced to the user and never
    /// allowed to block app launch or any other feature.
    func configureIfNeeded() async {
        // TEMPORARY — the very first line of this function, logged unconditionally on every
        // call (including a redundant second call that the guard below then skips), so a
        // TestFlight capture proves whether configureIfNeeded() is ever actually invoked from
        // EightyFiveBlendsApp's launch .task at all. Remove alongside every other TEMPORARY
        // block in this file.
        #if !DEBUG
        admobDiagnosticsLogger.log("""
            configureIfNeeded() called — \
            stateOnEntry=\(String(describing: self.configurationState), privacy: .public)
            """)
        #endif

        guard configurationState == .notConfigured else {
            // TEMPORARY — explains exactly why this call was skipped.
            #if !DEBUG
            admobDiagnosticsLogger.log("""
                configureIfNeeded() skipped — state is not notConfigured \
                (\(String(describing: self.configurationState), privacy: .public))
                """)
            #endif
            return
        }
        configurationState = .configuring

        // TEMPORARY — see the diagnostics-logger declaration at the top of this file.
        #if !DEBUG
        admobDiagnosticsLogger.log("""
            configureIfNeeded() starting — \
            state=\(String(describing: self.configurationState), privacy: .public)
            """)
        #endif

        // Gather UMP consent BEFORE ever starting the Mobile Ads SDK — see gatherConsent()'s own
        // header and this file's header for why. This sets consentAllowsAdRequests and clears
        // isInitialConsentResolutionPending regardless of outcome (including a network/UMP
        // failure — see gatherConsent()), so this function never hangs waiting on it.
        await gatherConsent()

        guard consentAllowsAdRequests else {
            // Consent isn't known to allow ad requests yet (not yet granted, still required, or
            // the request itself failed — see gatherConsent()). Per Google's own documented UMP
            // integration pattern, the Mobile Ads SDK itself is not started in this case, so no
            // ad-serving infrastructure spins up before consent is known. configurationState
            // deliberately stays `.configuring` (not `.configured`) — nothing in this app reads
            // isConfigured today, but leaving it here would misreport that the underlying SDK
            // actually started. A later cold launch's configureIfNeeded() call will try again.
            #if !DEBUG
            admobDiagnosticsLogger.log("""
                configureIfNeeded() stopping before MobileAds.shared.start() — \
                consent does not yet allow ad requests
                """)
            #endif
            return
        }

        // Privacy-first request configuration — set before start() so it's in effect for every
        // request this session. GMA SDK 10.14.0+ (installed: 13.8.0); disabling this removes a
        // cross-app publisher identifier signal from ad requests. See this file's header.
        MobileAds.shared.requestConfiguration.setPublisherFirstPartyIDEnabled(false)

        // GADApplicationIdentifier is read from Info.plist by the SDK itself at start(); this
        // app doesn't need to read or pass it explicitly (see RevenueCatConfiguration.swift for
        // why RevenueCat's public key needs manual Info.plist plumbing — the Mobile Ads SDK's
        // App ID does not, Google's SDK looks it up from the bundle directly).
        //
        // start(completionHandler:) is used (rather than the SDK's newer async start()) since
        // its signature has been stable across many SDK majors and is what every current Google
        // quickstart documents — wrapped once here in withCheckedContinuation so the rest of
        // this file, and every future caller of configureIfNeeded(), stays plain async/await.
        //
        // TEMPORARY — logged immediately before MobileAds.shared.start() is called.
        #if !DEBUG
        admobDiagnosticsLogger.log("MobileAds.shared.start() about to be called")
        #endif
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<InitializationStatus, Never>) in
            MobileAds.shared.start { status in
                // TEMPORARY — logs the instant the SDK's own completion handler fires, before
                // this continuation resumes — the direct test for whether MobileAds.shared.start
                // ever calls back at all. os.Logger is documented Sendable/thread-safe, so this
                // is safe to call regardless of what thread the SDK invokes this closure on.
                #if !DEBUG
                admobDiagnosticsLogger.log("MobileAds.shared.start() completion handler fired")
                #endif
                continuation.resume(returning: status)
            }
        }

        lastInitializationStatus = status
        configurationState = .configured

        // Safe failure handling: a not-ready adapter never throws and never blocks anything —
        // it's captured here purely as a diagnostics string (Self.errorDescription is
        // unit-testable in isolation from the real SDK, same reasoning as
        // RevenueCatSubscriptionService's pure decision functions), read only by internal
        // tooling, never by a user-facing view or alert. adapterStatusesByClassName's real
        // AdapterStatus objects are reduced to plain [String: AdapterInitializationState] here,
        // at the one call site that has a real SDK status to reduce — everything downstream of
        // this line operates on plain values only.
        let adapterStates = status.adapterStatusesByClassName.mapValues(\.state)
        lastErrorDescription = Self.errorDescription(forAdapterStates: adapterStates)

        #if DEBUG || INTERNAL_BUILD
        print("[85Blends][AdMob] Configured. \(lastErrorDescription ?? "All adapters ready.")")
        #endif

        // TEMPORARY — see the diagnostics-logger declaration at the top of this file. Separate
        // from the pre-existing print() line directly above (that one is permanent, ordinary
        // debug logging predating this investigation — left untouched). Logs completion plus
        // any adapter-initialization errors, so a TestFlight capture shows definitively whether
        // AdMob's SDK finished configuring at all, and when, relative to the first ad request.
        #if !DEBUG
        if let lastErrorDescription {
            admobDiagnosticsLogger.error("""
                configureIfNeeded() completed with issues — \(lastErrorDescription, privacy: .public), \
                finalState=\(String(describing: self.configurationState), privacy: .public)
                """)
        } else {
            admobDiagnosticsLogger.log("""
                configureIfNeeded() completed — all adapters ready, \
                finalState=\(String(describing: self.configurationState), privacy: .public)
                """)
        }
        #endif
    }

    /// Gathers/records the user's UMP consent choice before any ad is ever requested. Follows
    /// Google's own documented integration pattern exactly: request a fresh consent status,
    /// present the required consent form if-and-only-if the SDK determines one is needed (a
    /// developer never decides this directly), then read back whether ads may now be requested.
    /// Never throws — a network failure, a missing presenting view controller, or any other
    /// error here is captured into `lastErrorDescription` and otherwise treated the same as
    /// "consent not yet available": no ad request happens this launch, nothing crashes or blocks
    /// any other feature, and the next cold launch tries again.
    private func gatherConsent() async {
        defer { isInitialConsentResolutionPending = false }

        let parameters = RequestParameters()

        // Debug-only geography override so EEA-specific consent UI can be exercised on a
        // non-EEA test device. #if DEBUG || INTERNAL_BUILD — never Release — matching every
        // other test-vs-production split in this file (NativePlacement.adUnitID above). Real
        // users, in Release, always resolve geography from their actual location/IP, never a
        // hardcoded value.
        #if DEBUG || INTERNAL_BUILD
        let debugSettings = DebugSettings()
        debugSettings.geography = .EEA
        parameters.debugSettings = debugSettings
        #endif

        let requestError = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { error in
                continuation.resume(returning: error)
            }
        }

        if let requestError {
            #if !DEBUG
            admobDiagnosticsLogger.error("""
                gatherConsent() requestConsentInfoUpdate failed — \
                \(requestError.localizedDescription, privacy: .public)
                """)
            #endif
            lastErrorDescription = "UMP consent request failed: \(requestError.localizedDescription)"
            consentAllowsAdRequests = ConsentInformation.shared.canRequestAds
            return
        }

        do {
            // Presents the consent form only if the SDK determines one is actually required for
            // this user (e.g. EEA/UK, or an applicable US state) — a no-op otherwise. Never
            // called speculatively; this is the one and only place 85Blends presents any
            // consent/privacy UI at launch.
            if let presentingViewController = Self.topMostPresentingViewController() {
                try await ConsentForm.loadAndPresentIfRequired(from: presentingViewController)
            }
        } catch {
            // A failure here (no form loaded, presentation error) still falls through to read
            // whatever canRequestAds already reflects below — never crashes, never blocks.
            #if !DEBUG
            admobDiagnosticsLogger.error("""
                gatherConsent() loadAndPresentIfRequired failed — \
                \(error.localizedDescription, privacy: .public)
                """)
            #endif
        }

        consentAllowsAdRequests = ConsentInformation.shared.canRequestAds
    }

    /// The topmost presented view controller in the key window's scene, used only to present the
    /// UMP consent form (and, from Preferences, the privacy-options form) — never for any other
    /// purpose. Returns `nil` (rather than force-unwrapping anything) if no window scene/window/
    /// root view controller is available yet; every caller treats `nil` as "skip presenting this
    /// time," never as an error to surface to the user.
    static func topMostPresentingViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        guard let windowScene = (scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)
            ?? scenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene
        else { return nil }

        guard let root = (windowScene.windows.first { $0.isKeyWindow }?.rootViewController)
            ?? windowScene.windows.first?.rootViewController
        else { return nil }

        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    /// Pure summary of any not-ready adapters, or `nil` if every reported adapter is ready.
    /// Extracted out of configureIfNeeded() so it's testable with plain enum values, without
    /// constructing a real SDK-provided InitializationStatus/AdapterStatus (mirrors
    /// RevenueCatSubscriptionService's own pattern of pulling business logic out into plain,
    /// unit-testable static functions — see SubscriptionManagerTests.swift for the precedent
    /// this follows).
    static func errorDescription(forAdapterStates states: [String: AdapterInitializationState]) -> String? {
        let notReady = states
            .filter { $0.value != .ready }
            .map(\.key)
            .sorted()
        guard notReady.isEmpty == false else { return nil }
        return "Adapter(s) not ready: \(notReady.joined(separator: ", "))"
    }

    // MARK: - Native ad placements (Phase 2)

    /// 85Blends' two approved native ad locations — see this file's header on why there are
    /// exactly two and why nothing else (an interstitial placement, an app-open placement) may
    /// be added here. Each case is where Components/NativeAdView.swift resolves the ad unit ID
    /// it requests; call sites (CalculatorView.swift, StationsView.swift) pass a case, never a
    /// raw ad unit ID string.
    enum NativePlacement {
        /// CalculatorView's bottom-of-scroll placement — 85Blends' default/first tab.
        case calculatorHome
        /// StationsView's inline placement, after the 3rd station card.
        case stations

        /// Google's public sample Native Advanced ad unit ID for iOS — documented by Google for
        /// exactly this purpose, identical in shape to `RevenueCatConfiguration`'s
        /// test-vs-production key split, and to Phase 1's GADApplicationIdentifier choice. Every
        /// placement uses this one ID; there is nothing placement-specific about a test ID.
        private static let testAdUnitID = "ca-app-pub-3940256099942544/3986624511"

        /// The real 85Blends AdMob Native Advanced ad unit ID for this placement, as configured
        /// in Julian's AdMob account. Requested only by the Release/App Store build — see
        /// `adUnitID` below.
        var productionAdUnitID: String {
            switch self {
            case .calculatorHome: return "ca-app-pub-2011940670640942/1588596562"
            case .stations: return "ca-app-pub-2011940670640942/3192437795"
            }
        }

        /// The ad unit ID this app actually requests. `#if DEBUG || INTERNAL_BUILD` — not plain
        /// `#if DEBUG` — because Google's AdMob policy prohibits a publisher's own
        /// devices/testers from generating impressions/clicks on real ad units: Debug (every
        /// local Xcode run) and Internal (TestFlight builds used only by Julian and internal
        /// testers, never distributed publicly) must both keep requesting Google's test ad,
        /// exactly like `SubscriptionManager.isPro`'s own `#if DEBUG || INTERNAL_BUILD` split and
        /// this file's own `configureIfNeeded()` log gate. Only the Release configuration (the
        /// actual public App Store archive — confirmed to carry zero active compilation
        /// conditions of its own) falls through to the real, placement-specific production ID.
        var adUnitID: String {
            #if DEBUG || INTERNAL_BUILD
            Self.testAdUnitID
            #else
            productionAdUnitID
            #endif
        }
    }
}

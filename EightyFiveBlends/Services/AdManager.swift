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
//  TEST CONFIGURATION ONLY: Info.plist's GADApplicationIdentifier is Google's public sample App
//  ID (`ca-app-pub-3940256099942544~1458002511`, from Phase 1), and `NativePlacement.adUnitID`
//  below always resolves to Google's public sample Native Advanced ad unit ID, never the real
//  85Blends ad unit IDs — see `NativePlacement` for why both real IDs are recorded but neither is
//  requested yet.
//
//  PRO AWARENESS (foundation only): `isAdsEnabled` below reads SubscriptionManager.shared
//  directly — the same single entitlement source every other Pro gate in this app reads (see
//  SubscriptionManager.swift's own header) — so future native-ad placement code has one
//  ready-made, already-correct gate to call. Nothing in this file requests, loads, or shows an ad
//  against that gate yet; it exists now so later work doesn't need to invent a second way to ask
//  "is this user Pro."
//

import Foundation
import Observation
import GoogleMobileAds
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
        /// in Julian's AdMob account. Recorded here now so going live is a one-line change to
        /// `adUnitID` below — but nothing in this app reads `productionAdUnitID` yet.
        var productionAdUnitID: String {
            switch self {
            case .calculatorHome: return "ca-app-pub-2011940670640942/1588596562"
            case .stations: return "ca-app-pub-2011940670640942/3192437795"
            }
        }

        /// The ad unit ID this app actually requests. Always `testAdUnitID` for now — Testing
        /// Requirements for this phase are explicit: test ads only, regardless of build
        /// configuration. Flipping this to `productionAdUnitID` (gated the same
        /// `#if INTERNAL_BUILD`/Release way RevenueCatConfiguration already splits its keys) is
        /// deliberately deferred to a later, explicit "go live" change — not bundled into this
        /// phase.
        var adUnitID: String { Self.testAdUnitID }
    }
}

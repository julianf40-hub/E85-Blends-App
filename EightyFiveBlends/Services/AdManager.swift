//
//  AdManager.swift
//  EightyFiveBlends
//
//  AdMob Phase 1 — foundation only. This file initializes the Google Mobile Ads SDK and tracks
//  that initialization's state. It deliberately does NOT load, preload, or present any ad —
//  no ad unit ID exists anywhere in this file. Native ad views embedded in existing scrolling
//  content are separate, later work; this is SDK bootstrap only, mirroring how
//  RevenueCatSubscriptionService.swift is scoped to "configure the SDK and expose its state,"
//  not to any one paywall screen.
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
//  TEST CONFIGURATION ONLY (Phase 1): Info.plist's GADApplicationIdentifier is Google's public
//  sample App ID (`ca-app-pub-3940256099942544~1458002511`), documented by Google for exactly
//  this purpose — SDK bring-up and testing before a real AdMob app is wired in. No production ad
//  unit ID appears anywhere in this app yet.
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
        guard configurationState == .notConfigured else { return }
        configurationState = .configuring

        // GADApplicationIdentifier is read from Info.plist by the SDK itself at start(); this
        // app doesn't need to read or pass it explicitly (see RevenueCatConfiguration.swift for
        // why RevenueCat's public key needs manual Info.plist plumbing — the Mobile Ads SDK's
        // App ID does not, Google's SDK looks it up from the bundle directly).
        //
        // start(completionHandler:) is used (rather than the SDK's newer async start()) since
        // its signature has been stable across many SDK majors and is what every current Google
        // quickstart documents — wrapped once here in withCheckedContinuation so the rest of
        // this file, and every future caller of configureIfNeeded(), stays plain async/await.
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<InitializationStatus, Never>) in
            MobileAds.shared.start { status in
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
}

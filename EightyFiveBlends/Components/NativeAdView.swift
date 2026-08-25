//
//  NativeAdView.swift
//  EightyFiveBlends
//
//  AdMob Phase 2 — the first user-facing ad surface in 85Blends: a single, reusable SwiftUI
//  component that loads and renders one Google Mobile Ads Native Advanced ad. Used at exactly
//  two places — CalculatorView's bottom-of-scroll and StationsView's inline placement — both
//  constructing this same component with a different AdManager.NativePlacement, never
//  duplicating ad-loading logic per screen.
//
//  NON-INTERRUPTIVE BY CONSTRUCTION: this is a plain SwiftUI View embedded directly into
//  existing scrolling content, exactly like any other card in Calculator/Stations. It never
//  presents anything (no sheet, no full-screen cover, no modal) — there is nothing to dismiss,
//  nothing that blocks scrolling or input, and no state that can pause a workflow. See
//  AdManager.swift's header for the standing "no interruptive advertising" product decision this
//  file exists under. This file must never grow an interstitial/full-screen/app-open code path.
//
//  STATE HANDLING:
//    - Not yet loaded (idle/loading): renders EmptyView() — no placeholder box at all, so there
//      is no "large empty placeholder" to explain away, and nothing to visually collapse later.
//      Content below this position in the scroll simply gains a card once the ad arrives, the
//      same as any other lazily-loaded content in this app (e.g. live station search results).
//    - Loaded: renders the styled native ad card via AppCard — this app's own existing generic
//      card component (Theme.swift) — so the ad's chrome (background, border, corner radius,
//      padding) is pixel-identical to every other card in 85Blends, not a hand-approximated copy.
//    - Failed (no internet, no fill, SDK unavailable, or any other error): renders EmptyView(),
//      silently — never an error message, never a broken-looking box. The app must never look
//      degraded because an ad didn't load.
//    - Pro: every real call site (CalculatorView.swift / StationsView.swift) checks
//      SubscriptionManager.shared.isProUser BEFORE constructing this view at all, so a Pro user
//      never causes this type to exist. The AdManager.shared.isAdsEnabled check inside .task
//      below is a second, defense-in-depth read of that exact same property (never a new
//      entitlement source — see AdManager.swift's header) — belt-and-suspenders against a future
//      call site that forgets to gate, not a new check.
//
//  ONE LOAD PER PLACEMENT: each NativeAdView instance owns its own NativeAdLoader (below) via
//  @State, created once for that instance's lifetime and guarded against a second concurrent or
//  repeated load — see NativeAdLoader.loadIfNeeded(). SwiftUI re-evaluating this view's parent's
//  body (e.g. a Calculator input changing, a new station arriving) does not recreate this @State
//  object or trigger a second request, exactly like every other @State-held reference type
//  elsewhere in this app (e.g. CalculatorView's own @State private var locationManager-adjacent
//  services).
//

import SwiftUI
import GoogleMobileAds
import os

// TEMPORARY — production/TestFlight diagnostics for the "native ads not appearing"
// investigation. Every use of this logger below is marked TEMPORARY and must be removed,
// alongside this declaration, once the root cause is confirmed and fixed — see the matching
// comment on AdManager.swift's own diagnostics logger.
//
// os.Logger, not print(): 85Blends is validated through TestFlight on the Release/production
// configuration (per this pass's own context) — print() output is not retrievable from a
// TestFlight-installed, non-debugger-attached process, while os.Logger's unified-logging
// entries are (via Console.app / `log collect` with the device connected). Every interpolated
// value below is explicitly marked `privacy: .public` — os.Logger redacts interpolated values
// as `<private>` by default in release-signed builds, and everything logged here (an enum
// case, a Bool, a short technical string) is non-sensitive, so redaction would defeat the
// entire point of this pass.
//
// Gated `#if !DEBUG` — true for both Internal and Release (neither defines the DEBUG
// compilation condition; only the Debug configuration does), so this covers both
// configurations actually used for TestFlight validation while staying silent in local Xcode
// Debug runs.
#if !DEBUG
private let admobDiagnosticsLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.e85blends.app.ios",
    category: "AdMobDiagnostics"
)
#endif

struct NativeAdView: View {
    let placement: AdManager.NativePlacement

    @State private var loader: NativeAdLoader

    init(placement: AdManager.NativePlacement) {
        self.placement = placement
        _loader = State(initialValue: NativeAdLoader(adUnitID: placement.adUnitID, diagnosticsPlacement: placement))
        // TEMPORARY — see the diagnostics-logger declaration above this type for the full
        // rationale. Remove this block once the root cause is confirmed and fixed.
        #if !DEBUG
        admobDiagnosticsLogger.log("""
            NativeAdView created — \
            placement=\(String(describing: placement), privacy: .public), \
            isProUser=\(SubscriptionManager.shared.isProUser, privacy: .public)
            """)
        #endif
    }

    var body: some View {
        // LIFECYCLE FIX: was `Group { if ... else { EmptyView() } }`. Group is a purely
        // structural, identity-less wrapper — it has no view presence of its own, so
        // Group{EmptyView()} (which is what this resolves to for every render before an ad has
        // loaded) gave .task below no stable, genuinely-mounted node to attach to. That's why
        // "NativeAdView .task started" never logged for either placement despite init running
        // normally — see the lifecycle audit this fix implements. ZStack is a real SwiftUI
        // primitive with its own independent presence regardless of whether its children
        // currently render anything, so .task now has something concrete to mount on from the
        // very first render. The explicit `else { EmptyView() }` branch is dropped — omitting
        // the else already means "nothing," and ZStack itself supplies the presence .task
        // needs; behavior otherwise unchanged (idle/loading/failed all still render nothing
        // visible — see this file's header).
        ZStack {
            if let nativeAd = loader.nativeAd {
                NativeAdCard(nativeAd: nativeAd)
            }
        }
        .task {
            // TEMPORARY — logs the instant this .task actually starts running (as opposed to
            // NativeAdView merely being constructed — see init's own TEMPORARY log above,
            // which fires unconditionally on construction and does NOT prove .task ever runs).
            // Remove alongside every other TEMPORARY block in this file.
            #if !DEBUG
            admobDiagnosticsLogger.log("""
                NativeAdView .task started — \
                placement=\(String(describing: placement), privacy: .public)
                """)
            #endif

            // Defense-in-depth Pro check — see this file's header. Every real call site already
            // gates on SubscriptionManager.shared.isProUser before constructing this view at
            // all, so this is a second, cheap read of the exact same property, never a new
            // entitlement decision.
            guard AdManager.shared.isAdsEnabled else { return }

            // TEMPORARY — immediately before calling loadIfNeeded().
            #if !DEBUG
            admobDiagnosticsLogger.log("""
                NativeAdView .task calling loadIfNeeded() — \
                placement=\(String(describing: placement), privacy: .public), \
                loaderState=\(loader.diagnosticsStateDescription, privacy: .public)
                """)
            #endif

            loader.loadIfNeeded()

            // TEMPORARY — immediately after loadIfNeeded() returns. loadIfNeeded() itself is
            // synchronous (it only kicks off the SDK's callback-based load and returns; there is
            // no async work inside it to await — see NativeAdLoader.loadIfNeeded()), so this
            // confirms control actually returned to .task, not that the network load finished.
            #if !DEBUG
            admobDiagnosticsLogger.log("""
                NativeAdView .task loadIfNeeded() returned — \
                placement=\(String(describing: placement), privacy: .public), \
                loaderState=\(loader.diagnosticsStateDescription, privacy: .public)
                """)
            #endif
        }
    }
}

// MARK: - Loading

/// Owns exactly one Google Mobile Ads native ad request for one placement instance. Not
/// app-wide — each NativeAdView gets its own, via @State, so Calculator's and Stations'
/// placements never share or race on a single load, and each fails or succeeds independently.
@MainActor
@Observable
final class NativeAdLoader: NSObject {
    private(set) var nativeAd: NativeAd?

    private enum LoadState: Equatable { case idle, loading, loaded, failed }
    private var state: LoadState = .idle
    private let adUnitID: String
    // TEMPORARY — diagnostics only, carried alongside adUnitID purely so load-start/success/
    // failure logging below can report which placement they belong to. Remove this property
    // and the `diagnosticsPlacement:` init parameter together with every other TEMPORARY block
    // in this file once the root cause is confirmed and fixed.
    private let diagnosticsPlacement: AdManager.NativePlacement
    private var adLoader: AdLoader?

    // TEMPORARY — diagnostics only, exposes the private LoadState as a plain string so
    // NativeAdView's .task can log "loader current state" without exposing LoadState itself.
    // Remove alongside every other TEMPORARY block in this file.
    #if !DEBUG
    var diagnosticsStateDescription: String { String(describing: state) }
    #endif

    init(adUnitID: String, diagnosticsPlacement: AdManager.NativePlacement) {
        self.adUnitID = adUnitID
        self.diagnosticsPlacement = diagnosticsPlacement
        super.init()
    }

    /// Idempotent — a second call while already loading, loaded, or failed is a no-op, so
    /// nothing in this app can trigger more than one simultaneous or repeated request per
    /// placement instance (Performance Requirements: "one ad request per placement").
    func loadIfNeeded() {
        // TEMPORARY — the very first line of this function, logged unconditionally before the
        // idle-state guard below, so a TestFlight capture proves whether loadIfNeeded() is
        // reached at all, regardless of what the guard below then does with it.
        #if !DEBUG
        admobDiagnosticsLogger.log("""
            loadIfNeeded() entered — \
            placement=\(String(describing: self.diagnosticsPlacement), privacy: .public), \
            state=\(String(describing: self.state), privacy: .public), \
            adMobConfigured=\(AdManager.shared.isConfigured, privacy: .public)
            """)
        #endif

        guard state == .idle else {
            // TEMPORARY — explains exactly why the request was skipped.
            #if !DEBUG
            admobDiagnosticsLogger.log("""
                loadIfNeeded() skipped — state is not idle \
                (\(String(describing: self.state), privacy: .public)), \
                placement=\(String(describing: self.diagnosticsPlacement), privacy: .public)
                """)
            #endif
            return
        }
        state = .loading

        // rootViewController is nil: native ads render inline (no full-screen presentation is
        // ever performed), so no view controller reference is needed to request or display one
        // — consistent with this file's non-interruptive, embedded-only design.
        let loader = AdLoader(
            adUnitID: adUnitID,
            rootViewController: nil,
            adTypes: [.native],
            options: nil
        )
        loader.delegate = self
        adLoader = loader
        // TEMPORARY — see the diagnostics-logger declaration near the top of this file. Logged
        // right before AdLoader.load(), including whether AdMob's SDK init has actually
        // completed yet (AdManager.shared.isConfigured) — this is the direct test for the
        // suspected SDK-init race: if this ever logs `adMobConfigured=false`, the ad request is
        // firing before MobileAds.shared.start(completionHandler:) has completed.
        #if !DEBUG
        admobDiagnosticsLogger.log("""
            AdLoader.load() starting — \
            placement=\(String(describing: self.diagnosticsPlacement), privacy: .public), \
            adUnitID=\(self.adUnitID, privacy: .public), \
            adMobConfigured=\(AdManager.shared.isConfigured, privacy: .public)
            """)
        #endif
        loader.load(Request())
    }
}

extension NativeAdLoader: NativeAdLoaderDelegate {
    nonisolated func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.nativeAd = nativeAd
            self.state = .loaded
            // TEMPORARY — see the diagnostics-logger declaration near the top of this file.
            // Logged here, inside the @MainActor hop, so it can safely read
            // self.diagnosticsPlacement (this delegate callback itself is nonisolated, since
            // Google's SDK may invoke it off the main thread).
            #if !DEBUG
            admobDiagnosticsLogger.log("""
                Native ad received — \
                placement=\(String(describing: self.diagnosticsPlacement), privacy: .public), \
                headline=\(nativeAd.headline ?? "nil", privacy: .public)
                """)
            #endif
        }
    }

    // Fail silently to the USER, always — no internet, SDK unavailable, and no-fill all land
    // here and are handled identically as far as the UI is concerned: state flips to .failed,
    // NativeAdView renders EmptyView(), and nothing is ever shown to the user. See this file's
    // header. The console-only diagnostic below is not user-facing and does not change that
    // contract — it exists purely so TestFlight testing can distinguish *why* a load failed
    // without adding any UI.
    nonisolated func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .failed
            // TEMPORARY — see the diagnostics-logger declaration near the top of this file.
            #if !DEBUG
            let nsError = error as NSError
            admobDiagnosticsLogger.error("""
                Native ad failed — \
                placement=\(String(describing: self.diagnosticsPlacement), privacy: .public), \
                domain=\(nsError.domain, privacy: .public), \
                code=\(nsError.code, privacy: .public), \
                message=\(nsError.localizedDescription, privacy: .public)
                """)
            #endif
        }
    }
}

// MARK: - Rendering

/// The actual ad card. Wrapped in AppCard (Theme.swift) — 85Blends' own existing generic card
/// component — so background, border, corner radius, and padding are identical to every other
/// card in the app, never a hand-approximated copy of that styling.
private struct NativeAdCard: View {
    let nativeAd: NativeAd

    var body: some View {
        AppCard {
            NativeAdContainer(nativeAd: nativeAd)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    // Accessibility requirement: the ad must be clearly identified as an advertisement, not
    // read as if it were 85Blends' own content.
    private var accessibilityLabel: String {
        var label = "Advertisement"
        if let headline = nativeAd.headline, headline.isEmpty == false {
            label += ": \(headline)"
        }
        return label
    }

    private var accessibilityHint: String {
        if let advertiser = nativeAd.advertiser, advertiser.isEmpty == false {
            return "Sponsored content from \(advertiser)."
        }
        return "Sponsored content."
    }
}

/// UIKit bridge: Google Mobile Ads' click and impression tracking is wired through
/// `GoogleMobileAds.NativeAdView` (a UIKit `UIView`) and its registered asset subviews — there is
/// no pure-SwiftUI native ad renderer, so this wraps that container exactly as Google's own
/// documented SwiftUI native-ads integration does. `GoogleMobileAds.NativeAdView` is fully
/// module-qualified everywhere it's used in this type to disambiguate it from this file's own
/// `NativeAdView` (the public SwiftUI component above) — same type name, different module,
/// deliberately distinct types.
private struct NativeAdContainer: UIViewRepresentable {
    let nativeAd: NativeAd

    // FIX (validation audit): SwiftUI calls updateUIView on most re-renders of the surrounding
    // hierarchy (a Calculator input changing, a Stations search updating) — not only when this
    // ad's own content changes. Without tracking what was last populated, every one of those
    // redraws re-wrote every asset view's text/image and reassigned `.nativeAd`, even though the
    // ad itself never changed. The Coordinator persists across updateUIView calls (unlike a
    // local var in this struct, which is a fresh value every re-render), so it's the correct
    // place to remember "this exact NativeAd instance is already displayed."
    final class Coordinator {
        var lastPopulatedNativeAd: NativeAd?

        // FIX (validator: "Advertiser assets outside native ad view" — 862pt over-wide adView
        // observed on real device; see sizeThatFits(_:uiView:context:) for the full width-audit
        // rationale). sizeThatFits needs to reuse the SAME width constraint across every call —
        // but an INACTIVE NSLayoutConstraint isn't discoverable via uiView.constraints (that
        // collection only ever contains currently-active constraints), and sizeThatFits
        // deliberately deactivates this one when SwiftUI proposes no concrete width (see below),
        // so a uiView.constraints lookup would silently lose track of it the moment that
        // happens. The Coordinator already persists across this representable's calls for
        // exactly this kind of per-instance state (see lastPopulatedNativeAd above), so it holds
        // the constraint directly instead.
        var widthConstraint: NSLayoutConstraint?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> GoogleMobileAds.NativeAdView {
        let adView = buildNativeAdView()
        context.coordinator.widthConstraint = adView.widthAnchor.constraint(equalToConstant: 0)
        return adView
    }

    // LIFECYCLE FIX (final validator investigation — "Advertiser assets outside native ad
    // view"): real-device evidence proved SwiftUI calls updateUIView BEFORE it ever calls
    // sizeThatFits(_:uiView:context:) on a freshly-appeared representable — at that first
    // updateUIView call, Coordinator.widthConstraint has never been activated (it's created
    // inactive in makeUIView, and the ONLY code that activates it lives in sizeThatFits'
    // bounded-width branch below), so adView has no width constraint governing it at all. The
    // OLD code called populate(_:with:) — and therefore adView.nativeAd = nativeAd, which is
    // what activates Google's own internal click/impression/geometry tracking for the ad —
    // unconditionally on that first call, meaning `.nativeAd` was always assigned while adView
    // was still in its transient, content-driven ~862pt-wide state (confirmed by device logs:
    // uiView.bounds=(0,0,862,252.67) at populate time, vs. sizeThatFits's proposal.width=372
    // arriving only afterward). If Google's SDK captures/acts on the view's CURRENT geometry at
    // the moment .nativeAd is assigned (plausible for AdChoices overlay placement or impression/
    // viewability setup), it would capture that wrong, oversized geometry — a strong candidate
    // for why this one validator warning persisted after every code-visible frame was already
    // confirmed correct by the time SwiftUI finished laying out.
    //
    // FIX: population is now gated on Coordinator.widthConstraint?.isActive == true — i.e. on
    // sizeThatFits having ALREADY established a real, SwiftUI-proposed, bounded width for this
    // exact uiView. On the (real-device-confirmed) ordering where updateUIView runs first, this
    // defers here; sizeThatFits's own bounded branch below performs the deferred population
    // once it activates the width constraint (see its own comment for why that handoff is
    // async, not inline). On any LATER updateUIView call — once bounded width already exists —
    // this populates directly, synchronously, exactly as before. Either path funnels through
    // populateIfNeeded(_:context:), whose own lastPopulatedNativeAd guard (unchanged from the
    // previous single-call-site version) makes population idempotent regardless of which path
    // actually triggers it — "populate exactly once per NativeAd instance" holds either way.
    // Ad LOADING is entirely unaffected: NativeAdLoader already finished fetching this exact
    // NativeAd well before NativeAdContainer is ever constructed (see NativeAdView.body's
    // `if let nativeAd = loader.nativeAd` gate) — deferring population defers nothing about the
    // network request, never triggers a second one, and never touches NativeAdLoader/AdLoader.
    func updateUIView(_ uiView: GoogleMobileAds.NativeAdView, context: Context) {
        // Cheap early exit for the common case (already populated, SwiftUI re-rendering the
        // surrounding hierarchy for an unrelated reason) — avoids touching the Coordinator's
        // widthConstraint or calling populateIfNeeded at all once there's nothing left to do.
        // populateIfNeeded's OWN identical guard (below) is still the source of truth — this is
        // purely a hot-path optimization, not a second, independent correctness mechanism.
        guard context.coordinator.lastPopulatedNativeAd !== nativeAd else { return }

        guard context.coordinator.widthConstraint?.isActive == true else {
            // DEFERRED — see this function's header comment. sizeThatFits(_:uiView:context:)
            // will perform the deferred population once it establishes a real bounded width.
            #if !DEBUG
            admobDiagnosticsLogger.log("""
                updateUIView deferring populate() — bounded width not yet established \
                (uiView.bounds=\(String(describing: uiView.bounds), privacy: .public))
                """)
            #endif
            return
        }

        populateIfNeeded(uiView, context: context)
    }

    // Shared by updateUIView (once bounded width already exists) and sizeThatFits's deferred
    // handoff (the moment bounded width is first established) — see updateUIView's header
    // comment for the full lifecycle rationale. Safe to call from either place any number of
    // times: the lastPopulatedNativeAd guard makes real population (and everything logged
    // below it) happen at most once per NativeAd instance, regardless of caller.
    private func populateIfNeeded(_ uiView: GoogleMobileAds.NativeAdView, context: Context) {
        // Only repopulate when the underlying NativeAd instance actually changed. Reference
        // identity (===/!==) is the right comparison here — NativeAd is a reference type, and
        // NativeAdLoader only ever produces one instance per placement's displayed lifetime (see
        // NativeAdLoader.loadIfNeeded()'s idle/loading/loaded/failed guard), so this reduces to
        // "populate exactly once," not a per-property diff.
        guard context.coordinator.lastPopulatedNativeAd !== nativeAd else { return }
        populate(uiView, with: nativeAd)
        context.coordinator.lastPopulatedNativeAd = nativeAd

        // TEMPORARY — asset frame diagnostics for the "Advertiser assets outside native ad
        // view" validator investigation. Originally moved here from buildNativeAdView() (see
        // git history) so uiView would have a real, resolved frame to log against. Now that
        // this whole function only ever runs once Coordinator.widthConstraint is confirmed
        // active (see updateUIView/sizeThatFits), that frame is the real, SwiftUI-bounded one
        // (~372pt) rather than the transient, unbounded one (~862pt) it could previously be —
        // see the LIFECYCLE FIX comment on updateUIView for the full investigation. See the
        // diagnostics-logger declaration near the top of this file for the os.Logger/privacy
        // rationale. Remove alongside every other TEMPORARY block in this file.
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()

        #if !DEBUG
        let assetViews: [(name: String, view: UIView?)] = [
            ("headlineView", uiView.headlineView),
            ("bodyView", uiView.bodyView),
            ("iconView", uiView.iconView),
            ("mediaView", uiView.mediaView),
            ("advertiserView", uiView.advertiserView),
            ("callToActionView", uiView.callToActionView),
        ]
        // Extended for the width-audit investigation: uiView.frame (its position/size in its
        // superview's coordinate space — where uiView.bounds is only its own local size) and,
        // when uiView is actually in a window, that same frame converted into the window's
        // coordinate space — the closest available approximation of "real screen-space size,"
        // to compare directly against the ~340-430pt a real device's screen can actually offer.
        let frameInWindowDescription: String
        if let window = uiView.window {
            let frameInWindow = uiView.convert(uiView.bounds, to: window)
            frameInWindowDescription = String(describing: frameInWindow)
        } else {
            frameInWindowDescription = "no window"
        }
        admobDiagnosticsLogger.log("""
            Native ad asset frames (updateUIView, post-populate) — \
            uiView.bounds=\(String(describing: uiView.bounds), privacy: .public), \
            uiView.frame=\(String(describing: uiView.frame), privacy: .public), \
            uiView.frameInWindow=\(frameInWindowDescription, privacy: .public)
            """)
        for (name, assetView) in assetViews {
            guard let assetView else {
                admobDiagnosticsLogger.log("""
                    Native ad asset frame (updateUIView, post-populate) — \
                    \(name, privacy: .public)=not registered
                    """)
                continue
            }
            let frameInAdView = assetView.convert(assetView.bounds, to: uiView)
            admobDiagnosticsLogger.log("""
                Native ad asset frame (updateUIView, post-populate) — \
                \(name, privacy: .public)=\(String(describing: frameInAdView), privacy: .public)
                """)
        }
        #endif

        // TEMPORARY — deeper diagnostics for the same "Advertiser assets outside native ad
        // view" validator investigation. The per-asset frame log above shows every REGISTERED
        // asset view's own frame inside uiView's bounds, yet Ad Inspector still reports an
        // asset outside the native ad view — which points at something the per-asset log
        // can't see: content Google's SDK composes *inside* one of those registered views,
        // on a subview this code never registered or sized itself. mediaView is the prime
        // suspect (Google privately manages the real media creative as mediaView's own
        // subview(s)), so this recursively dumps mediaView's entire UIView subtree — class,
        // frame (converted into uiView's coordinate space, same basis as the log above),
        // bounds, clipsToBounds, and hidden state for every descendant — plus
        // intrinsicContentSize for headlineView/advertiserView, since a label's laid-out frame
        // can be correct while its intrinsic content still exceeds it. Reuses the
        // setNeedsLayout()/layoutIfNeeded() already forced above; no second layout pass.
        // Remove alongside every other TEMPORARY block in this file.
        #if !DEBUG
        admobDiagnosticsLogger.log("""
            mediaView.clipsToBounds (updateUIView, post-populate) — \
            \(uiView.mediaView != nil ? String(describing: uiView.mediaView!.clipsToBounds) : "mediaView not registered", privacy: .public)
            """)

        func dumpMediaViewSubtree(_ view: UIView, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            let frameInAdView = view.convert(view.bounds, to: uiView)
            admobDiagnosticsLogger.log("""
                mediaView subtree (updateUIView, post-populate) — \
                \(indent, privacy: .public)class=\(String(describing: type(of: view)), privacy: .public), \
                frame=\(String(describing: frameInAdView), privacy: .public), \
                bounds=\(String(describing: view.bounds), privacy: .public), \
                clipsToBounds=\(view.clipsToBounds, privacy: .public), \
                hidden=\(view.isHidden, privacy: .public)
                """)
            for subview in view.subviews {
                dumpMediaViewSubtree(subview, depth: depth + 1)
            }
        }

        if let mediaView = uiView.mediaView {
            dumpMediaViewSubtree(mediaView, depth: 0)
        } else {
            admobDiagnosticsLogger.log("mediaView subtree (updateUIView, post-populate) — mediaView not registered")
        }

        // TEMPORARY — optional-asset visibility diagnostics for the "Advertiser assets
        // outside native ad view" validator investigation (per-asset audit, this pass).
        // Google's documented pattern hides each of these four OPTIONAL assets exactly when
        // its underlying NativeAd value is nil (confirmed already followed in
        // populate(_:with:) — headline/media are guaranteed assets and are never hidden, so
        // they're excluded here). This logs, per asset, whether that's exactly what
        // happened: whether the source value was nil, the resulting view.isHidden, its frame
        // (converted into uiView's coordinate space), and its intrinsicContentSize. A
        // VISIBLE asset with nil content, or nativeValueNil not matching isHidden, would be
        // a real bug this can catch; a HIDDEN asset with a zero-height/zero-size frame (e.g.
        // an empty advertiserLabel when nativeAd.advertiser is nil) is the expected, correct
        // result of a hidden UILabel with no text collapsing inside its UIStackView — not a
        // bug. Replaces the old advertiserView-only block above (see git history). Remove
        // alongside every other TEMPORARY block in this file.
        func logOptionalAssetDiagnostics(name: String, view: UIView?, nativeValueIsNil: Bool) {
            guard let view else {
                admobDiagnosticsLogger.log("""
                    \(name, privacy: .public) asset (updateUIView, post-populate) — not registered
                    """)
                return
            }
            let frameInAdView = view.convert(view.bounds, to: uiView)
            admobDiagnosticsLogger.log("""
                \(name, privacy: .public) asset (updateUIView, post-populate):
                nativeValueNil=\(nativeValueIsNil, privacy: .public)
                isHidden=\(view.isHidden, privacy: .public)
                frame=\(String(describing: frameInAdView), privacy: .public)
                intrinsicContentSize=\(String(describing: view.intrinsicContentSize), privacy: .public)
                """)
        }

        logOptionalAssetDiagnostics(name: "body", view: uiView.bodyView, nativeValueIsNil: nativeAd.body == nil)
        logOptionalAssetDiagnostics(name: "icon", view: uiView.iconView, nativeValueIsNil: nativeAd.icon == nil)
        logOptionalAssetDiagnostics(name: "advertiser", view: uiView.advertiserView, nativeValueIsNil: nativeAd.advertiser == nil)
        logOptionalAssetDiagnostics(name: "callToAction", view: uiView.callToActionView, nativeValueIsNil: nativeAd.callToAction == nil)

        if let headlineView = uiView.headlineView {
            let frameInAdView = headlineView.convert(headlineView.bounds, to: uiView)
            admobDiagnosticsLogger.log("""
                headlineView (updateUIView, post-populate) — \
                frame=\(String(describing: frameInAdView), privacy: .public), \
                intrinsicContentSize=\(String(describing: headlineView.intrinsicContentSize), privacy: .public)
                """)
        } else {
            admobDiagnosticsLogger.log("headlineView (updateUIView, post-populate) — not registered")
        }

        // TEMPORARY — final-layout diagnostics (lifecycle-ordering pass). This function only
        // ever runs once Coordinator.widthConstraint is confirmed active, so every field below
        // reflects the view's REAL, SwiftUI-bounded geometry — direct proof (on the next
        // TestFlight run) that the root view is ~372pt wide here, never the transient ~862pt
        // this investigation started from. Remove alongside every other TEMPORARY block in
        // this file.
        let widthConstraintDescription: String
        if let widthConstraint = context.coordinator.widthConstraint {
            widthConstraintDescription = """
                active=\(widthConstraint.isActive), constant=\(widthConstraint.constant)
                """
        } else {
            widthConstraintDescription = "nil"
        }
        let superviewDescription: String
        if let superview = uiView.superview {
            superviewDescription = "bounds=\(superview.bounds), frame=\(superview.frame)"
        } else {
            superviewDescription = "no superview"
        }
        let finalFrameInWindowDescription: String
        if let window = uiView.window {
            finalFrameInWindowDescription = String(describing: uiView.convert(uiView.bounds, to: window))
        } else {
            finalFrameInWindowDescription = "no window"
        }
        admobDiagnosticsLogger.log("""
            Final-layout diagnostics (post-bounded-width) — \
            uiView.bounds=\(String(describing: uiView.bounds), privacy: .public), \
            uiView.frame=\(String(describing: uiView.frame), privacy: .public) \
            (final rounded root height == frame.height, see sizeThatFits's ceil()), \
            superview=\(superviewDescription, privacy: .public), \
            frameInWindow=\(finalFrameInWindowDescription, privacy: .public), \
            widthConstraint=\(widthConstraintDescription, privacy: .public)
            """)

        let finalAssetViews: [(name: String, view: UIView?)] = [
            ("headline", uiView.headlineView),
            ("body", uiView.bodyView),
            ("icon", uiView.iconView),
            ("media", uiView.mediaView),
            ("advertiser", uiView.advertiserView),
            ("callToAction", uiView.callToActionView),
        ]
        for (name, assetView) in finalAssetViews {
            guard let assetView else {
                admobDiagnosticsLogger.log("""
                    Final-layout asset (post-bounded-width) — \
                    \(name, privacy: .public): not registered
                    """)
                continue
            }
            let frameInAdView = assetView.convert(assetView.bounds, to: uiView)
            let containedInBounds = uiView.bounds.contains(frameInAdView)
            admobDiagnosticsLogger.log("""
                Final-layout asset (post-bounded-width) — \(name, privacy: .public): \
                minX=\(frameInAdView.minX, privacy: .public), \
                minY=\(frameInAdView.minY, privacy: .public), \
                maxX=\(frameInAdView.maxX, privacy: .public), \
                maxY=\(frameInAdView.maxY, privacy: .public), \
                containedInBounds=\(containedInBounds, privacy: .public)
                """)
        }
        #endif
    }

    // FIX (AdMob validator: "Advertiser assets outside native ad view" — 862pt over-wide adView
    // observed on real device via the post-populate diagnostics; see NativeAdView.swift's width
    // audit in git history for the full investigation):
    //
    // adView (built in buildNativeAdView() below) never had an explicit width of its own — only
    // stack's edges were pinned to it, so adView's width had to come from somewhere else. The
    // PREVIOUS version of this method tried to supply that width purely via
    // systemLayoutSizeFitting's *fitting priority* — a soft, temporary negotiation parameter,
    // not a real constraint. That negotiation can lose to OTHER required-priority constraints
    // already inside this view's subtree: at the time this bug was diagnosed, callToActionButton
    // had *required* horizontal compression resistance (see buildNativeAdView() below), and once
    // its intrinsic content width (CTA title plus its horizontal content insets) exceeded the
    // proposed width, Auto Layout let that required content constraint win instead of the
    // proposed width — producing an adView far wider than the actual card (862pt on a real
    // device, regardless of the ~340-430pt the card actually had to give it). Every downstream
    // asset frame reported by the diagnostics scaled off that same inflated width.
    //
    // FIX: give adView a REAL, required-priority width constraint (held on the Coordinator —
    // see its own comment for why) that this method updates to SwiftUI's actual proposed width
    // on every call, instead of relying solely on fitting-priority negotiation. A real
    // constraint wins deterministically against any other required-priority constraint in the
    // subtree — content can no longer force adView wider than what SwiftUI proposed; a genuine
    // conflict now surfaces as an Auto Layout console warning, never as an inflated returned
    // frame. Height is still derived entirely from the ad's real content via
    // systemLayoutSizeFitting's low vertical fitting priority, exactly as before — only the
    // width mechanism changed.
    //
    // HARDENING (compliance pass, after this fix): callToActionButton's compression resistance
    // was subsequently downgraded from .required to .defaultHigh specifically because THIS
    // constraint is now required — leaving the CTA at .required too would have created a
    // required-vs-required conflict for a long CTA string, which Auto Layout resolves by
    // breaking one of them (a console warning) rather than a clean truncation. See
    // buildNativeAdView() below for the current CTA priority and why.
    //
    // Never hardcodes a device width and never reads UIScreen.main.bounds — the width always
    // comes from whatever SwiftUI actually proposes, so this keeps working across iPhone sizes,
    // rotation, and Dynamic Type without any device-specific branching.
    //
    // LIFECYCLE FIX (final validator investigation): the bounded branch below is also the
    // ONLY place Coordinator.widthConstraint ever gets activated — which makes it the ONLY
    // place that can correctly know "a real bounded width now exists," and therefore the
    // right place to perform any population updateUIView deferred (see updateUIView's own
    // header comment for the full ordering rationale). Deliberately NOT done inline/
    // synchronously here: sizeThatFits runs during SwiftUI's live layout/measurement pass, and
    // mutating adView's content synchronously mid-measurement (labels' text, .nativeAd) is not
    // something UIKit/SwiftUI's layout machinery is guaranteed to tolerate cleanly. Instead,
    // this hands off to DispatchQueue.main.async — a clean, standard "run on the next main-
    // thread run-loop turn, after this measurement call has already returned" — so
    // populateIfNeeded's real UIKit mutations never happen from inside a sizeThatFits call
    // frame. The only mutation sizeThatFits performs directly, unchanged from before this fix,
    // is the widthConstraint's own constant/isActive — pure Auto Layout constraint bookkeeping,
    // not ad content.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: GoogleMobileAds.NativeAdView,
        context: Context
    ) -> CGSize? {
        let widthConstraint = context.coordinator.widthConstraint

        guard let proposedWidth = proposal.width, proposedWidth.isFinite, proposedWidth > 0 else {
            // No concrete proposal — SwiftUI is asking for an "ideal"/natural size (some internal
            // measurement passes propose nil, per ProposedViewSize's own documented semantics,
            // independent of the final resolved layout width). Deactivate the hard width
            // constraint so it can't hold over a stale value from a previous call, and ask for
            // adView's genuinely smallest valid size instead — layoutFittingCompressedSize paired
            // with .fittingSizeLevel (not .required) priority on the same axis, matching its
            // documented pairing, so this branch can never itself inflate the width. No bounded
            // width exists in this branch, so population is never triggered from here either —
            // see updateUIView's header comment.
            widthConstraint?.isActive = false
            let targetFittingSize = UIView.layoutFittingCompressedSize
            let fittingResult = uiView.systemLayoutSizeFitting(
                targetFittingSize,
                withHorizontalFittingPriority: .fittingSizeLevel,
                verticalFittingPriority: .fittingSizeLevel
            )
            // PHASE 3 (fractional-height hardening): round up to the nearest whole point in
            // this fallback path too, for the same reason as the bounded branch below — see
            // its own comment for the full rationale. Width is left as fittingResult reports
            // it (this branch never asserts an exact SwiftUI-proposed width the way the
            // bounded branch does).
            let finalHeight = ceil(fittingResult.height)
            let fallbackSize = CGSize(width: fittingResult.width, height: finalHeight)

            // TEMPORARY — width diagnostics for the same investigation. Remove alongside every
            // other TEMPORARY block in this file.
            #if !DEBUG
            admobDiagnosticsLogger.log("""
                sizeThatFits (no bounded proposal.width) — \
                proposal.width=\(String(describing: proposal.width), privacy: .public), \
                proposal.height=\(String(describing: proposal.height), privacy: .public), \
                targetFittingSize=\(String(describing: targetFittingSize), privacy: .public), \
                fittingResult=\(String(describing: fittingResult), privacy: .public), \
                finalHeight=\(finalHeight, privacy: .public), \
                returned=\(String(describing: fallbackSize), privacy: .public)
                """)
            #endif

            return fallbackSize
        }

        widthConstraint?.constant = proposedWidth
        widthConstraint?.isActive = true

        let targetFittingSize = UIView.layoutFittingCompressedSize
        let fittingResult = uiView.systemLayoutSizeFitting(
            targetFittingSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        // PHASE 3 (fractional-height hardening): the un-rounded fitted height (e.g. observed
        // 252.666...pt on a real device) can land a registered asset's bottom edge exactly on
        // that same fractional root boundary (observed: CTA bottom 214.666...+38 ==
        // 252.666...) — a knife-edge that pixel/point rounding elsewhere in the rendering
        // pipeline could tip either side of. Rounding the FITTED height up to the next whole
        // point gives every asset a small amount of guaranteed containment slack against the
        // root boundary, without hardcoding any fixed card height and without changing
        // anything content-driven about the height itself — it is still entirely derived from
        // systemLayoutSizeFitting above, just ceil()'d before being returned.
        let finalHeight = ceil(fittingResult.height)
        // Width is guaranteed == proposedWidth by the required-priority constraint activated
        // just above — returned explicitly rather than trusting fittingResult's own width, so a
        // genuine content conflict (which would show up as an Auto Layout console warning) can
        // never inflate the size this reports back to SwiftUI.
        let returnedSize = CGSize(width: proposedWidth, height: finalHeight)

        // TEMPORARY — width diagnostics for the same investigation. Remove alongside every other
        // TEMPORARY block in this file.
        #if !DEBUG
        admobDiagnosticsLogger.log("""
            sizeThatFits (bounded) — \
            proposal.width=\(String(describing: proposal.width), privacy: .public), \
            proposal.height=\(String(describing: proposal.height), privacy: .public), \
            targetFittingSize=\(String(describing: targetFittingSize), privacy: .public), \
            fittingResult=\(String(describing: fittingResult), privacy: .public), \
            finalHeight=\(finalHeight, privacy: .public), \
            returned=\(String(describing: returnedSize), privacy: .public)
            """)
        #endif

        // LIFECYCLE FIX — deferred population handoff (see this function's header comment).
        // Only schedules the hop when population is still actually pending, so repeated
        // sizeThatFits calls after the ad is already populated (SwiftUI re-measuring for an
        // unrelated reason) never schedule a redundant no-op closure.
        if context.coordinator.lastPopulatedNativeAd !== nativeAd {
            DispatchQueue.main.async { [weak uiView] in
                guard let uiView else { return }
                self.populateIfNeeded(uiView, context: context)
            }
        }

        return returnedSize
    }

    private func buildNativeAdView() -> GoogleMobileAds.NativeAdView {
        let adView = GoogleMobileAds.NativeAdView()
        adView.backgroundColor = .clear
        adView.translatesAutoresizingMaskIntoConstraints = false
        // Note: adView's real width constraint (FIX for the 862pt-over-wide-adView validator
        // issue — see sizeThatFits(_:uiView:context:)) is created in makeUIView(context:), not
        // here — it's stored on the Coordinator, which this function has no access to, so
        // makeUIView creates it right after this function returns adView.

        // "Sponsored" badge — kept visually distinct and always present, per this app's
        // requirement that ad content never be mistaken for native 85Blends content.
        let sponsoredLabel = UILabel()
        sponsoredLabel.text = "SPONSORED"
        sponsoredLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        sponsoredLabel.textColor = UIColor(AppTheme.Colors.stationYellow)
        // POLICY (separate ad-attribution audit, this pass): Google's Native Ads Policy
        // requires the attribution label ("Ad"/"Advertisement"/"Sponsored") to be at least
        // 15pt in both height and width. Width is not a concern — "SPONSORED" at 10pt heavy
        // is comfortably over 15pt wide — but this label's own 10pt system font has a line
        // height of roughly 12-14pt, under that floor. Smallest possible fix: a minimum-
        // height constraint only, not a font/text/color change — text stays visually
        // centered within the (very slightly) taller box, and the label otherwise looks the
        // same.
        sponsoredLabel.translatesAutoresizingMaskIntoConstraints = false
        sponsoredLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 15).isActive = true

        let headlineLabel = UILabel()
        headlineLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        headlineLabel.textColor = UIColor(AppTheme.Colors.textPrimary)
        headlineLabel.numberOfLines = 2

        let advertiserLabel = UILabel()
        advertiserLabel.font = .systemFont(ofSize: 12, weight: .regular)
        advertiserLabel.textColor = UIColor(AppTheme.Colors.textSecondary)

        let bodyLabel = UILabel()
        bodyLabel.font = .systemFont(ofSize: 13, weight: .regular)
        bodyLabel.textColor = UIColor(AppTheme.Colors.textSecondary)
        // RESTORED (compliance hardening pass): PR #34's visual sizing pass trimmed this to 2
        // lines toward the ~250-320pt compact-card target, but Google's Native Advanced
        // guidelines require body text not be truncated before 90 characters — 2 lines can
        // truncate earlier than that on narrower iPhones. Restored to 3; font/other body
        // styling unchanged.
        bodyLabel.numberOfLines = 3

        let iconImageView = UIImageView()
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.layer.cornerRadius = 8
        iconImageView.clipsToBounds = true
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        iconImageView.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let mediaView = MediaView()
        mediaView.translatesAutoresizingMaskIntoConstraints = false
        // REVERTED (validator: "MediaView is too small for video") — PR #34's visual sizing pass
        // trimmed this to 110pt, but Google requires MediaView to be at least 120x120pt on iOS
        // for native video; 110pt tripped that minimum on the very next real-device validator
        // run. Restored to 120pt — mandatory, not a style choice. The other PR #34 compact-card
        // changes (stack spacing 6, bodyLabel 2 lines, CTA min height/insets below) are unrelated
        // to this minimum and stay as they were.
        mediaView.heightAnchor.constraint(equalToConstant: 120).isActive = true
        // FIX (AdMob validator: "Advertiser assets outside native ad view"): mediaView's own
        // frame is correctly constrained (height fixed above, width via the stack's fill
        // alignment — see the layout audit), but the media creative Google renders inside it
        // has its own native aspect ratio, unrelated to that fixed box. Without clipping,
        // content that doesn't match the constrained frame can paint outside mediaView's laid-
        // out bounds even though the view's frame itself is correct.
        mediaView.clipsToBounds = true

        // isUserInteractionEnabled = false: Google's native ad view intercepts taps on the
        // call-to-action itself to attribute the click correctly — a button-owned tap target
        // here would swallow the touch before that tracking runs. Documented SDK requirement,
        // not an accident.
        let callToActionButton = UIButton(type: .system)
        callToActionButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        callToActionButton.setTitleColor(.black, for: .normal)
        callToActionButton.backgroundColor = UIColor(AppTheme.Colors.primaryGreen)
        callToActionButton.layer.cornerRadius = 12
        callToActionButton.isUserInteractionEnabled = false
        callToActionButton.translatesAutoresizingMaskIntoConstraints = false
        // Visual sizing pass: previously had no explicit height at all, relying purely on
        // intrinsic content size (title height only) — undetermined and inconsistent with every
        // other fixed-size asset in this stack (iconImageView 40x40, mediaView's own height
        // constraint below). >= rather than == so a larger system font (e.g. Dynamic Type) can
        // still grow the button instead of clipping its title.
        callToActionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        // Horizontal breathing room around the title so it doesn't run edge-to-edge on longer
        // advertiser-supplied CTA strings — contentEdgeInsets (not UIButton.Configuration) to
        // match this button's existing pre-Configuration API usage above/below.
        callToActionButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        // FIX (AdMob validator: "Advertiser assets outside native ad view"): the button's width
        // comes from the stack's fill alignment, but nothing previously stopped a long
        // advertiser-supplied CTA string's intrinsic content width from winning that fight and
        // pushing the button wider than the stack (and therefore adView) — see the layout audit.
        // Compression resistance guarantees the fill constraint always wins instead, truncating
        // the title (single line, tail-truncated) rather than growing the button. .defaultLow
        // hugging keeps the button from being forced any wider than its content needs within
        // that same fill width.
        //
        // DOWNGRADED (compliance/Auto Layout hardening pass): .required → .defaultHigh. adView
        // itself now carries a REQUIRED root width constraint (see sizeThatFits(_:uiView:
        // context:)/Coordinator.widthConstraint) — leaving this at .required too meant a long
        // advertiser-supplied CTA string could set up a required-vs-required Auto Layout
        // conflict (this button's required intrinsic width vs. adView's required proposed
        // width), which Auto Layout resolves by breaking one of them with a console warning
        // rather than a clean, predictable truncation. .defaultHigh still beats the stack's
        // .defaultLow-ish fill/hugging behavior in the normal case (so the CTA still reads as a
        // real button, not a squashed sliver), but now yields cleanly to adView's required width
        // instead of fighting it — numberOfLines = 1 + .byTruncatingTail below still guarantee
        // truncation, not overflow, for a long title.
        callToActionButton.titleLabel?.numberOfLines = 1
        callToActionButton.titleLabel?.lineBreakMode = .byTruncatingTail
        callToActionButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        callToActionButton.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerTextStack = UIStackView(arrangedSubviews: [headlineLabel, advertiserLabel])
        headerTextStack.axis = .vertical
        headerTextStack.spacing = 2

        let headerRow = UIStackView(arrangedSubviews: [iconImageView, headerTextStack])
        headerRow.axis = .horizontal
        headerRow.spacing = 10
        headerRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [sponsoredLabel, headerRow, mediaView, bodyLabel, callToActionButton])
        stack.axis = .vertical
        // Visual sizing pass: 8 → 6pt — trims card height toward the compact-card target while
        // keeping comfortable breathing room between elements.
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        adView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: adView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: adView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: adView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: adView.trailingAnchor),
        ])

        // Asset-view registration — must happen before `.nativeAd` is ever assigned (see
        // populate(_:with:) below) for Google's click/impression tracking to activate correctly.
        adView.headlineView = headlineLabel
        adView.bodyView = bodyLabel
        adView.iconView = iconImageView
        adView.mediaView = mediaView
        adView.callToActionView = callToActionButton
        adView.advertiserView = advertiserLabel

        return adView
    }

    private func populate(_ adView: GoogleMobileAds.NativeAdView, with nativeAd: NativeAd) {
        (adView.headlineView as? UILabel)?.text = nativeAd.headline
        (adView.bodyView as? UILabel)?.text = nativeAd.body
        (adView.bodyView as? UILabel)?.isHidden = nativeAd.body == nil
        (adView.iconView as? UIImageView)?.image = nativeAd.icon?.image
        (adView.iconView as? UIImageView)?.isHidden = nativeAd.icon == nil
        (adView.advertiserView as? UILabel)?.text = nativeAd.advertiser
        (adView.advertiserView as? UILabel)?.isHidden = nativeAd.advertiser == nil
        (adView.callToActionView as? UIButton)?.setTitle(nativeAd.callToAction, for: .normal)
        (adView.callToActionView as? UIButton)?.isHidden = nativeAd.callToAction == nil
        (adView.mediaView as? MediaView)?.mediaContent = nativeAd.mediaContent

        // Must be assigned last, after every asset view above is registered — this is what
        // activates Google's click/impression tracking for the ad (documented SDK requirement).
        adView.nativeAd = nativeAd
    }
}

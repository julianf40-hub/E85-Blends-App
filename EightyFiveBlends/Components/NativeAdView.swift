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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> GoogleMobileAds.NativeAdView {
        buildNativeAdView()
    }

    func updateUIView(_ uiView: GoogleMobileAds.NativeAdView, context: Context) {
        // Only repopulate when the underlying NativeAd instance actually changed. Reference
        // identity (===/!==) is the right comparison here — NativeAd is a reference type, and
        // NativeAdLoader only ever produces one instance per placement's displayed lifetime (see
        // NativeAdLoader.loadIfNeeded()'s idle/loading/loaded/failed guard), so this reduces to
        // "populate exactly once," not a per-property diff.
        guard context.coordinator.lastPopulatedNativeAd !== nativeAd else { return }
        populate(uiView, with: nativeAd)
        context.coordinator.lastPopulatedNativeAd = nativeAd

        // TEMPORARY — asset frame diagnostics for the "Advertiser assets outside native ad
        // view" validator investigation. Moved here from buildNativeAdView() (see git history):
        // at construction time nothing has yet given uiView a real external frame (SwiftUI's
        // UIViewRepresentable machinery only lays it out afterward, via
        // sizeThatFits(_:uiView:context:) below), so those captures were guaranteed to be
        // .zero/degenerate. Here, after populate(_:with:) has assigned .nativeAd and a layout
        // pass is forced immediately below, uiView has a real, resolved frame to log against.
        // See the diagnostics-logger declaration near the top of this file for the os.Logger/
        // privacy rationale. Remove alongside every other TEMPORARY block in this file.
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
        admobDiagnosticsLogger.log("""
            Native ad asset frames (updateUIView, post-populate) — \
            uiView.bounds=\(String(describing: uiView.bounds), privacy: .public)
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

        if let advertiserView = uiView.advertiserView {
            let frameInAdView = advertiserView.convert(advertiserView.bounds, to: uiView)
            admobDiagnosticsLogger.log("""
                advertiserView (updateUIView, post-populate) — \
                frame=\(String(describing: frameInAdView), privacy: .public), \
                intrinsicContentSize=\(String(describing: advertiserView.intrinsicContentSize), privacy: .public)
                """)
        } else {
            admobDiagnosticsLogger.log("advertiserView (updateUIView, post-populate) — not registered")
        }

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
        #endif
    }

    // FIX (AdMob validator: "Advertiser assets outside native ad view"): adView (built in
    // buildNativeAdView() below, unchanged) never had an explicit width/height of its own —
    // only stack's edges were pinned to it, which makes stack's size equal adView's, not the
    // other way around. Without this override, SwiftUI's default UIViewRepresentable sizing
    // for a plain UIView with no intrinsicContentSize (GoogleMobileAds.NativeAdView doesn't
    // provide one) is implementation-defined, so adView's frame at the point Google's SDK
    // validates the ad was never guaranteed to be correct — producing degenerate/zero-sized
    // asset frames that the validator reports as "outside" the native ad view, even though the
    // view HIERARCHY (see buildNativeAdView()) is correct. This makes adView's size
    // deterministic: derived from its own Auto Layout constraint graph (stack's arrangedSubviews
    // — sponsoredLabel, headerRow, mediaView, bodyLabel, callToActionButton — already produce a
    // well-defined intrinsic height; see buildNativeAdView(), untouched), evaluated at SwiftUI's
    // proposed width. No fixed/placeholder size — the proposed width comes from the real layout
    // pass (AppCard's frame(maxWidth: .infinity)), and height still comes entirely from the ad's
    // actual content via systemLayoutSizeFitting, exactly as it always should have.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: GoogleMobileAds.NativeAdView,
        context: Context
    ) -> CGSize? {
        let targetWidth = proposal.width ?? UIView.layoutFittingCompressedSize.width
        return uiView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    private func buildNativeAdView() -> GoogleMobileAds.NativeAdView {
        let adView = GoogleMobileAds.NativeAdView()
        adView.backgroundColor = .clear
        adView.translatesAutoresizingMaskIntoConstraints = false

        // "Sponsored" badge — kept visually distinct and always present, per this app's
        // requirement that ad content never be mistaken for native 85Blends content.
        let sponsoredLabel = UILabel()
        sponsoredLabel.text = "SPONSORED"
        sponsoredLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        sponsoredLabel.textColor = UIColor(AppTheme.Colors.stationYellow)

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
        // Visual sizing pass: 3 → 2 lines — trims card height toward the ~250-320pt compact-card
        // target (see the sizing audit). Body copy isn't the ad's primary hook (the headline
        // above still gets its full 2 lines), so 2 lines stays plenty for typical native-ad
        // description text.
        bodyLabel.numberOfLines = 2

        let iconImageView = UIImageView()
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.layer.cornerRadius = 8
        iconImageView.clipsToBounds = true
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        iconImageView.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let mediaView = MediaView()
        mediaView.translatesAutoresizingMaskIntoConstraints = false
        // Visual sizing pass: 120 → 110pt — a modest trim toward the compact-card target.
        // Deliberately not smaller: Google's Native Ads policy expects the media asset to stay
        // visually prominent, and this file has already fixed two separate asset-prominence/
        // validator issues — no further reduction here to avoid reintroducing that risk.
        mediaView.heightAnchor.constraint(equalToConstant: 110).isActive = true
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
        // .required compression resistance guarantees the fill constraint always wins instead,
        // truncating the title (single line, tail-truncated) rather than growing the button.
        // .defaultLow hugging keeps the button from being forced any wider than its content
        // needs within that same fill width.
        callToActionButton.titleLabel?.numberOfLines = 1
        callToActionButton.titleLabel?.lineBreakMode = .byTruncatingTail
        callToActionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
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

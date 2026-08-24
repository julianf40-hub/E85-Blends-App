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

struct NativeAdView: View {
    let placement: AdManager.NativePlacement

    @State private var loader: NativeAdLoader

    init(placement: AdManager.NativePlacement) {
        self.placement = placement
        _loader = State(initialValue: NativeAdLoader(adUnitID: placement.adUnitID))
    }

    var body: some View {
        Group {
            if let nativeAd = loader.nativeAd {
                NativeAdCard(nativeAd: nativeAd)
            } else {
                // Covers idle, loading, and failed alike — see this file's header. No spinner,
                // no placeholder box, no error text; scrolling content simply doesn't include
                // this card until (and unless) a real ad is ready to show.
                EmptyView()
            }
        }
        .task {
            // Defense-in-depth Pro check — see this file's header. Every real call site already
            // gates on SubscriptionManager.shared.isProUser before constructing this view at
            // all, so this is a second, cheap read of the exact same property, never a new
            // entitlement decision.
            guard AdManager.shared.isAdsEnabled else { return }
            loader.loadIfNeeded()
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
    private var adLoader: AdLoader?

    init(adUnitID: String) {
        self.adUnitID = adUnitID
        super.init()
    }

    /// Idempotent — a second call while already loading, loaded, or failed is a no-op, so
    /// nothing in this app can trigger more than one simultaneous or repeated request per
    /// placement instance (Performance Requirements: "one ad request per placement").
    func loadIfNeeded() {
        guard state == .idle else { return }
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
        loader.load(Request())
    }
}

extension NativeAdLoader: NativeAdLoaderDelegate {
    nonisolated func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.nativeAd = nativeAd
            self.state = .loaded
        }
    }

    // Fail silently, always — no internet, SDK unavailable, and no-fill all land here and are
    // handled identically: state flips to .failed, NativeAdView renders EmptyView(), and nothing
    // is ever shown to the user. See this file's header.
    nonisolated func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.state = .failed
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
        mediaView.heightAnchor.constraint(equalToConstant: 120).isActive = true

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

        let headerTextStack = UIStackView(arrangedSubviews: [headlineLabel, advertiserLabel])
        headerTextStack.axis = .vertical
        headerTextStack.spacing = 2

        let headerRow = UIStackView(arrangedSubviews: [iconImageView, headerTextStack])
        headerRow.axis = .horizontal
        headerRow.spacing = 10
        headerRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [sponsoredLabel, headerRow, mediaView, bodyLabel, callToActionButton])
        stack.axis = .vertical
        stack.spacing = 8
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

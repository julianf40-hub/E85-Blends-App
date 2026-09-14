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
//    - Pro / entitlement-pending / consent: every real call site (CalculatorView.swift /
//      StationsView.swift) checks SubscriptionManager.shared.isProUser BEFORE constructing this
//      view at all, so a Pro user never causes this type to exist. The
//      AdManager.shared.canRequestAds check inside .task below is the single, centralized
//      ad-readiness gate (see AdManager.swift's header) — it re-checks Pro status as
//      defense-in-depth against a future call site that forgets to gate, and ALSO covers two
//      things no call site checks on its own: SubscriptionManager's entitlement-resolution-
//      pending window (so this view never loads an ad before it's actually known whether the
//      user is Pro) and Google UMP consent (so no ad is ever requested before the user's consent
//      choice, where required, is known). One gate, three checks — see canRequestAds itself for
//      why this is centralized here instead of duplicated per call site.
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
            // Centralized ad-readiness gate — see this file's header and AdManager.canRequestAds.
            // Covers Pro status, entitlement-resolution-pending, and UMP consent in one read; a
            // skipped load here always renders EmptyView() (see this file's header), so this
            // fully closes the ad-readiness race for this placement without either call site
            // needing its own pending/consent check.
            guard AdManager.shared.canRequestAds else { return }

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

    // Fail silently to the USER, always — no internet, SDK unavailable, and no-fill all land
    // here and are handled identically as far as the UI is concerned: state flips to .failed,
    // NativeAdView renders EmptyView(), and nothing is ever shown to the user. See this file's
    // header.
    nonisolated func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .failed
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

@MainActor
enum NativeAdTextLayout {
    static let headlineLineLimit = 2
    static let bodyLineLimit = 4

    static func configureHeadline(_ label: UILabel) {
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.numberOfLines = headlineLineLimit
    }

    static func configureBody(_ label: UILabel) {
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.numberOfLines = bodyLineLimit
    }

    static func applyBodyLayoutWidth(_ width: CGFloat, to label: UILabel?) {
        guard width.isFinite, width > 0 else { return }
        label?.preferredMaxLayoutWidth = width
    }
}

@MainActor
enum NativeAdLayout {
    // Google's reference SwiftUI renderer uses a deterministic 300-point minimum. A
    // matched A/B run inside both of 85Blends' real Stations hosts isolated the remaining Native
    // Ad Validator warning to this renderer's former content-derived root-height negotiation:
    // the unchanged custom asset hierarchy was clean in 5/5 impressions once only this fixed
    // root strategy was substituted. This custom hierarchy needs 311.17578125 points for the
    // conservative simultaneous 25-wide-glyph headline and 90-wide-glyph body case. One extra
    // point keeps the CTA strictly inside the registered root instead of exactly on its lower
    // edge, where subpixel rounding can make the Validator read it as fractionally outside.
    // Keep these values centralized so sizing and focused policy tests cannot drift apart.
    static let rootHeight: CGFloat = 313
    static let bottomSafetyInset: CGFloat = 1
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

        // REGRESSION FIX (PR #37 follow-up — "native ads no longer appear"): widthConstraint
        // .isActive is a TRANSIENT, per-call toggle — sizeThatFits correctly flips it back to
        // false on every nil-proposal "ideal size" measurement pass, which is a normal, expected,
        // and (per real-device evidence across this whole investigation) RECURRING part of
        // SwiftUI's layout negotiation for this view, not a one-time event. PR #37 gated
        // population (updateUIView/populateIfNeeded) directly on widthConstraint?.isActive ==
        // true. That is wrong: nothing guarantees the LAST sizeThatFits call SwiftUI ever makes
        // for a given, now-settled NativeAdContainer instance is a bounded one — once SwiftUI
        // considers this view's inputs unchanged, it can stop calling updateUIView/sizeThatFits
        // for it entirely, even while it stays on screen. If that last call happened to be a
        // nil-proposal one, widthConstraint.isActive is left false PERMANENTLY, and since
        // nothing else ever re-triggers a fresh call for that instance, population never
        // happens: lastPopulatedNativeAd stays nil forever and the ad silently never appears.
        // This field is the fix: a MONOTONIC "has bounded layout ever been established" signal,
        // set once a real, finite, positive width is first proposed (sizeThatFits's bounded
        // branch) and deliberately NEVER cleared by the nil-proposal branch — unlike
        // widthConstraint.isActive, which keeps toggling for its own, unrelated, correct
        // measurement purposes. updateUIView/populateIfNeeded now gate on THIS instead.
        var lastKnownBoundedWidth: CGFloat?

        // REGRESSION FIX (diagnostics + explicit pending-state tracking, same investigation):
        // the NativeAd updateUIView deferred because no bounded width had been established yet
        // at that time. Set when deferring, cleared the moment populateIfNeeded actually
        // populates. This doesn't change WHAT gets populated (this struct's own `nativeAd`
        // property is already always the correct value — NativeAdLoader only ever produces one
        // instance per placement's displayed lifetime), so it's bookkeeping/diagnostics only —
        // it exists to make "is there currently an ad waiting on bounded width" directly
        // observable in the logs below, and to let the validation story for this fix be phrased
        // in terms of an explicit, inspectable field rather than an implicit invariant.
        var pendingNativeAd: NativeAd?

    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> GoogleMobileAds.NativeAdView {
        let adView = buildNativeAdView()
        context.coordinator.widthConstraint = adView.widthAnchor.constraint(equalToConstant: 0)
        // Establish the production root height as soon as the GADNativeAdView exists. The width
        // remains proposal-driven below, while height is already deterministic before any asset
        // values or NativeAd association can reach this view.
        adView.heightAnchor.constraint(equalToConstant: NativeAdLayout.rootHeight).isActive = true
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
    // FIX: population is gated on Coordinator.lastKnownBoundedWidth != nil — a MONOTONIC "has
    // sizeThatFits EVER established a real, SwiftUI-proposed, bounded width for this exact
    // uiView" signal (see its declaration on Coordinator for why this replaced the transient
    // widthConstraint?.isActive check a prior pass used here, which could leave a pending ad
    // stranded forever — the PR #37 regression this fix addresses). On the (real-device-
    // confirmed) ordering where updateUIView runs first, bounded width has never been
    // established yet, so this stores the ad as pendingNativeAd and defers; sizeThatFits's own
    // bounded branch below performs the deferred population once it first records a bounded
    // width (see its own comment for why that handoff is async, not inline). On any LATER
    // updateUIView call — once bounded width has already been established at least once — this
    // populates directly, synchronously, exactly as before. Either path funnels through
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
        // pending state or calling populateIfNeeded at all once there's nothing left to do.
        // populateIfNeeded's OWN identical guard (below) is still the source of truth — this is
        // purely a hot-path optimization, not a second, independent correctness mechanism.
        guard context.coordinator.lastPopulatedNativeAd !== nativeAd else { return }

        guard context.coordinator.lastKnownBoundedWidth != nil else {
            // DEFERRED — see this function's header comment. sizeThatFits(_:uiView:context:)
            // will perform the deferred population once it first establishes a bounded width.
            // Recorded explicitly as pendingNativeAd so the "is an ad waiting" state is directly
            // observable rather than implicit — see the Coordinator field's own comment.
            context.coordinator.pendingNativeAd = nativeAd
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

        // REGRESSION FIX (replaces the prior widthConstraint?.isActive re-check — see
        // Coordinator.lastKnownBoundedWidth's own comment for the full root-cause rationale):
        // gate on the MONOTONIC "has bounded width ever been established" signal, not the
        // transient per-call isActive toggle. The prior check was itself a correct fix for a
        // real time-of-check/time-of-use gap (a queued DispatchQueue.main.async handoff running
        // after a LATER nil-proposal sizeThatFits call had deactivated the constraint again) —
        // but re-checking isActive specifically, rather than lastKnownBoundedWidth, meant that
        // TOCTOU-safe re-check could itself abort a population attempt that was perfectly safe
        // to make (bounded width WAS established earlier; it just isn't the constraint's
        // CURRENT transient state), with nothing guaranteeing another attempt would ever follow
        // — the exact stranding this fix closes. If bounded width was never established at all,
        // do nothing: lastPopulatedNativeAd stays nil, pendingNativeAd stays set, and the next
        // bounded sizeThatFits call (which always re-schedules this same handoff whenever
        // lastPopulatedNativeAd !== nativeAd — see its own comment) naturally retries. No timer,
        // no polling, no new dispatch loop.
        guard let lastKnownBoundedWidth = context.coordinator.lastKnownBoundedWidth else { return }

        // Defensively re-apply the last known-good bounded width before populating. Between
        // lastKnownBoundedWidth being recorded and this call actually running, an intervening
        // nil-proposal sizeThatFits call may have deactivated widthConstraint for its own
        // (correct, unrelated) measurement purposes — see sizeThatFits's fallback branch. This
        // guarantees adView is in a genuinely bounded, correct state at the exact moment
        // adView.nativeAd is assigned below, regardless of the constraint's transient state at
        // this instant, without waiting for or depending on another sizeThatFits call.
        if let widthConstraint = context.coordinator.widthConstraint {
            widthConstraint.constant = lastKnownBoundedWidth
            widthConstraint.isActive = true
        }

        // Google's SDK begins managing/tracking the registered assets the moment nativeAd is
        // assigned. Populate values first, then resolve the already-bounded fixed root before
        // making that association. The final assignment remains deliberately last.
        populateAssetValues(uiView, with: nativeAd)

        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()

        // Must be assigned last, after every asset view is populated and the fixed root has laid
        // out. This activates Google's click/impression tracking (documented SDK requirement).
        uiView.nativeAd = nativeAd

        context.coordinator.lastPopulatedNativeAd = nativeAd
        context.coordinator.pendingNativeAd = nil

        // Pick up any SDK-managed internal adjustment made during association.
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()

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
    // frame. The required width remains proposal-driven independently of the fixed root height.
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
    // ONLY place Coordinator.lastKnownBoundedWidth ever gets recorded (REGRESSION FIX, PR #37
    // follow-up: this used to be phrased in terms of widthConstraint.isActive, a transient
    // per-call toggle that could leave a pending ad stranded forever — see lastKnownBoundedWidth's
    // own comment on Coordinator) — which makes it the ONLY place that can correctly know "a
    // real bounded width has now been established," and therefore the right place to perform
    // any population updateUIView deferred (see updateUIView's own header comment for the full
    // ordering rationale). Deliberately NOT done inline/
    // synchronously here: sizeThatFits runs during SwiftUI's live layout/measurement pass, and
    // mutating adView's content synchronously mid-measurement (labels' text, .nativeAd) is not
    // something UIKit/SwiftUI's layout machinery is guaranteed to tolerate cleanly. Instead,
    // this hands off to DispatchQueue.main.async — a clean, standard "run on the next main-
    // thread run-loop turn, after this measurement call has already returned" — so
    // populateIfNeeded's real UIKit mutations never happen from inside a sizeThatFits call
    // frame. The only mutations sizeThatFits performs directly are width-constraint updates,
    // body wrapping width, and layout passes — never `.nativeAd` association.
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
            //
            widthConstraint?.isActive = false
            let targetFittingSize = UIView.layoutFittingCompressedSize
            let fittingResult = uiView.systemLayoutSizeFitting(
                targetFittingSize,
                withHorizontalFittingPriority: .fittingSizeLevel,
                verticalFittingPriority: .fittingSizeLevel
            )
            // Width is still the view's natural fitting width for an ideal proposal, but root
            // height never participates in content-derived reconciliation.
            let fallbackSize = CGSize(
                width: fittingResult.width,
                height: NativeAdLayout.rootHeight
            )

            return fallbackSize
        }

        widthConstraint?.constant = proposedWidth
        widthConstraint?.isActive = true
        // Google requires publishers to allow body content through 90 characters. Supplying
        // UILabel's actual bounded width makes its existing multiline policy wrap against the
        // real production width instead of an unbounded intrinsic width.
        NativeAdTextLayout.applyBodyLayoutWidth(
            proposedWidth,
            to: uiView.bodyView as? UILabel
        )
        // REGRESSION FIX — record the MONOTONIC "bounded width established" signal here,
        // alongside (but distinct from) the transient widthConstraint.isActive toggle above.
        // Deliberately never cleared by the nil-proposal branch — see Coordinator.
        // lastKnownBoundedWidth's own comment for the full root-cause rationale.
        context.coordinator.lastKnownBoundedWidth = proposedWidth

        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()

        // Width is guaranteed == proposedWidth by the required-priority constraint activated
        // just above — returned explicitly rather than trusting fittingResult's own width, so a
        // genuine content conflict (which would show up as an Auto Layout console warning) can
        // never inflate the size this reports back to SwiftUI.
        let returnedSize = CGSize(width: proposedWidth, height: NativeAdLayout.rootHeight)

        // LIFECYCLE FIX — deferred population handoff (see this function's header comment).
        // Only schedules the hop when population is still actually pending, so repeated
        // sizeThatFits calls after the ad is already populated (SwiftUI re-measuring for an
        // unrelated reason) never schedule a redundant no-op closure.
        let willScheduleDeferredHandoff = context.coordinator.lastPopulatedNativeAd !== nativeAd
        if willScheduleDeferredHandoff {
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
        NativeAdTextLayout.configureHeadline(headlineLabel)
        headlineLabel.textColor = UIColor(AppTheme.Colors.textPrimary)

        let advertiserLabel = UILabel()
        advertiserLabel.font = .systemFont(ofSize: 12, weight: .regular)
        advertiserLabel.textColor = UIColor(AppTheme.Colors.textSecondary)

        let bodyLabel = UILabel()
        NativeAdTextLayout.configureBody(bodyLabel)
        bodyLabel.textColor = UIColor(AppTheme.Colors.textSecondary)
        // Google's Native Advanced guidelines require body text not be truncated before 90
        // characters. Four lines preserve that full allowance at the narrowest supported card
        // width even for a conservative all-wide-glyph stress string; font and color stay
        // unchanged.

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
            stack.bottomAnchor.constraint(
                equalTo: adView.bottomAnchor,
                constant: -NativeAdLayout.bottomSafetyInset
            ),
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

    // Sets asset values without associating the NativeAd. Association remains in
    // populateIfNeeded after the fixed root has laid out. Google's documented optional-asset
    // hide-when-nil pattern is unchanged.
    private func populateAssetValues(_ adView: GoogleMobileAds.NativeAdView, with nativeAd: NativeAd) {
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
    }
}

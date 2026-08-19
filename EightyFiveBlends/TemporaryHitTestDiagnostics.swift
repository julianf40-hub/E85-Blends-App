//
//  TemporaryHitTestDiagnostics.swift
//  EightyFiveBlends
//
//  TEMPORARY, DIAGNOSTIC-ONLY. Not part of the app's real UI or business logic — exists solely
//  to collect on-device runtime evidence (frames, tap locations, action counts) for the Garage
//  Add Vehicle hit-test investigation, calibrated against Reminders' known-good Add Reminder
//  control. Consumed by the temporary instrumentation in GarageView.swift and
//  RemindersView.swift — see those files for exactly where each piece here is attached.
//
//  Every value collected is transient @State/@Preference data local to whichever view reads
//  it: nothing is written to UserDefaults/SwiftData, nothing is logged, nothing is sent over
//  the network, and everything resets the moment the view (or the app) restarts. No location,
//  station, or vehicle data is touched — only view geometry and tap coordinates already visible
//  on screen.
//
//  DELETE THIS FILE, and the instrumentation that references it, once the investigation
//  concludes.
//
//  PHASE 3 ADDITION — UIKit hit-test owner inspection. Public UIKit APIs only: UIView, UIWindow,
//  UIViewRepresentable, UIView.hitTest(_:with:), UIView.convert(_:to:), UIView.superview,
//  UIView.gestureRecognizers, and UIGestureRecognizer's public state/flag properties. No
//  private APIs, no Objective-C runtime swizzling, no method replacement, no UIWindow
//  subclassing, no recursiveDescription/_printHierarchy, no KVC into private internals, no
//  synthetic touches. `window.hitTest(point, with: nil)` is called read-only, purely to
//  inspect what a real touch at that point WOULD hit — it never overrides hitTest/
//  point(inside:)/sendEvent, never intercepts a real event, and has zero effect on actual user
//  taps. See HitTestWindowReader and UIKitHitTestInspector below.
//

import SwiftUI
import UIKit

/// Collects named view frames (in whatever `CoordinateSpace` the caller chose — `.global` by
/// convention here) reported by `measureHitTestFrame(_:in:)` below, keyed by a caller-chosen
/// label. Multiple views can report under different labels; SwiftUI merges them as the
/// preference bubbles up to the nearest `.onPreferenceChange` reader.
struct HitTestFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// One probe level's accumulated diagnostic state: a tap count plus the most recent tap
/// location. Session-only — never persisted, never read back into any decision.
struct HitTestProbeState {
    var count = 0
    var lastLocation: CGPoint?

    mutating func record(_ location: CGPoint) {
        count += 1
        lastLocation = location
    }
}

extension View {
    /// Reports this view's own runtime frame under `label`, via a `GeometryReader` placed in
    /// `.background(...)`. A `.background` takes on the modified view's own size without
    /// affecting its layout — it cannot grow, shrink, or reposition the view it's attached to,
    /// and cannot change Button sizing. Both the `GeometryReader` and the `Color.clear` inside
    /// it are explicitly `.allowsHitTesting(false)`, so this can never intercept a touch meant
    /// for the view it's measuring, regardless of how SwiftUI would otherwise treat background
    /// content for hit-testing purposes.
    func measureHitTestFrame(_ label: String, in space: CoordinateSpace = .global) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .allowsHitTesting(false)
                    .preference(key: HitTestFramePreferenceKey.self, value: [label: proxy.frame(in: space)])
            }
            .allowsHitTesting(false)
        )
    }

    /// Reports a tap's local coordinate to `onTap` whenever this view (or whatever within it
    /// already has a hit-testable shape — e.g. a Button's label, or rendered Text) receives
    /// one. Uses `SpatialTapGesture` + `.simultaneousGesture(...)` specifically: a simultaneous
    /// gesture only ever OBSERVES alongside a view's own existing gesture recognizers (a
    /// Button's tap handling, a ScrollView's pan/scroll recognizer) — it never blocks, replaces,
    /// or takes priority over them, and — critically for this investigation — attaching it to a
    /// plain, background-less container does not by itself expand that container's
    /// hit-testable area: SwiftUI still only delivers a gesture where a shape (rendered
    /// content, or an explicit `.contentShape`) already exists. No `.contentShape` is added
    /// anywhere by this helper.
    func tapProbe(onTap: @escaping (CGPoint) -> Void) -> some View {
        simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    onTap(value.location)
                }
        )
    }
}

extension CGRect {
    /// Compact, rounded, screenshot-readable rendering, e.g. "x 461...681 w 220 | y 126...185 h 59".
    var hitTestDescription: String {
        "x \(Int(minX.rounded()))...\(Int(maxX.rounded())) w \(Int(width.rounded())) | y \(Int(minY.rounded()))...\(Int(maxY.rounded())) h \(Int(height.rounded()))"
    }

    /// Whether this frame's horizontal span alone contains `x` — ignores Y deliberately: the
    /// Phase 1 device evidence for the "dead" tap only reported an X coordinate, so this checks
    /// exactly what that evidence can support, nothing more.
    func containsX(_ x: CGFloat) -> Bool {
        x >= minX && x <= maxX
    }

    /// Whether this frame is within `tolerance` points of `other` on every edge — used to
    /// compare two independently-measured frames (e.g. "does the padded label span the same
    /// area as the Button's own outer frame?") without floating-point exact-equality noise.
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(minX - other.minX) <= tolerance &&
            abs(maxX - other.maxX) <= tolerance &&
            abs(minY - other.minY) <= tolerance &&
            abs(maxY - other.maxY) <= tolerance
    }
}

extension CGPoint {
    /// e.g. "x 505, y 159".
    var hitTestDescription: String {
        "x \(Int(x.rounded())), y \(Int(y.rounded()))"
    }
}

extension Optional where Wrapped == Bool {
    /// "yes"/"no" when known, "?" while the frames this depends on are still being measured
    /// (SwiftUI's first layout pass hasn't reported a preference value yet).
    var hitTestYesNo: String {
        switch self {
        case .some(true): return "yes"
        case .some(false): return "no"
        case .none: return "?"
        }
    }
}

/// Phase 1 real-device evidence located the "dead" tap at approximately this global X — used
/// only to annotate the diagnostic readout ("does frame F span this X?"); never read by, or
/// fed back into, any production decision. Diagnostic-only by construction: this type has no
/// members besides this one constant.
enum HitTestDiagnosticReference {
    static let deadX: CGFloat = 305
}

/// Compact, screenshot-friendly readout of whatever rows a caller assembles. Purely
/// presentational and never hit-testable on its own — callers are still expected to apply
/// `.allowsHitTesting(false)` at the `.overlay` call site, matching the diagnostic's "must not
/// intercept any touch" requirement explicitly rather than relying on this view alone.
struct HitTestDiagnosticReadout: View {
    let title: String
    let rows: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            ForEach(rows, id: \.self) { row in
                Text(row)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
            }
        }
        .foregroundStyle(Color.white)
        .padding(8)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Phase 3: UIKit hit-test owner inspection

/// Bridges to the real `UIWindow` hosting whatever SwiftUI view this is attached to (via
/// `.background(...)`), reporting it through `onWindowChange`. That's its ONLY job: it draws
/// nothing (`isOpaque = false`, clear background, no `draw(_:)` override) and
/// `isUserInteractionEnabled = false`, so it can never receive or affect a touch — pair with
/// `.allowsHitTesting(false)` at the SwiftUI call site as defense in depth. The window
/// reference itself is ordinary transient `@State` in whichever view reads it (see
/// GarageView/RemindersView) — not `weak`, because a `UIWindow` is already kept alive by UIKit
/// for as long as it's on screen, and a value-type SwiftUI `View` holding a reference to it
/// creates no retain cycle (the window never holds a reference back to the View struct).
/// Nothing here is persisted, transmitted, or kept beyond the current view's lifetime.
struct HitTestWindowReader: UIViewRepresentable {
    let onWindowChange: (UIWindow?) -> Void

    func makeUIView(context: Context) -> PassiveWindowProbeView {
        let view = PassiveWindowProbeView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateUIView(_ uiView: PassiveWindowProbeView, context: Context) {
        uiView.onWindowChange = onWindowChange
        // Covers the case where the view is already attached to a window by the time SwiftUI
        // next calls updateUIView — didMoveToWindow may already have fired once against a
        // closure captured from an earlier render.
        onWindowChange(uiView.window)
    }

    final class PassiveWindowProbeView: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isOpaque = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("HitTestWindowReader.PassiveWindowProbeView does not support Interface Builder")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }
}

/// Read-only, compact summary of one `UIGestureRecognizer` — public properties only.
struct HitTestGestureInfo {
    let className: String
    let isEnabled: Bool
    let cancelsTouchesInView: Bool
    let delaysTouchesBegan: Bool
    let delaysTouchesEnded: Bool
    let state: String
}

/// One level of the winning hit view's superview ancestry, walking from the hit view itself up
/// toward its `UIWindow`.
struct HitTestAncestorInfo {
    let className: String
    let frameInWindow: CGRect
    let isUserInteractionEnabled: Bool
    let isHidden: Bool
    let alpha: CGFloat
    let gestureRecognizers: [HitTestGestureInfo]
}

/// The result of one `window.hitTest(point, with: nil)` call, plus its bounded ancestry chain.
/// `ancestry[0]` is the winning hit view itself; later elements are its `superview` chain, up
/// to (and including) the `UIWindow` or `UIKitHitTestInspector.maxAncestryDepth`, whichever
/// comes first. Empty `ancestry` means `hitTest` returned nil at that point (no view claims it
/// — which itself would be notable).
struct UIKitHitTestSnapshot {
    let label: String
    let windowPoint: CGPoint
    let ancestry: [HitTestAncestorInfo]

    var ownerClassName: String {
        ancestry.first?.className ?? "no hit view"
    }

    var ownerFrame: CGRect? {
        ancestry.first?.frameInWindow
    }

    var ownerFrameContainsPoint: Bool {
        ownerFrame?.contains(windowPoint) ?? false
    }

    func shortChain(levels: Int = 3) -> String {
        ancestry.prefix(levels).map { $0.className.hitTestTruncated(18) }.joined(separator: " > ")
    }

    /// Index of the first ancestry level whose class name differs from `other`'s corresponding
    /// level, or nil if every compared level matches (up to the shorter chain's length — a
    /// length mismatch alone, with all shared levels matching, is reported as the point right
    /// after the shorter chain ends).
    func firstDivergingAncestryIndex(comparedTo other: UIKitHitTestSnapshot) -> Int? {
        let count = min(ancestry.count, other.ancestry.count)
        for index in 0..<count where ancestry[index].className != other.ancestry[index].className {
            return index
        }
        return ancestry.count == other.ancestry.count ? nil : count
    }

    func ancestryMatches(_ other: UIKitHitTestSnapshot) -> Bool {
        firstDivergingAncestryIndex(comparedTo: other) == nil
    }

    /// Index of the first ancestry level whose gesture-recognizer CLASS SET differs from
    /// `other`'s corresponding level (compared by class name only, ignoring instance identity
    /// and order), or nil if every compared level's recognizer set matches.
    func firstDivergingGestureIndex(comparedTo other: UIKitHitTestSnapshot) -> Int? {
        let count = min(ancestry.count, other.ancestry.count)
        for index in 0..<count {
            let mine = Set(ancestry[index].gestureRecognizers.map(\.className))
            let theirs = Set(other.ancestry[index].gestureRecognizers.map(\.className))
            if mine != theirs { return index }
        }
        return nil
    }

    func gestureChainsMatch(_ other: UIKitHitTestSnapshot) -> Bool {
        firstDivergingGestureIndex(comparedTo: other) == nil
    }
}

/// Runs a read-only `UIView.hitTest(_:with:)` at a given window point and walks the winning
/// view's superview ancestry. Never mutates any view, gesture recognizer, or window; never
/// overrides hitTest/point(inside:)/sendEvent; never subclasses UIWindow. Bounded to
/// `maxAncestryDepth` levels so a single sample stays cheap regardless of hierarchy depth.
enum UIKitHitTestInspector {
    static let maxAncestryDepth = 12

    @MainActor
    static func snapshot(label: String, at windowPoint: CGPoint, in window: UIWindow?) -> UIKitHitTestSnapshot? {
        guard let window else { return nil }
        guard let hitView = window.hitTest(windowPoint, with: nil) else {
            return UIKitHitTestSnapshot(label: label, windowPoint: windowPoint, ancestry: [])
        }

        var ancestry: [HitTestAncestorInfo] = []
        var current: UIView? = hitView
        var depth = 0
        while let view = current, depth < maxAncestryDepth {
            ancestry.append(
                HitTestAncestorInfo(
                    className: String(describing: type(of: view)),
                    frameInWindow: view.convert(view.bounds, to: window),
                    isUserInteractionEnabled: view.isUserInteractionEnabled,
                    isHidden: view.isHidden,
                    alpha: view.alpha,
                    gestureRecognizers: (view.gestureRecognizers ?? []).map { recognizer in
                        HitTestGestureInfo(
                            className: String(describing: type(of: recognizer)),
                            isEnabled: recognizer.isEnabled,
                            cancelsTouchesInView: recognizer.cancelsTouchesInView,
                            delaysTouchesBegan: recognizer.delaysTouchesBegan,
                            delaysTouchesEnded: recognizer.delaysTouchesEnded,
                            state: describeGestureState(recognizer.state)
                        )
                    }
                )
            )
            if view === window { break }
            current = view.superview
            depth += 1
        }

        return UIKitHitTestSnapshot(label: label, windowPoint: windowPoint, ancestry: ancestry)
    }

    private static func describeGestureState(_ state: UIGestureRecognizer.State) -> String {
        switch state {
        case .possible: return "possible"
        case .began: return "began"
        case .changed: return "changed"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }
}

extension String {
    /// Truncates to `maxLength` characters for screenshot-readable class-name display —
    /// SwiftUI's hosting-view class names can be very long (generic parameters encoding the
    /// whole view-tree type). Display-only; never used to compare or identify a class.
    func hitTestTruncated(_ maxLength: Int = 44) -> String {
        guard count > maxLength else { return self }
        return String(prefix(maxLength)) + "…"
    }
}

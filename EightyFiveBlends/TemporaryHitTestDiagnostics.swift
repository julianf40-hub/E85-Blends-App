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

import SwiftUI

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

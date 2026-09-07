import Foundation

/// A small discrete zoom level for the Large Nearby E85 widget's map. This is presentation-only —
/// it never affects which stations are fetched or how often location refreshes, only how tightly
/// `NearbyE85MapRegion` frames the same station set the base algorithm already selected.
nonisolated enum NearbyE85MapZoomLevel: Int, CaseIterable, Codable, Sendable {
    case zoomedOutFar = 0
    case zoomedOutSlightly = 1
    case standard = 2
    case zoomedIn = 3
    case zoomedInFar = 4

    static let `default` = Self.standard
    static let minimum = Self.zoomedOutFar
    static let maximum = Self.zoomedInFar

    /// Multiplies the base region's span. 1.0 (`.standard`) reproduces the exact framing the
    /// widget already shipped with before zoom controls existed.
    var spanMultiplier: Double {
        switch self {
        case .zoomedOutFar: 1.45
        case .zoomedOutSlightly: 1.20
        case .standard: 1.00
        case .zoomedIn: 0.82
        case .zoomedInFar: 0.68
        }
    }

    var isAtMinimum: Bool { self == .minimum }
    var isAtMaximum: Bool { self == .maximum }

    /// Clamps at `.maximum` — repeated taps once already zoomed all the way in are a no-op.
    func zoomedInOneStep() -> Self { Self(rawValue: min(rawValue + 1, Self.maximum.rawValue))! }
    /// Clamps at `.minimum` — repeated taps once already zoomed all the way out are a no-op.
    func zoomedOutOneStep() -> Self { Self(rawValue: max(rawValue - 1, Self.minimum.rawValue))! }
}

/// Persists the Large widget's zoom level in the App Group shared container so it survives
/// timeline regeneration and widget-process relaunches. Deliberately a single shared preference,
/// not per-widget-instance state: WidgetKit's `AppIntent`-based interactivity for a
/// `StaticConfiguration` widget has no per-instance identifier to key separate storage off of, and
/// a single Large-widget zoom preference is an explicitly acceptable model for 2.4.0.
nonisolated struct NearbyE85MapZoomStore {
    static let key = "NearbyE85LargeWidgetZoomLevel"

    let defaults: UserDefaults?

    init(defaults: UserDefaults? = NearbyE85Configuration.appGroup.flatMap { UserDefaults(suiteName: $0) }) {
        self.defaults = defaults
    }

    /// Falls back to `.default` whenever the App Group is unavailable, nothing has been stored
    /// yet, or the stored value is corrupted/out of range — never crashes, never zooms to
    /// something the user didn't choose.
    func read() -> NearbyE85MapZoomLevel {
        guard let defaults, let raw = defaults.object(forKey: Self.key) as? Int,
              let level = NearbyE85MapZoomLevel(rawValue: raw) else { return .default }
        return level
    }

    func write(_ level: NearbyE85MapZoomLevel) {
        defaults?.set(level.rawValue, forKey: Self.key)
    }
}

/// The pure step each zoom AppIntent performs — separated from `perform()` so it's directly
/// testable without invoking AppIntents/WidgetKit machinery.
nonisolated enum NearbyE85ZoomAction {
    case zoomIn, zoomOut

    @discardableResult
    func apply(using store: NearbyE85MapZoomStore) -> NearbyE85MapZoomLevel {
        let current = store.read()
        let next = self == .zoomIn ? current.zoomedInOneStep() : current.zoomedOutOneStep()
        store.write(next)
        return next
    }
}

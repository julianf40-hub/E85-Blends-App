import Foundation

/// A small discrete zoom level for the Large Nearby E85 widget's map. This is presentation-only —
/// it never affects which stations are fetched or how often location refreshes, only how tightly
/// `NearbyE85MapRegion` frames the same station set the base algorithm already selected.
///
/// 85Blends 2.4.0 widget quality pass — expanded from 5 to 9 levels for a visibly smoother
/// zoom-step progression (see NearbyE85MapZoomLevelTests.multipliersFormAConsistentGeometricProgression).
/// Case names deliberately don't reuse the old 5-level names (`zoomedOutFar`/`zoomedIn`/etc.) —
/// see `migrated(fromLegacyRawValue:)` and NearbyE85MapZoomStore for why an old persisted raw
/// value must never be reinterpreted directly against these new cases.
nonisolated enum NearbyE85MapZoomLevel: Int, CaseIterable, Codable, Sendable {
    case zoomedOut4 = 0
    case zoomedOut3 = 1
    case zoomedOut2 = 2
    case zoomedOut1 = 3
    case standard = 4
    case zoomedIn1 = 5
    case zoomedIn2 = 6
    case zoomedIn3 = 7
    case zoomedIn4 = 8

    static let `default` = Self.standard
    static let minimum = Self.zoomedOut4
    static let maximum = Self.zoomedIn4

    /// Multiplies the base region's span. 1.0 (`.standard`) reproduces the exact framing the
    /// widget already shipped with before zoom controls existed. An approximately geometric
    /// progression (~12.7% span change per step) so each adjacent tap feels like a consistent,
    /// visibly smaller increment than the old 5-level set's ~20-45% jumps.
    var spanMultiplier: Double {
        switch self {
        case .zoomedOut4: 1.60
        case .zoomedOut3: 1.42
        case .zoomedOut2: 1.26
        case .zoomedOut1: 1.12
        case .standard: 1.00
        case .zoomedIn1: 0.89
        case .zoomedIn2: 0.79
        case .zoomedIn3: 0.70
        case .zoomedIn4: 0.62
        }
    }

    var isAtMinimum: Bool { self == .minimum }
    var isAtMaximum: Bool { self == .maximum }

    /// Clamps at `.maximum` — repeated taps once already zoomed all the way in are a no-op.
    func zoomedInOneStep() -> Self { Self(rawValue: min(rawValue + 1, Self.maximum.rawValue))! }
    /// Clamps at `.minimum` — repeated taps once already zoomed all the way out are a no-op.
    func zoomedOutOneStep() -> Self { Self(rawValue: max(rawValue - 1, Self.minimum.rawValue))! }

    /// Maps a pre-2.4.0-widget-quality-pass raw value (the old 5-level scheme: `zoomedOutFar`...
    /// `zoomedInFar`, raw values 0...4) to its approximately equivalent level in this 9-level
    /// scheme — never a direct `Self(rawValue:)` reinterpretation, which would silently turn an
    /// existing user's old `.standard` (old raw value 2) into this scheme's `.zoomedOut2` (a
    /// real, different, already-zoomed-out level at raw value 2) purely by coincidence of the
    /// numbers lining up.
    ///
    /// Both schemes are odd-length (5 and 9), evenly spaced, and centered on `.standard`, so
    /// `newRawValue = oldRawValue * 2` exactly preserves each old level's relative position:
    /// old index 0 (max zoom out) -> new index 0 (max zoom out), old index 2 (standard) -> new
    /// index 4 (standard), old index 4 (max zoom in) -> new index 8 (max zoom in), with the two
    /// old intermediate steps landing on their proportionally equivalent new steps. `nil` for
    /// anything outside the old scheme's own valid 0...4 range, so a caller can fail closed to
    /// `.default` rather than guessing at a meaning that was never valid to begin with.
    static func migrated(fromLegacyRawValue legacyRawValue: Int) -> Self? {
        guard (0...4).contains(legacyRawValue) else { return nil }
        return Self(rawValue: legacyRawValue * 2)
    }
}

/// Persists the Large widget's zoom level in the App Group shared container so it survives
/// timeline regeneration and widget-process relaunches. Deliberately a single shared preference,
/// not per-widget-instance state: WidgetKit's `AppIntent`-based interactivity for a
/// `StaticConfiguration` widget has no per-instance identifier to key separate storage off of, and
/// a single Large-widget zoom preference is an explicitly acceptable model for 2.4.0.
nonisolated struct NearbyE85MapZoomStore {
    /// 85Blends 2.4.0 widget quality pass — a NEW key for the 9-level scheme, not a
    /// reinterpretation of the 5-level scheme's own `legacyKey` — see
    /// `NearbyE85MapZoomLevel.migrated(fromLegacyRawValue:)` for why reusing the same key with
    /// overlapping raw values would be ambiguous (ranges 0...4 mean two different things in the
    /// two schemes) rather than merely "old data in a new shape."
    static let key = "NearbyE85LargeWidgetZoomLevelV2"
    /// The 5-level scheme's key, from every TestFlight/App Store build before this pass. Only
    /// ever read (once, to migrate), never written again.
    static let legacyKey = "NearbyE85LargeWidgetZoomLevel"

    let defaults: UserDefaults?

    init(defaults: UserDefaults? = NearbyE85Configuration.appGroup.flatMap { UserDefaults(suiteName: $0) }) {
        self.defaults = defaults
    }

    /// Falls back to `.default` whenever the App Group is unavailable, nothing has been stored
    /// yet under either key, or a stored value is corrupted/out of range — never crashes, never
    /// zooms to something the user didn't choose. A legacy 5-level value, if found, is migrated
    /// via `NearbyE85MapZoomLevel.migrated(fromLegacyRawValue:)`, persisted under the new key,
    /// and the old key is cleared — so this migration happens at most once per install, and
    /// every later read (this session or a future one) hits the fast, direct path above it.
    func read() -> NearbyE85MapZoomLevel {
        guard let defaults else { return .default }
        if let raw = defaults.object(forKey: Self.key) as? Int, let level = NearbyE85MapZoomLevel(rawValue: raw) {
            return level
        }
        if let legacyRaw = defaults.object(forKey: Self.legacyKey) as? Int,
           let migrated = NearbyE85MapZoomLevel.migrated(fromLegacyRawValue: legacyRaw) {
            write(migrated)
            defaults.removeObject(forKey: Self.legacyKey)
            return migrated
        }
        return .default
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

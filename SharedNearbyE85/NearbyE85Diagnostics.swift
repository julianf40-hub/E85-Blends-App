import Foundation
import os

/// 85Blends 2.4.1 performance audit (Phase 2A) — lightweight, privacy-safe diagnostics shared
/// by the app and the widget extension. Every signpost/log call site that uses this is purely
/// observational: no return value, timing, or control-flow decision in NearbyE85Provider/
/// NearbyE85Cache/NearbyE85MapRenderer/the AppIntents depends on anything in this file, so
/// adding or removing a measurement point can never change what the widget shows or when it
/// refreshes. Intended to be inspected via Console.app/Instruments (subsystem below), not a
/// third-party analytics SDK and not an in-app debug screen.
///
/// PRIVACY — never log a coordinate, station name/address/id, price, ethanol reading, or
/// RevenueCat/subscription identifier here. Only counts, byte sizes, booleans, durations (via
/// signposts), and enum/case names are safe — check every new call site against this rule
/// before adding one.
nonisolated enum NearbyE85Diagnostics {
    static let subsystem = "com.e85blends.nearbyE85"
    static let logger = Logger(subsystem: subsystem, category: "Diagnostics")
    static let signposter = OSSignposter(subsystem: subsystem, category: "Performance")

    /// Starts a signpost interval for `name`; pair with `end(_:_:)`, typically via `defer` so
    /// the interval still closes on an early return or a thrown error.
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// One non-sensitive line at every call site that asks WidgetKit to reload the Nearby E85
    /// timeline — lets the gap between "a reload was requested" and "the provider actually ran"
    /// (WidgetKit's own budget decides that) be read back from Console/Instruments.
    static func logReloadRequested(source: StaticString) {
        logger.debug("NearbyE85 reload requested: source=\(source, privacy: .public)")
    }
}

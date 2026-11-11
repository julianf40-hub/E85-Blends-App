//
//  PausedPriceAlertsEntryTests.swift
//  EightyFiveBlendsTests
//
//  2.4.1: Station Price Alerts is paused, so its "Coming soon" / "Arrives in an upcoming Pro
//  update" promotional cards were removed from Stations and More. SwiftUI view composition has
//  no semantic seam to inspect without new dependencies, so this is a source-level guard that
//  asserts the teaser stays gone while Trip Planner and Advanced Fuel Analytics remain.
//
//  The view sources are copied into this test bundle at build time by the test target's
//  "Bundle Paused Price Alerts View Sources" Run Script phase, and read from the bundle here.
//  Reading them via #filePath failed on Xcode Cloud: #filePath is the build machine's checkout
//  path, which does not exist where the tests run. A missing bundled copy is a test failure.
//

import Foundation
import Testing

/// Locates this test bundle (Bundle(for:) needs a class).
private final class BundleToken {}

struct PausedPriceAlertsEntryTests {

    private struct SourceReadError: Error, CustomStringConvertible {
        let description: String
    }

    /// Hard ceiling on bytes read per file; the view sources are well under this.
    private static let maxSourceBytes = 4 * 1024 * 1024

    // Plain POSIX open/fstat/read with a finite byte cap. String(contentsOf:) stalled when the
    // Simulator-hosted bundle read host files, so this avoids Foundation file coordination.
    private static func appSource(_ fileName: String) throws -> String {
        guard let resources = Bundle(for: BundleToken.self).resourceURL else {
            throw SourceReadError(description: "test bundle has no resource directory")
        }
        let path = resources.appendingPathComponent("PausedPriceAlertsSources")
            .appendingPathComponent(fileName + ".txt").path

        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw SourceReadError(description: "open(\(path)) failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw SourceReadError(description: "fstat(\(path)) failed: \(String(cString: strerror(errno)))")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw SourceReadError(description: "\(path) is not a regular file")
        }
        guard info.st_size > 0, info.st_size <= maxSourceBytes else {
            throw SourceReadError(description: "\(path) size \(info.st_size) outside 1...\(maxSourceBytes) bytes")
        }

        let expected = Int(info.st_size)
        var bytes = [UInt8](repeating: 0, count: expected)
        var total = 0
        while total < expected {
            let n = bytes.withUnsafeMutableBytes { buffer in
                read(fd, buffer.baseAddress! + total, expected - total)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw SourceReadError(description: "read(\(path)) failed: \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            total += n
        }
        guard total == expected else {
            throw SourceReadError(description: "read(\(path)) returned \(total) of \(expected) bytes")
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw SourceReadError(description: "\(path) is not valid UTF-8")
        }
        return text
    }

    @Test("Stations no longer promotes Station Price Alerts, and keeps Trip Planner")
    func stationsHasNoPriceAlertsTeaser() throws {
        let source = try Self.appSource("StationsView.swift")
        #expect(!source.contains("StationAlertsView()"))
        #expect(!source.contains("title: \"Station Price Alerts\""))
        #expect(!source.contains("comingSoonSection"))
        #expect(source.contains("TripPlannerView()"))
    }

    @Test("More no longer promotes Station Price Alerts, and keeps Advanced Fuel Analytics and Trip Planner")
    func moreHasNoPriceAlertsTeaser() throws {
        let source = try Self.appSource("MoreView.swift")
        #expect(!source.contains("StationAlertsView()"))
        #expect(!source.contains("title: \"Station Price Alerts\""))
        #expect(source.contains("title: \"Advanced Fuel Analytics\""))
        #expect(source.contains("AdvancedAnalyticsView()"))
        #expect(source.contains("TripPlannerView()"))
    }
}

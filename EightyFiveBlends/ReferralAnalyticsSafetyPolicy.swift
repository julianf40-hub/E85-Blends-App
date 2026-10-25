//
//  ReferralAnalyticsSafetyPolicy.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — the single, immutable decision for whether this process may perform LIVE
//  referral-api or analytics writes. Two signals, both fixed for the lifetime of the process:
//
//    - The compile condition: an INTERNAL_BUILD binary never performs live referral/analytics
//      writes. There is deliberately NO user default, environment variable, launch argument, or
//      runtime switch that re-enables them — any such "allow" flag is ignored, not parsed.
//    - The app-host test signal: when XCTest has launched this app as a test host (any scheme or
//      configuration, including the default scheme's Debug TestAction), the process environment
//      carries XCTest's own launch keys from the very first instruction. This is read once, from
//      ProcessInfo, before any referral startup task is attached — never from a flag a test bundle
//      sets later in setUp.
//
//  Ordinary non-test, non-Internal builds (App Store Release, a Debug run from Xcode) are
//  unaffected: `allowsLiveWrites` is true there, exactly as before this policy existed.
//
//  Positive tests never go through a "bypass" of this policy. They use explicit per-instance
//  fake dependencies (see ReferralManager's test-double initializer) or a URLSession whose
//  protocol classes are defined in the .xctest bundle (see `isInterceptedTestSession(_:)`) —
//  neither of which can ever authorize a live default dependency.
//

import Foundation

nonisolated struct ReferralAnalyticsSafetyPolicy: Equatable, Sendable {
    let isInternalBuild: Bool
    let isHostedTestProcess: Bool

    var allowsLiveWrites: Bool {
        isInternalBuild == false && isHostedTestProcess == false
    }

    /// XCTest's own launch environment keys for an app-hosted test run. Presence of ANY of them
    /// marks the process as a test host; their values are never interpreted.
    static let hostedTestEnvironmentKeys: Set<String> = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCTestSessionIdentifier",
        "XCInjectBundleInto",
    ]

    /// Pure evaluation — deterministic for tests. Every key in `processEnvironment` other than
    /// `hostedTestEnvironmentKeys` is ignored, so an "allow production writes" style flag (absent,
    /// malformed, or set) can never change the result.
    static func evaluate(
        isInternalBuild: Bool,
        processEnvironment: [String: String]
    ) -> ReferralAnalyticsSafetyPolicy {
        let isHostedTestProcess = processEnvironment.keys.contains { hostedTestEnvironmentKeys.contains($0) }
        return ReferralAnalyticsSafetyPolicy(
            isInternalBuild: isInternalBuild,
            isHostedTestProcess: isHostedTestProcess
        )
    }

    static var isInternalBuildCompiled: Bool {
        #if INTERNAL_BUILD
        return true
        #else
        return false
        #endif
    }

    /// The live decision for this process — computed once, on first access, and immutable after.
    static let live: ReferralAnalyticsSafetyPolicy = evaluate(
        isInternalBuild: isInternalBuildCompiled,
        processEnvironment: ProcessInfo.processInfo.environment
    )

    #if DEBUG || INTERNAL_BUILD
    /// True only for a URLSession whose FIRST protocol class is defined in an .xctest bundle — i.e.
    /// every request is intercepted by a test URLProtocol before any system transport sees it.
    /// The default/shared sessions (system protocol classes only) can never satisfy this.
    static func isInterceptedTestSession(_ session: URLSession) -> Bool {
        guard let first = session.configuration.protocolClasses?.first else { return false }
        return Bundle(for: first).bundleURL.pathExtension == "xctest"
    }
    #endif
}

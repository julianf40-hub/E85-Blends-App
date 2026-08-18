//
//  CommunityReportCelebrationPresentation.swift
//  EightyFiveBlends
//
//  Pure decision/state logic behind the Community E85 Price Report celebration overlay
//  (CommunityReportSuccessOverlay). Kept independent of SwiftUI/SwiftData/networking — mirroring
//  CommunityPriceEligibility/WhatsNewPresentation/PumpStationContextResolver's separation of pure
//  rules from the views/functions that call them — so the actual rules StationsView depends on
//  are directly unit-testable. See EightyFiveBlendsTests/CommunityReportCelebrationPresentationTests.swift.
//

import Foundation

/// Whether a just-completed price-update submission should trigger the celebration overlay.
/// StationsView.savePriceUpdate(for:reportToCommunity:) calls this exactly once, inside the
/// MainActor.run block that runs after its community-submission Task either succeeds or fails —
/// never earlier in that async operation, and never for a submission that only ever intended to
/// save locally.
enum CommunityReportCelebrationDecision {
    /// - Parameters:
    ///   - reportToCommunity: Whether this submission was a "Save & Report" (as opposed to
    ///     "Save Locally"). A "Save Locally" submission never reaches the community-submission
    ///     Task at all in StationsView, but this parameter exists so that guarantee is an
    ///     explicit, directly-testable part of the rule rather than something only implied by
    ///     surrounding control flow.
    ///   - submissionSucceeded: Whether the remote community submission (community-station
    ///     upsert + price report POST) completed without throwing. Must reflect a submission that
    ///     has already finished — this function makes no attempt to look ahead or predict an
    ///     in-flight result.
    static func shouldCelebrate(reportToCommunity: Bool, submissionSucceeded: Bool) -> Bool {
        reportToCommunity && submissionSucceeded
    }
}

/// Pure present/dismiss transitions for the celebration's lifecycle. StationsView's
/// `@State private var communityReportCelebration` holds one of these; `presentCommunityReportSuccess()`
/// calls `present()` and `dismissCommunityReportSuccess()` calls `dismiss()` — the SwiftUI/Task
/// plumbing around timing (haptic, the 2s auto-dismiss Task, cancellation) lives in StationsView,
/// but the state transitions themselves live here where they can be exercised without a view.
struct CommunityReportCelebrationLifecycle: Equatable {
    private(set) var isPresented = false

    /// Total number of times `present()` has actually transitioned this into the presented
    /// state. Exists purely so "triggers only once per successful submission" is something a
    /// test can assert on directly: a full success flow calls `present()` exactly once.
    private(set) var presentationCount = 0

    mutating func present() {
        isPresented = true
        presentationCount += 1
    }

    mutating func dismiss() {
        isPresented = false
    }
}

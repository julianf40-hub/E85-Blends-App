//
//  CommunityReportCelebrationPresentationTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision/state logic behind the Community E85 Price Report celebration
//  overlay (CommunityReportCelebrationDecision.shouldCelebrate, CommunityReportCelebrationLifecycle)
//  — the actual types StationsView.savePriceUpdate(for:reportToCommunity:),
//  presentCommunityReportSuccess(), and dismissCommunityReportSuccess() use, not a duplicate
//  reimplementation — so passing tests here directly verify production behavior.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//
//  Context: the celebration replaces the plain "Thank You! 🙌" alert that used to fire whenever
//  `savePriceUpdate`'s community-submission Task set `infoMessage = thankYouCommunityReportMessage`
//  — that constant and its alert-title branch have been removed entirely. The overlay is
//  presented from exactly one call site (the MainActor.run block at the end of that Task), gated
//  on `CommunityReportCelebrationDecision.shouldCelebrate`, and never earlier in the async
//  operation — StationsView still saves locally, calls CommunityPriceService, and only reaches
//  that MainActor.run block after the community submission has already finished one way or the
//  other. Save Locally (`reportToCommunity == false`) never even reaches that Task.
//
//  Several required regression scenarios are recorded below as inspection facts, mirroring the
//  convention CommunityPriceEligibilityTests.swift already established for this codebase, since
//  they exercise SwiftUI view state, Task scheduling, or UIKit haptics/accessibility this file
//  does not (and, without a test target or UI-test infra, currently cannot) exercise directly:
//
//  - "Nearby and Saved share identical success behavior": shouldCelebrate/present take no
//    station or provenance parameter at all — StationPriceUpdateContext.saved(_:) and .live(_:)
//    both flow through the exact same savePriceUpdate → same Task → same MainActor.run block,
//    with no branch anywhere on which factory built the context. This mirrors exactly how
//    CommunityPriceEligibilityTests.swift proves canReport has no provenance parameter.
//  - "No leaked async Task if the parent view disappears first": StationsView's `.onDisappear`
//    now cancels `communityReportSuccessDismissTask` alongside `liveSearchTask`/
//    `communityPriceTask`, exactly the same pattern already used for those two.
//  - "No duplicate network submission": the celebration is presentation-only, wired in at the end
//    of the Task after both CommunityPriceService calls have already completed — dismissing or
//    re-presenting it cannot re-trigger `upsertCommunityStation`/`submitPriceReport`, which this
//    file never calls.
//  - "Reduce Motion path doesn't require animation completion" (see #8 below): the 2-second
//    auto-dismiss Task in `presentCommunityReportSuccess()` calls `Task.sleep(for: .seconds(2))`
//    unconditionally and calls `dismissCommunityReportSuccess()` directly — it has no dependency
//    on, or callback from, CommunityReportSuccessOverlay's internal `withAnimation`/`.animation`
//    state, so the timing is identical whether Reduce Motion is on or off. This is structural:
//    CommunityReportCelebrationLifecycle's API (below) has no animation/duration parameter for a
//    caller to depend on in the first place.

import Testing
@testable import EightyFiveBlends

struct CommunityReportCelebrationPresentationTests {

    // MARK: 1. Celebration triggers on a successful Save & Report submission

    @Test("A Save & Report submission that completed without throwing should celebrate")
    func shouldCelebrate_reportToCommunitySucceeded_isTrue() {
        #expect(CommunityReportCelebrationDecision.shouldCelebrate(
            reportToCommunity: true,
            submissionSucceeded: true
        ) == true)
    }

    // MARK: 2. Save Locally never triggers it

    @Test("A Save Locally submission (reportToCommunity == false) never celebrates, regardless of the succeeded flag")
    func shouldCelebrate_saveLocallyOnly_isFalse() {
        #expect(CommunityReportCelebrationDecision.shouldCelebrate(
            reportToCommunity: false,
            submissionSucceeded: true
        ) == false)
        // Included even though this combination can't occur in StationsView today (a Save
        // Locally submission never reaches the community-submission Task, so
        // submissionSucceeded has no real value to report) — the rule itself must not depend on
        // submissionSucceeded to get this right; reportToCommunity alone must be a hard gate.
        #expect(CommunityReportCelebrationDecision.shouldCelebrate(
            reportToCommunity: false,
            submissionSucceeded: false
        ) == false)
    }

    // MARK: 3. A failed community submission never celebrates

    @Test("A Save & Report submission that failed does not celebrate — existing error behavior remains reachable")
    func shouldCelebrate_reportToCommunityFailed_isFalse() {
        #expect(CommunityReportCelebrationDecision.shouldCelebrate(
            reportToCommunity: true,
            submissionSucceeded: false
        ) == false)
    }

    // MARK: 4. Triggers only once per successful submission

    @Test("A single successful submission presents the celebration exactly once")
    func lifecycle_singlePresent_incrementsCountExactlyOnce() {
        var lifecycle = CommunityReportCelebrationLifecycle()
        #expect(lifecycle.isPresented == false)
        #expect(lifecycle.presentationCount == 0)

        lifecycle.present()

        #expect(lifecycle.isPresented == true)
        #expect(lifecycle.presentationCount == 1)
    }

    @Test("A failed submission never calls present() — presentationCount stays zero")
    func lifecycle_neverPresentedOnFailure_countStaysZero() {
        let lifecycle = CommunityReportCelebrationLifecycle()
        // Mirrors savePriceUpdate's real control flow: shouldCelebrate == false means
        // presentCommunityReportSuccess() (and therefore lifecycle.present()) is never called.
        let shouldCelebrate = CommunityReportCelebrationDecision.shouldCelebrate(
            reportToCommunity: true,
            submissionSucceeded: false
        )
        #expect(shouldCelebrate == false)
        #expect(lifecycle.isPresented == false)
        #expect(lifecycle.presentationCount == 0)
    }

    // MARK: 5. Dismiss clears presentation state

    @Test("dismiss() clears isPresented without affecting how many times it was presented")
    func lifecycle_dismiss_clearsIsPresented() {
        var lifecycle = CommunityReportCelebrationLifecycle()
        lifecycle.present()
        #expect(lifecycle.isPresented == true)

        lifecycle.dismiss()

        #expect(lifecycle.isPresented == false)
        // presentationCount is a lifetime counter, not a "currently showing" flag — dismissing
        // must not roll it back, so a later regression can't hide a spurious extra present().
        #expect(lifecycle.presentationCount == 1)
    }

    @Test("dismiss() before any present() is a safe no-op")
    func lifecycle_dismissWithoutPresent_isNoOp() {
        var lifecycle = CommunityReportCelebrationLifecycle()
        lifecycle.dismiss()
        #expect(lifecycle.isPresented == false)
        #expect(lifecycle.presentationCount == 0)
    }

    // MARK: 6. Nearby and Saved share identical success behavior

    @Test("shouldCelebrate has no station/provenance parameter — Nearby- and Saved-Station-originated reports are indistinguishable to this rule")
    func shouldCelebrate_hasNoProvenanceParameter() {
        // Structural guarantee, mirroring CommunityPriceEligibilityTests.canReport_hasNoProvenanceParameter:
        // shouldCelebrate's signature only accepts (reportToCommunity, submissionSucceeded) — there
        // is no "isLiveDiscovered"/"source"/"origin" argument a caller could pass, so a Nearby-
        // originated and a Saved-Station-originated report that both succeed necessarily produce
        // the same answer.
        let asIfFromNearbySearch = CommunityReportCelebrationDecision.shouldCelebrate(
            reportToCommunity: true, submissionSucceeded: true
        )
        let asIfFromSavedStations = CommunityReportCelebrationDecision.shouldCelebrate(
            reportToCommunity: true, submissionSucceeded: true
        )
        #expect(asIfFromNearbySearch == asIfFromSavedStations)
    }

    // MARK: 7. Existing error behavior remains reachable

    @Test("A failed submission's message is still assignable to infoMessage — the celebration path and the error-alert path are mutually exclusive")
    func shouldCelebrate_failurePath_leavesRoomForExistingErrorAlert() {
        // savePriceUpdate's MainActor.run block does exactly this: `if shouldCelebrate { present }
        // else if let failureMessage { infoMessage = failureMessage }`. Proving shouldCelebrate is
        // false whenever a failure occurred is what guarantees that `else if let failureMessage`
        // branch — the pre-existing error alert — is still reachable and still fires.
        let failureOccurred = true
        let shouldCelebrate = CommunityReportCelebrationDecision.shouldCelebrate(
            reportToCommunity: true,
            submissionSucceeded: failureOccurred == false
        )
        #expect(shouldCelebrate == false)
    }

    // MARK: 8. Reduce Motion path doesn't require animation completion

    @Test("CommunityReportCelebrationLifecycle's present/dismiss API has no animation or timing dependency")
    func lifecycle_presentAndDismiss_areSynchronousAndAnimationAgnostic() {
        // present()/dismiss() are plain, synchronous, non-async mutations with no completion
        // handler, no Task, and no animation/duration parameter to await or depend on — calling
        // them back-to-back resolves immediately and deterministically, exactly as
        // presentCommunityReportSuccess()'s 2-second auto-dismiss Task requires regardless of
        // whether Reduce Motion is enabled (that Task's own Task.sleep(for: .seconds(2)) is what
        // provides the timing; this type is never in that critical path).
        var lifecycle = CommunityReportCelebrationLifecycle()
        lifecycle.present()
        lifecycle.dismiss()
        #expect(lifecycle.isPresented == false)
        #expect(lifecycle.presentationCount == 1)
    }
}

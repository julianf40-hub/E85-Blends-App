//
//  FeaturedCarouselMetricsTests.swift
//  EightyFiveBlendsTests
//
//  Pins the sizing rule behind the Recommended Gear carousel (`FeaturedCarouselMetrics` in
//  RecommendedGearView.swift). The two pages have very different natural heights (the eFlexFuel card
//  is far shorter than the RVP gallery card), and the carousel used to step to the snapped page's
//  height only once the next card had almost reached the edge, which clipped the taller card
//  mid-swipe and then made the height jump. These tests hold the replacement rule: the height follows
//  the swipe's progress, is exactly each page's own height when that page is settled (or within a
//  few points of it), is never shorter than the shorter page, never jumps, and behaves the same in
//  both swipe directions.
//
//  Pure arithmetic only: no SwiftUI, no scrolling. That the real scroll view reports the measurements
//  these functions take (page leading edges and heights) is a device check, not something this file
//  can prove.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct FeaturedCarouselMetricsTests {

    // Representative geometry: a 343pt page spacing (card width plus the 24pt gap) and the 16pt
    // content margin the settled page's leading edge sits at.
    private static let spacing: CGFloat = 343
    private static let margin: CGFloat = 16

    // eFlexFuel-like short page and RVP-like tall page.
    private static let short: CGFloat = 250
    private static let tall: CGFloat = 700

    private func isClose(_ a: CGFloat?, _ b: CGFloat, tolerance: CGFloat = 1e-9) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tolerance
    }

    /// Leading edges of two pages when the scroll view has moved `offset` points from rest.
    private func edges(offset: CGFloat) -> [CGFloat?] {
        [Self.margin - offset, Self.margin + Self.spacing - offset]
    }

    // MARK: - Progress from measured edges

    @Test("Page 1 settled is progress 0, page 2 settled is progress 1, halfway is 0.5")
    func progress_atRestAndSettledAndHalfway() {
        #expect(isClose(FeaturedCarouselMetrics.progress(pageMinX: edges(offset: 0), restingMinX: Self.margin), 0))
        #expect(isClose(FeaturedCarouselMetrics.progress(pageMinX: edges(offset: Self.spacing), restingMinX: Self.margin), 1))
        #expect(isClose(FeaturedCarouselMetrics.progress(pageMinX: edges(offset: Self.spacing / 2), restingMinX: Self.margin), 0.5))
    }

    @Test("Progress rises steadily with the scroll offset, one swipe direction and the other")
    func progress_isMonotonicInBothDirections() {
        let offsets = stride(from: CGFloat(0), through: Self.spacing, by: 7)
        let forward = offsets.map { FeaturedCarouselMetrics.progress(pageMinX: edges(offset: $0), restingMinX: Self.margin) ?? -1 }
        #expect(forward == forward.sorted())
        #expect(forward.first == 0)
        #expect(forward.last == 1)   // 343 = 49 x 7, so the last sample is the settled second page
        #expect(Array(forward.reversed()) == forward.sorted(by: >))
    }

    @Test("Rubber-banding past either end clamps to the first and last page")
    func progress_clampsOverscroll() {
        #expect(FeaturedCarouselMetrics.progress(pageMinX: edges(offset: -60), restingMinX: Self.margin) == 0)
        #expect(FeaturedCarouselMetrics.progress(pageMinX: edges(offset: Self.spacing + 60), restingMinX: Self.margin) == 1)
    }

    @Test("A snap that lands one margin off (page at x = 0 instead of 16) still reads as fully settled")
    func progress_toleratesMarginMisalignment() {
        let settledAtZero: [CGFloat?] = [-Self.spacing, 0]
        #expect(FeaturedCarouselMetrics.progress(pageMinX: settledAtZero, restingMinX: Self.margin) == 1)
    }

    @Test("Missing, partial, degenerate or non-finite measurements give no progress")
    func progress_missingMeasurements() {
        #expect(FeaturedCarouselMetrics.progress(pageMinX: [], restingMinX: Self.margin) == nil)
        #expect(FeaturedCarouselMetrics.progress(pageMinX: [nil, nil], restingMinX: Self.margin) == nil)
        #expect(FeaturedCarouselMetrics.progress(pageMinX: [16, nil], restingMinX: Self.margin) == nil)
        #expect(FeaturedCarouselMetrics.progress(pageMinX: [nil, 359], restingMinX: Self.margin) == nil)
        #expect(FeaturedCarouselMetrics.progress(pageMinX: [16, 16], restingMinX: Self.margin) == nil)        // no spacing to scale by
        #expect(FeaturedCarouselMetrics.progress(pageMinX: [359, 16], restingMinX: Self.margin) == nil)       // out of order
        #expect(FeaturedCarouselMetrics.progress(pageMinX: [.nan, 359], restingMinX: Self.margin) == nil)
        #expect(FeaturedCarouselMetrics.progress(pageMinX: [16, .infinity], restingMinX: Self.margin) == nil)
        #expect(FeaturedCarouselMetrics.progress(pageMinX: [16, 359], restingMinX: .nan) == nil)
    }

    @Test("A single page is always progress 0")
    func progress_singlePage() {
        #expect(FeaturedCarouselMetrics.progress(pageMinX: [16], restingMinX: Self.margin) == 0)
        #expect(FeaturedCarouselMetrics.progress(pageMinX: [-200], restingMinX: Self.margin) == 0)
    }

    // MARK: - Height at a progress

    @Test("Each settled page gets exactly its own height")
    func height_settledPagesKeepTheirNaturalHeight() {
        let heights: [CGFloat?] = [Self.short, Self.tall]
        #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 0) == Self.short)
        #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 1) == Self.tall)
    }

    @Test("Two unequal pages: the height eases from the shorter page to the taller one")
    func height_unequalPages_shortToTall() {
        let heights: [CGFloat?] = [Self.short, Self.tall]
        // The ramp runs between the settle zones (0.05 ... 0.95): t = (progress - 0.05) / 0.9, the
        // distance from the taller page is d = 1 - t, and height = 700 - 450 * d^2.
        #expect(isClose(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 0.25), 3850.0 / 9))   // t = 2/9
        #expect(isClose(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 0.5), 587.5))         // t = 1/2
        #expect(isClose(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 0.75), 6100.0 / 9))   // t = 7/9
    }

    @Test("Swiping the other way (tall page first) gives the mirrored heights")
    func height_unequalPages_tallToShort() {
        let heights: [CGFloat?] = [Self.tall, Self.short]
        #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 0) == Self.tall)
        #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 1) == Self.short)
        #expect(isClose(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 0.25), 6100.0 / 9))
        #expect(isClose(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 0.5), 587.5))
        #expect(isClose(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 0.75), 3850.0 / 9))
    }

    @Test("Within the settle zone of a page the carousel is exactly that page's height, then the ramp starts")
    func height_settleZone() {
        let tolerance = FeaturedCarouselMetrics.settleTolerance
        #expect(tolerance == 0.05)
        for heights: [CGFloat?] in [[Self.short, Self.tall], [Self.tall, Self.short]] {
            let first = heights[0]!, second = heights[1]!
            for progress: CGFloat in [0, 0.01, 0.03, tolerance] {
                #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: progress) == first)
                #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 1 - progress) == second)
            }
            // Just past the zone the ramp has barely begun: no jump at the edge of the zone.
            let justPast = FeaturedCarouselMetrics.height(pageHeights: heights, progress: tolerance + 0.0001) ?? -1
            #expect(abs(justPast - first) < 1)
            let justBefore = FeaturedCarouselMetrics.height(pageHeights: heights, progress: 1 - tolerance - 0.0001) ?? -1
            #expect(abs(justBefore - second) < 1)
        }
    }

    @Test("A settled page is its own height even when its neighbor has not been measured")
    func height_settleZoneNeedsOnlyThePageItself() {
        #expect(FeaturedCarouselMetrics.height(pageHeights: [Self.short, nil], progress: 0.03) == Self.short)
        #expect(FeaturedCarouselMetrics.height(pageHeights: [nil, Self.tall], progress: 0.97) == Self.tall)
        #expect(FeaturedCarouselMetrics.height(pageHeights: [Self.short, nil], progress: 0.97) == nil)
        #expect(FeaturedCarouselMetrics.height(pageHeights: [nil, Self.tall], progress: 0.03) == nil)
    }

    @Test("The same distance from the tall page gives the same height whichever page it is (both directions agree)")
    func height_isSymmetricBetweenDirections() {
        for step in 0...100 {
            let progress = CGFloat(step) / 100
            let shortFirst = FeaturedCarouselMetrics.height(pageHeights: [Self.short, Self.tall], progress: progress)
            let tallFirst = FeaturedCarouselMetrics.height(pageHeights: [Self.tall, Self.short], progress: 1 - progress)
            #expect(isClose(shortFirst, tallFirst ?? -1))
        }
    }

    @Test("Short to tall never shrinks, tall to short never grows, and it stays between the two page heights")
    func height_isMonotonicAndBounded() {
        let samples = (0...200).map { CGFloat($0) / 200 }

        let growing = samples.compactMap { FeaturedCarouselMetrics.height(pageHeights: [Self.short, Self.tall], progress: $0) }
        #expect(growing.count == samples.count)
        #expect(growing == growing.sorted())

        let shrinking = samples.compactMap { FeaturedCarouselMetrics.height(pageHeights: [Self.tall, Self.short], progress: $0) }
        #expect(shrinking == shrinking.sorted(by: >))

        // The shorter page is never cut, and nothing is ever taller than the tallest page.
        #expect((growing + shrinking).allSatisfy { $0 >= Self.short && $0 <= Self.tall })
    }

    @Test("Interrupting and reversing a swipe midway retraces the same heights (no hysteresis)")
    func height_isPathIndependent() {
        let heights: [CGFloat?] = [Self.short, Self.tall]
        let positions: [CGFloat] = [0, 0.1, 0.25, 0.4, 0.5, 0.6, 0.75, 0.9, 1]
        // Swipe forward to 0.6, turn around and come back, then go on to the end.
        let path: [CGFloat] = [0, 0.1, 0.25, 0.4, 0.5, 0.6, 0.5, 0.4, 0.25, 0.1, 0, 0.1, 0.25, 0.4, 0.5, 0.6, 0.75, 0.9, 1]
        let byPosition = Dictionary(uniqueKeysWithValues: positions.map { ($0, FeaturedCarouselMetrics.height(pageHeights: heights, progress: $0)) })
        for position in path {
            #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: position) == byPosition[position]!)
        }
    }

    @Test("No jump: adjacent samples never differ by more than the easing's bounded slope")
    func height_neverJumps() {
        let step: CGFloat = 0.001
        let range = Self.tall - Self.short
        // |d(d^k)/dd| <= k, and the ramp is stretched over (1 - 2 * settleTolerance) of the swipe.
        let maxStep = range * FeaturedCarouselMetrics.easeExponent * step / (1 - 2 * FeaturedCarouselMetrics.settleTolerance) + 1e-6
        var previous = FeaturedCarouselMetrics.height(pageHeights: [Self.short, Self.tall], progress: 0) ?? -1
        for index in 1...1000 {
            let current = FeaturedCarouselMetrics.height(pageHeights: [Self.short, Self.tall], progress: CGFloat(index) * step) ?? -1
            #expect(abs(current - previous) <= maxStep, "jump of \(abs(current - previous))pt at progress \(CGFloat(index) * step)")
            previous = current
        }
    }

    @Test("Equal-height pages never change height")
    func height_equalHeightPages() {
        for step in 0...20 {
            #expect(FeaturedCarouselMetrics.height(pageHeights: [400, 400], progress: CGFloat(step) / 20) == 400)
        }
    }

    @Test("Progress outside the pages clamps to the first or last page; non-finite progress gives nothing")
    func height_clampsAndRejectsBadProgress() {
        let heights: [CGFloat?] = [Self.short, Self.tall]
        #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: -3) == Self.short)
        #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 9) == Self.tall)
        #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: .nan) == nil)
        #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: .infinity) == nil)
    }

    @Test("Before the first measurement there is no height, and one missing page is enough to give none")
    func height_missingMeasurements() {
        #expect(FeaturedCarouselMetrics.height(pageHeights: [], progress: 0) == nil)
        #expect(FeaturedCarouselMetrics.height(pageHeights: [nil, nil], progress: 0) == nil)
        #expect(FeaturedCarouselMetrics.height(pageHeights: [Self.short, nil], progress: 0.5) == nil)
        #expect(FeaturedCarouselMetrics.height(pageHeights: [nil, Self.tall], progress: 0.5) == nil)
        // Mid-swipe needs both pages; a settled page needs only itself.
        #expect(FeaturedCarouselMetrics.height(pageHeights: [Self.short, nil], progress: 0) == Self.short)
        #expect(FeaturedCarouselMetrics.height(pageHeights: [nil, Self.tall], progress: 1) == Self.tall)
        #expect(FeaturedCarouselMetrics.height(pageHeights: [nil, Self.tall], progress: 0) == nil)
    }

    @Test("A zero, negative or non-finite height is treated as missing, never used to collapse the carousel")
    func height_unusableHeightsAreMissing() {
        for bad: CGFloat in [0, -10, .nan, .infinity] {
            #expect(FeaturedCarouselMetrics.height(pageHeights: [bad, Self.tall], progress: 0.5) == nil)
            #expect(FeaturedCarouselMetrics.height(pageHeights: [Self.short, bad], progress: 0.5) == nil)
        }
    }

    @Test("Three pages interpolate between the two being swiped")
    func height_threePages() {
        let heights: [CGFloat?] = [Self.short, Self.tall, 400]
        #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 1) == Self.tall)
        #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 2) == 400)
        #expect(isClose(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 1.5), 625))   // 700 - 300 * 0.5^2
        #expect(FeaturedCarouselMetrics.height(pageHeights: heights, progress: 2.5) == 400)          // clamped
    }

    @Test("Larger text scales every height together: the same swipe gives proportionally larger heights")
    func height_scalesWithDynamicType() {
        for scale in [CGFloat(1.0), 1.3, 1.6, 2.4] {
            let scaled: [CGFloat?] = [Self.short * scale, Self.tall * scale]
            for step in 0...10 {
                let progress = CGFloat(step) / 10
                let base = FeaturedCarouselMetrics.height(pageHeights: [Self.short, Self.tall], progress: progress) ?? -1
                #expect(isClose(FeaturedCarouselMetrics.height(pageHeights: scaled, progress: progress), base * scale, tolerance: 1e-6))
            }
        }
    }

    @Test("Mid-swipe the carousel stays closer to the taller page than a linear blend would")
    func easing_staysNearTheTallerPage() {
        #expect(FeaturedCarouselMetrics.easeExponent == 2)
        let eased = FeaturedCarouselMetrics.height(pageHeights: [Self.short, Self.tall], progress: 0.5) ?? -1
        let linear = (Self.short + Self.tall) / 2
        #expect(eased > linear)
    }

    // MARK: - What the screen uses

    @Test("VoiceOver sizes the carousel to its natural height, whatever has been measured")
    func carouselHeight_voiceOverUsesNaturalHeight() {
        let heights: [CGFloat?] = [Self.short, Self.tall]
        #expect(FeaturedCarouselMetrics.carouselHeight(pageHeights: heights, progress: 0.5, selectedIndex: 0, voiceOverEnabled: true) == nil)
        #expect(FeaturedCarouselMetrics.carouselHeight(pageHeights: heights, progress: nil, selectedIndex: 1, voiceOverEnabled: true) == nil)
        #expect(FeaturedCarouselMetrics.carouselHeight(pageHeights: heights, progress: 0.5, selectedIndex: 0, voiceOverEnabled: false) != nil)
    }

    @Test("Without usable progress the carousel follows the snapped page, as it did before")
    func carouselHeight_fallsBackToTheSnappedPage() {
        let heights: [CGFloat?] = [Self.short, Self.tall]
        #expect(FeaturedCarouselMetrics.carouselHeight(pageHeights: heights, progress: nil, selectedIndex: 0, voiceOverEnabled: false) == Self.short)
        #expect(FeaturedCarouselMetrics.carouselHeight(pageHeights: heights, progress: nil, selectedIndex: 1, voiceOverEnabled: false) == Self.tall)
    }

    @Test("Initially nothing is measured, so the carousel keeps its natural height")
    func carouselHeight_initialStateIsNaturalHeight() {
        #expect(FeaturedCarouselMetrics.carouselHeight(pageHeights: [], progress: nil, selectedIndex: 0, voiceOverEnabled: false) == nil)
        #expect(FeaturedCarouselMetrics.carouselHeight(pageHeights: [nil, nil], progress: 0, selectedIndex: 0, voiceOverEnabled: false) == nil)
    }

    @Test("A measurement that never moved while the page changed is rejected; any real movement is trusted")
    func hasFollowedScroll_rejectsOnlyAProgressThatNeverMoved() {
        // Stuck at the first page (for example a coordinate space that scrolls with the content).
        #expect(FeaturedCarouselMetrics.hasFollowedScroll(furthestProgress: 0) == false)
        #expect(FeaturedCarouselMetrics.hasFollowedScroll(furthestProgress: FeaturedCarouselMetrics.movementThreshold) == false)
        // A quick flick can change the snapped page early in the swipe, so a small movement is enough.
        #expect(FeaturedCarouselMetrics.hasFollowedScroll(furthestProgress: 0.01))
        #expect(FeaturedCarouselMetrics.hasFollowedScroll(furthestProgress: 0.3))
        #expect(FeaturedCarouselMetrics.hasFollowedScroll(furthestProgress: 1))
    }
}

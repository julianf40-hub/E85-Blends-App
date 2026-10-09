//
//  FeaturedOfferCopyTests.swift
//  EightyFiveBlendsTests
//
//  Pins two pure pieces behind the eFlexFuel card (RecommendedGearView.swift):
//
//  - `FeaturedOfferCopyFeedback`, the "Copied" feedback after Copy Code is tapped. It is a value type
//    with no knowledge of the pasteboard or of any website link, so these tests also show that the
//    feedback can only ever follow a copy: nothing else (opening the site included) can start it, and
//    a stale expiry can never clear a newer tap's feedback.
//  - `FeaturedWordmarkLayout`, the width rules for the official wordmark on the More card.
//
//  That Copy Code really writes E85BLENDS to the pasteboard only when tapped, and that it and the
//  shop buttons are separate Buttons (none nested in another), is a property of the SwiftUI view and
//  is checked by reading it and on a device, not here.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct FeaturedOfferCopyTests {

    private func isClose(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    // MARK: - Copied feedback

    @Test("Nothing shows Copied until Copy Code has been tapped")
    func feedback_startsIdle() {
        let feedback = FeaturedOfferCopyFeedback()
        #expect(feedback.isCopied == false)
    }

    @Test("Tapping Copy Code shows Copied, and its own expiry clears it")
    func feedback_copyThenExpire() {
        var feedback = FeaturedOfferCopyFeedback()
        let token = feedback.didCopy()
        #expect(feedback.isCopied)

        feedback.expire(token: token)
        #expect(feedback.isCopied == false)
    }

    @Test("An expiry with no copy behind it does nothing")
    func feedback_expireWithoutCopyIsInert() {
        var feedback = FeaturedOfferCopyFeedback()
        feedback.expire(token: 1)
        #expect(feedback.isCopied == false)
        #expect(feedback == FeaturedOfferCopyFeedback())
    }

    @Test("A second tap restarts the feedback, and the first tap's late expiry cannot cut it short")
    func feedback_staleExpiryDoesNotClearANewerCopy() {
        var feedback = FeaturedOfferCopyFeedback()
        let first = feedback.didCopy()
        let second = feedback.didCopy()
        #expect(first != second)

        feedback.expire(token: first)
        #expect(feedback.isCopied, "The first tap's expiry arrived after the second tap")

        feedback.expire(token: second)
        #expect(feedback.isCopied == false)
    }

    @Test("Once expired, the same token cannot do anything, and a new tap starts fresh feedback")
    func feedback_expiredTokenIsInertAndNewTapRestarts() {
        var feedback = FeaturedOfferCopyFeedback()
        let first = feedback.didCopy()
        feedback.expire(token: first)

        let second = feedback.didCopy()
        #expect(feedback.isCopied)
        feedback.expire(token: first)
        #expect(feedback.isCopied, "A spent token must not clear the new feedback")
        feedback.expire(token: second)
        #expect(feedback.isCopied == false)
    }

    // MARK: - More card wordmark width

    @Test("The More wordmark is 55% of the container on common iPhone widths, inside the 190-225pt range")
    func wordmark_scalesWithTheContainer() {
        #expect(isClose(FeaturedWordmarkLayout.moreWidth(containerWidth: 375), 206.25))
        #expect(isClose(FeaturedWordmarkLayout.moreWidth(containerWidth: 390), 214.5))
        #expect(isClose(FeaturedWordmarkLayout.moreWidth(containerWidth: 393), 216.15))
        #expect(isClose(FeaturedWordmarkLayout.moreWidth(containerWidth: 402), 221.1))
        #expect(FeaturedWordmarkLayout.moreWidthRange == 190...225)
    }

    @Test("It stops shrinking on the narrowest layouts and stops growing on the widest")
    func wordmark_isClamped() {
        #expect(FeaturedWordmarkLayout.moreWidth(containerWidth: 320) == 190)
        #expect(FeaturedWordmarkLayout.moreWidth(containerWidth: 200) == 190)
        #expect(FeaturedWordmarkLayout.moreWidth(containerWidth: 430) == 225)
        #expect(FeaturedWordmarkLayout.moreWidth(containerWidth: 1024) == 225)
        #expect(FeaturedWordmarkLayout.moreWidth(containerWidth: 1366) == 225)
    }

    @Test("A wider container never gets a smaller wordmark, and every width stays within the range")
    func wordmark_isMonotonicAndBounded() {
        let widths = stride(from: CGFloat(100), through: 1400, by: 1)
        let wordmarks = widths.map { FeaturedWordmarkLayout.moreWidth(containerWidth: $0) }
        #expect(wordmarks == wordmarks.sorted())
        #expect(wordmarks.allSatisfy { FeaturedWordmarkLayout.moreWidthRange.contains($0) })
    }

    @Test("A container with no usable width gets the smallest wordmark, never zero, negative or NaN")
    func wordmark_badInput() {
        for width: CGFloat in [0, -50, .nan, .infinity, -.infinity] {
            #expect(FeaturedWordmarkLayout.moreWidth(containerWidth: width) == FeaturedWordmarkLayout.moreWidthRange.lowerBound)
        }
    }

    @Test("The Recommended Gear wordmark is capped so it does not dwarf the copy")
    func wordmark_cardCap() {
        #expect(FeaturedWordmarkLayout.cardMaxWidth > FeaturedWordmarkLayout.moreWidthRange.upperBound)
        #expect(FeaturedWordmarkLayout.cardMaxWidth <= 300)
    }
}

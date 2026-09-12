import UIKit
import XCTest
@testable import EightyFiveBlends

@MainActor
final class NativeAdTextLayoutTests: XCTestCase {
    func testBodyAllowsNinetyCharactersAtProductionWidth() {
        let text = String(
            "The Google Ads mobile app helps you stay connected to your campaigns while on the go. Extra"
                .prefix(90)
        )
        XCTAssertEqual(text.count, 90)

        let label = UILabel()
        NativeAdTextLayout.configureBody(label)
        NativeAdTextLayout.applyBodyLayoutWidth(335, to: label)
        label.text = text

        let requiredSize = label.sizeThatFits(
            CGSize(width: 335, height: CGFloat.greatestFiniteMagnitude)
        )
        let renderedLineCount = Int(ceil(requiredSize.height / label.font.lineHeight))

        XCTAssertEqual(label.preferredMaxLayoutWidth, 335)
        XCTAssertLessThanOrEqual(renderedLineCount, NativeAdTextLayout.bodyLineLimit)
    }

    func testHeadlineAllowsTwentyFiveCharactersWithoutChangingItsLayoutPolicy() {
        let text = "Test mode: Google Ads Now"
        XCTAssertEqual(text.count, 25)

        let label = UILabel()
        NativeAdTextLayout.configureHeadline(label)
        label.text = text

        // 285pt is the measured headline width in the matched iOS 27 control run after the
        // production 40pt icon and 10pt header spacing are removed from the 335pt ad width.
        let requiredSize = label.sizeThatFits(
            CGSize(width: 285, height: CGFloat.greatestFiniteMagnitude)
        )
        let renderedLineCount = Int(ceil(requiredSize.height / label.font.lineHeight))

        XCTAssertEqual(label.preferredMaxLayoutWidth, 0)
        XCTAssertLessThanOrEqual(renderedLineCount, NativeAdTextLayout.headlineLineLimit)
    }
}

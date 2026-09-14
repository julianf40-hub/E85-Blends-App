import UIKit
import XCTest
@testable import EightyFiveBlends

@MainActor
final class NativeAdTextLayoutTests: XCTestCase {
    // A 375-point iPhone viewport yields a 307-point native-ad root after the screen's 16-point
    // horizontal padding and AppCard's 18-point inset on each side. The other values represent
    // the current 403- and 430-point production iPhone classes through the same layout path.
    private let productionRootWidths: [CGFloat] = [307, 335, 362]

    private let dynamicTypeCategories: [UIContentSizeCategory] = [
        .large,
        .extraExtraExtraLarge,
        .accessibilityExtraExtraExtraLarge,
    ]

    func testBodyAllowsNinetyWideGlyphCharactersAtSupportedWidthsAndDynamicType() {
        // Exercise the full character budget with wide glyphs, without reducing the stress
        // by filling half of that budget with spaces.
        let text = String(repeating: "W", count: 90)
        XCTAssertEqual(text.count, 90)

        for category in dynamicTypeCategories {
            UITraitCollection(preferredContentSizeCategory: category).performAsCurrent {
                for width in productionRootWidths {
                    let label = UILabel()
                    NativeAdTextLayout.configureBody(label)
                    NativeAdTextLayout.applyBodyLayoutWidth(width, to: label)
                    label.text = text

                    let requiredLineCount = unrestrictedLineCount(for: label, width: width)

                    XCTAssertEqual(label.preferredMaxLayoutWidth, width)
                    XCTAssertLessThanOrEqual(
                        requiredLineCount,
                        NativeAdTextLayout.bodyLineLimit,
                        "90 wide-glyph characters require \(requiredLineCount) lines at "
                            + "\(width)pt / \(category.rawValue)"
                    )
                }
            }
        }
    }

    func testHeadlineAllowsTwentyFiveCharactersAtSupportedWidthsAndDynamicType() {
        let text = String(repeating: "W", count: 25)
        XCTAssertEqual(text.count, 25)

        for category in dynamicTypeCategories {
            UITraitCollection(preferredContentSizeCategory: category).performAsCurrent {
                for rootWidth in productionRootWidths {
                    let headlineWidth = rootWidth - 40 - 10
                    let label = UILabel()
                    NativeAdTextLayout.configureHeadline(label)
                    label.text = text

                    let requiredLineCount = unrestrictedLineCount(
                        for: label,
                        width: headlineWidth
                    )

                    XCTAssertEqual(label.preferredMaxLayoutWidth, 0)
                    XCTAssertLessThanOrEqual(
                        requiredLineCount,
                        NativeAdTextLayout.headlineLineLimit,
                        "25-character headline requires \(requiredLineCount) lines at "
                            + "\(headlineWidth)pt / \(category.rawValue)"
                    )
                }
            }
        }
    }

    func testFixedRootLeavesRoomForThresholdTextAndMinimumAssets() {
        let headline = UILabel()
        NativeAdTextLayout.configureHeadline(headline)
        headline.text = String(repeating: "W", count: 25)

        let body = UILabel()
        NativeAdTextLayout.configureBody(body)
        body.text = String(repeating: "W", count: 90)

        for category in dynamicTypeCategories {
            UITraitCollection(preferredContentSizeCategory: category).performAsCurrent {
                for width in productionRootWidths {
                    let headlineLineCount = unrestrictedLineCount(for: headline, width: width - 50)
                    let bodyLineCount = unrestrictedLineCount(for: body, width: width)
                    let headlineHeight = CGFloat(headlineLineCount) * headline.font.lineHeight
                    let advertiserHeight = UIFont.systemFont(ofSize: 12).lineHeight
                    let headerHeight = max(40, headlineHeight + 2 + advertiserHeight)
                    let bodyHeight = CGFloat(bodyLineCount) * body.font.lineHeight
                    let minimumContentHeight = 15 + headerHeight + 120 + bodyHeight + 38 + (4 * 6)

                    XCTAssertGreaterThanOrEqual(
                        width,
                        120,
                        "MediaView must remain at least 120pt wide"
                    )
                    XCTAssertLessThanOrEqual(
                        minimumContentHeight,
                        NativeAdLayout.rootHeight - NativeAdLayout.bottomSafetyInset,
                        "90-character body plus 25-character headline require "
                            + "\(minimumContentHeight)pt at \(width)pt / \(category.rawValue)"
                    )
                }
            }
        }

        XCTAssertEqual(NativeAdLayout.rootHeight, 313)
        XCTAssertEqual(NativeAdLayout.bottomSafetyInset, 1)
    }

    private func unrestrictedLineCount(for configuredLabel: UILabel, width: CGFloat) -> Int {
        let measurementLabel = UILabel()
        measurementLabel.font = configuredLabel.font
        measurementLabel.lineBreakMode = configuredLabel.lineBreakMode
        measurementLabel.numberOfLines = 0
        measurementLabel.text = configuredLabel.text

        let requiredSize = measurementLabel.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        // UILabel rounds its fitted height to the pixel grid, so a true three-line result can be
        // fractionally taller than exactly 3 * lineHeight. Nearest-line rounding avoids turning
        // that rendering precision into a false fourth line.
        return Int((requiredSize.height / measurementLabel.font.lineHeight).rounded())
    }
}

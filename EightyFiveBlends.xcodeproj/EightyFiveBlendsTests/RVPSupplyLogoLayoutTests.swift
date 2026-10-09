//
//  RVPSupplyLogoLayoutTests.swift
//  EightyFiveBlendsTests
//
//  Pins the sizing rules for the RVP Supply logo plate (`RVPSupplyLogoLayout` in
//  RecommendedGearView.swift), which is shown on the More screen sponsor banner and in the
//  Recommended Gear sponsor card. Only widths are decided there: a plate's height follows the
//  artwork's own aspect ratio, so nothing here depends on the logo's pixel dimensions (the asset
//  itself is checked in RVPSupplyLogoAssetTests).
//
//  Pure arithmetic only: how the plate actually looks (lettering readable on the dark plate, no
//  clipping at large text sizes) is a device check, not something this file can prove.
//

import Foundation
import Testing
@testable import EightyFiveBlends

struct RVPSupplyLogoLayoutTests {

    private func isClose(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    // MARK: - More banner

    @Test("The banner plate is 31% of the container's width on common iPhone widths")
    func bannerPlate_scalesWithTheContainer() {
        #expect(isClose(RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: 375), 116.25))
        #expect(isClose(RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: 390), 120.9))
        #expect(isClose(RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: 393), 121.83))
        #expect(isClose(RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: 402), 124.62))
    }

    @Test("It stops shrinking on the narrowest layouts and stops growing on the widest")
    func bannerPlate_isClamped() {
        #expect(RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: 320) == 108)
        #expect(RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: 200) == 108)
        #expect(RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: 430) == 132)
        #expect(RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: 1024) == 132)
        #expect(RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: 1366) == 132)
    }

    @Test("A wider container never gets a smaller plate, and every plate stays within the range")
    func bannerPlate_isMonotonicAndBounded() {
        let widths = stride(from: CGFloat(100), through: 1400, by: 1)
        let plates = widths.map { RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: $0) }
        #expect(plates == plates.sorted())
        #expect(plates.allSatisfy { RVPSupplyLogoLayout.bannerWidthRange.contains($0) })
    }

    @Test("A container with no usable width gets the smallest plate, never zero, negative or NaN")
    func bannerPlate_badInput() {
        for width: CGFloat in [0, -50, .nan, .infinity, -.infinity] {
            #expect(RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: width) == RVPSupplyLogoLayout.bannerWidthRange.lowerBound)
        }
    }

    @Test("The banner plate is large enough to read the wordmark and in the intended 115-140pt range on large phones")
    func bannerPlate_sizeRange() {
        #expect(RVPSupplyLogoLayout.bannerWidthRange.lowerBound >= 100)
        #expect(RVPSupplyLogoLayout.bannerWidthRange.upperBound <= 140)
        // The old logo frame was 80pt wide.
        #expect(RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: 375) > 80)
        #expect(RVPSupplyLogoLayout.bannerPlateWidth(containerWidth: 430) >= 115)
    }

    // MARK: - Recommended Gear sponsor card

    @Test("The sponsor card tries wider plates first, all larger than the old 100pt one, and stacks at 128pt")
    func cardPlate_widths() {
        #expect(RVPSupplyLogoLayout.cardWideWidth > RVPSupplyLogoLayout.cardMediumWidth)
        #expect(RVPSupplyLogoLayout.cardMediumWidth > RVPSupplyLogoLayout.cardNarrowWidth)
        // The previous plate was 100pt wide.
        #expect(RVPSupplyLogoLayout.cardNarrowWidth > 100)
        #expect(RVPSupplyLogoLayout.cardWideWidth <= 140)
        #expect(RVPSupplyLogoLayout.cardStackedWidth == RVPSupplyLogoLayout.cardWideWidth)
    }

    // MARK: - The plate

    @Test("The plate is the asset-catalog logo with a small inset and a corner radius, nothing pixel-specific")
    func plateConstants() {
        #expect(RVPSupplyLogoLayout.assetName == "RVPSupplyLogo")
        #expect(RVPSupplyLogoLayout.horizontalInset > 0 && RVPSupplyLogoLayout.horizontalInset <= 12)
        #expect(RVPSupplyLogoLayout.verticalInset > 0 && RVPSupplyLogoLayout.verticalInset <= 12)
        #expect(RVPSupplyLogoLayout.cornerRadius > 0)
    }
}

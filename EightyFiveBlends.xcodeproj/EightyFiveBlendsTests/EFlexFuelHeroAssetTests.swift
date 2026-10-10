//
//  EFlexFuelHeroAssetTests.swift
//  EightyFiveBlendsTests
//
//  Verifies the eFlexFuel Auto conversion kit hero in the compiled asset catalog
//  (EFlexFuelAutoKitHero, used by FeaturedBrandArtwork in RecommendedGearView.swift): that it loads,
//  is the supplied 1093 x 946 photo with an alpha channel, that its white studio background was
//  removed (all four corners transparent), and that the removal was selective rather than a blanket
//  "strip every near-white pixel" pass — a known dark product pixel (the EFlexPlus controller body)
//  stays opaque, and so does a known light one (a label/connector highlight), proving real product
//  detail was not punched out along with the background.
//
//  Pixel coordinates and colors are pinned against the supplied artwork on purpose, so replacing the
//  hero with a different file is a deliberate edit here too. How the photo looks against the studio-
//  gray plate in light, dark, and OLED is a device check, not something these tests can prove.
//

import CoreGraphics
import Testing
import UIKit
@testable import EightyFiveBlends

struct EFlexFuelHeroAssetTests {

    private static let assetName = "EFlexFuelAutoKitHero"

    @Test("The hero loads from the asset catalog")
    func heroLoads() {
        #expect(UIImage(named: Self.assetName) != nil)
    }

    @Test("It is the supplied 1093 x 946 photo with an alpha channel")
    func heroHasTheSuppliedDimensionsAndAlpha() throws {
        let image = try #require(UIImage(named: Self.assetName))
        let cgImage = try #require(image.cgImage)
        #expect(cgImage.width == 1093)
        #expect(cgImage.height == 946)

        let alpha = cgImage.alphaInfo
        #expect(alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast, "The hero must keep its transparency")
    }

    @Test("Its white studio background was removed: all four corners are transparent")
    func heroCornersAreTransparent() throws {
        let image = try #require(UIImage(named: Self.assetName))
        let cgImage = try #require(image.cgImage)
        let pixel = try pixelReader(for: cgImage)

        for (x, y) in [(5, 5), (cgImage.width - 6, 5), (5, cgImage.height - 6), (cgImage.width - 6, cgImage.height - 6)] {
            #expect(pixel(x, y).a == 0, "Corner (\(x), \(y)) should be transparent")
        }
    }

    @Test("Background removal was selective: real dark and light product detail both stayed opaque")
    func heroPreservesRealProductDetail() throws {
        let image = try #require(UIImage(named: Self.assetName))
        let cgImage = try #require(image.cgImage)
        let pixel = try pixelReader(for: cgImage)

        // A dark point on the eFlexPlus controller's case.
        let dark = pixel(241, 546)
        #expect(dark.a >= 240)
        #expect(dark.r < 50 && dark.g < 50 && dark.b < 50, "Expected a dark, opaque product pixel, got \(dark)")

        // A light highlight (connector/label) that a blanket white-removal pass would have erased
        // along with the background.
        let light = pixel(173, 803)
        #expect(light.a >= 240)
        #expect(light.r > 190 && light.g > 190 && light.b > 190, "Expected a light, opaque product pixel, got \(light)")
    }

    // MARK: - Pixel reading

    private func pixelReader(for image: CGImage) throws -> (Int, Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drawn)
        return { x, y in
            let offset = (y * width + x) * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
        }
    }
}

//
//  RVPSupplyLogoAssetTests.swift
//  EightyFiveBlendsTests
//
//  Verifies the RVPSupplyLogo asset in the compiled asset catalog is the supplied transparent logo
//  (1622 x 969 px, with an alpha channel and a transparent surround), not the earlier opaque
//  1500 x 1145 image with a black background baked in, and that the plate's heights stay compact.
//
//  These pin the supplied artwork on purpose (its pixel size and a few known pixels), so replacing the
//  logo with a different file is a deliberate edit here too; the plate's own layout never depends on
//  those dimensions. The logo is white lettering on transparency, so what it looks like on the dark
//  plate is a device check, not something these tests can prove.
//

import CoreGraphics
import Testing
import UIKit
@testable import EightyFiveBlends

struct RVPSupplyLogoAssetTests {

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]   // RGBA, premultiplied, row 0 is the top row

        func pixel(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let offset = (y * width + x) * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
        }
    }

    private func bitmap(of image: CGImage) -> Bitmap? {
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
        return drawn ? Bitmap(width: width, height: height, bytes: bytes) : nil
    }

    @Test("RVPSupplyLogo loads from the asset catalog")
    func logoLoads() {
        #expect(UIImage(named: RVPSupplyLogoLayout.assetName) != nil)
    }

    @Test("It is the supplied 1622 x 969 logo with an alpha channel")
    func logoHasTheSuppliedDimensionsAndAlpha() throws {
        let image = try #require(UIImage(named: RVPSupplyLogoLayout.assetName))
        let cgImage = try #require(image.cgImage)
        #expect(cgImage.width == 1622)
        #expect(cgImage.height == 969)

        let alpha = cgImage.alphaInfo
        #expect(alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast, "The logo must keep its transparency")
    }

    @Test("Its surround is transparent and the cactus is opaque green (the artwork, not a flattened copy)")
    func logoContentIsTheTransparentArtwork() throws {
        let image = try #require(UIImage(named: RVPSupplyLogoLayout.assetName))
        let cgImage = try #require(image.cgImage)
        let pixels = try #require(bitmap(of: cgImage))
        #expect(pixels.width == 1622 && pixels.height == 969)

        // All four corners are empty.
        for (x, y) in [(5, 5), (pixels.width - 6, 5), (5, pixels.height - 6), (pixels.width - 6, pixels.height - 6)] {
            #expect(pixels.pixel(x: x, y: y).a == 0, "Corner (\(x), \(y)) should be transparent")
        }

        // The middle of the cactus trunk is solid and clearly green.
        let trunk = pixels.pixel(x: 845, y: 400)
        #expect(trunk.a >= 240)
        #expect(trunk.g > trunk.r + 40 && trunk.g > trunk.b + 40, "Expected green at the cactus, got \(trunk)")
    }

    @Test("The plate stays compact: the artwork's own aspect ratio keeps every plate between 60 and 85pt tall")
    func plateHeightsStayCompact() throws {
        let image = try #require(UIImage(named: RVPSupplyLogoLayout.assetName))
        let aspect = image.size.height / image.size.width
        #expect(aspect > 0)

        func plateHeight(width: CGFloat) -> CGFloat {
            (width - 2 * RVPSupplyLogoLayout.horizontalInset) * aspect + 2 * RVPSupplyLogoLayout.verticalInset
        }

        let widths: [CGFloat] = [
            RVPSupplyLogoLayout.bannerWidthRange.lowerBound,
            RVPSupplyLogoLayout.bannerWidthRange.upperBound,
            RVPSupplyLogoLayout.cardWideWidth,
            RVPSupplyLogoLayout.cardMediumWidth,
            RVPSupplyLogoLayout.cardNarrowWidth,
            RVPSupplyLogoLayout.cardStackedWidth,
        ]
        for width in widths {
            let height = plateHeight(width: width)
            #expect(height >= 60 && height <= 85, "A \(width)pt plate would be \(height)pt tall")
        }
    }
}

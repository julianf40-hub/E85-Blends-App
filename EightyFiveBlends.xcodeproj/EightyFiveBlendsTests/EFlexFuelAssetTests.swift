//
//  EFlexFuelAssetTests.swift
//  EightyFiveBlendsTests
//
//  Verifies the official eFlexFuel wordmark in the compiled asset catalog (EFlexFuelWordmark): that it
//  loads, that both appearances are configured (a light image and a dark image, each 1200 x 158 with an
//  alpha channel), and that they are not swapped. The light-mode image is the orange-and-charcoal
//  logo and the dark-mode image is the orange-and-white one, so the wrong way round would put charcoal
//  lettering on the dark and OLED cards.
//
//  Both supplied files carry their own parallelogram plate (white behind the charcoal logo, black
//  behind the white one) rather than being fully transparent; these tests do not assume transparency.
//  How the logo looks on each theme's card is a device check, not something these tests can prove.
//

import CoreGraphics
import Testing
import UIKit
@testable import EightyFiveBlends

struct EFlexFuelAssetTests {

    private static let assetName = "EFlexFuelWordmark"

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

    // The image the catalog serves for one appearance. Asking the image asset for a trait collection
    // resolves that appearance directly, instead of whatever the test process happens to be in.
    private func image(for style: UIUserInterfaceStyle) -> UIImage? {
        let traits = UITraitCollection(userInterfaceStyle: style)
        guard let base = UIImage(named: Self.assetName, in: .main, compatibleWith: traits) else { return nil }
        return base.imageAsset?.image(with: traits) ?? base
    }

    @Test("The wordmark loads from the asset catalog, and the brand model names it")
    func wordmarkLoads() {
        #expect(UIImage(named: Self.assetName) != nil)
        #expect(FeaturedBrand.eFlexFuel.wordmarkAssetName == Self.assetName)
    }

    @Test("Light and dark appearances are both configured, 1200 x 158 with an alpha channel")
    func bothAppearancesAreConfigured() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = try #require(image(for: style), "No image for \(style)")
            let cgImage = try #require(image.cgImage)
            #expect(cgImage.width == 1200, "\(style): width")
            #expect(cgImage.height == 158, "\(style): height")

            let alpha = cgImage.alphaInfo
            #expect(alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast, "\(style): alpha channel")
        }
    }

    @Test("The light and dark images decode to different pixels")
    func appearancesDiffer() throws {
        let lightImage = try #require(image(for: .light)?.cgImage)
        let darkImage = try #require(image(for: .dark)?.cgImage)
        let light = try #require(bitmap(of: lightImage))
        let dark = try #require(bitmap(of: darkImage))
        #expect(light.bytes != dark.bytes)
    }

    @Test("Light mode gets the orange-and-charcoal logo and dark mode the orange-and-white one")
    func appearancesAreNotSwapped() throws {
        let lightImage = try #require(image(for: .light)?.cgImage)
        let darkImage = try #require(image(for: .dark)?.cgImage)
        let light = try #require(bitmap(of: lightImage))
        let dark = try #require(bitmap(of: darkImage))

        // The middle of the wordmark falls inside a letter in both images.
        let lightLetter = light.pixel(x: 600, y: 79)
        let darkLetter = dark.pixel(x: 600, y: 79)
        #expect(lightLetter.a >= 240 && lightLetter.r < 110 && lightLetter.g < 110 && lightLetter.b < 110,
                "Light mode's lettering should be charcoal, got \(lightLetter)")
        #expect(darkLetter.a >= 240 && darkLetter.r > 200 && darkLetter.g > 200 && darkLetter.b > 200,
                "Dark mode's lettering should be white, got \(darkLetter)")

        // The "E" is eFlexFuel orange (255, 85, 0) in both.
        for (name, e) in [("light", light.pixel(x: 100, y: 80)), ("dark", dark.pixel(x: 100, y: 80))] {
            #expect(e.a >= 240 && e.r > 240 && e.g > 60 && e.g < 110 && e.b < 30, "\(name): expected orange at the E, got \(e)")
        }
    }
}

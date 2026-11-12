//
//  GearImageDecoderTests.swift
//  EightyFiveBlendsTests
//
//  ImageIO decoding for remote catalog images (GearRemoteImage.swift): header dimension checks
//  before decoding, display-size downsampling, corrupt data and the decoded-cost figure.
//  REQUIRES APPLE FRAMEWORKS (ImageIO, CoreGraphics); compiled only where they exist. The portable
//  dimension rule itself is also covered in GearImageLimitsTests below, which runs everywhere.
//

import Foundation
import Testing
@testable import EightyFiveBlends

@MainActor
struct GearImageLimitsTests {
    @Test func headerDimensionRule() {
        #expect(GearImageLimits.acceptsSource(width: 1_200, height: 1_200))
        #expect(GearImageLimits.acceptsSource(width: 8_192, height: 4_000))
        #expect(GearImageLimits.acceptsSource(width: 8_193, height: 10) == false)
        #expect(GearImageLimits.acceptsSource(width: 8_000, height: 8_000) == false, "64 MP exceeds the pixel budget")
        #expect(GearImageLimits.acceptsSource(width: 0, height: 100) == false)
        #expect(GearImageLimits.acceptsSource(width: Int.max, height: Int.max) == false)
    }
}

#if canImport(ImageIO) && canImport(CoreGraphics) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
struct GearImageDecoderTests {
    private static func encodedImage(width: Int, height: Int, type: UTType = .png) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A tiny, well-formed PNG whose header claims `width` x `height` pixels: the classic
    /// decompression-bomb shape. It must be rejected from the header alone.
    private static func pngHeaderOnly(width: UInt32, height: UInt32) -> Data {
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
            }
            return ~crc
        }
        func bigEndian(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            return bigEndian(UInt32(body.count)) + typed + bigEndian(crc32(typed))
        }
        let ihdr = bigEndian(width) + bigEndian(height) + [8, 6, 0, 0, 0]
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return Data(signature + chunk("IHDR", ihdr) + chunk("IDAT", [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]) + chunk("IEND", []))
    }

    @Test func largePhotoIsDownsampledToDisplaySize() throws {
        let data = try Self.encodedImage(width: 4_000, height: 3_000, type: .jpeg)
        let image = try #require(GearImageDecoder.displayImage(from: data))
        #expect(max(image.cgImage.width, image.cgImage.height) <= GearImageLimits.displayMaxPixelSize)
        #expect(image.cgImage.width > image.cgImage.height, "aspect ratio kept")
        #expect(image.cost == image.cgImage.bytesPerRow * image.cgImage.height)
        #expect(image.cost < 4_000 * 3_000 * 4, "never a full-resolution bitmap")
    }

    @Test func smallImageIsNotUpscaled() throws {
        let data = try Self.encodedImage(width: 300, height: 200)
        let image = try #require(GearImageDecoder.displayImage(from: data))
        #expect(image.cgImage.width == 300)
        #expect(image.cgImage.height == 200)
    }

    @Test func hugeDeclaredDimensionsAreRejectedFromTheHeader() {
        let bomb = Self.pngHeaderOnly(width: 20_000, height: 20_000)
        #expect(bomb.count < 200)
        #expect(GearImageDecoder.displayImage(from: bomb) == nil)
    }

    @Test func corruptOrNonImageDataIsRejected() throws {
        #expect(GearImageDecoder.displayImage(from: Data()) == nil)
        #expect(GearImageDecoder.displayImage(from: Data("<html>not an image</html>".utf8)) == nil)
        let truncated = try Self.encodedImage(width: 400, height: 400).prefix(40)
        #expect(GearImageDecoder.displayImage(from: Data(truncated)) == nil)
    }
}
#endif

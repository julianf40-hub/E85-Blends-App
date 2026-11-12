//
//  GearRemoteImage.swift
//  EightyFiveBlends
//
//  Remote product photos and logos for the Recommended Gear catalog (GearCatalog.swift).
//
//  Catalog image URLs are VERSIONED: replacing artwork means uploading a new file name and
//  publishing its new URL, never overwriting an existing object. Every URL is therefore immutable,
//  so a stored copy is served whenever one exists (offline included) and the network is used only
//  for a URL never fetched before.
//
//  Memory and size safety (GearImageLimits, GearDownloading.swift):
//  - bytes are limited during transfer, for network and cached responses alike;
//  - the header's pixel dimensions are checked before any pixels are decoded;
//  - images are decoded by ImageIO straight to a display-sized thumbnail, off the main thread, so a
//    full-resolution bitmap is never created;
//  - the memory cache is bounded by decoded bytes, and emptied on a memory warning;
//  - at most three transfers/decodes run at once; callers for the same URL share one.
//  Failures, timeouts, oversized or undecodable data show the supplied fallback (bundled artwork,
//  a typographic name, or a neutral placeholder). Bundled artwork never goes through this path.
//

import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// A decoded, display-sized image. CGImage is immutable, so sharing it across threads is safe.
nonisolated struct GearDecodedImage: @unchecked Sendable {
    let cgImage: CGImage

    /// Decoded memory, for the cost-bounded cache.
    var cost: Int { cgImage.bytesPerRow * cgImage.height }
}

nonisolated enum GearImageDecoder {
    /// Reads the header, rejects oversized sources, then lets ImageIO decode directly to a thumbnail
    /// no longer than `maxPixelSize` on its longest side (never upscaled), with EXIF orientation
    /// applied. Returns nil for corrupt, unsupported or oversized images.
    static func displayImage(from data: Data, maxPixelSize: Int = GearImageLimits.displayMaxPixelSize) -> GearDecodedImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              GearImageLimits.acceptsSource(width: width, height: height) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return GearDecodedImage(cgImage: image)
    }
}

/// The shared image loader used by every remote catalog image.
enum GearImagePipeline {
    private static var observers: [NSObjectProtocol] = []

    static let shared: GearAssetLoader<GearDecodedImage> = {
        let loader = GearAssetLoader<GearDecodedImage>(
            downloader: GearBoundedDownloader(configuration: makeConfiguration()),
            maximumConcurrentLoads: GearImageLimits.maximumConcurrentLoads,
            byteLimit: GearImageLimits.maximumBytes,
            timeout: GearImageLimits.requestTimeout,
            costLimit: GearImageLimits.memoryCostLimit,
            countLimit: GearImageLimits.memoryCountLimit,
            cost: { $0.cost },
            decode: { GearImageDecoder.displayImage(from: $0) }
        )
        #if canImport(UIKit)
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { loader.removeAllCached() }
        })
        #endif
        return loader
    }()

    nonisolated static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RecommendedGearImages", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: GearImageLimits.diskCacheBytes, directory: directory)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = GearImageLimits.requestTimeout
        configuration.timeoutIntervalForResource = GearImageLimits.requestTimeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = GearImageLimits.maximumConcurrentLoads
        return configuration
    }
}

/// A remote catalog image, aspect-fit, with `fallback` shown while it loads and if it can't.
/// Callers apply their own clip shapes, frames and accessibility (these images are decorative).
struct GearRemoteImage<Fallback: View>: View {
    let url: URL?
    let fallback: () -> Fallback

    @State private var loaded: GearDecodedImage?
    @State private var loadedURL: URL?

    init(url: URL?, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.url = url
        self.fallback = fallback
    }

    var body: some View {
        Group {
            if let loaded, loadedURL == url {
                Image(decorative: loaded.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                fallback()
            }
        }
        .task(id: url) {
            guard let url else {
                loaded = nil
                loadedURL = nil
                return
            }
            if let cached = GearImagePipeline.shared.cachedValue(for: url) {
                loaded = cached
                loadedURL = url
                return
            }
            let image = await GearImagePipeline.shared.load(url)
            guard Task.isCancelled == false else { return }
            loaded = image
            loadedURL = image == nil ? nil : url
        }
    }
}

/// Bundled artwork from the asset catalog, or a neutral placeholder when there is none (a remote-
/// only product whose photo failed to load). Never another brand's artwork.
struct GearBundledImage: View {
    let assetName: String

    var body: some View {
        if assetName.isEmpty == false {
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
        }
    }
}

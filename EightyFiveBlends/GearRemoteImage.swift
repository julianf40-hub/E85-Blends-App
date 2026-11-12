//
//  GearRemoteImage.swift
//  EightyFiveBlends
//
//  Remote product photos and logos for the Recommended Gear catalog (GearCatalog.swift).
//
//  Catalog image URLs are VERSIONED: replacing artwork means uploading a new file name and
//  publishing its new URL, never overwriting an existing object. That makes every URL immutable, so
//  this loader serves a stored copy whenever it has one (including offline) and only goes to the
//  network for a URL it has never fetched. Failures, timeouts and undecodable data show the
//  supplied fallback (bundled artwork, a typographic name, or a neutral placeholder), never a blank
//  or a spinner that never ends.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// Shared loader: an in-memory cache, a dedicated on-disk URL cache, request coalescing, a short
/// timeout and a size limit.
@MainActor
final class GearImagePipeline {
    static let shared = GearImagePipeline()

    nonisolated static let maximumBytes = 8_000_000
    nonisolated static let requestTimeout: TimeInterval = 15

    private let session: URLSession
    private let memory = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init(session: URLSession = GearImagePipeline.makeSession()) {
        self.session = session
        memory.countLimit = 80
    }

    nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RecommendedGearImages", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 60_000_000, directory: directory)
        // Versioned URLs never change content, so any stored copy is valid, even an "expired" one.
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        if let running = inFlight[url] { return await running.value }

        let session = self.session
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  data.isEmpty == false, data.count <= GearImagePipeline.maximumBytes,
                  let image = UIImage(data: data) else {
                return nil
            }
            // Decode off the main thread so scrolling the carousel never stalls on a large photo.
            return image.preparingForDisplay() ?? image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }
}
#endif

/// A remote catalog image, aspect-fit, with `fallback` shown while it loads and if it can't.
/// Callers apply their own clip shapes, frames and accessibility (these images are decorative).
struct GearRemoteImage<Fallback: View>: View {
    let url: URL?
    let fallback: () -> Fallback

    init(url: URL?, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.url = url
        self.fallback = fallback
    }

    #if canImport(UIKit)
    @State private var loaded: UIImage?
    @State private var loadedURL: URL?
    #endif

    var body: some View {
        #if canImport(UIKit)
        Group {
            if let loaded, loadedURL == url {
                Image(uiImage: loaded)
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
            if let cached = GearImagePipeline.shared.cachedImage(for: url) {
                loaded = cached
                loadedURL = url
                return
            }
            let image = await GearImagePipeline.shared.image(for: url)
            guard Task.isCancelled == false else { return }
            loaded = image
            loadedURL = image == nil ? nil : url
        }
        #else
        fallback()
        #endif
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

//
//  GearDownloading.swift
//  EightyFiveBlends
//
//  Bounded networking for the remote Recommended Gear catalog and its images (2.4.1).
//
//  Every byte limit is enforced WHILE the body is received, never after: Content-Length is only
//  used to refuse an obviously oversized response early, and a missing or misleading header cannot
//  get past the running count. The transfer is cancelled as soon as the limit is exceeded. The same
//  path serves responses from URLCache, so cached bodies pass the same limits.
//
//  Foundation only (no UIKit, SwiftUI or ImageIO), so this file's logic is also exercised by the
//  portable tests in GearDownloadTests.swift.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

nonisolated enum GearDownloadError: Error, Equatable {
    /// Declared or actually received more than the allowed bytes.
    case tooLarge
    /// Not an HTTP response.
    case invalidResponse
}

/// Pure byte accounting for one transfer.
nonisolated struct GearByteBudget {
    let limit: Int
    private(set) var data = Data()

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// `expectedLength` is `URLResponse.expectedContentLength` (-1 when unknown). Unknown lengths are
    /// allowed here and limited by `append` instead.
    func allows(expectedLength: Int64) -> Bool {
        expectedLength < 0 || expectedLength <= Int64(limit)
    }

    /// Adds a received chunk. Returns false (and keeps nothing more) once the total would exceed the
    /// limit; the caller must then cancel the transfer.
    mutating func append(_ chunk: Data) -> Bool {
        guard chunk.count <= limit - data.count else { return false }
        data.append(chunk)
        return true
    }
}

/// A bounded, oldest-first record of cancellations, for diagnostics and tests. Disabled (capacity
/// 0) unless a caller opts in, so production downloaders retain nothing, URLs included.
///
/// Entries are reference objects. A transfer keeps a reference to its OWN entry and updates it
/// directly when late data arrives, so there are no positions to go stale: evicting an entry only
/// drops the log's reference, and a late update then touches an object the log no longer holds,
/// never another transfer's entry.
nonisolated struct GearCancellationLog {
    /// Upper bound for any opted-in capacity.
    static let maximumCapacity = 256

    final class Entry {
        let url: URL?
        let reason: GearBoundedDownloader.Cancellation.Reason
        let limit: Int
        let retainedBytes: Int
        var ignoredBytes = 0

        init(url: URL?, reason: GearBoundedDownloader.Cancellation.Reason, limit: Int, retainedBytes: Int) {
            self.url = url
            self.reason = reason
            self.limit = limit
            self.retainedBytes = retainedBytes
        }

        var snapshot: GearBoundedDownloader.Cancellation {
            GearBoundedDownloader.Cancellation(url: url, reason: reason, limit: limit,
                                              retainedBytes: retainedBytes, ignoredBytes: ignoredBytes)
        }
    }

    let capacity: Int
    private(set) var entries: [Entry] = []

    init(capacity: Int) {
        self.capacity = min(max(0, capacity), Self.maximumCapacity)
    }

    var isEnabled: Bool { capacity > 0 }

    /// Adds an entry and evicts the oldest beyond `capacity`. Returns nil (recording nothing) when
    /// disabled.
    mutating func record(url: URL?, reason: GearBoundedDownloader.Cancellation.Reason, limit: Int, retainedBytes: Int) -> Entry? {
        guard isEnabled else { return nil }
        let entry = Entry(url: url, reason: reason, limit: limit, retainedBytes: retainedBytes)
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        return entry
    }

    var snapshot: [GearBoundedDownloader.Cancellation] { entries.map(\.snapshot) }
}

/// URLSession data tasks with a hard per-request byte limit. One instance owns one session and is
/// its delegate; delegate callbacks run on a private serial queue.
nonisolated final class GearBoundedDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Why and when a transfer was cancelled (opt-in diagnostics; see `GearCancellationLog`). `retainedBytes` is what
    /// the transfer held when cancellation was requested (never more than the limit);
    /// `ignoredBytes` counts data that still arrived afterwards (already buffered by the loading
    /// system) and was discarded.
    struct Cancellation: Equatable {
        enum Reason: Equatable { case declaredLengthOverLimit, bodyOverLimit, invalidResponse }
        let url: URL?
        let reason: Reason
        let limit: Int
        let retainedBytes: Int
        var ignoredBytes = 0
    }

    private final class Transfer {
        var budget: GearByteBudget
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        var response: HTTPURLResponse?
        var failure: Error?
        /// This transfer's own diagnostic entry, when diagnostics are enabled.
        var cancellation: GearCancellationLog.Entry?

        init(limit: Int, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            budget = GearByteBudget(limit: limit)
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var session: URLSession!
    private var cancellations: GearCancellationLog

    /// The most recent cancellations, oldest first (empty unless diagnostics were enabled).
    var cancellationLog: [Cancellation] { locked { cancellations.snapshot } }

    /// Whether this downloader keeps cancellation diagnostics at all.
    var keepsCancellationLog: Bool { locked { cancellations.isEnabled } }

    /// Records a cancellation (call with the lock held). A no-op when diagnostics are disabled.
    private func recordCancellation(_ transfer: Transfer, _ reason: Cancellation.Reason, url: URL?) {
        transfer.cancellation = cancellations.record(url: url, reason: reason, limit: transfer.budget.limit,
                                                     retainedBytes: transfer.budget.data.count)
    }

    /// `cancellationLogCapacity` opts in to keeping that many recent cancellations (capped at
    /// `GearCancellationLog.maximumCapacity`). The default, 0, keeps none: production callers
    /// should not pass it.
    init(configuration: URLSessionConfiguration, cancellationLogCapacity: Int = 0) {
        cancellations = GearCancellationLog(capacity: cancellationLogCapacity)
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "GearBoundedDownloader"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// For tests: cancels everything and releases the session (it retains its delegate).
    func invalidate() {
        session.invalidateAndCancel()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Downloads `request`, failing with `GearDownloadError.tooLarge` as soon as more than `limit`
    /// bytes are declared or received. Cancelling the calling task cancels the transfer. Any HTTP
    /// status is returned; callers decide which statuses they accept.
    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                locked { transfers[task.taskIdentifier] = Transfer(limit: limit, continuation: continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let allow: Bool = locked {
            guard let transfer = transfers[dataTask.taskIdentifier] else { return false }
            guard let http = response as? HTTPURLResponse else {
                transfer.failure = GearDownloadError.invalidResponse
                recordCancellation(transfer, .invalidResponse, url: response.url)
                return false
            }
            guard transfer.budget.allows(expectedLength: response.expectedContentLength) else {
                transfer.failure = GearDownloadError.tooLarge
                recordCancellation(transfer, .declaredLengthOverLimit, url: response.url)
                return false
            }
            transfer.response = http
            return true
        }
        // A refused response gets the documented `.cancel` disposition AND an explicit cancel: on
        // Apple platforms `.cancel` is equivalent to cancelling the task; in testing, another
        // Foundation implementation kept reading the body after `.cancel` alone. The failure is
        // already recorded, so any bytes that still arrive are ignored.
        completionHandler(allow ? .allow : .cancel)
        if allow == false { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded: Bool = locked {
            guard let transfer = transfers[dataTask.taskIdentifier] else { return false }
            guard transfer.failure == nil else {
                // Already cancelled: data the loading system had buffered is discarded.
                // Updates this transfer's own entry, even if the log has since evicted it.
                transfer.cancellation?.ignoredBytes += data.count
                return false
            }
            if transfer.budget.append(data) { return false }
            transfer.failure = GearDownloadError.tooLarge
            recordCancellation(transfer, .bodyOverLimit, url: dataTask.originalRequest?.url)
            return true
        }
        if exceeded { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void
    ) {
        // Only complete, in-limit, successful bodies are worth keeping.
        let keep: Bool = locked {
            guard let transfer = transfers[dataTask.taskIdentifier] else { return false }
            return transfer.failure == nil && (transfer.response.map { (200..<300).contains($0.statusCode) } ?? false)
                && proposedResponse.data.count <= transfer.budget.limit
        }
        completionHandler(keep ? proposedResponse : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = locked({ transfers.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = transfer.failure {
            transfer.continuation.resume(throwing: failure)
        } else if let error {
            transfer.continuation.resume(throwing: error)
        } else if let response = transfer.response {
            transfer.continuation.resume(returning: (transfer.budget.data, response))
        } else {
            transfer.continuation.resume(throwing: GearDownloadError.invalidResponse)
        }
    }
}

/// At most `limit` holders at once; later callers wait in FIFO order.
actor GearAsyncLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the slot straight to the next waiter, if any.
    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }

    var activeCount: Int { active }
}

/// A least-recently-used cache bounded by total cost (decoded bytes for images) and entry count.
/// Deterministic, unlike NSCache, so its limits are testable.
nonisolated struct GearCostCache<Key: Hashable, Value> {
    let costLimit: Int
    let countLimit: Int
    private var entries: [Key: (value: Value, cost: Int)] = [:]
    private var order: [Key] = [] // least recent first
    private(set) var totalCost = 0

    init(costLimit: Int, countLimit: Int) {
        self.costLimit = max(0, costLimit)
        self.countLimit = max(0, countLimit)
    }

    var count: Int { entries.count }

    mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return entry.value
    }

    /// An item costlier than the whole cache is not stored.
    mutating func insert(_ value: Value, for key: Key, cost: Int) {
        remove(key)
        let cost = max(0, cost)
        guard cost <= costLimit, countLimit > 0 else { return }
        entries[key] = (value, cost)
        order.append(key)
        totalCost += cost
        while totalCost > costLimit || entries.count > countLimit, let oldest = order.first {
            remove(oldest)
        }
    }

    mutating func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalCost -= entry.cost
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalCost = 0
    }
}

/// Loads and decodes remote assets with: one transfer per URL at a time (callers for the same URL
/// share it), at most `maximumConcurrentLoads` transfers+decodes overall, a byte limit during
/// transfer, off-main decoding, and a cost-bounded memory cache. Returns nil on any failure so the
/// caller shows its fallback. `Value` is the decoded form (a downsampled CGImage on iOS).
@MainActor
final class GearAssetLoader<Value: Sendable> {
    typealias Decode = @Sendable (Data) -> Value?

    private let downloader: GearBoundedDownloader
    private let limiter: GearAsyncLimiter
    private let byteLimit: Int
    private let timeout: TimeInterval
    private let decode: Decode
    private let cost: (Value) -> Int
    private var cache: GearCostCache<URL, Value>
    private var inFlight: [URL: Task<Value?, Never>] = [:]

    init(
        downloader: GearBoundedDownloader,
        maximumConcurrentLoads: Int,
        byteLimit: Int,
        timeout: TimeInterval,
        costLimit: Int,
        countLimit: Int,
        cost: @escaping (Value) -> Int,
        decode: @escaping Decode
    ) {
        self.downloader = downloader
        limiter = GearAsyncLimiter(limit: maximumConcurrentLoads)
        self.byteLimit = byteLimit
        self.timeout = timeout
        self.cost = cost
        self.decode = decode
        cache = GearCostCache(costLimit: costLimit, countLimit: countLimit)
    }

    var cachedCost: Int { cache.totalCost }
    var inFlightCount: Int { inFlight.count }

    func cachedValue(for url: URL) -> Value? {
        cache.value(for: url)
    }

    func removeAllCached() {
        cache.removeAll()
    }

    func load(_ url: URL) async -> Value? {
        if let cached = cache.value(for: url) { return cached }
        if let running = inFlight[url] { return await running.value }

        let downloader = self.downloader
        let limiter = self.limiter
        let byteLimit = self.byteLimit
        let timeout = self.timeout
        let decode = self.decode
        let task = Task.detached(priority: .utility) { () -> Value? in
            await limiter.acquire()
            let value = await GearAssetLoader<Value>.fetch(
                url, downloader: downloader, byteLimit: byteLimit, timeout: timeout, decode: decode
            )
            await limiter.release()
            return value
        }
        inFlight[url] = task
        let value = await task.value
        inFlight[url] = nil
        if let value { cache.insert(value, for: url, cost: cost(value)) }
        return value
    }

    nonisolated private static func fetch(
        _ url: URL,
        downloader: GearBoundedDownloader,
        byteLimit: Int,
        timeout: TimeInterval,
        decode: Decode
    ) async -> Value? {
        // Versioned URLs never change content, so any stored copy is valid, offline included.
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        guard let (data, response) = try? await downloader.data(for: request, limit: byteLimit),
              (200..<300).contains(response.statusCode), data.isEmpty == false else {
            return nil
        }
        return decode(data)
    }
}

/// Limits for remote catalog images. Pure, so the dimension rule is testable on any platform; the
/// ImageIO decoding that applies it lives in GearRemoteImage.swift.
nonisolated enum GearImageLimits {
    /// Compressed bytes allowed per image (enforced during transfer, cached copies included).
    static let maximumBytes = 5_000_000
    /// Source dimensions read from the image header BEFORE any pixel decoding. Anything larger is
    /// rejected outright (a "decompression bomb" can be tiny on the wire and huge in memory).
    static let maximumDimension = 8_192
    static let maximumPixelCount = 40_000_000
    /// Longest side of the decoded, display-sized image. The largest slot is the 200pt-tall hero
    /// across a full-width card, about 1,200px at 3x, so 1,600px keeps photos sharp on every iPhone.
    static let displayMaxPixelSize = 1_600
    static let maximumConcurrentLoads = 3
    /// Decoded bytes (bytesPerRow x height) kept in memory, and entries.
    static let memoryCostLimit = 32 * 1_024 * 1_024
    static let memoryCountLimit = 120
    static let requestTimeout: TimeInterval = 15
    static let diskCacheBytes = 60_000_000

    static func acceptsSource(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension else { return false }
        return width.multipliedReportingOverflow(by: height).partialValue <= maximumPixelCount
    }
}

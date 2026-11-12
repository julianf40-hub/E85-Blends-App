//
//  GearDownloadTests.swift
//  EightyFiveBlendsTests
//
//  Bounded downloads, concurrency limiting, the cost-bounded cache and request coalescing
//  (GearDownloading.swift). PORTABLE: Foundation only, no UIKit/ImageIO, so these also run outside
//  Apple platforms. Transfers go through the real URLSession data-task path with a scripted
//  URLProtocol stub (no network). ImageIO decoding has its own Apple-only suite
//  (GearImageDecoderTests.swift).
//
//  The stub does not rely on timing. Each script says how many body chunks go out as soon as
//  loading starts; the rest are held until the test calls `release`. "The transfer ended while the
//  body was still held" is therefore proof that the downloader cancelled it, independent of how
//  quickly URLSession later delivers `stopLoading`. On Apple platforms every URLProtocolClient call
//  is made on the thread `startLoading` ran on (the URL loading system's contract for custom
//  protocols, and the thread `stopLoading` arrives on). Cache hits offered by the loading system
//  (`cachedResponse`) are served the way the built-in HTTP protocol serves them.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import EightyFiveBlends

// MARK: - Scripted URLProtocol

/// Lets the stub hand values to blocks run on its client thread. URLProtocol instances are driven
/// by URLSession's loader; the stub's mutable state is guarded by `lock`.
nonisolated struct GearUncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

nonisolated final class GearStubProtocol: URLProtocol {
    struct Script {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        /// Chunks sent as soon as loading starts. The rest wait for `release(_:)`. When every chunk
        /// has been sent the load finishes.
        var initialChunks = Int.max
    }

    final class Record {
        /// Loads that used the script (the "network").
        var networkRequests = 0
        /// Loads answered from the `cachedResponse` the loading system offered.
        var cacheHits = 0
        var deliveredChunks = 0
        /// `stopLoading` arrived before the load finished.
        var stopped = false
        var finished = false
        var active = 0
        var maximumActive = 0
    }

    private static let lock = NSLock()
    private static var scripts: [String: Script] = [:]
    private static var records: [String: Record] = [:]
    /// Concurrency is tracked per group (the URL's host), across URLs.
    private static var groups: [String: Record] = [:]
    private static var live: [String: GearStubProtocol] = [:]

    /// Not reentrant: never call `record`, `group`, `register` or `release` inside `locked`.
    static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func register(_ url: URL, _ script: Script) {
        locked {
            scripts[url.absoluteString] = script
            records[url.absoluteString] = Record()
        }
    }

    static func record(_ url: URL) -> Record {
        locked { records[url.absoluteString] ?? Record() }
    }

    static func group(_ host: String) -> Record {
        locked {
            if let group = groups[host] { return group }
            let group = Record()
            groups[host] = group
            return group
        }
    }

    /// Sends the held chunks of the load currently running for `url`, then finishes it.
    static func release(_ url: URL) {
        guard let stub = locked({ live[url.absoluteString] }) else { return }
        stub.onClientThread { stub.sendRemaining() }
    }

    private var script = Script()
    private var record = Record()
    private var nextChunk = 0
    private var isStopped = false
    private var isDone = false
    private var group: Record?
    #if canImport(Darwin)
    private var clientRunLoop: CFRunLoop?
    #endif

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Runs `body` on the thread that called `startLoading` (Apple platforms), where client calls
    /// belong and where `stopLoading` is delivered. Elsewhere it runs immediately.
    private func onClientThread(_ body: @escaping () -> Void) {
        #if canImport(Darwin)
        guard let runLoop = locked({ clientRunLoop }) else { return }
        let box = GearUncheckedBox(value: body)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { box.value() }
        CFRunLoopWakeUp(runLoop)
        #else
        body()
        #endif
    }

    private func locked<T>(_ body: () -> T) -> T { Self.locked(body) }

    override func startLoading() {
        let key = request.url!.absoluteString
        let host = request.url!.host ?? ""
        let group = Self.group(host)
        #if canImport(Darwin)
        let runLoop = CFRunLoopGetCurrent()
        #endif
        let offeredCache = cachedResponse
        let found: (Script, Record)? = locked {
            #if canImport(Darwin)
            clientRunLoop = runLoop
            #endif
            guard let script = Self.scripts[key], let record = Self.records[key] else { return nil }
            if offeredCache != nil { record.cacheHits += 1 } else { record.networkRequests += 1 }
            self.script = script
            self.record = record
            self.group = group
            group.active += 1
            group.maximumActive = max(group.maximumActive, group.active)
            Self.live[key] = self
            return (script, record)
        }
        guard found != nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        if let offeredCache {
            // How the built-in HTTP protocol answers from URLCache: the stored response and body,
            // through the same client (and so the same delegate) calls as a network load.
            client?.urlProtocol(self, didReceive: offeredCache.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: offeredCache.data)
            finish()
            return
        }

        let response = HTTPURLResponse(url: request.url!, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: script.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        send(upTo: script.initialChunks)
    }

    /// Sends chunks while not stopped, up to `limit` in total; finishes when all are sent.
    private func send(upTo limit: Int) {
        while true {
            let next: Data? = locked {
                guard isStopped == false, isDone == false, nextChunk < script.chunks.count, nextChunk < limit else { return nil }
                defer { nextChunk += 1 }
                record.deliveredChunks += 1
                return script.chunks[nextChunk]
            }
            guard let next else { break }
            client?.urlProtocol(self, didLoad: next)
        }
        if locked({ isStopped == false && nextChunk >= script.chunks.count }) { finish() }
    }

    private func sendRemaining() { send(upTo: Int.max) }

    private func finish() {
        let shouldFinish: Bool = locked {
            guard isDone == false, isStopped == false else { return false }
            isDone = true
            record.finished = true
            group?.active -= 1
            Self.live[request.url!.absoluteString] = nil
            return true
        }
        if shouldFinish { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        locked {
            if isDone == false {
                record.stopped = true
                isDone = true
                group?.active -= 1
                Self.live[request.url!.absoluteString] = nil
            }
            isStopped = true
        }
    }
}

// MARK: - Tests

@MainActor
struct GearDownloadTests {
    private static func url(_ name: String, host: String = "gear-\(UUID().uuidString.lowercased()).test") -> URL {
        URL(string: "https://\(host)/\(name)-\(UUID().uuidString)")!
    }

    private static func downloader(cache: URLCache? = nil) -> GearBoundedDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GearStubProtocol.self]
        configuration.urlCache = cache
        configuration.requestCachePolicy = cache == nil ? .reloadIgnoringLocalCacheData : .returnCacheDataElseLoad
        return GearBoundedDownloader(configuration: configuration)
    }

    private static func chunks(_ count: Int, size: Int) -> [Data] {
        (0..<count).map { Data(repeating: UInt8($0 % 250), count: size) }
    }

    /// Waits for an event, bounded (5 s) so a missing event fails the test instead of hanging it.
    private static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while condition() == false, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    struct WatchdogExpired: Error {}

    /// `downloader.data`, but abandoned by a 10 s watchdog. With the body held by the stub, a
    /// downloader that failed to cancel on its own would otherwise wait forever, or (since the
    /// failure is recorded first) still report tooLarge once something else cancelled it. A
    /// watchdog expiry therefore throws `WatchdogExpired`, which fails the expectation: the
    /// downloader must end the transfer itself, promptly.
    private static func download(_ downloader: GearBoundedDownloader, _ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.lock(); value = true; lock.unlock() }
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let expired = Flag()
        let transfer = Task { try await downloader.data(for: request, limit: limit) }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            guard Task.isCancelled == false else { return }
            expired.set()
            transfer.cancel()
        }
        defer { watchdog.cancel() }
        let result = await transfer.result
        if expired.isSet { throw WatchdogExpired() }
        return try result.get()
    }

    /// Network loads for `url` (reads the record outside the lock it takes).
    private static func networkRequests(_ url: URL) -> Int {
        let record = GearStubProtocol.record(url)
        return GearStubProtocol.locked { record.networkRequests }
    }

    private static func stub(_ record: GearStubProtocol.Record) -> (delivered: Int, stopped: Bool, finished: Bool) {
        GearStubProtocol.locked { (record.deliveredChunks, record.stopped, record.finished) }
    }

    // MARK: Byte budget (pure)

    @Test func byteBudgetCountsReceivedBytesNotHeaders() {
        var budget = GearByteBudget(limit: 10)
        #expect(budget.allows(expectedLength: -1), "unknown length is limited while receiving")
        #expect(budget.allows(expectedLength: 10))
        #expect(budget.allows(expectedLength: 11) == false)
        let first = budget.append(Data(count: 6))
        let second = budget.append(Data(count: 4))
        let overflow = budget.append(Data(count: 1))
        #expect(first)
        #expect(second)
        #expect(overflow == false)
        #expect(budget.data.count == 10)
    }

    // MARK: Bounded downloader

    /// No Content-Length; three 1,000-byte chunks are sent and seventeen are held. The third chunk
    /// crosses the 2,500-byte limit. The call must fail with tooLarge while the rest of the body is
    /// still held: the transfer ended because the downloader cancelled it, not because the body was
    /// complete.
    @Test func chunkedResponseWithoutLengthIsCancelledAtTheLimit() async throws {
        let url = Self.url("chunked")
        GearStubProtocol.register(url, .init(chunks: Self.chunks(20, size: 1_000), initialChunks: 3))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }

        await #expect(throws: GearDownloadError.tooLarge) {
            _ = try await Self.download(downloader, URLRequest(url: url), limit: 2_500)
        }
        let record = GearStubProtocol.record(url)
        let state = Self.stub(record)
        #expect(state.delivered == 3, "only the chunks the stub chose to send were read")
        #expect(state.finished == false, "the body was never completed; the downloader ended the transfer")
        #expect(downloader.cancellationLog.map(\.reason) == [.bodyOverLimit])
        #expect(downloader.cancellationLog.first?.retainedBytes == 2_000, "never more than the limit retained")

        // The cancellation then reaches the protocol. Asserted separately (bounded), since its
        // delivery time belongs to the URL loading system.
        await Self.waitUntil { Self.stub(record).stopped }
        #expect(Self.stub(record).stopped, "URLSession stopped the protocol after the cancellation")
        GearStubProtocol.release(url)
        #expect(Self.stub(record).delivered == 3, "nothing more is sent once stopped")
    }

    /// Everything is sent at once, so data keeps arriving after the limit is crossed (already
    /// buffered by the loading system). It is discarded: retained bytes stay within the limit.
    @Test func bufferedDataAfterTheLimitIsDiscarded() async throws {
        let url = Self.url("burst")
        GearStubProtocol.register(url, .init(chunks: Self.chunks(6, size: 1_000)))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }

        await #expect(throws: GearDownloadError.tooLarge) {
            _ = try await Self.download(downloader, URLRequest(url: url), limit: 2_500)
        }
        let log = downloader.cancellationLog
        #expect(log.count == 1, "one cancellation, however much data was already in flight")
        #expect(log.first?.reason == .bodyOverLimit)
        #expect(log.first?.retainedBytes == 2_000)
        let ignored = log.first?.ignoredBytes ?? -1
        #expect(ignored >= 0 && ignored <= 3_000, "later chunks, if delivered at all, were ignored")
    }

    @Test func misleadingContentLengthDoesNotBypassTheLimit() async throws {
        let url = Self.url("misleading")
        GearStubProtocol.register(url, .init(headers: ["Content-Length": "100"], chunks: Self.chunks(5, size: 1_000)))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }
        await #expect(throws: GearDownloadError.tooLarge) {
            _ = try await Self.download(downloader, URLRequest(url: url), limit: 2_500)
        }
        #expect(downloader.cancellationLog.map(\.reason) == [.bodyOverLimit], "caught by the running count, not the header")
        #expect((downloader.cancellationLog.first?.retainedBytes ?? .max) <= 2_500)
    }

    /// Content-Length 50,000 against a 2,500-byte limit, with the whole body held. The call must
    /// fail before a single body byte is sent.
    @Test func declaredOversizeIsRefusedBeforeTheBody() async throws {
        let url = Self.url("declared")
        GearStubProtocol.register(url, .init(headers: ["Content-Length": "50000"], chunks: Self.chunks(50, size: 1_000), initialChunks: 0))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }
        await #expect(throws: GearDownloadError.tooLarge) {
            _ = try await Self.download(downloader, URLRequest(url: url), limit: 2_500)
        }
        let record = GearStubProtocol.record(url)
        #expect(Self.stub(record).delivered == 0, "refused from the header, with no body read")
        #expect(Self.stub(record).finished == false)
        #expect(downloader.cancellationLog.map(\.reason) == [.declaredLengthOverLimit])
        #expect(downloader.cancellationLog.first?.retainedBytes == 0)
        await Self.waitUntil { Self.stub(record).stopped }
        #expect(Self.stub(record).stopped)
    }

    @Test func bodyWithinLimitAndAnyStatusAreReturned() async throws {
        let ok = Self.url("ok")
        let missing = Self.url("missing")
        GearStubProtocol.register(ok, .init(chunks: Self.chunks(5, size: 500)))
        GearStubProtocol.register(missing, .init(status: 404, chunks: [Data("nope".utf8)]))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }

        let (data, response) = try await Self.download(downloader, URLRequest(url: ok), limit: 2_500)
        #expect(data.count == 2_500, "exactly at the limit is allowed")
        #expect(response.statusCode == 200)
        let (_, notFound) = try await Self.download(downloader, URLRequest(url: missing), limit: 2_500)
        #expect(notFound.statusCode == 404)
        #expect(downloader.cancellationLog.isEmpty)
    }

    @Test func cancellingTheCallerCancelsTheTransfer() async throws {
        let url = Self.url("slow")
        GearStubProtocol.register(url, .init(chunks: Self.chunks(100, size: 10), initialChunks: 2))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }

        let record = GearStubProtocol.record(url)
        let task = Task { try await downloader.data(for: URLRequest(url: url), limit: 1_000_000) }
        await Self.waitUntil { Self.stub(record).delivered == 2 }
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(Self.stub(record).finished == false)
        await Self.waitUntil { Self.stub(record).stopped }
        #expect(Self.stub(record).stopped)
        #expect(Self.stub(record).delivered == 2)
    }

    #if canImport(Darwin)
    /// A body served from URLCache passes the same limit. The cache entry is preloaded (and
    /// checked), the request allows cached data, and the URL loading system offers it to the
    /// protocol as `cachedResponse`; the stub serves it like the built-in HTTP protocol does,
    /// without touching its scripted "network" body. Apple-only: other Foundations integrate
    /// URLCache with custom protocols differently.
    @Test func cachedResponsesPassTheSameLimit() async throws {
        let url = Self.url("cached")
        GearStubProtocol.register(url, .init(chunks: [Data("small".utf8)]))
        let cache = URLCache(memoryCapacity: 10_000_000, diskCapacity: 0, directory: nil)
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        let cachedResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Cache-Control": "max-age=31536000",
                                                            "Content-Type": "application/octet-stream"])!
        cache.storeCachedResponse(CachedURLResponse(response: cachedResponse, data: Data(count: 5_000),
                                                    userInfo: nil, storagePolicy: .allowedInMemoryOnly),
                                  for: request)
        #expect(cache.cachedResponse(for: request)?.data.count == 5_000, "precondition: the oversized entry is cached")
        let downloader = Self.downloader(cache: cache)
        defer { downloader.invalidate() }

        await #expect(throws: GearDownloadError.tooLarge) {
            _ = try await Self.download(downloader, request, limit: 2_500)
        }
        let record = GearStubProtocol.record(url)
        #expect(GearStubProtocol.locked { record.cacheHits } == 1, "the loading system offered the cached response")
        #expect(GearStubProtocol.locked { record.networkRequests } == 0, "no network load")
        #expect(downloader.cancellationLog.map(\.reason) == [.bodyOverLimit])
        #expect(downloader.cancellationLog.first?.retainedBytes == 0, "the oversized cached body was not kept")
    }
    #endif

    // MARK: Concurrency limiter

    @Test func limiterNeverExceedsItsSlots() async {
        actor Counter {
            var active = 0, maximum = 0
            func enter() { active += 1; maximum = max(maximum, active) }
            func leave() { active -= 1 }
        }
        let limiter = GearAsyncLimiter(limit: 2)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await limiter.acquire()
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(20))
                    await counter.leave()
                    await limiter.release()
                }
            }
        }
        #expect(await counter.maximum == 2)
        #expect(await limiter.activeCount == 0)
    }

    // MARK: Cost-bounded cache (pure)

    @Test func costCacheEvictsLeastRecentlyUsedByCost() {
        var cache = GearCostCache<String, Int>(costLimit: 100, countLimit: 10)
        cache.insert(1, for: "a", cost: 40)
        cache.insert(2, for: "b", cost: 40)
        #expect(cache.value(for: "a") == 1) // "a" is now most recent
        cache.insert(3, for: "c", cost: 40) // over 100: evicts "b"
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "c") == 3)
        #expect(cache.totalCost == 80)

        cache.insert(4, for: "huge", cost: 101)
        #expect(cache.value(for: "huge") == nil, "an item larger than the cache is not stored")
        #expect(cache.totalCost == 80)

        cache.insert(5, for: "a", cost: 10) // replacing updates the cost
        #expect(cache.totalCost == 50)
        cache.removeAll()
        #expect(cache.count == 0 && cache.totalCost == 0)
    }

    @Test func costCacheRespectsCountLimit() {
        var cache = GearCostCache<Int, Int>(costLimit: 1_000, countLimit: 3)
        for index in 0..<5 { cache.insert(index, for: index, cost: 1) }
        #expect(cache.count == 3)
        #expect(cache.value(for: 0) == nil && cache.value(for: 1) == nil)
        #expect(cache.value(for: 4) == 4)
    }

    // MARK: Asset loader: coalescing, caching, failure, limits

    private static func stringLoader(
        downloader: GearBoundedDownloader,
        concurrent: Int = 3,
        byteLimit: Int = 10_000,
        costLimit: Int = 1_000
    ) -> GearAssetLoader<String> {
        GearAssetLoader<String>(
            downloader: downloader, maximumConcurrentLoads: concurrent, byteLimit: byteLimit, timeout: 5,
            costLimit: costLimit, countLimit: 50, cost: { $0.utf8.count },
            decode: { data in
                let text = String(decoding: data, as: UTF8.self)
                return text == "corrupt" ? nil : text
            }
        )
    }

    /// Both callers ask while the body is held, so they are concurrent by construction.
    @Test func sameURLRequestsAreCoalescedAndCached() async throws {
        let url = Self.url("coalesce")
        GearStubProtocol.register(url, .init(chunks: [Data("hello".utf8)], initialChunks: 0))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }
        let loader = Self.stringLoader(downloader: downloader)
        let record = GearStubProtocol.record(url)

        async let first = loader.load(url)
        async let second = loader.load(url)
        await Self.waitUntil { GearStubProtocol.locked { record.networkRequests } == 1 }
        #expect(loader.inFlightCount == 1)
        GearStubProtocol.release(url)
        let results = await [first, second]
        #expect(results == ["hello", "hello"])
        #expect(GearStubProtocol.locked { record.networkRequests } == 1, "one transfer for both callers")

        #expect(loader.cachedValue(for: url) == "hello")
        #expect(await loader.load(url) == "hello")
        #expect(GearStubProtocol.locked { record.networkRequests } == 1, "served from memory")
        #expect(loader.inFlightCount == 0)
    }

    @Test func failuresReturnNilAndAreNotCached() async throws {
        let corrupt = Self.url("corrupt")
        let oversized = Self.url("oversized")
        let missing = Self.url("missing")
        GearStubProtocol.register(corrupt, .init(chunks: [Data("corrupt".utf8)]))
        GearStubProtocol.register(oversized, .init(chunks: Self.chunks(3, size: 1_000)))
        GearStubProtocol.register(missing, .init(status: 404, chunks: [Data("not found".utf8)]))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }
        let loader = Self.stringLoader(downloader: downloader, byteLimit: 2_000)

        #expect(await loader.load(corrupt) == nil)
        #expect(await loader.load(oversized) == nil)
        #expect(await loader.load(missing) == nil)
        #expect(await loader.load(corrupt) == nil)
        #expect(Self.networkRequests(corrupt) == 2, "a failure is retried next time, not cached")
        #expect(loader.cachedCost == 0)
    }

    @Test func memoryCacheIsBoundedByCost() async throws {
        let downloader = Self.downloader()
        defer { downloader.invalidate() }
        let loader = Self.stringLoader(downloader: downloader, costLimit: 10)
        let first = Self.url("first")
        let second = Self.url("second")
        GearStubProtocol.register(first, .init(chunks: [Data("123456".utf8)]))
        GearStubProtocol.register(second, .init(chunks: [Data("abcdef".utf8)]))

        _ = await loader.load(first)
        _ = await loader.load(second)
        #expect(loader.cachedCost == 6)
        #expect(loader.cachedValue(for: first) == nil, "evicted to stay within the cost limit")
        #expect(loader.cachedValue(for: second) == "abcdef")
    }

    /// Six loads with a limit of two, every body held: exactly two transfers start, the others
    /// wait; releasing a running transfer lets the next one in. Nothing depends on timing.
    @Test func loaderBoundsConcurrentTransfers() async throws {
        let host = "gear-concurrency-\(UUID().uuidString.lowercased()).test"
        let urls = (0..<6).map { Self.url("item\($0)", host: host) }
        for url in urls { GearStubProtocol.register(url, .init(chunks: [Data("x".utf8), Data("y".utf8)], initialChunks: 0)) }
        let downloader = Self.downloader()
        defer { downloader.invalidate() }
        let loader = Self.stringLoader(downloader: downloader, concurrent: 2)
        let group = GearStubProtocol.group(host)
        func started() -> [URL] { urls.filter { Self.networkRequests($0) > 0 } }
        func finished() -> [URL] { urls.filter { Self.stub(GearStubProtocol.record($0)).finished } }

        let loads = Task {
            await withTaskGroup(of: String?.self) { tasks in
                for url in urls { tasks.addTask { await loader.load(url) } }
                var values: [String?] = []
                for await value in tasks { values.append(value) }
                return values
            }
        }

        await Self.waitUntil { started().count == 2 }
        #expect(started().count == 2, "only two transfers start")
        var released: Set<URL> = []
        while finished().count < urls.count {
            let running = started().filter { released.contains($0) == false }
            guard running.isEmpty == false else {
                Issue.record("no transfer to release; \(finished().count) of \(urls.count) finished")
                break
            }
            for url in running {
                released.insert(url)
                GearStubProtocol.release(url)
            }
            await Self.waitUntil { finished().count == released.count && (started().count > released.count || released.count == urls.count) }
        }
        let values = await loads.value
        #expect(values.count == 6 && values.allSatisfy { $0 == "xy" })
        #expect(GearStubProtocol.locked { group.maximumActive } == 2, "the limit was reached and never exceeded")
    }
}

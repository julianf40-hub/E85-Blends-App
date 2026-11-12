//
//  GearDownloadTests.swift
//  EightyFiveBlendsTests
//
//  Bounded downloads, concurrency limiting, the cost-bounded cache and request coalescing
//  (GearDownloading.swift). PORTABLE: Foundation only, no UIKit/ImageIO, so these also run outside
//  Apple platforms. Transfers go through the real URLSession data-task path with a scripted
//  URLProtocol stub (no network): headers, chunking, delays and cancellation are all controlled.
//  ImageIO decoding has its own Apple-only suite (GearImageDecoderTests.swift).
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import EightyFiveBlends

// MARK: - Scripted URLProtocol

/// Lets the stub hand itself to its own delivery queue. URLProtocol instances are driven by
/// URLSession's loader; the stub's mutable state is guarded by `lock`.
nonisolated struct GearUncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

nonisolated final class GearStubProtocol: URLProtocol {
    struct Script {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var chunkDelay: TimeInterval = 0.005
    }

    final class Record {
        var requests = 0
        var deliveredChunks = 0
        var stopped = false
        var active = 0
        var maximumActive = 0
    }

    private static let lock = NSLock()
    private static var scripts: [String: Script] = [:]
    private static var records: [String: Record] = [:]
    /// Concurrency is tracked per group (the URL's host), across URLs.
    private static var groups: [String: Record] = [:]

    /// Not reentrant: never call `record`, `group` or `register` inside `locked`.
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

    private var isStopped = false
    private var isDone = false
    private var group: Record?
    private let queue = DispatchQueue(label: "GearStubProtocol")

    /// Leaves the concurrency group exactly once, on finish or on stop.
    private func markDone() {
        Self.locked {
            guard isDone == false else { return }
            isDone = true
            group?.active -= 1
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url!.absoluteString
        let host = request.url!.host ?? ""
        let group = Self.group(host)
        let (script, record): (Script?, Record?) = Self.locked {
            let record = Self.records[key]
            record?.requests += 1
            self.group = group
            group.active += 1
            group.maximumActive = max(group.maximumActive, group.active)
            return (Self.scripts[key], record)
        }
        guard let script, let record else {
            markDone()
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: script.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        deliver(script, index: 0, record: record, group: group)
    }

    private func deliver(_ script: Script, index: Int, record: Record, group: Record) {
        let box = GearUncheckedBox(value: (self, record, group))
        queue.asyncAfter(deadline: .now() + script.chunkDelay) {
            let (stub, record, group) = box.value
            let stopped = Self.locked { stub.isStopped }
            if stopped { return }
            if index < script.chunks.count {
                Self.locked { record.deliveredChunks += 1 }
                stub.client?.urlProtocol(stub, didLoad: script.chunks[index])
                stub.deliver(script, index: index + 1, record: record, group: group)
            } else {
                stub.markDone()
                stub.client?.urlProtocolDidFinishLoading(stub)
            }
        }
    }

    override func stopLoading() {
        let key = request.url!.absoluteString
        Self.locked {
            if isDone == false { Self.records[key]?.stopped = true }
            isStopped = true
        }
        markDone()
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

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where condition() == false {
            try? await Task.sleep(for: .milliseconds(10))
        }
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

    @Test func chunkedResponseWithoutLengthIsCancelledAtTheLimit() async throws {
        let url = Self.url("chunked")
        GearStubProtocol.register(url, .init(chunks: Self.chunks(20, size: 1_000), chunkDelay: 0.01))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }

        await #expect(throws: GearDownloadError.tooLarge) {
            _ = try await downloader.data(for: URLRequest(url: url), limit: 2_500)
        }
        let record = GearStubProtocol.record(url)
        await Self.waitUntil { GearStubProtocol.locked { record.stopped } }
        #expect(GearStubProtocol.locked { record.stopped }, "the transfer is cancelled")
        #expect(GearStubProtocol.locked { record.deliveredChunks } < 20, "the rest of the body is never read")
    }

    @Test func misleadingContentLengthDoesNotBypassTheLimit() async throws {
        let url = Self.url("misleading")
        GearStubProtocol.register(url, .init(headers: ["Content-Length": "100"], chunks: Self.chunks(5, size: 1_000)))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }
        await #expect(throws: GearDownloadError.tooLarge) {
            _ = try await downloader.data(for: URLRequest(url: url), limit: 2_500)
        }
    }

    @Test func declaredOversizeIsRefusedBeforeTheBody() async throws {
        let url = Self.url("declared")
        GearStubProtocol.register(url, .init(headers: ["Content-Length": "50000"], chunks: Self.chunks(50, size: 1_000), chunkDelay: 0.02))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }
        await #expect(throws: GearDownloadError.tooLarge) {
            _ = try await downloader.data(for: URLRequest(url: url), limit: 2_500)
        }
        let record = GearStubProtocol.record(url)
        #expect(GearStubProtocol.locked { record.deliveredChunks } <= 1)
    }

    @Test func bodyWithinLimitAndAnyStatusAreReturned() async throws {
        let ok = Self.url("ok")
        let missing = Self.url("missing")
        GearStubProtocol.register(ok, .init(chunks: Self.chunks(5, size: 500)))
        GearStubProtocol.register(missing, .init(status: 404, chunks: [Data("nope".utf8)]))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }

        let (data, response) = try await downloader.data(for: URLRequest(url: ok), limit: 2_500)
        #expect(data.count == 2_500, "exactly at the limit is allowed")
        #expect(response.statusCode == 200)
        let (_, notFound) = try await downloader.data(for: URLRequest(url: missing), limit: 2_500)
        #expect(notFound.statusCode == 404)
    }

    @Test func cancellingTheCallerCancelsTheTransfer() async throws {
        let url = Self.url("slow")
        GearStubProtocol.register(url, .init(chunks: Self.chunks(100, size: 10), chunkDelay: 0.05))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }

        let task = Task { try await downloader.data(for: URLRequest(url: url), limit: 1_000_000) }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        let record = GearStubProtocol.record(url)
        await Self.waitUntil { GearStubProtocol.locked { record.stopped } }
        #expect(GearStubProtocol.locked { record.stopped })
        #expect(GearStubProtocol.locked { record.deliveredChunks } < 100)
    }

    #if canImport(Darwin)
    /// Apple Foundation serves URLCache hits through the same delegate path, so a cached body
    /// larger than the limit is refused too. (Not asserted on other Foundations, whose URLCache
    /// integration differs.)
    @Test func cachedResponsesPassTheSameLimit() async throws {
        let url = Self.url("cached")
        GearStubProtocol.register(url, .init(chunks: [Data("small".utf8)]))
        let cache = URLCache(memoryCapacity: 10_000_000, diskCapacity: 0, directory: nil)
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        let cachedResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Cache-Control": "max-age=31536000"])!
        cache.storeCachedResponse(CachedURLResponse(response: cachedResponse, data: Data(count: 5_000)), for: request)
        let downloader = Self.downloader(cache: cache)
        defer { downloader.invalidate() }

        await #expect(throws: GearDownloadError.tooLarge) {
            _ = try await downloader.data(for: request, limit: 2_500)
        }
        #expect(GearStubProtocol.record(url).requests == 0, "served from the cache, still limited")
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

    @Test func sameURLRequestsAreCoalescedAndCached() async throws {
        let url = Self.url("coalesce")
        GearStubProtocol.register(url, .init(chunks: [Data("hello".utf8)], chunkDelay: 0.05))
        let downloader = Self.downloader()
        defer { downloader.invalidate() }
        let loader = Self.stringLoader(downloader: downloader)

        async let first = loader.load(url)
        async let second = loader.load(url)
        let results = await [first, second]
        #expect(results == ["hello", "hello"])
        #expect(GearStubProtocol.record(url).requests == 1, "one transfer for both callers")

        #expect(loader.cachedValue(for: url) == "hello")
        #expect(await loader.load(url) == "hello")
        #expect(GearStubProtocol.record(url).requests == 1, "served from memory")
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
        #expect(GearStubProtocol.record(corrupt).requests == 2, "a failure is retried next time, not cached")
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

    @Test func loaderBoundsConcurrentTransfers() async throws {
        let host = "gear-concurrency-\(UUID().uuidString.lowercased()).test"
        let urls = (0..<6).map { Self.url("item\($0)", host: host) }
        for url in urls { GearStubProtocol.register(url, .init(chunks: [Data("x".utf8), Data("y".utf8)], chunkDelay: 0.03)) }
        let downloader = Self.downloader()
        defer { downloader.invalidate() }
        let loader = Self.stringLoader(downloader: downloader, concurrent: 2)

        await withTaskGroup(of: String?.self) { group in
            for url in urls { group.addTask { await loader.load(url) } }
            for await value in group { #expect(value == "xy") }
        }
        let group = GearStubProtocol.group(host)
        let maximum = GearStubProtocol.locked { group.maximumActive }
        #expect(maximum <= 2)
        #expect(maximum >= 1)
    }
}

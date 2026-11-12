//
//  GearCatalogSourceTests.swift
//  EightyFiveBlendsTests
//
//  The Internal-only staging catalog preview (GearCatalogSource / GearCatalogStore.selectSource):
//  default and persisted selection, per-source cache/ETag/ordering isolation, switching during an
//  in-flight request, unavailable staging, and production updates after a newer staging
//  publication. Local fixtures and injected networking only: no bucket, no upload.
//  Compiled only where the feature exists (DEBUG or INTERNAL_BUILD), like the feature itself.
//

#if DEBUG || INTERNAL_BUILD
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import EightyFiveBlends

@MainActor
struct GearCatalogSourceTests {
    private static let production = URL(string: "https://example.supabase.co/storage/v1/object/public/recommended-gear/catalog-v1.json")!
    private static let staging = URL(string: "https://example.supabase.co/storage/v1/object/public/recommended-gear/staging/catalog-v1.json")!

    private static func brand(_ id: String) -> [String: Any] {
        ["id": id, "kind": "brand", "name": "Brand \(id)", "tagline": "Tools", "description": "Details",
         "ctaTitle": "View products", "destinationURL": "https://example.com/\(id)", "more": [String: Any]()]
    }

    private static func document(_ ids: [String], revision: String, publishedAt: Double) -> Data {
        let object: [String: Any] = ["schemaVersion": 1, "revision": revision, "publishedAt": publishedAt,
                                     "brands": ids.map(brand)]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Replies immediately per URL, or holds requests for `gated` URLs until `release` is called.
    private final class Server {
        var replies: [URL: [(Int, Data, [String: String])]] = [:]
        var gated: Set<URL> = []
        var requests: [URLRequest] = []
        private var held: [(URL, CheckedContinuation<(Data, URLResponse), Error>)] = []

        var heldCount: Int { held.count }

        func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let url = request.url!
            if gated.contains(url) {
                return try await withCheckedThrowingContinuation { held.append((url, $0)) }
            }
            guard var queue = replies[url], queue.isEmpty == false else { throw URLError(.notConnectedToInternet) }
            let (status, data, headers) = queue.removeFirst()
            replies[url] = queue
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }

        func release(status: Int, data: Data, headers: [String: String] = [:]) {
            let (url, continuation) = held.removeFirst()
            continuation.resume(returning: (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!))
        }
    }

    private struct Harness {
        let suite = "GearCatalogSourceTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let server = Server()

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        @MainActor
        func makeStore(stagingConfigured: Bool = true) -> GearCatalogStore {
            let server = self.server
            var endpoints: [GearCatalogSource: URL] = [.production: GearCatalogSourceTests.production]
            if stagingConfigured { endpoints[.staging] = GearCatalogSourceTests.staging }
            return GearCatalogStore(defaults: defaults, endpoints: endpoints,
                                    fetch: { try await server.fetch($0) }, observesApplication: false)
        }

        func tearDown() { defaults.removePersistentDomain(forName: suite) }
    }

    private static func ids(_ store: GearCatalogStore) -> [String] { store.content.pages.map(\.id) }

    // MARK: -

    @Test func defaultsToProductionAndSelectionSurvivesRestart() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        #expect(store.activeSource == .production)
        #expect(Self.ids(store) == FeaturedGearPage.catalog.map(\.id), "production starts on the bundled catalog")

        store.selectSource(.staging)
        #expect(harness.makeStore().activeSource == .staging)
        harness.makeStore().selectSource(.production)
        #expect(harness.makeStore().activeSource == .production)

        harness.defaults.set("not-a-source", forKey: GearCatalogStore.selectedSourceKey)
        #expect(harness.makeStore().activeSource == .production, "unknown values fall back to production")
    }

    @Test func stagingNeverShowsBundledOrProductionContent() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        try store.accept(Self.document(["prod-brand"], revision: "p1", publishedAt: 1_000))
        let generation = store.generation

        store.selectSource(.staging)
        #expect(store.content.pages.isEmpty, "nothing received from staging yet")
        #expect(store.content.moreSponsor == nil)
        #expect(store.content.moreFeaturedBrands.isEmpty)
        #expect(store.generation > generation, "the carousel resets on a switch")

        store.selectSource(.production)
        #expect(Self.ids(store) == ["prod-brand"], "production content returns immediately, before any refresh")
    }

    @Test func cachesETagsAndOrderingAreIsolatedPerSource() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.server.replies[Self.production] = [
            (200, Self.document(["prod-brand"], revision: "p1", publishedAt: 1_000), ["ETag": "\"prod\""]),
            (304, Data(), [:])
        ]
        harness.server.replies[Self.staging] = [
            (200, Self.document(["staging-brand"], revision: "s1", publishedAt: 5_000), ["ETag": "\"staging\""]),
            (304, Data(), [:])
        ]
        let store = harness.makeStore()
        #expect(await store.refresh(force: true) == .updated)
        #expect(await store.selectSourceAndRefresh(.staging) == .updated)
        #expect(Self.ids(store) == ["staging-brand"])

        // Restart in staging: staging's own copy, not production's.
        let relaunched = harness.makeStore()
        #expect(relaunched.activeSource == .staging)
        #expect(Self.ids(relaunched) == ["staging-brand"])
        #expect(await relaunched.refresh(force: true) == .notModified)
        #expect(harness.server.requests.last?.url == Self.staging)
        #expect(harness.server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"staging\"")

        relaunched.selectSource(.production)
        #expect(Self.ids(relaunched) == ["prod-brand"])
        #expect(await relaunched.refresh(force: true) == .notModified)
        #expect(harness.server.requests.last?.url == Self.production)
        #expect(harness.server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"prod\"")

        // A staging revision name means nothing to production's history.
        #expect(try relaunched.accept(Self.document(["prod-brand-2"], revision: "s1", publishedAt: 1_500)))
    }

    @Test func newerStagingPublicationNeverBlocksProductionUpdates() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        try store.accept(Self.document(["prod-v1"], revision: "p1", publishedAt: 1_000))
        store.selectSource(.staging)
        try store.accept(Self.document(["staging"], revision: "s1", publishedAt: 9_000))

        store.selectSource(.production)
        #expect(try store.accept(Self.document(["prod-v2"], revision: "p2", publishedAt: 2_000)))
        #expect(Self.ids(store) == ["prod-v2"])
        // Production's own ordering still applies.
        #expect(throws: GearCatalog.ValidationError.stale) {
            try store.accept(Self.document(["prod-v1"], revision: "p0", publishedAt: 1_500))
        }
        #expect(Self.ids(harness.makeStore()) == ["prod-v2"])
    }

    @Test func responseForThePreviousSourceIsDiscardedAfterASwitch() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.server.gated = [Self.production]
        harness.server.replies[Self.staging] = [(200, Self.document(["staging-brand"], revision: "s1", publishedAt: 5_000), [:])]
        let store = harness.makeStore()

        let productionRefresh = Task { await store.refresh(force: true) }
        for _ in 0..<200 where harness.server.heldCount == 0 { await Task.yield() }
        #expect(harness.server.heldCount == 1, "production request is in flight")

        #expect(await store.selectSourceAndRefresh(.staging) == .updated)
        harness.server.release(status: 200, data: Self.document(["late-prod-brand"], revision: "p1", publishedAt: 1_000))
        #expect(await productionRefresh.value == .superseded)
        #expect(Self.ids(store) == ["staging-brand"], "the late production response never reaches staging")
        #expect(store.lastRefreshOutcome == .updated)

        store.selectSource(.production)
        #expect(Self.ids(store) == FeaturedGearPage.catalog.map(\.id), "and it was not saved as production either")
    }

    @Test func unavailableStagingShowsNothingAndLeavesProductionAlone() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.server.replies[Self.staging] = [(404, Data("{}".utf8), [:])]
        let store = harness.makeStore()
        try store.accept(Self.document(["prod-brand"], revision: "p1", publishedAt: 1_000))

        #expect(await store.selectSourceAndRefresh(.staging) == .httpStatus(404))
        #expect(store.lastRefreshOutcome == .httpStatus(404))
        #expect(store.content.pages.isEmpty)
        #expect(await store.refresh(force: true) == .failed, "offline staging also shows nothing")
        #expect(store.content.pages.isEmpty)

        store.selectSource(.production)
        #expect(store.lastRefreshOutcome == nil, "diagnostics are per source")
        #expect(Self.ids(store) == ["prod-brand"])

        let unconfigured = try Harness()
        defer { unconfigured.tearDown() }
        let noStaging = unconfigured.makeStore(stagingConfigured: false)
        #expect(await noStaging.selectSourceAndRefresh(.staging) == .notConfigured)
        #expect(noStaging.content.pages.isEmpty)
        #expect(unconfigured.server.requests.isEmpty)
    }

    @Test func stagingFixturesUseDownloadRulesAndNeverTouchProduction() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        try store.accept(Self.document(["prod-brand"], revision: "p1", publishedAt: 1_000))
        #expect(throws: GearCatalog.ValidationError.self) {
            try store.acceptStagingFixture(Self.document(["fixture"], revision: "f1", publishedAt: 2_000))
        }
        #expect(Self.ids(store) == ["prod-brand"], "fixtures can't be applied to production")

        store.selectSource(.staging)
        #expect(try store.acceptStagingFixture(Self.document(["fixture"], revision: "f1", publishedAt: 2_000)))
        #expect(store.lastRefreshOutcome == .updated)
        #expect(Self.ids(store) == ["fixture"])
        #expect(throws: GearCatalog.ValidationError.stale) {
            try store.acceptStagingFixture(Self.document(["older"], revision: "f0", publishedAt: 1_500))
        }

        store.resetStagingData()
        #expect(store.content.pages.isEmpty)
        #expect(try store.acceptStagingFixture(Self.document(["older"], revision: "f0", publishedAt: 1_500)), "a reset replays from scratch")

        store.selectSource(.production)
        #expect(Self.ids(store) == ["prod-brand"])
        #expect(try store.accept(Self.document(["prod-brand-2"], revision: "p2", publishedAt: 1_001)), "production ordering unaffected")
    }

    @Test func switchingRefreshesImmediatelyEvenWhenRecentlyRefreshed() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.server.replies[Self.production] = [
            (200, Self.document(["prod-brand"], revision: "p1", publishedAt: 1_000), [:]),
            (304, Data(), [:])
        ]
        harness.server.replies[Self.staging] = [(200, Self.document(["staging-brand"], revision: "s1", publishedAt: 5_000), [:])]
        let store = harness.makeStore()
        #expect(await store.refresh() == .updated)
        #expect(await store.refresh() == .throttled)
        #expect(await store.selectSourceAndRefresh(.staging) == .updated)
        #expect(await store.selectSourceAndRefresh(.production) == .notModified)
        #expect(harness.server.requests.map(\.url) == [Self.production, Self.staging, Self.production])
    }
}
#endif

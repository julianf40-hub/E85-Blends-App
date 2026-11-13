//
//  GearCatalogSourceTests.swift
//  EightyFiveBlendsTests
//
//  The staging catalog preview (GearCatalogSource / GearCatalogStore.selectSource): default and
//  persisted selection, per-source cache/ETag/ordering isolation, switching during an in-flight
//  request, unavailable staging, production updates after a newer staging publication, and the
//  preview eligibility gate (TestFlight/Xcode eligible, App Store and unknown on production).
//  Local fixtures, injected networking and an injected environment provider only: no bucket, no
//  upload, no StoreKit. Compiled into every configuration, like the feature itself.
//

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
            release(at: 0, status: status, data: data, headers: headers)
        }

        /// Releases the held request at `index` (in the order the requests were made).
        func release(at index: Int, status: Int, data: Data, headers: [String: String] = [:]) {
            let (url, continuation) = held.remove(at: index)
            continuation.resume(returning: (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!))
        }

        func fail(at index: Int, _ error: URLError = URLError(.timedOut)) {
            held.remove(at: index).1.resume(throwing: error)
        }
    }

    /// Lets started refresh tasks reach the server. Deterministic: yields until the expected number
    /// of requests is held (no sleeps), bounded so a bug fails rather than hangs.
    private static func waitForHeld(_ server: Server, _ count: Int) async {
        for _ in 0..<1_000 where server.heldCount < count { await Task.yield() }
    }

    /// Asserts that a new refresh reports "in progress" instead of issuing a duplicate request.
    /// If a buggy store did issue one, it is recorded and released so the test fails, not hangs.
    private static func expectInProgress(_ store: GearCatalogStore, _ server: Server, held: Int,
                                         _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) async {
        let probe = Task { await store.refresh(force: true) }
        await waitForHeld(server, held + 1)
        if server.heldCount > held {
            Issue.record("duplicate request issued: \(comment)", sourceLocation: sourceLocation)
            server.release(at: held, status: 304, data: Data())
        }
        #expect(await probe.value == .inProgress, comment, sourceLocation: sourceLocation)
    }

    private static func productionETag(_ defaults: UserDefaults) -> String? { defaults.string(forKey: "recommendedGear.etag.v1") }
    private static func productionRevisions(_ defaults: UserDefaults) -> [String] { defaults.stringArray(forKey: "recommendedGear.acceptedRevisions.v1") ?? [] }
    private static func stagingKeysPresent(_ defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("recommendedGear.staging.") }.sorted()
    }

    /// Stands in for StoreKit's verified AppTransaction environment. Answers from `answers` in
    /// order (nil once exhausted), or, when `gated`, holds each call until `release`.
    private final class EnvironmentProvider: ReferralRevenueEnvironmentProviding, @unchecked Sendable {
        var answers: [ReferralRevenueEnvironment?]
        var gated = false
        private(set) var calls = 0
        private var held: [CheckedContinuation<ReferralRevenueEnvironment?, Never>] = []
        var heldCount: Int { held.count }

        init(_ answers: [ReferralRevenueEnvironment?] = []) { self.answers = answers }

        func currentEnvironment() async -> ReferralRevenueEnvironment? {
            calls += 1
            if gated { return await withCheckedContinuation { held.append($0) } }
            return answers.isEmpty ? nil : answers.removeFirst()
        }

        func release(_ environment: ReferralRevenueEnvironment?) {
            held.removeFirst().resume(returning: environment)
        }
    }

    private static func waitForHeld(_ provider: EnvironmentProvider, _ count: Int) async {
        for _ in 0..<1_000 where provider.heldCount < count { await Task.yield() }
    }

    private struct Harness {
        let suite = "GearCatalogSourceTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let server = Server()

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        @MainActor
        /// Eligible by default (the TestFlight case), explicitly, so these tests behave the same in
        /// Debug and Release builds of the test target.
        func makeStore(stagingConfigured: Bool = true,
                       eligibility: GearCatalogPreviewEligibility = .eligible,
                       provider: EnvironmentProvider? = nil) -> GearCatalogStore {
            let server = self.server
            var endpoints: [GearCatalogSource: URL] = [.production: GearCatalogSourceTests.production]
            if stagingConfigured { endpoints[.staging] = GearCatalogSourceTests.staging }
            return GearCatalogStore(defaults: defaults, endpoints: endpoints,
                                    fetch: { try await server.fetch($0) },
                                    previewEligibility: eligibility, environmentProvider: provider,
                                    observesApplication: false)
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

    // MARK: Request invalidation (held responses, no timing)

    /// Production A is held; Production -> Staging -> Production; a fresh request B starts (it is
    /// not "in progress" because of A). B completes, then A completes: only B applies, and A
    /// changes nothing even though its source is active again and its publishedAt is newer.
    @Test func obsoleteProductionResponseAfterRoundTripIsDiscarded_newerFirst() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.server.gated = [Self.production]
        let store = harness.makeStore()

        let requestA = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 1)
        store.selectSource(.staging)
        store.selectSource(.production)
        let requestB = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 2)
        #expect(harness.server.heldCount == 2, "B started instead of returning in progress")

        harness.server.release(at: 1, status: 200, data: Self.document(["brand-b"], revision: "b", publishedAt: 2_000), headers: ["ETag": "\"b\""])
        #expect(await requestB.value == .updated)
        harness.server.release(at: 0, status: 200, data: Self.document(["brand-a"], revision: "a", publishedAt: 9_000), headers: ["ETag": "\"a\""])
        #expect(await requestA.value == .superseded)

        #expect(Self.ids(store) == ["brand-b"])
        #expect(Self.productionETag(harness.defaults) == "\"b\"")
        #expect(harness.defaults.double(forKey: "recommendedGear.lastPublishedAt.v1") == 2_000)
        #expect(Self.productionRevisions(harness.defaults) == ["b"])
        #expect(store.lastRefreshOutcome == .updated)
        #expect(Self.ids(harness.makeStore()) == ["brand-b"])
    }

    @Test func obsoleteProductionResponseAfterRoundTripIsDiscarded_olderFirst() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.server.gated = [Self.production]
        let store = harness.makeStore()

        let requestA = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 1)
        store.selectSource(.staging)
        store.selectSource(.production)
        let requestB = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 2)

        harness.server.release(at: 0, status: 200, data: Self.document(["brand-a"], revision: "a", publishedAt: 1_000), headers: ["ETag": "\"a\""])
        #expect(await requestA.value == .superseded)
        #expect(Self.ids(store) == FeaturedGearPage.catalog.map(\.id), "A changed nothing")
        #expect(Self.productionETag(harness.defaults) == nil)
        #expect(Self.productionRevisions(harness.defaults).isEmpty)
        #expect(store.lastRefreshOutcome == nil)
        await Self.expectInProgress(store, harness.server, held: 1, "A's completion did not clear B's tracking")

        harness.server.release(at: 0, status: 200, data: Self.document(["brand-b"], revision: "b", publishedAt: 2_000), headers: ["ETag": "\"b\""])
        #expect(await requestB.value == .updated)
        #expect(Self.ids(store) == ["brand-b"])
        #expect(Self.productionRevisions(harness.defaults) == ["b"])
    }

    @Test func stagingResetDiscardsTheInFlightStagingResponse() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.server.gated = [Self.staging]
        let store = harness.makeStore()
        store.selectSource(.staging)

        let old = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 1)
        store.resetStagingData()
        harness.server.release(status: 200, data: Self.document(["old-staging"], revision: "s1", publishedAt: 5_000), headers: ["ETag": "\"s1\""])
        #expect(await old.value == .superseded)
        #expect(store.content.pages.isEmpty, "staging stays reset")
        #expect(Self.stagingKeysPresent(harness.defaults).isEmpty, "no cache, ETag, ordering or revisions written")
        #expect(store.lastRefreshOutcome == nil)
    }

    @Test func obsoleteCompletionAfterResetDoesNotUntrackTheNewRequest() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.server.gated = [Self.staging]
        let store = harness.makeStore()
        store.selectSource(.staging)

        let old = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 1)
        store.resetStagingData()
        let new = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 2)
        #expect(harness.server.heldCount == 2)

        harness.server.release(at: 0, status: 200, data: Self.document(["old-staging"], revision: "s1", publishedAt: 5_000))
        #expect(await old.value == .superseded)
        await Self.expectInProgress(store, harness.server, held: 1, "the new request is still tracked")

        harness.server.release(at: 0, status: 200, data: Self.document(["new-staging"], revision: "s2", publishedAt: 6_000))
        #expect(await new.value == .updated)
        #expect(Self.ids(store) == ["new-staging"])
        harness.server.gated = []
        #expect(await store.refresh(force: true) != .inProgress, "tracking cleared once the new request finished")
    }

    @Test func loadedFixtureStaysAuthoritativeOverAnEarlierDownload() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.server.gated = [Self.staging]
        let store = harness.makeStore()
        store.selectSource(.staging)

        let download = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 1)
        #expect(try store.acceptStagingFixture(Self.document(["fixture"], revision: "f1", publishedAt: 1_000)))
        // Newer publishedAt: only invalidation, not ordering, can keep it out.
        harness.server.release(status: 200, data: Self.document(["downloaded"], revision: "d1", publishedAt: 9_000), headers: ["ETag": "\"d1\""])
        #expect(await download.value == .superseded)
        #expect(Self.ids(store) == ["fixture"])
        #expect(store.lastRefreshOutcome == .updated, "the fixture's status, not the download's")
        #expect(harness.defaults.string(forKey: "recommendedGear.staging.etag.v1") == nil)
        #expect(harness.defaults.stringArray(forKey: "recommendedGear.staging.acceptedRevisions.v1") == ["f1"])
        #expect(Self.ids(harness.makeStore()) == ["fixture"])
    }

    @Test func supersededFailuresDoNotOverwriteTheCurrentStatus() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.server.gated = [Self.production, Self.staging]
        let store = harness.makeStore()

        let requestA = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 1)
        store.selectSource(.staging)
        store.selectSource(.production)
        let requestB = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 2)
        harness.server.release(at: 1, status: 404, data: Data())
        #expect(await requestB.value == .httpStatus(404))
        harness.server.fail(at: 0)
        #expect(await requestA.value == .superseded)
        #expect(store.lastRefreshOutcome == .httpStatus(404), "the obsolete timeout is not reported")

        // Same for staging after a fixture.
        store.selectSource(.staging)
        let stale = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 1)
        try store.acceptStagingFixture(Self.document(["fixture"], revision: "f1", publishedAt: 1_000))
        harness.server.fail(at: 0, URLError(.notConnectedToInternet))
        #expect(await stale.value == .superseded)
        #expect(store.lastRefreshOutcome == .updated)
        #expect(Self.ids(store) == ["fixture"])
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

    // MARK: - Preview eligibility (TestFlight vs App Store)

    /// A TestFlight session that selected Staging and holds a staging publication.
    private static func seedStagingPreview(_ harness: Harness) throws {
        let store = harness.makeStore()
        #expect(store.selectSource(.staging))
        #expect(try store.acceptStagingFixture(Self.document(["staging-brand"], revision: "s1", publishedAt: 5_000)))
    }

    @Test func eligibilityFollowsTheVerifiedStoreEnvironment() {
        #expect(GearCatalogPreviewEligibility.from(.sandbox) == .eligible, "TestFlight and Xcode builds")
        #expect(GearCatalogPreviewEligibility.from(.production) == .ineligible, "App Store installs")
        #expect(GearCatalogPreviewEligibility.from(nil) == .unknown, "unverified, offline, timed out")
        #if DEBUG || INTERNAL_BUILD
        #expect(GearCatalogPreviewEligibility.compiledDefault == .eligible)
        #else
        #expect(GearCatalogPreviewEligibility.compiledDefault == .unknown, "Release builds must ask StoreKit")
        #endif
    }

    @Test func eligibleInstallDefaultsToProductionUntilStagingIsChosen() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let provider = EnvironmentProvider([.sandbox])
        let store = harness.makeStore(eligibility: .unknown, provider: provider)
        #expect(await store.resolvePreviewEligibility() == false, "no saved selection: nothing switches")
        #expect(store.previewEligibility == .eligible)
        #expect(store.activeSource == .production)
        #expect(Self.ids(store) == FeaturedGearPage.catalog.map(\.id))
        #expect(harness.server.requests.isEmpty)
        #expect(harness.defaults.string(forKey: GearCatalogStore.selectedSourceKey) == nil)

        // Explicit opt-in, then the empty staging state (nothing published yet).
        harness.server.replies[Self.staging] = [(400, Data(#"{"error":"not_found"}"#.utf8), [:])]
        #expect(await store.selectSourceAndRefresh(.staging) == .httpStatus(400))
        #expect(store.activeSource == .staging)
        #expect(store.content.pages.isEmpty)
        #expect(harness.defaults.string(forKey: GearCatalogStore.selectedSourceKey) == "staging")
    }

    @Test func unknownEnvironmentStaysOnProductionAndRejectsEveryStagingOperation() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try Self.seedStagingPreview(harness)
        let seeded = Self.stagingKeysPresent(harness.defaults)

        let store = harness.makeStore(eligibility: .unknown)
        #expect(store.activeSource == .production, "a saved Staging selection is ignored")
        #expect(Self.ids(store) == FeaturedGearPage.catalog.map(\.id), "cached staging content is never shown")

        #expect(store.selectSource(.staging) == false)
        #expect(await store.selectSourceAndRefresh(.staging) == .previewUnavailable)
        #expect(throws: GearCatalog.ValidationError.self) {
            try store.acceptStagingFixture(Self.document(["fixture"], revision: "f9", publishedAt: 9_000))
        }
        #expect(store.resetStagingData() == false)
        #expect(store.activeSource == .production)
        #expect(Self.ids(store) == FeaturedGearPage.catalog.map(\.id))
        #expect(harness.server.requests.isEmpty, "no staging request was made")
        #expect(Self.stagingKeysPresent(harness.defaults) == seeded, "kept, unseen, until the environment is known")
        #expect(harness.defaults.string(forKey: GearCatalogStore.selectedSourceKey) == "staging")
        // Selecting production is always allowed (and here already active).
        #expect(store.selectSource(.production))
    }

    @Test func confirmedTestFlightRestoresTheSavedStagingSelection() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try Self.seedStagingPreview(harness)
        let provider = EnvironmentProvider([nil, .sandbox])
        let store = harness.makeStore(eligibility: .unknown, provider: provider)
        let generation = store.generation

        #expect(await store.resolvePreviewEligibility() == false, "no answer yet (offline at launch)")
        #expect(store.previewEligibility == .unknown)
        #expect(store.activeSource == .production)

        #expect(await store.resolvePreviewEligibility(), "retried, e.g. on returning to the foreground")
        #expect(store.previewEligibility == .eligible)
        #expect(store.activeSource == .staging)
        #expect(Self.ids(store) == ["staging-brand"], "staging's own cache, shown immediately")
        #expect(store.generation > generation)
        #expect(provider.calls == 2)
        #expect(await store.resolvePreviewEligibility() == false)
        #expect(provider.calls == 2, "decided once per launch")
    }

    @Test func appStoreInstallReplacingTestFlightForgetsStagingAndStaysOnProduction() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.server.replies[Self.production] = [(200, Self.document(["prod-brand"], revision: "p1", publishedAt: 1_000), ["ETag": "\"p1\""])]
        #expect(await harness.makeStore().refresh() == .updated)
        try Self.seedStagingPreview(harness)
        #expect(Self.stagingKeysPresent(harness.defaults).isEmpty == false)

        // Same bundle ID, same defaults: the App Store build launches over the TestFlight data.
        let provider = EnvironmentProvider([.production, .sandbox])
        let store = harness.makeStore(eligibility: .unknown, provider: provider)
        #expect(store.activeSource == .production)
        #expect(Self.ids(store) == ["prod-brand"], "never the cached staging content, even before StoreKit answers")

        #expect(await store.resolvePreviewEligibility() == false)
        #expect(store.previewEligibility == .ineligible)
        #expect(Self.stagingKeysPresent(harness.defaults).isEmpty, "staging cache, ETag and ordering state deleted")
        #expect(harness.defaults.string(forKey: GearCatalogStore.selectedSourceKey) == nil)
        #expect(Self.ids(store) == ["prod-brand"])
        #expect(Self.productionRevisions(harness.defaults) == ["p1"], "production state untouched")
        #expect(Self.productionETag(harness.defaults) == "\"p1\"")

        #expect(store.selectSource(.staging) == false)
        #expect(await store.selectSourceAndRefresh(.staging) == .previewUnavailable)
        #expect(throws: GearCatalog.ValidationError.self) {
            try store.acceptStagingFixture(Self.document(["fixture"], revision: "f1", publishedAt: 9_000))
        }
        #expect(store.resetStagingData() == false)
        #expect(Self.stagingKeysPresent(harness.defaults).isEmpty)
        #expect(await store.resolvePreviewEligibility() == false)
        #expect(store.previewEligibility == .ineligible, "a later answer cannot re-enable the preview")
        #expect(provider.calls == 1)
    }

    @Test func ineligibleAtLaunchPurgesSavedStagingState() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try Self.seedStagingPreview(harness)
        let store = harness.makeStore(eligibility: .ineligible)
        #expect(store.activeSource == .production)
        #expect(Self.ids(store) == FeaturedGearPage.catalog.map(\.id))
        #expect(Self.stagingKeysPresent(harness.defaults).isEmpty)
        #expect(harness.defaults.string(forKey: GearCatalogStore.selectedSourceKey) == nil)
    }

    @Test func productionResponseInFlightWhenTestFlightIsConfirmedIsDiscarded() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try Self.seedStagingPreview(harness)
        harness.server.gated = [Self.production]
        let provider = EnvironmentProvider()
        provider.gated = true
        let store = harness.makeStore(eligibility: .unknown, provider: provider)

        let productionRequest = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 1)
        let resolution = Task { await store.resolvePreviewEligibility() }
        await Self.waitForHeld(provider, 1)
        #expect(await store.resolvePreviewEligibility() == false, "a concurrent check does not start a second one")
        provider.release(.sandbox)
        #expect(await resolution.value)
        #expect(store.activeSource == .staging)

        harness.server.release(status: 200, data: Self.document(["prod-brand"], revision: "p1", publishedAt: 1_000), headers: ["ETag": "\"p1\""])
        #expect(await productionRequest.value == .superseded)
        #expect(Self.ids(store) == ["staging-brand"])
        #expect(Self.productionRevisions(harness.defaults).isEmpty, "the obsolete production response wrote nothing")
        #expect(Self.productionETag(harness.defaults) == nil)
        #expect(provider.calls == 1)
    }

    @Test func productionResponseInFlightWhenAppStoreIsConfirmedStillApplies() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try Self.seedStagingPreview(harness)
        harness.server.gated = [Self.production]
        let provider = EnvironmentProvider([.production])
        let store = harness.makeStore(eligibility: .unknown, provider: provider)

        let productionRequest = Task { await store.refresh(force: true) }
        await Self.waitForHeld(harness.server, 1)
        #expect(await store.resolvePreviewEligibility() == false)
        #expect(store.previewEligibility == .ineligible)
        harness.server.release(status: 200, data: Self.document(["prod-brand"], revision: "p1", publishedAt: 1_000))
        #expect(await productionRequest.value == .updated, "production was the active source throughout")
        #expect(Self.ids(store) == ["prod-brand"])
        #expect(Self.stagingKeysPresent(harness.defaults).isEmpty)
    }
}

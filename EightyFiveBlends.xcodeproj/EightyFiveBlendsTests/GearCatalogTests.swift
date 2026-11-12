//
//  GearCatalogTests.swift
//  EightyFiveBlendsTests
//
//  Remote Recommended Gear catalog (GearCatalog.swift): validation, the bundled -> published
//  lifecycle, cross-screen removal, branding isolation, offer timing and refresh outcomes. No real
//  network: the store takes an injected fetch and clock. The same acceptance rules are mirrored by
//  tools/remote-gear/validate_catalog.py, which the publishing dashboard must run before publishing.
//

import Foundation
import Testing
@testable import EightyFiveBlends

@MainActor
struct GearCatalogTests {

    // MARK: - Fixtures

    private nonisolated static let endpoint = URL(string: "https://example.supabase.co/storage/v1/object/public/recommended-gear/catalog-v1.json")!

    private static func neutralBrand(id: String = "new-brand", _ extra: [String: Any] = [:]) -> [String: Any] {
        var brand: [String: Any] = [
            "id": id, "kind": "brand", "name": "New Brand", "tagline": "Tools",
            "description": "Product details", "ctaTitle": "View products",
            "destinationURL": "https://example.com/products"
        ]
        brand.merge(extra) { _, new in new }
        return brand
    }

    private static func offer(_ extra: [String: Any] = [:]) -> [String: Any] {
        var offer: [String: Any] = [
            "amountOff": 25, "eligibleProducts": "eligible tools", "code": "SAVE25",
            "terms": "Terms at checkout.", "disclosure": "We may earn a commission."
        ]
        offer.merge(extra) { _, new in new }
        return offer
    }

    /// The RVP sponsor entry built from the bundled constants, so a publication of it is a no-op.
    private static func rvpSponsor(_ extra: [String: Any] = [:], wheels: [[String: Any]]? = nil) -> [String: Any] {
        let rvp = FeaturedBrand.rvpSupplyWheels
        var brand: [String: Any] = [
            "id": rvp.id, "kind": "rvp_wheels", "name": rvp.name, "tagline": rvp.tagline,
            "description": rvp.description, "accessibilityDescription": rvp.accessibilityDescription,
            "ctaTitle": rvp.ctaTitle, "destinationURL": RVPSupplyDestination.wheelsCollection!.absoluteString,
            "homepageURL": RVPSupplyDestination.homepage!.absoluteString,
            "configuratorURL": RVPSupplyDestination.configurator!.absoluteString,
            "more": ["subtitle": "Performance parts & gear"],
            "wheels": wheels ?? RVPWheelProduct.catalog.map { product -> [String: Any] in
                ["id": product.id, "displayName": product.displayName,
                 "accessibilityName": product.accessibilityName, "productURL": product.productURL!.absoluteString]
            }
        ]
        brand.merge(extra) { _, new in new }
        return brand
    }

    private static func eFlexFuel(_ extra: [String: Any] = [:]) -> [String: Any] {
        let brand = FeaturedBrand.eFlexFuel
        let approved = FeaturedOffer.eFlexFuel
        var fields: [String: Any] = [
            "name": brand.name, "tagline": brand.tagline, "description": brand.description,
            "accessibilityDescription": brand.accessibilityDescription, "ctaTitle": brand.ctaTitle,
            "destinationURL": brand.destinationURL!.absoluteString, "more": [String: Any](),
            "offer": offer(["amountOff": approved.amountOff, "eligibleProducts": approved.eligibleProducts,
                            "code": approved.code, "terms": approved.terms, "disclosure": approved.disclosure])
        ]
        fields.merge(extra) { _, new in new }
        return neutralBrand(id: brand.id, fields)
    }

    private static func document(
        _ brands: [[String: Any]],
        version: Int = 1,
        revision: String = "r1",
        publishedAt: Double = 1_800_000_000
    ) -> Data {
        let object: [String: Any] = ["schemaVersion": version, "revision": revision,
                                     "publishedAt": publishedAt, "brands": brands]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static var parityDocument: Data { document([eFlexFuel(), rvpSponsor()]) }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// Records requests and returns queued responses (or throws), like a tiny URL protocol.
    private final class FakeServer {
        enum Reply { case status(Int, Data, [String: String]), error(URLError) }
        var replies: [Reply] = []
        var requests: [URLRequest] = []

        func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let reply: Reply = replies.isEmpty ? .error(URLError(.notConnectedToInternet)) : replies.removeFirst()
            switch reply {
            case .error(let error):
                throw error
            case .status(let code, let data, let headers):
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (data, response)
            }
        }
    }

    private struct Harness {
        let defaults: UserDefaults
        let suite: String
        let clock = Clock()
        let server = FakeServer()

        init() throws {
            suite = "GearCatalogTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        @MainActor
        func makeStore(endpoint: URL? = GearCatalogTests.endpoint) -> GearCatalogStore {
            let server = self.server
            let clock = self.clock
            return GearCatalogStore(defaults: defaults, endpoint: endpoint,
                                    fetch: { try await server.fetch($0) },
                                    now: { clock.now }, observesApplication: false)
        }

        func tearDown() { defaults.removePersistentDomain(forName: suite) }
    }

    private static func pageIDs(_ content: GearContent) -> [String] { content.pages.map(\.id) }

    // MARK: - Lifecycle: bundled, published, empty, unreadable

    @Test func bundledContentUntilFirstPublication() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        #expect(store.source == .bundled)
        #expect(Self.pageIDs(store.content) == FeaturedGearPage.catalog.map(\.id))
        #expect(store.content.moreSponsor?.title == "Sponsored by RVP Supply")
        #expect(store.content.moreFeaturedBrands.map(\.id) == ["eflexfuel"])
    }

    @Test func publishingTheBundledEquivalentChangesNothingVisible() throws {
        let catalog = try GearCatalog.decode(Self.parityDocument)
        let published = catalog.content(at: Date(timeIntervalSince1970: 1_800_000_000))
        let bundled = GearContent.bundled
        #expect(Self.pageIDs(published) == Self.pageIDs(bundled))
        #expect(published.products.map(\.id) == bundled.products.map(\.id))
        #expect(published.products.map(\.assetName) == bundled.products.map(\.assetName))
        #expect(published.products.map(\.productURL) == bundled.products.map(\.productURL))
        #expect(published.configuratorURL == bundled.configuratorURL)
        #expect(published.moreSponsor?.homepageURL == bundled.moreSponsor?.homepageURL)
        #expect(published.moreSponsor?.subtitle == bundled.moreSponsor?.subtitle)
        #expect(published.moreFeaturedBrands.map(\.id) == ["eflexfuel"])
        guard case .brand(let eflex) = published.pages[0], case .sponsor(let rvp) = published.pages[1] else {
            Issue.record("Expected eFlexFuel brand then RVP sponsor")
            return
        }
        #expect(eflex.offer == FeaturedOffer.eFlexFuel)
        #expect(eflex.wordmarkAssetName == FeaturedBrand.eFlexFuel.wordmarkAssetName)
        #expect(eflex.heroAssetName == FeaturedBrand.eFlexFuel.heroAssetName)
        #expect(eflex.brandCardAccessibilityLabel(position: 1, total: 2)
                == FeaturedBrand.eFlexFuel.brandCardAccessibilityLabel(position: 1, total: 2))
        #expect(rvp.sponsorHeaderAccessibilityLabel(position: 2, total: 2)
                == FeaturedBrand.rvpSupplyWheels.sponsorHeaderAccessibilityLabel(position: 2, total: 2))
    }

    @Test func emptyPublicationIsAuthoritativeAcrossRestart() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        try store.accept(Self.document([]))
        #expect(store.content.pages.isEmpty)
        #expect(store.content.moreSponsor == nil)
        #expect(store.content.moreFeaturedBrands.isEmpty)

        let relaunched = harness.makeStore()
        #expect(relaunched.source == .published)
        #expect(relaunched.content.pages.isEmpty)
        #expect(relaunched.content.moreSponsor == nil)
    }

    @Test func unreadableSavedPublicationNeverFallsBackToBundled() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.makeStore().accept(Self.document([Self.neutralBrand()]))
        harness.defaults.set(Data("{corrupt".utf8), forKey: "recommendedGear.catalog.v1")

        let relaunched = harness.makeStore()
        #expect(relaunched.source == .unreadable)
        #expect(relaunched.content.pages.isEmpty)
        #expect(relaunched.content.moreSponsor == nil)
        #expect(relaunched.content.moreFeaturedBrands.isEmpty)
    }

    @Test func invalidOrUnsupportedUpdatesKeepLastValidPublication() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        try store.accept(Self.document([Self.neutralBrand()]))
        let generation = store.generation

        #expect(throws: GearCatalog.ValidationError.unsupportedSchema(2)) {
            try store.accept(Self.document([], version: 2))
        }
        #expect(throws: GearCatalog.ValidationError.self) { try store.accept(Data("not json".utf8)) }
        #expect(throws: GearCatalog.ValidationError.self) {
            try store.accept(Self.document([Self.neutralBrand(["destinationURL": "javascript:alert(1)"])]))
        }
        #expect(throws: GearCatalog.ValidationError.tooLarge) {
            try store.accept(Data(repeating: 32, count: GearCatalog.maximumBytes + 1))
        }
        #expect(Self.pageIDs(store.content) == ["new-brand"])
        #expect(store.generation == generation)
        #expect(Self.pageIDs(harness.makeStore().content) == ["new-brand"])
    }

    // MARK: - Publication ordering

    /// The withdrawal regression: once a removal is accepted, no older or equal-timestamp document
    /// (a stale CDN edge, a cached copy, a mistaken re-upload) can bring the removed item back,
    /// including after an offline restart.
    @Test func withdrawalCannotBeUndoneByOlderOrEqualTimestampDocuments() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        try store.accept(Self.document([Self.neutralBrand()], revision: "with-brand", publishedAt: 1_000), etag: "\"a\"")
        try store.accept(Self.document([], revision: "withdrawn", publishedAt: 2_000), etag: "\"b\"")
        #expect(store.content.pages.isEmpty)

        let older = Self.document([Self.neutralBrand()], revision: "with-brand", publishedAt: 1_000)
        let equalTimestamp = Self.document([Self.neutralBrand()], revision: "other", publishedAt: 2_000)
        #expect(throws: GearCatalog.ValidationError.stale) { try store.accept(older, etag: "\"a\"") }
        #expect(throws: GearCatalog.ValidationError.conflict) { try store.accept(equalTimestamp, etag: "\"c\"") }
        #expect(store.content.pages.isEmpty)
        #expect(harness.defaults.string(forKey: "recommendedGear.etag.v1") == "\"b\"", "a rejected document never changes the ETag")

        let relaunchedOffline = harness.makeStore()
        #expect(relaunchedOffline.content.pages.isEmpty)
        #expect(throws: GearCatalog.ValidationError.stale) { try relaunchedOffline.accept(older) }
        #expect(throws: GearCatalog.ValidationError.conflict) { try relaunchedOffline.accept(equalTimestamp) }
        #expect(harness.makeStore().content.pages.isEmpty)
    }

    @Test func staleDocumentsFromRefreshKeepContentAndETag() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        harness.server.replies = [
            .status(200, Self.document([Self.neutralBrand()], revision: "r1", publishedAt: 1_000), ["ETag": "\"r1\""]),
            .status(200, Self.document([], revision: "r2", publishedAt: 2_000), ["ETag": "\"r2\""]),
            .status(200, Self.document([Self.neutralBrand()], revision: "r1", publishedAt: 1_000), ["ETag": "\"r1\""]),
            .status(200, Self.document([Self.neutralBrand()], revision: "r3", publishedAt: 2_000), ["ETag": "\"r3\""]),
            .status(304, Data(), [:])
        ]
        #expect(await store.refresh(force: true) == .updated)
        #expect(await store.refresh(force: true) == .updated)
        #expect(await store.refresh(force: true) == .rejected(.stale))
        #expect(await store.refresh(force: true) == .rejected(.conflict))
        #expect(store.content.pages.isEmpty)
        #expect(await store.refresh(force: true) == .notModified)
        #expect(harness.server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"r2\"")
    }

    @Test func identicalRetryIsAcceptedAsUnchanged() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        let publication = Self.document([Self.neutralBrand()], revision: "r1", publishedAt: 1_000)
        #expect(try store.accept(publication, etag: "\"one\""))
        let generation = store.generation
        #expect(try store.accept(publication, etag: "\"two\"") == false)
        #expect(store.generation == generation)
        #expect(harness.defaults.string(forKey: "recommendedGear.etag.v1") == "\"two\"", "same bytes, refreshed ETag")
        #expect(try harness.makeStore().accept(publication) == false)
    }

    @Test func reusedRevisionWithChangedContentIsRejected() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        try store.accept(Self.document([Self.neutralBrand()], revision: "r1", publishedAt: 1_000))
        try store.accept(Self.document([], revision: "r2", publishedAt: 2_000))
        #expect(throws: GearCatalog.ValidationError.revisionReused) {
            try store.accept(Self.document([Self.neutralBrand()], revision: "r2", publishedAt: 3_000))
        }
        #expect(throws: GearCatalog.ValidationError.revisionReused) {
            try store.accept(Self.document([Self.neutralBrand()], revision: "r1", publishedAt: 3_000))
        }
        #expect(store.content.pages.isEmpty)
    }

    @Test func rollbackIsANewPublication() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        try store.accept(Self.document([Self.neutralBrand()], revision: "r1", publishedAt: 1_000))
        try store.accept(Self.document([], revision: "r2", publishedAt: 2_000))
        // Re-uploading r1 unchanged is ignored; republishing its content as r3 with a newer time works.
        #expect(throws: GearCatalog.ValidationError.stale) {
            try store.accept(Self.document([Self.neutralBrand()], revision: "r1", publishedAt: 1_000))
        }
        #expect(try store.accept(Self.document([Self.neutralBrand()], revision: "r3-rollback-of-r1", publishedAt: 2_001)))
        #expect(Self.pageIDs(store.content) == ["new-brand"])
    }

    @Test func orderingSurvivesAnUnreadableSavedCopy() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let withdrawal = Self.document([], revision: "withdrawn", publishedAt: 2_000)
        let store = harness.makeStore()
        try store.accept(Self.document([Self.neutralBrand()], revision: "r1", publishedAt: 1_000))
        try store.accept(withdrawal)
        harness.defaults.set(Data("{corrupt".utf8), forKey: "recommendedGear.catalog.v1")

        let relaunched = harness.makeStore()
        #expect(relaunched.source == .unreadable)
        #expect(throws: GearCatalog.ValidationError.stale) {
            try relaunched.accept(Self.document([Self.neutralBrand()], revision: "r1", publishedAt: 1_000))
        }
        #expect(relaunched.content.pages.isEmpty)
        // Re-downloading the same publication restores it.
        #expect(try relaunched.accept(withdrawal))
        #expect(relaunched.source == .published)
        #expect(harness.makeStore().source == .published)
    }

    @Test func identicalDocumentDoesNotBumpGeneration() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        #expect(try store.accept(Self.parityDocument))
        let generation = store.generation
        #expect(try store.accept(Self.parityDocument) == false)
        #expect(store.generation == generation)
    }

    // MARK: - Ordering, removal and hiding across both screens

    @Test func orderAndRemovalApplyToBothScreens() throws {
        let catalog = try GearCatalog.decode(Self.document([Self.rvpSponsor(), Self.neutralBrand(["more": [String: Any]()]), Self.eFlexFuel()]))
        let content = catalog.content(at: Date())
        #expect(Self.pageIDs(content) == ["rvp-supply-oem-beadlocks", "new-brand", "eflexfuel"])
        #expect(content.moreFeaturedBrands.map(\.id) == ["new-brand", "eflexfuel"])

        let withoutRVP = try GearCatalog.decode(Self.document([Self.eFlexFuel()])).content(at: Date())
        #expect(withoutRVP.moreSponsor == nil)
        #expect(withoutRVP.products.isEmpty)
        #expect(withoutRVP.configuratorURL == nil)

        let withoutEFlexFuel = try GearCatalog.decode(Self.document([Self.rvpSponsor()])).content(at: Date())
        #expect(withoutEFlexFuel.moreFeaturedBrands.isEmpty)
        #expect(withoutEFlexFuel.moreSponsor?.brandID == "rvp-supply-oem-beadlocks")
    }

    @Test func hiddenPartnersAndWheelsDisappearEverywhere() throws {
        var wheels = (Self.rvpSponsor()["wheels"] as! [[String: Any]])
        wheels[0]["hidden"] = true
        let catalog = try GearCatalog.decode(Self.document([
            Self.eFlexFuel(["hidden": true]),
            Self.rvpSponsor(wheels: wheels)
        ]))
        let content = catalog.content(at: Date())
        #expect(Self.pageIDs(content) == ["rvp-supply-oem-beadlocks"])
        #expect(content.moreFeaturedBrands.isEmpty)
        #expect(content.products.count == 8)
        #expect(content.products.contains(where: { $0.id == wheels[0]["id"] as? String }) == false)

        let hiddenSponsor = try GearCatalog.decode(Self.document([Self.rvpSponsor(["hidden": true])]))
        #expect(hiddenSponsor.content(at: Date()).moreSponsor == nil)
    }

    @Test func morePlacementIsOptIn() throws {
        let content = try GearCatalog.decode(Self.document([
            Self.neutralBrand(), Self.rvpSponsor(["more": NSNull()])
        ])).content(at: Date())
        #expect(content.pages.count == 2)
        #expect(content.moreFeaturedBrands.isEmpty)
        #expect(content.moreSponsor == nil)
    }

    @Test func unknownKindsAreSkippedSoOlderAppsStillApplyWithdrawals() throws {
        let catalog = try GearCatalog.decode(Self.document([
            ["id": "future-card", "kind": "video_card", "anything": 1],
            Self.neutralBrand()
        ]))
        #expect(Self.pageIDs(catalog.content(at: Date())) == ["new-brand"])
        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([["kind": "video_card"]]))
        }
    }

    // MARK: - Branding isolation and the sponsor distinction

    @Test func newBrandsNeverInheritEFlexFuelOrRVPArtwork() throws {
        let content = try GearCatalog.decode(Self.document([
            Self.neutralBrand(["offer": Self.offer()])
        ])).content(at: Date())
        guard case .brand(let brand) = content.pages[0] else {
            Issue.record("Expected a neutral brand card")
            return
        }
        #expect(brand.wordmarkAssetName == nil)
        #expect(brand.heroAssetName == nil)
        #expect(brand.heroImageURL == nil)
        #expect(GearBundledArtwork.usesEFlexFuelOfferStyle(brandID: brand.id) == false)
        #expect(GearBundledArtwork.usesEFlexFuelOfferStyle(brandID: "eflexfuel"))
    }

    @Test func remoteLogoChoosesAppearanceVariant() throws {
        let content = try GearCatalog.decode(Self.document([Self.neutralBrand([
            "logo": ["url": "https://cdn.example.com/logo-light-v1.png", "darkURL": "https://cdn.example.com/logo-dark-v1.png"],
            "heroImageURL": "https://cdn.example.com/hero-v1.png", "priceText": "From $499"
        ])])).content(at: Date())
        guard case .brand(let brand) = content.pages[0] else {
            Issue.record("Expected a neutral brand card")
            return
        }
        #expect(brand.remoteLogoURL(isDark: false)?.lastPathComponent == "logo-light-v1.png")
        #expect(brand.remoteLogoURL(isDark: true)?.lastPathComponent == "logo-dark-v1.png")
        #expect(brand.heroImageURL?.lastPathComponent == "hero-v1.png")
        #expect(brand.priceText == "From $499")
    }

    @Test func sponsorIdentityAndWordingAreReserved() {
        // A neutral card may not claim a relationship, nor take RVP Supply's id.
        for extra: [String: Any] in [["tagline": "Our sponsor"], ["description": "Official partner gear"],
                                      ["more": ["subtitle": "Affiliate pick"]]] {
            #expect(throws: GearCatalog.ValidationError.self) {
                try GearCatalog.decode(Self.document([Self.neutralBrand(extra)]))
            }
        }
        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([Self.neutralBrand(id: "rvp-supply-oem-beadlocks")]))
        }
        // The sponsor layout belongs to RVP Supply only, once, and carries no price or offer.
        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([Self.rvpSponsor(["id": "someone-else"])]))
        }
        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([Self.rvpSponsor(["priceText": "$999"])]))
        }
        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([Self.rvpSponsor(["offer": Self.offer()])]))
        }
        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([Self.neutralBrand(["wheels": [Any]()])]))
        }
    }

    @Test func wheelsNeedBundledArtworkOrARemoteImage() throws {
        var wheels = (Self.rvpSponsor()["wheels"] as! [[String: Any]])
        wheels.append(["id": "new-wheel", "displayName": "New", "accessibilityName": "New wheel",
                       "productURL": "https://rvpsupply.com/products/new"])
        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([Self.rvpSponsor(wheels: wheels)]))
        }
        wheels[wheels.count - 1]["imageURL"] = "https://cdn.example.com/new-wheel-v1.png"
        let products = try GearCatalog.decode(Self.document([Self.rvpSponsor(wheels: wheels)])).content(at: Date()).products
        #expect(products.count == 10)
        #expect(products.last?.assetName == "")
        #expect(products.last?.imageURL?.lastPathComponent == "new-wheel-v1.png")
        // Ten wheels: the sponsor card must fall back to the grid (ring is designed for nine).
        #expect(products.count != RVPWheelRingLayout.designedWheelCount)
    }

    @Test func duplicateIdentifiersAreRejected() {
        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([Self.neutralBrand(), Self.neutralBrand()]))
        }
        var wheels = (Self.rvpSponsor()["wheels"] as! [[String: Any]])
        wheels.append(wheels[0])
        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([Self.rvpSponsor(wheels: wheels)]))
        }
        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([Self.rvpSponsor(), Self.rvpSponsor()]))
        }
    }

    // MARK: - Offers

    @Test func offerWindowUsesStartAndExpiry() throws {
        let catalog = try GearCatalog.decode(Self.document([
            Self.neutralBrand(["offer": Self.offer(["startsAt": 1_000, "expiresAt": 2_000])])
        ]))
        func offerCode(at seconds: Double) -> String? {
            guard case .brand(let brand) = catalog.content(at: Date(timeIntervalSince1970: seconds)).pages[0] else { return nil }
            return brand.offer?.code
        }
        #expect(offerCode(at: 999) == nil)
        #expect(offerCode(at: 1_000) == "SAVE25")
        #expect(offerCode(at: 1_999) == "SAVE25")
        #expect(offerCode(at: 2_000) == nil)
        #expect(catalog.content(at: Date(timeIntervalSince1970: 2_000)).pages.count == 1, "expiry removes the offer, not the brand")

        #expect(catalog.nextOfferTransition(after: Date(timeIntervalSince1970: 500)) == Date(timeIntervalSince1970: 1_000))
        #expect(catalog.nextOfferTransition(after: Date(timeIntervalSince1970: 1_000)) == Date(timeIntervalSince1970: 2_000))
        #expect(catalog.nextOfferTransition(after: Date(timeIntervalSince1970: 2_000)) == nil)

        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([Self.neutralBrand(["offer": Self.offer(["startsAt": 2_000, "expiresAt": 2_000])])]))
        }
        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([Self.neutralBrand(["offer": Self.offer(["amountOff": 0])])]))
        }
        #expect(throws: GearCatalog.ValidationError.self) {
            try GearCatalog.decode(Self.document([Self.neutralBrand(["offer": Self.offer(["code": "TWO WORDS"])])]))
        }
    }

    @Test func expiredOfferStopsShowingOfflineWithoutRefresh() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let expiry = harness.clock.now.addingTimeInterval(3_600)
        try harness.makeStore().accept(Self.document([
            Self.neutralBrand(["offer": Self.offer(["expiresAt": expiry.timeIntervalSince1970])])
        ]))

        let relaunchedOffline = harness.makeStore()
        guard case .brand(let before) = relaunchedOffline.content.pages[0] else { Issue.record("brand"); return }
        #expect(before.offer != nil)

        harness.clock.now = expiry
        relaunchedOffline.reevaluate()
        guard case .brand(let after) = relaunchedOffline.content.pages[0] else { Issue.record("brand"); return }
        #expect(after.offer == nil)
        #expect(harness.server.requests.isEmpty)
    }

    @Test func singleTimerRemovesOfferAtExpiryWithoutPolling() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        let expiry = harness.clock.now.addingTimeInterval(0.3)
        try store.accept(Self.document([
            Self.neutralBrand(["offer": Self.offer(["expiresAt": expiry.timeIntervalSince1970])])
        ]))
        guard case .brand(let before) = store.content.pages[0] else { Issue.record("brand"); return }
        #expect(before.offer != nil)

        harness.clock.now = expiry
        try await Task.sleep(for: .seconds(1))
        guard case .brand(let after) = store.content.pages[0] else { Issue.record("brand"); return }
        #expect(after.offer == nil, "the scheduled transition re-resolves content on its own")
    }

    // MARK: - Refresh

    @Test func refreshAppliesValidDocumentAndSendsConditionalRequests() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        harness.server.replies = [.status(200, Self.document([Self.neutralBrand()]), ["ETag": "\"v1\""]),
                                  .status(304, Data(), [:])]

        #expect(await store.refresh() == .updated)
        #expect(Self.pageIDs(store.content) == ["new-brand"])
        let first = try #require(harness.server.requests.first)
        #expect(first.url == Self.endpoint)
        #expect(first.httpMethod == "GET")
        #expect(first.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(first.value(forHTTPHeaderField: "Authorization") == nil, "public read only: no credentials")
        #expect(first.value(forHTTPHeaderField: "apikey") == nil)
        #expect(first.timeoutInterval == GearCatalogStore.requestTimeout)

        #expect(await store.refresh() == .throttled)
        harness.clock.now.addTimeInterval(GearCatalogStore.minimumRefreshInterval)
        #expect(await store.refresh() == .notModified)
        #expect(harness.server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(Self.pageIDs(store.content) == ["new-brand"])
    }

    @Test func refreshFailuresKeepLastValidPublication() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        try store.accept(Self.document([Self.neutralBrand()]))
        harness.server.replies = [
            .error(URLError(.timedOut)),
            .error(URLError(.notConnectedToInternet)),
            .status(404, Data(), [:]),
            .status(500, Data("oops".utf8), [:]),
            .status(200, Self.document([], version: 2), [:]),
            .status(200, Data("<html>".utf8), [:])
        ]
        #expect(await store.refresh(force: true) == .failed)
        #expect(await store.refresh(force: true) == .failed)
        #expect(await store.refresh(force: true) == .httpStatus(404))
        #expect(await store.refresh(force: true) == .httpStatus(500))
        #expect(await store.refresh(force: true) == .rejected(.unsupportedSchema(2)))
        if case .rejected = await store.refresh(force: true) {} else { Issue.record("HTML must be rejected") }
        #expect(Self.pageIDs(store.content) == ["new-brand"])
    }

    @Test func bundledContentSurvivesFailedFirstRefresh() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore()
        harness.server.replies = [.error(URLError(.timedOut))]
        #expect(await store.refresh() == .failed)
        #expect(store.source == .bundled)
        #expect(Self.pageIDs(store.content) == FeaturedGearPage.catalog.map(\.id))
    }

    @Test func refreshWithoutConfigurationDoesNothing() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let store = harness.makeStore(endpoint: nil)
        #expect(await store.refresh(force: true) == .notConfigured)
        #expect(harness.server.requests.isEmpty)
    }
}

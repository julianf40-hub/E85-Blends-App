import Foundation
import Testing
@testable import EightyFiveBlends

@MainActor
struct GearCatalogTests {
    private func payload(brands: String = "[]", version: Int = 1) -> Data {
        Data("""
        {"schemaVersion":\(version),"revision":"test","brands":\(brands),"wheels":[],
         "configuratorURL":"https://customize.rvpsupply.com/"}
        """.utf8)
    }

    private let brand = """
    {"kind":"brand","id":"new-brand","name":"New brand","tagline":"Tools",
     "description":"Product details","ctaTitle":"View products","destinationURL":"https://example.com",
     "offer":{"amountOff":10,"eligibleProducts":"eligible tools","code":"TEST",
              "terms":"Check eligibility","disclosure":"Commission disclosure","expiresAt":2000}}
    """

    @Test func emptyPublicationRemainsEmptyAfterOfflineRestart() throws {
        let suite = "GearCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GearCatalogStore(defaults: defaults)
        #expect(store.pages().count == 2)
        try store.accept(payload())
        #expect(store.pages().isEmpty)
        #expect(GearCatalogStore(defaults: defaults).pages().isEmpty)
    }

    @Test func invalidUpdateDoesNotReplaceLastValidPublication() throws {
        let suite = "GearCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GearCatalogStore(defaults: defaults)
        try store.accept(payload())
        #expect(throws: (any Error).self) { try store.accept(payload(version: 2)) }
        #expect(store.pages().isEmpty)
    }

    @Test func expiredOfferDisappearsWithoutRemovingBrand() throws {
        let catalog = try GearCatalog.decode(payload(brands: "[\(brand)]"))
        guard case .brand(let before) = catalog.pages(at: Date(timeIntervalSince1970: 1999))[0],
              case .brand(let after) = catalog.pages(at: Date(timeIntervalSince1970: 2000))[0] else {
            Issue.record("Expected brand cards")
            return
        }
        #expect(before.offer?.code == "TEST")
        #expect(after.offer == nil)
        #expect(after.id == "new-brand")
    }

    @Test func rejectsDuplicateIdentityAndUnsafeLinks() {
        #expect(throws: (any Error).self) { try GearCatalog.decode(payload(brands: "[\(brand),\(brand)]")) }
        let unsafe = brand.replacingOccurrences(of: "https://example.com", with: "javascript:alert(1)")
        #expect(throws: (any Error).self) { try GearCatalog.decode(payload(brands: "[\(unsafe)]")) }
    }

    @Test func rejectsUnknownLayoutsAndOversizeDocuments() {
        let unknown = brand.replacingOccurrences(of: "\"kind\":\"brand\"", with: "\"kind\":\"executable\"")
        #expect(throws: (any Error).self) { try GearCatalog.decode(payload(brands: "[\(unknown)]")) }
        #expect(throws: (any Error).self) { try GearCatalog.decode(Data(repeating: 32, count: 512_001)) }
    }
}

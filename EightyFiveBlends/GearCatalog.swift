import Foundation
import Combine

/// Shared, versioned wire format. Array order is display order; omission removes an item.
/// This is content only: layout kinds and behavior are implemented in each mobile client.
struct GearCatalog: Codable {
    let schemaVersion: Int
    let revision: String
    let brands: [Brand]
    let wheels: [Wheel]
    let configuratorURL: URL

    struct Brand: Codable {
        let kind: String
        let id: String
        let name: String
        let tagline: String
        let description: String
        let ctaTitle: String
        let destinationURL: URL
        let wordmarkAssetName: String?
        let heroImageURL: URL?
        let priceText: String?
        let offer: Offer?
    }

    struct Offer: Codable {
        let amountOff: Int
        let eligibleProducts: String
        let code: String
        let terms: String
        let disclosure: String
        /// UTC Unix seconds, shared with Android. Nil means no declared end date.
        let expiresAt: Double?
    }

    struct Wheel: Codable {
        let id: String
        let displayName: String
        let assetName: String?
        let imageURL: URL?
        let productURL: URL
        let accessibilityName: String
    }

    enum ValidationError: Error { case invalidCatalog }

    static func decode(_ data: Data) throws -> GearCatalog {
        guard data.count <= 512_000 else { throw ValidationError.invalidCatalog }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        try catalog.validate()
        return catalog
    }

    func validate() throws {
        func secure(_ url: URL) -> Bool {
            url.scheme?.lowercased() == "https" && url.host?.isEmpty == false &&
                url.user == nil && url.password == nil
        }
        func text(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 4_000
        }
        guard schemaVersion == 1, text(revision), brands.count <= 30, wheels.count <= 50,
              Set(brands.map(\.id)).count == brands.count,
              Set(wheels.map(\.id)).count == wheels.count, secure(configuratorURL) else {
            throw ValidationError.invalidCatalog
        }
        for brand in brands {
            guard [brand.id, brand.name, brand.tagline, brand.description, brand.ctaTitle].allSatisfy(text),
                  ["brand", "rvp_wheels"].contains(brand.kind),
                  brand.kind != "rvp_wheels" || brand.id == "rvp-supply-oem-beadlocks",
                  secure(brand.destinationURL), brand.heroImageURL.map(secure) ?? true,
                  brand.priceText.map(text) ?? true,
                  brand.wordmarkAssetName == nil || brand.wordmarkAssetName == "EFlexFuelWordmark" else {
                throw ValidationError.invalidCatalog
            }
            if let offer = brand.offer {
                guard brand.kind == "brand", offer.amountOff > 0, offer.amountOff <= 100_000,
                      [offer.eligibleProducts, offer.code, offer.terms, offer.disclosure].allSatisfy(text),
                      offer.expiresAt.map({ $0.isFinite && $0 > 0 }) ?? true else {
                    throw ValidationError.invalidCatalog
                }
            }
        }
        let bundledAssets = Set(RVPWheelProduct.catalog.map(\.assetName))
        for wheel in wheels {
            guard [wheel.id, wheel.displayName, wheel.accessibilityName].allSatisfy(text),
                  secure(wheel.productURL), wheel.imageURL.map(secure) ?? true,
                  wheel.assetName.map({ bundledAssets.contains($0) }) ?? true,
                  wheel.imageURL != nil || wheel.assetName != nil else {
                throw ValidationError.invalidCatalog
            }
        }
    }

    func pages(at date: Date) -> [FeaturedGearPage] {
        brands.map { item in
            let liveOffer = item.offer.flatMap { offer -> FeaturedOffer? in
                guard offer.expiresAt.map({ date.timeIntervalSince1970 < $0 }) ?? true else { return nil }
                return FeaturedOffer(amountOff: offer.amountOff, eligibleProducts: offer.eligibleProducts,
                                     code: offer.code, terms: offer.terms, disclosure: offer.disclosure)
            }
            let brand = FeaturedBrand(id: item.id, name: item.name, tagline: item.tagline,
                                      description: item.description, ctaTitle: item.ctaTitle,
                                      destinationURL: item.destinationURL, accessibilityDescription: item.description,
                                      wordmarkAssetName: item.wordmarkAssetName, offer: liveOffer,
                                      heroImageURL: item.heroImageURL, priceText: item.priceText)
            return item.kind == "rvp_wheels" ? .sponsor(brand) : .brand(brand)
        }
    }

    var products: [RVPWheelProduct] {
        wheels.map { RVPWheelProduct(id: $0.id, displayName: $0.displayName,
                                    assetName: $0.assetName ?? "", productURL: $0.productURL,
                                    accessibilityName: $0.accessibilityName, imageURL: $0.imageURL) }
    }
}

/// The bundled catalog is used only until a valid published snapshot has been received.
/// A valid empty catalog is authoritative, including after restarting offline.
@MainActor
final class GearCatalogStore: ObservableObject {
    static let shared = GearCatalogStore()
    @Published private(set) var catalog: GearCatalog?
    private let defaults: UserDefaults
    private let cacheKey = "recommendedGear.catalog.v1"
    private var refreshing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: cacheKey) {
            catalog = try? GearCatalog.decode(data)
        }
    }

    func pages(at date: Date = Date()) -> [FeaturedGearPage] {
        catalog?.pages(at: date) ?? FeaturedGearPage.catalog
    }

    var products: [RVPWheelProduct] { catalog?.products ?? RVPWheelProduct.catalog }
    var configuratorURL: URL? { catalog?.configuratorURL ?? RVPSupplyDestination.configurator }

    /// One atomic publication object; no public write endpoint or administrator key in the app.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let config = try SupabaseConfig.load()
            let url = config.url.appendingPathComponent("storage/v1/object/public/recommended-gear/catalog-v1.json")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { return }
            try accept(data)
        } catch {
            // Keep the last valid snapshot, including removals. Gear must work offline.
        }
    }

    func accept(_ data: Data) throws {
        let next = try GearCatalog.decode(data)
        defaults.set(data, forKey: cacheKey)
        catalog = next
    }
}

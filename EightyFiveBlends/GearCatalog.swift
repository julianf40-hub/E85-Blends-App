//
//  GearCatalog.swift
//  EightyFiveBlends
//
//  Remote Recommended Gear content (2.4.1). One versioned JSON document, published to public
//  Supabase Storage, drives BOTH the Recommended Gear carousel and the More screen's partner
//  placements, so a partner removed or hidden in one place cannot linger in the other.
//
//  The wire format is shared with the Android client and documented in docs/remote-gear/README.md
//  (with a JSON Schema beside it). It carries content only: text, https links, prices, offers and
//  remote image URLs. Layout kinds, colors, bundled artwork and accessibility behavior stay in each
//  native client. Bundled artwork is resolved here from stable IDs (never from asset names in the
//  JSON), so a new brand can never pick up eFlexFuel's or RVP Supply's artwork or styling.
//
//  The app only ever reads a public object. There is no write endpoint, no service-role key and no
//  administrator credential in the client.
//

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Wire format (schema version 1)

/// The published document. Array order is display order; omitting an item (or setting `hidden`)
/// removes it everywhere. Unknown keys are ignored, so optional fields can be added within v1.
struct GearCatalog: Decodable {
    static let supportedSchemaVersion = 1
    nonisolated static let maximumBytes = 512_000

    let schemaVersion: Int
    /// Changes on every publication, including a rollback.
    let revision: String
    /// UTC Unix seconds set by the publisher, strictly increasing across publications. A device only
    /// accepts a changed document whose publishedAt is strictly newer than the last one it accepted,
    /// so a stale CDN edge or cached copy cannot resurrect removed items (see `GearCatalogStore.accept`).
    let publishedAt: Double
    let brands: [BrandEntry]

    enum Kind: String, Decodable {
        /// A neutral "Featured Brand" card. Never labeled or worded as a sponsor.
        case brand
        /// RVP Supply's sponsor card: wheel ring/grid, configurator and homepage banner.
        case rvpWheels = "rvp_wheels"
    }

    /// A brand entry whose `kind` this client may not know. Unknown kinds are the contract's
    /// extension point: they are skipped (never shown), and the rest of the document still applies,
    /// so adding a new layout later cannot freeze older apps on a stale catalog.
    enum BrandEntry: Decodable {
        case supported(Brand)
        case unsupported(id: String?, kind: String)

        private enum KindKey: String, CodingKey { case kind, id }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: KindKey.self)
            let kind = try container.decode(String.self, forKey: .kind)
            if Kind(rawValue: kind) != nil {
                self = .supported(try Brand(from: decoder))
            } else {
                self = .unsupported(id: try? container.decode(String.self, forKey: .id), kind: kind)
            }
        }

        var id: String? {
            switch self {
            case .supported(let brand): return brand.id
            case .unsupported(let id, _): return id
            }
        }
    }

    struct Brand: Decodable {
        let id: String
        let kind: Kind
        let name: String
        let tagline: String
        let description: String
        let ctaTitle: String
        let destinationURL: URL
        let accessibilityDescription: String?
        /// Withdrawn from every screen without deleting its content from the document.
        let hidden: Bool?
        /// Present = also placed on the More screen (a Featured Brand card for `brand`, the
        /// "Sponsored by" banner for `rvp_wheels`).
        let more: MorePlacement?

        // `brand` only.
        let logo: Logo?
        let heroImageURL: URL?
        let priceText: String?
        let offer: Offer?

        // `rvp_wheels` only.
        let homepageURL: URL?
        let configuratorURL: URL?
        let footnote: String?
        let wheels: [Wheel]?
    }

    struct MorePlacement: Decodable {
        /// The More card's second line. Defaults to the brand's tagline.
        let subtitle: String?
    }

    /// A remote wordmark. `darkURL` is used in dark and OLED appearances; without it `url` is used
    /// in every appearance. Logos must be transparent and legible on the card surface.
    struct Logo: Decodable {
        let url: URL
        let darkURL: URL?
    }

    struct Offer: Decodable {
        let amountOff: Int
        let eligibleProducts: String
        let code: String
        let terms: String
        let disclosure: String
        /// UTC Unix seconds. Before this the offer is not shown. Nil = active immediately.
        let startsAt: Double?
        /// UTC Unix seconds. From this moment the offer is not shown, on the device clock and
        /// offline. Nil = no declared end.
        let expiresAt: Double?
    }

    struct Wheel: Decodable {
        let id: String
        let displayName: String
        let accessibilityName: String
        let productURL: URL
        /// Required unless `id` is one of the bundled wheel IDs (see `GearBundledArtwork`).
        let imageURL: URL?
        let hidden: Bool?
    }

    enum ValidationError: Error, Equatable {
        case tooLarge
        case unsupportedSchema(Int)
        case invalid(String)
        /// Older than the last accepted publication (for example a stale CDN edge).
        case stale
        /// Same publishedAt as the last accepted publication but different bytes. Publications must
        /// have strictly increasing timestamps, so this is never a legitimate update.
        case conflict
        /// A revision already accepted earlier, with different bytes.
        case revisionReused
        /// The download exceeded `maximumBytes` while it was being received.
        case downloadTooLarge
    }

    static func decode(_ data: Data) throws -> GearCatalog {
        guard data.count <= maximumBytes else { throw ValidationError.tooLarge }
        // Read the version first so a future v2 document is reported as unsupported rather than
        // as malformed v1.
        struct Header: Decodable { let schemaVersion: Int }
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw ValidationError.invalid("not a catalog document")
        }
        guard header.schemaVersion == supportedSchemaVersion else {
            throw ValidationError.unsupportedSchema(header.schemaVersion)
        }
        let catalog: GearCatalog
        do {
            catalog = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ValidationError.invalid("decoding failed")
        }
        try catalog.validate()
        return catalog
    }
}

// MARK: - Validation

/// Text limits keep remote copy inside the native layouts. The publishing dashboard must enforce
/// the same limits before publication (docs/remote-gear/catalog-v1.schema.json).
nonisolated enum GearCatalogLimits {
    static let brands = 30
    static let wheels = 24
    static let id = 64
    static let revision = 200
    static let name = 60
    static let tagline = 120
    static let description = 500
    static let ctaTitle = 60
    static let accessibilityText = 500
    static let priceText = 60
    static let subtitle = 120
    static let footnote = 160
    static let offerCode = 40
    static let offerText = 300
    static let maximumAmountOff = 10_000

    /// Relationship wording a neutral `brand` card may never use. Only the sponsor card may say
    /// "sponsor". The dashboard applies the full FeaturedGearTests wording guards on top of this.
    static let neutralBrandBannedWords = ["sponsor", "partner", "affiliate", "endorse"]
}

extension GearCatalog {
    func validate() throws {
        func fail(_ reason: String) -> ValidationError { .invalid(reason) }

        guard GearCatalogValidation.text(revision, max: GearCatalogLimits.revision) else { throw fail("revision") }
        guard publishedAt.isFinite, publishedAt > 0 else { throw fail("publishedAt") }
        guard brands.count <= GearCatalogLimits.brands else { throw fail("too many brands") }

        let ids = brands.map(\.id)
        guard ids.allSatisfy({ $0.map(GearCatalogValidation.identifier) ?? false }) else { throw fail("brand id") }
        guard Set(ids.compactMap { $0 }).count == ids.count else { throw fail("duplicate brand id") }

        var sponsorCount = 0
        for entry in brands {
            guard case .supported(let brand) = entry else { continue }
            switch brand.kind {
            case .brand: try validateNeutralBrand(brand)
            case .rvpWheels:
                sponsorCount += 1
                try validateSponsor(brand)
            }
        }
        guard sponsorCount <= 1 else { throw fail("more than one rvp_wheels entry") }
    }

    private func validateShared(_ brand: Brand) throws {
        typealias V = GearCatalogValidation
        typealias L = GearCatalogLimits
        guard V.text(brand.name, max: L.name), V.text(brand.tagline, max: L.tagline),
              V.text(brand.description, max: L.description), V.text(brand.ctaTitle, max: L.ctaTitle),
              brand.accessibilityDescription.map({ V.text($0, max: L.accessibilityText) }) ?? true,
              brand.more?.subtitle.map({ V.text($0, max: L.subtitle) }) ?? true else {
            throw ValidationError.invalid("\(brand.id) text")
        }
        guard V.secure(brand.destinationURL) else { throw ValidationError.invalid("\(brand.id) destinationURL") }
    }

    private func validateNeutralBrand(_ brand: Brand) throws {
        try validateShared(brand)
        guard brand.id != GearBundledArtwork.rvpSponsorID else {
            throw ValidationError.invalid("the RVP Supply id is reserved for rvp_wheels")
        }
        guard brand.homepageURL == nil, brand.configuratorURL == nil, brand.footnote == nil, brand.wheels == nil else {
            throw ValidationError.invalid("\(brand.id) has sponsor-only fields")
        }
        let copy = [brand.name, brand.tagline, brand.description, brand.ctaTitle,
                    brand.accessibilityDescription ?? "", brand.more?.subtitle ?? ""]
            .joined(separator: " ").lowercased()
        guard GearCatalogLimits.neutralBrandBannedWords.allSatisfy({ copy.contains($0) == false }) else {
            throw ValidationError.invalid("\(brand.id) neutral copy uses sponsor wording")
        }
        guard brand.heroImageURL.map(GearCatalogValidation.secure) ?? true,
              brand.logo.map({ GearCatalogValidation.secure($0.url) && ($0.darkURL.map(GearCatalogValidation.secure) ?? true) }) ?? true,
              brand.priceText.map({ GearCatalogValidation.text($0, max: GearCatalogLimits.priceText) }) ?? true else {
            throw ValidationError.invalid("\(brand.id) media or price")
        }
        if let offer = brand.offer {
            typealias V = GearCatalogValidation
            typealias L = GearCatalogLimits
            guard (1...L.maximumAmountOff).contains(offer.amountOff),
                  V.text(offer.code, max: L.offerCode),
                  offer.code.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  [offer.eligibleProducts, offer.terms, offer.disclosure].allSatisfy({ V.text($0, max: L.offerText) }),
                  offer.startsAt.map(V.timestamp) ?? true,
                  offer.expiresAt.map(V.timestamp) ?? true else {
                throw ValidationError.invalid("\(brand.id) offer")
            }
            if let start = offer.startsAt, let end = offer.expiresAt, start >= end {
                throw ValidationError.invalid("\(brand.id) offer window")
            }
        }
    }

    private func validateSponsor(_ brand: Brand) throws {
        try validateShared(brand)
        guard brand.id == GearBundledArtwork.rvpSponsorID else {
            throw ValidationError.invalid("rvp_wheels is reserved for RVP Supply")
        }
        // The sponsor card carries no price, discount or remote branding (its logo is bundled).
        guard brand.offer == nil, brand.priceText == nil, brand.heroImageURL == nil, brand.logo == nil else {
            throw ValidationError.invalid("rvp_wheels has brand-only fields")
        }
        guard let homepage = brand.homepageURL, GearCatalogValidation.secure(homepage),
              let configurator = brand.configuratorURL, GearCatalogValidation.secure(configurator) else {
            throw ValidationError.invalid("rvp_wheels links")
        }
        guard brand.footnote.map({ GearCatalogValidation.text($0, max: GearCatalogLimits.footnote) }) ?? true else {
            throw ValidationError.invalid("rvp_wheels footnote")
        }
        let wheels = brand.wheels ?? []
        guard wheels.count <= GearCatalogLimits.wheels,
              wheels.allSatisfy({ GearCatalogValidation.identifier($0.id) }),
              Set(wheels.map(\.id)).count == wheels.count else {
            throw ValidationError.invalid("wheel ids")
        }
        for wheel in wheels {
            guard GearCatalogValidation.text(wheel.displayName, max: GearCatalogLimits.name),
                  GearCatalogValidation.text(wheel.accessibilityName, max: GearCatalogLimits.accessibilityText),
                  GearCatalogValidation.secure(wheel.productURL),
                  wheel.imageURL.map(GearCatalogValidation.secure) ?? true,
                  wheel.imageURL != nil || GearBundledArtwork.wheelAssetName(forID: wheel.id) != nil else {
                throw ValidationError.invalid("wheel \(wheel.id)")
            }
        }
    }
}

nonisolated enum GearCatalogValidation {
    /// https with a host, no credentials. The same rule FeaturedBrandLink applies before openURL.
    static func secure(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host(percentEncoded: false), host.isEmpty == false else { return false }
        return url.user == nil && url.password == nil
    }

    static func text(_ value: String, max: Int) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && value.count <= max
    }

    /// Lowercase ASCII letters, digits and hyphens: stable across iOS, Android and storage paths.
    static func identifier(_ value: String) -> Bool {
        guard (1...GearCatalogLimits.id).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "-"
        }
    }

    static func timestamp(_ value: Double) -> Bool { value.isFinite && value > 0 }
}

/// A stable fingerprint of a publication's exact bytes (64-bit FNV-1a plus length), used to tell a
/// harmless retry of the same publication from a different document. Not a security boundary: only
/// the trusted publisher can write the object.
nonisolated enum GearCatalogDigest {
    static func of(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16) + "-" + String(data.count)
    }
}

// MARK: - Bundled artwork (iOS mapping of stable IDs)

/// Bundled images are chosen by stable ID on each platform, never named in the JSON. Android keeps
/// its own table keyed by the same IDs (docs/remote-gear/README.md, "Android mapping").
enum GearBundledArtwork {
    static let eFlexFuelBrandID = "eflexfuel"
    static let rvpSponsorID = "rvp-supply-oem-beadlocks"

    static func wordmarkAssetName(forBrandID id: String) -> String? {
        id == eFlexFuelBrandID ? "EFlexFuelWordmark" : nil
    }

    static func heroAssetName(forBrandID id: String) -> String? {
        id == eFlexFuelBrandID ? "EFlexFuelAutoKitHero" : nil
    }

    /// The eFlexFuel orange offer styling is reserved for eFlexFuel; every other brand gets the
    /// neutral theme styling.
    static func usesEFlexFuelOfferStyle(brandID id: String) -> Bool { id == eFlexFuelBrandID }

    static func wheelAssetName(forID id: String) -> String? {
        RVPWheelProduct.catalog.first(where: { $0.id == id })?.assetName
    }
}

// MARK: - Resolved presentation content

/// The More screen's sponsor banner. The "Sponsored by" disclosure is fixed app copy; only the
/// subtitle and the homepage link come from the catalog.
struct MoreSponsorBanner {
    let brandID: String
    let name: String
    let subtitle: String
    let homepageURL: URL?

    var title: String { "Sponsored by \(name)" }
    var accessibilityHint: String { "Opens the \(name) website" }
}

/// Everything both screens show, resolved for one moment in time.
struct GearContent {
    var pages: [FeaturedGearPage]
    var products: [RVPWheelProduct]
    var configuratorURL: URL?
    var sponsorFootnote: String
    var moreSponsor: MoreSponsorBanner?
    var moreFeaturedBrands: [FeaturedBrand]

    /// Shown only until the first valid publication has been received.
    static var bundled: GearContent {
        GearContent(
            pages: FeaturedGearPage.catalog,
            products: RVPWheelProduct.catalog,
            configuratorURL: RVPSupplyDestination.configurator,
            sponsorFootnote: RVPWheelProduct.footnote,
            moreSponsor: MoreSponsorBanner(
                brandID: FeaturedBrand.rvpSupplyWheels.id,
                name: FeaturedBrand.rvpSupplyWheels.name,
                subtitle: "Performance parts & gear",
                homepageURL: RVPSupplyDestination.homepage
            ),
            moreFeaturedBrands: [.eFlexFuel]
        )
    }

    /// A previously received publication can no longer be read. Showing nothing (until the next
    /// refresh) is safer than resurrecting bundled items that may have been withdrawn.
    static var empty: GearContent {
        GearContent(pages: [], products: [], configuratorURL: nil, sponsorFootnote: RVPWheelProduct.footnote,
                    moreSponsor: nil, moreFeaturedBrands: [])
    }
}

extension GearCatalog {
    var supportedBrands: [Brand] {
        brands.compactMap { entry in
            guard case .supported(let brand) = entry, brand.hidden != true else { return nil }
            return brand
        }
    }

    func content(at date: Date) -> GearContent {
        let now = date.timeIntervalSince1970
        var result = GearContent.empty

        for item in supportedBrands {
            switch item.kind {
            case .brand:
                let brand = FeaturedBrand(
                    id: item.id,
                    name: item.name,
                    tagline: item.tagline,
                    description: item.description,
                    ctaTitle: item.ctaTitle,
                    destinationURL: item.destinationURL,
                    accessibilityDescription: item.accessibilityDescription ?? item.description,
                    wordmarkAssetName: GearBundledArtwork.wordmarkAssetName(forBrandID: item.id),
                    offer: item.offer.flatMap { Self.activeOffer($0, now: now) },
                    heroAssetName: GearBundledArtwork.heroAssetName(forBrandID: item.id),
                    heroImageURL: item.heroImageURL,
                    logoURL: item.logo?.url,
                    logoDarkURL: item.logo?.darkURL,
                    priceText: item.priceText,
                    moreSubtitle: item.more?.subtitle
                )
                result.pages.append(.brand(brand))
                if item.more != nil { result.moreFeaturedBrands.append(brand) }

            case .rvpWheels:
                let brand = FeaturedBrand(
                    id: item.id,
                    name: item.name,
                    tagline: item.tagline,
                    description: item.description,
                    ctaTitle: item.ctaTitle,
                    destinationURL: item.destinationURL,
                    accessibilityDescription: item.accessibilityDescription ?? item.description
                )
                result.pages.append(.sponsor(brand))
                result.products = (item.wheels ?? []).filter { $0.hidden != true }.map { wheel in
                    RVPWheelProduct(
                        id: wheel.id,
                        displayName: wheel.displayName,
                        assetName: GearBundledArtwork.wheelAssetName(forID: wheel.id) ?? "",
                        productURL: wheel.productURL,
                        accessibilityName: wheel.accessibilityName,
                        imageURL: wheel.imageURL
                    )
                }
                result.configuratorURL = item.configuratorURL
                result.sponsorFootnote = item.footnote ?? RVPWheelProduct.footnote
                if let more = item.more {
                    result.moreSponsor = MoreSponsorBanner(
                        brandID: item.id,
                        name: item.name,
                        subtitle: more.subtitle ?? item.tagline,
                        homepageURL: item.homepageURL
                    )
                }
            }
        }
        return result
    }

    private static func activeOffer(_ offer: Offer, now: TimeInterval) -> FeaturedOffer? {
        if let start = offer.startsAt, now < start { return nil }
        if let end = offer.expiresAt, now >= end { return nil }
        return FeaturedOffer(amountOff: offer.amountOff, eligibleProducts: offer.eligibleProducts,
                             code: offer.code, terms: offer.terms, disclosure: offer.disclosure)
    }

    /// The next moment an offer starts or ends after `date`, so the store can wake exactly then
    /// instead of polling.
    func nextOfferTransition(after date: Date) -> Date? {
        let now = date.timeIntervalSince1970
        let moments = supportedBrands.compactMap(\.offer).flatMap { [$0.startsAt, $0.expiresAt] }
            .compactMap { $0 }
            .filter { $0 > now }
        return moments.min().map { Date(timeIntervalSince1970: $0) }
    }
}

// MARK: - Catalog sources

/// Where the catalog is read from. App Store builds only have `.production`: the staging case, its
/// object path and the developer selection are compiled out (`#if DEBUG || INTERNAL_BUILD`). Both
/// sources serve the same v1 JSON contract from the same public bucket, read without credentials.
enum GearCatalogSource: String, CaseIterable, Sendable {
    case production
    #if DEBUG || INTERNAL_BUILD
    /// Internal preview of an unpublished catalog. Never falls back to bundled or production
    /// content, so nothing on screen can be mistaken for staging data.
    case staging
    #endif

    /// Public object path, relative to the Supabase project URL.
    var objectPath: String {
        switch self {
        case .production: return "storage/v1/object/public/recommended-gear/catalog-v1.json"
        #if DEBUG || INTERNAL_BUILD
        case .staging: return "storage/v1/object/public/recommended-gear/staging/catalog-v1.json"
        #endif
        }
    }

    var displayName: String {
        switch self {
        case .production: return "Production"
        #if DEBUG || INTERNAL_BUILD
        case .staging: return "Staging"
        #endif
        }
    }

    /// UserDefaults key prefix. Production keeps the original key names (no migration); each
    /// other source has its own cache, ETag, ordering state and revision history.
    fileprivate var keyPrefix: String {
        switch self {
        case .production: return "recommendedGear."
        #if DEBUG || INTERNAL_BUILD
        case .staging: return "recommendedGear.staging."
        #endif
        }
    }

    /// Before its first publication, production shows the bundled catalog; any other source shows
    /// nothing.
    fileprivate var usesBundledFallback: Bool { self == .production }
}

// MARK: - Store

/// Holds the last valid publication and the content both screens render.
///
/// - Before any valid publication: bundled content (production only; staging shows nothing).
/// - After one: only published content, persisted across launches. A valid empty catalog is
///   authoritative. Invalid, unsupported or older documents never replace it.
/// - If the saved publication becomes unreadable: empty content until the next valid download,
///   never the bundled items (they may have been withdrawn).
@MainActor
final class GearCatalogStore: ObservableObject {
    static let shared = GearCatalogStore(endpoints: GearCatalogStore.defaultEndpoints())

    enum Source: Equatable { case bundled, published, unreadable }

    enum RefreshOutcome: Equatable {
        case updated, unchanged, notModified, throttled, inProgress, notConfigured
        /// Made obsolete while in flight (source switched, staging reset, fixture loaded); its
        /// response or failure was discarded without changing anything.
        case superseded
        case rejected(GearCatalog.ValidationError)
        case httpStatus(Int)
        case failed
    }

    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)
    /// Suspends for the given number of seconds (throws when cancelled). Injected so offer timing
    /// can be tested deterministically; production uses `Task.sleep`.
    typealias Sleep = (TimeInterval) async throws -> Void

    @Published private(set) var content: GearContent
    /// Changes whenever the visible publication changes, including a source switch (not on offer expiry).
    @Published private(set) var generation = 0
    /// Production in App Store builds, always.
    @Published private(set) var activeSource: GearCatalogSource
    /// The last refresh result for `activeSource` (cleared on a source switch). For diagnostics.
    @Published private(set) var lastRefreshOutcome: RefreshOutcome?
    private(set) var catalog: GearCatalog?
    private(set) var source: Source

    /// Matches the recommended 60 s Cache-Control on the published object.
    static let minimumRefreshInterval: TimeInterval = 60
    nonisolated static let requestTimeout: TimeInterval = 15
    /// How many accepted revisions are remembered to reject reuse.
    static let rememberedRevisionCount = 100
    #if DEBUG || INTERNAL_BUILD
    static let selectedSourceKey = "recommendedGear.developer.selectedSource"
    #endif

    private let defaults: UserDefaults
    private let endpoints: [GearCatalogSource: URL]
    private let fetch: Fetch
    private let now: () -> Date
    private let sleep: Sleep
    private var lastAttempts: [GearCatalogSource: Date] = [:]

    // Request invalidation. Every event that makes a source's outstanding responses obsolete (a
    // switch away from or to it, a staging reset, a fixture load) bumps that source's epoch. A
    // request applies its result only if, when it returns, its source is still active AND the
    // epoch is the one it started with. Comparing the source alone is not enough: Production ->
    // Staging -> Production leaves the source equal while the old request is obsolete.
    private var requestEpochs: [GearCatalogSource: Int] = [:]
    private struct InFlightRequest { let id: Int; let epoch: Int }
    /// At most one tracked request per source; only a request from the current epoch counts as
    /// "in progress", and a request only ever clears its own entry.
    private var inFlight: [GearCatalogSource: InFlightRequest] = [:]
    private var nextRequestID = 0

    /// Makes every outstanding request for `source` obsolete and lets a fresh one start at once.
    private func invalidateRequests(for source: GearCatalogSource) {
        requestEpochs[source, default: 0] += 1
        inFlight[source] = nil
        lastAttempts[source] = nil
    }

    private func isCurrent(_ target: GearCatalogSource, epoch: Int) -> Bool {
        activeSource == target && requestEpochs[target, default: 0] == epoch
    }
    private var transitionTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Per-source persistence keys.
    private struct Keys {
        let catalog, receivedPublication, etag, lastPublishedAt, lastDigest, acceptedRevisions: String

        init(_ source: GearCatalogSource) {
            let prefix = source.keyPrefix
            catalog = prefix + "catalog.v1"
            receivedPublication = prefix + "receivedPublication"
            etag = prefix + "etag.v1"
            // Ordering state, stored apart from the document so it survives an unreadable cache.
            lastPublishedAt = prefix + "lastPublishedAt.v1"
            lastDigest = prefix + "lastDigest.v1"
            acceptedRevisions = prefix + "acceptedRevisions.v1"
        }
    }

    private var keys: Keys { Keys(activeSource) }

    init(
        defaults: UserDefaults = .standard,
        // No default: default arguments are evaluated outside the main actor, and reading
        // SupabaseConfig is main-actor isolated in this target.
        endpoints: [GearCatalogSource: URL],
        fetch: @escaping Fetch = GearCatalogStore.networkFetch,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
        observesApplication: Bool = true
    ) {
        self.defaults = defaults
        self.endpoints = endpoints
        self.fetch = fetch
        self.now = now
        self.sleep = sleep
        #if DEBUG || INTERNAL_BUILD
        activeSource = defaults.string(forKey: Self.selectedSourceKey).flatMap(GearCatalogSource.init(rawValue:)) ?? .production
        #else
        activeSource = .production
        #endif
        source = .bundled
        content = .bundled
        loadPersistedState()
        content = resolve(at: now())
        scheduleNextTransition()
        if observesApplication { observeApplication() }
    }

    /// Reads the active source's saved publication into `catalog`/`source`.
    private func loadPersistedState() {
        let keys = self.keys
        if let data = defaults.data(forKey: keys.catalog), let decoded = try? GearCatalog.decode(data) {
            catalog = decoded
            source = .published
            if defaults.object(forKey: keys.lastPublishedAt) == nil {
                defaults.set(decoded.publishedAt, forKey: keys.lastPublishedAt)
                defaults.set(GearCatalogDigest.of(data), forKey: keys.lastDigest)
                defaults.set([decoded.revision], forKey: keys.acceptedRevisions)
            }
        } else if defaults.bool(forKey: keys.receivedPublication) {
            // Corrupt, or written by an app version with different rules: force a full download.
            catalog = nil
            defaults.removeObject(forKey: keys.etag)
            source = .unreadable
        } else {
            catalog = nil
            source = .bundled
        }
    }

    static func defaultEndpoints() -> [GearCatalogSource: URL] {
        guard let config = try? SupabaseConfig.load() else { return [:] }
        var endpoints: [GearCatalogSource: URL] = [:]
        for source in GearCatalogSource.allCases {
            endpoints[source] = storageObjectURL(from: config.url, objectPath: source.objectPath)
        }
        return endpoints
    }

    /// SUPABASE_URL is configured as PostgREST's endpoint (`https://<ref>.supabase.co/rest/v1/`),
    /// but Storage lives at the project root (`/storage/v1/...`). Appending to the configured URL
    /// as-is produced `.../rest/v1/storage/v1/object/...`, which PostgREST answers with 401, so no
    /// catalog could ever load. This strips a trailing `rest/v1` (with or without a trailing slash)
    /// back to the project root first, the same rule as `ReferralAPIService.edgeFunctionURL`; a
    /// bare project-root URL is left unchanged.
    nonisolated static func storageObjectURL(from configuredURL: URL, objectPath: String) -> URL {
        let pathComponents = configuredURL.pathComponents.filter { $0 != "/" }
        let projectBaseURL = pathComponents.suffix(2) == ["rest", "v1"]
            ? configuredURL.deletingLastPathComponent().deletingLastPathComponent()
            : configuredURL
        return projectBaseURL.appending(path: objectPath)
    }

    /// An ephemeral session: no shared HTTP cache, cookies or credentials. Public read only.
    /// Enforces `GearCatalog.maximumBytes` while the body is received (Content-Length is not
    /// trusted), cancelling the transfer as soon as it is exceeded.
    nonisolated static let downloader: GearBoundedDownloader = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.waitsForConnectivity = false
        return GearBoundedDownloader(configuration: configuration)
    }()

    nonisolated static func networkFetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await downloader.data(for: request, limit: GearCatalog.maximumBytes)
        return (data, response)
    }

    // MARK: Developer source selection (Internal and Debug builds only)

    #if DEBUG || INTERNAL_BUILD
    /// Switches the catalog source, persisting the choice. The new source's own saved content (or
    /// nothing, for a staging source never fetched) is shown immediately; the caller then refreshes
    /// it (see `selectSourceAndRefresh`). Requests already in flight for either source are made
    /// obsolete and discarded when they return.
    func selectSource(_ newSource: GearCatalogSource) {
        guard newSource != activeSource else { return }
        invalidateRequests(for: activeSource)
        invalidateRequests(for: newSource)
        activeSource = newSource
        defaults.set(newSource.rawValue, forKey: Self.selectedSourceKey)
        lastRefreshOutcome = nil
        loadPersistedState()
        generation += 1
        reevaluate()
    }

    @discardableResult
    func selectSourceAndRefresh(_ newSource: GearCatalogSource) async -> RefreshOutcome {
        selectSource(newSource)
        return await refresh(force: true)
    }

    /// Applies a locally supplied document (for example a fixture pasted from the clipboard) to the
    /// STAGING source, with exactly the validation and ordering of a download. Lets Internal testers
    /// exercise scenarios without uploading anything. Production can never be changed this way.
    @discardableResult
    func acceptStagingFixture(_ data: Data) throws -> Bool {
        guard activeSource == .staging else {
            throw GearCatalog.ValidationError.invalid("select the Staging source first")
        }
        let changed = try accept(data, etag: nil)
        // An earlier download must not replace the fixture when it finally returns.
        invalidateRequests(for: .staging)
        lastRefreshOutcome = changed ? .updated : .unchanged
        return changed
    }

    /// Forgets everything received for staging (cache, ETag, ordering state, revisions), so a
    /// fixture sequence can be replayed from the start. Production is untouched.
    func resetStagingData() {
        let keys = Keys(.staging)
        for key in [keys.catalog, keys.receivedPublication, keys.etag, keys.lastPublishedAt, keys.lastDigest, keys.acceptedRevisions] {
            defaults.removeObject(forKey: key)
        }
        // A staging request still in flight must not repopulate what was just cleared.
        invalidateRequests(for: .staging)
        guard activeSource == .staging else { return }
        lastRefreshOutcome = nil
        loadPersistedState()
        generation += 1
        reevaluate()
    }

    /// For the developer card: what the active source currently holds.
    var activePublicationSummary: String {
        switch source {
        case .published:
            guard let catalog else { return "Published" }
            let date = Date(timeIntervalSince1970: catalog.publishedAt)
            return "Revision \(catalog.revision) · \(date.formatted(date: .abbreviated, time: .standard))"
        case .unreadable: return "Saved copy unreadable; showing nothing"
        case .bundled: return activeSource.usesBundledFallback ? "Bundled catalog (nothing published yet)" : "Nothing received yet; showing nothing"
        }
    }
    #endif

    // MARK: Content and offer timing

    /// Re-resolves content for the current clock (offer start/expiry) and re-arms the single timer.
    func reevaluate() {
        content = resolve(at: now())
        scheduleNextTransition()
    }

    private func resolve(at date: Date) -> GearContent {
        switch source {
        case .published: return catalog?.content(at: date) ?? .empty
        case .unreadable: return .empty
        case .bundled: return activeSource.usesBundledFallback ? .bundled : .empty
        }
    }

    /// One sleeping task until the next offer start/expiry, instead of a once-per-second loop.
    /// Foregrounding and clock changes re-run `reevaluate()`, which also covers time spent suspended.
    private func scheduleNextTransition() {
        transitionTask?.cancel()
        transitionTask = nil
        let current = now()
        guard let next = catalog?.nextOfferTransition(after: current) else { return }
        // Wake at the transition, but at least daily, so a long sleep is never the only safeguard.
        let delay = min(max(next.timeIntervalSince(current), 0.25), 86_400)
        let sleep = self.sleep
        transitionTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            // A timer replaced while it was waking must not act.
            guard Task.isCancelled == false else { return }
            self?.reevaluate()
        }
    }

    private func observeApplication() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reevaluate()
                Task { await self.refresh() }
            }
        })
        observers.append(center.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        })
        #endif
    }

    // MARK: Refresh

    /// Downloads the active source's published document. Every failure keeps the last valid
    /// content. Throttled to one attempt per source per `minimumRefreshInterval` unless `force` is
    /// set. A request made obsolete while in flight (see `invalidateRequests`) returns
    /// `.superseded` and changes nothing: no content, cache, ETag, ordering state, revision history
    /// or diagnostics.
    @discardableResult
    func refresh(force: Bool = false) async -> RefreshOutcome {
        let outcome = await refresh(activeSource, force: force)
        switch outcome {
        case .inProgress, .throttled, .superseded:
            break
        default:
            // Only reached with no suspension since the request was confirmed current.
            lastRefreshOutcome = outcome
        }
        return outcome
    }

    private func refresh(_ target: GearCatalogSource, force: Bool) async -> RefreshOutcome {
        guard let endpoint = endpoints[target] else { return .notConfigured }
        let epoch = requestEpochs[target, default: 0]
        if let running = inFlight[target], running.epoch == epoch { return .inProgress }
        let started = now()
        if force == false, let last = lastAttempts[target], started.timeIntervalSince(last) < Self.minimumRefreshInterval {
            return .throttled
        }
        nextRequestID += 1
        let id = nextRequestID
        inFlight[target] = InFlightRequest(id: id, epoch: epoch)
        lastAttempts[target] = started
        // Clears only this request's own entry, never a newer request's.
        defer { if inFlight[target]?.id == id { inFlight[target] = nil } }

        let keys = Keys(target)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if source == .published, let etag = defaults.string(forKey: keys.etag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            let (body, response) = try await fetch(request)
            guard isCurrent(target, epoch: epoch) else { return .superseded }
            guard let response = response as? HTTPURLResponse else { return .failed }
            data = body
            http = response
        } catch GearDownloadError.tooLarge {
            return isCurrent(target, epoch: epoch) ? .rejected(.downloadTooLarge) : .superseded
        } catch {
            return isCurrent(target, epoch: epoch) ? .failed : .superseded // Offline, timeout, cancelled.
        }
        // No suspension point from here on, so the request stays current while it is applied.

        switch http.statusCode {
        case 304:
            return .notModified
        case 200:
            do {
                let changed = try accept(data, etag: http.value(forHTTPHeaderField: "ETag"))
                return changed ? .updated : .unchanged
            } catch let error as GearCatalog.ValidationError {
                return .rejected(error)
            } catch {
                return .failed
            }
        default:
            // Including 404: a missing object never clears the catalog. Publish an empty catalog to
            // withdraw everything.
            return .httpStatus(http.statusCode)
        }
    }

    /// Validates, orders and, if accepted, persists and applies a downloaded document for the
    /// ACTIVE source. Returns whether the visible publication changed. Throws, persisting nothing
    /// (document, ordering state and ETag all unchanged), when the document is invalid or out of order:
    ///
    /// - byte-identical to the last accepted publication: accepted, unchanged (a retry or re-upload).
    ///   Also restores a saved copy that had become unreadable.
    /// - otherwise `publishedAt` must be strictly newer than the last accepted one (older: `.stale`,
    ///   equal: `.conflict`) and `revision` must not have been accepted before (`.revisionReused`).
    ///
    /// A rollback is therefore a NEW publication of the old content, with a new revision and a newer
    /// publishedAt. Each source has its own ordering state, so a staging publication never affects
    /// what production accepts.
    @discardableResult
    func accept(_ data: Data, etag: String? = nil) throws -> Bool {
        let keys = self.keys
        let next = try GearCatalog.decode(data)
        let digest = GearCatalogDigest.of(data)

        if digest == defaults.string(forKey: keys.lastDigest) {
            if let etag { defaults.set(etag, forKey: keys.etag) }
            guard source != .published else { return false }
            // Same publication as before, re-downloaded after the saved copy became unreadable.
            defaults.set(data, forKey: keys.catalog)
            apply(next)
            return true
        }

        if defaults.object(forKey: keys.lastPublishedAt) != nil {
            let last = defaults.double(forKey: keys.lastPublishedAt)
            if next.publishedAt < last { throw GearCatalog.ValidationError.stale }
            if next.publishedAt == last { throw GearCatalog.ValidationError.conflict }
        }
        var revisions = defaults.stringArray(forKey: keys.acceptedRevisions) ?? []
        if revisions.contains(next.revision) { throw GearCatalog.ValidationError.revisionReused }

        revisions.append(next.revision)
        defaults.set(Array(revisions.suffix(Self.rememberedRevisionCount)), forKey: keys.acceptedRevisions)
        defaults.set(next.publishedAt, forKey: keys.lastPublishedAt)
        defaults.set(digest, forKey: keys.lastDigest)
        defaults.set(data, forKey: keys.catalog)
        defaults.set(true, forKey: keys.receivedPublication)
        if let etag { defaults.set(etag, forKey: keys.etag) } else { defaults.removeObject(forKey: keys.etag) }
        apply(next)
        return true
    }

    private func apply(_ next: GearCatalog) {
        catalog = next
        source = .published
        generation += 1
        reevaluate()
    }
}

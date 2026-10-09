//
//  FeaturedGearTests.swift
//  EightyFiveBlendsTests
//
//  Pins the Recommended Gear carousel catalog (RecommendedGearView.swift): its page order, the
//  https-only link rule every destination passes through before openURL, RVP Supply's nine-wheel
//  gallery (order, ids, product URLs, and the asset-catalog image behind each tile), and
//  brand-specific copy guards. eFlexFuel is a neutral Featured Brand with no confirmed
//  relationship, so its copy must never claim sponsorship, partnership, affiliation, exclusivity,
//  or an offer. RVP Supply is an actual sponsor, so its copy may say so, but no card may state a
//  price, an offer, or an unsupported performance or compatibility claim.
//
//  Data and logic only: no SwiftUI rendering, no network, no openURL. The one exception is the
//  asset-catalog guard, which looks images up by name in the host app's bundle (this test target is
//  hosted by the app, so that bundle is available).
//

import Foundation
import Testing
import UIKit
@testable import EightyFiveBlends

@MainActor
struct FeaturedGearTests {

    // The user-facing strings a catalog entry owns. Chrome labels that live in the view (the
    // "Featured Brand" and "Sponsor" badges, the section heading) are fixed wording reviewed
    // separately; which badge a page gets is decided by its FeaturedGearPage case.
    private static func brandCopy(_ brand: FeaturedBrand) -> [String] {
        [
            brand.name,
            brand.tagline,
            brand.description,
            brand.ctaTitle,
            brand.accessibilityDescription
        ]
    }

    private static func productCopy(_ product: RVPWheelProduct) -> [String] {
        [product.displayName, product.accessibilityName]
    }

    // Nothing in the carousel may state a price, an offer, or an unsupported performance, race, or
    // compatibility claim, whichever brand it is.
    private static let unsupportedClaims = [
        "discount",
        "promo",
        "coupon",
        "% off",
        "$",
        "guarantee",
        "universal",
        "all vehicles",
        "fits all",
        "horsepower",
        "racing",
        "strongest",
        "fastest"
    ]

    // Relationship wording that is only legitimate for an actual sponsor.
    private static let relationshipClaims = [
        "official partner",
        "partner",
        "sponsor",
        "affiliate",
        "exclusive",
        "endorse"
    ]

    // The nine wheels in gallery order (row by row), as approved.
    private static let expectedGallery: [(id: String, name: String, asset: String, url: String)] = [
        ("oem-hellcat", "OEM Hellcat", "RVPWheelOEMHellcat", "https://rvpsupply.com/products/oem-beadlock-style-8"),
        ("oem-hellcat-v2", "OEM Hellcat V2", "RVPWheelOEMHellcatV2", "https://rvpsupply.com/products/oem-beadlock-style-4"),
        ("oem-hellcat-redeye", "OEM Hellcat Redeye", "RVPWheelOEMHellcatRedeye", "https://rvpsupply.com/products/oem-beadlock-style-9"),
        ("5-spoke-hellcat", "5 Spoke Hellcat", "RVPWheel5SpokeHellcat", "https://rvpsupply.com/products/oem-beadlock-style-3"),
        ("5-spoke-hellcat-v2", "5 Spoke Hellcat V2", "RVPWheel5SpokeHellcatV2", "https://rvpsupply.com/products/oem-beadlock-style-1"),
        ("oem-demon", "OEM Demon", "RVPWheelOEMDemon", "https://rvpsupply.com/products/oem-beadlock-style-7"),
        ("hollow-5-spoke", "Hollow 5 Spoke", "RVPWheelHollow5Spoke", "https://rvpsupply.com/products/oem-beadlock-style-5"),
        ("chrome-oem-hellcat", "Chrome OEM Hellcat", "RVPWheelChromeOEMHellcat", "https://rvpsupply.com/products/oem-beadlock-style-2"),
        ("oem-widebody", "OEM Widebody", "RVPWheelOEMWidebody", "https://rvpsupply.com/products/oem-beadlock-style-6")
    ]

    private static func assertAvoids(_ phrases: [String], in texts: [String]) {
        for text in texts {
            let lowered = text.lowercased()
            for phrase in phrases {
                #expect(lowered.contains(phrase) == false, "\"\(text)\" contains banned phrase \"\(phrase)\"")
            }
        }
    }

    // MARK: - Carousel catalog

    @Test("The carousel is exactly eFlexFuel (Featured Brand) then RVP Supply (sponsor)")
    func catalog_isEFlexFuelThenRVPSupply() {
        let pages = FeaturedGearPage.catalog
        #expect(pages.count == 2)

        guard case .brand(let brand) = pages[0] else {
            Issue.record("The first page must be the neutral eFlexFuel Featured Brand card")
            return
        }
        #expect(brand.id == "eflexfuel")
        #expect(brand.name == "eFlexFuel")
        #expect(brand.ctaTitle == "View eFlexFuel Products")

        guard case .sponsor(let sponsor) = pages[1] else {
            Issue.record("The second page must be the RVP Supply sponsor card")
            return
        }
        #expect(sponsor.id == "rvp-supply-oem-beadlocks")
        #expect(sponsor.name == "RVP Supply")
        #expect(sponsor.tagline == "OEM+ Beadlock Wheels")
        #expect(sponsor.description == "Nine OEM-style beadlock designs for supported fitments.")
        #expect(sponsor.ctaTitle == "View All RVP Wheels")
    }

    @Test("Page ids are unique and stable")
    func catalog_idsAreUniqueAndStable() {
        let ids = FeaturedGearPage.catalog.map { $0.id }
        #expect(Set(ids).count == ids.count)
        #expect(ids == ["eflexfuel", "rvp-supply-oem-beadlocks"])
    }

    @Test("Only RVP Supply is presented as a sponsor; eFlexFuel never is")
    func catalog_onlyRVPSupplyIsASponsor() {
        let sponsorIDs = FeaturedGearPage.catalog.compactMap { page -> String? in
            if case .sponsor(let brand) = page {
                return brand.id
            }
            return nil
        }
        #expect(sponsorIDs == ["rvp-supply-oem-beadlocks"])
    }

    // MARK: - Destinations

    @Test("eFlexFuel opens the official U.S. auto-products page over https")
    func eFlexFuel_destinationIsVerifiedHTTPSPage() {
        let destination = FeaturedBrand.eFlexFuel.destinationURL
        #expect(destination?.absoluteString == "https://eflexfuel.com/us/auto-products")
        #expect(FeaturedBrandLink.validatedURL(destination) != nil)
    }

    @Test("View All RVP Wheels opens the RVP Wheels collection over https")
    func rvpSupply_collectionDestinationIsWheelsCollection() {
        let destination = FeaturedBrand.rvpSupplyWheels.destinationURL
        #expect(destination?.absoluteString == "https://rvpsupply.com/collections/wheels-1")
        #expect(FeaturedBrandLink.validatedURL(destination) != nil)
    }

    @Test("Only well-formed https URLs with a host pass link validation")
    func validatedURL_acceptsOnlyHTTPS() {
        #expect(FeaturedBrandLink.validatedURL(nil) == nil)
        #expect(FeaturedBrandLink.validatedURL(URL(string: "https://example.com/products")) != nil)
        #expect(FeaturedBrandLink.validatedURL(URL(string: "HTTPS://example.com/products")) != nil)
    }

    @Test(
        "Non-https and hostless URLs are rejected",
        arguments: [
            "http://eflexfuel.com/us/auto-products",
            "mailto:someone@example.com",
            "tel:5555555555",
            "ftp://example.com/file",
            "e85blends://nearby",
            "https://",
            "/us/auto-products"
        ]
    )
    func validatedURL_rejectsEverythingElse(_ urlString: String) {
        #expect(FeaturedBrandLink.validatedURL(URL(string: urlString)) == nil)
    }

    // MARK: - RVP wheel gallery

    @Test("The RVP gallery has exactly nine wheels, in the approved row-by-row order")
    func gallery_hasNineWheelsInExpectedOrder() {
        let products = RVPWheelProduct.catalog
        #expect(products.count == 9)
        #expect(products.map { $0.id } == Self.expectedGallery.map { $0.id })
        #expect(products.map { $0.displayName } == Self.expectedGallery.map { $0.name })
        #expect(products.map { $0.assetName } == Self.expectedGallery.map { $0.asset })
        #expect(products.compactMap { $0.productURL?.absoluteString } == Self.expectedGallery.map { $0.url })
    }

    @Test("Wheel ids, names, assets, and product URLs are all unique")
    func gallery_valuesAreUnique() {
        let products = RVPWheelProduct.catalog
        #expect(Set(products.map { $0.id }).count == products.count)
        #expect(Set(products.map { $0.displayName }).count == products.count)
        #expect(Set(products.map { $0.assetName }).count == products.count)
        #expect(Set(products.map { $0.accessibilityName }).count == products.count)
        #expect(Set(products.compactMap { $0.productURL?.absoluteString }).count == products.count)
    }

    @Test("Every wheel opens its own https RVP product page, never the collection")
    func gallery_urlsAreHTTPSProductPages() {
        let collection = FeaturedBrand.rvpSupplyWheels.destinationURL

        for product in RVPWheelProduct.catalog {
            let validated = FeaturedBrandLink.validatedURL(product.productURL)
            #expect(validated != nil, "\(product.displayName) needs a valid https URL")
            #expect(product.productURL?.host(percentEncoded: false) == "rvpsupply.com")
            #expect(product.productURL?.path.hasPrefix("/products/oem-beadlock-style-") == true)
            #expect(product.productURL != collection)
        }
    }

    @Test("Every wheel names a non-empty asset, and that image exists in the asset catalog")
    func gallery_assetsExistInCatalog() {
        for product in RVPWheelProduct.catalog {
            #expect(product.assetName.isEmpty == false)
            #expect(product.assetName.hasPrefix("RVPWheel"))
            #expect(UIImage(named: product.assetName) != nil, "Missing asset-catalog image \"\(product.assetName)\"")
        }
    }

    @Test("Each tile announces its product name as a beadlock wheel")
    func gallery_accessibilityNamesIdentifyEachWheel() {
        for product in RVPWheelProduct.catalog {
            #expect(product.accessibilityName == "\(product.displayName) beadlock wheel")
        }
    }

    // MARK: - Copy guards

    @Test("eFlexFuel copy claims no relationship, offer, or unsupported result")
    func eFlexFuelCopy_avoidsRelationshipAndUnsupportedClaims() {
        // Neutral Featured Brand: no sponsor/partner/affiliate/exclusive/endorse wording at all,
        // and no mention of the separate sponsor either.
        Self.assertAvoids(
            Self.relationshipClaims + Self.unsupportedClaims + ["rvp"],
            in: Self.brandCopy(.eFlexFuel)
        )
    }

    @Test("RVP Supply copy may say sponsor but claims no partnership, offer, or unsupported result")
    func rvpSupplyCopy_avoidsUnsupportedClaims() {
        // "sponsor" and "sponsored" are allowed here: RVP Supply is an actual sponsor. A
        // partnership, affiliation, exclusivity, or endorsement is still not claimed.
        var texts = Self.brandCopy(.rvpSupplyWheels)
        texts += RVPWheelProduct.catalog.flatMap { Self.productCopy($0) }
        texts.append(RVPWheelProduct.footnote)

        Self.assertAvoids(
            ["official partner", "affiliate", "exclusive", "endorse"] + Self.unsupportedClaims,
            in: texts
        )
    }

    @Test("The gallery footnote claims no specification shared by all nine wheels")
    func gallery_footnoteMakesNoSharedSpecificationClaim() {
        // The rotary-forged 6061-T6 wording has only been checked on one of the nine product pages,
        // so the footnote points to the product pages for specifications rather than asserting it.
        Self.assertAvoids(["6061", "rotary", "forged", "aluminum"], in: [RVPWheelProduct.footnote])
        #expect(RVPWheelProduct.footnote.lowercased().contains("see product pages"))
    }
}

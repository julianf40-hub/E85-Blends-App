//
//  FeaturedGearTests.swift
//  EightyFiveBlendsTests
//
//  Pins the Recommended Gear carousel catalog (RecommendedGearView.swift): its page order, the
//  https-only link rule every destination passes through before openURL, and brand-specific copy
//  guards. eFlexFuel is a neutral Featured Brand with no confirmed relationship, so its copy must
//  never claim sponsorship, partnership, affiliation, exclusivity, or an offer. RVP Supply is an
//  actual sponsor, so its copy may say so, but no card may state a price, an offer, or an
//  unsupported performance or compatibility claim.
//
//  Pure data and logic only: no SwiftUI rendering, no network, no openURL.
//

import Foundation
import Testing
@testable import EightyFiveBlends

@MainActor
struct FeaturedGearTests {

    // The user-facing strings a catalog entry owns. Chrome labels that live in the view (the
    // "Featured Brand" and "Sponsor" badges, the section heading) are fixed wording reviewed
    // separately; which badge a page gets is decided by its FeaturedGearPage case.
    private static func copy(of brand: FeaturedBrand) -> [String] {
        [
            brand.name,
            brand.tagline,
            brand.description,
            brand.ctaTitle,
            brand.accessibilityDescription
        ]
    }

    // Nothing in the carousel may state a price, an offer, or an unsupported performance or
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
        "horsepower"
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

    private static func assertAvoids(_ phrases: [String], in texts: [String]) {
        for text in texts {
            let lowered = text.lowercased()
            for phrase in phrases {
                #expect(lowered.contains(phrase) == false, "\"\(text)\" contains banned phrase \"\(phrase)\"")
            }
        }
    }

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
        #expect(sponsor.ctaTitle == "View OEM+ Beadlocks")
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

    @Test("eFlexFuel opens the official U.S. auto-products page over https")
    func eFlexFuel_destinationIsVerifiedHTTPSPage() {
        let destination = FeaturedBrand.eFlexFuel.destinationURL
        #expect(destination?.absoluteString == "https://eflexfuel.com/us/auto-products")
        #expect(FeaturedBrandLink.validatedURL(destination) != nil)
    }

    @Test("RVP Supply opens its Wheels collection over https")
    func rvpSupply_destinationIsWheelsCollection() {
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

    @Test("eFlexFuel copy claims no relationship, offer, or unsupported result")
    func eFlexFuelCopy_avoidsRelationshipAndUnsupportedClaims() {
        // Neutral Featured Brand: no sponsor/partner/affiliate/exclusive/endorse wording at all,
        // and no mention of the separate sponsor either.
        Self.assertAvoids(
            Self.relationshipClaims + Self.unsupportedClaims + ["rvp"],
            in: Self.copy(of: .eFlexFuel)
        )
    }

    @Test("RVP Supply copy may say sponsor but claims no partnership, offer, or unsupported result")
    func rvpSupplyCopy_avoidsUnsupportedClaims() {
        // "sponsor" and "sponsored" are allowed here: RVP Supply is an actual sponsor. A
        // partnership, affiliation, exclusivity, or endorsement is still not claimed.
        Self.assertAvoids(
            ["official partner", "affiliate", "exclusive", "endorse"] + Self.unsupportedClaims,
            in: Self.copy(of: .rvpSupplyWheels)
        )
    }
}

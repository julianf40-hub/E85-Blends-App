//
//  FeaturedGearTests.swift
//  EightyFiveBlendsTests
//
//  Pins the Recommended Gear Featured Brands catalog (RecommendedGearView.swift): its page order,
//  the https-only link rule every destination passes through before openURL, and a copy guard that
//  keeps unconfirmed-relationship language (sponsorship, partnership, endorsement, offers) out of
//  the catalog's user-facing strings. Also guards the More-screen separation: the More sponsor
//  placement never appears in this carousel.
//
//  Pure data and logic only: no SwiftUI rendering, no network, no openURL.
//

import Foundation
import Testing
@testable import EightyFiveBlends

@MainActor
struct FeaturedGearTests {

    // Every user-facing string the catalog owns. Chrome labels that live in the view (the
    // "Featured Brand" badge, the section heading) are fixed neutral wording reviewed separately.
    private static func catalogCopy() -> [String] {
        FeaturedGearPage.catalog.flatMap { page -> [String] in
            switch page {
            case .brand(let brand):
                return [
                    brand.name,
                    brand.tagline,
                    brand.description,
                    brand.ctaTitle,
                    brand.accessibilityDescription
                ]
            case .comingSoon(let placeholder):
                return [placeholder.title, placeholder.message]
            }
        }
    }

    @Test("The demo carousel is eFlexFuel first, then one non-brand placeholder")
    func catalog_isEFlexFuelThenPlaceholder() {
        let pages = FeaturedGearPage.catalog
        #expect(pages.count == 2)

        guard case .brand(let brand) = pages[0] else {
            Issue.record("The first page must be the eFlexFuel brand card")
            return
        }
        #expect(brand.id == "eflexfuel")
        #expect(brand.name == "eFlexFuel")
        #expect(brand.ctaTitle == "View eFlexFuel Products")

        guard case .comingSoon(let placeholder) = pages[1] else {
            Issue.record("The second page must be the neutral coming-soon placeholder")
            return
        }
        #expect(placeholder.title == "More Featured Gear")
    }

    @Test("Page ids are unique and stable")
    func catalog_idsAreUniqueAndStable() {
        let ids = FeaturedGearPage.catalog.map { $0.id }
        #expect(Set(ids).count == ids.count)
        #expect(ids == ["eflexfuel", "more-featured-gear"])
    }

    @Test("eFlexFuel opens the official U.S. auto-products page over https")
    func eFlexFuel_destinationIsVerifiedHTTPSPage() {
        let destination = FeaturedBrand.eFlexFuel.destinationURL
        #expect(destination?.absoluteString == "https://eflexfuel.com/us/auto-products")
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

    @Test("Catalog copy never claims an unconfirmed relationship, offer, or result")
    func catalogCopy_avoidsUnconfirmedClaims() {
        let banned = [
            "official partner",
            "partner",
            "sponsor",
            "affiliate",
            "exclusive",
            "endorse",
            "discount",
            "promo",
            "coupon",
            "% off",
            "guarantee",
            "rvp"
        ]

        for text in Self.catalogCopy() {
            let lowered = text.lowercased()
            for phrase in banned {
                #expect(lowered.contains(phrase) == false, "\"\(text)\" contains banned phrase \"\(phrase)\"")
            }
        }
    }
}

//
//  FeaturedGearTests.swift
//  EightyFiveBlendsTests
//
//  Pins the Recommended Gear carousel catalog (RecommendedGearView.swift): its page order, the
//  https-only link rule every destination passes through before openURL, RVP Supply's nine-wheel
//  gallery (order, ids, product URLs, and the asset-catalog image behind each tile), and
//  brand-specific copy guards. eFlexFuel is a neutral Featured Brand, so its brand copy must never
//  claim sponsorship, partnership, affiliation, exclusivity, or an unsupported result; the one thing
//  it may carry beyond that copy is the explicitly approved promotion (`FeaturedOffer.eFlexFuel`: code
//  E85BLENDS, $100 off eligible Auto or Moto conversion kits, with the commission disclosure), which
//  is held to its own guards below and invents no expiry, exclusivity, or extra eligibility. RVP
//  Supply is an actual sponsor, so its copy may say so, but no card may state a price, an offer, or
//  an unsupported performance or compatibility claim.
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
    // separately; which badge a page gets is decided by its FeaturedGearPage case. A brand's offer
    // is deliberately NOT part of this list: it is the one approved exception to the no-price,
    // no-discount, no-"85Blends" rules below, so it has its own narrower guards (see "Offer").
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
        "endorse",
        // Wording that reads as a tie to 85Blends or as vouching for the brand: eFlexFuel's own page
        // never says "integration", so the app must not either.
        "integrat",
        "works with",
        "work with",
        "85blends",
        "official",
        "authorized",
        "trusted",
        "preferred",
        "powered by",
        "collaborat"
    ]

    // The nine wheels in gallery order (row by row), as approved. Each name is RVP Supply's own
    // product title without its trailing "Beadlock" (e.g. "OEM Hellcat Style Beadlock"), checked
    // against the live product pages.
    private static let expectedGallery: [(id: String, name: String, asset: String, url: String)] = [
        ("oem-hellcat", "OEM Hellcat Style", "RVPWheelOEMHellcat", "https://rvpsupply.com/products/oem-beadlock-style-8"),
        ("oem-hellcat-v2", "OEM Hellcat Style V2", "RVPWheelOEMHellcatV2", "https://rvpsupply.com/products/oem-beadlock-style-4"),
        ("oem-hellcat-redeye", "OEM Hellcat Redeye Style", "RVPWheelOEMHellcatRedeye", "https://rvpsupply.com/products/oem-beadlock-style-9"),
        ("5-spoke-hellcat", "5 Spoke Hellcat Style", "RVPWheel5SpokeHellcat", "https://rvpsupply.com/products/oem-beadlock-style-3"),
        ("5-spoke-hellcat-v2", "5 Spoke Hellcat Style V2", "RVPWheel5SpokeHellcatV2", "https://rvpsupply.com/products/oem-beadlock-style-1"),
        ("oem-demon", "OEM Demon Style", "RVPWheelOEMDemon", "https://rvpsupply.com/products/oem-beadlock-style-7"),
        ("hollow-5-spoke", "Hollow 5 Spoke Style", "RVPWheelHollow5Spoke", "https://rvpsupply.com/products/oem-beadlock-style-5"),
        ("chrome-oem-hellcat", "Chrome OEM Hellcat Style", "RVPWheelChromeOEMHellcat", "https://rvpsupply.com/products/oem-beadlock-style-2"),
        ("oem-widebody", "OEM Widebody Style", "RVPWheelOEMWidebody", "https://rvpsupply.com/products/oem-beadlock-style-6")
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

    @Test("Only eFlexFuel carries an offer; RVP Supply, the sponsor, carries none")
    func catalog_onlyEFlexFuelHasAnOffer() {
        let withOffer = FeaturedGearPage.catalog.compactMap { page -> String? in
            switch page {
            case .brand(let brand), .sponsor(let brand):
                return brand.offer == nil ? nil : brand.id
            }
        }
        #expect(withOffer == ["eflexfuel"])
        #expect(FeaturedBrand.rvpSupplyWheels.offer == nil)
        #expect(FeaturedBrand.eFlexFuel.offer == FeaturedOffer.eFlexFuel)
    }

    @Test("eFlexFuel names its official wordmark asset; RVP Supply names none here")
    func brands_wordmarkAssetNames() {
        #expect(FeaturedBrand.eFlexFuel.wordmarkAssetName == "EFlexFuelWordmark")
        #expect(FeaturedBrand.rvpSupplyWheels.wordmarkAssetName == nil)
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

    @Test("Wheel names keep RVP's own \"Style\" wording, so none reads as a genuine OEM part")
    func gallery_namesKeepManufacturerStyleWording() {
        for product in RVPWheelProduct.catalog {
            #expect(product.displayName.contains(" Style"), "\"\(product.displayName)\" must keep RVP's \"Style\" qualifier")
            #expect(product.accessibilityName.contains(" Style"), "\"\(product.accessibilityName)\" must keep RVP's \"Style\" qualifier")
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

    // MARK: - Offer
    //
    // The approved eFlexFuel promotion: the only price, discount, or "85Blends" wording allowed
    // anywhere in the carousel. These guards keep it to exactly what was approved.

    // Everything the offer shows or speaks, except the commission disclosure (which has to name 85Blends).
    private static func offerCopyWithoutDisclosure(_ offer: FeaturedOffer) -> [String] {
        [
            offer.headline,
            offer.detail,
            offer.terms,
            FeaturedOffer.codeLabel,
            FeaturedOffer.copyTitle,
            FeaturedOffer.copiedTitle,
            offer.accessibilityLabel,
            offer.copyButtonAccessibilityLabel,
            offer.copiedButtonAccessibilityLabel,
            offer.copiedAnnouncement
        ]
    }

    @Test("The offer is $100 off with code E85BLENDS, exactly")
    func offer_isTheApprovedCodeAndAmount() {
        let offer = FeaturedOffer.eFlexFuel
        #expect(offer.code == "E85BLENDS")
        #expect(offer.amountOff == 100)
        #expect(offer.headline == "$100 OFF")
        #expect(offer.detail == "Save $100 on eligible eFlexFuel Auto or Moto conversion kits.")
        #expect(FeaturedOffer.codeLabel == "Use code")
        #expect(FeaturedOffer.copyTitle == "Copy Code")
        #expect(FeaturedOffer.copiedTitle == "Copied")
    }

    @Test("The offer is for eligible Auto or Moto conversion kits and claims nothing broader")
    func offer_claimsNoUniversalEligibility() {
        let detail = FeaturedOffer.eFlexFuel.detail.lowercased()
        #expect(detail.contains("eligible"))
        #expect(detail.contains("auto"))
        #expect(detail.contains("moto"))
        #expect(detail.contains("conversion kits"))
        // No sitewide, accessory, all-product, or guaranteed wording.
        Self.assertAvoids(
            ["sitewide", "site-wide", "everything", "every ", "all products", "all kits", "any ", "accessor", "guarantee", "universal", "all vehicles", "fits all", "free"],
            in: [detail]
        )
    }

    @Test("The offer says eFlexFuel decides eligibility at checkout and discloses 85Blends' commission")
    func offer_hasTermsNoteAndCommissionDisclosure() {
        let offer = FeaturedOffer.eFlexFuel
        #expect(offer.terms == "Offer terms are determined by eFlexFuel at checkout.")
        #expect(offer.disclosure == "85Blends may earn a commission on qualifying purchases.")
        #expect(offer.finePrint == "\(offer.terms) \(offer.disclosure)")
    }

    @Test("The offer invents no expiry, exclusivity, urgency, or extra condition")
    func offer_inventsNoTermsOrUrgency() {
        let offer = FeaturedOffer.eFlexFuel
        let everything = Self.offerCopyWithoutDisclosure(offer) + [offer.disclosure, offer.finePrint]
        Self.assertAvoids(
            ["exclusive", "limited", "expire", "expiry", "ends today", "ends soon", "ends in", "ends on", "until", "today",
             "now only", "hurry", "last chance", "minimum", "first order", "new customer", "stack", "free shipping",
             "% off", "percent", "bonus", "extra"],
            in: everything
        )

        // The only digits anywhere are the approved $100 and the 85 in "E85BLENDS" and "85Blends".
        for text in everything {
            let stripped = text
                .replacingOccurrences(of: "E85BLENDS", with: "")
                .replacingOccurrences(of: "85Blends", with: "")
                .replacingOccurrences(of: "$100", with: "")
            #expect(stripped.contains(where: \.isNumber) == false, "\"\(text)\" has an unapproved number")
        }
    }

    @Test("The offer claims no sponsorship, partnership, or endorsement")
    func offer_claimsNoRelationship() {
        let offer = FeaturedOffer.eFlexFuel
        // "85blends" is left out for the disclosure only: it has to name 85Blends to say who may earn
        // the commission. Everything else about a relationship stays banned in all offer copy.
        let relationshipClaimsExceptName = Self.relationshipClaims.filter { $0 != "85blends" }
        Self.assertAvoids(
            relationshipClaimsExceptName + ["rvp"],
            in: Self.offerCopyWithoutDisclosure(offer) + [offer.disclosure, offer.finePrint]
        )
        // The offer's own wording (apart from the disclosure) never names 85Blends. The approved code
        // E85BLENDS contains the letters, so it is masked out before looking.
        let withoutCode = Self.offerCopyWithoutDisclosure(offer).map {
            $0.replacingOccurrences(of: offer.code, with: "")
        }
        Self.assertAvoids(["85blends"], in: withoutCode)
    }

    @Test("The offer's VoiceOver text names the code, the kits and the button, and Copied is announced")
    func offer_accessibilityText() {
        let offer = FeaturedOffer.eFlexFuel
        #expect(offer.accessibilityLabel == "Save $100 on eligible eFlexFuel Auto or Moto conversion kits. Use code E85BLENDS.")
        #expect(offer.copyButtonAccessibilityLabel == "Copy code E85BLENDS")
        #expect(offer.copiedButtonAccessibilityLabel == "Copied. Code E85BLENDS")
        #expect(offer.copiedAnnouncement == "Code E85BLENDS copied to the clipboard.")
    }

    @Test("The brand copy itself still has no offer, price, or relationship wording; the offer is separate")
    func offer_staysOutOfTheBrandCopy() {
        // The guard above (eFlexFuelCopy_avoidsRelationshipAndUnsupportedClaims) still covers every
        // brand string unchanged; this pins that the offer's amount and code are not in it.
        let brandStrings = Self.brandCopy(.eFlexFuel).joined(separator: " ")
        #expect(brandStrings.contains("E85BLENDS") == false)
        #expect(brandStrings.contains("$") == false)
    }

    // MARK: - Badges

    @Test("The neutral brand badge never says Sponsor; the RVP badge does")
    func badges_matchTheRelationship() {
        #expect(FeaturedGearPage.brandBadgeTitle == "Featured Brand")
        #expect(FeaturedGearPage.sponsorBadgeTitle == "Sponsor")
        Self.assertAvoids(Self.relationshipClaims, in: [FeaturedGearPage.brandBadgeTitle])
    }

    // MARK: - Every destination

    @Test("Every destination the carousel can open (2 brand pages + 9 products) passes the https link gate")
    func everyDestination_passesLinkGate() {
        let brandURLs: [URL?] = FeaturedGearPage.catalog.map { page in
            switch page {
            case .brand(let brand), .sponsor(let brand):
                return brand.destinationURL
            }
        }
        let all = brandURLs + RVPWheelProduct.catalog.map { $0.productURL }
        #expect(all.count == 11)
        #expect(all.allSatisfy { FeaturedBrandLink.validatedURL($0) != nil })
        // The app's own scheme would be routed back into the app by ContentView's .onOpenURL.
        #expect(all.allSatisfy { $0?.scheme?.lowercased() != "e85blends" })
    }

    // MARK: - VoiceOver copy

    @Test("The eFlexFuel carousel and More-card VoiceOver text is neutral and carries its position")
    func eFlexFuelAccessibilityCopy_isNeutralAndPositioned() {
        let brand = FeaturedBrand.eFlexFuel
        let carousel = brand.brandCardAccessibilityLabel(position: 1, total: 2)

        #expect(carousel.hasPrefix("eFlexFuel. Featured brand 1 of 2."))
        #expect(carousel == "eFlexFuel. Featured brand 1 of 2. \(brand.accessibilityDescription)")
        // The call to action is a separate button with its own label, so it is not read twice.
        #expect(carousel.contains(brand.ctaTitle) == false)
        #expect(brand.compactCardAccessibilityLabel == "eFlexFuel. Featured brand. Flex-fuel conversion & ethanol monitoring.")
        #expect(brand.compactCardAccessibilityHint == "Opens Recommended Gear with eFlexFuel featured.")

        Self.assertAvoids(
            Self.relationshipClaims + Self.unsupportedClaims + ["rvp"],
            in: [carousel, brand.compactCardAccessibilityLabel, brand.compactCardAccessibilityHint]
        )
    }

    @Test("The RVP sponsor header says Sponsor and its position, and claims no partnership or offer")
    func rvpSupplyAccessibilityHeader_identifiesSponsorAndPosition() {
        let label = FeaturedBrand.rvpSupplyWheels.sponsorHeaderAccessibilityLabel(position: 2, total: 2)

        #expect(label.hasPrefix("RVP Supply. Sponsor."))
        #expect(label.contains("Featured card 2 of 2."))
        Self.assertAvoids(["official partner", "affiliate", "exclusive", "endorse"] + Self.unsupportedClaims, in: [label])
    }

    // MARK: - Gallery layout

    @Test("Standard text sizes show three wheels per row, accessibility sizes two")
    func galleryLayout_columnCount() {
        #expect(FeaturedGalleryLayout.columnCount(isAccessibilitySize: false) == 3)
        #expect(FeaturedGalleryLayout.columnCount(isAccessibilitySize: true) == 2)
    }

    @Test("Nine wheels fill three rows of three at standard sizes, in order, with no padding")
    func galleryLayout_standardRows() {
        let ids = RVPWheelProduct.catalog.map { $0.id }
        let rows = FeaturedGalleryLayout.rows(ids, columns: 3)

        #expect(rows.map(\.count) == [3, 3, 3])
        #expect(rows.flatMap { $0 } == ids)
        #expect(rows.allSatisfy { FeaturedGalleryLayout.padding(forRowOf: $0.count, columns: 3) == 0 })
    }

    @Test("At accessibility sizes the nine wheels become four rows of two, then a padded row of one")
    func galleryLayout_accessibilityRows() {
        let ids = RVPWheelProduct.catalog.map { $0.id }
        let rows = FeaturedGalleryLayout.rows(ids, columns: 2)

        #expect(rows.map(\.count) == [2, 2, 2, 2, 1])
        #expect(rows.flatMap { $0 } == ids)
        #expect(rows.dropLast().allSatisfy { FeaturedGalleryLayout.padding(forRowOf: $0.count, columns: 2) == 0 })
        #expect(FeaturedGalleryLayout.padding(forRowOf: 1, columns: 2) == 1)
    }

    @Test("Degenerate input never traps and never drops a tile")
    func galleryLayout_degenerateInputs() {
        #expect(FeaturedGalleryLayout.rows([Int](), columns: 3).isEmpty)
        #expect(FeaturedGalleryLayout.rows([1, 2, 3], columns: 0) == [[1], [2], [3]])
        #expect(FeaturedGalleryLayout.rows([1, 2], columns: 5) == [[1, 2]])
        #expect(FeaturedGalleryLayout.padding(forRowOf: 5, columns: 3) == 0)
    }
}

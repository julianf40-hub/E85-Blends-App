//
//  RecommendedGearView.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation
import SwiftUI

// MARK: - Featured content model
//
// Recommended Gear leads with a "Featured Brands" carousel. "Featured" is a neutral placement
// label only: a `.brand` page states or implies no sponsorship, partnership, affiliate
// relationship, endorsement, discount, or offer, and must keep it that way until a relationship
// is confirmed and approved wording exists. The one exception is a `.sponsor` page, reserved for
// an actual sponsor (RVP Supply) and labeled as such; it still carries no price, discount, or
// performance or compatibility claim.
//
// These are presentation data only: no `Color`s (AppTheme tokens are dynamic and must be resolved
// inside `body`, never cached), no remote configuration. They are not `private` solely so
// EightyFiveBlendsTests can pin the catalog, the copy, and the link rules.

/// A brand card in the Featured Brands carousel.
struct FeaturedBrand: Identifiable {
    let id: String
    let name: String
    let tagline: String
    let description: String
    let ctaTitle: String
    let destinationURL: URL?
    let accessibilityDescription: String
}

extension FeaturedBrand {
    static let eFlexFuel = FeaturedBrand(
        id: "eflexfuel",
        name: "eFlexFuel",
        tagline: "Flex-fuel conversion & ethanol monitoring",
        description: "Flex-fuel conversion kits, real-time ethanol monitoring, and eFlexApp integration for E85 drivers.",
        ctaTitle: "View eFlexFuel Products",
        destinationURL: URL(string: "https://eflexfuel.com/us/auto-products"),
        accessibilityDescription: "Flex-fuel conversion and ethanol monitoring. Flex-fuel conversion kits, real-time ethanol monitoring, and eFlexApp integration for E85 drivers."
    )
}

extension FeaturedBrand {
    /// RVP Supply's OEM+ beadlock wheels, shown as a labeled sponsor. The call to action opens the
    /// Wheels collection, and the card's gallery (`RVPWheelProduct.catalog`) opens individual
    /// products. The copy is deliberately conservative: no price, no performance or race claim,
    /// and no claim of universal fitment.
    static let rvpSupplyWheels = FeaturedBrand(
        id: "rvp-supply-oem-beadlocks",
        name: "RVP Supply",
        tagline: "OEM+ Beadlock Wheels",
        description: "Nine OEM-style beadlock designs for supported fitments.",
        ctaTitle: "View All RVP Wheels",
        destinationURL: URL(string: "https://rvpsupply.com/collections/wheels-1"),
        accessibilityDescription: "OEM plus beadlock wheels."
    )
}

/// One wheel in RVP Supply's gallery: its photo (an image set in the asset catalog, named by
/// `assetName`) and the RVP product page it opens. Presentation data only, like `FeaturedBrand`.
struct RVPWheelProduct: Identifiable {
    let id: String
    let displayName: String
    let assetName: String
    let productURL: URL?
    let accessibilityName: String
}

extension RVPWheelProduct {
    /// RVP Supply's nine current OEM-style beadlock designs, in gallery order (row by row).
    static let catalog: [RVPWheelProduct] = [
        RVPWheelProduct(
            id: "oem-hellcat",
            displayName: "OEM Hellcat",
            assetName: "RVPWheelOEMHellcat",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-8"),
            accessibilityName: "OEM Hellcat beadlock wheel"
        ),
        RVPWheelProduct(
            id: "oem-hellcat-v2",
            displayName: "OEM Hellcat V2",
            assetName: "RVPWheelOEMHellcatV2",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-4"),
            accessibilityName: "OEM Hellcat V2 beadlock wheel"
        ),
        RVPWheelProduct(
            id: "oem-hellcat-redeye",
            displayName: "OEM Hellcat Redeye",
            assetName: "RVPWheelOEMHellcatRedeye",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-9"),
            accessibilityName: "OEM Hellcat Redeye beadlock wheel"
        ),
        RVPWheelProduct(
            id: "5-spoke-hellcat",
            displayName: "5 Spoke Hellcat",
            assetName: "RVPWheel5SpokeHellcat",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-3"),
            accessibilityName: "5 Spoke Hellcat beadlock wheel"
        ),
        RVPWheelProduct(
            id: "5-spoke-hellcat-v2",
            displayName: "5 Spoke Hellcat V2",
            assetName: "RVPWheel5SpokeHellcatV2",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-1"),
            accessibilityName: "5 Spoke Hellcat V2 beadlock wheel"
        ),
        RVPWheelProduct(
            id: "oem-demon",
            displayName: "OEM Demon",
            assetName: "RVPWheelOEMDemon",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-7"),
            accessibilityName: "OEM Demon beadlock wheel"
        ),
        RVPWheelProduct(
            id: "hollow-5-spoke",
            displayName: "Hollow 5 Spoke",
            assetName: "RVPWheelHollow5Spoke",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-5"),
            accessibilityName: "Hollow 5 Spoke beadlock wheel"
        ),
        RVPWheelProduct(
            id: "chrome-oem-hellcat",
            displayName: "Chrome OEM Hellcat",
            assetName: "RVPWheelChromeOEMHellcat",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-2"),
            accessibilityName: "Chrome OEM Hellcat beadlock wheel"
        ),
        RVPWheelProduct(
            id: "oem-widebody",
            displayName: "OEM Widebody",
            assetName: "RVPWheelOEMWidebody",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-6"),
            accessibilityName: "OEM Widebody beadlock wheel"
        )
    ]

    /// The fact line under the gallery. Only one of the nine product pages has been checked for
    /// the "rotary-forged 6061-T6 aluminum" wording, so this does not claim a shared specification;
    /// it points to each product page instead.
    static let footnote = "OEM+ beadlock designs · See product pages for fitment and specifications"
}

/// One page of the Featured Brands carousel. Both cases share the `FeaturedBrand` data shape; the
/// case picks the presentation and the label: `.brand` is the neutral "Featured Brand" card, and
/// `.sponsor` is reserved for an actual sponsor and is labeled "Sponsor".
enum FeaturedGearPage: Identifiable {
    case brand(FeaturedBrand)
    case sponsor(FeaturedBrand)

    var id: String {
        switch self {
        case .brand(let brand), .sponsor(let brand):
            return brand.id
        }
    }

    /// Live-demo catalog: exactly two pages, eFlexFuel (neutral Featured Brand) then RVP Supply
    /// (sponsor).
    static let catalog: [FeaturedGearPage] = [
        .brand(.eFlexFuel),
        .sponsor(.rvpSupplyWheels)
    ]
}

/// The single gate every featured-brand destination passes through before `openURL`: a
/// well-formed `https` URL with a host, and nothing else (never http, mailto:, tel:, or the app's
/// own e85blends:// scheme, which ContentView's `.onOpenURL` would route back into the app).
nonisolated enum FeaturedBrandLink {
    static func validatedURL(_ url: URL?) -> URL? {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host(percentEncoded: false),
              host.isEmpty == false
        else {
            return nil
        }
        return url
    }
}

// MARK: - Screen

struct RecommendedGearView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedPageID: String?
    @State private var linkMessages: [String: String] = [:]
    @State private var pageHeights: [String: CGFloat] = [:]

    private let pages = FeaturedGearPage.catalog

    // Each card takes most of the carousel's width so the next one peeks in from the trailing
    // edge, which is what tells people the row swipes. On page 1 the peek works out to
    // (1 - cardWidthFraction) * container - (cardSpacing - pageMargin), about 16-21pt on 375-440pt
    // wide phones. That is roughly a card's 18pt inner padding, so only the next card's outer edge
    // (at most the first couple of points of its content) shows and none of its text is readable
    // or clipped into view. The card spacing is also larger than the page margin so, once a later
    // card is aligned to the margin, the previous one is fully off screen instead of leaving a
    // sliver at the screen edge.
    private static let cardWidthFraction: CGFloat = 0.93
    private static let cardSpacing: CGFloat = 24
    private static let pageMargin: CGFloat = 16

    private var currentPageIndex: Int {
        pages.firstIndex(where: { $0.id == selectedPageID }) ?? 0
    }

    // The carousel is as tall as the page being shown. The RVP gallery card is much taller than the
    // eFlexFuel card, and stretching the shorter page to match (or leaving a gap under it) would look
    // broken, so each page keeps its natural height and the carousel follows the current one. It is
    // nil until the first measurement, when the carousel just sizes to its tallest page.
    private var carouselHeight: CGFloat? {
        pageHeights[pages[currentPageIndex].id]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                    .padding(.horizontal, Self.pageMargin)

                featuredBrandsSection

                aboutFeaturedBrandsCard
                    .padding(.horizontal, Self.pageMargin)
            }
            .padding(.vertical, 16)
            // Eases the carousel's height change (and the page dots and About card moving with it)
            // when the page changes. Keyed on the page, not the height, so the first measurement and
            // Dynamic Type relayouts do not animate; there is no animation with Reduce Motion.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: currentPageIndex)
        }
        .background(AppTheme.Colors.charcoal)
        .navigationTitle("Recommended Gear")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GEAR")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            Text("Recommended Gear")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text("Tools and products for getting more from your E85 experience.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    // A local heading instead of the shared SectionHeader: that one is always uppercased muted
    // caption text (low contrast on the light page background) and carries no header trait.
    private var featuredBrandsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Featured Brands")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Self.pageMargin)

            carousel

            if pages.count > 1 {
                FeaturedPageIndicator(count: pages.count, currentIndex: currentPageIndex)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // iOS 17 scroll APIs only (the production target is 17.6): plain ScrollView + HStack (not
    // Lazy, so every card stays in the VoiceOver tree), view-aligned snapping, and scrollPosition
    // to drive the page indicator. Cards have no fixed height, so they grow with Dynamic Type.
    private var carousel: some View {
        let widthFraction = Self.cardWidthFraction
        let spacing = Self.cardSpacing

        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        featuredCard(for: page, position: index + 1)
                            .containerRelativeFrame(.horizontal) { length, _ in
                                length * widthFraction
                            }
                            // Natural height (never stretched to a taller neighbor), measured so the
                            // carousel can follow the page being shown.
                            .fixedSize(horizontal: false, vertical: true)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: FeaturedPageHeightKey.self,
                                        value: [page.id: proxy.size.height]
                                    )
                                }
                            )
                    }
                }
                .scrollTargetLayout()

                // Trailing runway (outside the snap-target layout). Without it the last card can
                // never reach the leading edge, so scrollPosition keeps reporting the previous
                // card and the page indicator would lag behind what is on screen. The extra 2pt
                // keeps that from depending on exact floating-point equality.
                Color.clear
                    .frame(height: 1)
                    .containerRelativeFrame(.horizontal) { length, _ in
                        length * (1 - widthFraction) + 2
                    }
                    .accessibilityHidden(true)
            }
            // The scroll view clips to this height, so a taller page shows in full once it becomes
            // the current page. (The change is eased by the animation on the page's stack in `body`.)
            .frame(height: carouselHeight, alignment: .top)
        }
        .onPreferenceChange(FeaturedPageHeightKey.self) { pageHeights = $0 }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $selectedPageID)
        .contentMargins(.horizontal, Self.pageMargin, for: .scrollContent)
    }

    @ViewBuilder
    private func featuredCard(for page: FeaturedGearPage, position: Int) -> some View {
        switch page {
        case .brand(let brand):
            FeaturedBrandCard(
                brand: brand,
                position: position,
                total: pages.count,
                statusMessage: linkMessages[brand.id]
            ) {
                openFeaturedBrand(brand)
            }
        case .sponsor(let brand):
            FeaturedSponsorCard(
                brand: brand,
                products: RVPWheelProduct.catalog,
                position: position,
                total: pages.count,
                statusMessage: linkMessages[brand.id],
                openProduct: { product in openRVPProduct(product, sponsor: brand) },
                openCollection: { openFeaturedBrand(brand) }
            )
        }
    }

    // Stacks the icon above the text at accessibility sizes so long words get the full card width
    // instead of breaking mid-word beside the icon.
    private var aboutFeaturedBrandsCard: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))

        return layout {
            Image(systemName: "info.circle")
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(width: 44, height: 44)
                .background(
                    AppTheme.Colors.softGreenBackground,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("About Featured Brands")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("Featured brands open their own websites. Check product compatibility with the manufacturer before installation.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gearCardChrome()
        .accessibilityElement(children: .combine)
    }

    private func openFeaturedBrand(_ brand: FeaturedBrand) {
        linkMessages[brand.id] = nil

        guard let url = FeaturedBrandLink.validatedURL(brand.destinationURL) else {
            showLinkMessage("The \(brand.name) link is unavailable right now.", for: brand)
            return
        }

        openURL(url) { accepted in
            if accepted == false {
                showLinkMessage("Unable to open the \(brand.name) website right now.", for: brand)
            }
        }
    }

    // One opener for all nine wheel tiles: the same https-only validation, openURL, and inline
    // failure message as the brand links, reported on the sponsor card.
    private func openRVPProduct(_ product: RVPWheelProduct, sponsor brand: FeaturedBrand) {
        linkMessages[brand.id] = nil

        guard let url = FeaturedBrandLink.validatedURL(product.productURL) else {
            showLinkMessage("The \(product.displayName) link is unavailable right now.", for: brand)
            return
        }

        openURL(url) { accepted in
            if accepted == false {
                showLinkMessage("Unable to open the \(product.displayName) page right now.", for: brand)
            }
        }
    }

    private func showLinkMessage(_ message: String, for brand: FeaturedBrand) {
        linkMessages[brand.id] = message
        AccessibilityNotification.Announcement(message).post()
    }
}

// MARK: - Carousel cards

/// Tappable brand card: one coherent accessibility control that opens the brand's website in the
/// browser. The wordmark and artwork are separate views so approved brand imagery can replace
/// them later without touching the rest of the card.
private struct FeaturedBrandCard: View {
    let brand: FeaturedBrand
    let position: Int
    let total: Int
    let statusMessage: String?
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 14) {
                    FeaturedBadge(title: "Featured Brand")

                    // Decorative only, and dropped at accessibility text sizes so the copy and
                    // the call to action get the room instead.
                    if dynamicTypeSize.isAccessibilitySize == false {
                        FeaturedBrandArtwork()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FeaturedBrandWordmark(name: brand.name)

                        Text(brand.tagline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(brand.description)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    callToAction
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(brand.name). Featured brand \(position) of \(total). \(brand.accessibilityDescription) \(brand.ctaTitle).")
            .accessibilityHint("Opens the \(brand.name) website in your browser.")
            .accessibilityAddTraits(.isButton)

            // Outside the Button so it is its own VoiceOver element and never part of the tap target.
            if let statusMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.Colors.warningRed)
                        .accessibilityHidden(true)

                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .gearCardChrome()
    }

    // Inverted high-contrast pill built from existing tokens (near-black on light, white on
    // dark/OLED) so it never depends on the accent color for legibility. At accessibility sizes
    // the external-link glyph moves below the text so the label keeps the full pill width.
    private var callToAction: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))

        return layout {
            Text(brand.ctaTitle)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if stacked == false {
                Spacer(minLength: 8)
            }

            Image(systemName: "arrow.up.forward.square")
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(AppTheme.Colors.surfaceElevated)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(
            AppTheme.Colors.textPrimary,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

/// Page-2 sponsor card: RVP Supply's OEM-style beadlock lineup as a 3x3 gallery. Labeled "Sponsor"
/// (RVP Supply is an actual sponsor, so it is the one card here that may say so). Unlike the brand
/// card it is not one big button: each wheel tile opens that wheel's own RVP product page, and
/// "View All RVP Wheels" opens the Wheels collection, all through the same https-only link flow.
/// It is a separate view only so the approved eFlexFuel card stays untouched.
private struct FeaturedSponsorCard: View {
    let brand: FeaturedBrand
    let products: [RVPWheelProduct]
    let position: Int
    let total: Int
    let statusMessage: String?
    let openProduct: (RVPWheelProduct) -> Void
    let openCollection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header

                FeaturedWheelGallery(products: products, action: openProduct)

                FeaturedClaimPill(text: RVPWheelProduct.footnote)

                Button(action: openCollection) {
                    FeaturedCallToAction(title: brand.ctaTitle)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the \(brand.name) wheels website in your browser.")
            }
            .padding(18)

            // Outside the buttons so it is its own VoiceOver element and never part of a tap target.
            if let statusMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.Colors.warningRed)
                        .accessibilityHidden(true)

                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .gearCardChrome()
    }

    // One VoiceOver element that identifies the sponsor and the page, read before the tiles. The
    // brand mark and the accent rule are decorative.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                FeaturedBadge(title: "Sponsor")

                Spacer(minLength: 8)

                FeaturedSponsorLogoPlate(width: 100, height: 60, scale: 0.095)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(brand.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)

                Text(brand.tagline)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(brand.description)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Capsule()
                .fill(AppTheme.Colors.accentGreen)
                .frame(width: 44, height: 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(brand.name). Sponsor. \(brand.accessibilityDescription) Featured card \(position) of \(total). \(brand.description)")
    }
}

/// The wheel tiles, three to a row (two at accessibility text sizes, so product names keep room).
/// Plain stacks rather than a lazy grid: there are only nine, every tile stays in the VoiceOver
/// tree, and the reading order is simply row by row, left to right.
private struct FeaturedWheelGallery: View {
    let products: [RVPWheelProduct]
    let action: (RVPWheelProduct) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columnCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 2 : 3
    }

    private var rows: [[RVPWheelProduct]] {
        let count = columnCount
        return stride(from: 0, to: products.count, by: count).map { start in
            Array(products[start..<min(start + count, products.count)])
        }
    }

    var body: some View {
        let columns = columnCount

        return VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row) { product in
                        FeaturedWheelTile(product: product, action: { action(product) })
                    }

                    // Pads a short last row so every tile keeps the same width.
                    ForEach(0..<(columns - row.count), id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }
}

/// One wheel: the unmodified product photo (square, aspect preserved) and its short name on a
/// small card. The whole tile is the tap target and announces just the product name; the photo
/// is decorative to VoiceOver and never intercepts the tap. Sized like the approved Figma tile:
/// 6pt padding, 12pt photo corners, 16pt tile corners, and a caption two lines tall.
private struct FeaturedWheelTile: View {
    let product: RVPWheelProduct
    let action: () -> Void

    // Two lines of the 11pt caption, scaled with Dynamic Type so a longer name never gets clipped.
    @ScaledMetric(relativeTo: .caption2) private var captionMinHeight: CGFloat = 26

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(product.assetName)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                Text(product.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: captionMinHeight)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                AppTheme.Colors.charcoal,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AppTheme.Colors.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(product.accessibilityName)
        .accessibilityHint("Opens RVP Supply product page.")
        .accessibilityAddTraits(.isButton)
    }
}

// The fact line under the gallery, as a small pill with an accent dot (the approved Figma's
// "Supported Claim"). The text is always conservative copy from the model.
private struct FeaturedClaimPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(AppTheme.Colors.accentGreen)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Text(text)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            AppTheme.Colors.charcoal,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.Colors.border, lineWidth: 1)
        )
    }
}

/// The inverted call-to-action pill, matching the one inside `FeaturedBrandCard` (kept separate
/// so that approved card is untouched). Near-black on light, white on dark/OLED, so it never
/// depends on the accent color; at accessibility sizes the external-link glyph moves below the text.
private struct FeaturedCallToAction: View {
    let title: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))

        return layout {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if stacked == false {
                Spacer(minLength: 8)
            }

            Image(systemName: "arrow.up.forward.square")
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(AppTheme.Colors.surfaceElevated)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(
            AppTheme.Colors.textPrimary,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

// The existing RVPSupplyLogo asset (unmodified) is a 1500x1145px image with its black background
// baked in and a lot of empty padding around the mark. Rather than edit it, it sits on an
// intentional dark plate, cropped to the mark: the mark spans roughly x 359-1204 and y 308-845 px,
// so the window is centered on (781, 572) px, a little right of the image center, which the small
// x offset (31.5px) corrects. `scale` is points per image pixel; the sponsor header's 100x60pt plate
// at 0.095 shows about x 255-1308 and y 257-888 px, which holds the whole mark with margin.
// High-quality interpolation keeps the thin arcs and underline clean at this downscale (about 3.5x
// on 3x screens).
// The image frame needs both dimensions at the same scale (1500 x 1145): with only a width, the
// plate's own height would be proposed to the image and scaledToFit would shrink it to fit that.
private struct FeaturedSponsorLogoPlate: View {
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat

    var body: some View {
        Image("RVPSupplyLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 1500 * scale, height: 1145 * scale)
            .offset(x: -31.5 * scale)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: height * 0.22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: height * 0.22, style: .continuous)
                    .strokeBorder(AppTheme.Colors.border, lineWidth: 1)
            )
    }
}

// Natural height of each carousel page's card, keyed by page id (the same measuring pattern as
// ContentHeightKey in VehicleLimitUpsellView).
private struct FeaturedPageHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Card pieces

private struct FeaturedBadge: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .tracking(1.0)
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppTheme.Colors.charcoal, in: Capsule())
            .overlay(Capsule().strokeBorder(AppTheme.Colors.border, lineWidth: 1))
    }
}

// Typographic treatment only. Swap this body for an approved logo asset once one exists; the
// rest of the card does not depend on it.
private struct FeaturedBrandWordmark: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.system(.title, design: .rounded).weight(.heavy))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            Capsule()
                .fill(AppTheme.Colors.accentGreen)
                .frame(width: 36, height: 4)
                .accessibilityHidden(true)
        }
    }
}

// Native placeholder artwork (fuel, ethanol level, monitoring), all SF Symbols and SwiftUI
// shapes. Swap this body for an approved product image later; it is decorative either way. The
// center dial is layered (face, scale ticks, level arc, droplet) from AppTheme tokens only.
private struct FeaturedBrandArtwork: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.Colors.softGreenBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(AppTheme.Colors.accentGreen.opacity(0.25), lineWidth: 1)
                )

            HStack(spacing: 18) {
                FeaturedArtworkTile(systemImage: "fuelpump.fill", fill: AppTheme.Colors.surfaceElevated)

                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.surfaceElevated)

                    Circle()
                        .strokeBorder(AppTheme.Colors.border, lineWidth: 1)

                    // One shared 270-degree sweep, rotated so the opening faces down: scale ticks
                    // (a dashed arc), the track, and the level arc.
                    ZStack {
                        Circle()
                            .trim(from: 0, to: 0.75)
                            .stroke(
                                AppTheme.Colors.textMuted.opacity(0.55),
                                style: StrokeStyle(lineWidth: 5, dash: [1.5, 7.85])
                            )
                            .padding(8)

                        Circle()
                            .trim(from: 0, to: 0.75)
                            .stroke(
                                AppTheme.Colors.textMuted.opacity(0.35),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .padding(18)

                        Circle()
                            .trim(from: 0, to: 0.52)
                            .stroke(
                                AppTheme.Colors.accentGreen,
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .padding(18)
                    }
                    .rotationEffect(.degrees(135))

                    Image(systemName: "drop.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                .frame(width: 96, height: 96)

                FeaturedArtworkTile(systemImage: "waveform.path.ecg", fill: AppTheme.Colors.surfaceElevated)
            }
        }
        .frame(height: 120)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

private struct FeaturedArtworkTile: View {
    let systemImage: String
    let fill: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(AppTheme.Colors.textPrimary)
            .frame(width: 44, height: 44)
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppTheme.Colors.border, lineWidth: 1)
            )
    }
}

// Decorative and hidden from VoiceOver: each card already announces "N of M". The current page
// is the wider, darker capsule, so it reads without relying on color alone. Inactive capsules use
// textSecondary at 85% so they stay above 3:1 against the light page background.
private struct FeaturedPageIndicator: View {
    let count: Int
    let currentIndex: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == currentIndex ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary.opacity(0.85))
                    .frame(width: index == currentIndex ? 22 : 8, height: 8)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: currentIndex)
        .accessibilityHidden(true)
    }
}

private extension View {
    // Same 22pt continuous surface + hairline border the rest of the app's cards use. The border
    // is inset (strokeBorder) so it is not half-clipped.
    func gearCardChrome() -> some View {
        self
            .background(AppTheme.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(AppTheme.Colors.border, lineWidth: 1)
            )
    }
}

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        RecommendedGearView()
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack {
        RecommendedGearView()
    }
    .preferredColorScheme(.dark)
}

#Preview("Dark, Accessibility 5") {
    NavigationStack {
        RecommendedGearView()
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}

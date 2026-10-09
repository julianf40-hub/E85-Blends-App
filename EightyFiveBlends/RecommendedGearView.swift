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
    // VoiceOver strings are built here, not inline in the views, so FeaturedGearTests holds them to
    // the same relationship and claim guards as the visible copy.

    /// The neutral "Featured Brand" carousel card, with its position in the carousel.
    func brandCardAccessibilityLabel(position: Int, total: Int) -> String {
        "\(name). Featured brand \(position) of \(total). \(accessibilityDescription) \(ctaTitle)."
    }

    /// The sponsor card's header, read before its wheel tiles.
    func sponsorHeaderAccessibilityLabel(position: Int, total: Int) -> String {
        "\(name). Sponsor. \(accessibilityDescription) Featured card \(position) of \(total). \(description)"
    }

    /// The compact More-screen card that opens Recommended Gear.
    var compactCardAccessibilityLabel: String { "\(name). Featured brand. \(tagline)." }
    var compactCardAccessibilityHint: String { "Opens Recommended Gear with \(name) featured." }
}

extension FeaturedBrand {
    static let eFlexFuel = FeaturedBrand(
        id: "eflexfuel",
        name: "eFlexFuel",
        tagline: "Flex-fuel conversion & ethanol monitoring",
        description: "Flex-fuel conversion kits and real-time ethanol content monitoring through the eFlexApp.",
        ctaTitle: "View eFlexFuel Products",
        destinationURL: URL(string: "https://eflexfuel.com/us/auto-products"),
        accessibilityDescription: "Flex-fuel conversion kits and real-time ethanol content monitoring through the eFlexApp."
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
            displayName: "OEM Hellcat Style",
            assetName: "RVPWheelOEMHellcat",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-8"),
            accessibilityName: "OEM Hellcat Style beadlock wheel"
        ),
        RVPWheelProduct(
            id: "oem-hellcat-v2",
            displayName: "OEM Hellcat Style V2",
            assetName: "RVPWheelOEMHellcatV2",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-4"),
            accessibilityName: "OEM Hellcat Style V2 beadlock wheel"
        ),
        RVPWheelProduct(
            id: "oem-hellcat-redeye",
            displayName: "OEM Hellcat Redeye Style",
            assetName: "RVPWheelOEMHellcatRedeye",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-9"),
            accessibilityName: "OEM Hellcat Redeye Style beadlock wheel"
        ),
        RVPWheelProduct(
            id: "5-spoke-hellcat",
            displayName: "5 Spoke Hellcat Style",
            assetName: "RVPWheel5SpokeHellcat",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-3"),
            accessibilityName: "5 Spoke Hellcat Style beadlock wheel"
        ),
        RVPWheelProduct(
            id: "5-spoke-hellcat-v2",
            displayName: "5 Spoke Hellcat Style V2",
            assetName: "RVPWheel5SpokeHellcatV2",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-1"),
            accessibilityName: "5 Spoke Hellcat Style V2 beadlock wheel"
        ),
        RVPWheelProduct(
            id: "oem-demon",
            displayName: "OEM Demon Style",
            assetName: "RVPWheelOEMDemon",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-7"),
            accessibilityName: "OEM Demon Style beadlock wheel"
        ),
        RVPWheelProduct(
            id: "hollow-5-spoke",
            displayName: "Hollow 5 Spoke Style",
            assetName: "RVPWheelHollow5Spoke",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-5"),
            accessibilityName: "Hollow 5 Spoke Style beadlock wheel"
        ),
        RVPWheelProduct(
            id: "chrome-oem-hellcat",
            displayName: "Chrome OEM Hellcat Style",
            assetName: "RVPWheelChromeOEMHellcat",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-2"),
            accessibilityName: "Chrome OEM Hellcat Style beadlock wheel"
        ),
        RVPWheelProduct(
            id: "oem-widebody",
            displayName: "OEM Widebody Style",
            assetName: "RVPWheelOEMWidebody",
            productURL: URL(string: "https://rvpsupply.com/products/oem-beadlock-style-6"),
            accessibilityName: "OEM Widebody Style beadlock wheel"
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

    /// The badge text each case carries, in one place so FeaturedGearTests can hold the neutral brand
    /// to never saying "Sponsor".
    static let brandBadgeTitle = "Featured Brand"
    static let sponsorBadgeTitle = "Sponsor"

    /// Live-demo catalog: exactly two pages, eFlexFuel (neutral Featured Brand) then RVP Supply
    /// (sponsor). The eFlexFuel page, like MoreView's featured-brand card, is pending an approved
    /// relationship and wording; dropping `.brand(.eFlexFuel)` here and removing that card is the
    /// whole demo. Everything else on this screen is the RVP sponsor.
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

/// How the RVP wheel gallery lays out its tiles: three to a row, two at accessibility text sizes so
/// product names keep room. Pure, so the layout (and the padding of a short last row) is testable.
nonisolated enum FeaturedGalleryLayout {
    static func columnCount(isAccessibilitySize: Bool) -> Int {
        isAccessibilitySize ? 2 : 3
    }

    /// Row-by-row, left-to-right chunks of `columns` items; only the last row can be short.
    static func rows<Item>(_ items: [Item], columns: Int) -> [[Item]] {
        let width = max(1, columns)
        return stride(from: 0, to: items.count, by: width).map { start in
            Array(items[start..<min(start + width, items.count)])
        }
    }

    /// Empty cells a row needs so every tile keeps the same width.
    static func padding(forRowOf count: Int, columns: Int) -> Int {
        max(0, columns - count)
    }
}

/// Sizing rules for the RVP Supply logo, which sits on a dark plate in two places: the More screen
/// sponsor banner and the Recommended Gear sponsor card (`FeaturedSponsorLogoPlate`). Only widths are
/// chosen here; a plate's height always follows the artwork's own aspect ratio, so none of this
/// depends on the logo's pixel dimensions. Pure, so it is testable without SwiftUI.
nonisolated enum RVPSupplyLogoLayout {
    static let assetName = "RVPSupplyLogo"

    /// Space between the plate's edge and the artwork, and the plate's corner radius.
    static let horizontalInset: CGFloat = 8
    static let verticalInset: CGFloat = 6
    static let cornerRadius: CGFloat = 14

    /// The More banner's plate is this share of the container's width, kept within `bannerWidthRange`,
    /// so it grows from the smallest iPhone to the largest and stops growing on iPad.
    static let bannerWidthFraction: CGFloat = 0.31
    static let bannerWidthRange: ClosedRange<CGFloat> = 108...132

    static func bannerPlateWidth(containerWidth: CGFloat) -> CGFloat {
        guard containerWidth.isFinite, containerWidth > 0 else { return bannerWidthRange.lowerBound }
        return min(max(containerWidth * bannerWidthFraction, bannerWidthRange.lowerBound), bannerWidthRange.upperBound)
    }

    /// The sponsor card header tries these beside the "Sponsor" badge, widest first, and uses the first
    /// that fits. If none does (the badge grows with Dynamic Type), the plate goes under the badge.
    static let cardWideWidth: CGFloat = 128
    static let cardMediumWidth: CGFloat = 116
    static let cardNarrowWidth: CGFloat = 104
    static let cardStackedWidth: CGFloat = 128
}

/// How tall the Featured Brands carousel is while it is swiped. Its pages have very different natural
/// heights (the eFlexFuel card is far shorter than the RVP gallery card), so the carousel follows the
/// swipe instead of stepping to the snapped page. Pure, so the whole rule is testable without SwiftUI.
///
/// "Progress" is the carousel's continuous page position: 0 with the first page settled, 1 with the
/// second settled, and the fractions in between while swiping. It comes from the pages' measured
/// leading edges, because the scroll view's snapped-page id (`scrollPosition`) only changes once the
/// next card has almost reached the edge, which is far too late to size from.
nonisolated enum FeaturedCarouselMetrics {
    /// How the height leaves the taller page's height. 1 is linear. 2 keeps the carousel close to the
    /// taller page's height while most of that page is still on screen, so less of its bottom is cut
    /// mid-swipe, and still reaches the shorter page's exact height when it settles.
    static let easeExponent: CGFloat = 2

    /// How close to a page (as a fraction of the distance between two pages) still counts as that
    /// page being settled. It absorbs the last few points of a snap and a settled page sitting a margin
    /// off where it is expected (16pt is within it once the pages are about 320pt apart or more), so a
    /// settled carousel is exactly the page's own height. The ramp between two pages is stretched over
    /// the rest of the swipe, so there is no jump at the edge of this zone.
    static let settleTolerance: CGFloat = 0.05

    /// The measured progress must have passed this to count as having moved.
    static let movementThreshold: CGFloat = 0.001

    /// Continuous page position from the pages' left edges (`nil` = not measured yet), measured in
    /// the scroll view's own coordinate space. (A right-to-left layout puts the pages in the other
    /// order, which reads as no usable spacing, so it falls back to the snapped page.) `restingMinX` is where the settled page's leading edge
    /// sits (the scroll content margin). The spacing between pages is read from the first two edges
    /// rather than assumed. `nil` when it can't be worked out, and clamped to the real pages otherwise
    /// so rubber-banding past either end can't ask for a height that doesn't exist.
    static func progress(pageMinX: [CGFloat?], restingMinX: CGFloat) -> CGFloat? {
        guard pageMinX.isEmpty == false, let first = pageMinX[0], first.isFinite, restingMinX.isFinite else {
            return nil
        }
        guard pageMinX.count > 1 else { return 0 }
        guard let second = pageMinX[1], second.isFinite else { return nil }

        let pageSpacing = second - first
        guard pageSpacing > 1 else { return nil }
        return min(max((restingMinX - first) / pageSpacing, 0), CGFloat(pageMinX.count - 1))
    }

    /// The carousel's height at `progress`, between the two pages being swiped. Exactly a page's own
    /// height whenever that page is settled. `nil` if a page it needs isn't usable yet (not measured,
    /// zero, negative or not finite), so the caller can fall back to the natural height rather than
    /// collapse the carousel.
    static func height(pageHeights: [CGFloat?], progress: CGFloat) -> CGFloat? {
        guard pageHeights.isEmpty == false, progress.isFinite else { return nil }

        let position = min(max(progress, 0), CGFloat(pageHeights.count - 1))
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = min(lowerIndex + 1, pageHeights.count - 1)
        let fraction = position - CGFloat(lowerIndex)
        // A settled page needs only its own height, not its neighbour's.
        if lowerIndex == upperIndex || fraction <= settleTolerance { return usable(pageHeights[lowerIndex]) }
        if fraction >= 1 - settleTolerance { return usable(pageHeights[upperIndex]) }
        guard let lower = usable(pageHeights[lowerIndex]), let upper = usable(pageHeights[upperIndex]) else {
            return nil
        }

        // Eased by distance from the TALLER page, so both swipe directions behave the same, the
        // carousel never gets shorter than the shorter page (it is never cut), and the slope stays
        // bounded (no sudden jump) at either end.
        let transit = (fraction - settleTolerance) / (1 - 2 * settleTolerance)
        let taller = max(lower, upper)
        let shorter = min(lower, upper)
        let distanceFromTaller = lower >= upper ? transit : 1 - transit
        let eased = CGFloat(pow(Double(distanceFromTaller), Double(easeExponent)))
        return taller - (taller - shorter) * eased
    }

    /// What the screen uses. With VoiceOver on, focus can move to the next page before the carousel
    /// has scrolled far enough to have grown, which would leave the focused element under the clip, so
    /// it is sized to its natural (tallest) height instead. With no usable progress it follows the
    /// snapped page, as the carousel did before progress was measured.
    static func carouselHeight(
        pageHeights: [CGFloat?],
        progress: CGFloat?,
        selectedIndex: Int,
        voiceOverEnabled: Bool
    ) -> CGFloat? {
        guard voiceOverEnabled == false else { return nil }
        return height(pageHeights: pageHeights, progress: progress ?? CGFloat(selectedIndex))
    }

    /// Checked when the snapped page changes. The carousel only changes page by scrolling, so a
    /// measured progress that has never left the first page means the measurement is not following the
    /// scroll (for example its coordinate space moves with the content), and the screen then stops
    /// using it and follows the snapped page. Deliberately about "ever moved", not "how far": the
    /// snapped page can change early in a quick flick, so how far along the swipe is varies.
    static func hasFollowedScroll(furthestProgress: CGFloat) -> Bool {
        furthestProgress > movementThreshold
    }

    private static func usable(_ height: CGFloat?) -> CGFloat? {
        guard let height, height.isFinite, height > 0 else { return nil }
        return height
    }
}

// MARK: - Screen

struct RecommendedGearView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var selectedPageID: String?
    @State private var linkMessages: [String: String] = [:]
    // Each page's natural height, in page order (nil until measured), and how far the carousel has
    // scrolled between pages (0 = first page settled, 1 = second). See FeaturedCarouselMetrics.
    @State private var pageHeights: [CGFloat?] = []
    @State private var scrollProgress: CGFloat?
    // The furthest progress seen so far, and whether to keep using it: if the snapped page changes
    // while the progress has never moved, the carousel goes back to following the snapped page rather
    // than trust a measurement that is not following the scroll.
    @State private var furthestScrollProgress: CGFloat = 0
    @State private var scrollProgressIsTrusted = true

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
    private static let carouselSpace = "featuredCarousel"

    private var currentPageIndex: Int {
        pages.firstIndex(where: { $0.id == selectedPageID }) ?? 0
    }

    // The RVP gallery card is much taller than the eFlexFuel card, and stretching the shorter page to
    // match (or leaving a gap under it) would look broken, so each page keeps its natural height and
    // the carousel's height follows the SWIPE: exactly a page's own height when it is settled, and
    // eased between the two pages as the scroll view moves. (It used to follow the snapped page,
    // whose id only changes once the next card has nearly reached the edge, so a taller card was
    // clipped for most of the swipe and the height then jumped.) It is nil until the first
    // measurement, when the carousel just sizes to its tallest page, and with VoiceOver on. Without a
    // usable swipe measurement it follows the snapped page, as before. All of the arithmetic is in
    // FeaturedCarouselMetrics.
    private var carouselFollowsSwipe: Bool {
        scrollProgressIsTrusted && scrollProgress != nil
    }

    private var carouselHeight: CGFloat? {
        FeaturedCarouselMetrics.carouselHeight(
            pageHeights: pageHeights,
            progress: scrollProgressIsTrusted ? scrollProgress : nil,
            selectedIndex: currentPageIndex,
            voiceOverEnabled: voiceOverEnabled
        )
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
            // While the carousel follows the swipe, its height is driven by the scroll position and must not
            // be animated on top (Reduce Motion then has nothing to turn off). Only when there is no usable
            // swipe measurement does it step to the snapped page, and that step is eased as it used to be
            // (never with Reduce Motion). Keyed on the page, not the height, so the first measurement and
            // Dynamic Type relayouts do not animate.
            .animation(reduceMotion || carouselFollowsSwipe ? nil : .easeInOut(duration: 0.25), value: currentPageIndex)
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
    // to drive the page indicator. Cards have no fixed height, so they grow with Dynamic Type. Each
    // card reports its height and its leading edge in the scroll view's own coordinate space; the
    // edges are how far the carousel has scrolled, which sizes its height (see `carouselHeight`).
    private var carousel: some View {
        let widthFraction = Self.cardWidthFraction
        let spacing = Self.cardSpacing
        let space = Self.carouselSpace
        let pageIDs = pages.map(\.id)
        let restingMinX = Self.pageMargin

        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        featuredCard(for: page, position: index + 1)
                            .containerRelativeFrame(.horizontal) { length, _ in
                                length * widthFraction
                            }
                            // Natural height (never stretched to a taller neighbor), measured with the
                            // card's leading edge so the carousel can follow the swipe. Neither depends
                            // on the carousel's own height, so sizing it from them cannot feed back.
                            .fixedSize(horizontal: false, vertical: true)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: FeaturedPageMetricsKey.self,
                                        value: [page.id: FeaturedPageMetric(
                                            height: proxy.size.height,
                                            minX: proxy.frame(in: .named(space)).minX
                                        )]
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
            // The scroll view clips to this height, which follows the swipe (see `carouselHeight`), so the
            // page dots and About card below stay attached to the carousel instead of jumping.
            .frame(height: carouselHeight, alignment: .top)
        }
        .coordinateSpace(.named(space))
        .onPreferenceChange(FeaturedPageMetricsKey.self) { metrics in
            let heights = pageIDs.map { metrics[$0]?.height }
            if pageHeights != heights { pageHeights = heights }

            let progress = FeaturedCarouselMetrics.progress(
                pageMinX: pageIDs.map { metrics[$0]?.minX },
                restingMinX: restingMinX
            )
            if scrollProgress != progress { scrollProgress = progress }
            if let progress, progress > furthestScrollProgress { furthestScrollProgress = progress }
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $selectedPageID)
        .onChange(of: selectedPageID) { old, new in verifyScrollProgress(from: old, to: new) }
        .contentMargins(.horizontal, Self.pageMargin, for: .scrollContent)
    }

    // Runs when the snapped page changes. (nil is the first page, so the id first being filled in at
    // launch is not a page change.)
    private func verifyScrollProgress(from old: String?, to new: String?) {
        let oldIndex = pages.firstIndex(where: { $0.id == old }) ?? 0
        let newIndex = pages.firstIndex(where: { $0.id == new }) ?? 0
        // VoiceOver can move the carousel without a drag (and already uses the natural height).
        guard oldIndex != newIndex, scrollProgressIsTrusted, voiceOverEnabled == false else { return }
        if FeaturedCarouselMetrics.hasFollowedScroll(furthestProgress: furthestScrollProgress) == false {
            scrollProgressIsTrusted = false
        }
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
                    FeaturedBadge(title: FeaturedGearPage.brandBadgeTitle)

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

                    FeaturedCallToAction(title: brand.ctaTitle)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(brand.brandCardAccessibilityLabel(position: position, total: total))
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

    private func badgeAndLogo(plateWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 8) {
            FeaturedBadge(title: FeaturedGearPage.sponsorBadgeTitle)

            Spacer(minLength: 8)

            FeaturedSponsorLogoPlate()
                .frame(width: plateWidth)
        }
    }

    // One VoiceOver element that identifies the sponsor and the page, read before the tiles. The
    // brand mark and the accent rule are decorative.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                badgeAndLogo(plateWidth: RVPSupplyLogoLayout.cardWideWidth)
                badgeAndLogo(plateWidth: RVPSupplyLogoLayout.cardMediumWidth)
                badgeAndLogo(plateWidth: RVPSupplyLogoLayout.cardNarrowWidth)

                // Safety net for large accessibility text on a narrow card: when the badge is too wide
                // to share a row even with the narrowest plate, the logo goes under it.
                VStack(alignment: .leading, spacing: 8) {
                    FeaturedBadge(title: FeaturedGearPage.sponsorBadgeTitle)

                    FeaturedSponsorLogoPlate()
                        .frame(width: RVPSupplyLogoLayout.cardStackedWidth)
                }
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
        .accessibilityLabel(brand.sponsorHeaderAccessibilityLabel(position: position, total: total))
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
        FeaturedGalleryLayout.columnCount(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    private var rows: [[RVPWheelProduct]] {
        FeaturedGalleryLayout.rows(products, columns: columnCount)
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
                    ForEach(0..<FeaturedGalleryLayout.padding(forRowOf: row.count, columns: columns), id: \.self) { _ in
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
                    .interpolation(.high)
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

/// The inverted call-to-action pill shared by both cards. Near-black on light, white on dark/OLED,
/// so it never depends on the accent color; at accessibility sizes the external-link glyph moves
/// below the text.
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

// The RVPSupplyLogo asset is a transparent PNG with white lettering, so it needs a backing plate of
// its own: the cards it sits on are white in light mode and near-black in dark and OLED. The plate
// is a fixed dark color rather than a theme color, so the lettering reads the same in every
// appearance, and the hairline border separates it from the card. The artwork is aspect-fit inside a
// small inset: no pixel coordinates, offsets, or scale factors, so it never crops and a replacement
// asset of other dimensions still lays out. The caller sets only the plate's width (`.frame(width:)`);
// the height follows the artwork's aspect ratio. High-quality interpolation keeps the thin arcs and
// underline clean when the large image is scaled down. The logo is decorative: every place that shows
// it also says "RVP Supply" in text, so it is hidden from VoiceOver rather than read as "RVPSupplyLogo".
struct FeaturedSponsorLogoPlate: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RVPSupplyLogoLayout.cornerRadius, style: .continuous)

        Image(RVPSupplyLogoLayout.assetName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .padding(.horizontal, RVPSupplyLogoLayout.horizontalInset)
            .padding(.vertical, RVPSupplyLogoLayout.verticalInset)
            .background(Color(red: 0.04, green: 0.04, blue: 0.045), in: shape)
            .overlay(shape.strokeBorder(AppTheme.Colors.border, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

// A carousel page card's natural height and its leading edge in the carousel scroll view's coordinate
// space (so it changes as the carousel scrolls), keyed by page id (the same measuring pattern as
// ContentHeightKey in VehicleLimitUpsellView).
private nonisolated struct FeaturedPageMetric: Equatable, Sendable {
    var height: CGFloat
    var minX: CGFloat
}

private struct FeaturedPageMetricsKey: PreferenceKey {
    static let defaultValue: [String: FeaturedPageMetric] = [:]
    static func reduce(value: inout [String: FeaturedPageMetric], nextValue: () -> [String: FeaturedPageMetric]) {
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

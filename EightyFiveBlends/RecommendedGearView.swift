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
    /// RVP Supply's OEM+ beadlock wheels, shown as a labeled sponsor. The destination is the Wheels
    /// collection (not a single product) so the card showcases the category without locking in one
    /// fitment, and the copy is RVP's own product wording, conservative on purpose: no price, no
    /// performance claim, and no claim of universal fitment.
    static let rvpSupplyWheels = FeaturedBrand(
        id: "rvp-supply-oem-beadlocks",
        name: "RVP Supply",
        tagline: "OEM+ Beadlock Wheels",
        description: "Rotary-forged beadlock wheels with OEM+ styling, lightweight construction, and fitment options for supported vehicles.",
        ctaTitle: "View OEM+ Beadlocks",
        destinationURL: URL(string: "https://rvpsupply.com/collections/wheels-1"),
        accessibilityDescription: "OEM plus beadlock wheels."
    )
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

    @State private var selectedPageID: String?
    @State private var linkMessages: [String: String] = [:]

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
        }
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
                position: position,
                total: pages.count,
                statusMessage: linkMessages[brand.id]
            ) {
                openFeaturedBrand(brand)
            }
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

/// Page-2 sponsor card. Same structure as `FeaturedBrandCard` (one whole-card button, with the
/// inline failure message outside it, stretched to the carousel's height) but labeled "Sponsor":
/// RVP Supply is an actual sponsor, so it is the one card here that may say so. It shares the
/// brand card's link flow, and is a separate view only so the approved eFlexFuel card stays
/// untouched.
private struct FeaturedSponsorCard: View {
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
                    FeaturedBadge(title: "Sponsor")

                    // Decorative only, and dropped at accessibility text sizes like the brand card's.
                    if dynamicTypeSize.isAccessibilitySize == false {
                        FeaturedSponsorArtwork()
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
            .accessibilityLabel("\(brand.name). Sponsor. \(brand.accessibilityDescription) Featured card \(position) of \(total). \(brand.description) \(brand.ctaTitle).")
            .accessibilityHint("Opens the \(brand.name) wheels website in your browser.")
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

// Sponsor artwork: a quick glance at several OEM-style beadlock wheel designs (one lead wheel and
// three companions), with a restrained RVP mark and a one-line caption underneath. Same 120pt
// panel as the brand card's artwork, so the two pages stay the same height. Decorative: the
// card's own label already says what it is, so the whole panel is hidden from VoiceOver.
private struct FeaturedSponsorArtwork: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.Colors.charcoal)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(AppTheme.Colors.stationYellow.opacity(0.35), lineWidth: 1)
                )

            // 72pt lineup + 6pt gap + 28pt footer = 106pt, centered in the 120pt panel.
            VStack(spacing: 6) {
                FeaturedWheelLineup()

                HStack(spacing: 8) {
                    FeaturedSponsorLogoPlate(width: 44, height: 28, scale: 0.044)

                    Text("Multiple OEM-style beadlock designs")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(height: 28)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 120)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

// Four different spoke patterns so the row reads as a lineup of styles, not one wheel repeated.
private enum FeaturedWheelStyle {
    case fiveSpoke
    case splitSixSpoke
    case mesh
    case hollowFiveSpoke
}

// A lead wheel with three smaller companions, 246pt wide in total (72 + 3 x 52 + 3 x 6), which
// fits any card down to a 375pt-wide phone (283pt of card inner width) with room to spare. On a
// 320pt-wide screen (a Zoomed display) the panel has only about 208pt, so there it falls back to a
// lead plus two companions (188pt) instead of overflowing the card.
private struct FeaturedWheelLineup: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                FeaturedWheelThumbnail(style: .fiveSpoke, diameter: 72)
                FeaturedWheelThumbnail(style: .splitSixSpoke, diameter: 52)
                FeaturedWheelThumbnail(style: .mesh, diameter: 52)
                FeaturedWheelThumbnail(style: .hollowFiveSpoke, diameter: 52)
            }

            HStack(spacing: 6) {
                FeaturedWheelThumbnail(style: .fiveSpoke, diameter: 72)
                FeaturedWheelThumbnail(style: .splitSixSpoke, diameter: 52)
                FeaturedWheelThumbnail(style: .mesh, diameter: 52)
            }
        }
        .frame(height: 72)
    }
}

// Wheel finishes. A wheel is a physical object, so these stay the same in every appearance:
// graphite with a light edge highlight, which reads on the light panel and on the dark ones
// instead of following the theme.
private enum WheelFinish {
    static let tire = Color(white: 0.08)
    static let face = Color(white: 0.14)
    static let spoke = Color(white: 0.34)
    static let highlight = Color(white: 0.58)
}

// One beadlock-style wheel from shapes only. Every proportion is a fraction of the diameter, so the
// same view draws the lead wheel and the companions: tire, a rim ring, a ring of 24 bolts, a dark
// face with the style's spokes, and a hub with a small yellow cap (the yellow the app already uses
// for the sponsor card in More).
private struct FeaturedWheelThumbnail: View {
    let style: FeaturedWheelStyle
    let diameter: CGFloat

    var body: some View {
        let d = diameter
        // The bolts sit on a circle 0.70d across. A dashed stroke with round caps draws a dot at
        // each dash, so a pitch of circumference / 24 gives exactly 24 evenly spaced bolts.
        let boltPitch = CGFloat.pi * 0.70 * d / 24

        return ZStack {
            Circle()
                .fill(WheelFinish.tire)

            Circle()
                .strokeBorder(WheelFinish.highlight.opacity(0.45), lineWidth: 1)

            Circle()
                .stroke(WheelFinish.highlight, lineWidth: d * 0.03)
                .frame(width: d * 0.80, height: d * 0.80)

            Circle()
                .stroke(
                    WheelFinish.highlight,
                    style: StrokeStyle(lineWidth: d * 0.04, lineCap: .round, dash: [0.1, boltPitch - 0.1])
                )
                .frame(width: d * 0.70, height: d * 0.70)

            Circle()
                .fill(WheelFinish.face)
                .frame(width: d * 0.62, height: d * 0.62)

            spokes(d)

            Circle()
                .fill(WheelFinish.spoke)
                .frame(width: d * 0.17, height: d * 0.17)

            Circle()
                .fill(AppTheme.Colors.stationYellow)
                .frame(width: d * 0.06, height: d * 0.06)
        }
        .frame(width: d, height: d)
    }

    // Spokes run from just outside the hub to the bolt ring (0.05d to 0.325d from the center). Each
    // is offset up from the center and then rotated about it.
    @ViewBuilder
    private func spokes(_ d: CGFloat) -> some View {
        let length = d * 0.275
        let center = d * 0.1875

        switch style {
        case .fiveSpoke:
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: d * 0.04, style: .continuous)
                    .fill(WheelFinish.spoke)
                    .frame(width: d * 0.15, height: length)
                    .offset(y: -center)
                    .rotationEffect(.degrees(Double(index) * 72))
            }
        case .splitSixSpoke:
            // Six spokes, each split into a pair of thin bars.
            ForEach(0..<12, id: \.self) { index in
                let side: CGFloat = index % 2 == 0 ? -1 : 1
                RoundedRectangle(cornerRadius: d * 0.02, style: .continuous)
                    .fill(WheelFinish.spoke)
                    .frame(width: d * 0.05, height: length)
                    .offset(x: side * d * 0.04, y: -center)
                    .rotationEffect(.degrees(Double(index / 2) * 60))
            }
        case .mesh:
            ForEach(0..<15, id: \.self) { index in
                RoundedRectangle(cornerRadius: d * 0.015, style: .continuous)
                    .fill(WheelFinish.spoke)
                    .frame(width: d * 0.03, height: length)
                    .offset(y: -center)
                    .rotationEffect(.degrees(Double(index) * 24))
            }
        case .hollowFiveSpoke:
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: d * 0.04, style: .continuous)
                    .strokeBorder(WheelFinish.spoke, lineWidth: max(1, d * 0.025))
                    .frame(width: d * 0.15, height: length)
                    .offset(y: -center)
                    .rotationEffect(.degrees(Double(index) * 72))
            }
        }
    }
}

// The existing RVPSupplyLogo asset (unmodified) is a 1500x1145px image with its black background
// baked in and a lot of empty padding around the mark. Rather than edit it, it sits on an
// intentional dark plate, cropped to the mark: the mark spans roughly x 359-1204 and y 308-845 px,
// so the window is centered on (781, 572) px, a little right of the image center, which the small
// x offset (31.5px) corrects. `scale` is points per image pixel; at 0.044 a 44x28pt plate shows
// about x 281-1281 and y 254-890 px, which holds the whole mark with margin.
// The image frame needs both dimensions at the same scale (1500 x 1145): with only a width, the
// plate's own height would be proposed to the image and scaledToFit would shrink it to fit that.
private struct FeaturedSponsorLogoPlate: View {
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat

    var body: some View {
        Image("RVPSupplyLogo")
            .resizable()
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

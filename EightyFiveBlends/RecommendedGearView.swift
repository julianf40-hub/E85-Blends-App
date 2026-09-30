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
// label only: nothing here states or implies a sponsorship, partnership, affiliate relationship,
// endorsement, discount, or offer. Keep it that way until a relationship is confirmed and approved
// wording exists. The More screen's own sponsor placement stays in More and deliberately never
// appears in this carousel.
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

/// A non-brand, non-linking carousel page. Not a partner and never implies one.
struct FeaturedPlaceholder: Identifiable {
    let id: String
    let title: String
    let message: String
}

/// One page of the Featured Brands carousel.
enum FeaturedGearPage: Identifiable {
    case brand(FeaturedBrand)
    case comingSoon(FeaturedPlaceholder)

    var id: String {
        switch self {
        case .brand(let brand):
            return brand.id
        case .comingSoon(let placeholder):
            return placeholder.id
        }
    }

    /// Live-demo catalog: eFlexFuel, then a neutral placeholder that shows the carousel swiping
    /// without inventing another brand.
    static let catalog: [FeaturedGearPage] = [
        .brand(.eFlexFuel),
        .comingSoon(
            FeaturedPlaceholder(
                id: "more-featured-gear",
                title: "More Featured Gear",
                message: "We're building a curated collection of E85 tools, monitoring gear, and accessories."
            )
        )
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
    // edge, which is what tells people the row swipes. The card spacing is at least the page
    // margin so, once a later card is aligned to the margin, the previous one is fully off screen
    // instead of leaving a sliver at the screen edge.
    private static let cardWidthFraction: CGFloat = 0.88
    private static let cardSpacing: CGFloat = 16
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
        case .comingSoon(let placeholder):
            FeaturedPlaceholderCard(
                placeholder: placeholder,
                position: position,
                total: pages.count
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

                Text("Featured brands open their own websites. Compatibility varies by vehicle, so check with the brand before installing.")
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

/// Non-linking page that keeps the carousel honest about what is not here yet.
private struct FeaturedPlaceholderCard: View {
    let placeholder: FeaturedPlaceholder
    let position: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FeaturedBadge(title: "Coming Soon")

            HStack(spacing: 10) {
                FeaturedArtworkTile(systemImage: "fuelpump.fill", fill: AppTheme.Colors.charcoal)
                FeaturedArtworkTile(systemImage: "waveform.path.ecg", fill: AppTheme.Colors.charcoal)
                FeaturedArtworkTile(systemImage: "wrench.and.screwdriver", fill: AppTheme.Colors.charcoal)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(placeholder.title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(placeholder.message)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .gearCardChrome(dashed: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(placeholder.title) coming soon. Featured card \(position) of \(total). \(placeholder.message)")
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
// shapes. Swap this body for an approved product image later; it is decorative either way.
private struct FeaturedBrandArtwork: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.Colors.softGreenBackground)

            HStack(spacing: 18) {
                FeaturedArtworkTile(systemImage: "fuelpump.fill", fill: AppTheme.Colors.surfaceElevated)

                ZStack {
                    ZStack {
                        Circle()
                            .trim(from: 0, to: 0.75)
                            .stroke(
                                AppTheme.Colors.textMuted.opacity(0.35),
                                style: StrokeStyle(lineWidth: 9, lineCap: .round)
                            )

                        Circle()
                            .trim(from: 0, to: 0.52)
                            .stroke(
                                AppTheme.Colors.accentGreen,
                                style: StrokeStyle(lineWidth: 9, lineCap: .round)
                            )
                    }
                    .padding(5)
                    .rotationEffect(.degrees(135))

                    Image(systemName: "drop.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                .frame(width: 84, height: 84)

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
    // is inset (strokeBorder) so it is not half-clipped. The placeholder page is dashed and uses a
    // stronger stroke, because the standard hairline is nearly invisible once dashed.
    func gearCardChrome(dashed: Bool = false) -> some View {
        self
            .background(AppTheme.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        dashed ? AppTheme.Colors.textMuted.opacity(0.7) : AppTheme.Colors.border,
                        style: StrokeStyle(lineWidth: 1, dash: dashed ? [6, 4] : [])
                    )
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

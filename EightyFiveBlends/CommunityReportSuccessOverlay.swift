//
//  CommunityReportSuccessOverlay.swift
//  EightyFiveBlends
//
//  A polished, native-feeling celebration shown after a Community E85 Price Report has been
//  confirmed to have succeeded remotely — see StationsView.presentCommunityReportSuccess(), the
//  one and only call site that presents this view. Presentation-only: this file has no knowledge
//  of, and no effect on, CommunityPriceService, Supabase, or local persistence — by the time it
//  is shown, the report has already succeeded and every other side effect has already happened.
//
//  Respects Reduce Motion throughout (no confetti, no scale/spring — a simple fade only) and is
//  fully Dynamic Type / VoiceOver aware. See CommunityReportSuccessOverlayTests.swift for the
//  presentation-state contract this pairs with in StationsView.
//
//  Confetti rendering fix: the burst originally sat BELOW `card` in the ZStack, and every piece
//  started at dead center with only 60-150pt of travel — well inside the opaque card's own
//  footprint — so it was fully occluded behind the card for its entire (fading) lifetime and was
//  never actually visible on a real device. It now renders ABOVE the card, anchored near the top
//  of the card, and only ejects into the upper hemisphere (never straight down through the
//  headline/supporting text) — see ConfettiPiece.makeBurst() and the ZStack ordering below.
//

import SwiftUI

struct CommunityReportSuccessOverlay: View {
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isContentVisible = false
    @State private var confettiProgress: CGFloat = 0
    // Generated exactly once per presentation — a `@State` initial value is evaluated only when
    // this view's identity is first created, never again on subsequent body re-evaluations.
    @State private var confettiPieces: [ConfettiPiece] = ConfettiPiece.makeBurst()

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            card
                .scaleEffect(isContentVisible ? 1 : (reduceMotion ? 1 : 0.92))
                .opacity(isContentVisible ? 1 : 0)
                .animation(
                    reduceMotion
                        ? .easeInOut(duration: 0.2)
                        : .spring(response: 0.34, dampingFraction: 0.78),
                    value: isContentVisible
                )

            if reduceMotion == false {
                // Above the card (not below it, where the card's own opaque background fully
                // occluded every piece) and anchored ~90pt above center — roughly where iconBadge
                // sits, since that's the one part of the card whose vertical position is stable
                // regardless of Dynamic Type text reflow — so the burst reads as radiating from
                // around the icon and out into the dimmed backdrop, never over the card's text.
                // allowsHitTesting/accessibilityHidden keep it fully decorative: it can never
                // intercept a tap meant for the card/button, and VoiceOver skips every particle.
                ConfettiBurstView(pieces: confettiPieces, progress: confettiProgress)
                    .offset(y: -90)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onAppear {
            isContentVisible = true
            AccessibilityNotification.Announcement(
                "E85 price report submitted successfully. Thanks for helping the E85 community."
            ).post()
        }
        .task {
            // Deferred one run-loop tick past onAppear so this view's first real frame — with
            // confettiProgress genuinely still 0 — actually commits before animating to 1.
            // Without this, the state change can collapse into the same initial transaction as
            // the parent's own `.transition(.opacity)` insertion of this overlay (StationsView
            // wraps presentation in `.animation(value: communityReportCelebration.isPresented)`),
            // so the very first frame already renders the fully-displaced, fully-faded end state
            // and the burst is never actually seen even though it "plays." `.task` also
            // auto-cancels if this view disappears before the yield resumes (e.g. a fast
            // "Awesome" tap), so a dismissed celebration can never set stale progress afterward.
            guard reduceMotion == false else { return }
            await Task.yield()
            confettiProgress = 1
        }
        // Tells VoiceOver this covers and blocks the rest of the screen while shown, matching its
        // actual behavior — the backdrop absorbs taps and only the card/button are interactive.
        .accessibilityAddTraits(.isModal)
    }

    private var card: some View {
        VStack(spacing: 16) {
            iconBadge
                .accessibilityHidden(true) // meaning is fully carried by the grouped text below

            VStack(spacing: 8) {
                Text("Thanks for helping the E85 community!")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text("Your E85 price report is live and helping nearby drivers find the best price.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            // One coherent VoiceOver phrase instead of the visual headline and supporting text
            // being read back to back — avoids duplicate/repetitive output.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "E85 price report submitted successfully. Thanks for helping the E85 community."
            )

            PrimaryButton(title: "Awesome", action: onDismiss)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(AppTheme.Colors.elevatedCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color.black.opacity(0.25), radius: 24, y: 12)
        .padding(.horizontal, 32)
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Colors.primaryGreen.opacity(0.16))
                .frame(width: 88, height: 88)

            Image(systemName: "fuelpump.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.primaryGreen)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, AppTheme.Colors.primaryGreen)
                .font(.system(size: 22, weight: .bold))
                .background(
                    Circle()
                        .fill(AppTheme.Colors.elevatedCardBackground)
                        .frame(width: 24, height: 24)
                )
                .offset(x: 4, y: 4)
        }
    }
}

/// One piece of the one-shot confetti burst. Colors deliberately reuse the app's existing theme
/// tokens (green/blue/gold) rather than introducing new hardcoded values.
private struct ConfettiPiece: Identifiable {
    let id = UUID()
    let color: Color
    let symbolName: String
    let angle: Double
    let distance: CGFloat
    let rotation: Double
    let scale: CGFloat
    let delay: Double

    /// Exactly 45 pieces, generated once per presentation — never regenerated on body
    /// re-evaluation (this is only ever called from a `@State` initial-value expression).
    static func makeBurst() -> [ConfettiPiece] {
        let colors: [Color] = [
            AppTheme.Colors.primaryGreen,
            AppTheme.Colors.rangeBlue,
            AppTheme.Colors.stationYellow
        ]
        let symbols = ["circle.fill", "sparkle", "seal.fill"]
        let count = 45

        return (0..<count).map { _ in
            ConfettiPiece(
                color: colors.randomElement() ?? AppTheme.Colors.primaryGreen,
                symbolName: symbols.randomElement() ?? "circle.fill",
                // Upper hemisphere only (SwiftUI's y-axis is down-positive, so a negative
                // sin(angle) moves a piece up): left, straight up, and right, but never straight
                // down — a downward angle would send a piece through the headline/supporting
                // text below the icon instead of out into the dimmed backdrop around the card.
                angle: Double.random(in: (-Double.pi)...0),
                distance: CGFloat.random(in: 70...170),
                rotation: Double.random(in: -180...180),
                scale: CGFloat.random(in: 0.5...1.1),
                delay: Double.random(in: 0...0.15)
            )
        }
    }
}

/// Renders a fixed set of confetti pieces flying outward from center once, driven purely by
/// `progress` (0 → 1, set exactly once by the presenting view's deferred `.task`). No Timer, no
/// repeating animation — each piece's own `.animation(_:value:)` modifier animates it once when
/// `progress` changes.
private struct ConfettiBurstView: View {
    let pieces: [ConfettiPiece]
    let progress: CGFloat

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                Image(systemName: piece.symbolName)
                    .font(.system(size: 10))
                    .foregroundStyle(piece.color)
                    .scaleEffect(piece.scale)
                    .rotationEffect(.degrees(piece.rotation * progress))
                    .opacity(1 - progress)
                    .offset(
                        x: cos(piece.angle) * piece.distance * progress,
                        y: sin(piece.angle) * piece.distance * progress
                    )
                    .animation(.easeOut(duration: 0.7).delay(piece.delay), value: progress)
            }
        }
    }
}

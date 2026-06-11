//
//  Theme.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

#if os(iOS)
import UIKit
#endif

enum AppTheme {
    static func applyTabBarAppearance() {
        #if os(iOS)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Colors.tabBarBackground)
        appearance.shadowColor = UIColor(Colors.borderColor)

        let selected = UIColor(Colors.primaryGreen)
        let unselected = UIColor(Colors.textMuted)

        appearance.stackedLayoutAppearance.selected.iconColor = selected
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: selected]
        appearance.stackedLayoutAppearance.normal.iconColor = unselected
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: unselected]

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().unselectedItemTintColor = unselected
        #endif
    }

    enum Colors {
        // Cached theme preference — updated via NotificationCenter when UserDefaults changes
        // so we never hit UserDefaults on every color access.
        private static var _cachedThemePreference: ThemePreferenceOption = {
            let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.themePreference)
                ?? ThemePreferenceOption.system.rawValue
            return ThemePreferenceOption(rawValue: raw) ?? .system
        }()

        // Observe UserDefaults changes once, lazily, via a stored token we keep alive.
        private static let _observer: NSObjectProtocol = {
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.themePreference)
                    ?? ThemePreferenceOption.system.rawValue
                _cachedThemePreference = ThemePreferenceOption(rawValue: raw) ?? .system
            }
        }()

        private static var themePreference: ThemePreferenceOption {
            // Referencing _observer here ensures the lazy initialiser has run at least once.
            _ = _observer
            return _cachedThemePreference
        }

        static var isOLEDThemeActive: Bool {
            themePreference == .oledDark
        }

        static var oledBackground: Color {
            // Light: #F5F7FA — subtle gray page so white cards visibly elevate.
            dynamic(
                light: Color(red: 0.961, green: 0.969, blue: 0.980),
                dark: Color(red: 0.04, green: 0.04, blue: 0.045),
                oled: .black
            )
        }

        static var cardBackground: Color {
            // Light: #FFFFFF — used for inputs, chips, and small surfaces.
            dynamic(
                light: .white,
                dark: Color(red: 0.08, green: 0.08, blue: 0.085),
                oled: Color(red: 0.004, green: 0.004, blue: 0.005)
            )
        }

        static var elevatedCardBackground: Color {
            // Light: #FFFFFF — outer cards float on the gray page; borders provide hierarchy.
            dynamic(
                light: .white,
                dark: Color(red: 0.11, green: 0.11, blue: 0.115),
                oled: Color(red: 0.015, green: 0.015, blue: 0.018)
            )
        }

        static var borderColor: Color {
            // Light: #E3E8EF — soft but clearly visible.
            dynamic(
                light: Color(red: 0.890, green: 0.910, blue: 0.937),
                dark: Color.white.opacity(0.08),
                oled: Color.white.opacity(0.12)
            )
        }

        static var tabBarBackground: Color {
            // Light: pure white tab bar for a cleaner separation from the gray page.
            dynamic(
                light: .white,
                dark: Color(red: 0.04, green: 0.04, blue: 0.045),
                oled: .black
            )
        }

        static var primaryGreen: Color { AccentThemeStore.shared.current.primaryColor }
        // Light mode: soft tint of the active accent so selected chips, icon halos, and active states
        // read as the accent without the muddy dark-sage/dark-navy used on dark surfaces.
        // Dark/OLED: keeps the existing dark muted fill from AppAccentTheme.softFillColor for contrast.
        static var softGreenBackground: Color {
            let primary = AccentThemeStore.shared.current.primaryColor
            let darkFill = AccentThemeStore.shared.current.softFillColor
            return dynamic(
                light: primary.opacity(0.16),
                dark: darkFill,
                oled: darkFill
            )
        }
        static let warningRed = Color(red: 0.91, green: 0.33, blue: 0.36)
        static let gasOrange = Color(red: 0.98, green: 0.58, blue: 0.16)
        static let stationYellow = Color(red: 0.98, green: 0.78, blue: 0.20)
        static let powerRed = Color(red: 1.0, green: 0.35, blue: 0.30)
        static let rangeBlue = Color(red: 0.32, green: 0.69, blue: 1.0)
        // In Performance Blue the range badge is stationYellow so it doesn't
        // compete visually with the primary royal-blue accent.
        static var rangeColor: Color {
            AccentThemeStore.shared.current == .performanceBlue ? stationYellow : rangeBlue
        }

        static var textPrimary: Color {
            // Light: #111827 — near-black for high contrast titles.
            dynamic(light: Color(red: 0.067, green: 0.094, blue: 0.153), dark: .white, oled: .white)
        }

        static var textSecondary: Color {
            // Light: #667085 — calm slate for body copy.
            dynamic(light: Color(red: 0.400, green: 0.439, blue: 0.522), dark: Color(red: 0.61, green: 0.69, blue: 0.79), oled: Color(red: 0.60, green: 0.69, blue: 0.80))
        }

        static var textMuted: Color {
            // Light: #8A95A5 — muted slate for hints/captions.
            dynamic(light: Color(red: 0.541, green: 0.584, blue: 0.647), dark: Color(red: 0.42, green: 0.52, blue: 0.62), oled: Color(red: 0.40, green: 0.50, blue: 0.60))
        }

        static var darkBlue: Color { textMuted }
        static var charcoal: Color { oledBackground }
        static var accentYellow: Color { stationYellow }
        static var accentGreen: Color { primaryGreen }
        static var surface: Color { cardBackground }
        static var surfaceElevated: Color { elevatedCardBackground }
        static var border: Color { borderColor }
        static var groupedBackground: Color { oledBackground }

        private static func dynamic(light: Color, dark: Color, oled: Color) -> Color {
            let darkValue = isOLEDThemeActive ? oled : dark
            #if os(iOS)
            return Color(
                UIColor { traits in
                    if traits.userInterfaceStyle == .light, themePreference != .oledDark, themePreference != .dark {
                        return UIColor(light)
                    }
                    return UIColor(darkValue)
                }
            )
            #else
            return darkValue
            #endif
        }
    }
}

struct AppCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.elevatedCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.Colors.textMuted)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    var systemImage: String = "tray"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.stationYellow)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.elevatedCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct WarningCard: View {
    let title: String
    let message: String
    var systemImage: String = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.stationYellow)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.gasOrange.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct PrimaryButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(AppTheme.Colors.primaryGreen)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.Colors.borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Accent Theme Store
// Single source of truth for the active accent theme. Using @Observable means any SwiftUI
// view body that accesses AppTheme.Colors.primaryGreen (which reads shared.current) is
// automatically tracked and re-rendered when the theme changes — no @EnvironmentObject needed.
@Observable
final class AccentThemeStore {
    static let shared = AccentThemeStore()

    private(set) var current: AppAccentTheme

    private init() {
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.accentTheme) ?? ""
        current = AppAccentTheme(rawValue: raw) ?? .originalGreen
    }

    func select(_ theme: AppAccentTheme) {
        current = theme
        UserDefaults.standard.set(theme.rawValue, forKey: AppPreferenceKey.accentTheme)
    }
}

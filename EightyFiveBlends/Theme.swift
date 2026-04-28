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
        appearance.backgroundColor = UIColor(Colors.oledBackground)
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
        private static var themePreference: ThemePreferenceOption {
            ThemePreferenceOption(
                rawValue: UserDefaults.standard.string(forKey: AppPreferenceKey.themePreference) ?? ThemePreferenceOption.system.rawValue
            ) ?? .system
        }

        private static var isOLED: Bool {
            themePreference == .oledDark
        }

        static var oledBackground: Color {
            dynamic(light: Color(red: 0.97, green: 0.98, blue: 0.99), dark: Color.black, oled: Color.black)
        }

        static var cardBackground: Color {
            dynamic(light: Color.white, dark: Color(red: 0.07, green: 0.07, blue: 0.07), oled: Color(red: 0.043, green: 0.043, blue: 0.043))
        }

        static var elevatedCardBackground: Color {
            dynamic(light: Color(red: 0.95, green: 0.96, blue: 0.98), dark: Color(red: 0.10, green: 0.10, blue: 0.10), oled: Color(red: 0.063, green: 0.063, blue: 0.063))
        }

        static var borderColor: Color {
            dynamic(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.08), oled: Color.white.opacity(0.09))
        }

        static let primaryGreen = Color(red: 0.19, green: 0.92, blue: 0.48)
        static let softGreenBackground = Color(red: 0.13, green: 0.28, blue: 0.20)
        static let warningRed = Color(red: 0.91, green: 0.33, blue: 0.36)
        static let gasOrange = Color(red: 0.98, green: 0.58, blue: 0.16)
        static let stationYellow = Color(red: 0.98, green: 0.78, blue: 0.20)
        static let powerRed = Color(red: 1.0, green: 0.35, blue: 0.30)
        static let rangeBlue = Color(red: 0.32, green: 0.69, blue: 1.0)

        static var textPrimary: Color {
            dynamic(light: Color.black.opacity(0.92), dark: .white, oled: .white)
        }

        static var textSecondary: Color {
            dynamic(light: Color(red: 0.30, green: 0.36, blue: 0.44), dark: Color(red: 0.61, green: 0.69, blue: 0.79), oled: Color(red: 0.60, green: 0.69, blue: 0.80))
        }

        static var textMuted: Color {
            dynamic(light: Color(red: 0.43, green: 0.49, blue: 0.57), dark: Color(red: 0.42, green: 0.52, blue: 0.62), oled: Color(red: 0.40, green: 0.50, blue: 0.60))
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
            let darkValue = isOLED ? oled : dark
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
        .background(AppTheme.Colors.gasOrange.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.Colors.gasOrange.opacity(0.45), lineWidth: 1)
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

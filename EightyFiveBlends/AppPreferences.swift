//
//  AppPreferences.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import SwiftUI

enum AppPreferenceKey {
    static let preferredMapsApp = "preferredMapsApp"
    static let defaultTargetBlend = "defaultTargetBlend"
    static let themePreference = "themePreference"
    static let showGarageTab = "showGarageTab"
    static let showRemindersTab = "showRemindersTab"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
}

enum MapsAppOption: String, CaseIterable {
    case appleMaps = "Apple Maps"
    case googleMaps = "Google Maps"
    case waze = "Waze"
}

enum BlendPreferenceOption: String, CaseIterable {
    case e20 = "E20"
    case e30 = "E30"
    case e40 = "E40"
    case e50 = "E50"
    case e60 = "E60"
    case e70 = "E70"
    case e85 = "E85"
}

enum ThemePreferenceOption: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    case oledDark = "OLED Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark, .oledDark:
            return .dark
        }
    }
}

//
//  AppPreferences.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import MapKit
import SwiftUI
import UIKit

enum AppPreferenceKey {
    static let preferredMapsApp = "preferredMapsApp"
    static let defaultTargetBlend = "defaultTargetBlend"
    static let themePreference = "themePreference"
    static let accentTheme = "appAccentTheme"
    static let showGarageTab = "showGarageTab"
    static let showRemindersTab = "showRemindersTab"
    // App Experience Mode (Simple / Normal) — presentation/navigation preference only. See
    // AppExperienceMode below and AppExperienceNavigation.swift for the tab-visibility rules
    // this key drives. Absence of this key (never-set / pre-feature installs) must resolve to
    // .normal — see AppExperienceMode.resolved(from:).
    static let appExperienceMode = "appExperienceMode"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let hasAcknowledgedDisclaimer = "hasAcknowledgedDisclaimer"
    static let disclaimerAcknowledgedAt = "disclaimerAcknowledgedAt"
    // The app version (CFBundleShortVersionString) the "What's New" sheet was last shown for.
    // Empty/absent means "never shown" — true both for a brand-new install and for an existing
    // install upgrading from a version that predates this feature. See
    // WhatsNewPresentation.shouldPresent(...) for how ContentView tells those two apart.
    static let lastPresentedWhatsNewVersion = "lastPresentedWhatsNewVersion"
    // Last At the Pump setup — lightweight UI memory only. Current blend deliberately
    // has no key here: it always comes from the fuel log / vehicle, never from memory.
    static let lastPumpTargetBlend = "lastPumpTargetBlend"
    static let lastPumpTargetIsMaxE85 = "lastPumpTargetIsMaxE85"
    static let lastPumpE85Content = "lastPumpE85Content"
    static let lastPumpFuelLevel = "lastPumpFuelLevel"
    static let lastPumpFuelType = "lastPumpFuelType"
    // Automatic Pump Detection — opt-in background arrival detection (see
    // AutomaticPumpDetectionService). All persisted state is namespaced under this prefix.
    static let automaticPumpDetectionEnabled = "automaticPumpDetectionEnabled"
    static let automaticPumpDetectionMonitoredStations = "automaticPumpDetectionMonitoredStations"
    static let automaticPumpDetectionCooldownState = "automaticPumpDetectionCooldownState"
    static let automaticPumpDetectionLastRefreshLatitude = "automaticPumpDetectionLastRefreshLatitude"
    static let automaticPumpDetectionLastRefreshLongitude = "automaticPumpDetectionLastRefreshLongitude"
    static let automaticPumpDetectionLastRefreshAt = "automaticPumpDetectionLastRefreshAt"
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

enum AppAccentTheme: String, CaseIterable {
    case originalGreen = "originalGreen"
    case performanceBlue = "performanceBlue"

    var displayName: String {
        switch self {
        case .originalGreen: return "Original Green"
        case .performanceBlue: return "Performance Blue"
        }
    }

    var primaryColor: Color {
        switch self {
        case .originalGreen: return Color(red: 0.19, green: 0.92, blue: 0.48)
        case .performanceBlue: return Color(red: 0.078, green: 0.361, blue: 1.0)
        }
    }

    var softFillColor: Color {
        switch self {
        case .originalGreen: return Color(red: 0.13, green: 0.28, blue: 0.20)
        case .performanceBlue: return Color(red: 0.063, green: 0.157, blue: 0.373)
        }
    }
}

/// Simple vs. Normal app presentation. This is purely a navigation/UI preference — switching
/// modes never touches SwiftData, CloudKit, Pro entitlements, or any of the other preference
/// keys above (in particular `showGarageTab`/`showRemindersTab`, which Normal Mode continues to
/// honor exactly as before; Simple Mode simply doesn't consult them). See
/// AppExperienceNavigation.swift for the tab-visibility rules this drives.
enum AppExperienceMode: String, CaseIterable, Identifiable {
    case simple
    case normal

    var id: String { rawValue }

    /// Existing installs — and any stored value this app version doesn't recognize — must
    /// resolve to `.normal` so an update never hides a tab a current user already relies on.
    /// Every read site should go through this rather than `AppExperienceMode(rawValue:)`
    /// directly, so that guarantee lives in exactly one place.
    static func resolved(from rawValue: String) -> AppExperienceMode {
        AppExperienceMode(rawValue: rawValue) ?? .normal
    }

    var displayName: String {
        switch self {
        case .simple: return "Simple"
        case .normal: return "Normal"
        }
    }

    /// One-line summary shown next to the mode picker in Settings.
    var settingsSummary: String {
        switch self {
        case .simple:
            return "Calculator and Stations with a streamlined interface."
        case .normal:
            return "Full 85Blends experience including Garage, Fuel Log, Reminders, Trip Planner, and other features."
        }
    }

    /// Longer description for the onboarding choice cards.
    var onboardingHeadline: String {
        switch self {
        case .simple:
            return "For drivers who mainly want to calculate ethanol blends and find E85 stations."
        case .normal:
            return "The complete 85Blends experience with vehicles, fuel tracking, reminders, trip planning, and more."
        }
    }

    // A small, representative set only — not an exhaustive feature list. Kept short enough to
    // lay out on one line inside the onboarding choice card at normal Dynamic Type sizes without
    // clipping or scrolling; onboardingHeadline's sentence already communicates that Normal is
    // the complete experience, so Fuel Log/Trip Planner/Analytics don't need their own chips.
    var onboardingFeatureBullets: [String] {
        switch self {
        case .simple:
            return ["Calculator", "Stations"]
        case .normal:
            return ["Calculator", "Stations", "Garage", "Reminders", "More"]
        }
    }
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

struct MapsRoutingDestination {
    let name: String
    let streetAddress: String
    let city: String
    let state: String
    let zip: String
    let latitude: Double?
    let longitude: Double?

    var coordinate: CLLocationCoordinate2D? {
        guard
            let latitude,
            let longitude,
            (-90...90).contains(latitude),
            (-180...180).contains(longitude),
            latitude != 0 || longitude != 0
        else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var addressQuery: String? {
        let parts = [name, streetAddress, city, state, zip]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard parts.isEmpty == false else { return nil }
        return parts.joined(separator: ", ")
    }
}

enum MapsRoutingError: LocalizedError {
    case insufficientLocationInformation

    var errorDescription: String? {
        switch self {
        case .insufficientLocationInformation:
            return "This station does not have enough location information for directions."
        }
    }
}

@MainActor
enum MapsRoutingHelper {
    static func openDirections(to destination: MapsRoutingDestination) -> String? {
        guard destination.coordinate != nil || destination.addressQuery != nil else {
            return MapsRoutingError.insufficientLocationInformation.localizedDescription
        }

        let preferredMapsApp = MapsAppOption(
            rawValue: UserDefaults.standard.string(forKey: AppPreferenceKey.preferredMapsApp) ?? ""
        ) ?? .appleMaps

        switch preferredMapsApp {
        case .appleMaps:
            openAppleMaps(to: destination)
        case .googleMaps:
            if openURL(googleMapsURL(for: destination)) == false {
                openAppleMaps(to: destination)
            }
        case .waze:
            if openURL(wazeURL(for: destination)) == false {
                openAppleMaps(to: destination)
            }
        }

        return nil
    }

    private static func openAppleMaps(to destination: MapsRoutingDestination) {
        if let coordinate = destination.coordinate {
            let placemark = MKPlacemark(coordinate: coordinate)
            let item = MKMapItem(placemark: placemark)
            item.name = destination.name.isEmpty ? "Station" : destination.name
            item.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
            ])
            return
        }

        guard let addressQuery = destination.addressQuery else { return }

        var components = URLComponents(string: "http://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: addressQuery),
            URLQueryItem(name: "dirflg", value: "d")
        ]
        _ = openURL(components?.url)
    }

    private static func googleMapsURL(for destination: MapsRoutingDestination) -> URL? {
        var components = URLComponents(string: "comgooglemaps://")
        components?.queryItems = googleMapsQueryItems(for: destination)
        return components?.url
    }

    private static func googleMapsQueryItems(for destination: MapsRoutingDestination) -> [URLQueryItem] {
        if let coordinate = destination.coordinate {
            return [
                URLQueryItem(name: "daddr", value: "\(coordinate.latitude),\(coordinate.longitude)"),
                URLQueryItem(name: "directionsmode", value: "driving")
            ]
        }

        return [
            URLQueryItem(name: "daddr", value: destination.addressQuery),
            URLQueryItem(name: "directionsmode", value: "driving")
        ]
    }

    private static func wazeURL(for destination: MapsRoutingDestination) -> URL? {
        var components = URLComponents(string: "waze://")
        components?.queryItems = wazeQueryItems(for: destination)
        return components?.url
    }

    private static func wazeQueryItems(for destination: MapsRoutingDestination) -> [URLQueryItem] {
        if let coordinate = destination.coordinate {
            return [
                URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
                URLQueryItem(name: "navigate", value: "yes")
            ]
        }

        return [
            URLQueryItem(name: "q", value: destination.addressQuery),
            URLQueryItem(name: "navigate", value: "yes")
        ]
    }

    @discardableResult
    private static func openURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }
}

//
//  ReleaseNotes.swift
//  EightyFiveBlends
//
//  Single source of truth for the CURRENT release's customer-facing changelog highlights.
//  AboutView's "What's New" section and WhatsNewView (the one-time update popup) both read
//  currentHighlights, so the two can never drift into independently maintained copies — update
//  this file when preparing a new release's changelog, and both surfaces pick it up.
//
//  currentHighlightsTitle reads the version number live from the app bundle
//  (CFBundleShortVersionString) rather than hardcoding it, so a future release only needs its
//  highlights array updated here — the title is automatically correct.
//

import Foundation

enum ReleaseNotes {
    /// This release's customer-facing highlights, in display order. Keep these short, concrete,
    /// and free of internal engineering/branch/build/QA language — this is shown directly to
    /// users in both AboutView and the What's New popup.
    static let currentHighlights: [String] = [
        "New Simple Mode gives drivers a streamlined experience focused on the Blend Calculator and E85 Stations.",
        "New Normal Mode keeps the complete 85Blends experience, including Garage, Fuel Log, Reminders, Trip Planner, and more.",
        "Choose your preferred experience during onboarding, and switch between Simple and Normal anytime from Preferences.",
        "Switching modes preserves your vehicles, fuel history, reminders, saved data, and app preferences.",
        "Improved onboarding makes it easier to choose the 85Blends experience that fits how you use the app.",
        "Compare Fuel Cost makes it easy to see how different ethanol blends affect the price of a fill-up.",
    ]

    /// "What's New in X.Y.Z" — the version is read live from the bundle, never hardcoded, so
    /// this label is correct for every future release without any code change here.
    static var currentHighlightsTitle: String {
        "What's New in \(currentAppVersion)"
    }

    /// CFBundleShortVersionString (MARKETING_VERSION at build time), with a safe fallback for
    /// contexts where the bundle's Info dictionary isn't populated (e.g. SwiftUI previews).
    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

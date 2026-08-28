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
        "Stations now opens faster by restoring your recent nearby results on relaunch while fresh station data updates in the background.",
        "85Blends Pro now includes an interactive Stations map for quickly browsing nearby E85, favorites, directions, and Trip Planner access.",
        "Pro users can choose between the new Map layout and the Classic Stations layout from Preferences.",
        "Share any E85 station's name and address directly from Stations — available to Free and Pro users.",
        "85Blends now opens directly to Stations, putting nearby E85 front and center when you launch the app.",
        "Improved station map framing and launch behavior make browsing nearby E85 feel smoother and more consistent.",
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

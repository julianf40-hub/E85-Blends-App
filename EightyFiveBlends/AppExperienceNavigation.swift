//
//  AppExperienceNavigation.swift
//  EightyFiveBlends
//
//  Pure decision logic behind App Experience Mode (Simple / Normal) tab visibility and the
//  safe-selection redirect used when a mode switch would otherwise leave the TabView pointed
//  at a tab that no longer exists. Kept independent of SwiftUI's TabView/@AppStorage machinery,
//  mirroring ReminderScheduling/VehicleOdometerPolicy/VehicleActivation's separation of pure
//  rules from the views that call them, so the actual rules ContentView depends on are directly
//  unit-testable. See EightyFiveBlendsTests/AppExperienceNavigationTests.swift.
//
//  This file only decides what's visible and where selection should land. It never reads or
//  writes showGarageTab/showRemindersTab, SwiftData, CloudKit, or Pro entitlement state — mode
//  switching is a presentation-only concern.
//

import Foundation

enum AppExperienceNavigation {
    /// The tabs to render, in the app's fixed display order, for a given mode and the user's
    /// existing (never mutated by a mode switch) Garage/Reminders tab preferences.
    ///
    /// Normal Mode reproduces today's behavior exactly: Calculator, Stations, Garage (if
    /// `showGarageTab`), Reminders (if `showRemindersTab`), More.
    ///
    /// Simple Mode ignores `showGarageTab`/`showRemindersTab` entirely — not because they've
    /// been cleared, but because Simple Mode's contract is a fixed three-tab set regardless of
    /// what a user previously chose for Normal Mode.
    static func visibleTabs(
        mode: AppExperienceMode,
        showGarageTab: Bool,
        showRemindersTab: Bool
    ) -> [ContentView.Tab] {
        switch mode {
        case .simple:
            return [.calculator, .stations, .more]
        case .normal:
            var tabs: [ContentView.Tab] = [.calculator, .stations]
            if showGarageTab {
                tabs.append(.garage)
            }
            if showRemindersTab {
                tabs.append(.reminders)
            }
            tabs.append(.more)
            return tabs
        }
    }

    /// The tab selection to use after `visibleTabs` changes (mode switch, or a tab-visibility
    /// preference change) given the previously selected tab. If `current` is still visible it's
    /// kept unchanged; otherwise this redirects to `.calculator`, which is present in every mode
    /// and preference combination, rather than leaving the choice to undefined TabView behavior.
    static func resolvedSelection(
        current: ContentView.Tab,
        visibleTabs: [ContentView.Tab]
    ) -> ContentView.Tab {
        visibleTabs.contains(current) ? current : .calculator
    }
}

//
//  ContentView.swift
//  EightyFiveBlends
//
//  Created by Julian FIgueroa on 4/27/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    // Internal (not private) so AppExperienceNavigation's pure tab-visibility/selection rules —
    // and their tests — can reference ContentView.Tab directly.
    enum Tab: Hashable {
        case calculator, stations, garage, reminders, more
    }

    @AppStorage(AppPreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppPreferenceKey.showGarageTab) private var showGarageTab = true
    @AppStorage(AppPreferenceKey.showRemindersTab) private var showRemindersTab = true
    // Absence of this key (pre-App-Experience-Mode installs) resolves to .normal via
    // AppExperienceMode.resolved(from:) — existing users never lose a tab on update.
    @AppStorage(AppPreferenceKey.appExperienceMode) private var appExperienceModeRaw = AppExperienceMode.normal.rawValue
    @Environment(AutomaticPumpDetectionService.self) private var pumpDetectionService
    @State private var selectedTab: Tab = .calculator

    private var appExperienceMode: AppExperienceMode {
        .resolved(from: appExperienceModeRaw)
    }

    private var visibleTabs: [Tab] {
        AppExperienceNavigation.visibleTabs(
            mode: appExperienceMode,
            showGarageTab: showGarageTab,
            showRemindersTab: showRemindersTab
        )
    }

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                TabView(selection: $selectedTab) {
                    CalculatorView()
                    .tabItem {
                        Label("Calculator", systemImage: "fuelpump")
                    }
                    .tag(Tab.calculator)

                    StationsView()
                        .tabItem {
                            Label("Stations", systemImage: "mappin.and.ellipse")
                        }
                        .tag(Tab.stations)

                    // Normal Mode honors the user's existing Garage/Reminders tab preferences
                    // exactly as before. Simple Mode shows only Calculator, Stations, and More,
                    // regardless of these preferences — they're never read, or mutated, while
                    // in Simple Mode (see AppExperienceNavigation.visibleTabs).
                    if appExperienceMode == .normal && showGarageTab {
                        GarageView()
                            .tabItem {
                                Label("Garage", systemImage: "car.fill")
                            }
                            .tag(Tab.garage)
                    }

                    if appExperienceMode == .normal && showRemindersTab {
                        RemindersView()
                            .tabItem {
                                Label("Reminders", systemImage: "bell.badge")
                            }
                            .tag(Tab.reminders)
                    }

                    MoreView()
                        .tabItem {
                            Label("More", systemImage: "ellipsis.circle.fill")
                        }
                        .tag(Tab.more)
                }
                .tint(AppTheme.Colors.primaryGreen)
                // A tapped Automatic Pump Detection notification resolves to a pending
                // station on the service; switch to Calculator so its own existing sheet
                // machinery (see CalculatorView) can present Pump Mode for it. Calculator is
                // present in every App Experience Mode, so this is always a valid destination —
                // if a future change ever targets a different tab here, it must first go
                // through AppExperienceNavigation.resolvedSelection like the mode-switch
                // handler below does.
                .onChange(of: pumpDetectionService.pendingDetectedStation) { _, newValue in
                    if newValue != nil {
                        selectedTab = .calculator
                    }
                }
                // Switching App Experience Mode can hide the tab currently on screen (e.g.
                // viewing Garage, then switching to Simple Mode). Redirect deliberately rather
                // than relying on undefined TabView behavior when its selection tag disappears.
                .onChange(of: appExperienceModeRaw) {
                    selectedTab = AppExperienceNavigation.resolvedSelection(
                        current: selectedTab,
                        visibleTabs: visibleTabs
                    )
                }
            } else {
                OnboardingView()
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [
                VehicleProfile.self,
                FuelLogEntry.self,
                MaintenanceReminder.self,
                ReminderCompletionRecord.self,
                FuelStation.self,
            ],
            inMemory: true
        )
}

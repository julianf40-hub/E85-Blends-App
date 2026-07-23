//
//  ContentView.swift
//  EightyFiveBlends
//
//  Created by Julian FIgueroa on 4/27/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    private enum Tab: Hashable {
        case calculator, stations, garage, reminders, more
    }

    @AppStorage(AppPreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppPreferenceKey.showGarageTab) private var showGarageTab = true
    @AppStorage(AppPreferenceKey.showRemindersTab) private var showRemindersTab = true
    @Environment(AutomaticPumpDetectionService.self) private var pumpDetectionService
    @State private var selectedTab: Tab = .calculator

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

                    if showGarageTab {
                        GarageView()
                            .tabItem {
                                Label("Garage", systemImage: "car.fill")
                            }
                            .tag(Tab.garage)
                    }

                    if showRemindersTab {
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
                // machinery (see CalculatorView) can present Pump Mode for it.
                .onChange(of: pumpDetectionService.pendingDetectedStation) { _, newValue in
                    if newValue != nil {
                        selectedTab = .calculator
                    }
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

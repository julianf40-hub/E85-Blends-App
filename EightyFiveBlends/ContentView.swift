//
//  ContentView.swift
//  EightyFiveBlends
//
//  Created by Julian FIgueroa on 4/27/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @AppStorage(AppPreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppPreferenceKey.showGarageTab) private var showGarageTab = true
    @AppStorage(AppPreferenceKey.showRemindersTab) private var showRemindersTab = true
    @AppStorage(AppPreferenceKey.showGearTab) private var showGearTab = true

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                TabView {
                    CalculatorView()
                    .tabItem {
                        Label("Calculator", systemImage: "fuelpump")
                    }

                    StationsView()
                        .tabItem {
                            Label("Stations", systemImage: "mappin.and.ellipse")
                        }

                    if showGarageTab {
                        GarageView()
                            .tabItem {
                                Label("Garage", systemImage: "car.fill")
                            }
                    }

                    if showRemindersTab {
                        RemindersView()
                            .tabItem {
                                Label("Reminders", systemImage: "bell.badge")
                            }
                    }

                    if showGearTab {
                        RecommendedGearView()
                            .tabItem {
                                Label("Gear", systemImage: "wrench.and.screwdriver")
                            }
                    }

                    MoreView()
                        .tabItem {
                            Label("More", systemImage: "ellipsis.circle.fill")
                        }
                }
                .tint(AppTheme.Colors.primaryGreen)
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

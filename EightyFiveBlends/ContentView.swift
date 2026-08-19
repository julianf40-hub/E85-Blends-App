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
    @AppStorage(AppPreferenceKey.lastPresentedWhatsNewVersion) private var lastPresentedWhatsNewVersion = ""
    @Environment(AutomaticPumpDetectionService.self) private var pumpDetectionService
    @State private var selectedTab: Tab = .calculator
    @State private var isShowingWhatsNew = false
    @State private var hasEvaluatedWhatsNewEligibility = false
    // Snapshotted once, synchronously, from the raw persisted value at the moment this view is
    // first created — deliberately NOT read via @AppStorage/.onChange, whose relative firing
    // order against .onAppear on a newly-mounted view isn't something to depend on. This makes
    // "did onboarding complete during this exact launch" a plain, deterministic comparison
    // instead of a race between two SwiftUI update-cycle callbacks.
    @State private var wasOnboardingAlreadyCompleteAtLaunch = UserDefaults.standard.bool(
        forKey: AppPreferenceKey.hasCompletedOnboarding
    )

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

    // True only when onboarding transitioned from incomplete to complete during this same
    // launch — i.e. a brand-new (or onboarding-reset) user finishing onboarding just now. False
    // for every other case, including an existing user who completed onboarding in some past
    // session, however long ago. See WhatsNewPresentation.shouldPresent(...).
    private var onboardingJustCompletedThisLaunch: Bool {
        hasCompletedOnboarding && wasOnboardingAlreadyCompleteAtLaunch == false
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

                    // Rendered tab membership is driven by the same visibleTabs computed
                    // property the mode-switch redirect below uses, rather than re-deriving
                    // "appExperienceMode == .normal && showGarageTab" inline here — one source
                    // of truth (AppExperienceNavigation.visibleTabs) instead of two copies of
                    // the same rule that could silently drift apart. Normal Mode honors the
                    // user's existing Garage/Reminders tab preferences exactly as before; Simple
                    // Mode shows only Calculator, Stations, and More, regardless of those
                    // preferences — they're never read, or mutated, while in Simple Mode.
                    if visibleTabs.contains(.garage) {
                        GarageView()
                            .tabItem {
                                Label("Garage", systemImage: "car.fill")
                            }
                            .tag(Tab.garage)
                    }

                    if visibleTabs.contains(.reminders) {
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
                // Attached to the TabView branch itself (not the outer Group), so this can only
                // ever run once onboarding is complete and the normal app interface is active —
                // structurally, not just by a runtime check, satisfying "never over active
                // onboarding." Not tied to any specific tab, so this works identically in
                // Simple and Normal App Experience Mode.
                .onAppear {
                    evaluateWhatsNewEligibility()
                }
                .sheet(
                    isPresented: $isShowingWhatsNew,
                    onDismiss: {
                        // Fires for every dismissal path — the Continue button and a
                        // swipe-away alike — so either one reliably records the version as
                        // shown and neither leaves the sheet re-appearing on a later launch.
                        lastPresentedWhatsNewVersion = WhatsNewPresentation.versionToPersistOnDismiss(
                            currentAppVersion: ReleaseNotes.currentAppVersion
                        )
                    }
                ) {
                    WhatsNewView(onContinue: { isShowingWhatsNew = false })
                }
            } else {
                OnboardingView()
            }
        }
    }

    private func evaluateWhatsNewEligibility() {
        guard hasEvaluatedWhatsNewEligibility == false else { return }
        hasEvaluatedWhatsNewEligibility = true

        // 85Blends 2.3.0 release-blocker fix: a brand-new user who just finished onboarding
        // this launch has already been introduced to the current app (shouldPresent already
        // suppresses What's New for them THIS launch via onboardingJustCompletedThisLaunch) —
        // but without this, lastPresentedWhatsNewVersion stays empty, so launch #2 would
        // incorrectly show What's New for the version they onboarded under. Record that version
        // as already handled, at this same deterministic onboarding-completion transition,
        // reusing the exact persistence semantics a normal dismissal already uses (see
        // WhatsNewPresentation.versionToPersistOnDismiss). A future version upgrade remains
        // eligible normally — this only ever records the CURRENT version.
        if onboardingJustCompletedThisLaunch {
            lastPresentedWhatsNewVersion = WhatsNewPresentation.versionToPersistOnDismiss(
                currentAppVersion: ReleaseNotes.currentAppVersion
            )
        }

        isShowingWhatsNew = WhatsNewPresentation.shouldPresent(
            currentAppVersion: ReleaseNotes.currentAppVersion,
            lastPresentedVersion: lastPresentedWhatsNewVersion,
            hasCompletedOnboarding: hasCompletedOnboarding,
            onboardingJustCompletedThisLaunch: onboardingJustCompletedThisLaunch
        )
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

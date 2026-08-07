//
//  AppExperienceNavigationTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the pure decision rules behind App Experience Mode (Simple / Normal): which tabs
//  are visible, and where tab selection should land after a mode switch. These are the actual
//  functions ContentView calls (AppExperienceMode.resolved(from:), AppExperienceNavigation.
//  visibleTabs, AppExperienceNavigation.resolvedSelection) — not a duplicate reimplementation —
//  so passing tests here directly verify production behavior.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//
//  Two of the ten required scenarios aren't expressible as pure-function tests and are recorded
//  here as inspection facts instead:
//  - "Pro entitlement unchanged by mode switch": AppExperienceMode (defined in AppPreferences.swift)
//    and AppExperienceNavigation.swift contain zero references to SubscriptionManager, StoreKit,
//    or any entitlement type — grep confirms this — and no file this feature touches
//    (ContentView.swift, MoreView.swift, StationsView.swift, PreferencesView.swift,
//    OnboardingView.swift, AppPreferences.swift, AppExperienceNavigation.swift) imports or
//    references SubscriptionManager.swift, which was not modified.
//  - "Stored SwiftData unchanged by mode switch": AppExperienceNavigation.swift imports only
//    Foundation (no SwiftData), and AppExperienceMode/AppPreferenceKey.appExperienceMode is a
//    plain @AppStorage(UserDefaults) value — there is no @Model, ModelContext, or SwiftData
//    relationship anywhere in this feature's code path.

import Testing
@testable import EightyFiveBlends

struct AppExperienceNavigationTests {

    // MARK: 1-3. AppExperienceMode.resolved(from:) — existing-user migration + explicit choice

    @Test("Absence of a stored value (the app's own @AppStorage default) resolves to .normal")
    func resolved_defaultRawValue_isNormal() {
        #expect(AppExperienceMode.resolved(from: AppExperienceMode.normal.rawValue) == .normal)
    }

    @Test("An unrecognized/corrupted stored value falls back to .normal, never Simple")
    func resolved_unrecognizedValue_fallsBackToNormal() {
        #expect(AppExperienceMode.resolved(from: "") == .normal)
        #expect(AppExperienceMode.resolved(from: "garbage") == .normal)
        #expect(AppExperienceMode.resolved(from: "SIMPLE") == .normal) // case-sensitive raw value, not a match
    }

    @Test("An explicit Simple selection resolves to .simple")
    func resolved_simpleRawValue_isSimple() {
        #expect(AppExperienceMode.resolved(from: AppExperienceMode.simple.rawValue) == .simple)
    }

    @Test("An explicit Normal selection resolves to .normal")
    func resolved_normalRawValue_isNormal() {
        #expect(AppExperienceMode.resolved(from: AppExperienceMode.normal.rawValue) == .normal)
    }

    // MARK: Normal Mode reproduces today's exact tab set (regression protection)

    @Test("Normal Mode with both optional tabs on matches the original hardcoded tab order")
    func visibleTabs_normalBothOn_matchesOriginalOrder() {
        let tabs = AppExperienceNavigation.visibleTabs(mode: .normal, showGarageTab: true, showRemindersTab: true)
        #expect(tabs == [.calculator, .stations, .garage, .reminders, .more])
    }

    @Test("Normal Mode honors showGarageTab/showRemindersTab in every combination, exactly as before")
    func visibleTabs_normal_honorsStoredTabPreferences() {
        #expect(
            AppExperienceNavigation.visibleTabs(mode: .normal, showGarageTab: false, showRemindersTab: true)
                == [.calculator, .stations, .reminders, .more]
        )
        #expect(
            AppExperienceNavigation.visibleTabs(mode: .normal, showGarageTab: true, showRemindersTab: false)
                == [.calculator, .stations, .garage, .more]
        )
        #expect(
            AppExperienceNavigation.visibleTabs(mode: .normal, showGarageTab: false, showRemindersTab: false)
                == [.calculator, .stations, .more]
        )
    }

    // MARK: 4 & 5. Mode switching never derives from, or mutates, showGarageTab/showRemindersTab

    @Test("Simple Mode's tab set is always Calculator/Stations/More, regardless of stored tab preferences")
    func visibleTabs_simple_ignoresStoredTabPreferencesInEveryCombination() {
        let expected: [ContentView.Tab] = [.calculator, .stations, .more]
        for showGarage in [true, false] {
            for showReminders in [true, false] {
                let tabs = AppExperienceNavigation.visibleTabs(
                    mode: .simple,
                    showGarageTab: showGarage,
                    showRemindersTab: showReminders
                )
                #expect(tabs == expected)
            }
        }
    }

    @Test("Returning to Normal Mode reproduces exactly the Garage/Reminders visibility that was stored before Simple Mode was entered")
    func visibleTabs_simpleThenNormalRoundTrip_preservesStoredTabPreferences() {
        // Simulates: user has Garage off / Reminders on in Normal Mode, switches to Simple
        // Mode (visibleTabs no longer reflects those booleans at all — see the test above),
        // then switches back to Normal Mode. Because visibleTabs is a pure function of its
        // arguments and nothing in this feature ever writes to showGarageTab/showRemindersTab,
        // the booleans themselves are untouched by the round trip, and Normal Mode's computed
        // tab set is identical before and after.
        let showGarageTab = false
        let showRemindersTab = true

        let beforeSimpleMode = AppExperienceNavigation.visibleTabs(
            mode: .normal, showGarageTab: showGarageTab, showRemindersTab: showRemindersTab
        )
        _ = AppExperienceNavigation.visibleTabs(
            mode: .simple, showGarageTab: showGarageTab, showRemindersTab: showRemindersTab
        )
        let afterReturningToNormal = AppExperienceNavigation.visibleTabs(
            mode: .normal, showGarageTab: showGarageTab, showRemindersTab: showRemindersTab
        )

        #expect(beforeSimpleMode == afterReturningToNormal)
        #expect(afterReturningToNormal == [.calculator, .stations, .reminders, .more])
    }

    // MARK: 6 & 7. Switching to Simple Mode while viewing a tab that becomes hidden redirects safely

    @Test("Viewing Garage, then switching to Simple Mode, redirects selection to Calculator")
    func resolvedSelection_fromGarage_switchingToSimple_redirectsToCalculator() {
        let simpleTabs = AppExperienceNavigation.visibleTabs(mode: .simple, showGarageTab: true, showRemindersTab: true)
        #expect(AppExperienceNavigation.resolvedSelection(current: .garage, visibleTabs: simpleTabs) == .calculator)
    }

    @Test("Viewing Reminders, then switching to Simple Mode, redirects selection to Calculator")
    func resolvedSelection_fromReminders_switchingToSimple_redirectsToCalculator() {
        let simpleTabs = AppExperienceNavigation.visibleTabs(mode: .simple, showGarageTab: true, showRemindersTab: true)
        #expect(AppExperienceNavigation.resolvedSelection(current: .reminders, visibleTabs: simpleTabs) == .calculator)
    }

    @Test("A tab that remains visible after a mode switch keeps its selection unchanged")
    func resolvedSelection_stillVisibleTab_isUnchanged() {
        let simpleTabs = AppExperienceNavigation.visibleTabs(mode: .simple, showGarageTab: true, showRemindersTab: true)
        #expect(AppExperienceNavigation.resolvedSelection(current: .stations, visibleTabs: simpleTabs) == .stations)
        #expect(AppExperienceNavigation.resolvedSelection(current: .more, visibleTabs: simpleTabs) == .more)
    }

    // MARK: 8. Calculator (the Automatic Pump Detection notification target) is always reachable

    @Test("Calculator is present in every mode / tab-preference combination")
    func visibleTabs_calculatorAlwaysPresent() {
        for mode in AppExperienceMode.allCases {
            for showGarage in [true, false] {
                for showReminders in [true, false] {
                    let tabs = AppExperienceNavigation.visibleTabs(
                        mode: mode, showGarageTab: showGarage, showRemindersTab: showReminders
                    )
                    #expect(tabs.contains(.calculator))
                }
            }
        }
    }

    @Test("A notification routing to Calculator always resolves to Calculator, in every mode")
    func resolvedSelection_calculatorNotificationRoute_alwaysSucceeds() {
        for mode in AppExperienceMode.allCases {
            let tabs = AppExperienceNavigation.visibleTabs(mode: mode, showGarageTab: true, showRemindersTab: true)
            #expect(AppExperienceNavigation.resolvedSelection(current: .calculator, visibleTabs: tabs) == .calculator)
        }
    }
}

//
//  PumpPollingTaskIDTests.swift
//  EightyFiveBlendsTests
//
//  Tests for CalculatorView.PumpPollingTaskID — the combined identity behind the foreground
//  pump-location-polling `.task(id:)` in CalculatorView.swift, and its pure decision rule
//  `shouldPoll(scenePhase:isActiveTab:)`, the exact guard that `.task(id:)` body uses, not a
//  duplicate reimplementation.
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//
//  2.3.2 public-release-readiness fix context: before this fix, CalculatorView's ~20s foreground
//  GPS poll restarted only on `scenePhase` changes (`.task(id: scenePhase)`), so it kept running
//  on every other tab too — SwiftUI's TabView keeps every child view mounted regardless of which
//  tab is selected. PumpPollingTaskID adds `isActiveTab` to the task's identity so leaving
//  Calculator for another tab is exactly as effective at stopping the loop as backgrounding the
//  app. Equatable's field-by-field comparison is what SwiftUI's `.task(id:)` relies on to decide
//  "did this change enough to cancel and restart" — the Equatable tests below exist because a
//  regression here (e.g. a hand-written Equatable that ignores a field) would silently defeat
//  the whole fix while still compiling and looking correct at the `.task(id:)` call site.
//

import Testing
import SwiftUI
@testable import EightyFiveBlends

struct PumpPollingTaskIDTests {

    // MARK: shouldPoll — the exact guard `.task(id:)`'s body uses

    @Test("Active scene phase and active tab: polling should run")
    func shouldPoll_activeAndActiveTab_isTrue() {
        #expect(PumpPollingTaskID.shouldPoll(scenePhase: .active, isActiveTab: true) == true)
    }

    @Test("Active scene phase but a different tab is selected: polling should NOT run — this is the exact 2.3.2 fix")
    func shouldPoll_activeButNotActiveTab_isFalse() {
        #expect(PumpPollingTaskID.shouldPoll(scenePhase: .active, isActiveTab: false) == false)
    }

    @Test("Calculator is the active tab, but the app is backgrounded or inactive: polling should NOT run")
    func shouldPoll_activeTabButNotForegrounded_isFalse() {
        #expect(PumpPollingTaskID.shouldPoll(scenePhase: .background, isActiveTab: true) == false)
        #expect(PumpPollingTaskID.shouldPoll(scenePhase: .inactive, isActiveTab: true) == false)
    }

    @Test("Neither condition favorable: polling should NOT run")
    func shouldPoll_neitherFavorable_isFalse() {
        #expect(PumpPollingTaskID.shouldPoll(scenePhase: .background, isActiveTab: false) == false)
    }

    // MARK: Equatable — what SwiftUI's .task(id:) actually keys its restart decision on

    @Test("Two identical task IDs are equal — .task(id:) must not restart the loop for an unrelated body re-evaluation")
    func equatable_identicalValues_areEqual() {
        let a = PumpPollingTaskID(scenePhase: .active, isActiveTab: true)
        let b = PumpPollingTaskID(scenePhase: .active, isActiveTab: true)
        #expect(a == b)
    }

    @Test("A scenePhase difference alone makes the task ID unequal — backgrounding must restart/cancel the loop")
    func equatable_differentScenePhase_areNotEqual() {
        let foreground = PumpPollingTaskID(scenePhase: .active, isActiveTab: true)
        let backgrounded = PumpPollingTaskID(scenePhase: .background, isActiveTab: true)
        #expect(foreground != backgrounded)
    }

    @Test("An isActiveTab difference alone makes the task ID unequal — switching tabs must restart/cancel the loop")
    func equatable_differentIsActiveTab_areNotEqual() {
        let onCalculatorTab = PumpPollingTaskID(scenePhase: .active, isActiveTab: true)
        let onAnotherTab = PumpPollingTaskID(scenePhase: .active, isActiveTab: false)
        #expect(onCalculatorTab != onAnotherTab)
    }
}

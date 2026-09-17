//
//  PendingPriceContributionStoreTests.swift
//  EightyFiveBlendsTests
//
//  Tests for PendingPriceContributionStore's persistence — the actual functions
//  StationsView/ContentView call, not a reimplementation. Each test constructs its own store
//  backed by an isolated UserDefaults suite (never `.standard`), mirroring
//  ReviewRequestManagerTests.swift's own isolation pattern, so these tests never race with each
//  other or with production state.
//

import Foundation
import Testing
@testable import EightyFiveBlends

@MainActor
struct PendingPriceContributionStoreTests {
    private func makeStore() -> PendingPriceContributionStore {
        let suiteName = "pending-price-contribution-store-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PendingPriceContributionStore(defaults: defaults)
    }

    private func makeContribution(
        stationKey: String = "shell|1 test st|testville|co|80000",
        stationName: String = "Shell",
        directionsOpenedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> PendingPriceContribution {
        PendingPriceContribution(
            stationKey: stationKey,
            stationName: stationName,
            streetAddress: "1 Test St",
            city: "Testville",
            state: "CO",
            zip: "80000",
            latitude: 39.0,
            longitude: -104.0,
            directionsOpenedAt: directionsOpenedAt,
            mapsProvider: "Apple Maps"
        )
    }

    @Test("record(_:) persists the contribution so current reflects it")
    func record_persistsContribution() {
        let store = makeStore()
        let contribution = makeContribution()

        store.record(contribution)

        #expect(store.current == contribution)
    }

    @Test("A second record(_:) replaces the first — never accumulates a history")
    func record_secondCallReplacesFirst() {
        let store = makeStore()
        store.record(makeContribution(stationKey: "first-station", stationName: "First"))
        let second = makeContribution(stationKey: "second-station", stationName: "Second")

        store.record(second)

        #expect(store.current == second)
        #expect(store.current?.stationName == "Second")
    }

    @Test("A fresh store instance pointed at the same UserDefaults suite reconstructs the pending contribution")
    func current_reconstructsAcrossSecondInstance() {
        let suiteName = "pending-price-contribution-store-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let contribution = makeContribution()

        let firstInstance = PendingPriceContributionStore(defaults: defaults)
        firstInstance.record(contribution)

        // Simulates "app relaunch" — a brand-new store object, never the same instance, reading
        // the same on-disk UserDefaults suite.
        let secondInstance = PendingPriceContributionStore(defaults: defaults)
        #expect(secondInstance.current == contribution)
    }

    @Test("clear() removes the persisted contribution")
    func clear_removesPersistedState() {
        let store = makeStore()
        store.record(makeContribution())
        #expect(store.current != nil)

        store.clear()

        #expect(store.current == nil)
    }

    @Test("clear() is safe to call when nothing is pending")
    func clear_safeWhenAlreadyEmpty() {
        let store = makeStore()
        store.clear()
        #expect(store.current == nil)
    }

    @Test("Corrupt persisted data fails closed to nil rather than crashing")
    func current_corruptDataFailsClosed() {
        let suiteName = "pending-price-contribution-store-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data("not valid JSON at all".utf8), forKey: AppPreferenceKey.pendingPriceContribution)
        let store = PendingPriceContributionStore(defaults: defaults)

        #expect(store.current == nil)
    }

    @Test("A store remains usable after encountering corrupt persisted data — no crash, no cascading failure")
    func store_remainsUsableAfterCorruptData() {
        let suiteName = "pending-price-contribution-store-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data("garbage".utf8), forKey: AppPreferenceKey.pendingPriceContribution)
        let store = PendingPriceContributionStore(defaults: defaults)
        #expect(store.current == nil)

        let contribution = makeContribution()
        store.record(contribution)

        #expect(store.current == contribution)
    }

    @Test("Every scalar station field survives an encode/decode round trip unchanged")
    func record_stationScalarDataSurvivesRoundTrip() {
        let store = makeStore()
        let contribution = PendingPriceContribution(
            stationKey: "mobil|6653 w mcdowell rd|phoenix|az|85035",
            stationName: "Mobil",
            streetAddress: "6653 W McDowell Rd",
            city: "Phoenix",
            state: "AZ",
            zip: "85035",
            latitude: 33.4622,
            longitude: -112.1866,
            directionsOpenedAt: Date(timeIntervalSince1970: 1_800_500_000),
            mapsProvider: "Waze"
        )

        store.record(contribution)
        let restored = store.current

        #expect(restored?.stationKey == contribution.stationKey)
        #expect(restored?.stationName == contribution.stationName)
        #expect(restored?.streetAddress == contribution.streetAddress)
        #expect(restored?.city == contribution.city)
        #expect(restored?.state == contribution.state)
        #expect(restored?.zip == contribution.zip)
        #expect(restored?.latitude == contribution.latitude)
        #expect(restored?.longitude == contribution.longitude)
        #expect(restored?.directionsOpenedAt == contribution.directionsOpenedAt)
        #expect(restored?.mapsProvider == contribution.mapsProvider)
    }

    @Test("Recording twice then clearing leaves no trace of either — a single slot, never a list")
    func store_neverAccumulatesHistory() {
        let store = makeStore()
        store.record(makeContribution(stationKey: "first-station", stationName: "First"))
        store.record(makeContribution(stationKey: "second-station", stationName: "Second"))
        store.clear()

        #expect(store.current == nil)
    }

    // MARK: - 6-hour expiration cleanup (pre-commit validation pass, Issue 8)

    @Test("An expired contribution, once evaluated and cleared by a caller, is physically removed from the underlying UserDefaults key — not merely nil from current")
    func clear_afterExpiration_physicallyRemovesUnderlyingKey() {
        let suiteName = "pending-price-contribution-store-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = PendingPriceContributionStore(defaults: defaults)
        let directionsOpenedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let contribution = makeContribution(directionsOpenedAt: directionsOpenedAt)

        store.record(contribution)
        #expect(defaults.data(forKey: AppPreferenceKey.pendingPriceContribution) != nil)

        // Mirrors ContentView.attemptPendingPriceContributionPromptIfNeeded()'s own
        // isExpired-then-clear sequence exactly (see ContentView.swift) — that is the one and
        // only caller responsible for actually discarding an expired contribution; the store
        // itself never self-expires anything (PendingPriceContributionEligibility.isExpired's
        // own doc comment says as much).
        let now = directionsOpenedAt.addingTimeInterval(PendingPriceContributionEligibility.maximumAge + 1)
        #expect(PendingPriceContributionEligibility.isExpired(contribution, now: now))

        if PendingPriceContributionEligibility.isExpired(contribution, now: now) {
            store.clear()
        }

        #expect(store.current == nil)
        // The stronger assertion this case actually calls for: the raw UserDefaults entry is
        // gone, not merely undecodable-so-nil — otherwise a stale, orphaned blob would sit on
        // disk forever even though every read of `current` already (and misleadingly) reports
        // nil.
        #expect(defaults.data(forKey: AppPreferenceKey.pendingPriceContribution) == nil)
    }

    @Test("Exactly at maximumAge, a contribution is not yet expired, so a caller never clears it")
    func isExpired_exactlyAtBoundary_isNotExpiredAndIsNotCleared() {
        let suiteName = "pending-price-contribution-store-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = PendingPriceContributionStore(defaults: defaults)
        let directionsOpenedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let contribution = makeContribution(directionsOpenedAt: directionsOpenedAt)
        store.record(contribution)

        let now = directionsOpenedAt.addingTimeInterval(PendingPriceContributionEligibility.maximumAge)
        #expect(PendingPriceContributionEligibility.isExpired(contribution, now: now) == false)

        // Confirms the inclusive/exclusive boundary documented on isExpired/isEligible is
        // honored end-to-end: a contribution exactly `maximumAge` old must still be sitting in
        // the store, untouched, since no caller would have had a reason to clear it.
        #expect(store.current == contribution)
        #expect(defaults.data(forKey: AppPreferenceKey.pendingPriceContribution) != nil)
    }
}

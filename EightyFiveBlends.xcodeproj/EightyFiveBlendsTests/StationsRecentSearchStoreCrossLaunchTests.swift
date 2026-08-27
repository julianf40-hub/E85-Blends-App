//
//  StationsRecentSearchStoreCrossLaunchTests.swift
//  EightyFiveBlendsTests
//
//  Tests for the PR #54 cross-launch disk-persistence tier of StationsRecentSearchStore — the
//  new persistSnapshotToDisk/restorePersistedSnapshotIfAvailable/persistedPreviewCompatibility/
//  discardRestoredSnapshot behavior layered on top of the existing, unchanged PR A/#48
//  session-cache semantics (compatibleSnapshot itself is not re-tested here — see this file's
//  existing coverage precedent, e.g. CommunityPriceEligibilityTests.swift, for that style of
//  pure-logic test; this file is scoped to what PR #54 actually added).
//
//  Note: like every other file in this directory, this is not currently wired into a test
//  target in project.pbxproj (see CLAUDE.md) — `xcodebuild test` will not run these until a
//  test target is added. Written to compile and pass once one exists.
//
//  Every test below constructs its own StationsRecentSearchStore against a private, unique
//  temporary-directory file (StationsRecentSearchStore.init(persistenceURL:), added by PR #54
//  specifically for this) — never the app's real Caches directory.
//

import CoreLocation
import Foundation
import Testing
@testable import EightyFiveBlends

// StationsRecentSearchStore is @MainActor (see its own declaration) — every test below
// constructs and calls it synchronously, so the suite itself is annotated @MainActor rather
// than decorating each individual @Test function. This is semantically correct (the suite
// exclusively exercises a @MainActor-isolated store) and lets Swift Testing dispatch every
// test method onto the main actor at runtime with no `await`/Task/MainActor.assumeIsolated
// workaround needed at any call site.
@MainActor
struct StationsRecentSearchStoreCrossLaunchTests {

    // MARK: - Test helpers

    private static func temporarySnapshotURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stations-cache-test-\(UUID().uuidString).json")
    }

    private static func sampleStation(
        name: String = "Test E85 Station",
        latitude: Double = 33.4484,
        longitude: Double = -112.0740,
        distanceMiles: Double = 3.2
    ) -> LiveFuelStation {
        LiveFuelStation(
            name: name,
            address: "123 Main St",
            city: "Phoenix",
            state: "AZ",
            zip: "85001",
            latitude: latitude,
            longitude: longitude,
            distanceMiles: distanceMiles,
            phone: "555-1234",
            accessHours: "24 hours daily",
            dateLastConfirmed: "2026-01-01",
            fuelTypeCode: "E85"
        )
    }

    // MARK: A/M. Persisted DTO round-trip, including search-center rounding

    @Test("A successful current-location result persists to disk and restores in a new store instance with matching station data and an approximately-rounded search center")
    func roundTrip_persistsAndRestores() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = StationsRecentSearchStore(persistenceURL: url)
        let originalCenter = StationCoordinate(latitude: 33.123456789, longitude: -112.987654321)
        writer.recordCurrentLocationSearchResult(
            stations: [Self.sampleStation()],
            center: originalCenter,
            radiusMiles: 25,
            fetchedAt: .now
        )

        // A fresh store instance pointed at the SAME file simulates a cold relaunch.
        let reader = StationsRecentSearchStore(persistenceURL: url)

        #expect(reader.snapshotOrigin == .restoredFromDisk)
        #expect(reader.snapshot?.stations.count == 1)
        #expect(reader.snapshot?.stations.first?.name == "Test E85 Station")
        #expect(reader.snapshot?.stations.first?.city == "Phoenix")
        #expect(reader.snapshot?.radiusMiles == 25)

        // Section 10 — rounded to ~3 decimal places (up to ~0.0005 of rounding error), never
        // stored at full GPS precision.
        let restoredCenter = reader.snapshot?.center
        #expect(restoredCenter != nil)
        if let restoredCenter {
            #expect(abs(restoredCenter.latitude - originalCenter.latitude) < 0.001)
            #expect(abs(restoredCenter.longitude - originalCenter.longitude) < 0.001)
            #expect(restoredCenter.latitude == 33.123)
            #expect(restoredCenter.longitude == -112.988)
        }
    }

    // MARK: B. Ephemeral LiveFuelStation UUID is not persisted

    @Test("A restored station is reconstructed with a fresh id, never the original in-memory station's ephemeral UUID")
    func roundTrip_restoredStationGetsFreshIdentity() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let original = Self.sampleStation()
        let writer = StationsRecentSearchStore(persistenceURL: url)
        writer.recordCurrentLocationSearchResult(
            stations: [original],
            center: StationCoordinate(latitude: 33.0, longitude: -112.0),
            radiusMiles: 25,
            fetchedAt: .now
        )

        let reader = StationsRecentSearchStore(persistenceURL: url)
        let restored = reader.snapshot?.stations.first

        #expect(restored != nil)
        if let restored {
            #expect(restored.id != original.id)
            #expect(restored.name == original.name)
        }
    }

    // MARK: L. Successful empty result round-trips correctly (never confused with a failure)

    @Test("A successful empty-array current-location result persists and restores as a valid, empty (not missing) snapshot")
    func roundTrip_emptyResultPersistsIntentionally() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = StationsRecentSearchStore(persistenceURL: url)
        writer.recordCurrentLocationSearchResult(
            stations: [],
            center: StationCoordinate(latitude: 33.0, longitude: -112.0),
            radiusMiles: 25,
            fetchedAt: .now
        )

        let reader = StationsRecentSearchStore(persistenceURL: url)
        #expect(reader.snapshotOrigin == .restoredFromDisk)
        #expect(reader.snapshot != nil)
        #expect(reader.snapshot?.stations.isEmpty == true)
    }

    // MARK: C/D. Exact radius match required

    @Test("persistedPreviewCompatibility validates an exact radius match")
    func persistedPreviewCompatibility_exactRadiusMatch_isEligible() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = StationsRecentSearchStore(persistenceURL: url)
        let center = StationCoordinate(latitude: 33.0, longitude: -112.0)
        writer.recordCurrentLocationSearchResult(stations: [Self.sampleStation()], center: center, radiusMiles: 25, fetchedAt: .now)

        let reader = StationsRecentSearchStore(persistenceURL: url)
        let result = reader.persistedPreviewCompatibility(near: center, radiusMiles: 25)
        guard case .validated = result else {
            Issue.record("Expected .validated for an exact radius + matching coordinate, got \(result)")
            return
        }
    }

    @Test("persistedPreviewCompatibility rejects a mismatched radius, never treating a 25mi snapshot as a 50mi one")
    func persistedPreviewCompatibility_wrongRadius_isUnavailable() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = StationsRecentSearchStore(persistenceURL: url)
        let center = StationCoordinate(latitude: 33.0, longitude: -112.0)
        writer.recordCurrentLocationSearchResult(stations: [Self.sampleStation()], center: center, radiusMiles: 25, fetchedAt: .now)

        let reader = StationsRecentSearchStore(persistenceURL: url)
        #expect(reader.persistedPreviewCompatibility(near: center, radiusMiles: 50) == .unavailable)
    }

    // MARK: E/F. 24h preview ceiling

    @Test("A persisted snapshot at just under the 24h ceiling is restored and available")
    func restore_underCeiling_isAvailable() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = StationsRecentSearchStore(persistenceURL: url)
        let center = StationCoordinate(latitude: 33.0, longitude: -112.0)
        writer.recordCurrentLocationSearchResult(
            stations: [Self.sampleStation()],
            center: center,
            radiusMiles: 25,
            fetchedAt: Date.now.addingTimeInterval(-23 * 60 * 60)
        )

        let reader = StationsRecentSearchStore(persistenceURL: url)
        #expect(reader.snapshotOrigin == .restoredFromDisk)
        #expect(reader.snapshot != nil)
    }

    @Test("A persisted snapshot older than the 24h ceiling is never restored, and the stale file is removed")
    func restore_overCeiling_isRejectedAndFileRemoved() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = StationsRecentSearchStore(persistenceURL: url)
        writer.recordCurrentLocationSearchResult(
            stations: [Self.sampleStation()],
            center: StationCoordinate(latitude: 33.0, longitude: -112.0),
            radiusMiles: 25,
            fetchedAt: Date.now.addingTimeInterval(-25 * 60 * 60)
        )
        #expect(FileManager.default.fileExists(atPath: url.path))

        let reader = StationsRecentSearchStore(persistenceURL: url)
        #expect(reader.snapshot == nil)
        #expect(reader.snapshotOrigin == nil)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    // MARK: G/H/I. Coordinate validation outcomes

    @Test("A current coordinate matching the persisted search center validates the preview")
    func persistedPreviewCompatibility_matchingCoordinate_isValidated() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let center = StationCoordinate(latitude: 33.4484, longitude: -112.0740)
        let writer = StationsRecentSearchStore(persistenceURL: url)
        writer.recordCurrentLocationSearchResult(stations: [Self.sampleStation()], center: center, radiusMiles: 25, fetchedAt: .now)

        let reader = StationsRecentSearchStore(persistenceURL: url)
        let result = reader.persistedPreviewCompatibility(near: center, radiusMiles: 25)
        guard case .validated = result else {
            Issue.record("Expected .validated, got \(result)")
            return
        }
    }

    @Test("A materially different current coordinate (Phoenix vs. Los Angeles) is reported as incompatibleLocation, never displayed")
    func persistedPreviewCompatibility_movedFarAway_isIncompatible() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let phoenix = StationCoordinate(latitude: 33.4484, longitude: -112.0740)
        let losAngeles = StationCoordinate(latitude: 34.0522, longitude: -118.2437)

        let writer = StationsRecentSearchStore(persistenceURL: url)
        writer.recordCurrentLocationSearchResult(stations: [Self.sampleStation()], center: phoenix, radiusMiles: 25, fetchedAt: .now)

        let reader = StationsRecentSearchStore(persistenceURL: url)
        #expect(reader.persistedPreviewCompatibility(near: losAngeles, radiusMiles: 25) == .incompatibleLocation)
    }

    @Test("No current coordinate yet reports the preview as provisional, not validated and not unavailable")
    func persistedPreviewCompatibility_noCoordinateYet_isProvisional() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = StationsRecentSearchStore(persistenceURL: url)
        writer.recordCurrentLocationSearchResult(
            stations: [Self.sampleStation()],
            center: StationCoordinate(latitude: 33.0, longitude: -112.0),
            radiusMiles: 25,
            fetchedAt: .now
        )

        let reader = StationsRecentSearchStore(persistenceURL: url)
        let result = reader.persistedPreviewCompatibility(near: nil, radiusMiles: 25)
        guard case .provisional = result else {
            Issue.record("Expected .provisional for a nil coordinate, got \(result)")
            return
        }
    }

    // MARK: J. Corrupted file cannot crash and is safely ignored

    @Test("A corrupted persisted cache file never crashes store initialization and is treated as no cache, and the corrupt file is removed")
    func restore_corruptedFile_isSafelyIgnored() throws {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not valid JSON at all {{{".utf8).write(to: url)

        let reader = StationsRecentSearchStore(persistenceURL: url)
        #expect(reader.snapshot == nil)
        #expect(reader.snapshotOrigin == nil)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    // MARK: K. Unknown/unsupported schema version is safely ignored

    @Test("An unsupported schemaVersion in an otherwise well-formed file is never restored, and the file is removed")
    func restore_unsupportedSchemaVersion_isSafelyIgnored() throws {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Mirrors PersistedStationsSearchSnapshot's on-disk shape (that type itself is private
        // to StationsRecentSearchStore.swift, so this reconstructs the JSON directly) with a
        // schemaVersion this build does not support.
        let json = """
        {
            "schemaVersion": 999,
            "stations": [],
            "centerLatitude": 33.0,
            "centerLongitude": -112.0,
            "radiusMiles": 25,
            "fetchedAt": \(Date.now.timeIntervalSinceReferenceDate)
        }
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)

        let reader = StationsRecentSearchStore(persistenceURL: url)
        #expect(reader.snapshot == nil)
        #expect(reader.snapshotOrigin == nil)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    // MARK: N. A current-session record is never mistaken for a restored preview

    @Test("recordCurrentLocationSearchResult marks the snapshot origin as currentSession, and persistedPreviewCompatibility never treats a current-session snapshot as a restorable preview")
    func recordCurrentLocationSearchResult_marksCurrentSessionOrigin() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = StationsRecentSearchStore(persistenceURL: url)
        let center = StationCoordinate(latitude: 33.0, longitude: -112.0)
        store.recordCurrentLocationSearchResult(stations: [Self.sampleStation()], center: center, radiusMiles: 25, fetchedAt: .now)

        #expect(store.snapshotOrigin == .currentSession)
        #expect(store.persistedPreviewCompatibility(near: center, radiusMiles: 25) == .unavailable)
    }

    // MARK: Section 30 — discardRestoredSnapshot never touches a current-session snapshot

    @Test("discardRestoredSnapshot() is a no-op against a current-session snapshot — only a snapshot actually restored from disk this launch may be discarded")
    func discardRestoredSnapshot_neverTouchesCurrentSessionSnapshot() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = StationsRecentSearchStore(persistenceURL: url)
        store.recordCurrentLocationSearchResult(
            stations: [Self.sampleStation()],
            center: StationCoordinate(latitude: 33.0, longitude: -112.0),
            radiusMiles: 25,
            fetchedAt: .now
        )

        store.discardRestoredSnapshot()

        #expect(store.snapshot != nil)
        #expect(store.snapshotOrigin == .currentSession)
        // The just-written disk file must also survive — discardRestoredSnapshot() guarded out
        // before ever reaching removePersistedSnapshotFile().
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("discardRestoredSnapshot() clears a genuinely disk-restored snapshot from both memory and disk")
    func discardRestoredSnapshot_clearsRestoredSnapshot() {
        let url = Self.temporarySnapshotURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = StationsRecentSearchStore(persistenceURL: url)
        writer.recordCurrentLocationSearchResult(
            stations: [Self.sampleStation()],
            center: StationCoordinate(latitude: 33.0, longitude: -112.0),
            radiusMiles: 25,
            fetchedAt: .now
        )

        let reader = StationsRecentSearchStore(persistenceURL: url)
        #expect(reader.snapshot != nil)

        reader.discardRestoredSnapshot()

        #expect(reader.snapshot == nil)
        #expect(reader.snapshotOrigin == nil)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    // MARK: Missing file — the ordinary first-ever-launch case

    @Test("A store pointed at a file that doesn't exist yet starts with no snapshot and never crashes")
    func restore_missingFile_startsEmpty() {
        let url = Self.temporarySnapshotURL()
        // Deliberately never written to.
        let store = StationsRecentSearchStore(persistenceURL: url)
        #expect(store.snapshot == nil)
        #expect(store.snapshotOrigin == nil)
    }
}

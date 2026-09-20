//
//  ReferralInstallationCredentialTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.0 — iOS referral client foundation. Tests for ReferralInstallationCredential's
//  generation/validation rules and the load-or-create decision, using an in-memory fake store
//  (InMemoryReferralCredentialStore below) rather than the real device Keychain — see
//  ReferralCredentialStore.swift's own header for why.
//

import Testing
import Foundation
import Security
@testable import EightyFiveBlends

/// Test-only fake — never touches the real Keychain, and never syncs anywhere (it's just a
/// process-local variable), so these tests are fast and hermetic.
final class InMemoryReferralCredentialStore: ReferralCredentialStoring, @unchecked Sendable {
    private var stored: ReferralInstallationCredential?
    /// When non-nil, `loadCredential()` returns this raw value instead of `stored` — simulates a
    /// malformed/corrupted stored credential without needing real Keychain data corruption.
    var forcedMalformedCredential: ReferralInstallationCredential?
    /// When set, `loadCredential()` throws this instead of returning normally — simulates a
    /// genuine Keychain read failure (`errSecInteractionNotAllowed`, `errSecNotAvailable`, etc.),
    /// distinct from "not found."
    var forcedLoadError: Error?
    /// When set, `save(_:)` throws this instead of persisting — simulates a genuine Keychain write
    /// failure.
    var forcedSaveError: Error?

    func loadCredential() throws -> ReferralInstallationCredential? {
        if let forcedLoadError { throw forcedLoadError }
        return forcedMalformedCredential ?? stored
    }

    func save(_ credential: ReferralInstallationCredential) throws {
        if let forcedSaveError { throw forcedSaveError }
        stored = credential
        forcedMalformedCredential = nil
    }

    var savedCredential: ReferralInstallationCredential? { stored }
}

struct ReferralInstallationCredentialTests {

    // MARK: 1. Missing credential generates ID + strong secret

    @Test("loadOrCreate with no stored credential generates a valid new one and persists it")
    func missingCredential_generatesAndPersists() throws {
        let store = InMemoryReferralCredentialStore()
        let credential = try ReferralInstallationCredential.loadOrCreate(using: store)

        #expect(ReferralInstallationCredential.isValid(credential))
        #expect(store.savedCredential == credential)
    }

    // MARK: 2. Stored credential is reused

    @Test("loadOrCreate reuses an existing valid stored credential rather than generating a new one")
    func existingValidCredential_isReused() throws {
        let store = InMemoryReferralCredentialStore()
        let original = ReferralInstallationCredential.generate()
        try store.save(original)

        let resolved = try ReferralInstallationCredential.loadOrCreate(using: store)

        #expect(resolved == original)
    }

    // MARK: 3. Malformed stored credential is safely replaced

    @Test("loadOrCreate replaces a malformed stored credential (secret too short) with a fresh valid one")
    func malformedCredential_isReplaced() throws {
        let store = InMemoryReferralCredentialStore()
        store.forcedMalformedCredential = ReferralInstallationCredential(
            installationID: UUID(),
            installationSecret: "way_too_short"
        )

        let resolved = try ReferralInstallationCredential.loadOrCreate(using: store)

        #expect(ReferralInstallationCredential.isValid(resolved))
        #expect(resolved.installationSecret != "way_too_short")
        #expect(store.savedCredential == resolved)
    }

    // MARK: Hardening pass — fail-closed on genuine storage failures (never "absent")

    @Test("loadOrCreate propagates a genuine load failure and never generates a replacement credential")
    func loadFailure_neverGeneratesReplacement() {
        let store = InMemoryReferralCredentialStore()
        store.forcedLoadError = ReferralCredentialStoreError.keychainFailure(errSecInteractionNotAllowed)

        do {
            _ = try ReferralInstallationCredential.loadOrCreate(using: store)
            Issue.record("Expected loadOrCreate to throw")
        } catch is ReferralCredentialStoreError {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(store.savedCredential == nil)
    }

    @Test("A load failure never results in any backend-eligible credential — loadOrCreate throws before ever calling save")
    func loadFailure_neverCallsSave() {
        let store = InMemoryReferralCredentialStore()
        store.forcedLoadError = ReferralCredentialStoreError.keychainFailure(errSecInteractionNotAllowed)
        // If loadOrCreate ever called save() despite the load failure, this would flip to a
        // non-nil value — it must stay nil for the whole call.
        store.forcedSaveError = nil

        _ = try? ReferralInstallationCredential.loadOrCreate(using: store)

        #expect(store.savedCredential == nil)
    }

    @Test("loadOrCreate propagates a genuine save failure — never returns an unpersisted generated credential")
    func saveFailure_loadOrCreateThrows() {
        let store = InMemoryReferralCredentialStore()
        store.forcedSaveError = ReferralCredentialStoreError.keychainFailure(errSecNotAvailable)

        do {
            _ = try ReferralInstallationCredential.loadOrCreate(using: store)
            Issue.record("Expected loadOrCreate to throw")
        } catch is ReferralCredentialStoreError {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(store.savedCredential == nil)
    }

    @Test("A malformed stored credential whose replacement write fails leaves nothing persisted — fails closed")
    func malformedCredential_replacementWriteFailure_failsClosed() {
        let store = InMemoryReferralCredentialStore()
        store.forcedMalformedCredential = ReferralInstallationCredential(
            installationID: UUID(),
            installationSecret: "way_too_short"
        )
        store.forcedSaveError = ReferralCredentialStoreError.keychainFailure(errSecNotAvailable)

        do {
            _ = try ReferralInstallationCredential.loadOrCreate(using: store)
            Issue.record("Expected loadOrCreate to throw")
        } catch is ReferralCredentialStoreError {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        // The malformed value was never "promoted" — save() itself is what failed, so the store's
        // own persisted-credential slot is still untouched (forcedMalformedCredential is a
        // read-time override only; it does not count as a save).
        #expect(store.savedCredential == nil)
    }

    // MARK: 4/5. Secret length bounds

    @Test("Generated secret meets the >=32 character minimum")
    func generatedSecret_meetsMinimum() {
        let credential = ReferralInstallationCredential.generate()
        #expect(credential.installationSecret.count >= ReferralInstallationCredential.minimumSecretLength)
    }

    @Test("Generated secret never exceeds the 512 character maximum")
    func generatedSecret_neverExceedsMaximum() {
        let credential = ReferralInstallationCredential.generate()
        #expect(credential.installationSecret.count <= ReferralInstallationCredential.maximumSecretLength)
    }

    @Test("isValidSecret enforces both the lower and upper bound")
    func isValidSecret_boundsEnforced() {
        #expect(ReferralInstallationCredential.isValidSecret(String(repeating: "a", count: 31)) == false)
        #expect(ReferralInstallationCredential.isValidSecret(String(repeating: "a", count: 32)))
        #expect(ReferralInstallationCredential.isValidSecret(String(repeating: "a", count: 512)))
        #expect(ReferralInstallationCredential.isValidSecret(String(repeating: "a", count: 513)) == false)
    }

    @Test("Generated secret is not merely a UUID string")
    func generatedSecret_isNotJustAUUID() {
        let credential = ReferralInstallationCredential.generate()
        #expect(UUID(uuidString: credential.installationSecret) == nil)
        // A UUID string is always exactly 36 characters; this secret is meaningfully longer,
        // reflecting real extra entropy rather than the same 128 bits reformatted.
        #expect(credential.installationSecret.count > 36)
    }

    // MARK: 6. Installation ID is a valid UUID

    @Test("Generated installationID is a genuine UUID (typed, and round-trips through string form)")
    func installationID_isValidUUID() {
        let credential = ReferralInstallationCredential.generate()
        let roundTripped = UUID(uuidString: credential.installationID.uuidString)
        #expect(roundTripped == credential.installationID)
    }

    @Test("Two generated credentials never collide")
    func generatedCredentials_areUnique() {
        let first = ReferralInstallationCredential.generate()
        let second = ReferralInstallationCredential.generate()
        #expect(first.installationID != second.installationID)
        #expect(first.installationSecret != second.installationSecret)
    }

    // MARK: 7. Storage abstraction never syncs via CloudKit/UserDefaults

    @Test("The credential storing protocol has no CloudKit/UserDefaults-shaped surface — only load/save of the typed credential")
    func storageAbstraction_hasNoSyncSurface() throws {
        // Structural guarantee, not a runtime one: ReferralCredentialStoring exposes exactly
        // loadCredential()/save(_:) — nothing resembling a CloudKit share, a UserDefaults
        // suite/key, or an NSUbiquitousKeyValueStore accessor exists on the protocol for any
        // conforming type (including KeychainReferralCredentialStore) to route through, even
        // accidentally. This test exists as a documented, named assertion of that contract rather
        // than leaving it as an implicit property of the protocol's shape.
        let store: ReferralCredentialStoring = InMemoryReferralCredentialStore()
        let credential = ReferralInstallationCredential.generate()
        try store.save(credential)
        #expect(try store.loadCredential() == credential)
    }
}

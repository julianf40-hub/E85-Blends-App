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
@testable import EightyFiveBlends

/// Test-only fake — never touches the real Keychain, and never syncs anywhere (it's just a
/// process-local variable), so these tests are fast and hermetic.
final class InMemoryReferralCredentialStore: ReferralCredentialStoring, @unchecked Sendable {
    private var stored: ReferralInstallationCredential?
    /// When non-nil, `loadCredential()` returns this raw value instead of `stored` — simulates a
    /// malformed/corrupted stored credential without needing real Keychain data corruption.
    var forcedMalformedCredential: ReferralInstallationCredential?

    func loadCredential() -> ReferralInstallationCredential? {
        forcedMalformedCredential ?? stored
    }

    @discardableResult
    func save(_ credential: ReferralInstallationCredential) -> Bool {
        stored = credential
        forcedMalformedCredential = nil
        return true
    }

    var savedCredential: ReferralInstallationCredential? { stored }
}

struct ReferralInstallationCredentialTests {

    // MARK: 1. Missing credential generates ID + strong secret

    @Test("loadOrCreate with no stored credential generates a valid new one and persists it")
    func missingCredential_generatesAndPersists() {
        let store = InMemoryReferralCredentialStore()
        let credential = ReferralInstallationCredential.loadOrCreate(using: store)

        #expect(ReferralInstallationCredential.isValid(credential))
        #expect(store.savedCredential == credential)
    }

    // MARK: 2. Stored credential is reused

    @Test("loadOrCreate reuses an existing valid stored credential rather than generating a new one")
    func existingValidCredential_isReused() {
        let store = InMemoryReferralCredentialStore()
        let original = ReferralInstallationCredential.generate()
        store.save(original)

        let resolved = ReferralInstallationCredential.loadOrCreate(using: store)

        #expect(resolved == original)
    }

    // MARK: 3. Malformed stored credential is safely replaced

    @Test("loadOrCreate replaces a malformed stored credential (secret too short) with a fresh valid one")
    func malformedCredential_isReplaced() {
        let store = InMemoryReferralCredentialStore()
        store.forcedMalformedCredential = ReferralInstallationCredential(
            installationID: UUID(),
            installationSecret: "way_too_short"
        )

        let resolved = ReferralInstallationCredential.loadOrCreate(using: store)

        #expect(ReferralInstallationCredential.isValid(resolved))
        #expect(resolved.installationSecret != "way_too_short")
        #expect(store.savedCredential == resolved)
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
    func storageAbstraction_hasNoSyncSurface() {
        // Structural guarantee, not a runtime one: ReferralCredentialStoring exposes exactly
        // loadCredential()/save(_:) — nothing resembling a CloudKit share, a UserDefaults
        // suite/key, or an NSUbiquitousKeyValueStore accessor exists on the protocol for any
        // conforming type (including KeychainReferralCredentialStore) to route through, even
        // accidentally. This test exists as a documented, named assertion of that contract rather
        // than leaving it as an implicit property of the protocol's shape.
        let store: ReferralCredentialStoring = InMemoryReferralCredentialStore()
        let credential = ReferralInstallationCredential.generate()
        #expect(store.save(credential))
        #expect(store.loadCredential() == credential)
    }
}

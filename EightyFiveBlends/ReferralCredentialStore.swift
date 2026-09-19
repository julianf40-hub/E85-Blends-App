//
//  ReferralCredentialStore.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — iOS referral client foundation. Keychain-backed persistence for
//  ReferralInstallationCredential — device-only, never iCloud Keychain, never UserDefaults, never
//  SwiftData/CloudKit. `ReferralCredentialStoring` exists so this is unit-testable without the
//  real device Keychain (Keychain APIs behave unreliably/unavailable in the Simulator's test host
//  in some configurations, and tests must never depend on real Keychain state persisting or being
//  cleaned up between runs) — see ReferralInstallationCredentialTests.swift's in-memory fake.
//
//  Accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly — readable as soon as the
//  device has been unlocked once since boot (so a background bootstrap attempt, e.g. from a
//  background app refresh, isn't blocked on the device being unlocked AT THAT MOMENT the way
//  `WhenUnlocked` would be), while `ThisDeviceOnly` guarantees it never migrates via an encrypted
//  device backup/restore to a different device and is never eligible for iCloud Keychain
//  synchronization — no `kSecAttrSynchronizable` is ever set (its absence already means "not
//  synchronized"; this is not merely relying on a default, `ThisDeviceOnly` accessibility classes
//  are structurally excluded from iCloud Keychain sync regardless).
//
//  CORRECTNESS HARDENING PASS (2.4.0): both methods now THROW instead of collapsing every failure
//  into "absent"/`false`. `loadCredential()` distinguishes exactly three outcomes —
//  `errSecItemNotFound` (genuinely nil, safe to treat as "no credential yet"), a decodable item
//  (returned normally, malformed-or-not — see ReferralInstallationCredential.isValid), and ANY
//  other OSStatus (`errSecInteractionNotAllowed`, `errSecNotAvailable`, etc. — thrown as
//  `ReferralCredentialStoreError.keychainFailure`, NEVER treated as absence). Conflating a
//  transient Keychain failure with "absent" would let `loadOrCreate` generate a brand-new
//  identity while the device's real one is simply unreadable this instant — silently forking the
//  referral participant record. `save(_:)` throws the same way on any write failure, and never
//  logs Keychain item contents or the raw OSStatus beyond this internal error value.
//

import Foundation
import Security

/// Internal diagnostics only — see this file's header. Never surfaced to any future UI in this
/// raw form; a future UI's error projection should treat this the same as
/// `ReferralUserFacingError.temporarilyUnavailable` (see `ReferralServiceError.credentialUnavailable`).
enum ReferralCredentialStoreError: Error, Equatable, Sendable {
    case keychainFailure(OSStatus)
}

protocol ReferralCredentialStoring: Sendable {
    /// `nil` means genuinely absent (`errSecItemNotFound`) — safe to generate a new credential.
    /// A thrown error means the Keychain could not be read right now for some OTHER reason and
    /// MUST NOT be treated as absence (see this file's header).
    func loadCredential() throws -> ReferralInstallationCredential?
    func save(_ credential: ReferralInstallationCredential) throws
}

struct KeychainReferralCredentialStore: ReferralCredentialStoring {
    private static let service = "com.e85blends.app.referral.installation"
    private static let account = "installationCredential"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func loadCredential() throws -> ReferralInstallationCredential? {
        var query = Self.baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            // A successfully-read item that isn't decodable Data, or whose bytes don't decode as
            // a StoredCredential, is content-level corruption, not a Keychain-operation failure —
            // the read itself already succeeded, so there is no "real" credential being hidden by
            // a transient error here. Treated the same as "absent" (nil), which lets
            // `loadOrCreate` safely replace it, exactly like an out-of-bounds secret already does.
            guard let data = item as? Data else { return nil }
            return try? JSONDecoder().decode(StoredCredential.self, from: data).credential
        case errSecItemNotFound:
            return nil
        default:
            throw ReferralCredentialStoreError.keychainFailure(status)
        }
    }

    func save(_ credential: ReferralInstallationCredential) throws {
        let data = try JSONEncoder().encode(StoredCredential(credential))

        // Update-first, add-on-not-found: never delete an existing item before knowing the
        // replacement can actually be written (see this file's header) — a delete-then-add could
        // leave the Keychain holding NEITHER the old nor the new credential if the add step then
        // failed, which a plain SecItemUpdate cannot do (it only ever touches the existing item on
        // success, or leaves it untouched on failure).
        let updateStatus = SecItemUpdate(
            Self.baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw ReferralCredentialStoreError.keychainFailure(updateStatus)
        }

        var addQuery = Self.baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ReferralCredentialStoreError.keychainFailure(addStatus)
        }
    }
}

/// Wire shape actually stored in the Keychain item's data blob — kept distinct from
/// ReferralInstallationCredential itself so this file owns the on-disk encoding independently of
/// that type ever changing shape.
private struct StoredCredential: Codable {
    let installationID: UUID
    let installationSecret: String

    init(_ credential: ReferralInstallationCredential) {
        installationID = credential.installationID
        installationSecret = credential.installationSecret
    }

    var credential: ReferralInstallationCredential {
        ReferralInstallationCredential(installationID: installationID, installationSecret: installationSecret)
    }
}

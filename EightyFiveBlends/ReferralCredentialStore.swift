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

import Foundation
import Security

protocol ReferralCredentialStoring: Sendable {
    func loadCredential() -> ReferralInstallationCredential?
    @discardableResult
    func save(_ credential: ReferralInstallationCredential) -> Bool
}

struct KeychainReferralCredentialStore: ReferralCredentialStoring {
    private static let service = "com.e85blends.app.referral.installation"
    private static let account = "installationCredential"

    func loadCredential() -> ReferralInstallationCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }

        return try? JSONDecoder().decode(StoredCredential.self, from: data).credential
    }

    @discardableResult
    func save(_ credential: ReferralInstallationCredential) -> Bool {
        guard let data = try? JSONEncoder().encode(StoredCredential(credential)) else { return false }

        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]

        // Delete-then-add rather than SecItemUpdate: this is a single, small credential written
        // only at generation time (see ReferralInstallationCredential.loadOrCreate) — never a hot
        // write path — so the simplicity of one code path handling both "first write" and
        // "malformed value being replaced" outweighs the marginal cost of a delete + add.
        SecItemDelete(matchQuery as CFDictionary)

        var addQuery = matchQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
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

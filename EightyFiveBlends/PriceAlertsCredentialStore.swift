//
//  PriceAlertsCredentialStore.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). The installation credential that
//  authenticates this install to supabase/functions/price-alerts-api, and its Keychain persistence.
//
//  WHY THIS IS NOT THE REFERRAL CREDENTIAL. ReferralCredentialStore / ReferralInstallationCredential
//  solve the same problem for referral-api and this file follows their rules to the letter, but it
//  keeps its OWN Keychain item. The two backends hold independent installation tables, and the
//  recovery for a Price Alerts credential the server rejects is to mint a new one — an operation that
//  must never be able to fork the referral identity (or the other way round).
//
//  WHAT THE BACKEND REQUIRES (price-alerts-api `validateInstallationCredentials`): a UUID and a
//  secret of 32–512 characters. The CLIENT generates both; the server stores only sha256(secret) and
//  can neither return nor reset it. A lost secret is unrecoverable by design — the only way forward
//  is a new installation.
//
//  STORAGE RULES (all enforced by KeychainPriceAlertsCredentialStore and unit-tested through
//  `KeychainItemAccessing`, so no test touches the real Keychain):
//    - One generic-password item holding id AND secret together, so there is no half-written state
//      ("id without secret").
//    - kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: readable once the device has been unlocked
//      since boot (a background launch is not blocked), never restored to another device from a
//      backup, never eligible for iCloud Keychain. kSecAttrSynchronizable is never set.
//    - Never UserDefaults, SwiftData/CloudKit, a file or a log.
//    - A genuine Keychain failure THROWS. Only `errSecItemNotFound` (and an item whose bytes do not
//      decode, which is content-level corruption of an item that read fine) mean "absent". Treating a
//      transient failure as absence would mint a second identity while the real one is merely
//      unreadable this instant — duplicate installations.
//    - Update-first, add-on-not-found: an existing item is never deleted before its replacement is
//      known to be writable.
//
//  The secret appears in no description, debug description, mirror or error value.
//

import Foundation
import Security

// MARK: - Credential

nonisolated struct PriceAlertsInstallationCredential: Equatable, Sendable {
    /// price-alerts-api's own bounds on `installation_secret`.
    static let minimumSecretLength = 32
    static let maximumSecretLength = 512
    /// 48 random bytes (384 bits) → exactly 64 base64url characters.
    private static let secretByteCount = 48

    let installationID: UUID
    let installationSecret: String

    /// The id exactly as it goes on the wire. The backend lower-cases what it receives; sending it
    /// lower-case keeps what we log-free-compare against its responses identical.
    var wireInstallationID: String {
        installationID.uuidString.lowercased()
    }

    /// A secret the backend would accept AND whose JavaScript `.length` equals its Swift length:
    /// printable ASCII only (so no whitespace for the server's `trim()` to alter, and one byte per
    /// character), within the backend's length bounds.
    var isValid: Bool {
        let bytes = installationSecret.utf8
        guard (Self.minimumSecretLength...Self.maximumSecretLength).contains(bytes.count) else {
            return false
        }
        return bytes.allSatisfy { (0x21...0x7E).contains($0) }
    }

    /// A fresh identity: a random (version-4) UUID — which satisfies the backend's UUID pattern — and
    /// a secret drawn from the system CSPRNG. `SystemRandomNumberGenerator` is cryptographically
    /// secure on every platform and cannot fail, so there is no weaker fallback path to review.
    static func generate() -> PriceAlertsInstallationCredential {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<secretByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return PriceAlertsInstallationCredential(
            installationID: UUID(),
            installationSecret: base64URLEncoded(Data(bytes))
        )
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Every description/mirror path is redacted, so an accidental `print`, `dump`, `String(describing:)`,
/// interpolation — or one of a value that contains a credential — cannot put the secret in a log.
extension PriceAlertsInstallationCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "PriceAlertsInstallationCredential(<redacted>)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

// MARK: - Store seam

nonisolated enum PriceAlertsCredentialStoreError: Error, Equatable, Sendable {
    /// A Keychain call failed for a reason other than "item not found". Internal diagnostics only;
    /// PriceAlertsService reports it as `credentialStorageUnavailable` without the status.
    case keychainFailure(OSStatus)
}

protocol PriceAlertsCredentialStoring: Sendable {
    /// `nil` means genuinely absent — safe to generate a credential. A thrown error means the
    /// Keychain could not be read right now for some OTHER reason and MUST NOT be treated as absence.
    func loadCredential() throws -> PriceAlertsInstallationCredential?
    func save(_ credential: PriceAlertsInstallationCredential) throws
}

// MARK: - Keychain seam

nonisolated struct KeychainReadResult: Sendable {
    let status: OSStatus
    let data: Data?
}

/// The three `SecItem` calls the credential store needs, taking and returning exactly what the
/// Security framework does. The production implementation (SystemKeychain, in
/// PriceAlertsLiveDependencies.swift) is a one-line pass-through for each; the tests substitute an
/// in-memory fake that also RECORDS the queries, which is how the storage rules above are verified.
protocol KeychainItemAccessing: Sendable {
    func copyMatching(_ query: [String: Any]) -> KeychainReadResult
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
}

// MARK: - Keychain-backed store

struct KeychainPriceAlertsCredentialStore: PriceAlertsCredentialStoring {
    static let service = "com.e85blends.app.pricealerts.installation"
    static let account = "installationCredential"

    private let keychain: any KeychainItemAccessing

    init(keychain: any KeychainItemAccessing) {
        self.keychain = keychain
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func loadCredential() throws -> PriceAlertsInstallationCredential? {
        var query = Self.baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let result = keychain.copyMatching(query)
        switch result.status {
        case errSecSuccess:
            // The read itself succeeded, so a payload that is not decodable is corruption of the
            // item's CONTENT, not a Keychain failure hiding a real credential. Treated as absent;
            // `save` then replaces it in place.
            guard let data = result.data,
                  let stored = try? JSONDecoder().decode(StoredCredential.self, from: data)
            else { return nil }
            return stored.credential
        case errSecItemNotFound:
            return nil
        default:
            throw PriceAlertsCredentialStoreError.keychainFailure(result.status)
        }
    }

    func save(_ credential: PriceAlertsInstallationCredential) throws {
        let data = try JSONEncoder().encode(StoredCredential(credential))

        let updateStatus = keychain.update(Self.baseQuery, attributes: [kSecValueData as String: data])
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw PriceAlertsCredentialStoreError.keychainFailure(updateStatus)
        }

        var attributes = Self.baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = keychain.add(attributes)
        guard addStatus == errSecSuccess else {
            throw PriceAlertsCredentialStoreError.keychainFailure(addStatus)
        }
    }
}

/// The bytes actually stored: kept separate from the credential type so this file owns the on-disk
/// encoding independently of that type ever changing shape.
private nonisolated struct StoredCredential: Codable {
    let installationID: UUID
    let installationSecret: String

    init(_ credential: PriceAlertsInstallationCredential) {
        installationID = credential.installationID
        installationSecret = credential.installationSecret
    }

    var credential: PriceAlertsInstallationCredential {
        PriceAlertsInstallationCredential(installationID: installationID, installationSecret: installationSecret)
    }
}

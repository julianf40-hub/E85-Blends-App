//
//  ReferralInstallationCredential.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — iOS referral client foundation. The device-local possession credential that
//  identifies THIS installation to supabase/functions/referral-api — see that function's own
//  header ("gate B... THIS is the actual possession credential that identifies a specific
//  installation"). Persisted only via ReferralCredentialStoring (KeychainReferralCredentialStore
//  in production — see that file), never UserDefaults/SwiftData/CloudKit.
//
//  installationSecret is never logged, never included in analytics, never shown in UI — this type
//  intentionally has no CustomStringConvertible/description override that could accidentally leak
//  it into a print(...)/interpolation call site by looking "free."
//

import Foundation
import Security

struct ReferralInstallationCredential: Equatable, Sendable {
    let installationID: UUID
    let installationSecret: String
}

extension ReferralInstallationCredential {
    /// Matches supabase/functions/_shared/referral-api-validation.ts's
    /// MIN_INSTALLATION_SECRET_LENGTH/MAX_INSTALLATION_SECRET_LENGTH exactly — a secret outside
    /// this range would simply be rejected by the backend, so treat it as malformed here too
    /// rather than persisting/sending something guaranteed to fail bootstrap.
    static let minimumSecretLength = 32
    static let maximumSecretLength = 512

    /// ~48 random bytes (384 bits) base64url-encoded, no padding — always exactly 64 characters,
    /// comfortably within [minimumSecretLength, maximumSecretLength] with far more entropy than
    /// either bound requires. Never a UUID-only secret (128 bits, and structurally predictable in
    /// format) — see this feature's own task spec.
    static func generate() -> ReferralInstallationCredential {
        ReferralInstallationCredential(installationID: UUID(), installationSecret: generateSecret())
    }

    static func isValidSecret(_ secret: String) -> Bool {
        secret.count >= minimumSecretLength && secret.count <= maximumSecretLength
    }

    static func isValid(_ credential: ReferralInstallationCredential) -> Bool {
        isValidSecret(credential.installationSecret)
    }

    /// The load-or-create decision at the center of this feature's persistence contract: reuse a
    /// stored credential across ordinary launches (network failures, RevenueCat hiccups, and
    /// backgrounding must never regenerate it — see this feature's own task spec), but replace a
    /// missing OR malformed one (e.g. a corrupted write, or a value from some future format this
    /// version can't validate) rather than ever sending backend-guaranteed-invalid data.
    static func loadOrCreate(using store: ReferralCredentialStoring) -> ReferralInstallationCredential {
        if let existing = store.loadCredential(), isValid(existing) {
            return existing
        }
        let generated = generate()
        store.save(generated)
        return generated
    }

    /// Cryptographically random via the system CSPRNG. Falls back to concatenated `UUID()` values
    /// (also system-CSPRNG-backed on Apple platforms) only in the practically-unreachable case
    /// `SecRandomCopyBytes` itself fails — this must never crash app launch (see this feature's
    /// own "must not break the app" requirement), so this is deliberately NOT a precondition/
    /// fatalError.
    private static func generateSecret() -> String {
        let byteCount = 48
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            bytes = (0..<3).flatMap { _ in withUnsafeBytes(of: UUID().uuid) { Array($0) } }
        }
        return base64URLEncoded(Data(bytes))
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

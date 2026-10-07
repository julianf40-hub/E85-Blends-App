//
//  SystemKeychain.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). The real Keychain behind
//  KeychainItemAccessing: a one-line pass-through for each `SecItem` call, mirroring
//  KeychainReferralCredentialStore's usage exactly. It makes no decisions — every rule about what is
//  stored and how (accessibility, update-before-add, failure handling) lives in
//  KeychainPriceAlertsCredentialStore and is tested there against a fake, so no test depends on real
//  Keychain state. Calls are synchronous and brief, made in response to a user action (never at
//  launch), on the main actor like the referral store's.
//

import Foundation
import Security

struct SystemKeychain: KeychainItemAccessing {
    func copyMatching(_ query: [String: Any]) -> KeychainReadResult {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return KeychainReadResult(status: status, data: item as? Data)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

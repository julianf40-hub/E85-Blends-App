//
//  PushDeviceRegistrationMetadata.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). The two facts price-alerts-api needs
//  next to a device token so that its worker can actually deliver to it: the app's BUNDLE
//  IDENTIFIER (`register_device.bundle_id`, which the worker sends as the APNs topic) and the APNs
//  ENVIRONMENT the token belongs to (`register_device.apns_environment`, which picks
//  api.sandbox.push.apple.com or api.push.apple.com).
//
//  WHY A WRONG VALUE IS WORSE THAN NONE. The worker treats `BadDeviceToken` and
//  `DeviceTokenNotForTopic` as proof that a device is dead and disables it permanently. A token
//  registered under the wrong environment or topic therefore does not fail loudly: it quietly costs
//  the user their alerts. So this file never guesses — when the environment cannot be established the
//  metadata is `nil` and registration is skipped.
//
//  THE ENVIRONMENT IS A PROPERTY OF HOW THE BUILD IS SIGNED, NOT OF THE BUILD CONFIGURATION:
//
//      development-signed (run from Xcode on a device)   aps-environment = development  → sandbox
//      App Store / TestFlight                            aps-environment = production   → production
//      Ad Hoc / Enterprise                               aps-environment = production   → production
//
//  This is why `Debug`/`Internal`/`Release` and the `INTERNAL_BUILD` compile flag are NOT used:
//  the `Internal` configuration runs both ways. Built and run from Xcode it mints SANDBOX tokens;
//  archived by Xcode Cloud and delivered through TestFlight (the intended Internal channel) it mints
//  PRODUCTION tokens, with the internal bundle id as topic. Likewise `Release` run from Xcode is
//  sandbox. (docs/app-store-readiness-code-review.md A3 records the same rule.)
//
//  HOW IT IS ESTABLISHED. A development, Ad Hoc or Enterprise build carries `embedded.mobileprovision`,
//  whose entitlements say which environment applies; an App Store or TestFlight build carries no
//  profile at all, and is always production. The profile is a CMS envelope around an XML property
//  list that is stored in clear text, so no CMS decoding is needed — the plist is cut out and parsed.
//  The Simulator mints no real token; it reports sandbox, which is harmless because a simulator token
//  can never be delivered to anyway.
//
//  The bundle identifier is read from the running bundle, never hard-coded, so the Production and
//  Internal identifiers (com.e85blends.app.ios / com.e85blends.app.ios.internal) cannot be mixed up
//  by this code.
//

import Foundation

/// The two values price-alerts-api accepts for `apns_environment`.
nonisolated enum APNsEnvironment: String, Hashable, Sendable, Codable {
    case sandbox
    case production
}

/// Bundle identifier + APNs environment of the running build — what `register_device` needs besides
/// the token.
nonisolated struct PushDeviceRegistrationMetadata: Equatable, Sendable {
    /// price-alerts-api rejects `bundle_id` outside 3...255 characters.
    static let bundleIdentifierLengthRange = 3...255

    let bundleIdentifier: String
    let apnsEnvironment: APNsEnvironment

    /// `nil` when the bundle identifier is missing, padded with whitespace (the server trims, so a
    /// padded value would not be the APNs topic), or outside the backend's length bounds.
    init?(bundleIdentifier: String?, apnsEnvironment: APNsEnvironment) {
        guard let bundleIdentifier,
              Self.bundleIdentifierLengthRange.contains(bundleIdentifier.count),
              bundleIdentifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        self.bundleIdentifier = bundleIdentifier
        self.apnsEnvironment = apnsEnvironment
    }
}

// MARK: - Provisioning profile

/// What the running build's embedded provisioning profile says.
nonisolated enum ProvisioningProfileInfo: Equatable, Sendable {
    /// No `embedded.mobileprovision`: an App Store or TestFlight build.
    case absent
    /// A profile was read. `apsEnvironment` is its `aps-environment` entitlement, if it has one.
    case present(apsEnvironment: String?)
    /// A profile exists but could not be read or parsed.
    case unreadable
}

nonisolated enum ProvisioningProfileParser {
    /// Extracts `Entitlements["aps-environment"]` from the bytes of an `embedded.mobileprovision`.
    /// Total: any input — empty, truncated, binary, hostile — maps to a case without trapping.
    static func parse(_ data: Data) -> ProvisioningProfileInfo {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: .backwards),
              start.lowerBound < end.upperBound
        else { return .unreadable }

        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let plist = object as? [String: Any]
        else { return .unreadable }

        let entitlements = plist["Entitlements"] as? [String: Any]
        return .present(apsEnvironment: entitlements?["aps-environment"] as? String)
    }
}

protocol ProvisioningProfileReading: Sendable {
    func read() -> ProvisioningProfileInfo
}

/// Reads the profile embedded in a bundle (the app's, by default).
struct BundleProvisioningProfileReader: ProvisioningProfileReading {
    var bundle: Bundle = .main

    func read() -> ProvisioningProfileInfo {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return .absent
        }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return ProvisioningProfileParser.parse(data)
    }
}

// MARK: - Environment

nonisolated enum APNsEnvironmentResolver {
    /// `true` only when compiled for the iOS Simulator.
    static var isRunningInSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// The APNs environment a token minted by this build belongs to, or `nil` when it cannot be
    /// established — in which case nothing may be registered.
    static func resolve(profile: ProvisioningProfileInfo, isSimulator: Bool) -> APNsEnvironment? {
        if isSimulator { return .sandbox }
        switch profile {
        case .absent:
            // No profile: App Store or TestFlight — always production, whichever configuration or
            // bundle identifier (Production or Internal) the build has.
            return .production
        case .present(let apsEnvironment):
            switch apsEnvironment {
            case "development": return .sandbox
            case "production": return .production
            default: return nil
            }
        case .unreadable:
            return nil
        }
    }
}

// MARK: - Provider

protocol PushDeviceRegistrationMetadataProviding: Sendable {
    /// `nil` when the bundle identifier or the APNs environment cannot be established.
    func currentMetadata() -> PushDeviceRegistrationMetadata?
}

struct BundlePushDeviceRegistrationMetadataProvider: PushDeviceRegistrationMetadataProviding {
    var bundleIdentifier: String? = Bundle.main.bundleIdentifier
    var profileReader: any ProvisioningProfileReading = BundleProvisioningProfileReader()
    var isSimulator: Bool = APNsEnvironmentResolver.isRunningInSimulator

    func currentMetadata() -> PushDeviceRegistrationMetadata? {
        guard let environment = APNsEnvironmentResolver.resolve(profile: profileReader.read(), isSimulator: isSimulator) else {
            return nil
        }
        return PushDeviceRegistrationMetadata(bundleIdentifier: bundleIdentifier, apnsEnvironment: environment)
    }
}

//
//  ReferralModels.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — iOS referral client foundation. Wire-format Codable models for
//  supabase/functions/referral-api — field names/shapes mirror that function's own
//  _shared/referral-api-validation.ts / referral-api-response.ts exactly. Deliberately contains no
//  private backend identifier (participant/attribution/reward UUID) — referral-api's own response
//  contract never returns one; see that function's "never expose private identifiers" comment.
//

import Foundation

/// Maps exactly to the two strings referral-api's `isValidRevenueCatEnvironment` accepts — see
/// ReferralRevenueEnvironmentProviding.swift for how this is determined on-device.
enum ReferralRevenueEnvironment: String, Codable, Sendable {
    case sandbox = "SANDBOX"
    case production = "PRODUCTION"
}

enum ReferralAction: String, Codable, Sendable {
    case bootstrap
    case status
    case applyCode = "apply_code"
}

// MARK: - Requests

struct ReferralBootstrapRequest: Encodable, Sendable {
    let action = ReferralAction.bootstrap
    let clientInstallationID: UUID
    let installationSecret: String
    let revenueCatAppUserID: String
    let revenueCatEnvironment: ReferralRevenueEnvironment
    let appVersion: String?

    enum CodingKeys: String, CodingKey {
        case action
        case clientInstallationID = "client_installation_id"
        case installationSecret = "installation_secret"
        case revenueCatAppUserID = "revenuecat_app_user_id"
        case revenueCatEnvironment = "revenuecat_environment"
        case appVersion = "app_version"
    }
}

struct ReferralStatusRequest: Encodable, Sendable {
    let action = ReferralAction.status
    let clientInstallationID: UUID
    let installationSecret: String

    enum CodingKeys: String, CodingKey {
        case action
        case clientInstallationID = "client_installation_id"
        case installationSecret = "installation_secret"
    }
}

struct ReferralApplyCodeRequest: Encodable, Sendable {
    let action = ReferralAction.applyCode
    let clientInstallationID: UUID
    let installationSecret: String
    let referralCode: String

    enum CodingKeys: String, CodingKey {
        case action
        case clientInstallationID = "client_installation_id"
        case installationSecret = "installation_secret"
        case referralCode = "referral_code"
    }
}

// MARK: - Responses

/// The client-safe progress shape every one of referral-api's three actions returns — bootstrap
/// and apply_code embed these exact same fields at the JSON top level, alongside one extra field
/// each (`created` / `status`; see below).
struct ReferralStatus: Decodable, Equatable, Sendable {
    let referralCode: String
    let qualifiedReferrals: Int
    let pendingReferrals: Int
    let earnedMonthsAvailable: Int
    let fulfilledMonths: Int
    let nextMilestoneNumber: Int
    let nextRewardAt: Int
    let referralsNeeded: Int
    let canApplyReferralCode: Bool
    let referredByCode: String?
    let referredStatus: String?

    enum CodingKeys: String, CodingKey {
        case referralCode = "referral_code"
        case qualifiedReferrals = "qualified_referrals"
        case pendingReferrals = "pending_referrals"
        case earnedMonthsAvailable = "earned_months_available"
        case fulfilledMonths = "fulfilled_months"
        case nextMilestoneNumber = "next_milestone_number"
        case nextRewardAt = "next_reward_at"
        case referralsNeeded = "referrals_needed"
        case canApplyReferralCode = "can_apply_referral_code"
        case referredByCode = "referred_by_code"
        case referredStatus = "referred_status"
    }
}

struct ReferralBootstrapResponse: Decodable, Equatable, Sendable {
    let status: ReferralStatus
    let created: Bool

    private enum CodingKeys: String, CodingKey {
        case created
    }

    init(from decoder: Decoder) throws {
        status = try ReferralStatus(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        created = try container.decode(Bool.self, forKey: .created)
    }
}

extension ReferralBootstrapResponse {
    /// Memberwise construction for tests (see ReferralManagerTests.swift) — production code only
    /// ever produces this type via `init(from:)`, decoding a real referral-api response. Declared
    /// in an extension since the struct's own `init(from:)` above suppresses Swift's automatic
    /// memberwise initializer.
    init(status: ReferralStatus, created: Bool) {
        self.status = status
        self.created = created
    }
}

struct ReferralApplyCodeResponse: Decodable, Equatable, Sendable {
    let status: ReferralStatus
    /// Raw backend outcome string — "applied" or "already_applied" as of this writing. Kept as a
    /// plain String (not a closed enum) so a future backend addition can never fail decoding here;
    /// callers compare against the known values they care about.
    let applyStatus: String

    private enum CodingKeys: String, CodingKey {
        case applyStatus = "status"
    }

    init(from decoder: Decoder) throws {
        status = try ReferralStatus(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        applyStatus = try container.decode(String.self, forKey: .applyStatus)
    }
}

extension ReferralApplyCodeResponse {
    /// Memberwise construction for tests (see ReferralManagerTests.swift) — same rationale as
    /// `ReferralBootstrapResponse`'s own test-convenience initializer above.
    init(status: ReferralStatus, applyStatus: String) {
        self.status = status
        self.applyStatus = applyStatus
    }
}

struct ReferralAPIErrorResponse: Decodable, Sendable {
    let error: String
}

// MARK: - Errors

/// Every backend error code referral-api can return (see its own _shared/referral-api-errors.ts
/// and index.ts), mapped one-to-one so nothing is silently conflated at this layer — see
/// `userFacing` below for the smaller set a future UI would actually branch on.
enum ReferralAPIError: Error, Equatable, Sendable {
    case invalidAPIKey
    case invalidInstallationCredentials
    case invalidRequestBody
    case unknownAction
    case invalidReferralCode
    case referralCodeNotFound
    case selfReferralNotAllowed
    case referralAlreadyApplied
    case revenueCatIdentityConflict
    case rateLimited
    case serviceUnavailable
    case internalError
    case unrecognized(code: String, statusCode: Int)

    init(code: String, statusCode: Int) {
        switch code {
        case "invalid_api_key": self = .invalidAPIKey
        case "invalid_installation_credentials": self = .invalidInstallationCredentials
        case "invalid_request_body": self = .invalidRequestBody
        case "unknown_action": self = .unknownAction
        case "invalid_referral_code": self = .invalidReferralCode
        case "referral_code_not_found": self = .referralCodeNotFound
        case "self_referral_not_allowed": self = .selfReferralNotAllowed
        case "referral_already_applied": self = .referralAlreadyApplied
        case "revenuecat_identity_conflict": self = .revenueCatIdentityConflict
        case "rate_limited": self = .rateLimited
        case "service_unavailable": self = .serviceUnavailable
        case "internal_error": self = .internalError
        default: self = .unrecognized(code: code, statusCode: statusCode)
        }
    }
}

/// The small, user-safe set a future Refer & Earn UI would actually present — never the raw
/// backend error string (see this feature's own task spec: "Do not display backend error strings
/// directly later").
enum ReferralUserFacingError: Equatable, Sendable {
    case invalidCode
    case codeNotFound
    case selfReferral
    case alreadyApplied
    case identityConflict
    case rateLimited
    case temporarilyUnavailable
}

extension ReferralAPIError {
    var userFacing: ReferralUserFacingError {
        switch self {
        case .invalidReferralCode: .invalidCode
        case .referralCodeNotFound: .codeNotFound
        case .selfReferralNotAllowed: .selfReferral
        case .referralAlreadyApplied: .alreadyApplied
        case .revenueCatIdentityConflict: .identityConflict
        case .rateLimited: .rateLimited
        case .serviceUnavailable, .invalidAPIKey, .invalidInstallationCredentials,
             .invalidRequestBody, .unknownAction, .internalError, .unrecognized:
            .temporarilyUnavailable
        }
    }
}

/// Top-level error ReferralAPIService actually throws — keeps networking/decoding failures
/// distinct from typed backend error codes (see this feature's own task spec).
enum ReferralServiceError: Error, Equatable, Sendable {
    case notConfigured
    case api(ReferralAPIError)
    case network(String)
    case decoding
    case invalidResponse
}

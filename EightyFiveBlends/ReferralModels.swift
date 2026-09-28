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
    case claimReward = "claim_reward"
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

/// 85Blends 2.4.0 Referral Reward Redemption. `requestedProductID` is only consulted by the
/// backend when this installation is NOT currently an active Pro subscriber (see referral-api's
/// own claim_reward handler) — always `nil` when redeeming as an active subscriber, since the
/// backend issues that code for the subscriber's own currently active product regardless of what
/// this field carries (backend is authoritative — see this feature's task spec, Phase 1).
struct ReferralClaimRewardRequest: Encodable, Sendable {
    let action = ReferralAction.claimReward
    let clientInstallationID: UUID
    let installationSecret: String
    let requestedProductID: String?

    enum CodingKeys: String, CodingKey {
        case action
        case clientInstallationID = "client_installation_id"
        case installationSecret = "installation_secret"
        case requestedProductID = "requested_product_id"
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
    /// 85Blends 2.4.0 Referral Reward Redemption — non-nil only while a reward currently has a LIVE
    /// issued (not yet redeemed) Apple Offer Code for THIS installation. All four travel together:
    /// either all are non-nil (a code is currently issued) or all are nil (nothing is currently
    /// issued) — never a partial state, since referral-api's own issuedRewardCode is one query
    /// result, never assembled from independent fields.
    let issuedRewardProductID: String?
    let issuedRewardOfferReferenceName: String?
    /// The raw Apple one-time-use code itself. Safe to hold here — this response only ever reaches
    /// the authenticated installation it was issued to (see ReferralAPIService's own header) — but
    /// still never logged, never included in analytics, and never shown anywhere outside Refer &
    /// Earn's own redemption UI (see ReferEarnView.swift).
    let issuedRewardCode: String?
    /// Raw ISO 8601 wire value — deliberately not decoded as `Date` here (this struct relies on
    /// Swift's synthesized `Decodable` conformance, which uses the app-wide default
    /// JSONDecoder().dateDecodingStrategy unless one is set; ReferralAPIService's decoder sets
    /// none, to avoid any risk of affecting other decoding). See
    /// ReferralPresentation.parseISO8601Date(_:) for the actual, defensive parse a view should use.
    let issuedRewardExpiresAtRaw: String?

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
        case issuedRewardProductID = "issued_reward_product_id"
        case issuedRewardOfferReferenceName = "issued_reward_offer_reference_name"
        case issuedRewardCode = "issued_reward_code"
        case issuedRewardExpiresAtRaw = "issued_reward_expires_at"
    }

    /// Explicit initializer (mirrors PendingPriceContribution's own — a `let` property with a
    /// declaration-time default is excluded entirely from Swift's synthesized memberwise
    /// initializer, not merely given a defaultable parameter, so the four 2.4.0 fields' defaults
    /// live on this initializer's own parameters instead). Every pre-2.4.0 call site (previews,
    /// tests) that omits them keeps compiling unchanged; this does NOT suppress the synthesized
    /// `init(from:)` Decodable conformance this struct still relies on — writing your OWN
    /// memberwise-shaped initializer only suppresses the AUTOMATIC memberwise init, never a
    /// separately-synthesized protocol conformance.
    init(
        referralCode: String,
        qualifiedReferrals: Int,
        pendingReferrals: Int,
        earnedMonthsAvailable: Int,
        fulfilledMonths: Int,
        nextMilestoneNumber: Int,
        nextRewardAt: Int,
        referralsNeeded: Int,
        canApplyReferralCode: Bool,
        referredByCode: String?,
        referredStatus: String?,
        issuedRewardProductID: String? = nil,
        issuedRewardOfferReferenceName: String? = nil,
        issuedRewardCode: String? = nil,
        issuedRewardExpiresAtRaw: String? = nil
    ) {
        self.referralCode = referralCode
        self.qualifiedReferrals = qualifiedReferrals
        self.pendingReferrals = pendingReferrals
        self.earnedMonthsAvailable = earnedMonthsAvailable
        self.fulfilledMonths = fulfilledMonths
        self.nextMilestoneNumber = nextMilestoneNumber
        self.nextRewardAt = nextRewardAt
        self.referralsNeeded = referralsNeeded
        self.canApplyReferralCode = canApplyReferralCode
        self.referredByCode = referredByCode
        self.referredStatus = referredStatus
        self.issuedRewardProductID = issuedRewardProductID
        self.issuedRewardOfferReferenceName = issuedRewardOfferReferenceName
        self.issuedRewardCode = issuedRewardCode
        self.issuedRewardExpiresAtRaw = issuedRewardExpiresAtRaw
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

/// 85Blends 2.4.0 Referral Reward Redemption.
struct ReferralClaimRewardResponse: Decodable, Equatable, Sendable {
    let status: ReferralStatus
    /// Raw backend claim outcome — see private.claim_referral_reward's own RETURNS TABLE comment
    /// for the full set ("claimed", "no_eligible_reward", "no_code_available",
    /// "legacy_or_unsupported_product_active", "invalid_product", "outstanding_reward_exists", …).
    /// Kept as a plain String (not a closed enum), same rationale as
    /// `ReferralApplyCodeResponse.applyStatus` — a future backend addition can never fail decoding
    /// here. See ReferralManager.claimReward(requestedProductID:) for how this maps to a typed,
    /// UI-facing outcome.
    let claimStatus: String
    /// The specific milestone this claim attempt concerned, when the backend resolved one (nil only
    /// for `invalid_participant`/`no_eligible_reward`, which never reach a specific reward at all).
    let rewardMilestoneNumber: Int?

    private enum CodingKeys: String, CodingKey {
        case claimStatus = "status"
        case rewardMilestoneNumber = "reward_milestone_number"
    }

    init(from decoder: Decoder) throws {
        status = try ReferralStatus(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claimStatus = try container.decode(String.self, forKey: .claimStatus)
        rewardMilestoneNumber = try container.decodeIfPresent(Int.self, forKey: .rewardMilestoneNumber)
    }
}

extension ReferralClaimRewardResponse {
    /// Memberwise construction for tests — same rationale as `ReferralBootstrapResponse`'s own
    /// test-convenience initializer above.
    init(status: ReferralStatus, claimStatus: String, rewardMilestoneNumber: Int? = nil) {
        self.status = status
        self.claimStatus = claimStatus
        self.rewardMilestoneNumber = rewardMilestoneNumber
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
    /// 85Blends 2.4.0 Referral Reward Redemption — claim_reward could not authoritatively determine
    /// this installation's active Pro status/product via RevenueCat right now (see referral-api's
    /// own resolveAuthoritativeActiveProduct header: this never falls back to guessing). Routine
    /// and retryable, never a hard failure.
    case revenueCatLookupFailed
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
        case "revenuecat_lookup_failed": self = .revenueCatLookupFailed
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
             .invalidRequestBody, .unknownAction, .internalError, .revenueCatLookupFailed, .unrecognized:
            .temporarilyUnavailable
        }
    }
}

/// Top-level error ReferralAPIService/ReferralManager actually throw — keeps networking/decoding
/// failures distinct from typed backend error codes (see this feature's own task spec).
enum ReferralServiceError: Error, Equatable, Sendable {
    /// The referral system isn't ready for this operation yet — no RevenueCat identity or no
    /// StoreKit environment signal available this instant (see ReferralManager.ensureBootstrapped),
    /// or (pre-hardening-pass) SupabaseConfig itself failed to load. Routine and retryable, not a
    /// hard failure.
    case notConfigured
    /// 85Blends 2.4.0 correctness hardening pass — a durable Keychain read/write for the referral
    /// installation credential failed (see ReferralCredentialStoreError). Never carries the raw
    /// Keychain OSStatus. A future UI's error projection should treat this the same as
    /// `.serviceUnavailable`/`.internalError`: ReferralUserFacingError.temporarilyUnavailable.
    case credentialUnavailable
    case api(ReferralAPIError)
    case network(String)
    case decoding
    case invalidResponse
}

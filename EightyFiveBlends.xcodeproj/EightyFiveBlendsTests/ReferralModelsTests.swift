//
//  ReferralModelsTests.swift
//  EightyFiveBlendsTests
//
//  85Blends 2.4.0 — iOS referral client foundation. Tests for ReferralModels.swift's request
//  encoding (field names must match supabase/functions/referral-api's actual contract exactly),
//  response decoding, and backend-error-code mapping.
//

import Testing
import Foundation
@testable import EightyFiveBlends

struct ReferralModelsTests {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static func encodedJSON(_ value: some Encodable) throws -> [String: Any] {
        let data = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    // MARK: 8. Bootstrap exact field names

    @Test("Bootstrap request encodes exactly the fields/keys the backend expects")
    func bootstrapRequest_exactFieldNames() throws {
        let request = ReferralBootstrapRequest(
            clientInstallationID: UUID(),
            installationSecret: String(repeating: "s", count: 32),
            revenueCatAppUserID: "rc_user_123",
            revenueCatEnvironment: .production,
            appVersion: "2.4.0"
        )
        let json = try Self.encodedJSON(request)

        #expect(Set(json.keys) == [
            "action", "client_installation_id", "installation_secret",
            "revenuecat_app_user_id", "revenuecat_environment", "app_version",
        ])
        #expect(json["action"] as? String == "bootstrap")
        #expect(json["revenuecat_environment"] as? String == "PRODUCTION")
        #expect(json["app_version"] as? String == "2.4.0")
    }

    @Test("Bootstrap request with nil app_version still encodes the key as null, never omits it")
    func bootstrapRequest_nilAppVersion() throws {
        let request = ReferralBootstrapRequest(
            clientInstallationID: UUID(),
            installationSecret: String(repeating: "s", count: 32),
            revenueCatAppUserID: "rc_user_123",
            revenueCatEnvironment: .sandbox,
            appVersion: nil
        )
        let data = try Self.encoder.encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json.keys.contains("app_version"))
        #expect(json["app_version"] is NSNull)
        #expect(json["revenuecat_environment"] as? String == "SANDBOX")
    }

    // MARK: 9. Status exact field names

    @Test("Status request encodes exactly the fields/keys the backend expects")
    func statusRequest_exactFieldNames() throws {
        let request = ReferralStatusRequest(
            clientInstallationID: UUID(),
            installationSecret: String(repeating: "s", count: 32)
        )
        let json = try Self.encodedJSON(request)

        #expect(Set(json.keys) == ["action", "client_installation_id", "installation_secret"])
        #expect(json["action"] as? String == "status")
    }

    // MARK: 10/11. apply_code exact field names + trim/uppercase normalization

    @Test("Apply-code request encodes exactly the fields/keys the backend expects")
    func applyCodeRequest_exactFieldNames() throws {
        let request = ReferralApplyCodeRequest(
            clientInstallationID: UUID(),
            installationSecret: String(repeating: "s", count: 32),
            referralCode: "ABCD2345"
        )
        let json = try Self.encodedJSON(request)

        #expect(Set(json.keys) == ["action", "client_installation_id", "installation_secret", "referral_code"])
        #expect(json["action"] as? String == "apply_code")
    }

    @Test("Referral code is normalized (trim + uppercase) before being sent")
    func referralCode_trimAndUppercase() async throws {
        let service = try ReferralAPIService(session: URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CapturingURLProtocol.self]
            return configuration
        }()))
        let credential = ReferralInstallationCredential.generate()

        CapturingURLProtocol.stubbedResponse = .success(statusCode: 200, body: Self.statusJSON())
        _ = try? await service.applyCode("  abcd2345  ", credential: credential)

        let sentBody = try #require(CapturingURLProtocol.lastRequestBody)
        let json = try #require(try JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(json["referral_code"] as? String == "ABCD2345")
    }

    // MARK: 85Blends 2.4.0 Referral Reward Redemption — claim_reward request exact field names

    @Test("Claim-reward request (free/expired user, a plan chosen) encodes exactly the fields the backend expects")
    func claimRewardRequest_withRequestedProduct_exactFieldNames() throws {
        let request = ReferralClaimRewardRequest(
            clientInstallationID: UUID(),
            installationSecret: String(repeating: "s", count: 32),
            requestedProductID: "com.85blends.subscription.monthly"
        )
        let json = try Self.encodedJSON(request)

        #expect(Set(json.keys) == ["action", "client_installation_id", "installation_secret", "requested_product_id"])
        #expect(json["action"] as? String == "claim_reward")
        #expect(json["requested_product_id"] as? String == "com.85blends.subscription.monthly")
    }

    @Test("Claim-reward request (active Pro subscriber) still encodes requested_product_id as null, never omits it")
    func claimRewardRequest_activeSubscriber_nilProductStillEncodesKey() throws {
        let request = ReferralClaimRewardRequest(
            clientInstallationID: UUID(),
            installationSecret: String(repeating: "s", count: 32),
            requestedProductID: nil
        )
        let data = try Self.encoder.encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json.keys.contains("requested_product_id"))
        #expect(json["requested_product_id"] is NSNull)
    }

    // MARK: 85Blends 2.4.0 Referral Reward Redemption — ReferralStatus issued-code fields

    @Test("Status response decodes the four issued-reward-code fields when a code is currently issued")
    func statusResponse_decodesIssuedRewardCode() throws {
        let json = """
        {"referral_code":"ABCD2345","qualified_referrals":5,"pending_referrals":0,
         "earned_months_available":0,"fulfilled_months":0,"next_milestone_number":2,
         "next_reward_at":10,"referrals_needed":5,"can_apply_referral_code":false,
         "referred_by_code":null,"referred_status":null,
         "issued_reward_product_id":"com.85blends.subscription.monthly",
         "issued_reward_offer_reference_name":"REFERRAL_REWARD_MONTHLY_1M_FREE",
         "issued_reward_code":"ABCD1234EFGH",
         "issued_reward_expires_at":"2026-12-31T00:00:00.000Z",
         "issued_reward_needs_refresh":false}
        """.data(using: .utf8)!

        let status = try Self.decoder.decode(ReferralStatus.self, from: json)
        #expect(status.issuedRewardProductID == "com.85blends.subscription.monthly")
        #expect(status.issuedRewardOfferReferenceName == "REFERRAL_REWARD_MONTHLY_1M_FREE")
        #expect(status.issuedRewardCode == "ABCD1234EFGH")
        #expect(status.issuedRewardExpiresAtRaw == "2026-12-31T00:00:00.000Z")
        #expect(status.issuedRewardNeedsRefresh == false)
        // The real backend state after claiming the only earned reward — see
        // ReferralPresentation.RewardCardState's own header for why this is NOT a bug: a claimed
        // reward's own status is 'issued', not 'earned', so it correctly drops out of this count.
        #expect(status.earnedMonthsAvailable == 0)
    }

    @Test("Status response missing the issued-reward-code keys entirely (pre-this-feature-shaped payload) decodes them as nil/false, never throws")
    func statusResponse_missingIssuedRewardCodeKeys_decodesNil() throws {
        // Byte-for-byte the SAME JSON this file's own pre-existing `statusResponse_decodesWithReferredBy`
        // test already used, before this feature ever added these keys — proves backward
        // compatibility with a response shape that predates this feature, including
        // issued_reward_needs_refresh (third correctness hardening pass) — this is exactly the case
        // that requires ReferralStatus's own explicit `init(from:)` (see its header): a plain
        // non-optional Bool with no key present would otherwise throw, not default to false.
        let json = """
        {"referral_code":"ABCD2345","qualified_referrals":0,"pending_referrals":0,
         "earned_months_available":0,"fulfilled_months":0,"next_milestone_number":1,
         "next_reward_at":5,"referrals_needed":5,"can_apply_referral_code":false,
         "referred_by_code":"WXYZ6789","referred_status":"pending"}
        """.data(using: .utf8)!

        let status = try Self.decoder.decode(ReferralStatus.self, from: json)
        #expect(status.issuedRewardProductID == nil)
        #expect(status.issuedRewardOfferReferenceName == nil)
        #expect(status.issuedRewardCode == nil)
        #expect(status.issuedRewardExpiresAtRaw == nil)
        #expect(status.issuedRewardNeedsRefresh == false)
    }

    @Test("Status response decodes issued_reward_needs_refresh true when the backend reports an expired, unrecovered issued reward")
    func statusResponse_decodesIssuedRewardNeedsRefresh() throws {
        let json = """
        {"referral_code":"ABCD2345","qualified_referrals":5,"pending_referrals":0,
         "earned_months_available":0,"fulfilled_months":0,"next_milestone_number":2,
         "next_reward_at":10,"referrals_needed":5,"can_apply_referral_code":false,
         "referred_by_code":null,"referred_status":null,
         "issued_reward_product_id":null,"issued_reward_offer_reference_name":null,
         "issued_reward_code":null,"issued_reward_expires_at":null,
         "issued_reward_needs_refresh":true}
        """.data(using: .utf8)!

        let status = try Self.decoder.decode(ReferralStatus.self, from: json)
        #expect(status.issuedRewardNeedsRefresh == true)
        #expect(status.issuedRewardCode == nil)
    }

    // MARK: 85Blends 2.4.0 Referral Reward Redemption — claim_reward response decoding

    @Test("Claim-reward response decodes the claim status, reward milestone number, and full status")
    func claimRewardResponse_decodes() throws {
        let json = """
        {"status":"claimed","reward_milestone_number":1,
         "referral_code":"ABCD2345","qualified_referrals":5,"pending_referrals":0,
         "earned_months_available":1,"fulfilled_months":0,"next_milestone_number":2,
         "next_reward_at":10,"referrals_needed":5,"can_apply_referral_code":false,
         "referred_by_code":null,"referred_status":null,
         "issued_reward_product_id":"com.85blends.subscription.monthly",
         "issued_reward_offer_reference_name":"REFERRAL_REWARD_MONTHLY_1M_FREE",
         "issued_reward_code":"ABCD1234EFGH",
         "issued_reward_expires_at":"2026-12-31T00:00:00.000Z"}
        """.data(using: .utf8)!

        let response = try Self.decoder.decode(ReferralClaimRewardResponse.self, from: json)
        #expect(response.claimStatus == "claimed")
        #expect(response.rewardMilestoneNumber == 1)
        #expect(response.status.issuedRewardCode == "ABCD1234EFGH")
    }

    @Test("Claim-reward response with no available code decodes a nil issued code and reward_milestone_number, never throws")
    func claimRewardResponse_noCodeAvailable_decodesNilFields() throws {
        let json = """
        {"status":"no_code_available","reward_milestone_number":2,
         "referral_code":"ABCD2345","qualified_referrals":10,"pending_referrals":0,
         "earned_months_available":2,"fulfilled_months":0,"next_milestone_number":3,
         "next_reward_at":15,"referrals_needed":5,"can_apply_referral_code":false,
         "referred_by_code":null,"referred_status":null}
        """.data(using: .utf8)!

        let response = try Self.decoder.decode(ReferralClaimRewardResponse.self, from: json)
        #expect(response.claimStatus == "no_code_available")
        #expect(response.status.issuedRewardCode == nil)
    }

    @Test("revenuecat_lookup_failed maps to its own typed case and to the safe temporarilyUnavailable UX bucket")
    func revenueCatLookupFailedErrorCode_mapsExactly() {
        let error = ReferralAPIError(code: "revenuecat_lookup_failed", statusCode: 503)
        #expect(error == .revenueCatLookupFailed)
        #expect(error.userFacing == .temporarilyUnavailable)
    }

    // MARK: 15. Bootstrap response decoding

    @Test("Bootstrap response decodes status fields plus created")
    func bootstrapResponse_decodes() throws {
        let json = """
        {"referral_code":"ABCD2345","qualified_referrals":3,"pending_referrals":1,
         "earned_months_available":0,"fulfilled_months":0,"next_milestone_number":1,
         "next_reward_at":5,"referrals_needed":2,"can_apply_referral_code":true,
         "referred_by_code":null,"referred_status":null,"created":true}
        """.data(using: .utf8)!

        let response = try Self.decoder.decode(ReferralBootstrapResponse.self, from: json)
        #expect(response.created)
        #expect(response.status.referralCode == "ABCD2345")
        #expect(response.status.qualifiedReferrals == 3)
        #expect(response.status.canApplyReferralCode)
        #expect(response.status.referredByCode == nil)
    }

    // MARK: 16. Status response decoding

    @Test("Status response decodes all fields, including a non-null referred_by_code/referred_status")
    func statusResponse_decodesWithReferredBy() throws {
        let json = """
        {"referral_code":"ABCD2345","qualified_referrals":0,"pending_referrals":0,
         "earned_months_available":0,"fulfilled_months":0,"next_milestone_number":1,
         "next_reward_at":5,"referrals_needed":5,"can_apply_referral_code":false,
         "referred_by_code":"WXYZ6789","referred_status":"pending"}
        """.data(using: .utf8)!

        let status = try Self.decoder.decode(ReferralStatus.self, from: json)
        #expect(status.canApplyReferralCode == false)
        #expect(status.referredByCode == "WXYZ6789")
        #expect(status.referredStatus == "pending")
    }

    // MARK: 17. Apply response decoding

    @Test("Apply-code response decodes status fields plus the outcome status string")
    func applyCodeResponse_decodes() throws {
        let json = """
        {"referral_code":"ABCD2345","qualified_referrals":0,"pending_referrals":0,
         "earned_months_available":0,"fulfilled_months":0,"next_milestone_number":1,
         "next_reward_at":5,"referrals_needed":5,"can_apply_referral_code":false,
         "referred_by_code":"WXYZ6789","referred_status":"pending","status":"applied"}
        """.data(using: .utf8)!

        let response = try Self.decoder.decode(ReferralApplyCodeResponse.self, from: json)
        #expect(response.applyStatus == "applied")
        #expect(response.status.referredByCode == "WXYZ6789")
    }

    // MARK: 18. Unknown additional JSON fields tolerated

    @Test("Unknown additional JSON fields never break decoding of any referral response")
    func unknownFields_tolerated() throws {
        let json = """
        {"referral_code":"ABCD2345","qualified_referrals":0,"pending_referrals":0,
         "earned_months_available":0,"fulfilled_months":0,"next_milestone_number":1,
         "next_reward_at":5,"referrals_needed":5,"can_apply_referral_code":true,
         "referred_by_code":null,"referred_status":null,"created":false,
         "some_future_field":"unexpected_value","another_one":42}
        """.data(using: .utf8)!

        let response = try Self.decoder.decode(ReferralBootstrapResponse.self, from: json)
        #expect(response.created == false)
        #expect(response.status.referralCode == "ABCD2345")
    }

    // MARK: 19-26. Error code mapping

    @Test(
        "Every known backend error code maps to its own distinct typed case",
        arguments: [
            ("invalid_api_key", ReferralAPIError.invalidAPIKey),
            ("invalid_installation_credentials", .invalidInstallationCredentials),
            ("invalid_request_body", .invalidRequestBody),
            ("unknown_action", .unknownAction),
            ("invalid_referral_code", .invalidReferralCode),
            ("referral_code_not_found", .referralCodeNotFound),
            ("self_referral_not_allowed", .selfReferralNotAllowed),
            ("referral_already_applied", .referralAlreadyApplied),
            ("revenuecat_identity_conflict", .revenueCatIdentityConflict),
            ("rate_limited", .rateLimited),
            ("service_unavailable", .serviceUnavailable),
            ("internal_error", .internalError),
        ] as [(String, ReferralAPIError)]
    )
    func knownErrorCode_mapsExactly(code: String, expected: ReferralAPIError) {
        #expect(ReferralAPIError(code: code, statusCode: 400) == expected)
    }

    @Test("An unrecognized backend error code is preserved, not silently dropped or misclassified")
    func unrecognizedErrorCode_isPreserved() {
        let error = ReferralAPIError(code: "some_future_code", statusCode: 422)
        #expect(error == .unrecognized(code: "some_future_code", statusCode: 422))
    }

    @Test(
        "userFacing projects every backend code to a safe, non-raw-string semantic case",
        arguments: [
            (ReferralAPIError.invalidReferralCode, ReferralUserFacingError.invalidCode),
            (.referralCodeNotFound, .codeNotFound),
            (.selfReferralNotAllowed, .selfReferral),
            (.referralAlreadyApplied, .alreadyApplied),
            (.revenueCatIdentityConflict, .identityConflict),
            (.rateLimited, .rateLimited),
            (.serviceUnavailable, .temporarilyUnavailable),
            (.internalError, .temporarilyUnavailable),
            (.invalidAPIKey, .temporarilyUnavailable),
        ] as [(ReferralAPIError, ReferralUserFacingError)]
    )
    func userFacing_mapsToSafeSemanticCase(error: ReferralAPIError, expected: ReferralUserFacingError) {
        #expect(error.userFacing == expected)
    }

    fileprivate static func statusJSON() -> Data {
        """
        {"referral_code":"ABCD2345","qualified_referrals":0,"pending_referrals":0,
         "earned_months_available":0,"fulfilled_months":0,"next_milestone_number":1,
         "next_reward_at":5,"referrals_needed":5,"can_apply_referral_code":true,
         "referred_by_code":null,"referred_status":null,"status":"applied"}
        """.data(using: .utf8)!
    }
}

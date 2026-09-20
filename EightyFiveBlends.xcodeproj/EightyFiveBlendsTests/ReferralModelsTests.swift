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

//
//  AnalyticsEvent.swift
//  EightyFiveBlends
//
//  85Blends 2.4.0 — the smallest possible representation of an event for the existing, already
//  live `public.e85_analytics_events` Supabase table (see supabase/migrations/
//  20260909101339_create_e85_analytics_events_table.sql and its five follow-on CHECK-constraint
//  migrations). This pass transmits ONLY the four event names that table's `event_name` CHECK
//  constraint already accepts and that were explicitly scoped for this feature:
//  price_report_prompt_shown, price_report_opened, price_report_submitted, price_report_failed.
//  It deliberately does NOT transmit price_prompt_eligible/price_report_started/
//  price_prompt_dismissed/price_report_success — none of those names exist in the live schema's
//  CHECK constraint, and this file must never send a value Supabase will reject. See this
//  feature's implementation report for why each of those four is instead left untracked, or
//  tracked local-only, for this pass.
//

import Foundation

/// Exactly the six values `e85_analytics_events.event_name`'s CHECK constraint accepts today.
/// `stationViewed`/`communityPriceStateSeen` are declared for completeness/future use but are
/// never transmitted by this pass — see this file's header.
enum AnalyticsEventName: String, Encodable, Sendable {
    case stationViewed = "station_viewed"
    case communityPriceStateSeen = "community_price_state_seen"
    case priceReportPromptShown = "price_report_prompt_shown"
    case priceReportOpened = "price_report_opened"
    case priceReportSubmitted = "price_report_submitted"
    case priceReportFailed = "price_report_failed"
}

/// `entry_point` — exactly the five values the live `e85_analytics_entry_point_values` CHECK
/// constraint accepts. This pass sends `.other` for its post-navigation prompt/open/submit/fail
/// events: the live schema has no `post_navigation` value, and nothing in that constraint's
/// migration (`20260909101422_limit_e85_analytics_entry_points.sql`) or elsewhere documents
/// `.proximityPrompt` as intended for a post-navigation return rather than a genuine
/// geographic-proximity prompt, so this pass does not claim that meaning for a trigger that
/// isn't one. `.proximityPrompt` remains declared for whichever feature actually earns it.
enum AnalyticsEntryPoint: String, Encodable, Sendable {
    case stationList = "station_list"
    case stationMap = "station_map"
    case atThePump = "at_the_pump"
    case proximityPrompt = "proximity_prompt"
    case other
}

/// `price_state` — exactly the four values the live `e85_analytics_price_state_values` CHECK
/// constraint accepts. Mirrors `StationDataValidation.PriceFreshness`'s own four cases;
/// `.missing` is the database's name for what that enum calls `.noPrice` — a deliberate,
/// documented naming drift between the two, not a bug. Declared for completeness; unused by
/// this pass (see `AnalyticsEventProperties`'s own header for why `priceState` is left `nil`
/// here).
enum AnalyticsPriceState: String, Encodable, Sendable {
    case missing
    case fresh
    case checkPrice = "check_price"
    case stale
}

/// The exactly-four allowed `properties` keys (`e85_analytics_properties_allowed_keys`'s CHECK
/// constraint permits ONLY these — nothing else), as a strongly-typed struct rather than a raw
/// dictionary so an unlisted key can never be added by accident. Swift's synthesized
/// `Encodable` conformance uses `encodeIfPresent` for every `Optional` stored property, so a
/// `nil` field is OMITTED from the encoded JSON entirely (never encoded as `null`) — an
/// all-`nil` instance encodes to `{}`, which still satisfies
/// `jsonb_typeof(properties) = 'object'`.
///
/// This pass populates only `entryPoint` (always `.other` — see `AnalyticsEntryPoint`'s own
/// header for why) and, on a failure event, `failureCategory`. `stationSource`/`priceState` are
/// left `nil` deliberately: computing either
/// safely at this feature's actual call sites (ContentView, which does not have access to
/// StationsView's private `communityPriceSummaries`; and StationsView's own compact-mode call
/// sites, where the value would only describe the report itself, not add new information) would
/// mean fabricating a value rather than reading a real one.
struct AnalyticsEventProperties: Encodable, Sendable {
    var stationSource: String?
    var entryPoint: AnalyticsEntryPoint?
    var priceState: AnalyticsPriceState?
    var failureCategory: String?

    enum CodingKeys: String, CodingKey {
        case stationSource = "station_source"
        case entryPoint = "entry_point"
        case priceState = "price_state"
        case failureCategory = "failure_category"
    }
}

/// The exact wire payload for one POST to `e85_analytics_events`. `occurredAt` is always the
/// real moment of the event, never `received_at` (the server sets that column itself).
/// `properties` is always encoded (even when every field is `nil`, producing `{}`) since the
/// table's own `properties` column is `not null default '{}'::jsonb`.
struct AnalyticsEventPayload: Encodable, Sendable {
    let eventName: AnalyticsEventName
    let occurredAt: Date
    let appVersion: String
    let contributorID: String
    let properties: AnalyticsEventProperties

    enum CodingKeys: String, CodingKey {
        case eventName = "event_name"
        case occurredAt = "occurred_at"
        case appVersion = "app_version"
        case contributorID = "contributor_id"
        case properties
    }
}

/// Short (well under the server's 128-character limit — see
/// `e85_analytics_failure_category_shape`), stable, non-arbitrary labels for `failure_category`
/// — never a raw error's localized description, which could vary run to run and is not a closed
/// set. Mirrors `CommunityPriceServiceError`'s own cases (CommunityPriceService.swift) plus a
/// fallback for anything else (a plain network/URLError, for instance) `savePriceUpdate`'s catch
/// block might see.
enum AnalyticsFailureCategory {
    static func category(for error: Error) -> String {
        guard let serviceError = error as? CommunityPriceServiceError else {
            return "network_error"
        }
        switch serviceError {
        case .notConfigured: return "not_configured"
        case .invalidBaseURL: return "invalid_base_url"
        case .requestFailed: return "request_failed"
        case .invalidResponse: return "invalid_response"
        case .stationLookupFailed: return "station_lookup_failed"
        }
    }
}

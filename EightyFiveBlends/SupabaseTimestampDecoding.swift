//
//  SupabaseTimestampDecoding.swift
//  EightyFiveBlends
//
//  Decodes the `timestamptz` strings Supabase/PostgREST returns. Server-defaulted columns such as
//  `created_at` come back with fractional seconds (2026-10-02T20:30:46.123456+00:00) while
//  client-written columns such as `reported_at` come back without (2026-10-02T20:30:46+00:00).
//  JSONDecoder's `.iso8601` strategy is not guaranteed to accept fractional seconds on every
//  supported OS, so fractional values are tried first and whole-second values second. A value
//  neither accepts throws; there is no fallback date. ISO8601DateFormatter keeps millisecond
//  precision at most.
//

import Foundation

nonisolated enum SupabaseTimestamp {
    // ISO8601DateFormatter is not Sendable, so every use goes through `lock`.
    private static let lock = NSLock()
    nonisolated(unsafe) private static let fractional = makeFormatter([.withInternetDateTime, .withFractionalSeconds])
    nonisolated(unsafe) private static let wholeSecond = makeFormatter([.withInternetDateTime])

    private static func makeFormatter(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        return formatter
    }

    static func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: string) ?? wholeSecond.date(from: string)
    }

    static let decodingStrategy: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = SupabaseTimestamp.date(from: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO 8601 timestamp, fractional seconds optional, but found \"\(string)\"."
            )
        }
        return date
    }
}

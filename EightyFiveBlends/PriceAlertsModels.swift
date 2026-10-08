//
//  PriceAlertsModels.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). The value types of the
//  `price-alerts-api` alert resource, shaped by the backend contract recorded in
//  docs/PRICE_ALERTS_CLIENT_INTEGRATION_2.4.1.md (canonical source:
//  supabase/functions/price-alerts-api/index.ts). Pure Foundation, no networking, no UI.
//
//  Three decisions worth knowing before reading on:
//
//  1. MONEY IS INTEGER THOUSANDTHS. The backend stores every price and delta as `numeric(6,3)`,
//     sends them back as JSON *strings* ("3.250") and requires them on the way in as JSON *numbers*.
//     `PriceAlertAmount` holds whole thousandths of a dollar, so 3.499 is exactly 3499 — no binary
//     floating-point drift on the way to the database — and decodes from either a numeric string or
//     a JSON number.
//
//  2. THE MODE VOCABULARY IS THE BACKEND'S. `any_change`, `price_drop` and `at_or_below` are the
//     identifiers the database accepts. The MVP UI offers Price Drop and "At or Below $X"
//     (`PriceAlertRule.isOfferedInMVP`); `any_change` stays representable because the backend
//     supports it and a row created elsewhere must still decode. A mode this build has never heard
//     of decodes as `.unknown`, so a newer backend can never make the alert list undecodable.
//
//  3. THE STATION IDENTITY IS NEVER MANUFACTURED. `PriceAlertDraft` is the only way to build a
//     request body, and it takes the optional `communityStationID` exactly as stored on a saved
//     station. `nil` is refused with `stationNotEligibleForPriceAlerts`; it is never replaced by a
//     name, coordinates, a canonical key, a hash or a generated UUID.
//
//  4. (Phase 3C) AN ALERT WATCHES ONE PRICE. `PriceAlertPayment` is `cash`, `credit` or `unknown`. A
//     cash alert is judged only against cash prices (and prices reported as the same for both), a
//     credit alert only against credit prices, and the server — not this file — decides. `unknown` is
//     what an alert made before payment types existed reads as; this build never sends it and never
//     turns it into cash or credit on its own. A response that carries no `payment_type` (a backend
//     that has not been updated yet) reads as `unknown`, so the alert list still decodes.
//
//  Everything here is `nonisolated`: the app target defaults to MainActor isolation, and these are
//  plain values used from async code and tests alike.
//

import Foundation

// MARK: - Money

/// A dollar amount with exactly three decimal places, held as whole thousandths of a dollar
/// (`$3.499` is `3499`). Used for `threshold_price`, `minimum_change`, `last_notified_price` and the
/// latest report price — all `numeric(6,3)` columns.
nonisolated struct PriceAlertAmount: Hashable, Comparable, Sendable {
    /// Far above any real fuel price; keeps every parse and conversion free of integer overflow.
    static let maximumThousandths = 1_000_000_000

    let thousandths: Int

    init(thousandths: Int) {
        self.thousandths = thousandths
    }

    /// `nil` for a non-finite, negative or absurdly large value. Rounds to the nearest thousandth.
    init?(dollars: Double) {
        guard dollars.isFinite, dollars >= 0, dollars <= Double(Self.maximumThousandths) / 1000 else {
            return nil
        }
        thousandths = Int((dollars * 1000).rounded())
    }

    /// Parses the text Postgres renders for a `numeric` ("3.250", "3.5", "4"). A fourth fractional
    /// digit rounds half up and any further digits are ignored. Signs, exponents, spaces and the
    /// empty string are rejected.
    init?(wireString text: String) {
        var whole = 0
        var fraction = 0
        var fractionDigits = 0
        var roundUp = false
        var sawPoint = false
        var sawDigit = false

        for scalar in text.unicodeScalars {
            if scalar == "." {
                if sawPoint { return nil }
                sawPoint = true
                continue
            }
            guard scalar.value >= 0x30, scalar.value <= 0x39 else { return nil }
            let digit = Int(scalar.value - 0x30)
            sawDigit = true
            if sawPoint {
                fractionDigits += 1
                if fractionDigits <= 3 {
                    fraction = fraction * 10 + digit
                } else if fractionDigits == 4 {
                    roundUp = digit >= 5
                }
            } else {
                whole = whole * 10 + digit
                if whole > Self.maximumThousandths / 1000 { return nil }
            }
        }
        guard sawDigit else { return nil }
        while fractionDigits < 3 {
            fraction *= 10
            fractionDigits += 1
        }
        thousandths = whole * 1000 + fraction + (roundUp ? 1 : 0)
    }

    var dollars: Double {
        Double(thousandths) / 1000
    }

    static func < (lhs: PriceAlertAmount, rhs: PriceAlertAmount) -> Bool {
        lhs.thousandths < rhs.thousandths
    }
}

extension PriceAlertAmount: Codable {
    /// Accepts the numeric string the backend sends ("3.250") or a JSON number.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard let amount = PriceAlertAmount(wireString: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a non-negative decimal amount."
                )
            }
            self = amount
            return
        }
        let number = try container.decode(Double.self)
        guard let amount = PriceAlertAmount(dollars: number) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a finite, non-negative amount."
            )
        }
        self = amount
    }

    /// Always a JSON *number* (`3.499`), never a string — `set_alert` rejects strings.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(dollars)
    }
}

// MARK: - Modes and rules

/// The backend's `alert_mode` identifiers. `.unknown` keeps an unrecognized future mode decodable.
nonisolated enum PriceAlertMode: Hashable, Sendable {
    case anyChange
    case priceDrop
    case atOrBelow
    case unknown(String)

    init(wireValue: String) {
        switch wireValue {
        case "any_change": self = .anyChange
        case "price_drop": self = .priceDrop
        case "at_or_below": self = .atOrBelow
        default: self = .unknown(wireValue)
        }
    }

    var wireValue: String {
        switch self {
        case .anyChange: return "any_change"
        case .priceDrop: return "price_drop"
        case .atOrBelow: return "at_or_below"
        case .unknown(let value): return value
        }
    }
}

extension PriceAlertMode: Codable {
    init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// What an alert watches for, with the threshold attached to the one mode that has one — so a
/// threshold-less `at_or_below` or a stray threshold on `price_drop` cannot be expressed.
nonisolated enum PriceAlertRule: Hashable, Sendable {
    /// Any price move of at least `minimum_change`. Supported by the backend; not offered by the MVP UI.
    case anyChange
    /// "Price Drop": the price fell by at least `minimum_change`.
    case priceDrop
    /// "At or Below $X": the price is at or below this many dollars per gallon.
    case atOrBelow(PriceAlertAmount)

    /// The thresholds `set_alert` accepts: 1.000 through 8.000 dollars per gallon, inclusive.
    static let thresholdRange = PriceAlertAmount(thousandths: 1_000)...PriceAlertAmount(thousandths: 8_000)

    var mode: PriceAlertMode {
        switch self {
        case .anyChange: return .anyChange
        case .priceDrop: return .priceDrop
        case .atOrBelow: return .atOrBelow
        }
    }

    var thresholdPrice: PriceAlertAmount? {
        if case .atOrBelow(let threshold) = self { return threshold }
        return nil
    }

    /// Whether the MVP UI should offer this rule (Price Drop and At or Below).
    var isOfferedInMVP: Bool {
        switch self {
        case .anyChange: return false
        case .priceDrop, .atOrBelow: return true
        }
    }

    /// Rebuilds a rule from the mode and threshold a response carried. `nil` when the pair is not
    /// one this build understands: an unknown mode, or `at_or_below` without a threshold.
    init?(mode: PriceAlertMode, thresholdPrice: PriceAlertAmount?) {
        switch (mode, thresholdPrice) {
        case (.anyChange, nil): self = .anyChange
        case (.priceDrop, nil): self = .priceDrop
        case (.atOrBelow, .some(let threshold)): self = .atOrBelow(threshold)
        default: return nil
        }
    }
}

// MARK: - Payment

/// Which price an alert watches. The identifiers are the backend's (`price_alerts.payment_type`).
nonisolated enum PriceAlertPayment: String, CaseIterable, Hashable, Sendable {
    /// The price shown for paying cash.
    case cash
    /// The price shown for paying by card.
    case credit
    /// An alert made before payment types existed, or a value this build has never heard of. It is
    /// compared only with reports that did not say which price they were. Never chosen, never sent.
    case unknown

    /// What a person may choose for an alert. `.unknown` is not a choice.
    static let choices: [PriceAlertPayment] = [.cash, .credit]

    /// The backend's identifier.
    var wireValue: String { rawValue }

    /// Reads the backend's identifier. A missing value, a different spelling and anything this build
    /// does not know all read as `.unknown`.
    init(wireValue: String?) {
        guard let wireValue, let known = PriceAlertPayment(rawValue: wireValue) else {
            self = .unknown
            return
        }
        self = known
    }

    /// True for the two prices a person can choose.
    var isSpecified: Bool {
        self != .unknown
    }

    /// "Cash", "Credit", "Not set".
    var title: String {
        switch self {
        case .cash: return "Cash"
        case .credit: return "Credit"
        case .unknown: return "Not set"
        }
    }

    /// "Cash price", "Credit price" — what the alert watches, as a phrase.
    var priceTitle: String {
        switch self {
        case .cash: return "Cash price"
        case .credit: return "Credit price"
        case .unknown: return "Payment type not set"
        }
    }
}

extension CommunityPaymentType {
    /// Whether a community report of this type may be judged against an alert that watches `alertPayment` — the
    /// same rule the server applies when it decides a notification (cash alert: cash and same_for_both; credit
    /// alert: credit and same_for_both; a legacy alert: unknown only; nothing else, ever). The server is
    /// authoritative; this exists so the app can say honestly which price an alert is watching.
    func isComparable(to alertPayment: PriceAlertPayment) -> Bool {
        switch (alertPayment, self) {
        case (.cash, .cash), (.cash, .sameForBoth): return true
        case (.credit, .credit), (.credit, .sameForBoth): return true
        case (.unknown, .unknown): return true
        default: return false
        }
    }
}

// MARK: - Preferences

/// The two tunables every alert carries. Both are *replaced* on every save — the backend does not
/// keep the previous values when a field is omitted — so an update always sends the full pair.
nonisolated struct PriceAlertPreferences: Hashable, Sendable {
    var minimumChange: PriceAlertAmount
    var cooldownMinutes: Int

    /// The backend's own LEGACY defaults: a 5-cent move and a 6-hour cooldown. This is what a request
    /// that says nothing gets, and what every alert made before 2.4.1 Phase 3C holds. It is not
    /// changed, and nothing rewrites an existing alert to anything else.
    static let defaults = PriceAlertPreferences(
        minimumChange: PriceAlertAmount(thousandths: 50),
        cooldownMinutes: 360
    )

    /// What a NEW alert starts with in this version of the app: the recommended 10-cent drop and the
    /// same 6-hour cooldown. The app sends it explicitly, so the server's legacy default is untouched.
    static let newAlertDefaults = PriceAlertPreferences(
        minimumChange: PriceAlertAmount(thousandths: 100),
        cooldownMinutes: 360
    )

    /// 0.010 through 2.000 dollars per gallon.
    static let minimumChangeRange = PriceAlertAmount(thousandths: 10)...PriceAlertAmount(thousandths: 2_000)
    /// One hour through one week.
    static let cooldownMinutesRange = 60...10_080
}

// MARK: - Draft (the only request-side alert type)

/// Why a draft was refused before any request was built.
nonisolated enum PriceAlertValidationFailure: Equatable, Sendable {
    case thresholdOutOfRange
    case minimumChangeOutOfRange
    case cooldownOutOfRange
    /// An existing alert's mode is one this build does not understand, so its rule cannot be carried
    /// forward unchanged into an update.
    case unsupportedMode
}

/// A validated, ready-to-send alert definition for one station.
nonisolated struct PriceAlertDraft: Equatable, Sendable {
    /// `community_stations.id`.
    let stationID: UUID
    let rule: PriceAlertRule
    let preferences: PriceAlertPreferences
    /// The price the alert watches, or `nil` when the caller did not choose one. `nil` and `.unknown`
    /// are both left OUT of the request: the server then keeps an existing alert's payment type, or
    /// stores `unknown` for a new alert — exactly what it did before payment types existed.
    let paymentType: PriceAlertPayment?

    /// - Parameter communityStationID: the backend's station UUID exactly as stored on a saved
    ///   station (`FuelStation.communityStationID`). `nil` throws
    ///   `PriceAlertsServiceError.stationNotEligibleForPriceAlerts` — see this file's header.
    /// - Throws: `stationNotEligibleForPriceAlerts`, or `invalidAlert` when a value is outside the
    ///   range the backend would reject.
    init(
        communityStationID: UUID?,
        rule: PriceAlertRule,
        preferences: PriceAlertPreferences = .defaults,
        paymentType: PriceAlertPayment? = nil
    ) throws {
        guard let communityStationID else {
            throw PriceAlertsServiceError.stationNotEligibleForPriceAlerts
        }
        if let threshold = rule.thresholdPrice, PriceAlertRule.thresholdRange.contains(threshold) == false {
            throw PriceAlertsServiceError.invalidAlert(.thresholdOutOfRange)
        }
        guard PriceAlertPreferences.minimumChangeRange.contains(preferences.minimumChange) else {
            throw PriceAlertsServiceError.invalidAlert(.minimumChangeOutOfRange)
        }
        guard PriceAlertPreferences.cooldownMinutesRange.contains(preferences.cooldownMinutes) else {
            throw PriceAlertsServiceError.invalidAlert(.cooldownOutOfRange)
        }
        self.stationID = communityStationID
        self.rule = rule
        self.preferences = preferences
        self.paymentType = paymentType
    }
}

// MARK: - Responses

/// An alert as `set_alert` returns it: no station details, no notification history.
nonisolated struct PriceAlert: Equatable, Sendable, Decodable {
    let id: UUID
    let stationID: UUID
    let mode: PriceAlertMode
    let thresholdPrice: PriceAlertAmount?
    let minimumChange: PriceAlertAmount
    let cooldownMinutes: Int
    /// Mirrors the row's `enabled`. The backend writes `true` on every save and has no operation
    /// that sets it to `false` (see docs/PRICE_ALERTS_CLIENT_INTEGRATION_2.4.1.md §1.7), so this is
    /// informational; a client must never try to send it.
    let isEnabled: Bool
    /// The price this alert watches. `.unknown` for an alert made before payment types existed and
    /// for a response from a backend that does not send the field.
    let paymentType: PriceAlertPayment

    private enum CodingKeys: String, CodingKey {
        case id
        case stationID = "station_id"
        case mode = "alert_mode"
        case thresholdPrice = "threshold_price"
        case minimumChange = "minimum_change"
        case cooldownMinutes = "cooldown_minutes"
        case isEnabled = "enabled"
        case paymentType = "payment_type"
    }

    init(
        id: UUID,
        stationID: UUID,
        mode: PriceAlertMode,
        thresholdPrice: PriceAlertAmount?,
        minimumChange: PriceAlertAmount,
        cooldownMinutes: Int,
        isEnabled: Bool,
        paymentType: PriceAlertPayment = .unknown
    ) {
        self.id = id
        self.stationID = stationID
        self.mode = mode
        self.thresholdPrice = thresholdPrice
        self.minimumChange = minimumChange
        self.cooldownMinutes = cooldownMinutes
        self.isEnabled = isEnabled
        self.paymentType = paymentType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        stationID = try container.decode(UUID.self, forKey: .stationID)
        mode = try container.decode(PriceAlertMode.self, forKey: .mode)
        thresholdPrice = try container.decodeIfPresent(PriceAlertAmount.self, forKey: .thresholdPrice)
        minimumChange = try container.decode(PriceAlertAmount.self, forKey: .minimumChange)
        cooldownMinutes = try container.decode(Int.self, forKey: .cooldownMinutes)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        // Lenient on purpose: an absent, null or unrecognised payment type is `.unknown`, never an error
        // that would make the whole alert list undecodable.
        let rawPayment = try? container.decodeIfPresent(String.self, forKey: .paymentType)
        paymentType = PriceAlertPayment(wireValue: rawPayment)
    }

    /// `nil` when the mode is one this build does not understand.
    var rule: PriceAlertRule? {
        PriceAlertRule(mode: mode, thresholdPrice: thresholdPrice)
    }

    var preferences: PriceAlertPreferences {
        PriceAlertPreferences(minimumChange: minimumChange, cooldownMinutes: cooldownMinutes)
    }
}

nonisolated struct PriceAlertStation: Equatable, Sendable {
    let name: String
    let address: String?
    let city: String?
    let state: String?
}

/// An alert as `list_alerts` returns it: the alert plus the station it watches and that station's
/// latest community report.
nonisolated struct PriceAlertListing: Equatable, Sendable, Decodable {
    let alert: PriceAlert
    let station: PriceAlertStation
    let lastNotifiedPrice: PriceAlertAmount?
    let lastNotifiedAt: Date?
    /// The newest report of ANY kind (cash, credit, either, unclassified) — what this field has always
    /// meant. It is NOT necessarily the price the alert watches; see `latestComparablePrice`.
    let latestPrice: PriceAlertAmount?
    let latestReportedAt: Date?
    /// The newest report this alert is actually judged against (its own price stream), when the backend
    /// sends it. `nil` means there is none, OR the backend predates payment types and cannot say.
    let latestComparablePrice: PriceAlertAmount?
    let latestComparableReportedAt: Date?
    /// The kind of that report: a credit alert can be judged against a report made as `same_for_both`.
    let latestComparablePaymentType: CommunityPaymentType?

    private enum CodingKeys: String, CodingKey {
        case stationName = "station_name"
        case address
        case city
        case state
        case lastNotifiedPrice = "last_notified_price"
        case lastNotifiedAt = "last_notified_at"
        case latestPrice = "latest_price"
        case latestReportedAt = "latest_reported_at"
        case latestComparablePrice = "latest_comparable_price"
        case latestComparableReportedAt = "latest_comparable_reported_at"
        case latestComparablePaymentType = "latest_comparable_payment_type"
    }

    init(from decoder: Decoder) throws {
        // The alert's own fields share the object with the joined columns.
        alert = try PriceAlert(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        station = PriceAlertStation(
            name: try container.decode(String.self, forKey: .stationName),
            address: try container.decodeIfPresent(String.self, forKey: .address),
            city: try container.decodeIfPresent(String.self, forKey: .city),
            state: try container.decodeIfPresent(String.self, forKey: .state)
        )
        lastNotifiedPrice = try container.decodeIfPresent(PriceAlertAmount.self, forKey: .lastNotifiedPrice)
        lastNotifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastNotifiedAt)
        latestPrice = try container.decodeIfPresent(PriceAlertAmount.self, forKey: .latestPrice)
        latestReportedAt = try container.decodeIfPresent(Date.self, forKey: .latestReportedAt)
        latestComparablePrice = try container.decodeIfPresent(PriceAlertAmount.self, forKey: .latestComparablePrice)
        latestComparableReportedAt = try container.decodeIfPresent(Date.self, forKey: .latestComparableReportedAt)
        latestComparablePaymentType = try container.decodeIfPresent(CommunityPaymentType.self, forKey: .latestComparablePaymentType)
    }

    init(
        alert: PriceAlert,
        station: PriceAlertStation,
        lastNotifiedPrice: PriceAlertAmount? = nil,
        lastNotifiedAt: Date? = nil,
        latestPrice: PriceAlertAmount? = nil,
        latestReportedAt: Date? = nil,
        latestComparablePrice: PriceAlertAmount? = nil,
        latestComparableReportedAt: Date? = nil,
        latestComparablePaymentType: CommunityPaymentType? = nil
    ) {
        self.alert = alert
        self.station = station
        self.lastNotifiedPrice = lastNotifiedPrice
        self.lastNotifiedAt = lastNotifiedAt
        self.latestPrice = latestPrice
        self.latestReportedAt = latestReportedAt
        self.latestComparablePrice = latestComparablePrice
        self.latestComparableReportedAt = latestComparableReportedAt
        self.latestComparablePaymentType = latestComparablePaymentType
    }
}

/// What `bootstrap` reports about the installation.
nonisolated struct PriceAlertsBootstrapResult: Equatable, Sendable {
    /// The *server's* view of Pro, resolved from the RevenueCat identity linked at bootstrap.
    let proIsActive: Bool
    let revenueCatLinked: Bool
}

/// What `status` reports.
nonisolated struct PriceAlertsServerStatus: Equatable, Sendable {
    let proIsActive: Bool
    let revenueCatLinked: Bool
    /// Enabled, non-invalidated push devices. `0` right after a successful registration means the
    /// worker has since invalidated the device.
    let activeDevices: Int
    let enabledAlerts: Int
}

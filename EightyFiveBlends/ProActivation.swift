//
//  ProActivation.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — explicit "Activate Pro" for an Apple Offer Code redeemed OUTSIDE the app
//  (GitHub issue #122). The redemption happens in the App Store, so nothing in the app can observe
//  it, and the foreground refresh (`refreshCustomerInfoNow()`) only re-reads RevenueCat's own
//  cached/server CustomerInfo — it never asks StoreKit for the new transaction. Only
//  `syncAfterExternalRedemption()` (RevenueCat `syncPurchases()`) does, and until now only the
//  referral-reward sheet called it. `ProUpgradeView` now exposes it as a user-initiated action.
//
//  NOT an entitlement source. `RevenueCatSubscriptionService.revenueCatIsPro` (CustomerInfo
//  `entitlements["pro"]?.isActive`) stays the only authority; this file reads it, never writes it, and
//  never infers Pro from a sync "succeeding". It performs no purchase and no Restore, and touches no
//  referral state. Triggered only by an explicit tap — never on foreground, appear, or a timer —
//  because `syncPurchases()` can alias/transfer purchases between anonymous RevenueCat IDs (same
//  identity semantics as the existing Restore Purchases control).
//

import Foundation

/// What one explicit "Activate Pro" attempt concluded.
enum ProActivationOutcome: Equatable, Sendable {
    /// RevenueCat already reported an active `pro` entitlement, so no sync was performed.
    case alreadyPro
    /// After the sync, RevenueCat's authoritative entitlement is active.
    case proActive
    /// The sync completed but RevenueCat still reports no active `pro` entitlement. Never success.
    case notConfirmed
    /// The sync could not complete (network, StoreKit or SDK error). Says nothing about the entitlement.
    case failed
    /// RevenueCat is not configured (yet), so there was nothing to check.
    case unavailable
}

/// Runs one activation attempt, coalescing overlapping callers onto a single sync. The three seams
/// are injected so the decision logic is testable without a real RevenueCat `CustomerInfo`
/// (see SubscriptionManagerTests.swift for why that type can't be faked); `shared` wires them to the
/// existing singletons exactly as `ReferralRewardRedemptionSheet` wires its own reconciliation.
@MainActor
final class ProActivationRunner {
    static let shared = ProActivationRunner(
        isConfigured: { RevenueCatSubscriptionService.shared.isConfigured },
        // The RAW RevenueCat entitlement, not `isPro` — a Developer Pro Override is not a purchase.
        isProActive: { RevenueCatSubscriptionService.shared.revenueCatIsPro },
        sync: { await SubscriptionManager.shared.syncAfterExternalRedemption() }
    )

    private let isConfigured: @MainActor () -> Bool
    private let isProActive: @MainActor () -> Bool
    private let sync: @MainActor () async -> Bool
    private var inFlight: Task<ProActivationOutcome, Never>?

    init(
        isConfigured: @escaping @MainActor () -> Bool,
        isProActive: @escaping @MainActor () -> Bool,
        sync: @escaping @MainActor () async -> Bool
    ) {
        self.isConfigured = isConfigured
        self.isProActive = isProActive
        self.sync = sync
    }

    /// A call made while another is in flight awaits that same attempt instead of starting a second
    /// sync, so a double tap, a re-presented paywall, or two screens can never overlap `syncPurchases()`.
    /// The attempt runs in its own unstructured task, so a caller going away neither cancels it nor
    /// leaves it half-done; the slot is released inside that task, with no window for a stale result.
    func run() async -> ProActivationOutcome {
        if let inFlight { return await inFlight.value }
        let task = Task<ProActivationOutcome, Never> { [self] in
            let outcome = await perform()
            inFlight = nil
            return outcome
        }
        inFlight = task
        return await task.value
    }

    private func perform() async -> ProActivationOutcome {
        guard isConfigured() else { return .unavailable }
        // An existing subscriber needs no sync (and no alias/transfer exposure).
        if isProActive() { return .alreadyPro }
        let synced = await sync()
        // The entitlement is re-read AFTER the sync and is the only thing that can report success: the
        // sync's own Bool means "the call worked", not "Pro is active". Re-reading also honors a
        // CustomerInfo that arrived mid-sync from the foreground refresh or `customerInfoStream`.
        if isProActive() { return .proActive }
        return synced ? .notConfirmed : .failed
    }
}

/// The Pro screen's presentation state for an activation attempt — a pure value type (like
/// `PurchaseFlow`) so double taps and stale results are directly testable. Each `begin()` hands out
/// a token; a late result can never overwrite a newer attempt or resurface after the screen was left.
struct ProActivationProgress: Equatable {
    enum Phase: Equatable {
        case idle, checking, activated, notConfirmed, failed
    }

    private(set) var phase: Phase = .idle
    private var generation = 0

    static let checkingMessage = "Checking your subscription…"
    static let activatedMessage = "85Blends Pro is active."
    static let notConfirmedMessage = "Activation can take a moment. Try again or Restore Purchases."
    static let failedMessage = "We couldn't check your subscription right now. Check your connection and try again, or use Restore Purchases."

    /// `nil` while an attempt is already in flight (a duplicate tap).
    mutating func begin() -> Int? {
        guard phase != .checking else { return nil }
        generation += 1
        phase = .checking
        return generation
    }

    /// Ignored unless `token` belongs to the attempt still in flight.
    mutating func finish(_ outcome: ProActivationOutcome, token: Int) {
        guard phase == .checking, token == generation else { return }
        phase = Self.phase(for: outcome)
    }

    /// Returns to idle (the screen was left). An in-flight token is then inert: `finish` requires
    /// `.checking`, and the next `begin()` issues a new token.
    mutating func reset() {
        phase = .idle
    }

    /// Only an active entitlement (`proActive`, or `alreadyPro`) ever maps to `.activated`.
    static func phase(for outcome: ProActivationOutcome) -> Phase {
        switch outcome {
        case .alreadyPro, .proActive: .activated
        case .notConfirmed: .notConfirmed
        case .failed, .unavailable: .failed
        }
    }

    var message: String? {
        switch phase {
        case .idle: nil
        case .checking: Self.checkingMessage
        case .activated: Self.activatedMessage
        case .notConfirmed: Self.notConfirmedMessage
        case .failed: Self.failedMessage
        }
    }
}

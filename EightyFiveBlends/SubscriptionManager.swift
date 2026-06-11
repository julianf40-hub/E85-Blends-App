//
//  SubscriptionManager.swift
//  EightyFiveBlends
//

import StoreKit
import Observation

@Observable
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    // MARK: - Product identifiers
    static let monthlyID   = "com.85blends.pro.monthly"
    static let yearlyID    = "com.85blends.pro.yearly"
    static let lifetimeID  = "com.85blends.pro.lifetime"
    static let allProductIDs: Set<String> = [monthlyID, yearlyID, lifetimeID]

    // MARK: - Free-tier soft limits (non-blocking)
    static let freeVehicleLimit      = 2
    static let freeFuelLogLimit      = 25
    static let freeSavedStationLimit = 10

    // MARK: - Debug override (DEBUG and INTERNAL_BUILD only — compiled out in App Store release)
    #if DEBUG || INTERNAL_BUILD
    enum DebugProOverride: String, CaseIterable {
        case off       = "Off"
        case forceFree = "Force Free"
        case forcePro  = "Force Pro"
    }
    var debugProOverride: DebugProOverride = .off
    #endif

    // MARK: - Observable state

    // Raw StoreKit-verified Pro status. Use `isPro` for UI logic.
    private(set) var isProStoreKit: Bool = false
    private(set) var availableProducts: [Product] = []
    private(set) var isLoadingProducts: Bool = false

    // isPro is computed so the DEBUG/INTERNAL_BUILD override routes through without touching StoreKit state.
    // In App Store release builds the compiler eliminates the conditional entirely.
    var isPro: Bool {
        #if DEBUG || INTERNAL_BUILD
        switch debugProOverride {
        case .forcePro:  return true
        case .forceFree: return false
        case .off:       return isProStoreKit
        }
        #else
        return isProStoreKit
        #endif
    }

    enum PurchaseState: Equatable {
        case idle, purchasing, restoring, succeeded
        case failed(String)
    }
    private(set) var purchaseState: PurchaseState = .idle

    // MARK: - Private
    private var transactionListenerTask: Task<Void, Error>?
    private var isRefreshing = false

    private init() {
        transactionListenerTask = Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        Task { [weak self] in
            await self?.refreshEntitlements()
            await self?.loadProducts()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Public API

    @MainActor
    func refreshEntitlements() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var hasPro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result,
               Self.allProductIDs.contains(tx.productID) {
                hasPro = true
            }
        }
        isProStoreKit = hasPro
    }

    @MainActor
    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: Self.allProductIDs)
            let order: [String: Int] = [Self.monthlyID: 0, Self.yearlyID: 1, Self.lifetimeID: 2]
            availableProducts = products.sorted { (order[$0.id] ?? 99) < (order[$1.id] ?? 99) }
        } catch {
            // Expected in Simulator without a StoreKit configuration file — safe no-op.
            availableProducts = []
        }
    }

    @MainActor
    func purchase(_ product: Product) async {
        purchaseState = .purchasing
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
                purchaseState = .succeeded
            case .userCancelled, .pending:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    @MainActor
    func restorePurchases() async {
        purchaseState = .restoring
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            purchaseState = .succeeded
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Private helpers

    @MainActor
    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let tx) = result else { return }
        await tx.finish()
        await refreshEntitlements()
    }
}

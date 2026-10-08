//
//  PriceAlertsService.swift
//  EightyFiveBlends
//
//  85Blends 2.4.1 — Price Alerts client integration (Phase 3A). The one object a Price Alerts screen
//  will talk to: it sequences the pieces below and applies the product rules, and does nothing else.
//
//      PriceAlertsAPIClient               wire format                         (PriceAlertsAPI.swift)
//      PriceAlertsInstallationManager     credential + bootstrap lifecycle    (PriceAlertsInstallation.swift)
//      PriceAlertsDeviceRegistrar         APNs token → backend                (PriceAlertsDeviceRegistration.swift)
//      PriceAlertsEntitlementProviding    "may this user configure alerts?"   (PriceAlertsEntitlement.swift)
//
//  Each is injected, so each can be replaced by a fake. There is no UI here, and constructing this
//  service reads no Keychain item, makes no request, asks for no permission and creates no
//  installation. A screen calls into it when the user acts. The one app-level caller (Phase 3B) is
//  the launch / return-to-active / APNs-token-callback reconcile: a complete no-op for an install
//  that never turned notifications on, and for one that did it only MAINTAINS the existing
//  registration — it never prompts and never creates an installation (see PriceAlertsDeviceRegistrar).
//
//  THE RULES
//  - STATION IDENTITY. An alert is created for a `communityStationID` — `FuelStation.communityStationID`,
//    the backend's `community_stations.id` — or not at all. `nil` throws
//    `stationNotEligibleForPriceAlerts`; no name, coordinate, canonical key, hash or generated UUID is
//    ever substituted. (PriceAlertDraft enforces it.)
//  - PRO. Creating or changing an alert needs Pro on the client (`proRequired`, or
//    `entitlementUnresolved` while RevenueCat has not answered) AND on the server (`set_alert`
//    returns `pro_required`; if the client thinks the user is Pro the server's RevenueCat link is
//    refreshed once and the save retried once, then `proRequiredByServer`). Listing and deleting are
//    never gated, so a lapsed subscriber can still see and remove alerts.
//  - LAPSE PRESERVES. Nothing here deletes, disables or unregisters anything because Pro ended. The
//    alert rows live on the server, which also stops sending for a non-Pro installation and resumes
//    when Pro returns; re-subscribing needs no re-creation.
//  - NO ENABLE/DISABLE. The backend has no such operation (`set_alert` always writes enabled = true;
//    see docs/PRICE_ALERTS_CLIENT_INTEGRATION_2.4.1.md §1.7). Turning an alert off is `deleteAlert`;
//    on again is `createAlert`. There is deliberately no `setEnabled`.
//  - ONE ALERT PER STATION. The server keeps one alert per installation per station and `set_alert`
//    replaces it, so `createAlert` for a station that already has one replaces it, and a change is
//    always sent as the alert's FULL state (`updateAlert` carries unchanged fields forward).
//  - PAYMENT TYPE (Phase 3C). An alert watches the cash price or the credit price. `createAlert` and
//    `updateAlert` take it as an optional `paymentType`; `updateAlert` carries the alert's current one
//    forward when none is given, and an alert whose payment type is still `unknown` (made before
//    payment types existed) stays `unknown` until someone chooses — nothing here picks one for them.
//  - THE SERVER IS AUTHORITATIVE. After every successful change the list is re-read from the server
//    rather than patched locally.
//  - ORDERING. Operations that touch the alert list run one at a time, in the order they were
//    requested, so a slow older refresh can never overwrite a newer save's result.
//

import Foundation
import Observation

@MainActor
@Observable
final class PriceAlertsService {
    enum ListState: Equatable {
        /// Nothing has been loaded this process.
        case idle
        case loading
        case loaded
        /// The last load failed; `alerts` still holds the last successful result.
        case failed(PriceAlertsServiceError)
    }

    /// The alerts last read from the server, ordered as it returned them (by station name).
    private(set) var alerts: [PriceAlertListing] = []
    private(set) var listState: ListState = .idle
    /// The outcome of the most recent registration attempt made through this service, for a screen to
    /// show. `nil` until one has been made.
    private(set) var lastDeviceRegistrationOutcome: PriceAlertsDeviceRegistrationOutcome?

    private let api: any PriceAlertsAPIClienting
    private let installation: PriceAlertsInstallationManager
    private let registrar: PriceAlertsDeviceRegistrar
    private let entitlementProvider: any PriceAlertsEntitlementProviding
    @ObservationIgnored private var operationTail: Task<Void, Never>?

    init(
        api: any PriceAlertsAPIClienting,
        installation: PriceAlertsInstallationManager,
        registrar: PriceAlertsDeviceRegistrar,
        entitlementProvider: any PriceAlertsEntitlementProviding
    ) {
        self.api = api
        self.installation = installation
        self.registrar = registrar
        self.entitlementProvider = entitlementProvider
    }

    /// Wires the whole stack from its seams. The app's instance is built from live dependencies in
    /// PriceAlertsLiveDependencies.swift; the tests build one from fakes through this same function,
    /// so the wiring itself is covered.
    static func make(
        transport: any PriceAlertsAPITransport,
        credentialStore: any PriceAlertsCredentialStoring,
        revenueCatIdentity: any PriceAlertsRevenueCatIdentityProviding,
        push: any PriceAlertsPushStateProviding,
        metadata: any PushDeviceRegistrationMetadataProviding,
        registrationRecords: any PriceAlertsDeviceRegistrationRecordStoring,
        entitlement: any PriceAlertsEntitlementProviding,
        appVersion: @escaping @Sendable () -> String? = { nil },
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) -> PriceAlertsService {
        let api = PriceAlertsAPIClient(transport: transport)
        let installation = PriceAlertsInstallationManager(
            store: credentialStore,
            api: api,
            identityProvider: revenueCatIdentity,
            appVersion: appVersion
        )
        let registrar = PriceAlertsDeviceRegistrar(
            api: api,
            installation: installation,
            push: push,
            metadataProvider: metadata,
            records: registrationRecords,
            entitlementProvider: entitlement,
            now: now,
            sleep: sleep
        )
        return PriceAlertsService(
            api: api,
            installation: installation,
            registrar: registrar,
            entitlementProvider: entitlement
        )
    }

    /// Whether the user may create or change alerts, as the client sees it.
    var entitlement: PriceAlertsEntitlement {
        entitlementProvider.entitlement
    }

    // MARK: - Reading

    /// Reloads `alerts` from the server. Never throws — the outcome is `listState`. Not Pro-gated. An
    /// install that has never used Price Alerts has no installation and therefore no alerts; that is
    /// answered locally, without creating anything.
    func refreshAlerts() async {
        try? await serialized { await self.performRefresh() }
    }

    /// The server's own view of this installation (Pro, RevenueCat link, active devices, enabled
    /// alerts), or `nil` if this install has no installation yet. Useful for diagnosing "I'm Pro but
    /// alerts are refused" and a device the worker invalidated.
    func refreshServerStatus() async throws -> PriceAlertsServerStatus? {
        do {
            return try await installation.withExistingInstallation { credential in
                try await api.status(credential: credential)
            }
        } catch {
            throw PriceAlertsServiceError.from(error)
        }
    }

    // MARK: - Writing

    /// Creates the alert for a station — or replaces the one it already has (one alert per station).
    /// - Parameter communityStationID: `FuelStation.communityStationID`, passed through untouched.
    /// - Throws: `stationNotEligibleForPriceAlerts` (nil UUID), `invalidAlert`, `proRequired` /
    ///   `entitlementUnresolved` (before any request), or what the server answered.
    @discardableResult
    func createAlert(
        communityStationID: UUID?,
        rule: PriceAlertRule,
        preferences: PriceAlertPreferences = .defaults,
        paymentType: PriceAlertPayment? = nil
    ) async throws -> PriceAlert {
        let draft = try PriceAlertDraft(
            communityStationID: communityStationID,
            rule: rule,
            preferences: preferences,
            paymentType: paymentType
        )
        return try await save(draft)
    }

    /// Changes an existing alert. Whatever is not passed keeps its current value — the backend would
    /// otherwise reset it to a default, because `set_alert` replaces the whole alert. That includes the
    /// payment type: it is sent as the existing alert's own unless a new one is given.
    @discardableResult
    func updateAlert(
        _ existing: PriceAlert,
        rule: PriceAlertRule? = nil,
        preferences: PriceAlertPreferences? = nil,
        paymentType: PriceAlertPayment? = nil
    ) async throws -> PriceAlert {
        guard let resolvedRule = rule ?? existing.rule else {
            throw PriceAlertsServiceError.invalidAlert(.unsupportedMode)
        }
        let draft = try PriceAlertDraft(
            communityStationID: existing.stationID,
            rule: resolvedRule,
            preferences: preferences ?? existing.preferences,
            paymentType: paymentType ?? existing.paymentType
        )
        return try await save(draft)
    }

    /// Removes the station's alert. Idempotent (no alert is not an error) and not Pro-gated. If this
    /// install has no installation there is nothing to delete and nothing is created.
    func deleteAlert(communityStationID: UUID?) async throws {
        guard let stationID = communityStationID else {
            throw PriceAlertsServiceError.stationNotEligibleForPriceAlerts
        }
        try await serialized {
            do {
                _ = try await self.installation.withExistingInstallation { credential in
                    try await self.api.deleteAlert(credential: credential, stationID: stationID)
                }
            } catch {
                throw PriceAlertsServiceError.from(error)
            }
            await self.performRefresh()
        }
    }

    private func save(_ draft: PriceAlertDraft) async throws -> PriceAlert {
        // Cheapest and most local first: the user-facing gate, before any request or installation.
        try PriceAlertsEntitlementPolicy.authorizeWrite(entitlementProvider.entitlement)
        return try await serialized {
            let saved: PriceAlert
            do {
                saved = try await self.saveRecoveringServerProLink(draft)
            } catch {
                throw PriceAlertsServiceError.from(error)
            }
            await self.performRefresh()
            return saved
        }
    }

    /// The client says Pro; if the server says otherwise (its RevenueCat link missing or stale — the
    /// bootstrap may have run before RevenueCat was ready, or before the webhook landed), refresh that
    /// link once and try once more. A second refusal is the server's final word.
    private func saveRecoveringServerProLink(_ draft: PriceAlertDraft) async throws -> PriceAlert {
        do {
            return try await installation.withInstallation { credential in
                try await api.saveAlert(credential: credential, draft: draft)
            }
        } catch let error as PriceAlertsAPIError where error.isProRequired {
            _ = try await installation.ensureReady(forceRebootstrap: true)
            return try await installation.withInstallation { credential in
                try await api.saveAlert(credential: credential, draft: draft)
            }
        }
    }

    // MARK: - Push delivery

    /// The user is opting in to Price Alerts notifications: prompts for permission only if they were
    /// never asked, waits briefly for the OS token, and registers it. See PriceAlertsDeviceRegistrar.
    @discardableResult
    func enablePushDelivery() async -> PriceAlertsDeviceRegistrationOutcome {
        record(await registrar.enable())
    }

    /// For a returning user on a Price Alerts screen: re-reads the OS token (never prompting) and
    /// updates the backend only if something changed.
    @discardableResult
    func reconcileDeviceRegistration() async -> PriceAlertsDeviceRegistrationOutcome {
        record(await registrar.refresh())
    }

    /// Safe for app-level code (e.g. when the app becomes active): a complete no-op — no OS call, no
    /// network, nothing recorded — for an install that has never registered a device. For one that
    /// has, it re-reads the OS token (never prompting) and updates the backend only if something
    /// changed.
    @discardableResult
    func reconcileDeviceRegistrationIfPreviouslyRegistered() async -> PriceAlertsDeviceRegistrationOutcome {
        recordUnlessNotOptedIn(await registrar.refreshIfPreviouslyRegistered())
    }

    /// For the APNs token callback: the OS has just delivered a token. Registers it if this install
    /// has registered before; does NOT ask the OS for a token (it just gave one — asking again would
    /// make it call back again) and, like the hook above, does nothing at all for an install that never
    /// opted in.
    @discardableResult
    func reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered() async -> PriceAlertsDeviceRegistrationOutcome {
        recordUnlessNotOptedIn(await registrar.reconcileAfterTokenChangeIfPreviouslyRegistered())
    }

    /// Whether this install has registered a device before — the local record only, with no OS call,
    /// no network call and no Keychain read. Lets a screen show "notifications are on" for a returning
    /// user without asking the system anything.
    var hasRegisteredDevice: Bool {
        registrar.hasRegisteredBefore
    }

    /// Asks the backend to retire this device's token. Alerts are untouched. Not automatic anywhere.
    @discardableResult
    func disablePushDelivery() async throws -> Bool {
        try await registrar.unregister()
    }

    private func record(_ outcome: PriceAlertsDeviceRegistrationOutcome) -> PriceAlertsDeviceRegistrationOutcome {
        lastDeviceRegistrationOutcome = outcome
        return outcome
    }

    /// "Nothing happened because this install never opted in" is not an outcome a screen should keep:
    /// recording it on every foreground would overwrite what the person last saw (say, a denied
    /// permission) and churn observers for an install that does not use the feature at all.
    private func recordUnlessNotOptedIn(_ outcome: PriceAlertsDeviceRegistrationOutcome) -> PriceAlertsDeviceRegistrationOutcome {
        if outcome == .skipped(.notOptedIn) {
            return outcome
        }
        return record(outcome)
    }

    // MARK: - Internals

    private func performRefresh() async {
        if listState != .loaded {
            listState = .loading
        }
        do {
            let result = try await installation.withExistingInstallation { credential in
                try await api.listAlerts(credential: credential)
            }
            alerts = result ?? []
            listState = .loaded
        } catch {
            listState = .failed(PriceAlertsServiceError.from(error))
        }
    }

    /// Runs `operation` after every previously requested serialized operation has finished.
    /// Ordering is by request (the tail is claimed synchronously, before any suspension), not by
    /// completion. The operation runs in its own task, so a caller that is cancelled while waiting
    /// does not abandon a half-finished change.
    private func serialized<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = operationTail
        let task = Task { () -> T in
            await previous?.value
            return try await operation()
        }
        operationTail = Task { _ = await task.result }
        return try await task.value
    }
}

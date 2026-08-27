//
//  EightyFiveBlendsApp.swift
//  EightyFiveBlends
//
//  Created by Julian FIgueroa on 4/27/26.
//

import SwiftUI
import SwiftData

// @MainActor so init() below can wire AutomaticPumpDetectionService (itself @MainActor)
// synchronously — see the comment on that call for why this matters for background pump
// detection. App-level code already runs on the main actor in practice; this just makes it
// explicit rather than requiring an async hop.
@MainActor
@main
struct EightyFiveBlendsApp: App {
    @AppStorage(AppPreferenceKey.themePreference) private var themePreference = ThemePreferenceOption.system.rawValue
    @AppStorage(AppPreferenceKey.accentTheme) private var accentThemeRaw = AppAccentTheme.originalGreen.rawValue

    // Drives a Pro entitlement refresh whenever the app returns to the foreground, so a
    // subscription bought, cancelled, or expired outside the app is reflected without a relaunch.
    @Environment(\.scenePhase) private var scenePhase

    @State private var locationManager = StationLocationManager()
    @State private var automaticPumpDetectionService = AutomaticPumpDetectionService()
    @State private var recentLiveStationCache = RecentLiveStationCache()
    // Stations instant-loading foundation (2.3.2, PR A; cross-launch cache added in PR #54) —
    // an in-memory session cache PLUS a small, optional, atomic on-disk preview that lets a
    // cold relaunch show the last known nearby stations immediately while a fresh search runs
    // in the background — see StationsRecentSearchStore's header for the full two-tier design.
    // Deliberately separate from recentLiveStationCache above (Pump Mode's own cache) — see
    // StationsRecentSearchStore's header for why. Injected once here, exactly like
    // recentLiveStationCache, so it survives StationsView being recreated and ordinary tab
    // switching within one app session. No change to how it's constructed or injected — the
    // default `StationsRecentSearchStore()` call below is unchanged.
    @State private var stationsRecentSearchStore = StationsRecentSearchStore()
    private let sharedModelContainer: ModelContainer
    // True when all persistent store attempts failed and we are running data-less this session.
    private let isUsingInMemoryFallback: Bool

    init() {
        let schema = Schema([
            VehicleProfile.self,
            FuelLogEntry.self,
            MaintenanceReminder.self,
            ReminderCompletionRecord.self,
            FuelStation.self,
        ])

        let (container, inMemory) = EightyFiveBlendsApp.makeContainer(schema: schema)
        sharedModelContainer = container
        isUsingInMemoryFallback = inMemory

        // Wires region-monitoring/notification callbacks and, if the feature was already
        // enabled from a previous launch, resumes it. Deliberately called here — during App
        // init, guaranteed to run before WindowGroup's content ever mounts — rather than from
        // ContentView's .onAppear as before. A didEnterRegion callback can only fire once
        // StationLocationManager's underlying CLLocationManager has a delegate (it does, from
        // the moment `locationManager`'s own default value is constructed above) AND
        // `locationManager.onRegionEvent` has been wired by attach(to:) below — the previous
        // .onAppear-based wiring left a real window, during a background/cold-launch relaunch
        // triggered BY a region event, where Core Location could invoke the delegate before
        // SwiftUI had mounted its first view and run that .onAppear — silently dropping the
        // arrival with no retry, since onRegionEvent was still nil. See the branch report.
        automaticPumpDetectionService.attach(to: locationManager)
    }

    // Returns the best available ModelContainer and whether it is in-memory only.
    private static func makeContainer(schema: Schema) -> (ModelContainer, Bool) {
        let storeName = "EightyFiveBlends.store"

        // Attempt 1: CloudKit-backed persistent store.
        let cloudConfig = ModelConfiguration(
            storeName,
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        if let container = try? ModelContainer(for: schema, configurations: [cloudConfig]) {
            #if DEBUG
            print("[85Blends] CloudKit-backed SwiftData container initialized successfully.")
            #endif
            return (container, false)
        }

        // Attempt 2: Local-only persistent store (CloudKit temporarily unavailable).
        let localConfig = ModelConfiguration(
            storeName,
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        if let container = try? ModelContainer(for: schema, configurations: [localConfig]) {
            #if DEBUG
            print("[85Blends] Fell back to LOCAL-ONLY SwiftData container (CloudKit unavailable).")
            #endif
            return (container, false)
        }

        // Both persistent store attempts failed. This can happen transiently — CloudKit
        // auth delay, a pending migration, or a first-launch race. Do NOT delete the
        // store file; it may be recoverable after a restart and deleting it would cause
        // permanent, unrecoverable data loss. Fall through to in-memory so the app
        // can still launch. The degradedStorageBanner will surface this to the user.

        // Last resort: in-memory only — data will not persist beyond this session.
        #if DEBUG
        print("[85Blends] All persistent store attempts failed — running with in-memory container.")
        #endif
        let inMemoryConfig = ModelConfiguration(
            "EightyFiveBlends-InMemory.store",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [inMemoryConfig])
            return (container, true)
        } catch {
            // Only reachable if the SwiftData model schema itself is structurally broken
            // (e.g. conflicting attributes) — a developer error that must be caught in testing.
            assertionFailure("[85Blends] In-memory container creation failed: \(error)")

            // In release builds, attempt a default no-configuration container so the app
            // can at least launch rather than hard-crashing.
            if let fallback = try? ModelContainer(for: schema) {
                return (fallback, true)
            }

            // No container of any kind could be created — the model schema is broken.
            // This is a programmer error, not a runtime failure, and cannot be recovered from.
            fatalError("[85Blends] SwiftData schema is broken — no container could be created: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(locationManager)
                .environment(automaticPumpDetectionService)
                .environment(recentLiveStationCache)
                .environment(stationsRecentSearchStore)
                .preferredColorScheme(
                    ThemePreferenceOption(rawValue: themePreference)?.colorScheme
                )
                .onAppear {
                    AppTheme.applyTabBarAppearance()
                    // automaticPumpDetectionService.attach(to:) now happens in init() above,
                    // not here — see that comment for why.
                }
                .task {
                    // 85Blends 2.3.0 — RevenueCat authoritative cutover. RevenueCat is configured
                    // exactly once here, at app startup; it owns the subscription lifecycle from
                    // this point on (see RevenueCatSubscriptionService.swift's header). This also
                    // kicks off the initial CustomerInfo fetch and offering/package load.
                    //
                    // AdMob foundation (Phase 1, audit-only — no ad units, no ad UI yet): AdManager
                    // runs its SDK init concurrently with RevenueCat's, not chained after it —
                    // neither blocks the other, and neither blocks first frame. Same reasoning as
                    // RevenueCat's own configureIfNeeded() running its CustomerInfo and offerings
                    // loads as concurrent async lets rather than sequentially. See AdManager.swift's
                    // header for why this lives here and never in init() above.
                    async let revenueCatConfigure: Void = RevenueCatSubscriptionService.shared.configureIfNeeded()
                    async let adMobConfigure: Void = AdManager.shared.configureIfNeeded()
                    _ = await (revenueCatConfigure, adMobConfigure)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Re-verify entitlement on every return to active (App Store changes,
                    // expiration, Family Sharing, refunds, etc.). refreshCustomerInfoNow() is a
                    // no-op if RevenueCat isn't configured yet, so this is safe alongside the
                    // launch .task above.
                    if newPhase == .active {
                        Task { await RevenueCatSubscriptionService.shared.refreshCustomerInfoNow() }

                        // Stations instant-loading foundation (2.3.2, PR A) — formalizes what
                        // Stations already benefited from incidentally via Calculator's own
                        // foreground location polling: a cheap, authorization-gated, one-shot
                        // location prewarm so a coordinate is often already available by the
                        // time the user opens Stations. Never requests authorization (silently
                        // no-ops if not yet granted), never starts continuous updates, and is
                        // skipped entirely when a recent-enough fix already exists — see
                        // StationLocationManager.prewarmLocationIfAuthorized() and
                        // StationsLocationFreshness.
                        if StationsLocationFreshness.isCoordinateRecentEnough(
                            fixTimestamp: locationManager.latestFixTimestamp,
                            now: .now
                        ) == false {
                            locationManager.prewarmLocationIfAuthorized()
                        }
                    }
                }
                .onChange(of: themePreference) { _, _ in
                    AppTheme.applyTabBarAppearance()
                }
                .onChange(of: accentThemeRaw) { _, _ in
                    AppTheme.applyTabBarAppearance()
                }
                .safeAreaInset(edge: .bottom) {
                    if isUsingInMemoryFallback {
                        degradedStorageBanner
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }

    private var degradedStorageBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.yellow)
                .font(.subheadline)

            Text("Storage unavailable. Data will not be saved this session.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.12))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color(white: 0.28)),
            alignment: .top
        )
    }
}

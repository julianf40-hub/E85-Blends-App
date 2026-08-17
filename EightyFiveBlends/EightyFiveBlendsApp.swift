//
//  EightyFiveBlendsApp.swift
//  EightyFiveBlends
//
//  Created by Julian FIgueroa on 4/27/26.
//

import SwiftUI
import SwiftData

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
                .preferredColorScheme(
                    ThemePreferenceOption(rawValue: themePreference)?.colorScheme
                )
                .onAppear {
                    AppTheme.applyTabBarAppearance()
                    // Wires region-monitoring/notification callbacks and, if the feature
                    // was already enabled from a previous launch, resumes it. Safe to call
                    // every launch — a no-op background-monitoring resume when disabled.
                    automaticPumpDetectionService.attach(to: locationManager)
                }
                .task {
                    // source tag is diagnostic-only (temporary entitlement investigation aid) —
                    // see SubscriptionManager.refreshEntitlements(source:).
                    await SubscriptionManager.shared.refreshEntitlements(source: "appLaunchTask")
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Re-verify entitlement on every return to active (App Store changes,
                    // expiration, Family Sharing, etc.). refreshEntitlements() guards against
                    // overlapping runs, so this is safe alongside the launch .task above.
                    if newPhase == .active {
                        Task { await SubscriptionManager.shared.refreshEntitlements(source: "scenePhaseActive") }
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

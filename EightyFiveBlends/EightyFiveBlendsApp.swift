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
            return (container, false)
        }

        // Attempt 3: Store appears corrupt — delete it and retry with CloudKit.
        let storeURL = ModelConfiguration(storeName, schema: schema).url
        try? FileManager.default.removeItem(at: storeURL)
        let freshConfig = ModelConfiguration(
            storeName,
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        if let container = try? ModelContainer(for: schema, configurations: [freshConfig]) {
            return (container, false)
        }

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
                .preferredColorScheme(
                    ThemePreferenceOption(rawValue: themePreference)?.colorScheme
                )
                .onAppear {
                    AppTheme.applyTabBarAppearance()
                }
                .onChange(of: themePreference) { _, _ in
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

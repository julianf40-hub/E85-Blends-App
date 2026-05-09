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

    private static func makeInMemoryContainer(schema: Schema) -> ModelContainer {
        let inMemoryConfig = ModelConfiguration(
            "EightyFiveBlends-InMemory.store",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: [inMemoryConfig])
        } catch {
            fatalError("Unable to create any SwiftData container for EightyFiveBlends: \(error)")
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            VehicleProfile.self,
            FuelLogEntry.self,
            MaintenanceReminder.self,
            ReminderCompletionRecord.self,
            FuelStation.self,
        ])

        let storeName = "EightyFiveBlends.store"

        do {
            let cloudConfig = ModelConfiguration(
                storeName,
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .automatic
            )
            return try ModelContainer(for: schema, configurations: [cloudConfig])
        } catch {
            do {
                let localConfig = ModelConfiguration(
                    storeName,
                    schema: schema,
                    isStoredInMemoryOnly: false,
                    cloudKitDatabase: .none
                )
                return try ModelContainer(for: schema, configurations: [localConfig])
            } catch {
                let storeURL = ModelConfiguration(storeName, schema: schema).url
                try? FileManager.default.removeItem(at: storeURL)
                let freshConfig = ModelConfiguration(
                    storeName,
                    schema: schema,
                    isStoredInMemoryOnly: false,
                    cloudKitDatabase: .automatic
                )
                do {
                    return try ModelContainer(for: schema, configurations: [freshConfig])
                } catch {
                    // Last-resort fallback so the app can still launch even if both persistent stores fail.
                    return makeInMemoryContainer(schema: schema)
                }
            }
        }
    }()

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
        }
        .modelContainer(sharedModelContainer)
    }
}

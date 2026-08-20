# 85Blends App Store Readiness Code Review

**Version:** 2.0.1 (build 47)
**Review date:** 2026-05-09
**Scope:** Full codebase audit across 11 areas. Review only — no code changes made.

---

## A. Critical Issues — Must Fix Before App Store

### A1. No SwiftData Schema Versioning or Migration Plan

**Risk:** Data loss for existing users on any model change.

All five `@Model` classes (`VehicleProfile`, `FuelLogEntry`, `FuelStation`, `MaintenanceReminder`, `ReminderCompletionRecord`) use bare `@Model` with no `VersionedSchema`, `SchemaMigrationPlan`, or migration steps. The `ModelContainer` in `EightyFiveBlendsApp.swift` uses an implicit schema.

If a future property change isn't something SwiftData's lightweight migration can absorb, SwiftData may fail to open the existing store.

**Correction (2026-08-20, verified against current code during the 2.3.0 CloudKit/SwiftData audit):** the claim in the original paragraph above — that the fallback chain deletes and recreates the store on failure — is stale and does not match the current implementation. `EightyFiveBlendsApp.swift:60-125` falls through CloudKit-backed disk store → local-only disk store → in-memory-only, and explicitly documents why the store file is never deleted (`EightyFiveBlendsApp.swift:91-96`): *"Do NOT delete the store file; it may be recoverable after a restart and deleting it would cause permanent, unrecoverable data loss."* A schema-open failure today degrades to local-only or in-memory operation — surfaced to the user only in the in-memory case, via the "Storage unavailable" banner — rather than destroying existing data.

The underlying risk is still real, just less catastrophic than originally described here: with no migration plan, an incompatible (non-additive) schema change — a property removal, rename, retype, or a new required field without a safe default — still has no tested recovery path beyond falling back to local-only or in-memory mode. Worth addressing before such a change is needed; not a 2.3.0 blocker on its own.

**Files:** `EightyFiveBlendsApp.swift`, all five `@Model` files.

### A2. API Key Embedded in Info.plist

**Risk:** API key extraction from the app binary.

`Info.plist:17` contains the NLR (NREL) API key as a plaintext string:
```
oZqG4yF2uqSegQ8BIJq6DbtPQjB1XG6OPrck
```

Info.plist values are trivially extractable from .ipa bundles. If this key has rate limits or usage quotas, anyone can extract and abuse it. The Supabase anon key (`Info.plist:19`) is designed to be client-facing and protected by Row Level Security, so it is lower risk — but the NLR key has no such server-side protection.

**Mitigation options (pick one):**
- Move the NLR key to a server-side proxy that the app calls instead.
- Accept the risk if the NLR API is free/unlimited and the key is easily rotatable.
- Use a build-time obfuscation step (limited value, but raises the bar).

**Files:** `Info.plist`, `NRELStationService.swift:137-141`, `SupabaseConfig.swift`.

### A3. Entitlements: `aps-environment` Set to `development`

**Risk:** Push notification entitlement mismatch.

`EightyFiveBlends.entitlements:5` has `aps-environment` set to `development`. Xcode's archive process typically overrides this to `production` for App Store builds, but this should be verified. If it doesn't, push-related capabilities will fail in production.

The app registers `remote-notification` as a background mode (`Info.plist:23-25`) but does not appear to have any push notification handling code. If push notifications are not used, consider removing both the `aps-environment` entitlement and the `remote-notification` background mode to avoid unnecessary App Store review scrutiny.

**Files:** `EightyFiveBlends.entitlements`, `Info.plist`.

---

## B. High Priority — Should Fix Before App Store

### B1. Vehicle-to-Data Linkage by Name String

**Risk:** Orphaned data on vehicle rename.

`FuelLogEntry`, `MaintenanceReminder`, and `ReminderCompletionRecord` all reference vehicles by `vehicleName: String` rather than a SwiftData relationship. If a user renames a vehicle in the Garage, all associated fuel logs, reminders, and completion records become orphaned — they still reference the old name and won't appear under the renamed vehicle.

**Fix:** Either propagate the rename across all related records, or migrate to SwiftData `@Relationship` references.

**Files:** `FuelLogEntry.swift:13`, `MaintenanceReminder.swift:13`, `ReminderCompletionRecord.swift:14`, `GarageView.swift` (edit vehicle flow), `FuelLogStore.swift`.

### B2. Silent Data Save Failures — RESOLVED

**Correction (2026-08-20, verified against current code during the 2.3.0 CloudKit/SwiftData audit):** this finding is stale and no longer matches the implementation. `FuelLogStore.swift:81-86` now uses `do { try modelContext.save() } catch { AppHaptics.warning(); throw FuelLogStoreError.saveFailed }` — the error is no longer silently discarded. The caller, `AddEditFuelLogView.swift:67-69`, catches the thrown error and surfaces it via `.alert("Couldn't Save Fill-Up", ...)` (`AddEditFuelLogView.swift:103-109`). A local save failure is now both propagated and shown to the user, matching this section's original **Fix** recommendation.

**Scope note — do not read this as "all save failures are now visible":** this covers the *local* `modelContext.save()` call only — i.e., whether the write reached the on-disk store. It does not cover the asynchronous CloudKit import/export SwiftData performs afterward; that path has no error observation anywhere in the app (no `CKError`/`NSPersistentCloudKitContainer` event handling exists), so a CloudKit sync failure after a successful local save remains invisible to the user. That is a separate, still-open architectural gap, not something this correction claims to have fixed.

**Original finding (historical, no longer accurate):** ~~`FuelLogStore.swift:68` uses `try? modelContext.save()` which silently ignores save errors. If the persistent store is full, corrupted, or CloudKit sync fails, the user gets a success haptic (`AppHaptics.success()` on line 69) but their data is not actually persisted.~~

**Files:** `FuelLogStore.swift:81-86`, `AddEditFuelLogView.swift:67-69,103-109`.

### B3. Location Usage Description Mismatch

**Risk:** App Store rejection for misleading privacy string.

`Info.plist:12` says: *"85Blends uses your location to show nearby E85 stations and help detect when you are at a saved station."*

`project.pbxproj:292` (build settings) says: *"85Blends uses your location to show nearby E85 stations when you request it."*

The Info.plist version is more accurate and complete. The build settings version may override or conflict depending on build configuration. Ensure only one authoritative string exists.

**Files:** `Info.plist:12`, `project.pbxproj:292,331`.

### B4. Community Price Notes Field Unsanitized

**Risk:** Oversized or malformed data sent to Supabase.

`CommunityPriceService.swift:198` trims whitespace from the notes field but does not enforce a length limit. A user could submit an arbitrarily long string. This should be validated client-side (e.g., 500 character max) in addition to any server-side constraints.

**Files:** `CommunityPriceService.swift:198`, `StationsView.swift` (price update sheet).

### B5. No Network Timeout Configuration

**Risk:** Indefinite hangs on poor connectivity.

Both `CommunityPriceService` and `NLRStationService` use `URLSession.shared` with no custom timeout configuration. On poor cellular connections, requests could hang for the system default (60 seconds) with no user feedback. Consider setting `timeoutIntervalForRequest` to 15-20 seconds and showing a loading indicator.

**Files:** `CommunityPriceService.swift:36`, `NRELStationService.swift:104`.

### B6. Files at Project Root Instead of Source Subfolder

**Risk:** Build target confusion, incorrect file references.

Three Swift files exist at the project root (`/EightyFiveBlends/`) instead of the source subfolder (`/EightyFiveBlends/EightyFiveBlends/`):
- `CostCalculatorView.swift`
- `StationLocationManager.swift`
- `NRELStationService.swift`

These are included in the build target via `project.pbxproj` references, so they compile correctly. However, this inconsistency can cause confusion and makes the project harder to navigate. Move them into the source subfolder.

**Files:** The three files listed above, `project.pbxproj`.

---

## C. Medium Priority — Improvements

### C1. Large View Files

Several views exceed 1000 lines, making them harder to maintain, review, and test:

| File | Lines | Suggestion |
|------|-------|------------|
| `StationsView.swift` | ~2124 | Extract map logic, search, price sheet, community sync into separate files |
| `CalculatorView.swift` | ~1250 | Extract blend result display, pump mode logic, fuel log sheet |
| `RemindersView.swift` | ~1181 | Extract reminder row, status logic, completion sheet |
| `OnboardingView.swift` | ~828 | Extract individual step views |

Not a blocker for launch, but will slow down future development.

### C2. Duplicated Sponsor Card

The RVP Supply sponsor card (image, tap-to-visit, error message) is duplicated identically in `MoreView.swift:128-166` and `RecommendedGearView.swift:48-86`, including the `openSponsorLink()` method. Extract to a shared component.

**Files:** `MoreView.swift`, `RecommendedGearView.swift`.

### C3. Gas Grade Picker Not Used in Calculation

`CostCalculatorView.swift:137-166` displays a gas grade picker (87/89/91/93) and stores the selection in `selectedGasGrade`, but this value is only used in the break-even card's description text (`line 266`). It does not affect any cost calculation. This could confuse users who expect changing the grade to change the price or result.

**Options:** Remove the picker, or use it to auto-suggest a gas price, or clarify in the UI that it's for reference only.

**Files:** `CostCalculatorView.swift:16,137-166,266`.

### C4. No Unit Tests

There are no test targets or test files in the project. `BlendCalculator` is a pure function with well-defined edge cases — it's an ideal candidate for unit testing. `FuelLogStore.calculateMPG` and the community price normalization logic are also testable.

### C5. Vehicle Photo Size in CloudKit

`VehicleProfile.vehiclePhotoData` stores the photo as raw `Data` in SwiftData. While `AddEditVehicleView` resizes images to 1200x1200 at 0.75 JPEG quality, this can still be 200KB-1MB per vehicle. With CloudKit sync enabled, this counts against the user's iCloud quota and can slow sync. Consider documenting the size limit or reducing it further (e.g., 600x600).

**Files:** `VehicleProfile.swift:27`, `AddEditVehicleView.swift` (photo resizing logic).

### C6. `modelContext.save()` Not Called After Reminder/Vehicle Edits

While `FuelLogStore` explicitly calls `modelContext.save()`, other write paths (editing vehicles in `GarageView`, completing/editing reminders in `RemindersView`) rely on SwiftData's auto-save behavior. This is generally fine, but auto-save timing is not guaranteed — a crash immediately after an edit could lose the change.

---

## D. Low Priority — Post-Launch Ideas

### D1. Accessibility

No explicit `accessibilityLabel` or `accessibilityHint` modifiers on interactive elements like the blend tier chips, fuel level grid, gas grade picker, or MPG loss chips. VoiceOver users may hear unhelpful labels like "Button" for these controls.

### D2. Localization

All user-facing strings are hardcoded in English. No `.strings` files or `LocalizedStringKey` usage. Fine for US-only launch but blocks international expansion.

### D3. Error Handling in BlendCalculator

`BlendCalculator.calculate()` returns warning messages as strings in the result. Consider using a typed enum for warnings so callers can differentiate between "tank is full" (informational) and "inputs are invalid" (error) states programmatically.

### D4. Tab Visibility UX

Users can hide the Garage, Reminders, and Gear tabs via Preferences. If all optional tabs are hidden, the app has only Calculator, Stations, and More — which is fine, but there's no warning or confirmation. Consider a minimum tab count or a confirmation dialog.

### D5. Stale Community Price Data

Community prices are fetched once when `StationsView` appears but there's no pull-to-refresh or automatic refresh interval. Prices could be hours or days old during a long session. Consider adding a manual refresh button or a time-based refresh.

---

## E. Files Most Likely Involved for Each Issue

| Issue | Primary Files |
|-------|---------------|
| A1 Schema versioning | `EightyFiveBlendsApp.swift`, all `@Model` files |
| A2 API keys | `Info.plist`, `NRELStationService.swift`, `SupabaseConfig.swift` |
| A3 Entitlements | `EightyFiveBlends.entitlements`, `Info.plist` |
| B1 Name-based linkage | `FuelLogEntry.swift`, `MaintenanceReminder.swift`, `ReminderCompletionRecord.swift`, `GarageView.swift` |
| B2 Silent save | `FuelLogStore.swift` |
| B3 Location string | `Info.plist`, `project.pbxproj` |
| B4 Notes sanitization | `CommunityPriceService.swift`, `StationsView.swift` |
| B5 Network timeout | `CommunityPriceService.swift`, `NRELStationService.swift` |
| B6 File locations | `CostCalculatorView.swift`, `StationLocationManager.swift`, `NRELStationService.swift` |
| C2 Sponsor card | `MoreView.swift`, `RecommendedGearView.swift` |
| C3 Gas grade picker | `CostCalculatorView.swift` |

---

## F. Suggested Safe Fix Order

This order minimizes risk and avoids cascading changes:

1. **A3** — Verify entitlements (inspect only; Xcode may auto-fix on archive).
2. **B3** — Resolve location usage description conflict (one small string change).
3. **B6** — Move misplaced files into source subfolder (file move + pbxproj update).
4. **B4** — Add notes length limit in community price report (one guard clause).
5. **B5** — Add URLSession timeout configuration (small init change).
6. ~~**B2** — Surface save errors to the user (add error propagation to FuelLogStore).~~ **Resolved** — see the correction note under B2 above (2026-08-20).
7. **A2** — Evaluate NLR API key risk and decide on mitigation.
8. **C2** — Extract shared sponsor card component (safe refactor).
9. **C3** — Decide on gas grade picker behavior (UI decision).
10. **A1** — Add schema versioning (important but complex; do this when the schema is stable).
11. **B1** — Migrate vehicle linkage (highest-effort change; defer if no rename feature exists yet).

---

## G. Areas That Should Not Be Touched

- **`project.pbxproj`** — Only touch for file moves (B6). Do not change signing, deployment target, or capabilities.
- **`EightyFiveBlendsApp.swift` ModelContainer fallback chain** — The 4-level fallback is robust and well-tested. Don't simplify it.
- **`BlendCalculator.swift`** — Pure, correct, well-structured calculation engine. Leave as-is unless adding tests.
- **CloudKit configuration** — iCloud container ID and CloudKit entitlements are correct. Do not modify.
- **Supabase RLS / anon key setup** — The anon key is the correct key type for client-side use. Do not swap for a service role key.
- **`AppTheme.Colors`** — The dynamic color system with light/dark/OLED support is consistent across all views. Do not restructure.
- **Bundle identifier** (`com.e85blends.app.ios`) — Do not change.
- **Build number / version** — Do not increment during this review pass.

---

*End of review. No files were modified during this audit.*

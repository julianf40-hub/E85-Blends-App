# 2.2.2 Reliability Polish — Engineering Notes

Branch: `feature/2.2.2-reliability-polish`. Scope: low-risk, headless-verifiable reliability
work ahead of 2.3.0 Nearby E85 Widgets. No widget target, entitlements, App Groups,
StoreKit config, bundle IDs, signing, or `project.pbxproj` changes. No visual/SwiftUI
redesign. See the branch's audit + final report for the full findings list; this doc covers
the authoritative code paths and calculation assumptions going forward.

## 1. Authoritative blend calculation path

`EightyFiveBlends/BlendCalculator.swift` is the single source of truth for blend math.
`calculate(input:)` solves for a target blend; `gasOnlyFill(input:)` projects a gas-only
top-off. Both share the same guard order:

1. All numeric inputs finite (`isFinite`) → else "Enter valid numeric values..."
2. `tankSizeGallons > 0`
3. `currentFuelLevelPercent` and all ethanol percentages within `0...100`
4. Octanes `>= 0`
5. `targetFuelLevelPercent` (partial fill), if set: must be `<= 100` and `>= currentFuelLevelPercent`

Do not reimplement the ethanol-mixture formula (`(target·targetGallons - current·currentGallons
- space·gasEthanol) / (e85Ethanol - gasEthanol)`) anywhere else — `CostCalculatorView.swift`
currently has its own independent copy (see "Known duplication left in place" below).

**Fixed this branch:**
- `targetFuelLevelPercent` had no upper-bound guard — a value above 100% silently computed a
  fill beyond the tank's physical capacity. Both `calculate` and `gasOnlyFill` now reject it.
- `label(for:)` called `Int(percent.rounded())`, which traps on NaN/infinite input. A NaN
  `targetEthanolPercent` reached this from `warningResult`'s own "handle invalid input
  gracefully" path, meaning the guard meant to protect against bad input could itself crash
  the app. Both `label(for:)` and `warningResult`'s fallback percent are now NaN/infinity-safe.
  This was not reachable through the shipped UI (all current callers clamp with `?? 0`/`?? 30`
  before calling in), but the calculator's own public contract now actually holds.

Tests: `EightyFiveBlendsTests/BlendCalculatorTests.swift`.

## 2. Authoritative reminder scheduling path

`EightyFiveBlends/ReminderScheduling.swift` is the single source of truth for reminder day
math: `isOverdue(dueDate:asOf:calendar:)`, `wholeDays(from:to:calendar:)`, and
`nextDueDate(afterCompleting:repeatIntervalDays:calendar:)`. `RemindersView.swift` (both
`completeReminder` and `ReminderStatusInfo`) delegates to these instead of five independent
inline `Calendar.current.dateComponents([.day], ...)` calls.

Recurrence today is **day-interval based** (`repeatDateIntervalDays: Int`), not a
calendar-month/day-of-month recurrence — there is no "repeat on the 15th of every month"
concept in the model. `Calendar.date(byAdding:.day,...)` correctly and automatically handles
month-length differences (Jan 31 + 30 days lands on a real date the following month) and DST
transitions (adding a day preserves wall-clock time across a spring-forward/fall-back
boundary), so no month/DST-specific special-casing was needed — just tests proving it. Every
DST/leap-year date used in the tests was cross-checked against real Unix-epoch arithmetic
before being written as an assertion, since no Swift runtime was available to verify them by
actually running the tests.

`nextDueDate` returns `nil` for a non-positive `repeatIntervalDays` (defense in depth —
`AddEditReminderView` already clamps this to `>= 0` before save, so this should never be
exercised in practice, but the shared function no longer trusts that alone).

**Not applicable / intentionally not built:** this app has no `UNUserNotificationCenter` /
local push notification scheduling anywhere. "Notification authorization denied/revoked" and
"duplicate notification scheduling" are reliability scenarios that only apply to a
notifications feature that doesn't exist yet — building one would be new functionality, not
reliability work, so it's out of scope for this branch.

**Verified, not changed:** deleting a vehicle does not cascade-delete its reminders/fuel logs
(`GarageView.confirmDeletion`) — they're preserved and remain visible under "All Vehicles" or
the vehicle's own filter, matched by `vehicleName` string. Renaming a vehicle *does* propagate
to reminders (`RemindersView.propagateVehicleRename`). This is existing, intentional
history-preserving behavior — no code change made here.

Tests: `EightyFiveBlendsTests/ReminderSchedulingTests.swift`.

## 3. Station price validation and freshness rules

`EightyFiveBlends/StationDataValidation.swift` centralizes:
- `isValidPrice(_:)` — finite, `> 0`, `<= 15.0` (`maximumPlausiblePricePerGallon`, matching the
  sane-range ceiling already documented in `docs/PRE_RELEASE_SUPABASE_CHECKLIST.md` for
  community price reports, so the client and the recommended server-side `CHECK` constraint
  agree on what counts as a plausible price).
- `isValidCoordinate(latitude:longitude:)` — finite, in-range, and rejects `(0, 0)` ("Null
  Island") as unset/placeholder data rather than a real station.
- `isValidTimestamp(_:asOf:futureToleranceSeconds:)` — rejects epoch-zero/negative timestamps
  and anything more than 5 minutes in the future (clock-skew tolerance).
- `daysSince`/`isStale`/`priceFreshnessTier` — the 7-day "Fresh" / 14-day "Check Price" /
  stale tiering already used by `StationsView`'s price badges, now in one place.
- `normalizedNameKey`/`isDuplicateName` — the case/whitespace-insensitive station name
  matching used when linking a fuel-log entry to a saved station.

Wired in this branch:
- `FuelLogStore.updateStationIfNeeded` now rejects non-finite/absurd prices instead of
  writing them straight into `FuelStation.lastKnownE85Price`, and uses the shared
  `isDuplicateName` for its case-insensitive station match.
- `StationsView.updateStation` (manual station edit) now rejects an invalid price or
  out-of-range coordinates before saving, surfacing the existing `infoMessage` alert instead
  of silently persisting bad data. Existing favorites/history are never touched by this check
  — it only gates the specific edit being saved.
- `StationsView`'s `daysSincePriceUpdate` and the `Date.communityReportedText` /
  `communityPriceIsStale` extension now call the shared `daysSince`/`isStale` instead of each
  reimplementing the same `Calendar.current.startOfDay` diff.

**Known duplication left in place (deferred, not touched this branch):** `StationsView.swift`
and `RouteE85Planner.swift` each still have their own private, near-identical
`isValidCoordinate(latitude:longitude:)` (missing the `isFinite` guard `StationDataValidation`
adds). They're private to unrelated call sites in files with their own risk profile
(`RouteE85Planner` in particular has documented iOS-27 MapKit/actor-isolation workarounds
nearby) — unifying them wasn't done here to keep this branch's diff surgical. Worth a
follow-up.

Tests: `EightyFiveBlendsTests/StationDataValidationTests.swift`.

## 4. Fuel Analytics calculation foundation

`EightyFiveBlends/FuelAnalyticsEngine.swift` is a new, pure (no SwiftUI/SwiftData import),
fully unit-tested engine: totals (spending, gallons, fill-up count), averages (price/gallon,
ethanol content, gallons/fill-up), mileage-dependent metrics (total miles driven, cost/mile),
average logged MPG, filtering by vehicle/date range, and trends grouped by week or month.

**Not wired into any UI yet** — `AdvancedAnalyticsView` remains the existing placeholder Pro
shell ("Chart coming soon", metric tiles reading "—"). This branch intentionally stops at the
calculation layer per the task's scope ("do not expose a new public feature yet"); no feature
flag was added because there's no new UI behind one to gate.

Key invariant, enforced throughout and covered by tests: **MPG and cost-per-mile are never
fabricated.** `costPerMile` returns `nil` unless there's both real spending and a real
positive odometer spread for at least one vehicle; `averageLoggedMPG` returns `nil` unless at
least one entry has a positive logged `mpg` (mirroring `FuelLogStore.calculateMPG`'s existing
"0 means not enough data" convention rather than reimplementing that per-entry calculation).

Tests: `EightyFiveBlendsTests/FuelAnalyticsEngineTests.swift`.

## 5. Other crash/reliability fixes this branch

- **`StationLocationManager` is now `@MainActor`.** Its `CLLocationManagerDelegate` callbacks
  mutate `@Observable` state that drives SwiftUI (map recentering, pump-mode auto-trigger)
  without previously being isolated to the main actor. Every call site uses it exclusively via
  `@Environment(StationLocationManager.self)` in views or `@State` in the `App` struct — all
  already main-actor contexts — so this closes the isolation gap without changing any call
  site's behavior. Matches the `@MainActor` discipline `SubscriptionManager` already uses
  elsewhere in this codebase.
- **`OnboardingView`'s vehicle save failure is no longer silent.** Previously, a failed
  `modelContext.save()` while creating the onboarding vehicle only printed in `#if DEBUG` and
  then unconditionally continued to `hasCompletedOnboarding = true` — a new user could finish
  setup believing their vehicle was saved when it wasn't. It now surfaces a "Save Error" alert
  (the same idiom already used in `GarageView`/`RemindersView`/`FuelLogView`/`StationsView`)
  and returns before marking onboarding complete, so the user can retry instead of silently
  losing their vehicle profile.

## 6. What still requires Xcode, simulator, or device validation

- **Running any of the tests in this branch, or the pre-existing on-disk tests
  (`BlendCalculatorTests`, `PumpProximityTests`, `RouteE85PlannerTests`).** Per `CLAUDE.md`,
  there is no test target wired into `project.pbxproj` yet, and no testable reference in
  either scheme. This branch deliberately does not attempt to wire one up by hand-editing
  `project.pbxproj` — that's exactly the kind of project-file surgery this branch is scoped
  to avoid. A human needs to add a unit test target in Xcode (File → New → Target → Unit
  Testing Bundle, pointing at the existing `EightyFiveBlendsTests` folder) before any of these
  tests can actually execute. Every new test in this branch was instead hand-verified against
  the production formulas/guards it exercises, and DST/leap-year date math was additionally
  cross-checked against real Unix-epoch arithmetic before being written as an assertion.
- **A full build.** No Swift toolchain is available in this environment (confirmed —
  `swift`/`swiftc` are not installed), so nothing in this branch has been compiled. All edits
  were reviewed line-by-line for syntax, argument order (Swift requires labeled initializer
  arguments in declaration order — this was checked explicitly for every new `Input(...)` /
  `FuelLogEntry(...)` call), and brace/paren balance (verified with a script, see the branch's
  final report).
- **VoiceOver behavior.** The audit flagged several icon-only controls and sliders missing
  `.accessibilityLabel`/`.accessibilityValue`, and decorative icons that may double-announce.
  None of that was changed in this branch (see final report — deferred as requiring
  interaction judgment / device verification, not appropriate for a headless pass).
- **Confirming the new `.alert` in `OnboardingView` renders and dismisses correctly**, and
  that adding `@MainActor` to `StationLocationManager` doesn't shift actor-isolation
  requirements elsewhere in the file graph — both are standard, low-risk patterns already used
  elsewhere in this codebase, but a real build/run is the only way to fully confirm them.

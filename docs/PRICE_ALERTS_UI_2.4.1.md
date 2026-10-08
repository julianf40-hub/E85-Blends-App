# Price Alerts UI and app wiring — 2.4.1, Phase 3B

Phase 3B puts a user interface and the app lifecycle wiring on top of the Phase 3A client
([`PRICE_ALERTS_CLIENT_INTEGRATION_2.4.1.md`](PRICE_ALERTS_CLIENT_INTEGRATION_2.4.1.md)). A Pro user can
open Price Alerts for an eligible station, choose **Price Drop** or **At or Below $X**, save, see and edit
what the server holds, turn an alert off, and opt in to notifications. **Nothing was sent to production
while building it** — every test runs over fakes — and **real push delivery has not been tried**: see
[§6](#6-before-a-real-push-test).

Status: Phase 3B is a stacked branch on Phase 3A (`767f9de`), not merged, not released.

> **Phase 3C changed this screen.** An alert now watches **Cash or Credit** (chosen explicitly — there is no default,
> and an alert made before payment types existed is offered a calm "Choose Your Price Type" step — Phase 3C.1, §1.9), and a Price Drop has a **drop
> size**: 5¢, 10¢ (Recommended; the default for a *new* alert), 20¢ or Custom (0.01–2.00). The sheet is now: status,
> alert type, **price to watch**, **drop size** (Price Drop) or target price (At or Below), Save, notifications, Turn Off.
> The central list shows the price type and drop size per alert and the alert's own latest comparable price. The
> two-kind rule, the price field, saving/editing, Turn Off, Pro behavior and notifications below are otherwise as
> described. Details, rules and tests: [`PRICE_ALERTS_PAYMENT_TYPES_2.4.1.md`](PRICE_ALERTS_PAYMENT_TYPES_2.4.1.md) §8.3.
> Statements below that the sheet has no minimum-change control, or that the delivery note quotes `$0.05`, describe
> Phase 3B as delivered.

## 1. What a person sees

### 1.1 Entry points

A **bell** appears on a station only when the backend's community-station UUID is known for it — the one
saved on the station (`FuelStation.communityStationID`) or the one on its community price / ethanol
summaries. Nothing is ever derived from a name, address, coordinates, canonical key or GasBuddy id
(`PriceAlertsStationIdentity`, `PriceAlertStationTarget`: a target cannot even be constructed without the UUID).

| Surface | Entry |
|---|---|
| Classic saved-station card | icon button beside Share |
| Classic nearby-station card | icon button beside Share |
| Pro map, selected-station card | full-width "Price Alert" row in the scrollable details (the action row is four equal columns and has no room for a fifth at larger text sizes) |
| Stations screen (Normal mode) and More | "Station Price Alerts" row in the Pro section, opening the Price Alerts screen (§1.7) |

An **ineligible station shows no entry at all.** It is hidden rather than disabled: a dimmed icon on a dense
card cannot carry an explanation, and the usual reason (nobody has reported a price or ethanol percentage
there yet) is not something the person can act on. A station becomes eligible once the backend knows it.

A **Free** user sees the bell with a small lock; it opens the sheet's Pro card. While RevenueCat has not yet
answered (**unresolved**) the bell carries *no* lock and the sheet says "Checking your subscription…" —
an unresolved entitlement is never presented as Free.

### 1.2 The sheet

One compact sheet (`PriceAlertSheet`, detents medium/large) for every entry point. By state
(`PriceAlertsStationModel.Phase`):

| Phase | Shown |
|---|---|
| resolving entitlement | "Checking your subscription…" with Try Again (`SubscriptionManager.refreshProStatus()`) |
| Pro required | the existing locked-feature card (`ProFeatureLockView`) and, through it, the one `ProUpgradeView` paywall. A purchase made from it turns the card into the form with no relaunch. |
| loading / load failed | a spinner / the friendly reason with Try Again |
| ready | station, alert status, alert type, price (At or Below), Save, notifications, Turn Off |

Opened from the Price Alerts screen, the alert is shown at once (the list is already loaded).

### 1.3 Alert types — exactly two

* **Price Drop** — "Notify me when this station reports a lower E85 price." No threshold and no percentage:
  the backend has none for `price_drop`.
* **At or Below** — "Notify me when E85 reaches my target price." Needs a price.

`any_change` exists on the backend and is **never offered** (`PriceAlertKind` has two cases; a test proves
the form can produce no other rule). An `any_change` alert made elsewhere, or a mode this build has never
heard of, is *shown* ("Any price change" / "Custom alert") and can be replaced by choosing a type; it cannot
crash anything. (Phase 3C.1: while such an alert is only being moved to Cash or Credit, the form **carries** its rule and saves it
back unchanged — choosing a price type never converts it to a Price Drop; only an explicit choice of a type does, §1.9.)
Under the form, one sentence states how often the alert can fire, built from the alert's
own preferences (default: drops of $0.05 or more, at most once every 6 hours per station) so it cannot
disagree with what is sent.

### 1.4 The price field (`PriceAlertPriceInput`)

Dollars per gallon, decimal-pad keyboard, accessible label and hint, `$` prefix; a tap anywhere in the
drawn box focuses it. It is parsed to **integer
thousandths** — never through a `Double` — and converted to `PriceAlertAmount`.

* digits and one decimal mark; a pasted leading `$` is tolerated; a comma is read as the decimal mark
  (`3,25` is $3.25, `1,234.5` is refused — no fuel price has a thousands separator);
* **at most three decimals; a fourth is refused, never rounded away** — what is in the field is what is
  saved or rejected, never a quietly different number;
* no negatives (their own message), signs, exponents, letters, inner spaces or non-ASCII digits;
* 1.000 – 8.000 inclusive, read from `PriceAlertRule.thresholdRange` (the backend's bound);
* an empty field is guidance ("Enter the price per gallon you're waiting for, between $1.00 and $8.00"),
  not an error; a wrong one is explained under the field before Save is possible.

Switching between types **keeps the typed price**, so a mis-tap costs nothing; it is simply not part of a
Price Drop alert and is never sent for one. After a successful save the form is re-seeded from the server's
answer, which is what clears it for a Price Drop alert.

### 1.5 Saving, editing, turning off

* **Save** is offered only for a complete form that differs from what the server holds ("Create Alert" /
  "Update Alert"). A double tap saves once. An update sends the alert's **full state**: the preferences
  it already had are carried forward (the backend replaces the whole alert). A failed save keeps
  everything typed, says why in plain words and can be retried; the success is announced to VoiceOver
  and gets a subtle haptic.
* **Turn Off** asks first, using the app's `DestructiveConfirmationOverlay`: "Turn Off Price Alert?" /
  "You won't receive Price Alert notifications for this station unless you create a new alert." It calls
  `deleteAlert` — the backend has no enable/disable, so there is nothing to "pause", and the word is never
  used. **It does not touch the device's push registration**: the person's other alerts keep arriving.
* The **server is authoritative.** The sheet holds only the form; the alert it displays is read from the
  service's list on every render, refreshed after every change. A slow earlier load cannot overwrite a
  newer save, a failed turn-off leaves the alert exactly as it was, and if the refresh *after* a save
  fails the sheet says so and keeps the saved values rather than reverting to the stale list.
* **Pro lapse** changes what the sheet shows (the Pro card) and nothing else: no alert is deleted,
  disabled or unregistered, on the device or the server, and renewal brings the same alerts back. The
  backend remains authoritative at send time.

### 1.6 Notifications (`PriceAlertsNotificationCard`)

**Only a tap starts it.** Opening a sheet, loading, saving and turning an alert off never prompt, never
register and never touch the OS (a person who allowed notifications for pump arrival alerts is not silently
registered for Price Alerts because they looked at a station). The card's one button calls
`PriceAlertsService.enablePushDelivery()`; no SwiftUI file calls `UNUserNotificationCenter` or
`registerForRemoteNotifications()`. The card reflects the service's most recent registration outcome, so
coming back from Settings after revoking permission flips it with no help from the screen:

| State | Card | Action |
|---|---|---|
| never opted in | "Turn on notifications" | Turn On Notifications |
| in progress | "Setting up notifications…" | — |
| registered / already registered | "Notifications are on" | — |
| denied | "Notifications are turned off … Your alerts are saved either way." | Open Settings |
| no device token (still waiting, simulator, **no Push capability**) | "Notifications aren't ready yet … Your alerts are saved." | Try Again |
| push environment unresolved | "Notifications aren't available yet" | — |
| Pro required / subscription unresolved | a lock / "Checking your subscription" | — / Try Again |
| backing off | "We'll try again shortly" | Try Again (bypasses the wait) |
| failed | the friendly error | Try Again if it can help |

### 1.7 The Price Alerts screen

`StationAlertsView` used to be a placeholder with local toggles that did nothing. Left beside a live feature
it would have been a lie, so it is now real: the alerts the server holds, the notification card, and a row
per alert that opens the same sheet (where changing and turning off happen — one implementation of saving,
validation and confirmation). It is reached through `ProFeatureGate` from More and from the Stations
screen's Pro section, which previously listed it under "Coming Soon". (Phase 3C.1: when any alert has no payment type the list opens
with one "Choose Your Price Type" explanation, and each such row carries a "Payment type needed" banner with an Edit button — §1.9.)

### 1.8 Messages

Every error maps to friendly text (`PriceAlertsUserMessage`) and **none shows an HTTP status, backend error
code, function name, installation id, secret or token** — a test scans the whole matrix of errors for them.
"Pro required" and "still checking your subscription" are different messages; the server refusing a save
for a client that believes it is Pro (`proRequiredByServer`, e.g. the Developer Pro Override) reads "Couldn't
confirm Pro yet … if you just subscribed, wait a minute and try again".

### 1.9 Alerts made before payment types existed (Phase 3C.1)

Why: such an alert (`payment_type = unknown` on the server) is kept exactly as it was and keeps watching reports that did not say
Cash or Credit. As more people report typed prices, fewer unclassified reports arrive, so the alert would slowly stop hearing about
its station. Nobody should find that out by silence, and nobody's alert should be changed behind their back.

| Where | What is shown | Source of truth |
|---|---|---|
| Price Alerts list, once, above the rows | "Choose Your Price Type" / "Price reports now distinguish Cash and Credit prices. Choose which price you want to watch to keep your alerts up to date." | `PriceAlertsOverviewModel.paymentChoicePrompt` — only in the loaded list state, only while some alert has no payment type |
| each such row | a yellow-edged banner "Payment type needed" / "Choose Cash or Credit to continue watching this station's prices." and an **Edit** button (44 pt; the banner stacks text above the button so it survives the largest Dynamic Type) | `PriceAlertsOverviewModel.Row.paymentChoiceBanner` |
| the sheet (from the row, from Edit, or from the station's bell) | the same prompt first, containing the Cash / Credit picker; "Your alert type and settings stay the same."; after a choice on a Price Drop, how the starting point works | `PriceAlertsStationModel.paymentChoicePrompt`, `PriceAlertPaymentChoicePrompt.make` |

Rules (each is a test in `PriceAlertsLegacyMigrationTests.swift`):

* **Server-driven.** `PriceAlertWatch.needsPaymentChoice` is computed from the alert the server returned; there is no stored flag, so
  nothing can go stale and the prompt disappears the moment the server reports Cash or Credit. **Opening a screen performs no write.**
* **Cash and Credit only.** "Same for Both" is something a reporter says about a report; an alert watches one price.
* **No guess, no default.** Nothing is preselected; Save stays off until a type is chosen; the app never saves Credit "to be safe".
* **No delete-and-recreate.** The save is the ordinary `PriceAlertsService.updateAlert` upsert on the same installation + station, so the
  alert id, mode, target, drop size, cooldown, installation and Pro state are untouched. A legacy `any_change` rule is carried
  (`PriceAlertForm.carriedRule`) until the person picks another type explicitly.
* **Honest outcome.** After saving, the answer must carry the chosen type; if a backend that predates payment types answers `unknown`,
  the sheet says "Price type not saved" (keeping the choice, retryable) rather than "Price Alert updated".
* **No promise.** When no price of the chosen kind exists, the sheet says the next one — or one reported as the same for both — sets the
  starting point; it never says a notification is coming.
* **Pro unchanged.** Free sees the Pro card, unresolved entitlement is "checking", a lapse deletes nothing, the server still enforces Pro.

## 2. How it is built

| Layer | Files | Notes |
|---|---|---|
| pure rules | `PriceAlertsStationTarget`, `PriceAlertsPriceInput`, `PriceAlertsForm`, `PriceAlertsUserMessages`, `PriceAlertsPaymentMigration` (3C.1: the words, the sheet prompt, the row banner) | Foundation only |
| models | `PriceAlertsStationModel`, `PriceAlertsOverviewModel`, `PriceAlertsNotificationModel` | `@Observable`, over the narrow `PriceAlertsServing` seam (`PriceAlertsService` conforms unchanged; `disablePushDelivery` is deliberately not in it) |
| views | `PriceAlertSheet`, `PriceAlertsEntryViews`, `StationAlertsView` | thin: read the model, forward taps |
| existing code touched | `StationsView` (sheet state, call-site arguments, ~60 lines of helpers), `ProStationsMapView` (one optional row + callback), `MoreView`, `EightyFiveBlendsApp`, `AppDelegate`, `PriceAlertsDeviceRegistration`, `PriceAlertsService`, `PushRegistrationService+PriceAlerts` | no SwiftData model, entitlement, plist, project file, StoreKit/RevenueCat or Supabase change |

Reused rather than rebuilt: the price-report sheet's field/button/keyboard patterns, `DestructiveConfirmationOverlay`,
`ProFeatureLockView`/`ProUpgradeView`, `AppHaptics`, `AppCard`/`SectionHeader`/`WarningCard`, and the
pump-detection card's Open Settings call.

## 3. App lifecycle

* **Launch** (the existing launch `.task`, after RevenueCat is configured) and **every return to active**
  (the existing `scenePhase` handler) both call `reconcileDeviceRegistrationIfPreviouslyRegistered()`
  through one private function — the same launch/foreground split `ReviewRequestManager` uses. No new
  observer exists.
* It is a **complete no-op for an install that never opted in**: no OS call, no network, no Keychain read,
  nothing stored, nothing recorded, no prompt. For one that did, it re-reads the OS token (never
  prompting) and tells the backend only if the token or environment changed; an unchanged token costs no
  request, failures back off 30 s / 2 min / 10 min / 30 min, concurrent calls share one attempt.
* **Automatic triggers only maintain a registration; they never create an installation.** If no
  installation exists to maintain, they skip. Creating one takes a person (`enablePushDelivery()`).
* **APNs token callback** (`AppDelegate`): after the existing `handleDeviceToken`, if the token is *new*
  (`PushTokenChange.isNewToken`), `reconcileDeviceRegistrationAfterTokenChangeIfPreviouslyRegistered()` runs on
  a `Task`. The OS answers *every* `registerForRemoteNotifications()` with the current token — including the
  one the foreground reconcile makes — so reacting to an unchanged token would let a reconcile start the
  next one. Only a different token counts, and that reconcile does not ask the OS for anything.
* **A token that rotates mid-registration is not missed.** An attempt that ends without an error while the
  app now holds a token it did not use goes round again, at most three more times; a failed attempt is
  left to the backoff.

## 4. Decisions worth knowing

* **Hidden, not disabled**, for an ineligible station (§1.1).
* **The placeholder was replaced**, not left (§1.7); the Pro marketing copy (`ProUpgradeView`,
  onboarding) was **not** touched — it stays as the 2.3.0 review left it.
* **Simple Mode** shows the bell on station cards like Normal Mode does (the Pro map already shows in both);
  the Stations screen's Pro *navigation* section remains Normal-mode only. Hiding the bell in Simple Mode is
  one condition if you prefer it.
* **No central "turn off" in the list** — turning off happens in the sheet, to keep one implementation.
* **No analytics** were added.

## 5. What this phase did not do

No Supabase, Edge Function, cron, migration, Vault or secret change; no production request; no alert row
created anywhere; no APNs sent; no entitlement, `Info.plist`, project file, bundle id or signing change; no
RevenueCat purchase/restore change; no SwiftData or CloudKit change; no `any_change` in the UI; no pause or
enable API; no remote-notification background mode; no release, archive or tag.

## 6. Before a real push test

1. **Apple Push capability.** Neither `EightyFiveBlends.entitlements` nor `EightyFiveBlendsInternal.entitlements`
   has `aps-environment`. Until it does, every device answers the registration with a failure and the
   notification card correctly says "Notifications aren't ready yet". Adding the capability and the
   entitlement is a separate, deliberate change (portal and provisioning included).
2. **CloudKit Production schema.** `CD_FuelStation.CD_communityStationID` must exist in the Production
   CloudKit schema before any build containing it reaches TestFlight/App Store users.
3. **A physical iPhone, Internal build,** signed so `embedded.mobileprovision` carries the right
   `aps-environment` (TestFlight/App Store → production; development-signed → sandbox).
4. **End-to-end script:** Pro account → open a station that has a community UUID (the UUID comes from the
   station's latest community price or ethanol report, so a station nobody has reported on has no bell:
   submit a price or ethanol percentage for it with **Price / E%** first, and Stations adopts the UUID when
   the community summaries next load) → create At or Below with a price just above the current one → Turn
   On Notifications (system prompt) → post a lower community price for that station → expect the push and,
   on tap, the station in view. Then Price Drop, edit,
   Turn Off (confirm the push registration survives), lapse (Developer Pro Override Off) and renewal.
5. **Release gating.** Do not ship this UI in a Production build before items 1–2: the feature would
   be visible but could not deliver.

## 7. Validation

What was verified, and where. Nothing here was run against Supabase, APNs, RevenueCat or a device.

| Check | Result |
|---|---|
| Pure layer, models, registrar changes and the new tests, built and run on a Swift 6.4 toolchain with the Xcode project's language settings (Swift 5 mode, MainActor default isolation, the same upcoming features) | 370 tests in 41 suites pass — the 216 Phase 3A / push / router-payload / deep-link tests that were already there plus 154 new ones; no compiler diagnostics |
| The same sources and tests in Swift 6 language mode (extra signal for concurrency problems) | passes, no diagnostics |
| Mutation check: 36 defects injected one at a time into the new logic (a double tap saving twice, a failed save wiping the form, an unresolved entitlement treated as Free, a 4th decimal rounded away, a token callback re-asking the OS, a registration that creates an installation without a person, …) | all 36 detected: 33 by failing tests, 2 by a test that deadlocks (a missing double-tap guard), 1 by the compiler (an extra alert kind cannot compile without words). One mutant first survived — a slow earlier load re-seeding the form *while* a save was in flight — which exposed a gap; a test for it was added and the mutant is now caught. Source restored byte-for-byte after every run |
| The three SwiftUI files against the real models, using a stand-in for SwiftUI | type-checks. **This is a structural check only, not a compile of real SwiftUI**: it proves the views use the app's own models, enums, optionals and closures consistently (a planted typo is caught), not that every modifier label matches Apple's API. They have **not been built by Xcode** |
| A separate read-only review of the committed SwiftUI files and the hunks in `StationsView` / `ProStationsMapView` / `MoreView` / the app and AppDelegate wiring, by reading them against the real declarations in this repository (no compiler was available to it) | found nothing that should fail to compile — it checked project membership, the declaration order of every memberwise initializer at every call site, each shared component's real signature, every theme token, exhaustive switches, imports, actor isolation and name collisions. It raised two small items and one trade-off: the price field's tap target was only its line of text (**fixed**: the whole box now focuses it); the pale-red error text has low contrast in Light appearance (it is the app-wide error literal used by the Garage and price-report screens, so **left as is** — see §8); and the sheet's Close / swipe-dismiss are disabled while a request is in flight (**kept**, see §8) |
| Xcode build and tests | not run here (Linux). The gate is Xcode Cloud's *Test – iOS* action on the pushed commit; this phase is validated only when that reports success |

Test map: scenarios are covered in `PriceAlertsStationTargetTests` (entry / eligibility / Pro cue),
`PriceAlertsFormTests` (price parsing, drafts, mode switching), `PriceAlertsStationModelTests` (Pro states,
loading, existing / unknown alerts, save, failure, stale load, turn off, device registration untouched),
`PriceAlertsNotificationModelTests`, `PriceAlertsUserMessageTests`, `PriceAlertsOverviewModelTests`,
`PriceAlertsLifecycleTests` and `PriceAlertsAutomaticTriggerTests` (launch / foreground / token callback,
idempotence, backoff, convergence, the real push service's no-loop property) and
`PriceAlertsNavigationTests` (the notification-tap hand-off still routes once and names the same station).

### 7.1 Phase 3C.1 (legacy-alert flow and the drop-size marker) — what was verified

| Check | Result |
|---|---|
| The same Linux SwiftPM harness as above (project language settings, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), on the 3C.1 tree | 518 tests in 59 suites pass (the starting commit `ad02bf1` ran 490 in 57: +28 tests, +2 suites); no compiler diagnostics |
| The same sources in Swift 6 language mode | 518 tests pass, no diagnostics |
| The SwiftUI files (`PriceAlertSheet`, `StationAlertsView`) against the real models, using a stand-in for SwiftUI | type-checks. **Structural only, not Xcode**: every theme token and component the new views use was also checked by hand against its real declaration in the repository (`AppTheme.Colors.*`, `AppCard`, `AppHaptics.selection()`, the `Divider().overlay(…)` idiom already used elsewhere) |
| Mutation check: 20 defects injected one at a time into the new logic (the prompt shown for typed alerts, a preselected Credit, an `any_change` rule rewritten as a Price Drop, success announced although the server ignored the choice, Unknown offered as a choice, the entitlement ignored by the prompt, the marker missing or wrong, …) | all 20 detected. Three survived the first pass: two entitlement tests changed the entitlement before the list had loaded (so the mutant had nothing to hide), which exposed a gap — they were rewritten to lapse Pro with the list already loaded — and one mutant was equivalent (no observable difference) and was replaced by a real one ("the form ignores the carried rule when it decides what to send"). All three are then caught. Source restored byte-for-byte after every run |
| Xcode build and tests | not run here (Linux). The gate is Xcode Cloud's *Test – iOS* on the pushed commit |

## 8. Known limitations and follow-ups

* A station needs a community UUID for the bell to appear; stations nobody has reported on never get one.
* The sheet offers no cooldown control (Phase 3C added the drop size for Price Drop; the cooldown stays the alert's
  own value, 6 hours for a new alert, and is only stated in the note under the form).
* The Price Alerts screen has no search, and lists in the server's order (by station name).
* While a save or turn-off is in flight, Close and swipe-to-dismiss are disabled (as in the price-report
  sheet), so the person always sees the outcome instead of losing it behind a dismissed sheet. It is
  bounded by the request timeouts (15 s per request, 30 s per resource); a save that needs the
  re-bootstrap path is a few sequential requests.
* If the list refresh that follows a *successful* save or turn-off itself fails (two requests failing in a
  row), the sheet says so ("Couldn't refresh", with a Refresh button), but until a refresh succeeds its
  status card shows the last list the app holds: the service keeps the last good list on a failed refresh,
  and the sheet reads only that list instead of keeping a copy of its own. The server has the right state,
  the form already shows what was saved, and repeating either action is harmless (a test pins this for
  Save). Patching the list from the write's own answer would be a Phase 3A service change.
* Validation text (the price field, a failed save) uses the app's existing pale-red error colour, which
  has low contrast against the Light appearance's page background. It is the same literal as the Garage
  and price-report screens; fixing it properly means an appearance-adaptive error token in `Theme`,
  an app-wide change this phase did not make.
* `Simple Mode` question above; and whether the Pro section header wording ("Route planning and price
  alerts.") is the wording you want.
* **(3C.1) The new list explainer, row banner and sheet card have not been compiled by Xcode or seen on a device.** Their logic and
  words are pure and tested in a Linux harness; the SwiftUI files were checked only against a structural stand-in. Xcode Cloud's
  *Test – iOS* on the final commit is the gate, and a look at the list and sheet at the largest Dynamic Type and with VoiceOver is
  worth doing on a device before this reaches anyone.
* **(3C.1) An alert whose owner never opens the app is never moved.** The prompt is an offer, not a migration (see
  `PRICE_ALERTS_PAYMENT_TYPES_2.4.1.md` §12 question 17).
* **(3C.1) The prompt appears in the list only after the list has loaded** (not while loading, failed, empty or the entitlement is
  resolving), so it never shows beside a spinner or an error.

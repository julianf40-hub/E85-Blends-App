# TODO (Active Items)

Extracted from `todo.md` unchecked items during cleanup pass.

## Phase 2: High-Impact Features

- [ ] Integrate real-time fuel prices API
- [ ] Build Analytics dashboard with MPG trends
- [ ] Add charts for fuel economy visualization
## Garage Tab & Car Profiles

- [ ] Create car profile data model (year, make, model, trim, tank size, MPG, octane, flex-fuel flag)
- [ ] Create garage storage utility with AsyncStorage (CRUD for car profiles)
- [ ] Build Garage tab screen with car profile cards
- [ ] Add "Add Car" button and form with all vehicle fields
- [ ] Add "Edit Car" functionality for existing profiles
- [ ] Add "Delete Car" with confirmation dialog
- [ ] Add "Set Active" to select which car is used for calculations
- [ ] Show active car badge/indicator on profile card
- [ ] Update Settings to pull vehicle info from active car profile
- [ ] Update Calculator to auto-fill tank size from active car profile
- [ ] Update tab layout to include Garage tab
- [ ] Add Garage tab icon mapping
- [ ] Test all Garage features end-to-end
## Home Redesign & Reminders System

- [ ] Build reminder data model and storage library (mileage + date triggers, repeat, per-car)
- [ ] Redesign Home tab: car hero banner, current mileage card, reminders strip, recent fill-up timeline
- [ ] Build Reminders list screen (per-car, sorted by urgency)
- [ ] Build New Reminder modal (name, category, date toggle, mileage toggle, repeat)
- [ ] Add Reminders tab to navigation
## BLE Live Monitor (eFlexPlus)

- [ ] Install react-native-ble-plx and add config plugin
- [ ] Create lib/ble-eflex.ts with BLE manager, scan, connect, and read logic
- [ ] Build app/(tabs)/live-monitor.tsx with scanner list, connect button, and live gauge
- [ ] Add Live Monitor tab to tab layout with bluetooth icon
- [ ] Add placeholder UUIDs with clear TODO comments for easy swap-in
- [ ] Show live ethanol %, fuel temp, injector duty cycle on the screen
- [ ] Handle BLE permission requests (iOS + Android)
- [ ] Handle disconnect/reconnect gracefully
## Batch Improvements (Mar 28)

- [ ] Fix/remove opening splash screen
- [ ] Auto-update odometer from fuel log entry (keep hero card current)
- [ ] Remove recent fill-ups section from dashboard
- [ ] System theme button follows iOS light/dark mode automatically
- [ ] Remove random decimal points in More tab fuel preferences section
- [ ] Move Saved Blends from More tab to Fuel Log tab (pinned to top)
- [ ] Fix reminder category scroll (can't scroll up/down in picker) + add custom category option
- [ ] On reminder completion, auto-advance displayed next mileage point
- [ ] Date reminder repeat options: weekly, monthly, every 6 months, yearly, custom (days/weeks/months)
- [ ] Make reminder name optional (default to category name if blank)
## Phase 1 & 2: Production Readiness (Mar 29)

### Phase 1: Must-Fix Bugs

- [ ] Add dev settings screen for API base URL configuration
- [ ] Create environment validation script
- [ ] Ensure crowdsourced prices labeled clearly (not ambiguous)
### Phase 2: Polish Improvements

- [ ] Add location permission prompt on first app launch
- [ ] Show one-time onboarding tooltip about demo key rate limits
- [ ] Unify error messaging across Stations and Fuel Log tabs
- [ ] Add retry buttons to all error states
- [ ] Fix reminder category picker scroll
- [ ] Add repeat options (once, weekly, monthly, 6mo, yearly, custom)
- [ ] Remove obsolete todo.md items (e.g., "Garage tab")
- [ ] Fix ESLint ESM config warning
## Tab Restructure (Apr 2, 2026)

- [ ] Move Fuel Log from tab bar into More/Settings tab
- [ ] Build dedicated Calculator tab screen (promote modal to full tab)
- [ ] Make Calculator the default first tab (landing screen)
- [ ] Remove Fuel Log tab from tab bar
- [ ] Add calculator icon mapping to icon-symbol.tsx
- [ ] Update all router.push references to fuel-log tab
## Calculator-First Navigation Polish & TestFlight Prep

- [ ] Optimize Calculator screen information hierarchy (Calculator as core experience)
- [ ] Add quick actions to Calculator result: Save Blend, Log Fill-Up, Find Nearby Station
- [ ] Rework Home/index screen as supporting garage/dashboard overview
- [ ] Tighten navigation labels (Home → Dashboard or Garage)
- [ ] Audit app.config.ts for TestFlight readiness (bundle ID, version, build number)
- [ ] Verify all iOS icons and splash screen assets are correct format/size
- [ ] Check iOS-specific permissions in app.config.ts
- [ ] Review EAS build configuration for TestFlight
- [ ] Verify no missing environment values that would block iOS build
- [ ] Document all changed files and TestFlight steps

## Cleanup Pass 09 (Apr 9, 2026)

### Completed in this pass
- [x] Add `directionsApp` preference to `UserPreferences` model (`lib/preferences.ts`)
- [x] Wire `directionsApp` into `openDirections()` in `app/(tabs)/stations.tsx` (Apple Maps / Google Maps / Waze)
- [x] Add Directions App picker UI to Navigation card in `app/(tabs)/settings.tsx`
- [x] Fix onboarding `handleAddVehicle` routing from `/(tabs)` → `/(tabs)/index` (lands on Garage)
- [x] Fix onboarding `handleFinish("garage")` routing from `/(tabs)` → `/(tabs)/index`
- [x] Improve EIA fallback price sublabel: "EIA state average" → "EIA estimate — no reports yet"
- [x] Tighten station card badge row: hairline border, reduced padding/weight for visual hierarchy

### Deferred / Dependency cleanup debt
- [ ] Remove `expo-audio` plugin from `app.config.ts` (no imports anywhere in app code)
- [ ] Remove `expo-video` plugin from `app.config.ts` (no imports anywhere in app code)
- [ ] Remove `expo-audio` and `expo-video` from `package.json` dependencies
- [ ] Remove `expo-keep-awake` from `package.json` (no imports anywhere)
- [ ] Remove `expo-web-browser` from `package.json` (no imports anywhere)
- [ ] Directions App "Ask every time" option (ActionSheet on tap) — deferred, not in scope

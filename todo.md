# Project TODO

- [x] Update theme colors to green/amber fuel-inspired palette
- [x] Add tab icons for Calculator, Stations, My Blends
- [x] Build Calculator screen with blend ratio inputs
- [x] Implement E85 blend calculation logic
- [x] Add quick-select chips for common blends (E30, E40, E50, E60)
- [x] Display calculation results (gallons E85, gallons gas, octane, ethanol %)
- [x] Add visual blend ratio gauge
- [x] Implement save blend functionality with AsyncStorage
- [x] Build Stations screen with map view
- [x] Install and configure react-native-maps
- [x] Install and configure expo-location
- [x] Add E85 station data/API integration
- [x] Show station markers on map
- [x] Add station list below map
- [x] Build My Blends screen with saved calculations list
- [x] Add delete/swipe functionality for saved blends
- [x] Add re-load saved blend into calculator
- [x] Generate app logo
- [x] Update app branding in app.config.ts
- [x] Polish UI with iOS 26 Liquid Glass inspired design
- [x] Add haptic feedback on interactions
- [x] Integrate AFDC API for real E85 station data
- [x] Show nearby stations based on user's actual GPS location
- [x] Remove hardcoded sample station data
- [x] Handle API errors gracefully with fallback

## Phase 2: High-Impact Features

- [x] Build Settings screen with user preferences
- [x] Create preferences storage utility (AsyncStorage)
- [x] Build Fuel Log screen with fuel-up tracking
- [x] Create fuel log storage and retrieval utilities
- [x] Implement Station Favorites feature
- [x] Add Station History tracking
- [x] Build Station Reviews & Ratings system
- [x] Add review storage and retrieval
- [x] Update tab layout with 6 tabs (Calculator, Stations, My Blends, Fuel Log, Settings)
- [ ] Integrate real-time fuel prices API
- [ ] Build Analytics dashboard with MPG trends
- [ ] Add charts for fuel economy visualization

## Bug Fixes

- [x] Enable decimal input support for tank size (e.g., 18.5 gallons)
- [x] Enable decimal input support for fuel calculations
- [x] Fix vehicle information text inputs in Settings tab (unable to type)

- [x] Fix splash screen to show correct app icon instead of old one
- [x] Fix decimal input parsing - "18.5" not working in tank size field

## Current Work

- [x] Debug decimal input - improved parseFloat logic and input handling
- [x] Integrate E85 fuel prices display at stations
- [x] Add fuel price comparison (E85 vs gas savings %)
- [x] Create fuel-prices utility module with cost comparison calculations


## Crowdsourced Pricing Feature

- [x] Create station-prices utility for storing user-submitted prices
- [x] Build price update modal component
- [x] Add "Update Price" button to station cards
- [x] Display user-submitted prices with timestamps
- [x] Show price history (last 10 updates per station)
- [x] Add price age indicator (e.g., "Updated 2 hours ago")
- [x] Test crowdsourced pricing feature (10 new tests passing)


## Multi-Fuel-Grade Pricing Feature

- [x] Update station-prices module to support E85, 87, 89, 91/94 octane
- [x] Update price update modal with inputs for all fuel grades
- [x] Update stations screen to display all fuel grades with prices
- [x] Update fuel price tests for multi-grade support
- [x] All 58 tests passing


## Current Bug Fix

- [x] Fix decimal keyboard showing period-underscore instead of decimal point
- [x] Change keyboardType to "default" with dedicated "." buttons for Samsung compatibility
- [x] Rewrite calculator with string-based state to preserve trailing decimal points
- [x] Fix price modal layout - fuel grade inputs now visible with minHeight
- [x] Add decimal "." buttons to all numeric inputs across all screens
- [x] All 58 tests passing


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


## Station Caching & Map View

- [x] Add station cache utility with 30-min TTL (AsyncStorage)
- [x] Update fetchNearbyStations to read from cache before hitting API
- [x] Invalidate cache on manual refresh or radius change
- [x] Add map view toggle (List / Map) to Stations tab header
- [x] Show station pins on MapView with custom callouts
- [x] Tap pin to highlight station card / show detail callout
- [x] Center map on user location with accuracy circle
- [x] Animate map to fit all station pins on load

## Layout Bug Fix

- [x] Fix station card action buttons (Get Directions / Update Price / Call) being clipped horizontally

## OLED Theme & Price Freshness

- [x] Update dark theme to true OLED black (background #000000, surface #0A0A0A, etc.)
- [x] Add inline price freshness ("Updated 5m ago") next to price value in station cards

## Bug Fixes

- [x] Fix crash when switching to Map view in Stations tab

## Map Crash Fix

- [x] Switch MapView to OpenStreetMap tiles (PROVIDER_DEFAULT + UrlTile) — no Google API key needed
- [x] Add ACCESS_FINE_LOCATION and ACCESS_COARSE_LOCATION to Android permissions
- [x] Add expo-location plugin to app.config.ts for iOS NSLocationWhenInUseUsageDescription
- [x] Guard showsUserLocation behind location permission state

## New Features Batch 2

- [x] Light/dark mode manual toggle in Settings tab
- [x] 3-screen onboarding flow on first launch (add car, find stations, log fill-up)
- [x] Favorite stations (star/unstar, pinned to top of list, persisted in AsyncStorage)
- [x] Android App Shortcuts (long-press app icon to quick-launch Calculator or Stations via expo-quick-actions)

## OTA Updates

- [x] Install expo-updates and configure EAS Update channel
- [x] Add silent background update check on app launch
- [x] Add update notification banner when new version is available

## Stale Price Warning

- [x] Show price freshness in amber when user-submitted price is older than 7 days

## Home Redesign & Reminders System

- [ ] Build reminder data model and storage library (mileage + date triggers, repeat, per-car)
- [ ] Redesign Home tab: car hero banner, current mileage card, reminders strip, recent fill-up timeline
- [ ] Build Reminders list screen (per-car, sorted by urgency)
- [ ] Build New Reminder modal (name, category, date toggle, mileage toggle, repeat)
- [ ] Add Reminders tab to navigation

## Tab Bar Cleanup

- [x] Reduce 7 tabs to 5 by moving Garage into Settings tab (rename to "More")
- [x] Embed Garage car list directly in the More/Settings screen with section header
- [x] Remove standalone Garage tab from tab layout
- [x] Update all router.push("/(tabs)/garage") references to point to settings tab
- [x] Rename Settings tab to "More" with ellipsis icon

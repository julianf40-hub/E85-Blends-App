# E85 Blend App — Change Log

> A running history of every feature, improvement, and bug fix built into the app.
> Copy this into your notes app and append new entries as development continues.

---

## v1.0 — Initial Build

**Core foundation of the app established.**

The initial release introduced the E85 Blend Calculator as the centerpiece of the app. Users can input their tank size, current ethanol percentage in the tank, and target blend level, then receive a precise breakdown of how many gallons of E85 and regular gasoline to add. Quick-select chips for common blends (E30, E40, E50, E60) allow one-tap targeting, and a visual blend ratio gauge gives instant feedback. Calculated blends can be saved to a local list and reloaded into the calculator at any time.

The Stations tab launched with live E85 station data pulled from the AFDC (Alternative Fuels Data Center) API, showing nearby stations based on the user's GPS location. A green/amber fuel-inspired color palette and haptic feedback were applied throughout, and the app icon and branding were finalized.

---

## v1.1 — Fuel Log, Settings & Station Enhancements

**Tracking fill-ups and managing preferences.**

A full Fuel Log was added, allowing users to record every fill-up with date, odometer reading, gallons added, station name, and price paid. A Settings screen was introduced with fuel preferences (default tank size, preferred octane, default blend target, search radius) and vehicle information storage.

Station cards gained a crowdsourced pricing system: any user can report the current E85, 87, 89, and 91/94 octane prices at a station. Prices display with a freshness timestamp ("Updated 5m ago") and turn amber when older than 7 days. A price history of the last 10 reports per station is stored locally.

Station favorites were added — tap the star on any station to pin it to the top of the list. The Stations tab also gained a Map/List toggle, showing all nearby stations as pins on an OpenStreetMap-based map (no Google API key required). A 30-minute station cache prevents redundant API calls.

---

## v1.2 — Garage, Car Profiles & Odometer Tracking

**Per-vehicle profiles and mileage awareness.**

A Garage section was built into the More tab, allowing users to create detailed car profiles with year, make, model, trim, tank size, expected MPG on E85 and gas, preferred octane, flex-fuel flag, gas ethanol percentage, and current odometer. One car can be set as "active," and the calculator automatically pulls that car's tank size and gas ethanol percentage to pre-fill its inputs.

The Home dashboard was redesigned with a hero card showing the active car, its current odometer reading, and an E85 Calculator shortcut tile. A manual odometer update button lets users correct the mileage at any time. When a new fuel entry is logged, the odometer on the hero card updates automatically and takes priority over the manual entry.

The Fuel Log form was upgraded to accept separate E85 Gallons and Gas Gallons fields, automatically computing the total and blend ratio (ethanol %) as a read-only summary. A "Current Ethanol % in Tank" field was added, and the calculator auto-fills this value from the most recent fuel log entry, showing an "AUTO" badge when active.

---

## v1.3 — Reminders System & Calculator Accuracy

**Maintenance reminders and blend math corrections.**

A full maintenance reminders system was built. Users can create reminders by category (Oil Change, Tire Rotation, Air Filter, Spark Plugs, Transmission Fluid, Coolant, Brake Fluid, Fuel Filter, Injector Cleaner, and custom categories), set them to trigger at a specific mileage interval or on a date schedule, and mark them complete. When a mileage-based reminder is completed, the next target automatically advances to the current odometer plus the interval — it no longer resets to just the interval value. Date-based reminders support weekly, monthly, every 6 months, yearly, and custom (days/weeks/months) repeat options. Reminder names are optional and default to the category name if left blank.

The blend calculator's default gas ethanol percentage was corrected from 10% to 0%, which was causing results to read lower than expected when using pure 91/93 octane pump gas. A helper hint ("0% for pure 91/93 oct") was added below the field. A collapsible pump instructions card was added below the result, giving numbered steps for the fill-up sequence. A "Log This Fill-Up" button on the result card opens a quick modal to record the fill directly from the calculator.

The calculator's decimal input was rewritten using string-based state to preserve trailing decimal points during typing, fixing a long-standing issue where typing "18." would immediately round to "18".

---

## v1.4 — UI Overhaul, Tab Restructure & OTA Updates

**Navigation cleanup, visual polish, and live update delivery.**

The tab bar was reduced from 7 tabs to 5 (Home, Stations, Fuel Log, Reminders, More) by embedding the Garage section directly into the More tab. The Settings tab was renamed "More" with an ellipsis icon.

The Saved Blends list was moved from a standalone tab into the More screen (below Garage, above Appearance), and later promoted to the very top of the Fuel Log tab so favorite blends are always immediately accessible.

The dark theme was updated to true OLED black (background #000000, surface #0A0A0A) for battery savings on OLED displays. A 3-screen onboarding flow was added for first-time users, walking through adding a car, finding stations, and logging a fill-up. Android App Shortcuts were added so users can long-press the app icon to jump directly to the Calculator or Stations tab.

OTA (over-the-air) update support was configured via expo-updates, with a silent background check on launch and a banner notification when a new version is available.

---

## v1.5 — Stations Voting, Location Auto-Fill & Liquid Glass Tab Bar

**Community accuracy, smarter forms, and a modern native look.**

Each station card gained a community voting row where users can thumbs-up or thumbs-down whether the station actually sells E85/flex fuel. Votes persist locally, toggle on re-tap, and display a color-coded confidence score (green ≥70%, amber ≥40%, red below 40%) to help surface accurate listings.

The Add Fuel Entry form now auto-populates the station name field by looking up the nearest E85 station within 5 miles using the device's GPS when the modal opens. A location-pin icon pulses while searching; the user can always override the result.

The tab bar was redesigned with an iOS 26-style Liquid Glass look using `expo-blur` BlurView (intensity 85) on iOS, giving a native frosted-glass appearance that floats above the screen content. A semi-transparent fallback is used on Android and Web.

A pull-to-refresh gesture was added to the Stations tab for one-handed usability.

---

## v1.6 — Real Local Fuel Prices (EIA API)

**Replacing national averages with real state-level data.**

The "AFDC National Average" price row on station cards was replaced with real local price data. Regular gasoline prices are now fetched from the U.S. Energy Information Administration (EIA) weekly retail survey — a free, government-sourced feed updated every Monday — scoped to the user's state. E85 prices show the AFDC state-level average for that state, or the user-submitted crowdsourced price if one has been reported (always takes priority). Each price is labeled with its source (e.g., "Gas (TX · EIA)" or "E85 (reported)") and the savings percentage is recalculated from the two real local values.

A sort toggle was added to the station list header, allowing users to switch between sorting by distance (default) and sorting by cheapest E85 price first.

---

## v1.7 — UI Polish & System Theme Fix

**Removing clutter and making the theme follow the device.**

The decimal dot buttons were removed from the Fuel Preferences numeric inputs (Tank Size, Default Blend, Search Radius). The keyboard type is now `numeric`, so the decimal point is available directly on the system keypad when needed — no extra button required.

The System theme button in the Appearance section was fixed to actually follow the device's light/dark mode setting. The root cause was that `Appearance.setColorScheme()` was being called even when the user had selected "System" mode, which locked the OS-level appearance and prevented automatic switching. The fix clears any previous lock when System mode is selected, allowing iOS and Android to control the theme automatically.

The Saved Blends strip was promoted to the very first item in the Fuel Log tab, appearing above the stats cards, so favorite blend recipes are always one tap away when logging a fill-up.

---

## Pending / In Progress

The following items are planned or partially implemented and will appear in future change log entries:

- Splash screen removal / replacement with instant app launch
- Odometer auto-update when logging a fuel entry (hero card sync)
- Reminder category scroll fix and custom category input
- BLE Live Monitor for eFlexPlus adapter (real-time ethanol %, fuel temp, injector duty cycle)
- Fuel economy analytics chart (MPG over time, cost per mile, E85 vs gas spending)
- Push notification delivery for mileage and date-based reminders
- Blend quick-apply from Fuel Log (tap saved blend to pre-fill Add Entry form)

---

*Last updated: March 28, 2026*

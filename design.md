# E85 Blend App — Design Document

## Overview

The E85 Blend app helps car enthusiasts calculate optimal E85/gasoline fuel blends and locate nearby E85 gas stations. The design follows the iOS 26 Liquid Glass aesthetic with translucent surfaces, layered depth, and clean typography.

## Screen List

| Screen | Tab | Purpose |
|--------|-----|---------|
| Calculator | Tab 1 (Home) | E85 blend ratio calculator with inputs for tank size, current fuel, target ethanol % |
| Stations | Tab 2 | Map-based E85 station locator with list view |
| My Blends | Tab 3 | Saved blend history and favorite presets |

## Primary Content and Functionality

### Calculator Screen (Home Tab)
The main screen features a blend calculator card with a frosted glass appearance. Users input their tank size, current fuel level, E85 ethanol percentage (default 85%), gasoline ethanol percentage (default 10%), and desired target ethanol blend (E20–E85). The calculator outputs gallons of E85 and gasoline needed, the resulting octane rating, and the final ethanol percentage. A visual gauge shows the blend ratio. Quick-select chips allow choosing common blends (E30, E40, E50, E60). Results display in a translucent results card below the inputs.

### Stations Screen (Tab 2)
A full-screen map showing nearby E85 stations with pin markers. The user's current location is shown with a blue dot. Below the map, a draggable bottom sheet lists stations sorted by distance. Each station card shows name, address, distance, and price (if available). Tapping a station centers the map on it and shows a detail callout. A search bar at the top allows filtering by city or zip code.

### My Blends Screen (Tab 3)
A list of previously calculated blends saved locally via AsyncStorage. Each entry shows the date, target blend, gallons of E85/gas, and resulting octane. Users can tap to re-load a blend into the calculator. A "Clear All" option is available. Favorite presets (like "My Daily E30" or "Track Day E50") can be pinned to the top.

## Key User Flows

### Calculate a Blend
1. User opens app → lands on Calculator tab
2. Enters tank size (gallons) using a numeric input
3. Adjusts current fuel level slider (how full the tank is)
4. Selects target ethanol blend via quick-select chips or slider
5. Optionally adjusts E85 ethanol % and gas ethanol % in advanced settings
6. Taps "Calculate" button
7. Results card animates in showing: gallons of E85, gallons of gas, final ethanol %, estimated octane
8. User can tap "Save Blend" to store it in My Blends

### Find E85 Station
1. User taps Stations tab
2. App requests location permission
3. Map loads centered on user's current location
4. E85 station markers appear on the map
5. User taps a marker → callout shows station details
6. User taps the station list item → opens directions in Maps app

### Review Saved Blends
1. User taps My Blends tab
2. Sees list of saved calculations
3. Taps a saved blend → navigates to Calculator with values pre-filled
4. Can delete individual blends by swiping left

## Color Choices

The app uses a fuel/energy-inspired palette with green accents representing ethanol/E85 and warm amber for gasoline.

| Token | Light Mode | Dark Mode | Usage |
|-------|-----------|-----------|-------|
| primary | #16A34A (green-600) | #22C55E (green-500) | Main accent, E85 indicators, CTA buttons |
| background | #F8FAFC (slate-50) | #0F172A (slate-900) | Screen backgrounds |
| surface | #FFFFFF | #1E293B (slate-800) | Cards, input containers |
| foreground | #0F172A (slate-900) | #F1F5F9 (slate-100) | Primary text |
| muted | #64748B (slate-500) | #94A3B8 (slate-400) | Secondary text, labels |
| border | #E2E8F0 (slate-200) | #334155 (slate-700) | Dividers, input borders |
| success | #16A34A | #4ADE80 | Successful calculations |
| warning | #F59E0B | #FBBF24 | Caution indicators |
| error | #EF4444 | #F87171 | Error states |
| accent | #D97706 (amber-600) | #F59E0B (amber-500) | Gasoline indicators, secondary accent |

## iOS 26 Liquid Glass Design Approach

Since `expo-glass-effect` GlassView only works on iOS 26+ native builds, the app uses a cross-platform approximation of the Liquid Glass aesthetic using `expo-blur` BlurView and semi-transparent surfaces with the following patterns:

- **Translucent cards**: Surface cards use `bg-surface` with slight opacity and rounded corners (rounded-2xl / rounded-3xl)
- **Frosted glass headers**: Navigation areas use BlurView with `intensity={80}` and `tint="light"` (or `"dark"` in dark mode)
- **Layered depth**: Cards have subtle shadows and border treatments to create spatial hierarchy
- **Rounded geometry**: All interactive elements use generous border radius matching iOS 26 conventions
- **Clean typography**: SF-style font hierarchy with bold headings, medium labels, regular body text
- **Motion**: Subtle scale animations on press (0.97), gentle fade-ins for results
- **Color accents**: Green for E85/ethanol elements, amber for gasoline elements, creating a clear visual language

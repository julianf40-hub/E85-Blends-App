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

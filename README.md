# 85Blends — iOS-First E85 Calculator & Fuel Tracker

An iOS-first React Native app (built on Expo) for flex-fuel drivers: calculate perfect E85 blends, find nearby E85 stations, track fuel economy, and manage maintenance reminders.

**Tech Stack:** Expo 54 · React Native 0.81 · TypeScript · NativeWind (Tailwind CSS) · tRPC · PostgreSQL

> **Branch:** `codex/rebuild-85blends-on-ios-foundation` — clean iOS-first rebuild. iOS is the primary target; Android support follows.

---

## Quick Start

### Prerequisites

- **Node.js** 18+ and **pnpm** 9+
- **Xcode** (for iOS simulator) or physical iOS device with Expo Go

### Installation

```bash
# Clone the repo
git clone <repo-url>
cd e85-blend-app

# Install dependencies
pnpm install

# Copy environment template
cp .env.example .env
# Edit .env and fill in required keys (see below)

# Start development server
pnpm dev
```

### Environment Setup

Create a `.env` file in the project root. Required keys:

| Key | Description | Example |
|-----|-------------|---------|
| `NREL_API_KEY` | NREL API key for station data (get free key at [developer.nrel.gov](https://developer.nrel.gov)) | `YOUR_KEY_HERE` |
| `EXPO_PROJECT_ID` | Expo project ID for OTA updates (from EAS dashboard) | `abc123def456` |
| `DATABASE_URL` | PostgreSQL connection string (optional, for backend) | `postgresql://user:pass@localhost/e85` |
| `JWT_SECRET` | Secret for JWT signing (**required when running backend/auth**) | `openssl rand -base64 32` |

See `.env.example` for all available options.

---

## Development

### Start the Dev Server

```bash
pnpm dev
```

This starts:
- **Metro Bundler** on http://localhost:8081
- **API Server** on http://localhost:3000 (backend, if enabled)

### Testing on iOS

#### iOS Simulator / Expo Go

1. Install **Expo Go** from the App Store
2. Scan the QR code from the terminal output, or:
   ```bash
   pnpm qr
   ```

#### Testing on LAN (Recommended for Physical Devices)

If localhost doesn't work on your device, use your machine's LAN IP:

```bash
# Find your LAN IP
ifconfig | grep "inet " | grep -v 127.0.0.1

# Set EXPO_PUBLIC_API_BASE_URL in your environment or EAS secrets:
# http://192.168.x.x:3000
```

---

## Project Structure

```
app/
  (tabs)/              ← Main tab navigation
    calculator.tsx     ← E85 Blend Calculator
    stations.tsx       ← Find E85 Stations
    reminders.tsx      ← Maintenance Reminders
    garage.tsx         ← Vehicle Garage
    more.tsx           ← More / Settings
  _layout.tsx          ← Root layout with PreferencesProvider
  fuel-log.tsx         ← Fuel log screen
  onboarding.tsx       ← First-run onboarding

lib/rebuild/           ← Core rebuild libraries
  theme.ts             ← Color palette
  preferences.tsx      ← Preferences context + AsyncStorage
  storage.ts           ← Fuel log & reminders storage

components/            ← Reusable UI components
  ui/                  ← Icon mappings, buttons, etc.

server/                ← Backend (Node.js / tRPC)
  routers.ts           ← tRPC procedures
  db.ts                ← Database query helpers
  storage.ts           ← S3 storage helpers
  _core/               ← Server framework (trpc, auth, context)

assets/images/         ← App icons, splash screen
app.config.ts          ← Expo config (bundle ID: com.e85blends.app.ios)
eas.json               ← EAS Build & Submit config
```

---

## Key Features

### E85 Calculator
- Input desired blend % (e.g., 85% ethanol)
- Calculate E85 and gasoline gallons needed
- Save favorite blends for quick access

### Station Finder
- Locate nearby E85 stations (NREL database)
- View prices and community-reported data
- Sort by distance

### Fuel Log
- Log fill-ups with odometer, blend %, and prices
- Track fuel economy (MPG) over time

### Maintenance Reminders
- Set mileage-based or date-based reminders
- Receive notifications when reminders are due

---

## Troubleshooting

### "Station search not working" or "NREL API key not configured"

**Fix:**
1. Get a free API key at [developer.nrel.gov](https://developer.nrel.gov)
2. Add to `.env`: `NREL_API_KEY=your_key_here`
3. Restart: `pnpm dev`

### "API connection refused" on physical device

**Fix:** Set `EXPO_PUBLIC_API_BASE_URL` to your machine's LAN IP: `http://192.168.x.x:3000`

### App Store / TestFlight Submission

The App Store Connect API key (`AuthKey_*.p8`) is **not tracked in git**. Place the `.p8` file locally and set `EXPO_APPLE_APP_SPECIFIC_PASSWORD` or provide the key path at submit time:

```bash
eas submit --platform ios --path /path/to/AuthKey_8867QHS988.p8
```

---

## Testing

```bash
pnpm test
```

---

## Building for iOS

```bash
# Build for TestFlight / App Store
eas build --platform ios

# Build and submit
eas build --platform ios --auto-submit
```

See [Expo EAS docs](https://docs.expo.dev/eas/) for detailed instructions.

---

## License

MIT

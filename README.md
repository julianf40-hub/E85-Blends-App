# E85 Blend — Smart E85 Calculator & Fuel Tracking

A React Native mobile app (iOS/Android) that helps flex-fuel drivers calculate perfect E85 blends, find nearby E85 stations, track fuel economy, and manage vehicle maintenance reminders.

**Tech Stack:** Expo 54 · React Native 0.81 · TypeScript · NativeWind (Tailwind CSS) · tRPC · PostgreSQL

---

## Quick Start

### Prerequisites

- **Node.js** 18+ and **pnpm** 9+
- **Expo Go** app on iOS/Android (for testing on physical devices)

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
| `EXPO_PUBLIC_NREL_API_KEY` | NREL API key for station data (get free key at [developer.nrel.gov](https://developer.nrel.gov)) | `YOUR_KEY_HERE` |
| `EXPO_PROJECT_ID` | Expo project ID for OTA updates (from `app.json` or EAS) | `abc123def456` |
| `DATABASE_URL` | PostgreSQL connection string (optional, for backend) | `postgresql://user:pass@localhost/e85` |
| `JWT_SECRET` | Secret for JWT signing (optional, for auth) | `your-secret-key` |

**Note:** If `EXPO_PUBLIC_NREL_API_KEY` is not set, the app will use a shared demo key, which is **rate-limited**. For production, provide your own key.

See `.env.example` for all available options.

---

## Development

### Start the Dev Server

```bash
pnpm dev
```

This starts:
- **Metro Bundler** on http://localhost:8081 (web preview)
- **API Server** on http://localhost:3000 (backend, if enabled)

### Testing on Physical Devices

#### iOS/Android with Expo Go

1. Install **Expo Go** from App Store or Play Store
2. Scan the QR code from the terminal output, or:
   ```bash
   pnpm qr
   ```
3. App opens in Expo Go on your device

#### Testing on LAN (Recommended for Debugging)

If localhost doesn't work on your device, use your machine's LAN IP:

```bash
# Find your LAN IP
ifconfig | grep "inet " | grep -v 127.0.0.1

# In the app, go to Settings > Dev Settings > API Base URL
# Enter: http://192.168.x.x:3000 (replace x.x with your IP)
```

#### Using ngrok Tunnel (For Remote Testing)

```bash
# Install ngrok: https://ngrok.com
ngrok http 3000

# In the app, go to Settings > Dev Settings > API Base URL
# Enter the ngrok URL (e.g., https://abc123.ngrok.io)
```

---

## Project Structure

```
app/
  (tabs)/              ← Main tab navigation
    index.tsx          ← Home / Dashboard
    stations.tsx       ← Find E85 Stations
    fuel-log.tsx       ← Track Fill-Ups & Blends
    reminders.tsx      ← Maintenance Reminders
    settings.tsx       ← App Settings
  _layout.tsx          ← Root layout with providers

components/            ← Reusable UI components
  screen-container.tsx ← SafeArea wrapper
  ui/                  ← Icon mappings, buttons, etc.

lib/
  fuel-prices.ts       ← EIA price fetching
  station-data.ts      ← NREL station API
  ble-eflex.ts         ← BLE integration (placeholder)
  trpc.ts              ← tRPC client setup

server/                ← Backend (Node.js / Express)
  _core/index.ts       ← Server entry point
  routes/              ← API endpoints
  README.md            ← Backend documentation

assets/images/         ← App icons, splash screen
theme.config.js        ← Color palette
tailwind.config.js     ← Tailwind CSS config
```

---

## Key Features

### E85 Calculator
- Input desired blend % (e.g., 85% ethanol)
- Calculate E85 and gasoline gallons needed
- Save favorite blends for quick access

### Station Finder
- Locate nearby E85 stations (NREL database)
- View real-time prices (EIA weekly gas prices + community-reported E85)
- Community voting: confirm if station actually sells E85
- Sort by distance or cheapest price

### Fuel Log
- Log fill-ups with odometer, blend %, and prices
- Track fuel economy (MPG) over time
- View savings vs. regular gasoline

### Maintenance Reminders
- Set mileage-based reminders (e.g., oil change every 5,000 mi)
- Set date-based reminders (e.g., inspection every 12 months)
- Receive notifications when reminders are due

---

## Troubleshooting

### "Station search not working" or "Rate limit exceeded"

**Cause:** Using the shared demo NREL API key, which is rate-limited.

**Fix:** 
1. Get your own free API key at [developer.nrel.gov](https://developer.nrel.gov)
2. Add to `.env`: `EXPO_PUBLIC_NREL_API_KEY=your_key_here`
3. Restart the dev server: `pnpm dev`

### "API connection refused" on physical device

**Cause:** App is trying to connect to `localhost:3000`, which doesn't exist on the device.

**Fix:**
1. Go to Settings > Dev Settings > API Base URL
2. Enter your machine's LAN IP: `http://192.168.x.x:3000`
3. Restart the app

### "Auth not working" or "Login fails"

**Cause:** OAuth or JWT configuration issue.

**Fix:**
1. Check `.env` has `JWT_SECRET` set
2. Verify backend is running: `pnpm dev:server`
3. Check browser console for error messages
4. See `server/README.md` for OAuth setup

### "Splash screen flickers" or "Wrong first frame"

**Cause:** Splash screen configuration mismatch.

**Fix:**
1. Check `app.config.ts` splash screen settings
2. Ensure splash icon exists at `assets/images/splash-icon.png`
3. Clear cache: `pnpm dev --clear`

### ESLint warnings about ESM config

**Cause:** `eslint.config.js` ESM vs `package.json` type mismatch.

**Fix:** See Phase 1 checklist in `PRODUCTION_READINESS.md`

---

## Testing

Run the test suite:

```bash
pnpm test
```

Run tests in watch mode:

```bash
pnpm test --watch
```

---

## Backend Setup (Optional)

The app can work offline with local storage, but for cross-device sync, user accounts, and production NREL proxying, you'll need the backend.

See `server/README.md` for:
- Database setup (PostgreSQL)
- OAuth configuration
- tRPC endpoint setup
- Deployment instructions

---

## Building for Production

### iOS (via EAS)

```bash
eas build --platform ios --auto-submit
```

### Android (via EAS)

```bash
eas build --platform android
```

See [Expo EAS docs](https://docs.expo.dev/eas/) for detailed instructions.

---

## Contributing

1. Create a feature branch: `git checkout -b feature/my-feature`
2. Make changes and test locally
3. Run `pnpm lint` and `pnpm test` to verify
4. Commit and push: `git push origin feature/my-feature`
5. Open a pull request

---

## License

MIT

---

## Support & Feedback

- **Issues:** Open a GitHub issue
- **Questions:** Check `server/README.md` for backend questions
- **Feature requests:** Open a discussion

---

## Roadmap

- [ ] **Phase 1:** Core features (calculator, stations, fuel log) ✓
- [ ] **Phase 2:** Polish & production readiness (in progress)
- [ ] **Phase 3:** Monetization (accounts, analytics, premium features)
- [ ] **Phase 4:** Real-time fuel prices (licensed API integration)
- [ ] **Phase 5:** BLE integration for live ethanol monitoring

---

## Acknowledgments

- **NREL API** for station data
- **EIA** for weekly gasoline prices
- **Expo** for the amazing React Native framework

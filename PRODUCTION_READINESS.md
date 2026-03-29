# E85 Blend App — Production Readiness (Phase 1 & 2)

## Phase 1: Must-Fix Bugs (Correctness, Reliability, Trust)

### NREL API Rate Limits
- [ ] Create server-side tRPC endpoint `/api/stations` that proxies NREL calls with real `EXPO_PUBLIC_NREL_API_KEY`
- [ ] Update client to call `/api/stations` instead of direct NREL API
- [ ] Document that DEMO_KEY is rate-limited; production requires real key
- [ ] Add error messaging when rate limit is hit: "Station search temporarily unavailable — please try again in a few minutes"

### API Base URL on Real Devices
- [ ] Add dev settings screen (under More tab) to configure API base URL (default: `http://localhost:3000`)
- [ ] Detect if running on physical device and suggest LAN IP (`192.168.x.x:3000`) or ngrok tunnel
- [ ] Document in Root README: "For testing on physical devices, use LAN IP or ngrok tunnel"
- [ ] Store selected URL in AsyncStorage so it persists across app restarts

### Auth End-to-End Testing
- [ ] Implement `auth.logout()` handler (currently stubbed)
- [ ] Write and pass `auth.logout.test.ts` (currently skipped)
- [ ] Verify full round-trip: login → auth.me → logout → session cleared
- [ ] Test on both web and native platforms

### BLE / eFlex Module Feature Gate
- [ ] Hide "Live Monitor" tab or gate behind feature flag until real eFlexPlus GATT UUIDs are confirmed
- [ ] Document placeholder UUIDs in `lib/ble-eflex.ts` with TODO comment
- [ ] Add feature flag in settings: `enableBLEMonitor` (default: false)

### Environment Hygiene
- [ ] Create `.env.example` with all required keys and descriptions
- [ ] Add validation script: `scripts/validate-env.ts` that checks required vars at startup
- [ ] Document in Root README: "Copy `.env.example` to `.env` and fill in production keys"

### Expo Updates / OTA
- [ ] Confirm `EXPO_PROJECT_ID` is set in `.env`
- [ ] Test OTA update flow on physical device (if using EAS)
- [ ] Document in Root README: "OTA updates require valid EXPO_PROJECT_ID"

### Crowdsourced Prices Data Integrity
- [ ] Ensure all price entries are labeled "community reported" or "EIA weekly" (not ambiguous)
- [ ] Add data freshness indicator (e.g., "reported 2 hours ago")
- [ ] Document expected behavior: "Prices are user-submitted and may be outdated or incorrect"

---

## Phase 2: Polish Improvements (UX, Consistency, Maintainability)

### Root README
- [ ] Write single-page README with: install, `pnpm dev`, ports, `.env` checklist, link to `server/README.md`
- [ ] Include troubleshooting section: "localhost vs LAN IP," "rate limits," "auth not working"

### Kill ESLint Warning
- [ ] Fix `eslint.config.js` ESM vs `package.json` type mismatch
- [ ] Verify no warnings on `pnpm lint`

### Onboarding & First-Run
- [ ] Add location permission prompt on first app launch
- [ ] Show one-time tooltip: "Station search uses a shared demo API key (rate-limited). For unlimited access, add your own NREL key in Settings."
- [ ] Track `hasSeenOnboarding` in AsyncStorage

### Reminder UX Polish
- [ ] Fix category picker scroll (ensure all categories visible without friction)
- [ ] Add repeat options: "once," "weekly," "monthly," "every 6 months," "yearly," "custom"
- [ ] Improve picker UX: larger touch targets, clearer labels

### Splash Screen / Launch
- [ ] Remove splash screen flicker (if any)
- [ ] Ensure first frame is correct (no layout shift)

### Offline & Error States
- [ ] Unify error messaging across Stations and Fuel Log: "Unable to load [X] — check connection or try again"
- [ ] Add retry button to all error states
- [ ] Test offline mode (disable network, verify graceful fallback)

### Stale todo.md Cleanup
- [ ] Remove obsolete items (e.g., "Garage tab" if now under More)
- [ ] Archive completed sections
- [ ] Keep only active/planned work

---

## Next Steps (Phase 3 — Monetization, deferred)

Phase 3 items (accounts persistence, server NREL, analytics, privacy policy) will be tackled in a future session.

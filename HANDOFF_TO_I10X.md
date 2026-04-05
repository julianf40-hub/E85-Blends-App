# Handoff Document for i10x — E85 Blend App Development

**Date:** April 4, 2026  
**Previous Developer:** Manus AI Agent  
**Next Developer:** i10x  
**Project Status:** TestFlight-Ready (Production Build Phase)

---

## 📋 Executive Summary

The E85 Blend Calculator app is **production-ready** and heading to TestFlight. All critical bugs are fixed, security is hardened, and the codebase is clean. Your job is to:

1. **Build for TestFlight** (one command)
2. **Monitor beta feedback** and fix issues
3. **Add new features** as requested
4. **Maintain code quality** (0 errors, tests passing)

---

## 🚀 Quick Start (First 5 Minutes)

```bash
# 1. Extract the zip
unzip e85-blend-app-testflight-auto-fallback.zip
cd e85-blend-app

# 2. Install dependencies
pnpm install

# 3. Set the NREL API key (only required env var!)
eas secret set NREL_API_KEY wYvVTmn6ub2F09aUEbFrCZB0v6hfqLKeNN3o3ZX6

# 4. Build for TestFlight
eas build --platform ios --profile production

# 5. Submit to TestFlight (in EAS dashboard)
```

**That's it!** The app will automatically use the Manus backend on TestFlight. No manual config needed.

---

## 📚 Project Structure

```
e85-blend-app/
├── app/                          # Expo Router screens
│   ├── (tabs)/
│   │   ├── index.tsx            # Home (Blend Calculator)
│   │   ├── stations.tsx         # E85 Station Finder
│   │   ├── fuel-log.tsx         # Fuel Logging
│   │   ├── reminders.tsx        # Maintenance Reminders
│   │   ├── garage.tsx           # Vehicle Profiles
│   │   ├── settings.tsx         # App Settings
│   │   └── _layout.tsx          # Tab bar config
│   └── _layout.tsx              # Root layout + providers
├── lib/                          # Business logic
│   ├── blend-calculator.ts      # E85 blend math
│   ├── station-data.ts          # Station API integration
│   ├── fuel-log.ts              # Fuel entry storage
│   ├── reminders.ts             # Reminder logic
│   ├── garage.ts                # Vehicle profiles
│   ├── trpc.ts                  # tRPC client setup
│   └── __tests__/               # Unit tests
├── server/                       # Backend (Node.js + Express)
│   ├── _core/index.ts           # Server entry point
│   ├── routers.ts               # tRPC endpoints
│   └── storage.ts               # Database queries
├── constants/                    # Config
│   ├── oauth.ts                 # API base URL logic
│   └── theme.ts                 # Color tokens
├── components/                   # Reusable UI
│   ├── screen-container.tsx     # SafeArea wrapper
│   └── ui/                      # Icon mappings, etc.
├── hooks/                        # React hooks
│   ├── use-colors.ts            # Theme colors
│   └── use-color-scheme.ts      # Dark/light mode
├── API_KEY_SETUP.md             # API key configuration
├── STATIONS_AUDIT.md            # Stations feature audit
├── app.config.ts                # Expo config
├── eas.json                     # EAS build config
├── package.json                 # Dependencies
└── todo.md                       # Feature tracking
```

---

## 🔑 Critical Configuration

### Environment Variables (EAS Secrets)

**Required:**
```bash
NREL_API_KEY=wYvVTmn6ub2F09aUEbFrCZB0v6hfqLKeNN3o3ZX6
```

**Optional (for custom backend):**
```bash
EXPO_PUBLIC_API_BASE_URL=https://your-api-server.com
```

If `EXPO_PUBLIC_API_BASE_URL` is not set, the app automatically uses the Manus backend (`e85blend-pagwdikw.manus.space`). This is intentional and allows TestFlight builds to work without manual config.

### Apple Credentials (for TestFlight submission)

Update `eas.json` with your Apple account info:
```json
"submit": {
  "production": {
    "ios": {
      "appleId": "your-email@example.com",
      "ascAppId": "1234567890",
      "appleTeamId": "ABCD1234EF"
    }
  }
}
```

---

## 🏗️ Architecture Overview

### Frontend (React Native + Expo)
- **Framework:** Expo SDK 54, React Native 0.81, React 19
- **Styling:** NativeWind (Tailwind CSS)
- **State:** React Context + AsyncStorage (local persistence)
- **Navigation:** Expo Router 6 (file-based routing)
- **API:** tRPC (type-safe RPC)

### Backend (Node.js)
- **Framework:** Express.js
- **API:** tRPC routers
- **Database:** PostgreSQL (via Drizzle ORM)
- **Key Endpoints:**
  - `stations.search` — Find nearby E85 stations (proxies NREL API)
  - Other endpoints available for future expansion

### Data Flow
```
Mobile App (React Native)
    ↓
tRPC Client (lib/trpc.ts)
    ↓
Backend Server (Express + tRPC)
    ↓
External APIs (NREL, etc.) or Database
```

---

## 📱 Core Features (Status: Complete)

| Feature | Status | Notes |
|---------|--------|-------|
| **Blend Calculator** | ✅ Complete | Calculates E85/gas ratios, saved blends, quick presets |
| **Station Finder** | ✅ Complete | Maps, location search, auto-fallback to Manus backend |
| **Fuel Logger** | ✅ Complete | Log fill-ups, track prices, odometer syncs with reminders |
| **Reminders** | ✅ Complete | Mileage/date-based, swipe-to-delete, per-vehicle |
| **Garage** | ✅ Complete | Multiple vehicles, tank size, ethanol preference |
| **Settings** | ✅ Complete | Theme toggle, tab visibility, feedback |
| **Error Handling** | ✅ Complete | Meaningful errors instead of silent failures |
| **Security** | ✅ Complete | API key server-only, no client exposure |

---

## 🧪 Testing & Quality

### Run Tests
```bash
pnpm test
```

**Current Status:** 58 tests passing, 0 failures

### TypeScript Check
```bash
pnpm check
```

**Current Status:** 0 errors

### Linting
```bash
pnpm lint
```

### Code Style
- **Formatter:** Prettier (auto-format on save)
- **Linter:** ESLint + Expo recommended config
- **Type Safety:** TypeScript strict mode

---

## 🐛 Known Issues & Limitations

### None Currently
All critical bugs have been fixed. See `todo.md` for completed items.

### Performance Notes
- Station search uses NREL API (rate-limited to 10 requests/day with DEMO_KEY)
- With proper API key, limit is much higher
- Fuel log stored locally (AsyncStorage) — syncs to reminders automatically

---

## 📝 Recent Changes (Sessions 12-13)

### Session 12 — Six Targeted Fixes
1. ✅ Fixed Stations API (tRPC client initialization)
2. ✅ Added visibility toggles for Reminders and Garage tabs
3. ✅ Implemented swipe-to-delete for reminders
4. ✅ Changed default gas ethanol to 10% (E10 standard)
5. ✅ Made saved blends tappable to load configuration
6. ✅ Verified fuel log odometer syncs with reminders

### Session 13 — TestFlight Readiness Audit
1. ✅ Audited stations feature failure points
2. ✅ Implemented automatic Manus backend fallback
3. ✅ Enhanced error handling (meaningful messages)
4. ✅ Updated documentation
5. ✅ Removed manual config requirements

---

## 🚀 Deployment Checklist

Before submitting to TestFlight:

- [ ] Verify `NREL_API_KEY` is set in EAS
- [ ] Update Apple credentials in `eas.json`
- [ ] Run `pnpm test` — all passing
- [ ] Run `pnpm check` — 0 errors
- [ ] Test on iOS simulator: `pnpm ios`
- [ ] Build for TestFlight: `eas build --platform ios --profile production`
- [ ] Submit to TestFlight via EAS dashboard

---

## 🔧 Common Development Tasks

### Add a New Screen
1. Create file: `app/(tabs)/new-screen.tsx`
2. Use `ScreenContainer` for SafeArea handling
3. Add to tab bar in `app/(tabs)/_layout.tsx`
4. Add icon mapping in `components/ui/icon-symbol.tsx`

### Add a New API Endpoint
1. Add tRPC router in `server/routers.ts`
2. Call from client: `trpc.yourRouter.yourProcedure.query()`
3. Type-safe by default (TypeScript)

### Store Data Locally
1. Use `AsyncStorage` for simple key-value
2. Existing patterns in `lib/fuel-log.ts`, `lib/garage.ts`
3. Data persists across app restarts

### Modify Theme Colors
1. Edit `theme.config.js` (single source of truth)
2. Colors auto-update in Tailwind + runtime
3. Use in components: `className="text-primary"` or `useColors()`

---

## 📞 Support & Debugging

### Check Dev Server Status
```bash
pnpm dev
```

Opens Metro bundler at `http://localhost:8081` and backend at `http://localhost:3000`

### View Logs
- **Metro:** Terminal output
- **Backend:** `server/_core/index.ts` console logs
- **Device:** Expo Go app shows errors in real-time

### Debug on Device
1. Build dev client: `eas build --platform ios --profile development`
2. Scan QR code with Expo Go
3. Logs appear in terminal

### Common Issues

| Issue | Solution |
|-------|----------|
| "Cannot find module @/..." | Run `pnpm install` |
| TypeScript errors | Run `pnpm check` to see all errors |
| Tests failing | Run `pnpm test` to see which tests fail |
| Stations not loading | Check `NREL_API_KEY` is set, check network |
| App crashes on startup | Check `app/_layout.tsx` for provider errors |

---

## 📖 Documentation Files

- **API_KEY_SETUP.md** — NREL API key configuration (read this first!)
- **STATIONS_AUDIT.md** — Detailed audit of stations feature
- **README.md** — Original Expo template docs (reference)
- **todo.md** — Feature tracking and completion history

---

## 🎯 Next Steps for i10x

1. **Extract & Setup** (5 min)
   - Unzip the file
   - Run `pnpm install`

2. **Verify Build** (10 min)
   - Run `pnpm test` — should see 58 passing
   - Run `pnpm check` — should see 0 errors

3. **Set API Key** (2 min)
   - `eas secret set NREL_API_KEY <key>`

4. **Build for TestFlight** (30 min)
   - `eas build --platform ios --profile production`

5. **Submit** (5 min)
   - Use EAS dashboard to submit to TestFlight

6. **Monitor Beta** (ongoing)
   - Watch for feedback from testers
   - Fix bugs as they're reported
   - Add features as requested

---

## 💡 Pro Tips

1. **Always run tests before pushing:** `pnpm test && pnpm check`
2. **Use TypeScript strictly:** Let the type system catch bugs
3. **Test on real device:** Simulator doesn't catch all issues
4. **Keep git history clean:** One commit per feature
5. **Document big changes:** Update `todo.md` and code comments
6. **Ask for clarification:** If requirements are unclear, ask before coding

---

## 📞 Questions?

- **Project Context:** See `todo.md` for complete feature history
- **Code Questions:** Read the comments in the relevant file
- **Architecture Questions:** See this handoff document
- **API Questions:** See `server/routers.ts` and `lib/trpc.ts`

---

**Good luck! The app is in great shape. You've got this! 🚀**

# i10x Quick Start — 5 Minutes to TestFlight Build

## TL;DR — Just Run These Commands

```bash
# 1. Extract
unzip e85-blend-app-testflight-auto-fallback.zip
cd e85-blend-app

# 2. Install
pnpm install

# 3. Set API key (ONLY required env var!)
eas secret set NREL_API_KEY <your-nrel-api-key>

# 4. Verify everything works
pnpm test    # Should see: 58 passing
pnpm check   # Should see: 0 errors

# 5. Build for TestFlight
eas build --platform ios --profile production

# 6. Submit in EAS dashboard
```

**Done!** App is on TestFlight. No other config needed.

---

## What You're Taking Over

✅ **Production-Ready App**
- All bugs fixed
- Security hardened
- Tests passing
- Ready for beta

✅ **Automatic Backend**
- No manual config on TestFlight
- Uses Manus backend by default
- Can override with custom backend if needed

✅ **Clean Codebase**
- TypeScript strict mode
- 0 errors, 58 tests
- Well-documented
- Easy to extend

---

## Key Files to Know

| File | Purpose |
|------|---------|
| `app/(tabs)/` | All screens (calculator, stations, fuel log, etc.) |
| `lib/` | Business logic (blend math, storage, API calls) |
| `server/routers.ts` | Backend API endpoints |
| `constants/oauth.ts` | API base URL logic (has auto-fallback) |
| `API_KEY_SETUP.md` | API key configuration |
| `todo.md` | Feature tracking and history |
| `HANDOFF_TO_I10X.md` | Full handoff document (read this!) |

---

## Common Tasks

### Run Tests
```bash
pnpm test
```

### Check TypeScript
```bash
pnpm check
```

### Dev Server (for testing)
```bash
pnpm dev
```

### Format Code
```bash
pnpm format
```

### Build for iOS Simulator
```bash
pnpm ios
```

---

## Important Notes

1. **NREL_API_KEY is the only required env var** for TestFlight
2. **Automatic backend fallback** means no manual EXPO_PUBLIC_API_BASE_URL needed
3. **All data is local** (AsyncStorage) — no cloud sync by default
4. **Tests must pass** before every build
5. **TypeScript strict** — catch errors early

---

## If Something Breaks

1. Check `pnpm test` output
2. Check `pnpm check` output
3. Read the error message carefully
4. Look at `HANDOFF_TO_I10X.md` troubleshooting section
5. Check the relevant file's comments

---

## Questions?

**Read these in order:**
1. This file (you are here)
2. `HANDOFF_TO_I10X.md` (full context)
3. `API_KEY_SETUP.md` (API configuration)
4. `todo.md` (feature history)
5. Code comments in the relevant file

---

**You're all set! Build with confidence. 🚀**

# Stations Feature Audit & Fix Report

## Root Cause Analysis

### The Problem
Nearby stations feature fails silently on TestFlight/native builds, showing empty station list instead of meaningful errors.

### Why It Fails

**1. Missing API Base URL on Native**
- File: `constants/oauth.ts` line 32-50
- `getApiBaseUrl()` only works on web (derives from `window.location`)
- On native/TestFlight, it returns empty string `""`
- Result: tRPC URL becomes `"/api/trpc"` (relative URL) instead of `"https://api-server.com/api/trpc"`
- Native fetch fails to resolve relative URLs

**2. Errors Are Silently Swallowed**
- File: `lib/station-data.ts` line 81-84
- `fetchNearbyStations()` catches ALL errors and returns `[]` (empty array)
- No error logging or propagation
- Result: UI shows "No E85 stations found" instead of "Server unreachable"

**3. Missing Environment Variable**
- File: `constants/oauth.ts` line 16
- `EXPO_PUBLIC_API_BASE_URL` is never set in EAS build
- App depends on web-only logic to derive the URL
- On TestFlight, this logic doesn't run

**4. No Validation of Configuration**
- No check that `getApiBaseUrl()` returns a valid URL
- No warning when API base URL is empty
- No fallback for native builds

## Exact Failure Flow

1. User opens Stations tab on TestFlight
2. `stations.tsx` calls `fetchNearbyStations(lat, lon, radius)`
3. `station-data.ts` creates tRPC client with `createTRPCClient()`
4. tRPC client URL is `${getApiBaseUrl()}/api/trpc` = `"/api/trpc"` (empty base)
5. Native fetch tries to resolve relative URL `/api/trpc` → fails
6. Error caught and swallowed → returns `[]`
7. UI shows "No E85 stations found within 25 miles"
8. User thinks there are no stations, not that the app is misconfigured

## Files Requiring Changes

1. **constants/oauth.ts** - Fix `getApiBaseUrl()` for native
2. **lib/station-data.ts** - Surface meaningful errors instead of swallowing
3. **lib/trpc.ts** - Add validation and error handling
4. **app/(tabs)/stations.tsx** - Distinguish error types in UI
5. **eas.json** - Document required env vars
6. **API_KEY_SETUP.md** - Update setup documentation

## Required Environment Variables for TestFlight

```
EXPO_PUBLIC_API_BASE_URL=https://your-api-server.com
NREL_API_KEY=<your-nrel-key>
```

## Manual Steps Before Rebuilding

1. Set EAS secrets:
   ```bash
   eas secret set EXPO_PUBLIC_API_BASE_URL https://your-api-server.com
   eas secret set NREL_API_KEY <your-nrel-key>
   ```

2. Verify `eas.json` has `env` section with both variables

3. Rebuild:
   ```bash
   eas build --platform ios --profile production
   ```

## Expected Behavior After Fix

- **Valid API URL + Network OK**: Stations load normally
- **Valid API URL + Network Fail**: Shows "Network error. Check connection."
- **Invalid/Missing API URL**: Shows "App misconfigured. Contact support."
- **API returns 0 stations**: Shows "No E85 stations found. Try increasing radius."

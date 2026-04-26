# NREL API Key Setup — Security & Configuration

## Overview

The 85Blends app uses the NREL Alternative Fuel Data Center (AFDC) API to fetch E85 station locations and data. **The API key is now handled securely** — it's stored on the server only and never exposed to the client app.

## Architecture

- **Client app** (`lib/station-data.ts`): Calls the backend server proxy via tRPC
- **Backend server** (`server/routers.ts`): Holds the NREL API key in a server-only environment variable and proxies requests to NREL
- **Result**: The real API key never leaves the server; the client app can't access it

## Getting Your NREL API Key

1. Go to [developer.nrel.gov](https://developer.nrel.gov)
2. Sign up or log in
3. Create an API key for the Alternative Fuel Stations API
4. Copy the key (looks like: `<your-nrel-api-key>`)

## Local Development Setup

### Option 1: Environment Variable (.env.local)

Create a `.env.local` file in the project root:

```bash
NREL_API_KEY=your_actual_api_key_here
```

The dev server will read this automatically.

### Option 2: Shell Environment

```bash
export NREL_API_KEY=your_actual_api_key_here
pnpm dev
```

## EAS Build Setup (TestFlight / App Store)

### API Base URL (Required for Native Builds)

Set your backend server URL as an EAS secret so TestFlight builds can reach the API:

```bash
eas secret set EXPO_PUBLIC_API_BASE_URL https://your-api-server.com
```

### NREL API Key (Server-side) — Required

```bash
eas secret set NREL_API_KEY your_actual_api_key_here
```

This stores the key securely in EAS and injects it into the backend server. The key is **never** stored in `eas.json` or version control.

### Summary
- **NREL_API_KEY**: Required (backend needs it to call NREL API)
- **EXPO_PUBLIC_API_BASE_URL**: Required for native/TestFlight builds (set to your API server URL)

## Verifying the Setup

1. **Local dev**: Open the Stations tab, enable location, and search. If stations load, the key is working.
2. **Production build**: Same test — if stations load without hitting rate limits, the key is properly configured.

## Troubleshooting

| Issue | Solution |
|---|---|
| Stations don't load on TestFlight | Check that `NREL_API_KEY` and `EXPO_PUBLIC_API_BASE_URL` are set in EAS. |
| "Cannot reach server" error on TestFlight | Verify `EXPO_PUBLIC_API_BASE_URL` points to your running API server. |
| Stations work on web but not iOS/Android | Usually means `NREL_API_KEY` or `EXPO_PUBLIC_API_BASE_URL` is not set. Verify both are in EAS. |
| Rate limit errors (429) | Verify the API key is valid and not expired at developer.nrel.gov |
| "NREL API key is not configured on the server" | Set `NREL_API_KEY` in your backend environment and restart the server. |

## Security Notes

- ✅ The real API key is **never** in the client bundle
- ✅ The real API key is **never** in `eas.json` or version control
- ✅ Station requests go through the backend proxy, not directly from the client
- ✅ The server validates all requests before forwarding to NREL
- ⚠️ If you accidentally commit the key to Git, revoke it immediately at developer.nrel.gov

## API Endpoint

The backend proxy endpoint is:

```
POST /api/trpc/stations.search
```

Input:
```json
{
  "latitude": 40.7128,
  "longitude": -74.0060,
  "radius": 25,
  "fuelType": "E85"
}
```

Output: NREL AFDC API response with nearby E85 stations.

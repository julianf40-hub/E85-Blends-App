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
4. Copy the key (looks like: `wYvVTmn6ub2F09aUEbFrCZB0v6hfqLKeNN3o3ZX6`)

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

Before building for production, set the NREL API key as an EAS secret:

```bash
eas secret set NREL_API_KEY your_actual_api_key_here
```

This stores the key securely in EAS and injects it into the production build. The key is **never** stored in `eas.json` or version control.

## Verifying the Setup

1. **Local dev**: Open the Stations tab, enable location, and search. If stations load, the key is working.
2. **Production build**: Same test — if stations load without hitting rate limits, the key is properly configured.

## Troubleshooting

| Issue | Solution |
|---|---|
| Stations don't load | Check that `NREL_API_KEY` is set in your environment |
| Rate limit errors (429) | Verify the API key is valid and not expired at developer.nrel.gov |
| "DEMO_KEY" fallback used | The `NREL_API_KEY` env var is not set; the app falls back to the public demo key (rate-limited) |

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

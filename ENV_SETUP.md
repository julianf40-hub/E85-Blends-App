# Environment Configuration Guide

Copy the template below to `.env` in the project root and fill in your values.

```bash
# ─── REQUIRED (Production) ───────────────────────────────────────────────

# NREL API Key for station data
# Get free key at: https://developer.nrel.gov/signup/
# Without this, the app uses a shared demo key (rate-limited)
EXPO_PUBLIC_NREL_API_KEY=your_nrel_api_key_here

# Expo Project ID for OTA updates
# Find in: app.json > "extra" > "eas" > "projectId" or EAS dashboard
EXPO_PROJECT_ID=your_expo_project_id_here

# ─── OPTIONAL (Backend / Auth) ───────────────────────────────────────────

# PostgreSQL connection string (only if using backend)
# Format: postgresql://user:password@host:port/database
DATABASE_URL=postgresql://localhost/e85_blend_app

# JWT secret for token signing (only if using auth)
# Generate: openssl rand -base64 32
JWT_SECRET=your_jwt_secret_here

# OAuth provider credentials (if enabling sign-in)
# Google OAuth
GOOGLE_CLIENT_ID=your_google_client_id
GOOGLE_CLIENT_SECRET=your_google_client_secret

# Apple OAuth
APPLE_CLIENT_ID=your_apple_client_id
APPLE_TEAM_ID=your_apple_team_id

# ─── OPTIONAL (Development) ─────────────────────────────────────────────

# API base URL for development
# Default: http://localhost:3000
# For physical devices: http://192.168.x.x:3000 (replace x.x with your IP)
# For remote testing: https://your-ngrok-url.ngrok.io
API_BASE_URL=http://localhost:3000

# Node environment
NODE_ENV=development

# ─── OPTIONAL (Feature Flags) ────────────────────────────────────────────

# Enable BLE integration (Live ethanol monitor)
# Default: false (feature not yet ready)
ENABLE_BLE_MONITOR=false

# Enable analytics tracking
# Default: false (privacy-first by default)
ENABLE_ANALYTICS=false
```

## Required Keys Explained

| Key | Purpose | How to Get |
|-----|---------|-----------|
| `EXPO_PUBLIC_NREL_API_KEY` | Fetch E85 station data from NREL database | Free signup at [developer.nrel.gov](https://developer.nrel.gov/signup/) |
| `EXPO_PROJECT_ID` | Enable OTA (over-the-air) updates via Expo | Found in `app.json` or [EAS dashboard](https://expo.dev/eas) |

## For Production Deployment

1. **Never commit `.env` to version control** (it's in `.gitignore`)
2. **Use a secrets manager** (AWS Secrets Manager, Vercel Secrets, etc.)
3. **Ensure `EXPO_PUBLIC_NREL_API_KEY` is set** (not the demo key, which is rate-limited)
4. **Set `NODE_ENV=production`** for optimized builds
5. **Verify `JWT_SECRET` is strong and unique** (use `openssl rand -base64 32`)

## Troubleshooting

**"Station search not working" or "Rate limit exceeded"**
- You're using the shared demo key. Set `EXPO_PUBLIC_NREL_API_KEY` to your own key.

**"API connection refused" on physical device**
- Set `API_BASE_URL` to your machine's LAN IP: `http://192.168.x.x:3000`

**"Auth not working"**
- Ensure `JWT_SECRET` is set and the backend is running (`pnpm dev:server`)

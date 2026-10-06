// 85Blends — cross-platform Station Price Alert management API.
//
// verify_jwt=false is intentional: 85Blends does not use Supabase Auth sessions here and modern
// publishable keys are not JWTs. Authorization is enforced in-function with a client-safe project
// API key plus a per-installation random secret whose SHA-256 hash is the only stored form.
//
// iOS/APNs requests remain backward-compatible. Android clients use platform="android",
// package_name, and fcm_token for push-device registration.

import postgres from "npm:postgres@3.4.5";

type JsonObject = Record<string, unknown>;
type Sql = ReturnType<typeof postgres>;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ALLOWED_ALERT_MODES = new Set(["any_change", "price_drop", "at_or_below"]);
const ALLOWED_RC_ENVIRONMENTS = new Set(["SANDBOX", "PRODUCTION"]);
const ALLOWED_APNS_ENVIRONMENTS = new Set(["sandbox", "production"]);
const ALLOWED_PLATFORMS = new Set(["ios", "android"]);

function json(status: number, body: JsonObject): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function asObject(value: unknown): JsonObject | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as JsonObject
    : null;
}

function asTrimmedString(value: unknown, maxLength = 4096): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > maxLength) return null;
  return trimmed;
}

function asUuid(value: unknown): string | null {
  const text = asTrimmedString(value, 64);
  return text && UUID_RE.test(text) ? text.toLowerCase() : null;
}

function asFiniteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function asInteger(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) ? value : null;
}

function platformFrom(value: unknown, fallback: "ios" | "android" = "ios"): "ios" | "android" | null {
  if (value == null) return fallback;
  const platform = asTrimmedString(value, 16)?.toLowerCase() ?? null;
  return platform && ALLOWED_PLATFORMS.has(platform) ? platform as "ios" | "android" : null;
}

function publicApiKeys(): string[] {
  const keys: string[] = [];
  const rawPublishable = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  if (rawPublishable) {
    try {
      const parsed = JSON.parse(rawPublishable) as Record<string, unknown>;
      for (const value of Object.values(parsed)) {
        if (typeof value === "string" && value.length > 0) keys.push(value);
      }
    } catch {}
  }
  const legacyAnon = Deno.env.get("SUPABASE_ANON_KEY");
  if (legacyAnon) keys.push(legacyAnon);
  return keys;
}

function hasValidClientApiKey(req: Request): boolean {
  const candidates = publicApiKeys();
  if (candidates.length === 0) return false;
  const apiKey = req.headers.get("apikey")?.trim() ?? "";
  if (apiKey && candidates.includes(apiKey)) return true;
  const authorization = req.headers.get("authorization")?.trim() ?? "";
  if (authorization.toLowerCase().startsWith("bearer ")) {
    const bearer = authorization.slice(7).trim();
    if (bearer && candidates.includes(bearer)) return true;
  }
  return false;
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(a: string, b: string): boolean {
  const len = Math.max(a.length, b.length, 1);
  let diff = a.length === b.length ? 0 : 1;
  for (let i = 0; i < len; i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

function validateInstallationCredentials(body: JsonObject): { clientId: string; secret: string } | null {
  const clientId = asUuid(body.client_installation_id);
  const secret = asTrimmedString(body.installation_secret, 512);
  if (!clientId || !secret || secret.length < 32) return null;
  return { clientId, secret };
}

interface InstallationRow {
  id: string;
  client_installation_id: string;
  installation_secret_hash: string;
  client_platform: "ios" | "android";
  revenuecat_app_user_id: string | null;
  revenuecat_environment: "SANDBOX" | "PRODUCTION" | null;
  revenuecat_customer_id: string | null;
}

async function loadAndAuthenticateInstallation(
  sql: Sql,
  body: JsonObject,
): Promise<{ ok: true; installation: InstallationRow } | { ok: false; response: Response }> {
  const credentials = validateInstallationCredentials(body);
  if (!credentials) return { ok: false, response: json(400, { error: "invalid_installation_credentials" }) };
  const incomingHash = await sha256Hex(credentials.secret);
  const rows = await sql<InstallationRow[]>`
    select id, client_installation_id, installation_secret_hash, client_platform,
           revenuecat_app_user_id, revenuecat_environment, revenuecat_customer_id
    from private.price_alert_installations
    where client_installation_id = ${credentials.clientId}
    limit 1
  `;
  const installation = rows[0];
  if (!installation || !constantTimeEqual(installation.installation_secret_hash, incomingHash)) {
    return { ok: false, response: json(401, { error: "invalid_installation_credentials" }) };
  }
  await sql`update private.price_alert_installations set last_seen_at = now() where id = ${installation.id}`;
  return { ok: true, installation };
}

async function resolveCurrentPro(
  sql: Sql,
  installation: InstallationRow,
): Promise<{ isPro: boolean; customerId: string | null }> {
  if (!installation.revenuecat_app_user_id || !installation.revenuecat_environment) {
    return { isPro: false, customerId: null };
  }
  const rows = await sql<{ customer_id: string; pro_is_active: boolean }[]>`
    select ra.customer_id, rc.pro_is_active
    from private.revenuecat_aliases ra
    join private.revenuecat_customers rc on rc.id = ra.customer_id
    where ra.app_user_id = ${installation.revenuecat_app_user_id}
      and ra.environment = ${installation.revenuecat_environment}
      and rc.environment = ${installation.revenuecat_environment}
      and rc.entitlement_id = 'pro'
    limit 1
  `;
  const match = rows[0] ?? null;
  const customerId = match?.customer_id ?? null;
  await sql`
    update private.price_alert_installations
    set revenuecat_customer_id = ${customerId}, last_pro_check_at = now()
    where id = ${installation.id}
  `;
  return { isPro: match?.pro_is_active === true, customerId };
}

async function bootstrap(sql: Sql, body: JsonObject): Promise<Response> {
  const credentials = validateInstallationCredentials(body);
  if (!credentials) return json(400, { error: "invalid_installation_credentials" });
  const clientPlatform = platformFrom(body.platform ?? body.client_platform);
  if (!clientPlatform) return json(400, { error: "invalid_platform" });
  const secretHash = await sha256Hex(credentials.secret);
  const contributorId = body.contributor_id == null ? null : asUuid(body.contributor_id);
  if (body.contributor_id != null && !contributorId) return json(400, { error: "invalid_contributor_id" });
  const appVersion = body.app_version == null ? null : asTrimmedString(body.app_version, 64);
  if (body.app_version != null && !appVersion) return json(400, { error: "invalid_app_version" });

  await sql`
    insert into private.price_alert_installations (
      client_installation_id, installation_secret_hash, contributor_id, app_version, client_platform
    ) values (
      ${credentials.clientId}, ${secretHash}, ${contributorId}, ${appVersion}, ${clientPlatform}
    )
    on conflict (client_installation_id) do nothing
  `;

  const auth = await loadAndAuthenticateInstallation(sql, body);
  if (!auth.ok) return auth.response;
  await sql`
    update private.price_alert_installations
    set contributor_id = coalesce(${contributorId}, contributor_id),
        app_version = coalesce(${appVersion}, app_version),
        client_platform = ${clientPlatform},
        last_seen_at = now()
    where id = ${auth.installation.id}
  `;

  let installation: InstallationRow = { ...auth.installation, client_platform: clientPlatform };
  const rcAppUserId = body.revenuecat_app_user_id == null ? null : asTrimmedString(body.revenuecat_app_user_id, 512);
  const rcEnvironment = body.revenuecat_environment == null ? null : asTrimmedString(body.revenuecat_environment, 16);
  if ((body.revenuecat_app_user_id == null) !== (body.revenuecat_environment == null)) {
    return json(400, { error: "revenuecat_identity_requires_environment" });
  }
  if (body.revenuecat_app_user_id != null) {
    if (!rcAppUserId || !rcEnvironment || !ALLOWED_RC_ENVIRONMENTS.has(rcEnvironment)) {
      return json(400, { error: "invalid_revenuecat_identity" });
    }
    await sql`
      update private.price_alert_installations
      set revenuecat_app_user_id = ${rcAppUserId}, revenuecat_environment = ${rcEnvironment}, last_pro_check_at = now()
      where id = ${installation.id}
    `;
    installation = { ...installation, revenuecat_app_user_id: rcAppUserId, revenuecat_environment: rcEnvironment as "SANDBOX" | "PRODUCTION" };
  }

  const pro = await resolveCurrentPro(sql, installation);
  return json(200, {
    status: "ready",
    client_installation_id: credentials.clientId,
    platform: clientPlatform,
    pro_is_active: pro.isPro,
    revenuecat_linked: pro.customerId !== null,
  });
}

async function registerDevice(sql: Sql, body: JsonObject): Promise<Response> {
  const auth = await loadAndAuthenticateInstallation(sql, body);
  if (!auth.ok) return auth.response;
  const platform = platformFrom(body.platform, auth.installation.client_platform);
  if (!platform) return json(400, { error: "invalid_platform" });

  let appIdentifier: string;
  let environment: string | null;
  let deviceToken: string;
  if (platform === "ios") {
    const bundleId = asTrimmedString(body.bundle_id, 255);
    const apnsEnvironment = asTrimmedString(body.apns_environment, 16);
    const token = asTrimmedString(body.device_token, 1024);
    if (!bundleId || bundleId.length < 3 || !apnsEnvironment || !ALLOWED_APNS_ENVIRONMENTS.has(apnsEnvironment) || !token || token.length < 16) {
      return json(400, { error: "invalid_device_registration" });
    }
    appIdentifier = bundleId;
    environment = apnsEnvironment;
    deviceToken = token;
  } else {
    const packageName = asTrimmedString(body.package_name ?? body.bundle_id, 255);
    const token = asTrimmedString(body.fcm_token ?? body.device_token, 1024);
    if (!packageName || packageName.length < 3 || !token || token.length < 16) {
      return json(400, { error: "invalid_device_registration" });
    }
    appIdentifier = packageName;
    environment = null;
    deviceToken = token;
  }

  const tokenHash = await sha256Hex(deviceToken);
  let deviceId: string | null = null;
  await sql.begin(async (tx) => {
    // Serialize concurrent registrations for the same installation: the second waits for the first to
    // commit, then (READ COMMITTED) deactivates the first's token below instead of racing it. Only the
    // authenticated installation's own row is locked, so unrelated installations never wait. NO KEY
    // UPDATE (not UPDATE) so foreign-key checks from alert/device inserts are not blocked.
    await tx`select id from private.price_alert_installations where id = ${auth.installation.id} for no key update`;
    await tx`
      update private.price_alert_push_devices
      set enabled = false, invalidated_at = coalesce(invalidated_at, now())
      where installation_id = ${auth.installation.id}
        and platform = ${platform}
        and bundle_id = ${appIdentifier}
        and device_token_hash <> ${tokenHash}
        and enabled = true
        and invalidated_at is null
    `;

    if (platform === "ios") {
      const rows = await tx<{ id: string }[]>`
        insert into private.price_alert_push_devices (
          installation_id, platform, bundle_id, apns_environment,
          device_token, device_token_hash, enabled, invalidated_at, last_registered_at
        ) values (
          ${auth.installation.id}, 'ios', ${appIdentifier}, ${environment},
          ${deviceToken}, ${tokenHash}, true, null, now()
        )
        on conflict (bundle_id, apns_environment, device_token_hash) do update
        set installation_id = excluded.installation_id,
            platform = 'ios',
            device_token = excluded.device_token,
            enabled = true,
            invalidated_at = null,
            last_registered_at = now(),
            failure_count = 0,
            last_failure_at = null
        returning id
      `;
      deviceId = rows[0]?.id ?? null;
    } else {
      const rows = await tx<{ id: string }[]>`
        insert into private.price_alert_push_devices (
          installation_id, platform, bundle_id, apns_environment,
          device_token, device_token_hash, enabled, invalidated_at, last_registered_at
        ) values (
          ${auth.installation.id}, 'android', ${appIdentifier}, null,
          ${deviceToken}, ${tokenHash}, true, null, now()
        )
        on conflict (bundle_id, device_token_hash) where platform = 'android' do update
        set installation_id = excluded.installation_id,
            platform = 'android',
            apns_environment = null,
            device_token = excluded.device_token,
            enabled = true,
            invalidated_at = null,
            last_registered_at = now(),
            failure_count = 0,
            last_failure_at = null
        returning id
      `;
      deviceId = rows[0]?.id ?? null;
    }
  });

  return json(200, { status: "registered", platform, device_id: deviceId });
}

async function unregisterDevice(sql: Sql, body: JsonObject): Promise<Response> {
  const auth = await loadAndAuthenticateInstallation(sql, body);
  if (!auth.ok) return auth.response;
  const deviceToken = asTrimmedString(body.fcm_token ?? body.device_token, 1024);
  if (!deviceToken) return json(400, { error: "invalid_device_token" });
  const tokenHash = await sha256Hex(deviceToken);
  const rows = await sql<{ id: string }[]>`
    update private.price_alert_push_devices
    set enabled = false, invalidated_at = coalesce(invalidated_at, now())
    where installation_id = ${auth.installation.id} and device_token_hash = ${tokenHash}
    returning id
  `;
  return json(200, { status: "unregistered", changed: rows.length > 0 });
}

async function setAlert(sql: Sql, body: JsonObject): Promise<Response> {
  const auth = await loadAndAuthenticateInstallation(sql, body);
  if (!auth.ok) return auth.response;
  const pro = await resolveCurrentPro(sql, auth.installation);
  if (!pro.isPro) return json(403, { error: "pro_required" });
  const stationId = asUuid(body.station_id);
  const alertMode = asTrimmedString(body.alert_mode, 32) ?? "price_drop";
  if (!stationId || !ALLOWED_ALERT_MODES.has(alertMode)) return json(400, { error: "invalid_alert" });
  const threshold = body.threshold_price == null ? null : asFiniteNumber(body.threshold_price);
  if (alertMode === "at_or_below") {
    if (threshold == null || threshold < 1 || threshold > 8) return json(400, { error: "invalid_threshold_price" });
  } else if (body.threshold_price != null) {
    return json(400, { error: "threshold_only_valid_for_at_or_below" });
  }
  const minimumChange = body.minimum_change == null ? 0.05 : asFiniteNumber(body.minimum_change);
  const cooldownMinutes = body.cooldown_minutes == null ? 360 : asInteger(body.cooldown_minutes);
  if (minimumChange == null || minimumChange < 0.01 || minimumChange > 2 || cooldownMinutes == null || cooldownMinutes < 60 || cooldownMinutes > 10080) {
    return json(400, { error: "invalid_alert_preferences" });
  }
  const stationRows = await sql<{ id: string }[]>`select id from public.community_stations where id = ${stationId} limit 1`;
  if (stationRows.length === 0) return json(404, { error: "station_not_found" });
  const rows = await sql<{
    id: string; station_id: string; alert_mode: string; threshold_price: string | null;
    minimum_change: string; cooldown_minutes: number; enabled: boolean;
  }[]>`
    insert into private.price_alerts (
      installation_id, station_id, alert_mode, threshold_price, minimum_change, cooldown_minutes, enabled
    ) values (
      ${auth.installation.id}, ${stationId}, ${alertMode}, ${threshold}, ${minimumChange}, ${cooldownMinutes}, true
    )
    on conflict (installation_id, station_id) do update
    set alert_mode = excluded.alert_mode,
        threshold_price = excluded.threshold_price,
        minimum_change = excluded.minimum_change,
        cooldown_minutes = excluded.cooldown_minutes,
        enabled = true
    returning id, station_id, alert_mode, threshold_price, minimum_change, cooldown_minutes, enabled
  `;
  return json(200, { status: "saved", alert: rows[0] });
}

async function deleteAlert(sql: Sql, body: JsonObject): Promise<Response> {
  const auth = await loadAndAuthenticateInstallation(sql, body);
  if (!auth.ok) return auth.response;
  const stationId = asUuid(body.station_id);
  if (!stationId) return json(400, { error: "invalid_station_id" });
  const rows = await sql<{ id: string }[]>`
    delete from private.price_alerts
    where installation_id = ${auth.installation.id} and station_id = ${stationId}
    returning id
  `;
  return json(200, { status: "deleted", changed: rows.length > 0 });
}

async function listAlerts(sql: Sql, body: JsonObject): Promise<Response> {
  const auth = await loadAndAuthenticateInstallation(sql, body);
  if (!auth.ok) return auth.response;
  const alerts = await sql<{
    id: string; station_id: string; alert_mode: string; threshold_price: string | null;
    minimum_change: string; cooldown_minutes: number; enabled: boolean;
    last_notified_price: string | null; last_notified_at: string | null;
    station_name: string; address: string | null; city: string | null; state: string | null;
    latest_price: string | null; latest_reported_at: string | null;
  }[]>`
    select a.id, a.station_id, a.alert_mode, a.threshold_price,
           a.minimum_change, a.cooldown_minutes, a.enabled,
           a.last_notified_price, a.last_notified_at,
           s.name as station_name, s.address, s.city, s.state,
           latest.price as latest_price, latest.reported_at as latest_reported_at
    from private.price_alerts a
    join public.community_stations s on s.id = a.station_id
    left join lateral (
      select r.price, r.reported_at
      from public.e85_price_reports r
      where r.station_id = a.station_id
      order by r.reported_at desc, r.created_at desc
      limit 1
    ) latest on true
    where a.installation_id = ${auth.installation.id}
    order by s.name asc
  `;
  return json(200, { alerts });
}

async function status(sql: Sql, body: JsonObject): Promise<Response> {
  const auth = await loadAndAuthenticateInstallation(sql, body);
  if (!auth.ok) return auth.response;
  const pro = await resolveCurrentPro(sql, auth.installation);
  const [counts] = await sql<{ active_devices: number; enabled_alerts: number }[]>`
    select
      (select count(*)::int from private.price_alert_push_devices d
       where d.installation_id = ${auth.installation.id} and d.enabled = true and d.invalidated_at is null) as active_devices,
      (select count(*)::int from private.price_alerts a
       where a.installation_id = ${auth.installation.id} and a.enabled = true) as enabled_alerts
  `;
  return json(200, {
    platform: auth.installation.client_platform,
    pro_is_active: pro.isPro,
    revenuecat_linked: pro.customerId !== null,
    active_devices: counts?.active_devices ?? 0,
    enabled_alerts: counts?.enabled_alerts ?? 0,
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  if (!hasValidClientApiKey(req)) return json(401, { error: "unauthorized" });
  const dbUrl = Deno.env.get("SUPABASE_DB_URL");
  if (!dbUrl) return json(503, { error: "server_not_configured" });

  let body: JsonObject;
  try {
    const parsed = asObject(await req.json());
    if (!parsed) return json(400, { error: "invalid_json_object" });
    body = parsed;
  } catch {
    return json(400, { error: "invalid_json" });
  }
  const action = asTrimmedString(body.action, 64);
  if (!action) return json(400, { error: "action_required" });
  const sql = postgres(dbUrl, { prepare: false, max: 1, connect_timeout: 10, idle_timeout: 5 });
  try {
    switch (action) {
      case "bootstrap": return await bootstrap(sql, body);
      case "register_device": return await registerDevice(sql, body);
      case "unregister_device": return await unregisterDevice(sql, body);
      case "set_alert": return await setAlert(sql, body);
      case "delete_alert": return await deleteAlert(sql, body);
      case "list_alerts": return await listAlerts(sql, body);
      case "status": return await status(sql, body);
      default: return json(400, { error: "unknown_action" });
    }
  } catch (error) {
    console.error(JSON.stringify({
      level: "error",
      message: "price-alerts-api request failed",
      action,
      detail: error instanceof Error ? error.message.slice(0, 200) : "unknown_error",
      ts: new Date().toISOString(),
    }));
    return json(500, { error: "internal_error" });
  } finally {
    await sql.end({ timeout: 5 }).catch(() => {});
  }
});

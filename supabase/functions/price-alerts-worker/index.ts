// 85Blends — cross-platform station price-alert worker.
// Server-to-server only. Prepares alert deliveries for all registered devices, then claims/sends
// iOS deliveries only when APNs credentials are configured and Android deliveries only when a
// Firebase service-account secret is configured. Missing provider credentials never consume that
// provider's pending deliveries.

import postgres from "npm:postgres@3.4.5";
import { importPKCS8, SignJWT } from "npm:jose@5.9.6";
import { isAuthorizedWorkerCall } from "./auth.ts";
import { classifyFcmResponse } from "./fcm.ts";
import { messageFor, payloadPaymentType } from "./message.ts";

type Json = Record<string, unknown>;
type Sql = ReturnType<typeof postgres>;
type Platform = "ios" | "android";

type Job = { job_id: string; price_report_id: string; attempt_count: number };
type Delivery = {
  delivery_id: string;
  alert_id: string;
  price_report_id: string;
  push_device_id: string;
  platform: Platform;
  station_id: string;
  station_name: string;
  device_token: string;
  apns_environment: "sandbox" | "production" | null;
  bundle_id: string;
  observed_price: string | number;
  previous_price: string | number | null;
  reason_code: string | null;
  attempt_count: number;
  /** The alert's payment method when the delivery was decided. Read separately from the claim (see
   *  paymentTypesFor) so the claim function's pinned shape never changes; absent on an older database. */
  payment_type?: string | null;
};

type SendResult = { ok: boolean; status: number; reason: string; retryable: boolean; invalidate: boolean };
type DeliverySummary = { claimed: number; sent: number; retrying: number; invalid: number; dead: number };

type ApnsConfig = { teamId: string; keyId: string; privateKey: string };
type FcmConfig = { projectId: string; clientEmail: string; privateKey: string };

function response(status: number, body: Json): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

function integer(value: unknown, fallback: number, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isInteger(value)) return fallback;
  return Math.min(max, Math.max(min, value));
}

let cachedApnsToken: { token: string; createdAt: number; fingerprint: string } | null = null;
let cachedFcmToken: { token: string; expiresAt: number; fingerprint: string } | null = null;

function apnsConfig(): ApnsConfig | null {
  const teamId = Deno.env.get("APNS_TEAM_ID")?.trim();
  const keyId = Deno.env.get("APNS_KEY_ID")?.trim();
  const rawKey = Deno.env.get("APNS_PRIVATE_KEY_P8")?.trim();
  if (!teamId || !keyId || !rawKey) return null;
  const privateKey = rawKey.includes("\\n") ? rawKey.replaceAll("\\n", "\n") : rawKey;
  return { teamId, keyId, privateKey };
}

function fcmConfig(): FcmConfig | null {
  const raw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON")?.trim();
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const projectId = typeof parsed.project_id === "string" ? parsed.project_id.trim() : "";
    const clientEmail = typeof parsed.client_email === "string" ? parsed.client_email.trim() : "";
    const rawPrivateKey = typeof parsed.private_key === "string" ? parsed.private_key.trim() : "";
    if (!projectId || !clientEmail || !rawPrivateKey) return null;
    const privateKey = rawPrivateKey.includes("\\n") ? rawPrivateKey.replaceAll("\\n", "\n") : rawPrivateKey;
    return { projectId, clientEmail, privateKey };
  } catch {
    return null;
  }
}

async function apnsJwt(config: ApnsConfig): Promise<string> {
  const fingerprint = `${config.teamId}:${config.keyId}:${config.privateKey.length}`;
  const now = Math.floor(Date.now() / 1000);
  if (cachedApnsToken && cachedApnsToken.fingerprint === fingerprint && now - cachedApnsToken.createdAt < 50 * 60) {
    return cachedApnsToken.token;
  }
  const key = await importPKCS8(config.privateKey, "ES256");
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: config.keyId })
    .setIssuer(config.teamId)
    .setIssuedAt(now)
    .sign(key);
  cachedApnsToken = { token, createdAt: now, fingerprint };
  return token;
}

async function fcmAccessToken(config: FcmConfig): Promise<string> {
  const fingerprint = `${config.projectId}:${config.clientEmail}:${config.privateKey.length}`;
  const now = Math.floor(Date.now() / 1000);
  if (cachedFcmToken && cachedFcmToken.fingerprint === fingerprint && now < cachedFcmToken.expiresAt - 300) {
    return cachedFcmToken.token;
  }

  const key = await importPKCS8(config.privateKey, "RS256");
  const assertion = await new SignJWT({ scope: "https://www.googleapis.com/auth/firebase.messaging" })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(config.clientEmail)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);

  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!tokenResponse.ok) throw new Error(`fcm_oauth_http_${tokenResponse.status}`);
  const body = await tokenResponse.json() as Record<string, unknown>;
  const token = typeof body.access_token === "string" ? body.access_token : "";
  const expiresIn = typeof body.expires_in === "number" && Number.isFinite(body.expires_in) ? body.expires_in : 3600;
  if (!token) throw new Error("fcm_oauth_missing_access_token");
  cachedFcmToken = { token, expiresAt: now + Math.max(300, Math.floor(expiresIn)), fingerprint };
  return token;
}

async function sendApns(delivery: Delivery, config: ApnsConfig): Promise<SendResult> {
  if (!delivery.apns_environment) {
    return { ok: false, status: 0, reason: "missing_apns_environment", retryable: false, invalidate: false };
  }
  const token = await apnsJwt(config);
  const host = delivery.apns_environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  const copy = messageFor(delivery);
  const paymentType = payloadPaymentType(delivery.payment_type);
  const payload = {
    aps: { alert: copy, sound: "default" },
    type: "price_alert",
    station_id: delivery.station_id,
    observed_price: Number(delivery.observed_price),
    // Additive: present only for a Cash or Credit alert; receivers that do not know it ignore it.
    ...(paymentType ? { payment_type: paymentType } : {}),
  };

  const res = await fetch(`${host}/3/device/${encodeURIComponent(delivery.device_token)}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${token}`,
      "content-type": "application/json",
      "apns-topic": delivery.bundle_id,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": "0",
      "apns-id": delivery.delivery_id,
      "apns-collapse-id": `station-${delivery.station_id}`,
    },
    body: JSON.stringify(payload),
  });

  if (res.status === 200) return { ok: true, status: 200, reason: "sent", retryable: false, invalidate: false };
  let reason = `http_${res.status}`;
  try {
    const body = await res.json() as { reason?: unknown };
    if (typeof body.reason === "string" && body.reason.length > 0) reason = body.reason.slice(0, 128);
  } catch {}
  const invalidate = res.status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic" || reason === "Unregistered";
  const retryable = !invalidate && (res.status === 429 || res.status >= 500 || ["TooManyRequests", "InternalServerError", "ServiceUnavailable", "Shutdown"].includes(reason));
  return { ok: false, status: res.status, reason, retryable, invalidate };
}

async function sendFcm(delivery: Delivery, config: FcmConfig): Promise<SendResult> {
  const accessToken = await fcmAccessToken(config);
  const copy = messageFor(delivery);
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(config.projectId)}/messages:send`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json; charset=utf-8",
    },
    body: JSON.stringify({
      message: {
        token: delivery.device_token,
        notification: copy,
        data: {
          type: "price_alert",
          station_id: delivery.station_id,
          observed_price: String(Number(delivery.observed_price)),
          // Additive (FCM data values are strings): present only for a Cash or Credit alert.
          ...(payloadPaymentType(delivery.payment_type) ? { payment_type: payloadPaymentType(delivery.payment_type) as string } : {}),
        },
        android: { priority: "HIGH" },
      },
    }),
  });

  let parsed: unknown = null;
  if (!res.ok) { try { parsed = await res.json(); } catch {} }
  // Only an explicit UNREGISTERED may invalidate the device; configuration and provider errors never do
  // (see fcm.ts). The device token and credentials are never logged.
  const result = classifyFcmResponse(res.status, parsed);
  if (result.kind === "configuration") {
    console.error(JSON.stringify({ level: "error", message: "price-alerts-worker fcm configuration failure", status: result.status, code: result.reason, ts: new Date().toISOString() }));
  }
  return result;
}

async function prepareJobs(sql: Sql, limit: number): Promise<{ claimed: number; prepared: number; failed: number }> {
  const jobs = await sql<Job[]>`select * from private.claim_price_alert_jobs(${limit})`;
  let prepared = 0;
  let failed = 0;
  for (const job of jobs) {
    try {
      await sql`select * from private.prepare_price_alert_deliveries(${job.price_report_id}::uuid)`;
      await sql`select private.finalize_price_alert_job(${job.price_report_id}::uuid)`;
      prepared += 1;
    } catch (error) {
      const detail = error instanceof Error ? error.message.slice(0, 400) : "prepare_failed";
      await sql`select private.mark_price_alert_job_failed(${job.job_id}::uuid, ${detail}, true, 5)`;
      failed += 1;
    }
  }
  return { claimed: jobs.length, prepared, failed };
}

/**
 * The alert's payment method for each claimed delivery. A separate read by delivery id instead of a
 * new column on the claim function, whose exact return shape is pinned by the database test suite
 * because the deployed worker depends on it. If the column does not exist yet (the worker deployed
 * before the migration) or the read fails, every delivery simply gets the plain, method-less copy.
 */
async function paymentTypesFor(sql: Sql, deliveryIds: string[]): Promise<Map<string, string | null>> {
  const types = new Map<string, string | null>();
  if (deliveryIds.length === 0) return types;
  try {
    const rows = await sql<{ id: string; payment_type: string | null }[]>`
      select id, payment_type from private.price_alert_deliveries where id = any(${deliveryIds}::uuid[])
    `;
    for (const row of rows) types.set(row.id, row.payment_type);
  } catch {
    // legacy copy
  }
  return types;
}

async function sendDeliveries(
  sql: Sql,
  platform: Platform,
  limit: number,
  sender: (delivery: Delivery) => Promise<SendResult>,
): Promise<DeliverySummary> {
  const deliveries = await sql<Delivery[]>`select * from private.claim_price_alert_deliveries_v2(${limit}, ${platform})`;
  const paymentTypes = await paymentTypesFor(sql, deliveries.map((delivery) => delivery.delivery_id));
  for (const delivery of deliveries) delivery.payment_type = paymentTypes.get(delivery.delivery_id) ?? null;
  let sent = 0, retrying = 0, invalid = 0, dead = 0;
  for (const delivery of deliveries) {
    try {
      const result = await sender(delivery);
      if (result.ok) {
        await sql`select private.mark_price_alert_delivery_sent(${delivery.delivery_id}::uuid, ${result.status})`;
        sent += 1;
      } else {
        const rows = await sql<{ state: string }[]>`select private.mark_price_alert_delivery_failed(${delivery.delivery_id}::uuid, ${result.status || null}, ${result.reason}, ${result.retryable}, ${result.invalidate}, 5) as state`;
        const state = rows[0]?.state;
        if (state === "failed") retrying += 1;
        else if (state === "invalid_device") invalid += 1;
        else dead += 1;
      }
    } catch (error) {
      const reason = error instanceof Error ? error.name.slice(0, 128) : "worker_exception";
      const rows = await sql<{ state: string }[]>`select private.mark_price_alert_delivery_failed(${delivery.delivery_id}::uuid, null, ${reason}, true, false, 5) as state`;
      if (rows[0]?.state === "failed") retrying += 1; else dead += 1;
    }
  }
  return { claimed: deliveries.length, sent, retrying, invalid, dead };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return response(405, { error: "method_not_allowed" });

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";
  const cronSecret = Deno.env.get("PRICE_ALERTS_WORKER_CRON_SECRET")?.trim() ?? "";
  if (!isAuthorizedWorkerCall(req.headers, { serviceRoleKey, cronSecret })) return response(401, { error: "unauthorized" });

  const dbUrl = Deno.env.get("SUPABASE_DB_URL");
  if (!dbUrl) return response(503, { error: "server_not_configured" });

  let body: Json = {};
  try { body = await req.json() as Json; } catch {}
  const jobLimit = integer(body.job_limit, 20, 1, 100);
  const deliveryLimit = integer(body.delivery_limit, 50, 1, 100);

  const sql = postgres(dbUrl, { prepare: false, max: 1, connect_timeout: 10, idle_timeout: 5 });
  try {
    const jobs = await prepareJobs(sql, jobLimit);
    const apns = apnsConfig();
    const fcm = fcmConfig();

    const iosDeliveries = apns
      ? await sendDeliveries(sql, "ios", deliveryLimit, (delivery) => sendApns(delivery, apns))
      : null;
    const androidDeliveries = fcm
      ? await sendDeliveries(sql, "android", deliveryLimit, (delivery) => sendFcm(delivery, fcm))
      : null;

    const anyConfigured = Boolean(apns || fcm);
    return response(200, {
      status: anyConfigured ? "ok" : "prepared_only",
      apns_configured: Boolean(apns),
      fcm_configured: Boolean(fcm),
      jobs,
      ios_deliveries: iosDeliveries,
      android_deliveries: androidDeliveries,
    });
  } catch (error) {
    console.error(JSON.stringify({
      level: "error",
      message: "price-alerts-worker failed",
      detail: error instanceof Error ? error.message.slice(0, 300) : "unknown",
      ts: new Date().toISOString(),
    }));
    return response(500, { error: "internal_error" });
  } finally {
    await sql.end({ timeout: 5 }).catch(() => {});
  }
});

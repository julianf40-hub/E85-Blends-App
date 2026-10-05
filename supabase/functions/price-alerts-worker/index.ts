// 85Blends 2.4.0 — private station price-alert worker.
// Server-to-server only (see auth.ts: dedicated scheduler secret header, or the service-role
// Bearer). Prepares queued DB jobs even before APNs is configured, but never
// claims/sends device deliveries unless all APNs signing secrets are present.

import postgres from "npm:postgres@3.4.5";
import { importPKCS8, SignJWT } from "npm:jose@5.9.6";
import { isAuthorizedWorkerCall } from "./auth.ts";

type Json = Record<string, unknown>;
type Sql = ReturnType<typeof postgres>;

type Job = { job_id: string; price_report_id: string; attempt_count: number };
type Delivery = {
  delivery_id: string;
  alert_id: string;
  price_report_id: string;
  push_device_id: string;
  station_id: string;
  station_name: string;
  device_token: string;
  apns_environment: "sandbox" | "production";
  bundle_id: string;
  observed_price: string | number;
  previous_price: string | number | null;
  reason_code: string | null;
  attempt_count: number;
};

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

function apnsConfig(): { teamId: string; keyId: string; privateKey: string } | null {
  const teamId = Deno.env.get("APNS_TEAM_ID")?.trim();
  const keyId = Deno.env.get("APNS_KEY_ID")?.trim();
  const rawKey = Deno.env.get("APNS_PRIVATE_KEY_P8")?.trim();
  if (!teamId || !keyId || !rawKey) return null;
  const privateKey = rawKey.includes("\\n") ? rawKey.replaceAll("\\n", "\n") : rawKey;
  return { teamId, keyId, privateKey };
}

async function apnsJwt(config: { teamId: string; keyId: string; privateKey: string }): Promise<string> {
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

function messageFor(delivery: Delivery): { title: string; body: string } {
  const price = Number(delivery.observed_price);
  const formatted = Number.isFinite(price) ? `$${price.toFixed(2)}/gal` : "a new price";
  const name = delivery.station_name?.trim() || "An E85 station";
  switch (delivery.reason_code) {
    case "price_dropped": return { title: "E85 price dropped", body: `${name} dropped to ${formatted}.` };
    case "threshold_crossed":
    case "threshold_met":
    case "threshold_price_changed": return { title: "E85 price alert", body: `${name} is now ${formatted}.` };
    case "price_changed": return { title: "E85 price changed", body: `${name} is now ${formatted}.` };
    default: return { title: "E85 price update", body: `${name} is now ${formatted}.` };
  }
}

async function sendApns(delivery: Delivery, config: { teamId: string; keyId: string; privateKey: string }): Promise<{ ok: boolean; status: number; reason: string; retryable: boolean; invalidate: boolean }> {
  const token = await apnsJwt(config);
  const host = delivery.apns_environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  const copy = messageFor(delivery);
  const payload = {
    aps: { alert: copy, sound: "default" },
    type: "price_alert",
    station_id: delivery.station_id,
    observed_price: Number(delivery.observed_price),
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
  } catch { /* APNs body is optional for classification. */ }

  const invalidate = res.status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic" || reason === "Unregistered";
  const retryable = !invalidate && (res.status === 429 || res.status >= 500 || ["TooManyRequests", "InternalServerError", "ServiceUnavailable", "Shutdown"].includes(reason));
  return { ok: false, status: res.status, reason, retryable, invalidate };
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

async function sendDeliveries(sql: Sql, limit: number, config: { teamId: string; keyId: string; privateKey: string }): Promise<{ claimed: number; sent: number; retrying: number; invalid: number; dead: number }> {
  const deliveries = await sql<Delivery[]>`select * from private.claim_price_alert_deliveries(${limit})`;
  let sent = 0, retrying = 0, invalid = 0, dead = 0;
  for (const delivery of deliveries) {
    try {
      const result = await sendApns(delivery, config);
      if (result.ok) {
        await sql`select private.mark_price_alert_delivery_sent(${delivery.delivery_id}::uuid, ${result.status})`;
        sent += 1;
      } else {
        const rows = await sql<{ state: string }[]>`select private.mark_price_alert_delivery_failed(${delivery.delivery_id}::uuid, ${result.status}, ${result.reason}, ${result.retryable}, ${result.invalidate}, 5) as state`;
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
  try { body = await req.json() as Json; } catch { /* body optional */ }
  const jobLimit = integer(body.job_limit, 20, 1, 100);
  const deliveryLimit = integer(body.delivery_limit, 50, 1, 100);

  const sql = postgres(dbUrl, { prepare: false, max: 1, connect_timeout: 10, idle_timeout: 5 });
  try {
    const jobs = await prepareJobs(sql, jobLimit);
    const config = apnsConfig();
    if (!config) {
      return response(200, { status: "prepared_only", apns_configured: false, jobs });
    }
    const deliveries = await sendDeliveries(sql, deliveryLimit, config);
    return response(200, { status: "ok", apns_configured: true, jobs, deliveries });
  } catch (error) {
    console.error(JSON.stringify({ level: "error", message: "price-alerts-worker failed", detail: error instanceof Error ? error.message.slice(0, 300) : "unknown", ts: new Date().toISOString() }));
    return response(500, { error: "internal_error" });
  } finally {
    await sql.end({ timeout: 5 }).catch(() => {});
  }
});

// Run: node --test supabase/functions/price-alerts-api/*.test.ts   (Node 22+, no Deno required)
//
// Pins the `set_alert` request rules, including the payment-method and minimum-change contract that the
// 2.4.1 "payment-aware alerts" change added, and the wiring in index.ts that cannot run under Node.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  type AlertInput,
  ALLOWED_ALERT_PAYMENT_TYPES,
  COOLDOWN_MINUTES_RANGE,
  DEFAULT_COOLDOWN_MINUTES,
  LEGACY_DEFAULT_MINIMUM_CHANGE,
  MINIMUM_CHANGE_RANGE,
  parseAlertInput,
  THRESHOLD_RANGE,
} from "./alert-input.ts";

const STATION = "3f2c9d1e-5b7a-4c8e-9a10-1b2c3d4e5f60";

function base(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return { station_id: STATION, ...extra };
}

function ok(body: Record<string, unknown>): AlertInput {
  const result = parseAlertInput(body);
  if (!result.ok) assert.fail(`expected ok for ${JSON.stringify(body)}, got ${JSON.stringify(result)}`);
  return result.value;
}

function error(body: Record<string, unknown>): string {
  const result = parseAlertInput(body);
  if (result.ok) assert.fail(`expected an error for ${JSON.stringify(body)}`);
  return result.error;
}

// ---- payment method -------------------------------------------------------------------------------

test("only cash and credit are choosable for an alert", () => {
  assert.deepEqual([...ALLOWED_ALERT_PAYMENT_TYPES].sort(), ["cash", "credit"]);
});

test("a request that names cash or credit stores it", () => {
  assert.equal(ok(base({ payment_type: "cash" })).paymentType, "cash");
  assert.equal(ok(base({ payment_type: "credit" })).paymentType, "credit");
});

test("a request that does not name a method says so (older apps): keep the current one, never invent one", () => {
  assert.equal(ok(base()).paymentType, null);
  assert.equal(ok(base({ payment_type: null })).paymentType, null);
});

test("anything else is refused, with a stable error", () => {
  for (const bad of ["unknown", "same_for_both", "Cash", "CREDIT", " cash", "debit", "", "cash,credit", 1, true, {}, []]) {
    assert.equal(error(base({ payment_type: bad })), "invalid_payment_type", `payment_type=${JSON.stringify(bad)}`);
  }
});

test("a payment method works with every mode", () => {
  assert.equal(ok(base({ alert_mode: "price_drop", payment_type: "credit" })).paymentType, "credit");
  assert.equal(ok(base({ alert_mode: "at_or_below", threshold_price: 2.89, payment_type: "cash" })).paymentType, "cash");
  assert.equal(ok(base({ alert_mode: "any_change", payment_type: "cash" })).alertMode, "any_change");
});

// ---- minimum change (the Price Drop presets and Custom) ----------------------------------------------

test("the presets 0.05, 0.10 and 0.20 and both bounds are accepted unchanged", () => {
  for (const value of [0.05, 0.1, 0.2, MINIMUM_CHANGE_RANGE.min, MINIMUM_CHANGE_RANGE.max, 0.123, 1.999]) {
    assert.equal(ok(base({ minimum_change: value })).minimumChange, value);
  }
});

test("values outside 0.01 to 2.00, and non-numbers, are refused", () => {
  for (const bad of [0, 0.009, -0.05, 2.001, 5, "0.10", NaN, Infinity, {}]) {
    assert.equal(error(base({ minimum_change: bad })), "invalid_alert_preferences", `minimum_change=${String(bad)}`);
  }
});

test("an omitted minimum_change keeps the LEGACY 0.05 default; the newer app sends 0.10 explicitly", () => {
  assert.equal(LEGACY_DEFAULT_MINIMUM_CHANGE, 0.05);
  assert.equal(ok(base()).minimumChange, 0.05);
  assert.equal(ok(base({ minimum_change: null })).minimumChange, 0.05);
  assert.equal(ok(base({ minimum_change: 0.1 })).minimumChange, 0.1);
});

// ---- the rest of the contract is unchanged -----------------------------------------------------------

test("mode defaults to price_drop and must be a known mode", () => {
  assert.equal(ok(base()).alertMode, "price_drop");
  assert.equal(error(base({ alert_mode: "pause" })), "invalid_alert");
  assert.equal(error(base({ alert_mode: "enabled" })), "invalid_alert");
});

test("station_id must be a UUID", () => {
  assert.equal(error({ alert_mode: "price_drop" }), "invalid_alert");
  assert.equal(error({ station_id: "not-a-uuid" }), "invalid_alert");
  assert.equal(ok({ station_id: STATION.toUpperCase() }).stationId, STATION);
});

test("threshold: required and 1..8 for at_or_below, forbidden otherwise", () => {
  assert.equal(error(base({ alert_mode: "at_or_below" })), "invalid_threshold_price");
  assert.equal(error(base({ alert_mode: "at_or_below", threshold_price: 0.99 })), "invalid_threshold_price");
  assert.equal(error(base({ alert_mode: "at_or_below", threshold_price: 8.01 })), "invalid_threshold_price");
  assert.equal(ok(base({ alert_mode: "at_or_below", threshold_price: THRESHOLD_RANGE.min })).thresholdPrice, 1);
  assert.equal(ok(base({ alert_mode: "at_or_below", threshold_price: THRESHOLD_RANGE.max })).thresholdPrice, 8);
  assert.equal(ok(base({ alert_mode: "at_or_below", threshold_price: 2.899 })).thresholdPrice, 2.899);
  assert.equal(error(base({ alert_mode: "price_drop", threshold_price: 2.89 })), "threshold_only_valid_for_at_or_below");
});

test("cooldown defaults to 360 and is bounded 60..10080 integers", () => {
  assert.equal(DEFAULT_COOLDOWN_MINUTES, 360);
  assert.equal(ok(base()).cooldownMinutes, 360);
  assert.equal(ok(base({ cooldown_minutes: COOLDOWN_MINUTES_RANGE.min })).cooldownMinutes, 60);
  assert.equal(ok(base({ cooldown_minutes: COOLDOWN_MINUTES_RANGE.max })).cooldownMinutes, 10080);
  assert.equal(error(base({ cooldown_minutes: 59 })), "invalid_alert_preferences");
  assert.equal(error(base({ cooldown_minutes: 10081 })), "invalid_alert_preferences");
  assert.equal(error(base({ cooldown_minutes: 360.5 })), "invalid_alert_preferences");
});

test("there is no enable/disable/pause input: unknown fields are ignored, never persisted", () => {
  const value = ok(base({ enabled: false, paused: true, pause: true, set_enabled: false }));
  assert.deepEqual(Object.keys(value).sort(),
    ["alertMode", "cooldownMinutes", "minimumChange", "paymentType", "stationId", "thresholdPrice"]);
});

// ---- wiring in index.ts (it only runs on Deno, so its SQL is pinned as text) -----------------------

const here = dirname(fileURLToPath(import.meta.url));
const indexSource = readFileSync(join(here, "index.ts"), "utf8");

test("index.ts delegates validation to alert-input.ts and keeps no second copy of the rules", () => {
  assert.match(indexSource, /import \{ parseAlertInput \} from "\.\/alert-input\.ts";/);
  assert.match(indexSource, /parseAlertInput\(body\)/);
  assert.doesNotMatch(indexSource, /ALLOWED_ALERT_MODES/);
  assert.doesNotMatch(indexSource, /invalid_alert_preferences/);
});

test("set_alert persists payment_type: named => set, omitted => keep (update) or 'unknown' (new)", () => {
  assert.match(indexSource, /coalesce\(\$\{paymentType\}::text, 'unknown'\)/);
  assert.match(indexSource, /payment_type = coalesce\(\$\{paymentType\}::text, private\.price_alerts\.payment_type\)/);
  assert.match(indexSource, /on conflict \(installation_id, station_id\) do update/);
  assert.match(indexSource, /returning id, station_id, alert_mode, threshold_price, minimum_change, cooldown_minutes, enabled, payment_type/);
});

test("set_alert never writes the reference price or notification history (the database owns those)", () => {
  const start = indexSource.indexOf("async function setAlert");
  const end = indexSource.indexOf("async function deleteAlert");
  const setAlert = indexSource.slice(start, end);
  for (const column of ["baseline_price", "baseline_at", "last_notified_price", "last_notified_at"]) {
    assert.ok(!setAlert.includes(column), `set_alert must not write ${column}`);
  }
  assert.ok(!/enabled\s*=\s*false|set_enabled|pause/i.test(setAlert), "no enable/disable/pause path");
});

test("list_alerts keeps the legacy latest_* fields and adds the comparable ones and payment_type", () => {
  assert.match(indexSource, /latest\.price as latest_price, latest\.reported_at as latest_reported_at/);
  assert.match(indexSource, /comparable\.price as latest_comparable_price/);
  assert.match(indexSource, /comparable\.reported_at as latest_comparable_reported_at/);
  assert.match(indexSource, /comparable\.payment_type as latest_comparable_payment_type/);
  assert.match(indexSource, /private\.latest_comparable_price_report\(a\.station_id, a\.payment_type\) comparable/);
  assert.match(indexSource, /a\.enabled, a\.payment_type/);
});

test("delete_alert still only deletes (no device unregistration)", () => {
  const start = indexSource.indexOf("async function deleteAlert");
  const end = indexSource.indexOf("async function listAlerts");
  const deleteAlert = indexSource.slice(start, end);
  assert.match(deleteAlert, /delete from private\.price_alerts/);
  assert.ok(!/price_alert_push_devices/.test(deleteAlert));
});

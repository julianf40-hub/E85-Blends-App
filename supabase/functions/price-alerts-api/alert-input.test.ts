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
  ALERT_CONTRACT_VERSION_RANGE,
  type AlertInput,
  ALLOWED_ALERT_PAYMENT_TYPES,
  COOLDOWN_MINUTES_RANGE,
  DEFAULT_COOLDOWN_MINUTES,
  LEGACY_CONTRACT_VERSION,
  LEGACY_DEFAULT_MINIMUM_CHANGE,
  MINIMUM_CHANGE_RANGE,
  parseAlertInput,
  replacesStoredMinimumChange,
  SENSITIVITY_CONTRACT_VERSION,
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

// ---- the sensitivity contract (alert_contract_version) ------------------------------------------------
//
// An older client never chose a drop size: it sent the fixed 0.05 or nothing. A newer client does choose, and
// declares it with alert_contract_version >= 2. The question every row below answers is "does this request replace
// the drop size of an alert that ALREADY EXISTS?". (A NEW alert always stores the request's value, or 0.05.)

test("the contract constants are what the iOS app and the docs say they are", () => {
  assert.equal(LEGACY_CONTRACT_VERSION, 1);
  assert.equal(SENSITIVITY_CONTRACT_VERSION, 2);
  assert.deepEqual(ALERT_CONTRACT_VERSION_RANGE, { min: 1, max: 1000 });
});

type Row = {
  label: string;
  body: Record<string, unknown>;
  replaces: boolean;
  /** What a NEW alert from this request stores. */
  newAlertValue: number;
  version: number;
};

const sensitivityTable: Row[] = [
  // ---- a pre-contract client (no version) ----
  { label: "older client, minimum_change omitted", body: {}, replaces: false, newAlertValue: 0.05, version: 1 },
  { label: "older client, minimum_change null", body: { minimum_change: null }, replaces: false, newAlertValue: 0.05, version: 1 },
  { label: "older client, the fixed legacy 0.05", body: { minimum_change: 0.05 }, replaces: false, newAlertValue: 0.05, version: 1 },
  { label: "older client, 0.050 written differently", body: { minimum_change: 5e-2 }, replaces: false, newAlertValue: 0.05, version: 1 },
  { label: "older client, 0.05 with float noise", body: { minimum_change: 0.04999999999999999 }, replaces: false, newAlertValue: 0.04999999999999999, version: 1 },
  { label: "older client, 0.0504 (still 0.050 at numeric(6,3))", body: { minimum_change: 0.0504 }, replaces: false, newAlertValue: 0.0504, version: 1 },
  { label: "older client, an explicit 10 cents", body: { minimum_change: 0.1 }, replaces: true, newAlertValue: 0.1, version: 1 },
  { label: "older client, an explicit 20 cents", body: { minimum_change: 0.2 }, replaces: true, newAlertValue: 0.2, version: 1 },
  { label: "older client, a custom 0.137", body: { minimum_change: 0.137 }, replaces: true, newAlertValue: 0.137, version: 1 },
  { label: "older client, the 0.01 lower bound", body: { minimum_change: 0.01 }, replaces: true, newAlertValue: 0.01, version: 1 },
  { label: "older client, the 2.00 upper bound", body: { minimum_change: 2 }, replaces: true, newAlertValue: 2, version: 1 },
  { label: "older client, 0.0506 (rounds to 0.051: not the fixed value)", body: { minimum_change: 0.0506 }, replaces: true, newAlertValue: 0.0506, version: 1 },
  { label: "declared version 1 behaves exactly like no version (5 cents)", body: { alert_contract_version: 1, minimum_change: 0.05 }, replaces: false, newAlertValue: 0.05, version: 1 },
  { label: "declared version 1 behaves exactly like no version (20 cents)", body: { alert_contract_version: 1, minimum_change: 0.2 }, replaces: true, newAlertValue: 0.2, version: 1 },
  { label: "a null version is no version", body: { alert_contract_version: null, minimum_change: 0.05 }, replaces: false, newAlertValue: 0.05, version: 1 },
  // ---- a client that chooses (version 2 and up) ----
  { label: "2.4.1 app, a deliberate 5 cents", body: { alert_contract_version: 2, minimum_change: 0.05 }, replaces: true, newAlertValue: 0.05, version: 2 },
  { label: "2.4.1 app, 10 cents", body: { alert_contract_version: 2, minimum_change: 0.1 }, replaces: true, newAlertValue: 0.1, version: 2 },
  { label: "2.4.1 app, 20 cents", body: { alert_contract_version: 2, minimum_change: 0.2 }, replaces: true, newAlertValue: 0.2, version: 2 },
  { label: "2.4.1 app, custom 0.137", body: { alert_contract_version: 2, minimum_change: 0.137 }, replaces: true, newAlertValue: 0.137, version: 2 },
  { label: "2.4.1 app, custom 0.015", body: { alert_contract_version: 2, minimum_change: 0.015 }, replaces: true, newAlertValue: 0.015, version: 2 },
  { label: "2.4.1 app, bounds 0.01", body: { alert_contract_version: 2, minimum_change: 0.01 }, replaces: true, newAlertValue: 0.01, version: 2 },
  { label: "2.4.1 app, bounds 2.00", body: { alert_contract_version: 2, minimum_change: 2 }, replaces: true, newAlertValue: 2, version: 2 },
  { label: "version 2, minimum_change omitted: the stored value is kept", body: { alert_contract_version: 2 }, replaces: false, newAlertValue: 0.05, version: 2 },
  { label: "version 2, minimum_change null: the stored value is kept", body: { alert_contract_version: 2, minimum_change: null }, replaces: false, newAlertValue: 0.05, version: 2 },
  { label: "a later version behaves as version 2 (5 cents)", body: { alert_contract_version: 3, minimum_change: 0.05 }, replaces: true, newAlertValue: 0.05, version: 3 },
  { label: "the highest accepted version behaves as version 2", body: { alert_contract_version: 1000, minimum_change: 0.05 }, replaces: true, newAlertValue: 0.05, version: 1000 },
];

for (const row of sensitivityTable) {
  test(`sensitivity contract: ${row.label}`, () => {
    const value = ok(base(row.body));
    assert.equal(value.contractVersion, row.version, "declared contract version");
    assert.equal(value.updatesMinimumChange, row.replaces, "replaces an existing alert's drop size");
    assert.equal(value.minimumChange, row.newAlertValue, "what a NEW alert stores");
  });
}

test("the rule is one pure function, and the table above is not just its own mirror", () => {
  // Independent restatement of the contract: only the combination (no version) + (omitted or the fixed 0.05)
  // keeps an existing value, plus (version 2+) + (omitted).
  for (const version of [1, 2, 3, 50, 1000]) {
    for (const named of [false, true]) {
      for (const value of [0.01, 0.049, 0.05, 0.051, 0.1, 0.2, 2]) {
        const expected = !named ? false : version >= 2 ? true : Math.round(value * 1000) !== 50;
        assert.equal(replacesStoredMinimumChange(version, named, value), expected, `v${version} named=${named} ${value}`);
      }
    }
  }
});

test("a 5 cent request is NOT ignored when it comes from a client that declared the contract", () => {
  // The negative control the compatibility fix must never trade away: switching an alert back to 5 cents.
  assert.equal(ok(base({ alert_contract_version: 2, minimum_change: 0.05 })).updatesMinimumChange, true);
  assert.equal(ok(base({ minimum_change: 0.05 })).updatesMinimumChange, false);
});

test("a malformed alert_contract_version is refused with its own stable error, never guessed at", () => {
  const malformed: unknown[] = ["2", "two", "", " 2", 0, -1, -2, 1.5, 2.5, 1001, 100000, true, false, [], [2], {}, { v: 2 }, NaN, Infinity, -Infinity];
  for (const bad of malformed) {
    assert.equal(error(base({ alert_contract_version: bad, minimum_change: 0.2 })), "invalid_alert_contract_version", `alert_contract_version=${String(bad)}`);
  }
});

test("a whole-number version written as 2.0 is accepted (JSON cannot tell it from 2)", () => {
  assert.equal(ok(base({ alert_contract_version: JSON.parse("2.0"), minimum_change: 0.05 })).contractVersion, 2);
});

test("the version never rescues an invalid request, and a bad version is reported before the preference checks", () => {
  assert.equal(error(base({ alert_contract_version: 2, minimum_change: 5 })), "invalid_alert_preferences");
  assert.equal(error(base({ alert_contract_version: 2, minimum_change: "0.10" })), "invalid_alert_preferences");
  assert.equal(error(base({ alert_contract_version: 2, minimum_change: 0.009 })), "invalid_alert_preferences");
  assert.equal(error(base({ alert_contract_version: "2", minimum_change: 5 })), "invalid_alert_contract_version");
  assert.equal(error(base({ alert_contract_version: 2, payment_type: "debit" })), "invalid_payment_type");
  assert.equal(error({ alert_contract_version: 2, station_id: "nope" }), "invalid_alert");
});

test("a request that names a version is otherwise parsed exactly as before", () => {
  const withVersion = ok(base({ alert_contract_version: 2, alert_mode: "at_or_below", threshold_price: 2.89, payment_type: "cash", minimum_change: 0.2, cooldown_minutes: 720 }));
  assert.deepEqual(
    { ...withVersion },
    {
      stationId: STATION, alertMode: "at_or_below", thresholdPrice: 2.89, minimumChange: 0.2, cooldownMinutes: 720,
      paymentType: "cash", contractVersion: 2, updatesMinimumChange: true,
    },
  );
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
    ["alertMode", "contractVersion", "cooldownMinutes", "minimumChange", "paymentType", "stationId", "thresholdPrice", "updatesMinimumChange"]);
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

test("set_alert keeps an existing alert's drop size unless the request means to replace it (the sensitivity contract)", () => {
  const start = indexSource.indexOf("async function setAlert");
  const end = indexSource.indexOf("async function deleteAlert");
  const setAlert = indexSource.slice(start, end);
  // The parsed decision is what drives the SQL...
  assert.match(setAlert, /updatesMinimumChange \} = parsed\.value/);
  // ...as a CASE on the row being updated: replaced only when the request means it, otherwise the stored value stays.
  assert.match(
    setAlert,
    /minimum_change = case when \$\{updatesMinimumChange\}::boolean then excluded\.minimum_change\s+else private\.price_alerts\.minimum_change end/,
  );
  // A new alert still takes the request's value (or the 0.05 default).
  assert.match(setAlert, /\$\{thresholdPrice\}, \$\{minimumChange\}, \$\{cooldownMinutes\}/);
  // The old unconditional overwrite is gone.
  assert.doesNotMatch(setAlert, /minimum_change = excluded\.minimum_change/);
  // The version is a hint for THIS statement only: never persisted, never part of auth or Pro.
  assert.ok(!/alert_contract_version|contractVersion/.test(setAlert), "set_alert must not read or store the raw version");
});

// The SQL and shell tests cannot import index.ts, so they carry a hand-written copy of the set_alert upsert. A copy that
// drifted would leave those tests green while proving nothing about the statement that actually runs - so the three are pinned
// to each other here. Only the way the two inputs are WRITTEN may differ (a template placeholder, a function argument, a shell
// variable); every other character, after whitespace is squashed, must be the same.
test("the upsert the SQL tests exercise is the statement index.ts runs (three copies pinned together)", () => {
  const tests = join(here, "..", "..", "tests");
  const sources: Record<string, string> = {
    "index.ts": indexSource,
    "price_alert_payment_type.test.sql": readFileSync(join(tests, "price_alert_payment_type.test.sql"), "utf8"),
    "price_alert_payment_type_concurrency.test.sh": readFileSync(join(tests, "price_alert_payment_type_concurrency.test.sh"), "utf8"),
  };
  const normalize = (text: string) => text
    .replace(/\s+/g, " ")
    .replace(/\( /g, "(")
    .replace(/ \)/g, ")")
    .replace(/\$\{updatesMinimumChange\}|p_updates_min|\$2(?![0-9])/g, "<replaces>")
    .replace(/(?:\$\{paymentType\}|p_payment|\$pay\b)(?:::text)?/g, "<payment>::text")
    .trim();
  const pieces = (name: string, source: string) => {
    const insert = source.match(/insert into private\.price_alerts \(\s*installation_id, station_id, alert_mode, threshold_price, minimum_change, cooldown_minutes, payment_type, enabled\s*\)/);
    assert.ok(insert, `${name}: the insert column list`);
    const conflict = source.match(/on conflict \(installation_id, station_id\) do update\s+set alert_mode = excluded\.alert_mode,[\s\S]*?enabled = true/);
    assert.ok(conflict, `${name}: the ON CONFLICT ... DO UPDATE SET list`);
    return { insert: normalize(insert[0]), conflict: normalize(conflict[0]) };
  };
  const reference = pieces("index.ts", sources["index.ts"]!);
  assert.match(reference.conflict, /minimum_change = case when <replaces>::boolean then excluded\.minimum_change else private\.price_alerts\.minimum_change end/);
  assert.match(reference.conflict, /payment_type = coalesce\(<payment>::text, private\.price_alerts\.payment_type\)/);
  for (const [name, source] of Object.entries(sources)) {
    const copy = pieces(name, source);
    assert.equal(copy.insert, reference.insert, `${name}: the INSERT column list drifted from index.ts`);
    assert.equal(copy.conflict, reference.conflict, `${name}: the ON CONFLICT list drifted from index.ts`);
  }
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

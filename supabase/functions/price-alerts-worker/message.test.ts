// Run: node --test supabase/functions/price-alerts-worker/*.test.ts   (Node 22+, no Deno required)
//
// Pins the Price Alert notification copy and the worker wiring that carries the payment method.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { formatPrice, messageFor, paymentLabel, payloadPaymentType } from "./message.ts";

const STATION = "Corner Pump";

// ---- the copy the product asked for ---------------------------------------------------------------

test("a credit price drop names the price that was reported", () => {
  assert.deepEqual(
    messageFor({ reason_code: "price_dropped", observed_price: "3.090", station_name: STATION, payment_type: "credit" }),
    { title: "E85 price dropped!", body: "Credit price is now $3.09 at Corner Pump." },
  );
});

test("a reached target names the price that was reported (cash)", () => {
  for (const reason of ["threshold_crossed", "threshold_met", "threshold_price_changed"]) {
    assert.deepEqual(
      messageFor({ reason_code: reason, observed_price: 2.79, station_name: STATION, payment_type: "cash" }),
      { title: "Your E85 target was reached.", body: "Cash price is now $2.79 at Corner Pump." },
      reason,
    );
  }
});

test("a legacy alert (unknown method) keeps plain wording and never claims a method", () => {
  for (const payment of ["unknown", null, undefined, "", "debit", "same_for_both"]) {
    const message = messageFor({ reason_code: "price_dropped", observed_price: 3.09, station_name: STATION, payment_type: payment });
    assert.equal(message.body, "E85 price is now $3.09 at Corner Pump.", `payment_type=${String(payment)}`);
    assert.ok(!/cash|credit/i.test(message.body));
  }
});

test("other reasons keep their titles", () => {
  assert.equal(messageFor({ reason_code: "price_changed", observed_price: 3.1, station_name: STATION }).title, "E85 price changed");
  assert.equal(messageFor({ reason_code: "something_new", observed_price: 3.1, station_name: STATION }).title, "E85 price update");
  assert.equal(messageFor({ reason_code: null, observed_price: 3.1, station_name: STATION }).title, "E85 price update");
});

// ---- honesty and safety ---------------------------------------------------------------------------

test("the copy never says the price is verified, confirmed or official", () => {
  const reasons = ["price_dropped", "threshold_crossed", "threshold_met", "threshold_price_changed", "price_changed", "x", null];
  for (const reason of reasons) {
    for (const payment of ["cash", "credit", "unknown", null]) {
      const { title, body } = messageFor({ reason_code: reason, observed_price: 3.09, station_name: STATION, payment_type: payment });
      assert.ok(!/verif|confirm|official|guarantee|certified/i.test(`${title} ${body}`), `${reason}/${payment}`);
    }
  }
});

test("a missing or unusable price still produces a sentence, never 'NaN' or 'undefined'", () => {
  for (const price of [null, undefined, "", "abc", Number.NaN, 0, -1]) {
    const { body } = messageFor({ reason_code: "price_dropped", observed_price: price, station_name: STATION, payment_type: "credit" });
    assert.equal(body, "Credit price was updated at Corner Pump.", `price=${String(price)}`);
    assert.ok(!/NaN|undefined|null/.test(body));
  }
});

test("a missing or very long station name is handled", () => {
  assert.equal(messageFor({ reason_code: "price_dropped", observed_price: 3.09, station_name: null, payment_type: "cash" }).body,
    "Cash price is now $3.09 at an E85 station.");
  assert.equal(messageFor({ reason_code: "price_dropped", observed_price: 3.09, station_name: "   ", payment_type: "cash" }).body,
    "Cash price is now $3.09 at an E85 station.");
  const long = "X".repeat(200);
  const body = messageFor({ reason_code: "price_dropped", observed_price: 3.09, station_name: long, payment_type: "cash" }).body;
  assert.ok(body.length < 140, `body stays short: ${body.length}`);
  assert.ok(body.includes("…"));
});

test("prices are formatted to two decimals from numeric strings and numbers alike", () => {
  assert.equal(formatPrice("3.090"), "$3.09");
  assert.equal(formatPrice(3.1), "$3.10");
  assert.equal(formatPrice("2.8"), "$2.80");
  assert.equal(formatPrice(null), null);
  assert.equal(formatPrice("x"), null);
});

test("only Cash and Credit produce a label or a payload value", () => {
  assert.equal(paymentLabel("cash"), "Cash");
  assert.equal(paymentLabel("credit"), "Credit");
  for (const other of ["unknown", "same_for_both", "Cash", "", null, undefined]) {
    assert.equal(paymentLabel(other), null, String(other));
    assert.equal(payloadPaymentType(other), undefined, String(other));
  }
  assert.equal(payloadPaymentType("cash"), "cash");
  assert.equal(payloadPaymentType("credit"), "credit");
});

// ---- worker wiring (index.ts only runs on Deno, so it is pinned as text) ------------------------------

const here = dirname(fileURLToPath(import.meta.url));
const workerSource = readFileSync(join(here, "index.ts"), "utf8");

test("the worker uses message.ts and keeps no second copy of the copy", () => {
  assert.match(workerSource, /import \{ messageFor, payloadPaymentType \} from "\.\/message\.ts";/);
  assert.doesNotMatch(workerSource, /function messageFor/);
  assert.doesNotMatch(workerSource, /E85 price dropped/);
});

test("the station deep-link payload is untouched and payment_type is purely additive", () => {
  // APNs custom payload keys: type, station_id, observed_price (unchanged) + optional payment_type
  assert.match(workerSource, /type: "price_alert",\s+station_id: delivery\.station_id,\s+observed_price: Number\(delivery\.observed_price\),/);
  assert.match(workerSource, /\.\.\.\(paymentType \? \{ payment_type: paymentType \} : \{\}\)/);
  // FCM data keys: the same three plus the optional one
  assert.match(workerSource, /type: "price_alert",\s+station_id: delivery\.station_id,\s+observed_price: String\(Number\(delivery\.observed_price\)\),/);
  assert.match(workerSource, /payment_type: payloadPaymentType\(delivery\.payment_type\) as string/);
  // The APNs collapse id still groups by station
  assert.match(workerSource, /"apns-collapse-id": `station-\$\{delivery\.station_id\}`/);
});

test("the claim function is still the one the database suite pins; the method is a separate lookup that fails soft", () => {
  assert.match(workerSource, /select \* from private\.claim_price_alert_deliveries_v2\(\$\{limit\}, \$\{platform\}\)/);
  assert.match(workerSource, /select id, payment_type from private\.price_alert_deliveries where id = any\(\$\{deliveryIds\}::uuid\[\]\)/);
  const lookup = workerSource.slice(workerSource.indexOf("async function paymentTypesFor"), workerSource.indexOf("async function sendDeliveries"));
  assert.match(lookup, /catch \{/, "a database without the column must not break sending");
});

test("sending is unchanged: no new provider call, no Pro re-check, no scheduler change", () => {
  assert.equal((workerSource.match(/api\.push\.apple\.com|api\.sandbox\.push\.apple\.com/g) ?? []).length, 2);
  assert.equal((workerSource.match(/fcm\.googleapis\.com/g) ?? []).length, 1);
  assert.ok(!/revenuecat|pro_is_active/i.test(workerSource));
  assert.ok(!/cron\.schedule|cron\.alter_job/.test(workerSource));
});

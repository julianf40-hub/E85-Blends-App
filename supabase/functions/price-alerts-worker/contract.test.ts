// 85Blends 2.4.1 — Cross-file naming contract for the Price Alerts worker scheduler.
// Run under Node: node --test supabase/functions/price-alerts-worker/contract.test.ts
//
// The scheduler secret travels through four places that are written in three languages and can only
// be checked against each other by reading the files: the SQL invoker (Vault secret name + HTTP
// header + URL path), the worker's auth module (header name + minimum length), the worker entrypoint
// (Edge env secret name) and the runbook. A rename in one place that is not mirrored elsewhere would
// silently break the scheduler (every call a 401) while cron keeps reporting success, so this test
// pins them together.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CRON_SECRET_HEADER, MIN_CRON_SECRET_LENGTH } from "./auth.ts";

const here = new URL(".", import.meta.url);
const read = (relative: string) => readFileSync(new URL(relative, here), "utf8");

const migration = read("../../migrations/20261005120000_price_alert_worker_scheduler_and_freshness.sql");
const indexTs = read("./index.ts");
const runbook = read("../PRICE_ALERTS_SCHEDULER.md");
const config = read("../../config.toml");

const VAULT_TOKEN_NAME = "price_alerts_worker_cron_token";
const VAULT_URL_NAME = "project_url";
const EDGE_SECRET_NAME = "PRICE_ALERTS_WORKER_CRON_SECRET";
const WORKER_PATH = "/functions/v1/price-alerts-worker";

test("the HTTP header name is identical in the SQL invoker, the auth module and the runbook", () => {
  assert.equal(CRON_SECRET_HEADER, "x-85blends-cron-secret");
  assert.ok(migration.includes(`'${CRON_SECRET_HEADER}'`), "the invoker must send exactly the header the worker reads");
  assert.ok(runbook.includes(CRON_SECRET_HEADER), "the runbook must name the header");
});

test("the Vault secret names read by the invoker are the ones the runbook tells operators to create", () => {
  assert.ok(migration.includes(`name = '${VAULT_TOKEN_NAME}'`), "invoker reads the token secret by name");
  assert.ok(migration.includes(`name = '${VAULT_URL_NAME}'`), "invoker reads the project URL secret by name");
  assert.ok(runbook.includes(VAULT_TOKEN_NAME), "runbook names the token secret");
  assert.ok(runbook.includes(VAULT_URL_NAME), "runbook names the URL secret");
});

test("the Edge secret name is identical in the worker entrypoint, the migration commentary and the runbook", () => {
  assert.ok(indexTs.includes(`Deno.env.get("${EDGE_SECRET_NAME}")`), "worker reads the Edge secret");
  assert.ok(migration.includes(EDGE_SECRET_NAME), "migration comments name the Edge secret");
  assert.ok(runbook.includes(EDGE_SECRET_NAME), "runbook names the Edge secret");
});

test("the invoker targets the worker's own function path and the worker allows only POST", () => {
  assert.ok(migration.includes(WORKER_PATH), "invoker URL path");
  assert.ok(runbook.includes(WORKER_PATH) || runbook.includes("price-alerts-worker"), "runbook names the function");
  assert.ok(/req\.method !== "POST"/.test(indexTs), "worker rejects non-POST");
});

test("the minimum scheduler-secret length agrees between the SQL invoker and the auth module", () => {
  assert.equal(MIN_CRON_SECRET_LENGTH, 32);
  assert.ok(migration.includes("{32,}"), "SQL token floor is 32 characters");
});

test("the worker authenticates before any other work: the auth call precedes env/DB/body handling", () => {
  const authCall = indexTs.indexOf("isAuthorizedWorkerCall(req.headers");
  assert.ok(authCall > 0, "auth call present");
  for (const later of ['Deno.env.get("SUPABASE_DB_URL")', "await req.json()", "postgres(dbUrl", "prepareJobs(", "sendDeliveries("]) {
    const at = indexTs.indexOf(later, indexTs.indexOf("Deno.serve"));
    assert.ok(at > authCall, `${later} must come after the auth check`);
  }
  assert.ok(/return response\(401, \{ error: "unauthorized" \}\)/.test(indexTs), "auth failure returns a generic 401");
});

test("verify_jwt is off for the worker (and only the worker line changed meaning), documented in the runbook", () => {
  assert.ok(/\[functions\.price-alerts-worker\]\s*\nverify_jwt = false/.test(config), "config.toml turns the JWT gate off for the worker");
  assert.ok(/verify_jwt/i.test(runbook), "runbook explains verify_jwt");
});

test("no secret value, key or token literal is committed in the scheduler files", () => {
  for (const [name, text] of [["migration", migration], ["worker", indexTs], ["runbook", runbook]] as const) {
    assert.ok(!/eyJ[A-Za-z0-9_-]{20,}/.test(text), `${name}: no JWT-looking literal`);
    assert.ok(!/sb_secret_[A-Za-z0-9_-]{10,}/.test(text), `${name}: no secret-key literal`);
    assert.ok(!/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(text), `${name}: no private key`);
  }
  // the cron command text must be the bare invoker call: no URL, no token, no header
  const cronCommands = [...migration.matchAll(/\$cron\$([\s\S]*?)\$cron\$/g)].map((m) => m[1].trim());
  assert.deepEqual(cronCommands, ["select private.invoke_price_alerts_worker();"]);
});

test("the invoker never places the secret in the URL and never reads the service-role key", () => {
  const invoker = migration.slice(migration.indexOf("create or replace function private.invoke_price_alerts_worker"),
                                  migration.indexOf("revoke execute on function private.invoke_price_alerts_worker"));
  assert.ok(!/service_role/i.test(invoker), "invoker does not touch the service-role key");
  assert.ok(!/v_cron_token\s*\|\|\s*'/.test(invoker) && !/\|\|\s*v_cron_token/.test(invoker), "token is never concatenated into a string (URL)");
  assert.ok(!/raise exception[^;]*(v_cron_token|v_project_url)/.test(invoker), "errors never interpolate configured values");
});

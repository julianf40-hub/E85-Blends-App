// 85Blends 2.3.0 — Phase B1. Tests for revenuecat-api.ts, using an injected stub `fetch`.
// Run under Node — see hmac.test.ts's header comment. Uses the standard global `Response`
// (available in both Deno and Node), never a real network call.

import { test } from "node:test";
import assert from "node:assert/strict";
import { fetchCustomerSubscriptions } from "./revenuecat-api.ts";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

test("fetchCustomerSubscriptions: single page success", async () => {
  const calls: string[] = [];
  const fetchImpl = (async (url: string) => {
    calls.push(url);
    return jsonResponse(200, { items: [{ gives_access: true }], next_page: null });
  }) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );

  assert.equal(result.kind, "ok");
  if (result.kind === "ok") {
    assert.equal(result.subscriptions.length, 1);
  }
  assert.equal(calls.length, 1);
  assert.match(calls[0], /^https:\/\/api\.revenuecat\.com\/v2\/projects\/proj_1\/customers\/user_a\/subscriptions\?/);
  assert.match(calls[0], /environment=production/);
  assert.match(calls[0], /limit=100/);
});

test("fetchCustomerSubscriptions: URL-encodes the app_user_id path segment", async () => {
  const calls: string[] = [];
  const fetchImpl = (async (url: string) => {
    calls.push(url);
    return jsonResponse(200, { items: [], next_page: null });
  }) as typeof fetch;

  await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user/with slashes+special",
    "sandbox",
  );
  assert.ok(!calls[0].includes("user/with slashes+special"));
  assert.ok(calls[0].includes(encodeURIComponent("user/with slashes+special")));
});

test("fetchCustomerSubscriptions: follows next_page across multiple pages", async () => {
  let call = 0;
  const fetchImpl = (async () => {
    call += 1;
    if (call === 1) {
      return jsonResponse(200, {
        items: [{ gives_access: true }],
        next_page: "/v2/projects/proj_1/customers/user_a/subscriptions?environment=production&limit=100&starting_after=abc",
      });
    }
    return jsonResponse(200, { items: [{ gives_access: false }], next_page: null });
  }) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "ok");
  if (result.kind === "ok") {
    assert.equal(result.subscriptions.length, 2);
  }
  assert.equal(call, 2);
});

test("fetchCustomerSubscriptions: refuses to follow a next_page pointing outside api.revenuecat.com", async () => {
  const fetchImpl = (async () =>
    jsonResponse(200, { items: [], next_page: "https://evil.example.com/steal-data" })) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "retryable_error");
  if (result.kind === "retryable_error") {
    assert.equal(result.statusCategory, "invalid_next_page");
  }
});

test("fetchCustomerSubscriptions: refuses to follow a next_page outside the /v2 path", async () => {
  const fetchImpl = (async () =>
    jsonResponse(200, { items: [], next_page: "https://api.revenuecat.com/v1/something" })) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "retryable_error");
  if (result.kind === "retryable_error") {
    assert.equal(result.statusCategory, "invalid_next_page");
  }
});

test("fetchCustomerSubscriptions: stops with retryable_error if next_page never terminates within the page cap", async () => {
  let call = 0;
  const fetchImpl = (async () => {
    call += 1;
    return jsonResponse(200, {
      items: [],
      next_page: `/v2/projects/proj_1/customers/user_a/subscriptions?page=${call}`,
    });
  }) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "retryable_error");
  if (result.kind === "retryable_error") {
    assert.equal(result.statusCategory, "max_pages_exceeded");
  }
  assert.equal(call, 10); // MAX_PAGES
});

test("fetchCustomerSubscriptions: 404 -> not_found (not a retryable failure)", async () => {
  const fetchImpl = (async () => new Response(null, { status: 404 })) as typeof fetch;
  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.deepEqual(result, { kind: "not_found" });
});

test("fetchCustomerSubscriptions: 401 -> config_error", async () => {
  const fetchImpl = (async () => new Response(null, { status: 401 })) as typeof fetch;
  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "config_error");
});

test("fetchCustomerSubscriptions: 403 -> config_error", async () => {
  const fetchImpl = (async () => new Response(null, { status: 403 })) as typeof fetch;
  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "config_error");
});

test("fetchCustomerSubscriptions: 429 -> retryable_error", async () => {
  const fetchImpl = (async () => new Response(null, { status: 429 })) as typeof fetch;
  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "retryable_error");
});

test("fetchCustomerSubscriptions: 423 -> retryable_error", async () => {
  const fetchImpl = (async () => new Response(null, { status: 423 })) as typeof fetch;
  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "retryable_error");
});

test("fetchCustomerSubscriptions: 500 -> retryable_error", async () => {
  const fetchImpl = (async () => new Response(null, { status: 500 })) as typeof fetch;
  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "retryable_error");
});

test("fetchCustomerSubscriptions: network error (fetch throws) -> retryable_error", async () => {
  const fetchImpl = (async () => {
    throw new Error("network down");
  }) as typeof fetch;
  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "retryable_error");
  if (result.kind === "retryable_error") {
    assert.equal(result.statusCategory, "network_error");
  }
});

test("fetchCustomerSubscriptions: malformed JSON body -> retryable_error", async () => {
  const fetchImpl = (async () => new Response("not json", { status: 200 })) as typeof fetch;
  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "retryable_error");
});

test("fetchCustomerSubscriptions: sends Authorization: Bearer <key>", async () => {
  let seenAuth: string | null = null;
  const fetchImpl = (async (_url: string, init?: RequestInit) => {
    seenAuth = (init?.headers as Record<string, string>)?.Authorization ?? null;
    return jsonResponse(200, { items: [], next_page: null });
  }) as typeof fetch;

  await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_the_real_key", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(seenAuth, "Bearer sk_the_real_key");
});

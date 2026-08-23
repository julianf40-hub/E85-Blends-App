// 85Blends 2.3.0 — Phase B1. Tests for revenuecat-api.ts, using an injected stub `fetch`.
// Run under Node — see hmac.test.ts's header comment. Uses the standard global `Response`
// (available in both Deno and Node), never a real network call.
//
// Phase B1 review Finding 1 (pagination environment safety) and Finding 2 (404 must not downgrade
// Pro) each have a required test list in the review-repair report; every test below is labeled
// with which requirement it covers.

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
    return jsonResponse(200, { items: [{ gives_access: true, environment: "production" }], next_page: null });
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

test("fetchCustomerSubscriptions: 200 with an empty items array is a valid empty/Free result", async () => {
  // Finding 2's required test list: "200+items=[] is valid empty/Free state" — must be
  // indistinguishable from any other successful `ok` result with zero subscriptions, never an
  // error path.
  const fetchImpl = (async () => jsonResponse(200, { items: [], next_page: null })) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.deepEqual(result, { kind: "ok", subscriptions: [] });
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
        items: [{ gives_access: true, environment: "production" }],
        next_page: "/v2/projects/proj_1/customers/user_a/subscriptions?environment=production&limit=100&starting_after=abc",
      });
    }
    return jsonResponse(200, { items: [{ gives_access: false, environment: "production" }], next_page: null });
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

test("fetchCustomerSubscriptions: sandbox pagination re-forces environment=sandbox&limit=100 on page 2+ regardless of what the cursor carried", async () => {
  // Finding 1 required test: "sandbox/production pagination preserves environment on page 2+".
  // The mocked next_page cursor deliberately carries the WRONG environment and a different limit
  // to prove the client overwrites them rather than trusting the cursor.
  const calls: string[] = [];
  let call = 0;
  const fetchImpl = (async (url: string) => {
    calls.push(url);
    call += 1;
    if (call === 1) {
      return jsonResponse(200, {
        items: [{ gives_access: true, environment: "sandbox" }],
        next_page: "/v2/projects/proj_1/customers/user_a/subscriptions?environment=production&limit=5&starting_after=abc",
      });
    }
    return jsonResponse(200, { items: [{ gives_access: false, environment: "sandbox" }], next_page: null });
  }) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "sandbox",
  );
  assert.equal(result.kind, "ok");
  assert.equal(calls.length, 2);
  assert.match(calls[1], /environment=sandbox/);
  assert.doesNotMatch(calls[1], /environment=production/);
  assert.match(calls[1], /limit=100/);
});

test("fetchCustomerSubscriptions: production pagination re-forces environment=production&limit=100 on page 2+ regardless of what the cursor carried", async () => {
  const calls: string[] = [];
  let call = 0;
  const fetchImpl = (async (url: string) => {
    calls.push(url);
    call += 1;
    if (call === 1) {
      return jsonResponse(200, {
        items: [{ gives_access: true, environment: "production" }],
        next_page: "/v2/projects/proj_1/customers/user_a/subscriptions?environment=sandbox&limit=3&starting_after=abc",
      });
    }
    return jsonResponse(200, { items: [{ gives_access: false, environment: "production" }], next_page: null });
  }) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "ok");
  assert.equal(calls.length, 2);
  assert.match(calls[1], /environment=production/);
  assert.doesNotMatch(calls[1], /environment=sandbox/);
  assert.match(calls[1], /limit=100/);
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

test("fetchCustomerSubscriptions: refuses a next_page pointing at a DIFFERENT customer's path", async () => {
  // Finding 1 required test: "next_page pointing at a different customer path rejected". Same
  // project, same resource, but a different customer segment — must be rejected on exact-pathname
  // grounds, not merely "some /v2/... path".
  const fetchImpl = (async () =>
    jsonResponse(200, {
      items: [],
      next_page: "https://api.revenuecat.com/v2/projects/proj_1/customers/user_B_NOT_REQUESTED/subscriptions?environment=production&limit=100",
    })) as typeof fetch;

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

test("fetchCustomerSubscriptions: refuses a next_page pointing at a DIFFERENT resource endpoint for the same customer", async () => {
  // Finding 1 required test: "next_page pointing at a different resource endpoint rejected". Same
  // project, same customer, but a different trailing resource than "subscriptions".
  const fetchImpl = (async () =>
    jsonResponse(200, {
      items: [],
      next_page: "https://api.revenuecat.com/v2/projects/proj_1/customers/user_a/purchases?environment=production&limit=100",
    })) as typeof fetch;

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

test("fetchCustomerSubscriptions: rejects a PRODUCTION-tagged item on a SANDBOX request", async () => {
  // Finding 1 required test: "sandbox request receiving a production item rejected".
  const fetchImpl = (async () =>
    jsonResponse(200, { items: [{ gives_access: true, environment: "PRODUCTION" }], next_page: null })) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "sandbox",
  );
  assert.equal(result.kind, "retryable_error");
  if (result.kind === "retryable_error") {
    assert.equal(result.statusCategory, "unexpected_environment");
  }
});

test("fetchCustomerSubscriptions: rejects a SANDBOX-tagged item on a PRODUCTION request", async () => {
  // Finding 1 required test: "production request receiving a sandbox item rejected".
  const fetchImpl = (async () =>
    jsonResponse(200, { items: [{ gives_access: true, environment: "SANDBOX" }], next_page: null })) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "retryable_error");
  if (result.kind === "retryable_error") {
    assert.equal(result.statusCategory, "unexpected_environment");
  }
});

test("fetchCustomerSubscriptions: rejects an item with a missing environment field", async () => {
  // Finding 1 required test: "missing/invalid subscription.environment rejected".
  const fetchImpl = (async () =>
    jsonResponse(200, { items: [{ gives_access: true }], next_page: null })) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "retryable_error");
  if (result.kind === "retryable_error") {
    assert.equal(result.statusCategory, "unexpected_environment");
  }
});

test("fetchCustomerSubscriptions: rejects an item with an invalid (unparseable) environment field", async () => {
  const fetchImpl = (async () =>
    jsonResponse(200, { items: [{ gives_access: true, environment: "not_a_real_environment" }], next_page: null })) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "retryable_error");
  if (result.kind === "retryable_error") {
    assert.equal(result.statusCategory, "unexpected_environment");
  }
});

test("fetchCustomerSubscriptions: one bad item on page 2 fails the whole call, even if page 1 was clean", async () => {
  // The requested environment must hold for EVERY page, not just the first — a later page cannot
  // slip a wrong-environment item past validation just because page 1 looked fine.
  let call = 0;
  const fetchImpl = (async () => {
    call += 1;
    if (call === 1) {
      return jsonResponse(200, {
        items: [{ gives_access: true, environment: "production" }],
        next_page: "/v2/projects/proj_1/customers/user_a/subscriptions?environment=production&limit=100",
      });
    }
    return jsonResponse(200, { items: [{ gives_access: true, environment: "SANDBOX" }], next_page: null });
  }) as typeof fetch;

  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.equal(result.kind, "retryable_error");
  if (result.kind === "retryable_error") {
    assert.equal(result.statusCategory, "unexpected_environment");
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

test("fetchCustomerSubscriptions: 404 -> retryable_error (404_customer_not_found), never treated as empty/no entitlement", async () => {
  // Finding 2: a 404 means RevenueCat couldn't resolve the customer resource — NOT strong enough
  // evidence to revoke an existing Pro entitlement. Must be a retryable error, never the removed
  // "not_found" kind, and the result must carry no `subscriptions` for a caller to accidentally
  // compute entitlement from.
  const fetchImpl = (async () => new Response(null, { status: 404 })) as typeof fetch;
  const result = await fetchCustomerSubscriptions(
    { projectId: "proj_1", secretApiKey: "sk_test", fetchImpl },
    "user_a",
    "production",
  );
  assert.deepEqual(result, {
    kind: "retryable_error",
    statusCategory: "404_customer_not_found",
    detail: "RevenueCat API could not resolve this customer",
  });
  assert.ok(!("subscriptions" in result));
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

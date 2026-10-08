// LOCAL TEST SUPPORT ONLY - never deployed, never imported by a function.
//
// Runs the REAL supabase/functions/price-alerts-worker/index.ts with fetch() replaced by a recorder, so a push is
// never sent to Apple or Google. Every request the worker makes to a push provider is appended as one JSON line to the
// file named by RECORD_FILE and answered with a canned success; the Google OAuth token exchange gets a canned token;
// ANY other URL throws, so the worker cannot reach the network from this wrapper.
//
// Used by supabase/tests/price_alert_worker_message.test.sh, which supplies a throwaway signing key, a synthetic
// service-role key and a scratch database. Nothing here reads or needs a production secret.

const recordFile = Deno.env.get("RECORD_FILE");
if (!recordFile) throw new Error("RECORD_FILE is required");

const APNS_PREFIXES = ["https://api.sandbox.push.apple.com/", "https://api.push.apple.com/"];
const FCM_PREFIX = "https://fcm.googleapis.com/v1/projects/";
const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";

function record(entry: Record<string, unknown>): void {
  Deno.writeTextFileSync(recordFile!, JSON.stringify(entry) + "\n", { append: true });
}

function plainHeaders(init?: RequestInit): Record<string, string> {
  const out: Record<string, string> = {};
  new Headers(init?.headers).forEach((value, key) => {
    // The bearer value is a JWT signed with the test's throwaway key; keep it out of the record anyway.
    out[key] = key === "authorization" ? "<redacted>" : value;
  });
  return out;
}

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  const body = typeof init?.body === "string" ? init.body : null;

  if (APNS_PREFIXES.some((prefix) => url.startsWith(prefix))) {
    record({ provider: "apns", url, headers: plainHeaders(init), body });
    return new Response("", { status: 200 });
  }
  if (url === GOOGLE_TOKEN_URL) {
    return new Response(JSON.stringify({ access_token: "local-test-access-token", expires_in: 3600 }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }
  if (url.startsWith(FCM_PREFIX)) {
    record({ provider: "fcm", url, headers: plainHeaders(init), body });
    return new Response(JSON.stringify({ name: "projects/local-test/messages/1" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }
  throw new Error(`blocked outbound request in a local test: ${url}`);
}) as typeof fetch;

await import("../../functions/price-alerts-worker/index.ts");

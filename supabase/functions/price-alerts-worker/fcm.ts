// 85Blends 2.4.1 — Firebase Cloud Messaging (HTTP v1) response classification for price-alerts-worker.
//
// Pure (no Deno APIs, no I/O) so it is unit-testable under Node — see fcm.test.ts.
//
// The one decision that matters: `invalidate` makes the worker call
// private.mark_price_alert_delivery_failed(..., p_invalidate_device => true), which PERMANENTLY
// disables the user's push-device row. That must only happen when FCM states, explicitly, that the
// registration token itself is no longer valid (UNREGISTERED). A generic HTTP 404, a sender/project
// mismatch, an authentication or permission failure, or any provider error says something about
// OUR server or Firebase configuration, not about the user's device, and must never cost a valid
// user their Android token.
//
// Outcomes (`kind`):
//   sent           HTTP 2xx.
//   invalid_token  FCM explicitly reports UNREGISTERED. invalidate = true, retryable = false.
//   transient      429 / 5xx / QUOTA_EXCEEDED / RESOURCE_EXHAUSTED / UNAVAILABLE / INTERNAL /
//                  UNSPECIFIED_ERROR / DEADLINE_EXCEEDED. retryable = true, device untouched.
//   configuration  SENDER_ID_MISMATCH, THIRD_PARTY_AUTH_ERROR, UNAUTHENTICATED, PERMISSION_DENIED,
//                  and any 401 / 403 / 404 that does not carry UNREGISTERED. retryable = true (fixing
//                  the server configuration inside the retry window recovers the delivery; the
//                  attempt cap and the 2-hour freshness window bound it), device untouched.
//   rejected       anything else, e.g. INVALID_ARGUMENT. retryable = false, device untouched (the
//                  delivery ends `dead`; the device row is not disabled).
//
// Nothing here logs or returns a token, an access token or a service-account value.

export type FcmFailureKind = "sent" | "invalid_token" | "transient" | "configuration" | "rejected";

export interface FcmClassification {
  kind: FcmFailureKind;
  ok: boolean;
  status: number;
  /** FCM error code (or `http_<status>`), at most 128 characters; stored as last_error_code. */
  reason: string;
  retryable: boolean;
  invalidate: boolean;
}

const TRANSIENT_CODES = new Set([
  "QUOTA_EXCEEDED",
  "RESOURCE_EXHAUSTED",
  "UNAVAILABLE",
  "INTERNAL",
  "UNSPECIFIED_ERROR",
  "DEADLINE_EXCEEDED",
]);

const CONFIGURATION_CODES = new Set([
  "SENDER_ID_MISMATCH",
  "THIRD_PARTY_AUTH_ERROR",
  "UNAUTHENTICATED",
  "PERMISSION_DENIED",
]);

/** The FCM error code of a parsed error body: the FCM-specific `details[].errorCode` if present,
 *  otherwise the google.rpc status string. Null when the body carries neither. */
export function fcmErrorCode(body: unknown): string | null {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return null;
  const error = (body as Record<string, unknown>).error;
  if (typeof error !== "object" || error === null || Array.isArray(error)) return null;
  const record = error as Record<string, unknown>;
  if (Array.isArray(record.details)) {
    for (const detail of record.details) {
      if (typeof detail !== "object" || detail === null || Array.isArray(detail)) continue;
      const d = detail as Record<string, unknown>;
      if (typeof d.errorCode === "string" && d.errorCode.length > 0) return d.errorCode.slice(0, 128);
    }
  }
  if (typeof record.status === "string" && record.status.length > 0) return record.status.slice(0, 128);
  return null;
}

export function classifyFcmResponse(status: number, body: unknown): FcmClassification {
  if (status >= 200 && status < 300) {
    return { kind: "sent", ok: true, status, reason: "sent", retryable: false, invalidate: false };
  }

  const code = fcmErrorCode(body) ?? `http_${status}`;
  const failure = (kind: FcmFailureKind, retryable: boolean, invalidate: boolean): FcmClassification => ({
    kind,
    ok: false,
    status,
    reason: code,
    retryable,
    invalidate,
  });

  // The only evidence that a token is bad: FCM says so explicitly.
  if (code === "UNREGISTERED") return failure("invalid_token", false, true);

  if (status === 429 || status >= 500 || TRANSIENT_CODES.has(code)) return failure("transient", true, false);

  if (CONFIGURATION_CODES.has(code) || status === 401 || status === 403 || status === 404) {
    return failure("configuration", true, false);
  }

  return failure("rejected", false, false);
}

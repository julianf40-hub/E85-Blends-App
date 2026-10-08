// Pure validation of a `set_alert` request body. No Deno APIs and no database access, so the rules
// can be tested under Node (see alert-input.test.ts) even though the Edge Function itself only runs
// on Deno. index.ts calls this and nothing else decides what an alert may look like.

import { asFiniteNumber, asInteger, asTrimmedString, asUuid } from "./values.ts";

export const ALLOWED_ALERT_MODES = new Set(["any_change", "price_drop", "at_or_below"]);

/**
 * The payment methods a person can choose for an alert. `unknown` is deliberately NOT here: it is the
 * stored marker of a legacy alert that predates payment types, never something a client may choose, and
 * `same_for_both` is a property of a REPORT (it qualifies for either choice), not of an alert.
 */
export const ALLOWED_ALERT_PAYMENT_TYPES = new Set(["cash", "credit"]);

/** Backend bounds, unchanged: they match the table CHECK constraints. */
export const THRESHOLD_RANGE = { min: 1, max: 8 } as const;
export const MINIMUM_CHANGE_RANGE = { min: 0.01, max: 2 } as const;
export const COOLDOWN_MINUTES_RANGE = { min: 60, max: 10080 } as const;

/** Defaults for a request that omits the field. These are the LEGACY server defaults; the 10-cent default
 *  of the newer app is sent explicitly by that app, so older clients behave exactly as they always did. */
export const LEGACY_DEFAULT_MINIMUM_CHANGE = 0.05;
export const DEFAULT_COOLDOWN_MINUTES = 360;

export type AlertInput = {
  stationId: string;
  alertMode: string;
  thresholdPrice: number | null;
  minimumChange: number;
  cooldownMinutes: number;
  /** `null` = the request did not say: keep the alert's current method, or `unknown` for a new alert. */
  paymentType: "cash" | "credit" | null;
};

export type AlertInputResult =
  | { ok: true; value: AlertInput }
  | { ok: false; status: 400; error: string };

type JsonObject = Record<string, unknown>;

function bad(error: string): AlertInputResult {
  return { ok: false, status: 400, error };
}

export function parseAlertInput(body: JsonObject): AlertInputResult {
  const stationId = asUuid(body.station_id);
  const alertMode = asTrimmedString(body.alert_mode, 32) ?? "price_drop";
  if (!stationId || !ALLOWED_ALERT_MODES.has(alertMode)) return bad("invalid_alert");

  // Strict spelling: "Cash", "unknown", "same_for_both", "" and non-strings are all refused. Only an
  // absent or null field means "not specified".
  let paymentType: "cash" | "credit" | null = null;
  if (body.payment_type !== undefined && body.payment_type !== null) {
    const raw = typeof body.payment_type === "string" ? body.payment_type : null;
    if (raw === null || !ALLOWED_ALERT_PAYMENT_TYPES.has(raw)) return bad("invalid_payment_type");
    paymentType = raw as "cash" | "credit";
  }

  const threshold = body.threshold_price == null ? null : asFiniteNumber(body.threshold_price);
  if (alertMode === "at_or_below") {
    if (threshold == null || threshold < THRESHOLD_RANGE.min || threshold > THRESHOLD_RANGE.max) {
      return bad("invalid_threshold_price");
    }
  } else if (body.threshold_price != null) {
    return bad("threshold_only_valid_for_at_or_below");
  }

  const minimumChange = body.minimum_change == null ? LEGACY_DEFAULT_MINIMUM_CHANGE : asFiniteNumber(body.minimum_change);
  const cooldownMinutes = body.cooldown_minutes == null ? DEFAULT_COOLDOWN_MINUTES : asInteger(body.cooldown_minutes);
  if (
    minimumChange == null || minimumChange < MINIMUM_CHANGE_RANGE.min || minimumChange > MINIMUM_CHANGE_RANGE.max ||
    cooldownMinutes == null || cooldownMinutes < COOLDOWN_MINUTES_RANGE.min || cooldownMinutes > COOLDOWN_MINUTES_RANGE.max
  ) {
    return bad("invalid_alert_preferences");
  }

  return {
    ok: true,
    value: { stationId, alertMode, thresholdPrice: threshold, minimumChange, cooldownMinutes, paymentType },
  };
}

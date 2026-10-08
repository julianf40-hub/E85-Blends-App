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
 *  of the newer app is sent explicitly by that app, so a NEW alert from an older client is stored exactly as it always was. */
export const LEGACY_DEFAULT_MINIMUM_CHANGE = 0.05;
export const DEFAULT_COOLDOWN_MINUTES = 360;

/**
 * THE SENSITIVITY CONTRACT. Before the 2.4.1 payment-aware alerts, no client could choose how big a price drop an
 * alert waits for: every one of them sent the fixed 0.05 (or nothing), so the value carried no intent. Since then a
 * person can choose 5, 10 or 20 cents or a custom amount, and a stored value other than 0.05 is a deliberate choice
 * that a later request from an OLDER app must not undo just because that app re-saves the alert.
 *
 * A client that does choose declares it with `alert_contract_version` (an integer, 2 or higher). The rule, applied to
 * an alert that already exists (a NEW alert always takes the request's value, or the 0.05 default when it names none):
 *   - version 2+ : `minimum_change` is authoritative - a value in the request is stored (a deliberate 5 cents too),
 *                  and a request that omits it leaves the stored value alone.
 *   - no version : the request is from a pre-contract client. An omitted `minimum_change`, or the fixed legacy 0.05,
 *                  says nothing about intent, so the stored value is KEPT; any other value cannot be that fixed
 *                  default, so it is taken as meant.
 * The version is a capability hint, not a credential: claiming it can only make a client's OWN alert follow that
 * client's own `minimum_change`. It authorizes nothing - the Pro gate and the installation secret are unchanged.
 */
export const SENSITIVITY_CONTRACT_VERSION = 2;
/** What a request that names no version is taken to be. */
export const LEGACY_CONTRACT_VERSION = 1;
export const ALERT_CONTRACT_VERSION_RANGE = { min: 1, max: 1000 } as const;

/** `minimum_change` is stored as numeric(6,3): compare at that precision, so float noise in a legacy 5 cents
 *  (0.04999999999999999) is still a legacy 5 cents. */
const LEGACY_DEFAULT_THOUSANDTHS = Math.round(LEGACY_DEFAULT_MINIMUM_CHANGE * 1000);

export type AlertInput = {
  stationId: string;
  alertMode: string;
  thresholdPrice: number | null;
  /** What a NEW alert stores: the request's value, or the legacy 0.05 default when it names none. */
  minimumChange: number;
  cooldownMinutes: number;
  /** `null` = the request did not say: keep the alert's current method, or `unknown` for a new alert. */
  paymentType: "cash" | "credit" | null;
  /** The contract the client declared (`LEGACY_CONTRACT_VERSION` when it named none). */
  contractVersion: number;
  /** Whether this request REPLACES an existing alert's `minimum_change` (see the contract above). */
  updatesMinimumChange: boolean;
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

  // Absent or null = a pre-contract client. Anything present must be a whole number in range: a malformed hint is
  // refused outright (nothing is stored) rather than guessed at - guessing "legacy" would silently drop a deliberate
  // choice, guessing "current" would let a bad value overwrite one.
  let contractVersion = LEGACY_CONTRACT_VERSION;
  if (body.alert_contract_version !== undefined && body.alert_contract_version !== null) {
    const raw = asInteger(body.alert_contract_version);
    if (raw === null || raw < ALERT_CONTRACT_VERSION_RANGE.min || raw > ALERT_CONTRACT_VERSION_RANGE.max) {
      return bad("invalid_alert_contract_version");
    }
    contractVersion = raw;
  }

  const threshold = body.threshold_price == null ? null : asFiniteNumber(body.threshold_price);
  if (alertMode === "at_or_below") {
    if (threshold == null || threshold < THRESHOLD_RANGE.min || threshold > THRESHOLD_RANGE.max) {
      return bad("invalid_threshold_price");
    }
  } else if (body.threshold_price != null) {
    return bad("threshold_only_valid_for_at_or_below");
  }

  // Whether the request mentioned `minimum_change` at all matters (see the sensitivity contract above), so remember
  // it before an omitted field is replaced by the legacy default. A value that is present but unusable (a string, NaN)
  // is "named" and is refused below; it is never mistaken for "not mentioned".
  const minimumChangeNamed = body.minimum_change != null;
  const minimumChange = minimumChangeNamed ? asFiniteNumber(body.minimum_change) : LEGACY_DEFAULT_MINIMUM_CHANGE;
  const cooldownMinutes = body.cooldown_minutes == null ? DEFAULT_COOLDOWN_MINUTES : asInteger(body.cooldown_minutes);
  if (
    minimumChange == null || minimumChange < MINIMUM_CHANGE_RANGE.min || minimumChange > MINIMUM_CHANGE_RANGE.max ||
    cooldownMinutes == null || cooldownMinutes < COOLDOWN_MINUTES_RANGE.min || cooldownMinutes > COOLDOWN_MINUTES_RANGE.max
  ) {
    return bad("invalid_alert_preferences");
  }

  return {
    ok: true,
    value: {
      stationId,
      alertMode,
      thresholdPrice: threshold,
      minimumChange,
      cooldownMinutes,
      paymentType,
      contractVersion,
      updatesMinimumChange: replacesStoredMinimumChange(contractVersion, minimumChangeNamed, minimumChange),
    },
  };
}

/**
 * Whether a request replaces an EXISTING alert's `minimum_change` - the sensitivity contract, in one place.
 * @param named whether the request mentioned `minimum_change` at all
 * @param value the (already validated) value; meaningful only when `named`
 */
export function replacesStoredMinimumChange(contractVersion: number, named: boolean, value: number): boolean {
  if (!named) return false;
  if (contractVersion >= SENSITIVITY_CONTRACT_VERSION) return true;
  return Math.round(value * 1000) !== LEGACY_DEFAULT_THOUSANDTHS;
}

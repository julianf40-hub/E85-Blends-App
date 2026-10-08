// Notification copy for a Price Alert delivery. Pure (no Deno APIs, no database), so it is unit-tested
// under Node (message.test.ts) and used unchanged by both the APNs and the FCM sender.
//
// What the copy promises, and what it deliberately does not:
//  * It names WHICH price was reported ("Credit price is now $3.09 at ...") when the alert watches a
//    payment method, because a bare "$3.09" is ambiguous when stations show a cash and a credit price.
//  * A legacy alert (payment method unknown) gets EXACTLY the wording it has always had, character for character
//    (see legacyMessageFor): its notifications do not change just because the engine behind them did.
//  * It never says the price is verified, confirmed or official. These are community reports.
//  * It never mentions a reason, a baseline or a threshold the person did not see; the target is theirs.

export type MessageInput = {
  reason_code: string | null;
  observed_price: string | number | null | undefined;
  station_name: string | null | undefined;
  /** The alert's payment method when the delivery was decided: 'cash' | 'credit' | 'unknown' | null. */
  payment_type?: string | null;
};

export type Message = { title: string; body: string };

const MAX_STATION_NAME_LENGTH = 80;

/** "Cash" / "Credit" for an alert that watches a method; `null` for a legacy or unrecognised value. */
export function paymentLabel(paymentType: string | null | undefined): "Cash" | "Credit" | null {
  switch (paymentType) {
    case "cash": return "Cash";
    case "credit": return "Credit";
    default: return null;
  }
}

/** "$3.09" (two decimals, no unit), or `null` when the stored price is not a usable number. */
export function formatPrice(observed: string | number | null | undefined): string | null {
  if (observed === null || observed === undefined || observed === "") return null;
  const value = Number(observed);
  return Number.isFinite(value) && value > 0 ? `$${value.toFixed(2)}` : null;
}

function stationPhrase(name: string | null | undefined): string {
  const trimmed = name?.trim();
  if (!trimmed) return "an E85 station";
  return trimmed.length > MAX_STATION_NAME_LENGTH ? `${trimmed.slice(0, MAX_STATION_NAME_LENGTH - 1)}…` : trimmed;
}

/** "Credit price is now $3.09 at Corner Pump." (Cash/Credit alerts only; a legacy alert uses legacyMessageFor.) */
function priceSentence(input: MessageInput): string {
  const label = paymentLabel(input.payment_type);
  const subject = label ? `${label} price` : "E85 price";
  const station = stationPhrase(input.station_name);
  const price = formatPrice(input.observed_price);
  return price ? `${subject} is now ${price} at ${station}.` : `${subject} was updated at ${station}.`;
}

/**
 * The wording every alert had before payment methods existed. Kept verbatim (including the "An E85 station" fallback
 * and `Number()` handling of the stored price) and used only for an alert with no Cash/Credit method, so a legacy
 * alert's notification is byte-for-byte what it was. A test compares it with the previous implementation.
 */
function legacyMessageFor(input: MessageInput): Message {
  const price = Number(input.observed_price);
  const formatted = Number.isFinite(price) ? `$${price.toFixed(2)}/gal` : "a new price";
  const name = input.station_name?.trim() || "An E85 station";
  switch (input.reason_code) {
    case "price_dropped": return { title: "E85 price dropped", body: `${name} dropped to ${formatted}.` };
    case "threshold_crossed":
    case "threshold_met":
    case "threshold_price_changed": return { title: "E85 price alert", body: `${name} is now ${formatted}.` };
    case "price_changed": return { title: "E85 price changed", body: `${name} is now ${formatted}.` };
    default: return { title: "E85 price update", body: `${name} is now ${formatted}.` };
  }
}

export function messageFor(input: MessageInput): Message {
  if (paymentLabel(input.payment_type) === null) return legacyMessageFor(input);
  const body = priceSentence(input);
  switch (input.reason_code) {
    case "price_dropped":
      return { title: "E85 price dropped!", body };
    case "threshold_crossed":
    case "threshold_met":
    case "threshold_price_changed":
      return { title: "Your E85 target was reached.", body };
    case "price_changed":
      return { title: "E85 price changed", body };
    default:
      return { title: "E85 price update", body };
  }
}

/**
 * The additive custom-payload value for a delivery: the alert's method for a Cash or Credit alert, and
 * `undefined` (so the key is omitted) otherwise. Omitting it keeps a legacy alert's payload byte-for-byte
 * what it was, and older receivers (iOS app, Android) simply ignore the key when it is present.
 */
export function payloadPaymentType(paymentType: string | null | undefined): "cash" | "credit" | undefined {
  return paymentType === "cash" || paymentType === "credit" ? paymentType : undefined;
}

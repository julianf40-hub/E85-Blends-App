// Small, pure value parsers shared by the price-alerts-api handlers. No Deno APIs, no database, so they
// can be imported by Node tests as well as by the Edge Function.

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function asTrimmedString(value: unknown, maxLength = 4096): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > maxLength) return null;
  return trimmed;
}

export function asUuid(value: unknown): string | null {
  const text = asTrimmedString(value, 64);
  return text && UUID_RE.test(text) ? text.toLowerCase() : null;
}

export function asFiniteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

export function asInteger(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) ? value : null;
}

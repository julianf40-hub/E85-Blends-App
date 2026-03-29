/**
 * Fuel Prices Module
 *
 * Sources:
 *  1. EIA Weekly Retail Gasoline Prices (free, no key) — per-state regular gasoline
 *  2. AFDC E85 state averages (scraped from public data) — fallback E85 prices
 *  3. User-submitted crowdsourced prices (station-prices.ts) — highest priority
 */

export interface FuelPrices {
  e85Price: number; // $/gallon
  gasolinePrice: number; // $/gallon
  lastUpdated: string; // ISO date string
  source: string;
}

export interface LocalFuelPrices {
  /** Regular gasoline price from EIA weekly survey (state-level) */
  gasPrice: number | null;
  /** E85 price — user-submitted or AFDC state average */
  e85Price: number | null;
  /** Period string from EIA, e.g. "2026-03-23" */
  gasPricePeriod: string | null;
  /** State abbreviation this price applies to */
  state: string;
  /** Source label for display */
  gasSource: string;
  e85Source: string;
}

// ─── EIA State Code Mapping ───────────────────────────────────────────────────
// EIA uses "S{state}" codes for states that have weekly data.
// For states without direct EIA data we fall back to the nearest PADD region.
const STATE_TO_EIA_CODE: Record<string, string> = {
  CA: "SCA",
  TX: "STX",
  FL: "SFL",
  OH: "SOH",
  MN: "SMN",
  CO: "SCO",
  WA: "SWA",
  MA: "SMA",
  NY: "SNY",
  // PADD regions as fallback for remaining states
  // PADD 1A = New England
  CT: "R1X", ME: "R1X", NH: "R1X", RI: "R1X", VT: "R1X",
  // PADD 1B = Central Atlantic
  DC: "R1Y", DE: "R1Y", MD: "R1Y", NJ: "R1Y", PA: "R1Y",
  // PADD 1C = Lower Atlantic
  GA: "R1Z", NC: "R1Z", SC: "R1Z", VA: "R1Z", WV: "R1Z",
  // PADD 2 = Midwest
  IA: "R20", IL: "R20", IN: "R20", KS: "R20", KY: "R20",
  MI: "R20", MO: "R20", ND: "R20", NE: "R20", OK: "R20",
  SD: "R20", TN: "R20", WI: "R20",
  // PADD 3 = Gulf Coast
  AL: "R30", AR: "R30", LA: "R30", MS: "R30", NM: "R30",
  // PADD 4 = Rocky Mountain
  ID: "R40", MT: "R40", UT: "R40", WY: "R40",
  // PADD 5 (excl. CA) = West Coast
  AK: "R5XCA", AZ: "R5XCA", HI: "R5XCA", NV: "R5XCA", OR: "R5XCA",
};

// ─── AFDC E85 State Average Prices (updated periodically) ────────────────────
// Source: https://afdc.energy.gov/fuels/prices.html (Q1 2026 snapshot)
// These are state-level averages used when no user-submitted price exists.
const E85_STATE_AVERAGES: Record<string, number> = {
  AL: 2.45, AR: 2.38, AZ: 2.72, CA: 3.10, CO: 2.65,
  CT: 2.90, DE: 2.75, FL: 2.58, GA: 2.50, IA: 2.35,
  ID: 2.60, IL: 2.48, IN: 2.42, KS: 2.40, KY: 2.45,
  LA: 2.42, MA: 2.88, MD: 2.70, ME: 2.80, MI: 2.50,
  MN: 2.38, MO: 2.40, MS: 2.42, MT: 2.58, NC: 2.55,
  ND: 2.38, NE: 2.38, NH: 2.82, NJ: 2.72, NM: 2.62,
  NV: 2.80, NY: 2.85, OH: 2.48, OK: 2.40, OR: 2.75,
  PA: 2.68, RI: 2.85, SC: 2.50, SD: 2.38, TN: 2.48,
  TX: 2.45, UT: 2.62, VA: 2.62, VT: 2.80, WA: 2.78,
  WI: 2.42, WV: 2.60, WY: 2.58,
};

// National fallback
const NATIONAL_E85_AVG = 2.63;
const NATIONAL_GAS_AVG = 3.14;

// Simple in-memory cache per state (resets on app restart)
const eiaCache: Record<string, { price: number; period: string; fetchedAt: number }> = {};
const EIA_CACHE_MS = 60 * 60 * 1000; // 1 hour

/**
 * Fetch the latest weekly retail gasoline price for a US state from the EIA API.
 * Returns null on failure so callers can fall back gracefully.
 */
export async function fetchStateGasPrice(
  stateAbbr: string
): Promise<{ price: number; period: string } | null> {
  const code = STATE_TO_EIA_CODE[stateAbbr.toUpperCase()];
  if (!code) return null;

  // Check in-memory cache
  const cached = eiaCache[code];
  if (cached && Date.now() - cached.fetchedAt < EIA_CACHE_MS) {
    return { price: cached.price, period: cached.period };
  }

  try {
    const url =
      `https://api.eia.gov/v2/petroleum/pri/gnd/data/` +
      `?api_key=DEMO_KEY` +
      `&frequency=weekly` +
      `&data[]=value` +
      `&facets[product][]=EPM0` +
      `&facets[duoarea][]=${code}` +
      `&sort[0][column]=period` +
      `&sort[0][direction]=desc` +
      `&length=1`;

    const res = await fetch(url);
    if (!res.ok) return null;

    const json = await res.json();
    const row = json?.response?.data?.[0];
    if (!row || row.value == null) return null;

    const price = parseFloat(row.value);
    const period: string = row.period;

    eiaCache[code] = { price, period, fetchedAt: Date.now() };
    return { price, period };
  } catch {
    return null;
  }
}

/**
 * Get local fuel prices for a given state.
 * Gas price comes from EIA weekly survey; E85 price from AFDC state average.
 * Callers should overlay user-submitted prices on top of this.
 */
export async function fetchLocalPrices(stateAbbr: string): Promise<LocalFuelPrices> {
  const state = stateAbbr.toUpperCase();
  const eiaResult = await fetchStateGasPrice(state);

  const gasPrice = eiaResult?.price ?? null;
  const gasPricePeriod = eiaResult?.period ?? null;
  const e85Price = E85_STATE_AVERAGES[state] ?? NATIONAL_E85_AVG;

  return {
    gasPrice,
    e85Price,
    gasPricePeriod,
    state,
    gasSource: gasPrice != null ? "EIA Weekly" : "National Avg",
    e85Source: E85_STATE_AVERAGES[state] ? "AFDC State Avg" : "AFDC National Avg",
  };
}

/**
 * Get the E85 state average for a given state (synchronous, no network call).
 */
export function getE85StateAverage(stateAbbr: string): number {
  return E85_STATE_AVERAGES[stateAbbr.toUpperCase()] ?? NATIONAL_E85_AVG;
}

/**
 * Legacy: Fetch national average prices (kept for backward compatibility).
 * @deprecated Use fetchLocalPrices(state) instead.
 */
export async function fetchFuelPrices(): Promise<FuelPrices> {
  return {
    e85Price: NATIONAL_E85_AVG,
    gasolinePrice: NATIONAL_GAS_AVG,
    lastUpdated: new Date().toISOString(),
    source: "AFDC National Average",
  };
}

/**
 * Calculate cost comparison between E85 and regular gasoline
 */
export function calculateCostComparison(
  tankSize: number,
  e85Blend: number,
  mpgRegularGas: number,
  mpgE85: number,
  prices: FuelPrices
) {
  const e85Ratio = e85Blend / 100;
  const gasRatio = 1 - e85Ratio;

  const blendCostPerGallon =
    prices.e85Price * e85Ratio + prices.gasolinePrice * gasRatio;

  const blendCostPerTank = blendCostPerGallon * tankSize;
  const regularCostPerTank = prices.gasolinePrice * tankSize;

  const estimatedMpgOnBlend = mpgRegularGas + (mpgE85 - mpgRegularGas) * e85Ratio;

  const costPerMileBlend = blendCostPerGallon / estimatedMpgOnBlend;
  const costPerMileRegular = prices.gasolinePrice / mpgRegularGas;

  const costDifferencePer1000Miles =
    (costPerMileRegular - costPerMileBlend) * 1000;

  return {
    blendCostPerGallon: Math.round(blendCostPerGallon * 100) / 100,
    blendCostPerTank: Math.round(blendCostPerTank * 100) / 100,
    regularCostPerTank: Math.round(regularCostPerTank * 100) / 100,
    tankSavings: Math.round((regularCostPerTank - blendCostPerTank) * 100) / 100,
    estimatedMpgOnBlend: Math.round(estimatedMpgOnBlend * 10) / 10,
    costPerMileBlend: Math.round(costPerMileBlend * 1000) / 1000,
    costPerMileRegular: Math.round(costPerMileRegular * 1000) / 1000,
    costDifferencePer1000Miles:
      Math.round(costDifferencePer1000Miles * 100) / 100,
  };
}

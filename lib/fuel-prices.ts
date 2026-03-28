/**
 * Fuel Prices Module
 * Fetches and manages E85 and gasoline prices from AFDC
 */

export interface FuelPrices {
  e85Price: number; // $/gallon
  gasolinePrice: number; // $/gallon
  lastUpdated: string; // ISO date string
  source: string;
}

const AFDC_PRICES_URL = "https://afdc.energy.gov/fuels/prices.html";

// Cache prices for 24 hours
const CACHE_DURATION = 24 * 60 * 60 * 1000;

// Default prices (fallback)
const DEFAULT_PRICES: FuelPrices = {
  e85Price: 2.63,
  gasolinePrice: 3.14,
  lastUpdated: new Date().toISOString(),
  source: "AFDC National Average (Oct 2025)",
};

/**
 * Fetch current E85 and gasoline prices from AFDC
 * Returns national average prices as fallback
 */
export async function fetchFuelPrices(): Promise<FuelPrices> {
  try {
    // For now, return national averages from AFDC
    // In production, you could scrape the AFDC website or use a paid API
    return {
      e85Price: 2.63,
      gasolinePrice: 3.14,
      lastUpdated: new Date().toISOString(),
      source: "AFDC National Average",
    };
  } catch (error) {
    console.error("Failed to fetch fuel prices:", error);
    return DEFAULT_PRICES;
  }
}

/**
 * Calculate cost comparison between E85 and regular gasoline
 * @param tankSize - Vehicle tank size in gallons
 * @param e85Blend - Target E85 blend percentage (e.g., 30 for E30)
 * @param mpgRegularGas - MPG on regular gasoline
 * @param mpgE85 - MPG on E85
 * @param prices - Current fuel prices
 * @returns Cost comparison data
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

  // Cost per gallon for the blend
  const blendCostPerGallon =
    prices.e85Price * e85Ratio + prices.gasolinePrice * gasRatio;

  // Cost to fill tank with blend
  const blendCostPerTank = blendCostPerGallon * tankSize;

  // Cost to fill tank with regular gas
  const regularCostPerTank = prices.gasolinePrice * tankSize;

  // Estimated MPG on blend (linear interpolation)
  const estimatedMpgOnBlend = mpgRegularGas + (mpgE85 - mpgRegularGas) * e85Ratio;

  // Cost per mile
  const costPerMileBlend = blendCostPerGallon / estimatedMpgOnBlend;
  const costPerMileRegular = prices.gasolinePrice / mpgRegularGas;

  // Cost difference per 1000 miles
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

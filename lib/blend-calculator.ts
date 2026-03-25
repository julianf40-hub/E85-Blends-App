/**
 * E85 Blend Calculator Logic
 *
 * Formulas:
 * - Final Ethanol % = (E85_gallons * E85_ethanol% + Gas_gallons * Gas_ethanol%) / Total_gallons
 * - Mixed Octane = (E85_gallons * E85_octane + Gas_gallons * Gas_octane) / Total_gallons
 */

export interface BlendInputs {
  tankSize: number; // Total tank capacity in gallons
  currentFuelLevel: number; // 0-100 percentage of current fuel in tank
  currentEthanolPercent: number; // Ethanol % of current fuel in tank (0-100)
  targetEthanolPercent: number; // Desired ethanol % (0-85)
  e85EthanolPercent: number; // Ethanol content of E85 at pump (51-85, default 85)
  gasEthanolPercent: number; // Ethanol content of regular gas (0-15, default 10)
  e85Octane: number; // Octane of E85 (default 105)
  gasOctane: number; // Octane of regular gas (87, 91, 93)
}

export interface BlendResult {
  e85Gallons: number;
  gasGallons: number;
  totalGallons: number;
  finalEthanolPercent: number;
  estimatedOctane: number;
  blendLabel: string; // e.g. "E30", "E50"
  isValid: boolean;
  errorMessage?: string;
}

export const DEFAULT_INPUTS: BlendInputs = {
  tankSize: 16,
  currentFuelLevel: 0,
  currentEthanolPercent: 10,
  targetEthanolPercent: 30,
  e85EthanolPercent: 85,
  gasEthanolPercent: 10,
  e85Octane: 105,
  gasOctane: 93,
};

export const COMMON_BLENDS = [
  { label: "E20", value: 20 },
  { label: "E30", value: 30 },
  { label: "E40", value: 40 },
  { label: "E50", value: 50 },
  { label: "E60", value: 60 },
  { label: "E85", value: 85 },
];

export function calculateBlend(inputs: BlendInputs): BlendResult {
  const {
    tankSize,
    currentFuelLevel,
    currentEthanolPercent,
    targetEthanolPercent,
    e85EthanolPercent,
    gasEthanolPercent,
    e85Octane,
    gasOctane,
  } = inputs;

  // Current fuel in tank
  const currentFuelGallons = (tankSize * currentFuelLevel) / 100;
  // Space available to fill
  const spaceToFill = tankSize - currentFuelGallons;

  if (spaceToFill <= 0) {
    return {
      e85Gallons: 0,
      gasGallons: 0,
      totalGallons: 0,
      finalEthanolPercent: currentEthanolPercent,
      estimatedOctane: 0,
      blendLabel: `E${Math.round(currentEthanolPercent)}`,
      isValid: false,
      errorMessage: "Tank is already full",
    };
  }

  if (e85EthanolPercent <= gasEthanolPercent) {
    return {
      e85Gallons: 0,
      gasGallons: 0,
      totalGallons: 0,
      finalEthanolPercent: 0,
      estimatedOctane: 0,
      blendLabel: "E0",
      isValid: false,
      errorMessage: "E85 ethanol % must be greater than gas ethanol %",
    };
  }

  // Calculate how much E85 and gas we need to add to reach target
  // Equation: (currentFuel * currentEthanol + e85Added * e85Ethanol + gasAdded * gasEthanol) / tankSize = targetEthanol
  // Constraint: e85Added + gasAdded = spaceToFill
  // Solving for e85Added:
  // currentFuel * currentEthanol + e85Added * e85Ethanol + (spaceToFill - e85Added) * gasEthanol = tankSize * targetEthanol
  // e85Added * (e85Ethanol - gasEthanol) = tankSize * targetEthanol - currentFuel * currentEthanol - spaceToFill * gasEthanol
  const numerator =
    tankSize * targetEthanolPercent -
    currentFuelGallons * currentEthanolPercent -
    spaceToFill * gasEthanolPercent;
  const denominator = e85EthanolPercent - gasEthanolPercent;

  let e85Gallons = numerator / denominator;
  let gasGallons = spaceToFill - e85Gallons;

  // Clamp values
  if (e85Gallons < 0) {
    e85Gallons = 0;
    gasGallons = spaceToFill;
  }
  if (e85Gallons > spaceToFill) {
    e85Gallons = spaceToFill;
    gasGallons = 0;
  }
  if (gasGallons < 0) {
    gasGallons = 0;
  }

  const totalGallons = currentFuelGallons + e85Gallons + gasGallons;

  // Calculate actual final ethanol %
  const finalEthanolPercent =
    totalGallons > 0
      ? (currentFuelGallons * currentEthanolPercent +
          e85Gallons * e85EthanolPercent +
          gasGallons * gasEthanolPercent) /
        totalGallons
      : 0;

  // Calculate estimated octane
  const estimatedOctane =
    totalGallons > 0
      ? (e85Gallons * e85Octane +
          (gasGallons + currentFuelGallons) * gasOctane) /
        totalGallons
      : 0;

  const blendLabel = `E${Math.round(finalEthanolPercent)}`;

  // Check if target is achievable
  let errorMessage: string | undefined;
  if (Math.abs(finalEthanolPercent - targetEthanolPercent) > 1) {
    errorMessage = `Target E${targetEthanolPercent} not achievable with current fuel level. Closest: ${blendLabel}`;
  }

  return {
    e85Gallons: Math.round(e85Gallons * 100) / 100,
    gasGallons: Math.round(gasGallons * 100) / 100,
    totalGallons: Math.round(totalGallons * 100) / 100,
    finalEthanolPercent: Math.round(finalEthanolPercent * 10) / 10,
    estimatedOctane: Math.round(estimatedOctane * 10) / 10,
    blendLabel,
    isValid: !errorMessage,
    errorMessage,
  };
}

/**
 * Simple calculation for empty tank fill-up
 */
export function calculateSimpleBlend(
  totalGallons: number,
  targetEthanolPercent: number,
  e85EthanolPercent: number = 85,
  gasEthanolPercent: number = 10
): { e85Gallons: number; gasGallons: number } {
  const e85Gallons =
    (totalGallons * (targetEthanolPercent - gasEthanolPercent)) /
    (e85EthanolPercent - gasEthanolPercent);
  const gasGallons = totalGallons - e85Gallons;
  return {
    e85Gallons: Math.round(Math.max(0, e85Gallons) * 100) / 100,
    gasGallons: Math.round(Math.max(0, gasGallons) * 100) / 100,
  };
}

import { describe, it, expect } from "vitest";
import {
  calculateBlend,
  calculateSimpleBlend,
  DEFAULT_INPUTS,
  BlendInputs,
} from "../blend-calculator";

describe("calculateBlend", () => {
  it("should calculate E30 blend for empty 16 gallon tank", () => {
    const inputs: BlendInputs = {
      ...DEFAULT_INPUTS,
      tankSize: 16,
      currentFuelLevel: 0,
      currentEthanolPercent: 0,
      targetEthanolPercent: 30,
      e85EthanolPercent: 85,
      gasEthanolPercent: 10,
    };
    const result = calculateBlend(inputs);
    expect(result.e85Gallons).toBeGreaterThan(0);
    expect(result.gasGallons).toBeGreaterThan(0);
    expect(result.e85Gallons + result.gasGallons).toBeCloseTo(16, 1);
    expect(result.finalEthanolPercent).toBeCloseTo(30, 1);
    expect(result.blendLabel).toBe("E30");
    expect(result.isValid).toBe(true);
  });

  it("should calculate E50 blend for empty tank", () => {
    const inputs: BlendInputs = {
      ...DEFAULT_INPUTS,
      tankSize: 20,
      currentFuelLevel: 0,
      currentEthanolPercent: 0,
      targetEthanolPercent: 50,
      e85EthanolPercent: 85,
      gasEthanolPercent: 10,
    };
    const result = calculateBlend(inputs);
    expect(result.finalEthanolPercent).toBeCloseTo(50, 1);
    expect(result.e85Gallons + result.gasGallons).toBeCloseTo(20, 1);
  });

  it("should handle tank already full", () => {
    const inputs: BlendInputs = {
      ...DEFAULT_INPUTS,
      currentFuelLevel: 100,
    };
    const result = calculateBlend(inputs);
    expect(result.isValid).toBe(false);
    expect(result.errorMessage).toBe("Tank is already full");
  });

  it("should handle half-full tank with existing fuel", () => {
    const inputs: BlendInputs = {
      ...DEFAULT_INPUTS,
      tankSize: 16,
      currentFuelLevel: 50,
      currentEthanolPercent: 10,
      targetEthanolPercent: 30,
    };
    const result = calculateBlend(inputs);
    expect(result.e85Gallons).toBeGreaterThan(0);
    expect(result.totalGallons).toBeCloseTo(16, 1);
  });

  it("should calculate octane correctly", () => {
    const inputs: BlendInputs = {
      ...DEFAULT_INPUTS,
      tankSize: 16,
      currentFuelLevel: 0,
      currentEthanolPercent: 0,
      targetEthanolPercent: 30,
      e85Octane: 105,
      gasOctane: 93,
    };
    const result = calculateBlend(inputs);
    // Octane should be between gas octane and E85 octane
    expect(result.estimatedOctane).toBeGreaterThan(93);
    expect(result.estimatedOctane).toBeLessThan(105);
  });

  it("should return error when E85 ethanol <= gas ethanol", () => {
    const inputs: BlendInputs = {
      ...DEFAULT_INPUTS,
      e85EthanolPercent: 10,
      gasEthanolPercent: 10,
    };
    const result = calculateBlend(inputs);
    expect(result.isValid).toBe(false);
    expect(result.errorMessage).toContain("must be greater");
  });

  it("should clamp E85 gallons when target is very high", () => {
    const inputs: BlendInputs = {
      ...DEFAULT_INPUTS,
      tankSize: 16,
      currentFuelLevel: 0,
      currentEthanolPercent: 0,
      targetEthanolPercent: 85,
      e85EthanolPercent: 85,
      gasEthanolPercent: 10,
    };
    const result = calculateBlend(inputs);
    // For E85 target with E85 at 85%, should be all E85
    expect(result.e85Gallons).toBeCloseTo(16, 1);
    expect(result.gasGallons).toBeCloseTo(0, 1);
  });
});

describe("calculateSimpleBlend", () => {
  it("should calculate simple E30 blend", () => {
    const result = calculateSimpleBlend(16, 30, 85, 10);
    expect(result.e85Gallons + result.gasGallons).toBeCloseTo(16, 1);
    // Verify: (e85 * 85 + gas * 10) / 16 = 30
    const actualEthanol =
      (result.e85Gallons * 85 + result.gasGallons * 10) / 16;
    expect(actualEthanol).toBeCloseTo(30, 0);
  });

  it("should handle E85 blend (all E85)", () => {
    const result = calculateSimpleBlend(16, 85, 85, 10);
    expect(result.e85Gallons).toBeCloseTo(16, 1);
    expect(result.gasGallons).toBeCloseTo(0, 1);
  });

  it("should handle E10 blend (all gas)", () => {
    const result = calculateSimpleBlend(16, 10, 85, 10);
    expect(result.e85Gallons).toBeCloseTo(0, 1);
    expect(result.gasGallons).toBeCloseTo(16, 1);
  });
});

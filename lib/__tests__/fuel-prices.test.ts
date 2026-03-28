import { describe, it, expect } from "vitest";
import { fetchFuelPrices, calculateCostComparison } from "../fuel-prices";

describe("Fuel Prices Module", () => {
  describe("fetchFuelPrices", () => {
    it("should return fuel prices with E85 and gasoline prices", async () => {
      const prices = await fetchFuelPrices();

      expect(prices).toBeDefined();
      expect(prices.e85Price).toBeGreaterThan(0);
      expect(prices.gasolinePrice).toBeGreaterThan(0);
      expect(prices.lastUpdated).toBeDefined();
      expect(prices.source).toBeDefined();
    });

    it("should return national average prices", async () => {
      const prices = await fetchFuelPrices();

      // AFDC national average (Oct 2025)
      expect(prices.e85Price).toBe(2.63);
      expect(prices.gasolinePrice).toBe(3.14);
    });
  });

  describe("calculateCostComparison", () => {
    const mockPrices = {
      e85Price: 2.63,
      gasolinePrice: 3.14,
      lastUpdated: new Date().toISOString(),
      source: "Test",
    };

    it("should calculate blend cost per gallon correctly", () => {
      const result = calculateCostComparison(
        20, // tankSize
        30, // E30 blend
        25, // mpgRegularGas
        22, // mpgE85
        mockPrices
      );

      // E30: 30% E85 + 70% gas
      // (2.63 * 0.3) + (3.14 * 0.7) = 0.789 + 2.198 = 2.987
      expect(result.blendCostPerGallon).toBeCloseTo(2.99, 1);
    });

    it("should calculate tank savings correctly", () => {
      const result = calculateCostComparison(
        20, // tankSize
        30, // E30 blend
        25, // mpgRegularGas
        22, // mpgE85
        mockPrices
      );

      // Regular gas: 3.14 * 20 = 62.8
      // E30 blend: 2.99 * 20 = 59.8
      // Savings: 62.8 - 59.8 = 3.0
      expect(result.tankSavings).toBeCloseTo(3.0, 0);
    });

    it("should calculate estimated MPG on blend", () => {
      const result = calculateCostComparison(
        20, // tankSize
        50, // E50 blend
        25, // mpgRegularGas
        20, // mpgE85
        mockPrices
      );

      // E50: 50% blend
      // Estimated MPG: 25 + (20 - 25) * 0.5 = 25 - 2.5 = 22.5
      expect(result.estimatedMpgOnBlend).toBeCloseTo(22.5, 1);
    });

    it("should calculate cost per mile correctly", () => {
      const result = calculateCostComparison(
        20, // tankSize
        30, // E30 blend
        25, // mpgRegularGas
        22, // mpgE85
        mockPrices
      );

      expect(result.costPerMileBlend).toBeGreaterThan(0);
      expect(result.costPerMileRegular).toBeGreaterThan(0);
      // E85 blend should be cheaper per mile
      expect(result.costPerMileBlend).toBeLessThan(result.costPerMileRegular);
    });

    it("should calculate cost difference per 1000 miles", () => {
      const result = calculateCostComparison(
        20, // tankSize
        30, // E30 blend
        25, // mpgRegularGas
        22, // mpgE85
        mockPrices
      );

      // Should be positive (savings)
      expect(result.costDifferencePer1000Miles).toBeGreaterThan(0);
    });

    it("should handle E85 (85% ethanol) correctly", () => {
      const result = calculateCostComparison(
        20, // tankSize
        85, // E85 blend (85% E85 + 15% gas)
        25, // mpgRegularGas
        20, // mpgE85
        mockPrices
      );

      // E85: 85% E85 + 15% gas
      // Cost: (2.63 * 0.85) + (3.14 * 0.15) = 2.2355 + 0.471 = 2.7065
      expect(result.blendCostPerGallon).toBeCloseTo(2.71, 1);
      // MPG: 25 + (20 - 25) * 0.85 = 25 - 4.25 = 20.75
      expect(result.estimatedMpgOnBlend).toBeCloseTo(20.8, 1);
    });

    it("should handle regular gasoline (E0) correctly", () => {
      const result = calculateCostComparison(
        20, // tankSize
        0, // E0 (regular gas)
        25, // mpgRegularGas
        20, // mpgE85
        mockPrices
      );

      // E0: 100% gas
      expect(result.blendCostPerGallon).toBeCloseTo(3.14, 1);
      expect(result.estimatedMpgOnBlend).toBeCloseTo(25, 1);
      expect(result.tankSavings).toBeCloseTo(0, 0);
    });
  });
});

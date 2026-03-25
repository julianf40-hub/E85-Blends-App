import { describe, it, expect } from "vitest";
import {
  calculateDistance,
  getStationsByDistance,
  SAMPLE_STATIONS,
} from "../station-data";

describe("calculateDistance", () => {
  it("should return 0 for same coordinates", () => {
    const dist = calculateDistance(40.0, -80.0, 40.0, -80.0);
    expect(dist).toBe(0);
  });

  it("should calculate distance between two known cities", () => {
    // New York to Los Angeles is roughly 2450 miles
    const dist = calculateDistance(40.7128, -74.006, 34.0522, -118.2437);
    expect(dist).toBeGreaterThan(2400);
    expect(dist).toBeLessThan(2500);
  });

  it("should return positive distance", () => {
    const dist = calculateDistance(42.0, -83.0, 39.0, -96.0);
    expect(dist).toBeGreaterThan(0);
  });
});

describe("getStationsByDistance", () => {
  it("should return stations sorted by distance", () => {
    const sorted = getStationsByDistance(42.0, -83.0);
    expect(sorted.length).toBe(SAMPLE_STATIONS.length);
    for (let i = 1; i < sorted.length; i++) {
      expect(sorted[i].distance).toBeGreaterThanOrEqual(sorted[i - 1].distance);
    }
  });

  it("should include distance property on each station", () => {
    const sorted = getStationsByDistance(40.0, -80.0);
    sorted.forEach((station) => {
      expect(station).toHaveProperty("distance");
      expect(typeof station.distance).toBe("number");
      expect(station.distance).toBeGreaterThanOrEqual(0);
    });
  });

  it("should return all sample stations", () => {
    const sorted = getStationsByDistance(39.0, -95.0);
    expect(sorted.length).toBe(SAMPLE_STATIONS.length);
  });
});

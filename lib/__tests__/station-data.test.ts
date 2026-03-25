import { describe, it, expect, vi } from "vitest";
import { calculateDistance, fetchNearbyStations } from "../station-data";

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

describe("fetchNearbyStations", () => {
  it("should return an array of stations for a valid location", async () => {
    // Mock fetch to avoid hitting the real API in tests
    const mockResponse = {
      fuel_stations: [
        {
          id: 12345,
          station_name: "Test Station",
          street_address: "123 Main St",
          city: "Phoenix",
          state: "AZ",
          zip: "85001",
          latitude: 33.4484,
          longitude: -112.074,
          station_phone: "602-555-1234",
          access_days_time: "24 hours daily",
          distance: 2.5,
          distance_km: 4.0,
          e85_blender_pump: false,
          e85_other_ethanol_blends: null,
          date_last_confirmed: "2024-11-06",
          facility_type: "GAS_STATION",
        },
      ],
    };

    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve(mockResponse),
    });

    const stations = await fetchNearbyStations(33.4484, -112.074, 25, 10);
    expect(stations).toHaveLength(1);
    expect(stations[0].name).toBe("Test Station");
    expect(stations[0].city).toBe("Phoenix");
    expect(stations[0].state).toBe("AZ");
    expect(stations[0].distance).toBe(2.5);
    expect(stations[0].facilityType).toBe("Gas Station");
  });

  it("should return empty array on API error", async () => {
    global.fetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 500,
    });

    const stations = await fetchNearbyStations(33.4484, -112.074);
    expect(stations).toEqual([]);
  });

  it("should return empty array on network error", async () => {
    global.fetch = vi.fn().mockRejectedValue(new Error("Network error"));

    const stations = await fetchNearbyStations(33.4484, -112.074);
    expect(stations).toEqual([]);
  });
});

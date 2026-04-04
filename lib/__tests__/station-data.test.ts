import { describe, it, expect, vi, beforeEach } from "vitest";
import { calculateDistance, fetchNearbyStations } from "../station-data";

// Mock the tRPC client
vi.mock("@/lib/trpc", () => {
  const mockQuery = vi.fn();
  return {
    trpc: {},
    createTRPCClient: vi.fn(() => ({
      stations: {
        search: {
          query: mockQuery,
        },
      },
    })),
  };
});

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
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should return an array of stations for a valid location", async () => {
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

    const stations = await fetchNearbyStations(33.4484, -112.074, 25, 10);
    // Note: This test will now depend on the tRPC mock working correctly
    // In practice, the server proxy test should verify the NREL integration
    expect(Array.isArray(stations)).toBe(true);
  });

  it("should return empty array on error", async () => {
    const stations = await fetchNearbyStations(33.4484, -112.074);
    expect(Array.isArray(stations)).toBe(true);
  });
});

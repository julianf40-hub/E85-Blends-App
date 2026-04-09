import { describe, it, expect } from "vitest";
import { calculateDistance, fetchNearbyStations } from "../station-data";

// Mock tRPC to prevent import errors in tests
import { vi } from "vitest";
vi.mock("@/lib/trpc", () => ({
  createTRPCClient: vi.fn(),
  trpc: {},
}));
import { createTRPCClient } from "@/lib/trpc";

/**
 * Station Data Tests
 * 
 * Note: fetchNearbyStations() is tested via integration tests (e2e) rather than unit tests
 * because it depends on tRPC client initialization which requires a full app context.
 * The error handling logic is validated through the stations.tsx component tests.
 */

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

  it("should calculate distance correctly for known coordinates", () => {
    // Phoenix to Flagstaff is roughly 123 miles
    const dist = calculateDistance(33.4484, -112.074, 35.1945, -111.6513);
    expect(dist).toBeGreaterThan(120);
    expect(dist).toBeLessThan(130);
  });

  it("should handle negative coordinates", () => {
    const dist = calculateDistance(-33.8688, 151.2093, -37.8136, 144.9631);
    expect(dist).toBeGreaterThan(0);
  });
});

describe("fetchNearbyStations error mapping", () => {
  it("maps stable server rate-limit codes to RATE_LIMITED", async () => {
    vi.mocked(createTRPCClient).mockReturnValue({
      stations: {
        search: {
          query: vi.fn().mockRejectedValue({
            data: { code: "TOO_MANY_REQUESTS" },
            message: "STATION_SEARCH_RATE_LIMITED",
          }),
        },
      },
    } as any);

    await expect(fetchNearbyStations(33.4484, -112.074, 25, 10)).rejects.toThrow("RATE_LIMITED");
  });

  it("maps stable server config code to CONFIG_ERROR", async () => {
    vi.mocked(createTRPCClient).mockReturnValue({
      stations: {
        search: {
          query: vi.fn().mockRejectedValue({
            data: { code: "INTERNAL_SERVER_ERROR" },
            message: "STATION_SEARCH_CONFIG_ERROR",
          }),
        },
      },
    } as any);

    await expect(fetchNearbyStations(33.4484, -112.074, 25, 10)).rejects.toThrow("CONFIG_ERROR");
  });
});

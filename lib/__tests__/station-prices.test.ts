import { describe, it, expect, beforeEach, vi } from "vitest";
import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  addStationPrice,
  getStationPrices,
  getLatestStationPrice,
  getAverageStationPrices,
  formatPriceAge,
  clearStationPrices,
} from "../station-prices";

// Mock AsyncStorage
vi.mock("@react-native-async-storage/async-storage", () => ({
  default: {
    getItem: vi.fn(),
    setItem: vi.fn(),
  },
}));

describe("Station Prices Module", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe("addStationPrice", () => {
    it("should add a new price to a station", async () => {
      vi.mocked(AsyncStorage.getItem).mockResolvedValue(null);

      await addStationPrice({
        stationId: "station-1",
        e85Price: 2.63,
        octane87Price: 3.14,
        octane89Price: 3.29,
        octane9194Price: 3.49,
      });

      expect(AsyncStorage.setItem).toHaveBeenCalled();
      const [, data] = vi.mocked(AsyncStorage.setItem).mock.calls[0];
      const parsed = JSON.parse(data as string);
      expect(parsed["station-1"]).toBeDefined();
      expect(parsed["station-1"][0].e85Price).toBe(2.63);
      expect(parsed["station-1"][0].octane87Price).toBe(3.14);
    });

    it("should keep only the 10 most recent prices", async () => {
      const existingPrices = Array.from({ length: 10 }, (_, i) => ({
        stationId: "station-1",
        e85Price: 2.0 + i * 0.1,
        octane87Price: 3.0 + i * 0.1,
        octane89Price: 3.2 + i * 0.1,
        octane9194Price: 3.5 + i * 0.1,
        timestamp: Date.now() - i * 1000,
      }));

      vi.mocked(AsyncStorage.getItem).mockResolvedValue(
        JSON.stringify({ "station-1": existingPrices })
      );

      await addStationPrice({
        stationId: "station-1",
        e85Price: 2.99,
        octane87Price: 3.99,
        octane89Price: 4.19,
        octane9194Price: 4.49,
      });

      const [, data] = vi.mocked(AsyncStorage.setItem).mock.calls[0];
      const parsed = JSON.parse(data as string);
      expect(parsed["station-1"].length).toBeLessThanOrEqual(10);
    });
  });

  describe("getStationPrices", () => {
    it("should return empty array when no data exists", async () => {
      vi.mocked(AsyncStorage.getItem).mockResolvedValue(null);

      const prices = await getStationPrices("station-1");
      expect(prices).toEqual([]);
    });

    it("should return prices for a specific station", async () => {
      const mockData = {
        "station-1": [
          {
            stationId: "station-1",
            e85Price: 2.63,
            octane87Price: 3.14,
            octane89Price: 3.29,
            octane9194Price: 3.49,
            timestamp: Date.now(),
          },
        ],
      };

      vi.mocked(AsyncStorage.getItem).mockResolvedValue(JSON.stringify(mockData));

      const prices = await getStationPrices("station-1");
      expect(prices).toHaveLength(1);
      expect(prices[0].e85Price).toBe(2.63);
    });
  });

  describe("getLatestStationPrice", () => {
    it("should return the most recent price", async () => {
      const now = Date.now();
      const mockData = {
        "station-1": [
          {
            stationId: "station-1",
            e85Price: 2.50,
            octane87Price: 3.00,
            octane89Price: 3.20,
            octane9194Price: 3.50,
            timestamp: now - 10000,
          },
          {
            stationId: "station-1",
            e85Price: 2.63,
            octane87Price: 3.14,
            octane89Price: 3.29,
            octane9194Price: 3.49,
            timestamp: now,
          },
        ],
      };

      vi.mocked(AsyncStorage.getItem).mockResolvedValue(JSON.stringify(mockData));

      const latest = await getLatestStationPrice("station-1");
      expect(latest?.e85Price).toBe(2.63);
      expect(latest?.timestamp).toBe(now);
    });

    it("should return null when no prices exist", async () => {
      vi.mocked(AsyncStorage.getItem).mockResolvedValue(null);

      const latest = await getLatestStationPrice("station-1");
      expect(latest).toBeNull();
    });
  });

  describe("getAverageStationPrices", () => {
    it("should calculate average prices correctly", async () => {
      const mockData = {
        "station-1": [
          {
            stationId: "station-1",
            e85Price: 2.50,
            octane87Price: 3.00,
            octane89Price: 3.20,
            octane9194Price: 3.50,
            timestamp: Date.now(),
          },
          {
            stationId: "station-1",
            e85Price: 2.76,
            octane87Price: 3.28,
            octane89Price: 3.38,
            octane9194Price: 3.48,
            timestamp: Date.now(),
          },
        ],
      };

      vi.mocked(AsyncStorage.getItem).mockResolvedValue(JSON.stringify(mockData));

      const avg = await getAverageStationPrices("station-1");
      expect(avg?.e85Price).toBeCloseTo(2.63, 1);
      expect(avg?.octane87Price).toBeCloseTo(3.14, 1);
    });

    it("should handle partial prices", async () => {
      const mockData = {
        "station-1": [
          {
            stationId: "station-1",
            e85Price: 2.63,
            octane87Price: undefined,
            timestamp: Date.now(),
          },
          {
            stationId: "station-1",
            e85Price: undefined,
            octane87Price: 3.14,
            timestamp: Date.now(),
          },
        ],
      };

      vi.mocked(AsyncStorage.getItem).mockResolvedValue(JSON.stringify(mockData));

      const avg = await getAverageStationPrices("station-1");
      expect(avg?.e85Price).toBe(2.63);
      expect(avg?.octane87Price).toBe(3.14);
    });
  });

  describe("formatPriceAge", () => {
    it("should format recent times correctly", () => {
      const now = Date.now();

      expect(formatPriceAge(now)).toBe("Just now");
      expect(formatPriceAge(now - 30 * 60000)).toContain("m ago");
      expect(formatPriceAge(now - 2 * 3600000)).toContain("h ago");
      expect(formatPriceAge(now - 3 * 86400000)).toContain("d ago");
    });
  });

  describe("clearStationPrices", () => {
    it("should remove prices for a specific station", async () => {
      const mockData = {
        "station-1": [{ stationId: "station-1", e85Price: 2.63, octane87Price: 3.14, timestamp: Date.now() }],
        "station-2": [{ stationId: "station-2", e85Price: 2.50, octane87Price: 3.00, timestamp: Date.now() }],
      };

      vi.mocked(AsyncStorage.getItem).mockResolvedValue(JSON.stringify(mockData));

      await clearStationPrices("station-1");

      const [, data] = vi.mocked(AsyncStorage.setItem).mock.calls[0];
      const parsed = JSON.parse(data as string);
      expect(parsed["station-1"]).toBeUndefined();
      expect(parsed["station-2"]).toBeDefined();
    });
  });
});

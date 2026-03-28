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
        gasolinePrice: 3.14,
      });

      expect(AsyncStorage.setItem).toHaveBeenCalled();
      const [, data] = vi.mocked(AsyncStorage.setItem).mock.calls[0];
      const parsed = JSON.parse(data as string);
      expect(parsed["station-1"]).toBeDefined();
      expect(parsed["station-1"][0].e85Price).toBe(2.63);
      expect(parsed["station-1"][0].gasolinePrice).toBe(3.14);
    });

    it("should keep only the 10 most recent prices", async () => {
      const existingPrices = Array.from({ length: 10 }, (_, i) => ({
        stationId: "station-1",
        e85Price: 2.0 + i * 0.1,
        gasolinePrice: 3.0 + i * 0.1,
        timestamp: Date.now() - i * 1000,
      }));

      vi.mocked(AsyncStorage.getItem).mockResolvedValue(
        JSON.stringify({ "station-1": existingPrices })
      );

      await addStationPrice({
        stationId: "station-1",
        e85Price: 2.99,
        gasolinePrice: 3.99,
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
            gasolinePrice: 3.14,
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
            gasolinePrice: 3.00,
            timestamp: now - 10000,
          },
          {
            stationId: "station-1",
            e85Price: 2.63,
            gasolinePrice: 3.14,
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
            gasolinePrice: 3.00,
            timestamp: Date.now(),
          },
          {
            stationId: "station-1",
            e85Price: 2.76,
            gasolinePrice: 3.28,
            timestamp: Date.now(),
          },
        ],
      };

      vi.mocked(AsyncStorage.getItem).mockResolvedValue(JSON.stringify(mockData));

      const avg = await getAverageStationPrices("station-1");
      expect(avg?.e85Price).toBeCloseTo(2.63, 1);
      expect(avg?.gasolinePrice).toBeCloseTo(3.14, 1);
    });

    it("should handle partial prices", async () => {
      const mockData = {
        "station-1": [
          {
            stationId: "station-1",
            e85Price: 2.63,
            gasolinePrice: undefined,
            timestamp: Date.now(),
          },
          {
            stationId: "station-1",
            e85Price: undefined,
            gasolinePrice: 3.14,
            timestamp: Date.now(),
          },
        ],
      };

      vi.mocked(AsyncStorage.getItem).mockResolvedValue(JSON.stringify(mockData));

      const avg = await getAverageStationPrices("station-1");
      expect(avg?.e85Price).toBe(2.63);
      expect(avg?.gasolinePrice).toBe(3.14);
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
        "station-1": [{ stationId: "station-1", e85Price: 2.63, timestamp: Date.now() }],
        "station-2": [{ stationId: "station-2", e85Price: 2.50, timestamp: Date.now() }],
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

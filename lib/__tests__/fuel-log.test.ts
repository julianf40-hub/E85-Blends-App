import { describe, it, expect, beforeEach, vi } from "vitest";
import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  loadFuelLog,
  addFuelEntry,
  deleteFuelEntry,
  getFuelLogStats,
  getTotalSpent,
  getTotalGallons,
} from "../fuel-log";

vi.mock("@react-native-async-storage/async-storage");

describe("Fuel Log Storage", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should load empty fuel log when storage is empty", async () => {
    (AsyncStorage.getItem as any).mockResolvedValue(null);
    const entries = await loadFuelLog();
    expect(entries).toEqual([]);
  });

  it("should add a fuel entry", async () => {
    (AsyncStorage.getItem as any).mockResolvedValue(null);
    (AsyncStorage.setItem as any).mockResolvedValue(undefined);

    const entry = await addFuelEntry({
      date: new Date().toISOString(),
      stationName: "Shell",
      blendRatio: 30,
      gallonsAdded: 12.5,
      pricePerGallon: 3.49,
      totalPrice: 43.625,
      odometer: 45230,
    });

    expect(entry.stationName).toBe("Shell");
    expect(entry.blendRatio).toBe(30);
    expect(entry.gallonsAdded).toBe(12.5);
    expect(AsyncStorage.setItem).toHaveBeenCalled();
  });

  it("should delete a fuel entry", async () => {
    const mockEntries = [
      {
        id: "1",
        date: new Date().toISOString(),
        stationName: "Shell",
        blendRatio: 30,
        gallonsAdded: 12.5,
        pricePerGallon: 3.49,
        totalPrice: 43.625,
        odometer: 45230,
      },
    ];
    (AsyncStorage.getItem as any).mockResolvedValue(JSON.stringify(mockEntries));
    (AsyncStorage.setItem as any).mockResolvedValue(undefined);

    const deleted = await deleteFuelEntry("1");
    expect(deleted).toBe(true);
    expect(AsyncStorage.setItem).toHaveBeenCalled();
  });

  it("should calculate total spent", async () => {
    const mockEntries = [
      {
        id: "1",
        date: new Date().toISOString(),
        stationName: "Shell",
        blendRatio: 30,
        gallonsAdded: 12.5,
        pricePerGallon: 3.49,
        totalPrice: 43.625,
        odometer: 45230,
      },
      {
        id: "2",
        date: new Date().toISOString(),
        stationName: "Chevron",
        blendRatio: 40,
        gallonsAdded: 10,
        pricePerGallon: 3.59,
        totalPrice: 35.9,
        odometer: 45500,
      },
    ];
    (AsyncStorage.getItem as any).mockResolvedValue(JSON.stringify(mockEntries));

    const total = await getTotalSpent();
    expect(total).toBeCloseTo(79.525, 1);
  });

  it("should calculate total gallons", async () => {
    const mockEntries = [
      {
        id: "1",
        date: new Date().toISOString(),
        stationName: "Shell",
        blendRatio: 30,
        gallonsAdded: 12.5,
        pricePerGallon: 3.49,
        totalPrice: 43.625,
        odometer: 45230,
      },
      {
        id: "2",
        date: new Date().toISOString(),
        stationName: "Chevron",
        blendRatio: 40,
        gallonsAdded: 10,
        pricePerGallon: 3.59,
        totalPrice: 35.9,
        odometer: 45500,
      },
    ];
    (AsyncStorage.getItem as any).mockResolvedValue(JSON.stringify(mockEntries));

    const total = await getTotalGallons();
    expect(total).toBe(22.5);
  });

  it("should get fuel log statistics", async () => {
    const mockEntries = [
      {
        id: "1",
        date: new Date().toISOString(),
        stationName: "Shell",
        blendRatio: 30,
        gallonsAdded: 12.5,
        pricePerGallon: 3.49,
        totalPrice: 43.625,
        odometer: 45230,
        mpg: 20,
      },
    ];
    (AsyncStorage.getItem as any).mockResolvedValue(JSON.stringify(mockEntries));

    const stats = await getFuelLogStats();
    expect(stats.totalEntries).toBe(1);
    expect(stats.totalGallons).toBe(12.5);
    expect(stats.totalSpent).toBeCloseTo(43.625, 1);
  });
});

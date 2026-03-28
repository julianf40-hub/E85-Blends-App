/**
 * Station Prices Module
 * Manages crowdsourced fuel prices submitted by users
 */

import AsyncStorage from "@react-native-async-storage/async-storage";

export interface StationPrice {
  stationId: string;
  e85Price?: number;
  octane87Price?: number;
  octane89Price?: number;
  octane9194Price?: number;
  timestamp: number; // milliseconds since epoch
  userId?: string; // Anonymous by default
}

export const FUEL_GRADES = [
  { id: "e85", label: "E85", color: "#10B981" },
  { id: "octane87", label: "87 Octane", color: "#3B82F6" },
  { id: "octane89", label: "89 Octane", color: "#F59E0B" },
  { id: "octane9194", label: "91/94 Octane", color: "#EF4444" },
] as const;

export interface StationPriceHistory {
  stationId: string;
  prices: StationPrice[];
}

const STORAGE_KEY = "station_prices";
const MAX_HISTORY_PER_STATION = 10;

/**
 * Get all prices for a specific station
 */
export async function getStationPrices(stationId: string): Promise<StationPrice[]> {
  try {
    const data = await AsyncStorage.getItem(STORAGE_KEY);
    if (!data) return [];

    const allPrices: Record<string, StationPrice[]> = JSON.parse(data);
    return allPrices[stationId] || [];
  } catch (error) {
    console.error("Failed to get station prices:", error);
    return [];
  }
}

/**
 * Get the most recent price for a station
 */
export async function getLatestStationPrice(
  stationId: string
): Promise<StationPrice | null> {
  const prices = await getStationPrices(stationId);
  if (prices.length === 0) return null;

  // Sort by timestamp descending and return the most recent
  return prices.sort((a, b) => b.timestamp - a.timestamp)[0];
}

/**
 * Add a new price update for a station
 */
export async function addStationPrice(price: Omit<StationPrice, "timestamp">): Promise<void> {
  try {
    const data = await AsyncStorage.getItem(STORAGE_KEY);
    const allPrices: Record<string, StationPrice[]> = data ? JSON.parse(data) : {};

    const newPrice: StationPrice = {
      ...price,
      timestamp: Date.now(),
    };

    if (!allPrices[price.stationId]) {
      allPrices[price.stationId] = [];
    }

    // Add new price and keep only the most recent MAX_HISTORY_PER_STATION entries
    allPrices[price.stationId].push(newPrice);
    allPrices[price.stationId] = allPrices[price.stationId]
      .sort((a, b) => b.timestamp - a.timestamp)
      .slice(0, MAX_HISTORY_PER_STATION);

    await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(allPrices));
  } catch (error) {
    console.error("Failed to add station price:", error);
    throw error;
  }
}

/**
 * Get average prices for a station from user submissions
 */
export async function getAverageStationPrices(
  stationId: string
): Promise<{
  e85Price?: number;
  octane87Price?: number;
  octane89Price?: number;
  octane9194Price?: number;
} | null> {
  const prices = await getStationPrices(stationId);
  if (prices.length === 0) return null;

  const sums = {
    e85: { sum: 0, count: 0 },
    octane87: { sum: 0, count: 0 },
    octane89: { sum: 0, count: 0 },
    octane9194: { sum: 0, count: 0 },
  };

  prices.forEach((price) => {
    if (price.e85Price !== undefined) {
      sums.e85.sum += price.e85Price;
      sums.e85.count++;
    }
    if (price.octane87Price !== undefined) {
      sums.octane87.sum += price.octane87Price;
      sums.octane87.count++;
    }
    if (price.octane89Price !== undefined) {
      sums.octane89.sum += price.octane89Price;
      sums.octane89.count++;
    }
    if (price.octane9194Price !== undefined) {
      sums.octane9194.sum += price.octane9194Price;
      sums.octane9194.count++;
    }
  });

  return {
    e85Price: sums.e85.count > 0 ? Math.round((sums.e85.sum / sums.e85.count) * 100) / 100 : undefined,
    octane87Price: sums.octane87.count > 0 ? Math.round((sums.octane87.sum / sums.octane87.count) * 100) / 100 : undefined,
    octane89Price: sums.octane89.count > 0 ? Math.round((sums.octane89.sum / sums.octane89.count) * 100) / 100 : undefined,
    octane9194Price: sums.octane9194.count > 0 ? Math.round((sums.octane9194.sum / sums.octane9194.count) * 100) / 100 : undefined,
  };
}

/**
 * Returns true if a price timestamp is older than 7 days
 */
export function isPriceStale(timestamp: number): boolean {
  const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;
  return Date.now() - timestamp > SEVEN_DAYS_MS;
}

/**
 * Format timestamp as human-readable string
 */
export function formatPriceAge(timestamp: number): string {
  const now = Date.now();
  const diffMs = now - timestamp;
  const diffMins = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMs / 3600000);
  const diffDays = Math.floor(diffMs / 86400000);

  if (diffMins < 1) return "Just now";
  if (diffMins < 60) return `${diffMins}m ago`;
  if (diffHours < 24) return `${diffHours}h ago`;
  if (diffDays < 7) return `${diffDays}d ago`;

  return new Date(timestamp).toLocaleDateString();
}

/**
 * Clear all price history for a station
 */
export async function clearStationPrices(stationId: string): Promise<void> {
  try {
    const data = await AsyncStorage.getItem(STORAGE_KEY);
    if (!data) return;

    const allPrices: Record<string, StationPrice[]> = JSON.parse(data);
    delete allPrices[stationId];

    await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(allPrices));
  } catch (error) {
    console.error("Failed to clear station prices:", error);
  }
}

/**
 * Station Prices Module
 * Manages crowdsourced fuel prices submitted by users
 */

import AsyncStorage from "@react-native-async-storage/async-storage";

export interface StationPrice {
  stationId: string;
  e85Price?: number;
  gasolinePrice?: number;
  timestamp: number; // milliseconds since epoch
  userId?: string; // Anonymous by default
}

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
): Promise<{ e85Price?: number; gasolinePrice?: number } | null> {
  const prices = await getStationPrices(stationId);
  if (prices.length === 0) return null;

  let e85Sum = 0;
  let e85Count = 0;
  let gasSum = 0;
  let gasCount = 0;

  prices.forEach((price) => {
    if (price.e85Price !== undefined) {
      e85Sum += price.e85Price;
      e85Count++;
    }
    if (price.gasolinePrice !== undefined) {
      gasSum += price.gasolinePrice;
      gasCount++;
    }
  });

  return {
    e85Price: e85Count > 0 ? Math.round((e85Sum / e85Count) * 100) / 100 : undefined,
    gasolinePrice: gasCount > 0 ? Math.round((gasSum / gasCount) * 100) / 100 : undefined,
  };
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

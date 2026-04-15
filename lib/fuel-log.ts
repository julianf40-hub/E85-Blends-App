/**
 * Fuel Log Storage
 * Tracks every fuel-up: date, location, blend, gallons, price, odometer, MPG
 */

import AsyncStorage from "@react-native-async-storage/async-storage";

export interface FuelEntry {
  id: string;
  date: string; // ISO 8601
  stationName: string;
  stationId?: string;
  latitude?: number;
  longitude?: number;
  blendRatio: number; // E20-E85 (ethanol %)
  gallonsAdded: number; // total gallons (e85Gallons + gasGallons)
  e85Gallons?: number; // gallons of E85 added
  gasGallons?: number; // gallons of regular gas added
  gasOctane?: number; // octane rating of the gasoline used (87, 89, 91, 93)
  e85PricePerGallon?: number; // price per gallon of E85
  gasPricePerGallon?: number; // price per gallon of regular gas
  gasOctane?: "87" | "89" | "91/92" | "93";
  pricePerGallon: number; // blended average price per gallon
  totalPrice: number;
  odometer: number;
  mpg?: number; // calculated from previous entry
  currentEthanolPct?: number; // ethanol % already in tank at time of fill-up
  notes?: string;
  fuelQuality?: "excellent" | "good" | "fair" | "poor";
}

const FUEL_LOG_KEY = "e85_fuel_log";

/**
 * Load all fuel entries from AsyncStorage
 */
export async function loadFuelLog(): Promise<FuelEntry[]> {
  try {
    const stored = await AsyncStorage.getItem(FUEL_LOG_KEY);
    if (stored) {
      const entries = JSON.parse(stored) as FuelEntry[];
      // Sort by date descending (newest first)
      return entries.sort(
        (a, b) => new Date(b.date).getTime() - new Date(a.date).getTime()
      );
    }
    return [];
  } catch (error) {
    console.warn("Failed to load fuel log:", error);
    return [];
  }
}

/**
 * Add a new fuel entry
 */
export async function addFuelEntry(entry: Omit<FuelEntry, "id">): Promise<FuelEntry> {
  const entries = await loadFuelLog();
  const newEntry: FuelEntry = {
    ...entry,
    id: Date.now().toString(),
  };

  // Calculate MPG if we have a previous entry
  if (entries.length > 0) {
    const previousEntry = entries[0]; // Most recent entry (already sorted)
    const milesDriven = entry.odometer - previousEntry.odometer;
    if (milesDriven > 0) {
      newEntry.mpg = milesDriven / entry.gallonsAdded;
    }
  }

  entries.unshift(newEntry);
  await AsyncStorage.setItem(FUEL_LOG_KEY, JSON.stringify(entries));
  return newEntry;
}

/**
 * Update an existing fuel entry
 */
export async function updateFuelEntry(id: string, updates: Partial<FuelEntry>): Promise<FuelEntry | null> {
  const entries = await loadFuelLog();
  const index = entries.findIndex((e) => e.id === id);
  if (index === -1) return null;

  entries[index] = { ...entries[index], ...updates };
  await AsyncStorage.setItem(FUEL_LOG_KEY, JSON.stringify(entries));
  return entries[index];
}

/**
 * Delete a fuel entry
 */
export async function deleteFuelEntry(id: string): Promise<boolean> {
  const entries = await loadFuelLog();
  const filtered = entries.filter((e) => e.id !== id);
  if (filtered.length === entries.length) return false;
  await AsyncStorage.setItem(FUEL_LOG_KEY, JSON.stringify(filtered));
  return true;
}

/**
 * Get fuel entries for a specific date range
 */
export async function getFuelEntriesByDateRange(
  startDate: Date,
  endDate: Date
): Promise<FuelEntry[]> {
  const entries = await loadFuelLog();
  return entries.filter((e) => {
    const entryDate = new Date(e.date);
    return entryDate >= startDate && entryDate <= endDate;
  });
}

/**
 * Get fuel entries by blend ratio
 */
export async function getFuelEntriesByBlend(blendRatio: number): Promise<FuelEntry[]> {
  const entries = await loadFuelLog();
  return entries.filter((e) => e.blendRatio === blendRatio);
}

/**
 * Calculate average MPG across all entries
 */
export async function getAverageMPG(): Promise<number> {
  const entries = await loadFuelLog();
  const entriesWithMPG = entries.filter((e) => e.mpg && e.mpg > 0);
  if (entriesWithMPG.length === 0) return 0;
  const sum = entriesWithMPG.reduce((acc, e) => acc + (e.mpg || 0), 0);
  return sum / entriesWithMPG.length;
}

/**
 * Calculate average MPG for a specific blend
 */
export async function getAverageMPGByBlend(blendRatio: number): Promise<number> {
  const entries = await getFuelEntriesByBlend(blendRatio);
  const entriesWithMPG = entries.filter((e) => e.mpg && e.mpg > 0);
  if (entriesWithMPG.length === 0) return 0;
  const sum = entriesWithMPG.reduce((acc, e) => acc + (e.mpg || 0), 0);
  return sum / entriesWithMPG.length;
}

/**
 * Calculate total spent on E85
 */
export async function getTotalSpent(): Promise<number> {
  const entries = await loadFuelLog();
  return entries.reduce((sum, e) => sum + e.totalPrice, 0);
}

/**
 * Calculate total gallons purchased
 */
export async function getTotalGallons(): Promise<number> {
  const entries = await loadFuelLog();
  return entries.reduce((sum, e) => sum + e.gallonsAdded, 0);
}

/**
 * Get fuel log statistics
 */
export async function getFuelLogStats() {
  const entries = await loadFuelLog();
  const avgMPG = await getAverageMPG();
  const totalSpent = await getTotalSpent();
  const totalGallons = await getTotalGallons();

  const blendStats: Record<number, { count: number; avgMPG: number }> = {};
  for (const blend of [20, 30, 40, 50, 60, 85]) {
    const entries = await getFuelEntriesByBlend(blend);
    const avgMPG = await getAverageMPGByBlend(blend);
    blendStats[blend] = {
      count: entries.length,
      avgMPG,
    };
  }

  return {
    totalEntries: entries.length,
    averageMPG: avgMPG,
    totalSpent,
    totalGallons,
    averagePricePerGallon: totalSpent / (totalGallons || 1),
    blendStats,
  };
}

/**
 * Clear all fuel log entries
 */
export async function clearFuelLog(): Promise<void> {
  await AsyncStorage.removeItem(FUEL_LOG_KEY);
}

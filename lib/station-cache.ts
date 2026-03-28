/**
 * Station Cache Utility
 *
 * Caches AFDC API results in AsyncStorage with a 30-minute TTL.
 * Cache key is derived from lat/lon (rounded to 2 decimal places) + radius,
 * so nearby searches within ~1km share the same cache bucket.
 */

import AsyncStorage from "@react-native-async-storage/async-storage";
import { E85Station } from "./station-data";

const CACHE_PREFIX = "station_cache_";
const CACHE_TTL_MS = 30 * 60 * 1000; // 30 minutes

interface CacheEntry {
  stations: E85Station[];
  timestamp: number;
  lat: number;
  lon: number;
  radius: number;
}

/**
 * Build a cache key from location + radius.
 * Rounds lat/lon to 2 decimal places (~1.1 km precision) so nearby
 * locations share the same cache bucket.
 */
function buildCacheKey(lat: number, lon: number, radius: number): string {
  const roundedLat = Math.round(lat * 100) / 100;
  const roundedLon = Math.round(lon * 100) / 100;
  return `${CACHE_PREFIX}${roundedLat}_${roundedLon}_${radius}`;
}

/**
 * Read cached stations for a given location + radius.
 * Returns null if no cache exists or if the cache is older than TTL.
 */
export async function getCachedStations(
  lat: number,
  lon: number,
  radius: number
): Promise<E85Station[] | null> {
  try {
    const key = buildCacheKey(lat, lon, radius);
    const raw = await AsyncStorage.getItem(key);
    if (!raw) return null;

    const entry: CacheEntry = JSON.parse(raw);
    const age = Date.now() - entry.timestamp;

    if (age > CACHE_TTL_MS) {
      // Stale — remove and return null
      await AsyncStorage.removeItem(key);
      return null;
    }

    return entry.stations;
  } catch {
    return null;
  }
}

/**
 * Write stations to cache for a given location + radius.
 */
export async function setCachedStations(
  lat: number,
  lon: number,
  radius: number,
  stations: E85Station[]
): Promise<void> {
  try {
    const key = buildCacheKey(lat, lon, radius);
    const entry: CacheEntry = {
      stations,
      timestamp: Date.now(),
      lat,
      lon,
      radius,
    };
    await AsyncStorage.setItem(key, JSON.stringify(entry));
  } catch {
    // Cache write failure is non-fatal
  }
}

/**
 * Invalidate (delete) the cache entry for a specific location + radius.
 * Call this when the user manually refreshes.
 */
export async function invalidateStationCache(
  lat: number,
  lon: number,
  radius: number
): Promise<void> {
  try {
    const key = buildCacheKey(lat, lon, radius);
    await AsyncStorage.removeItem(key);
  } catch {
    // Non-fatal
  }
}

/**
 * Clear all station cache entries.
 */
export async function clearStationCache(): Promise<void> {
  try {
    const keys = await AsyncStorage.getAllKeys();
    const cacheKeys = keys.filter((k) => k.startsWith(CACHE_PREFIX));
    if (cacheKeys.length > 0) {
      await AsyncStorage.multiRemove(cacheKeys);
    }
  } catch {
    // Non-fatal
  }
}

/**
 * Get the age of the cache entry in minutes, or null if no cache.
 */
export async function getStationCacheAge(
  lat: number,
  lon: number,
  radius: number
): Promise<number | null> {
  try {
    const key = buildCacheKey(lat, lon, radius);
    const raw = await AsyncStorage.getItem(key);
    if (!raw) return null;
    const entry: CacheEntry = JSON.parse(raw);
    return Math.floor((Date.now() - entry.timestamp) / 60000);
  } catch {
    return null;
  }
}

/**
 * Station Favorites & History Storage
 * Track favorite stations and visit history
 */

import AsyncStorage from "@react-native-async-storage/async-storage";

export interface StationFavorite {
  stationId: string;
  stationName: string;
  city: string;
  state: string;
  latitude: number;
  longitude: number;
  addedDate: string; // ISO 8601
  rating?: number; // 1-5 stars
  notes?: string;
}

export interface StationVisit {
  stationId: string;
  stationName: string;
  visitDate: string; // ISO 8601
  blendUsed: number;
  gallonsAdded: number;
  pricePerGallon: number;
}

const FAVORITES_KEY = "e85_station_favorites";
const HISTORY_KEY = "e85_station_history";

/**
 * Load all favorite stations
 */
export async function loadFavorites(): Promise<StationFavorite[]> {
  try {
    const stored = await AsyncStorage.getItem(FAVORITES_KEY);
    if (stored) {
      return JSON.parse(stored);
    }
    return [];
  } catch (error) {
    console.warn("Failed to load favorites:", error);
    return [];
  }
}

/**
 * Add a station to favorites
 */
export async function addFavorite(station: StationFavorite): Promise<void> {
  const favorites = await loadFavorites();
  const exists = favorites.some((f) => f.stationId === station.stationId);
  if (!exists) {
    favorites.push(station);
    await AsyncStorage.setItem(FAVORITES_KEY, JSON.stringify(favorites));
  }
}

/**
 * Remove a station from favorites
 */
export async function removeFavorite(stationId: string): Promise<void> {
  const favorites = await loadFavorites();
  const filtered = favorites.filter((f) => f.stationId !== stationId);
  await AsyncStorage.setItem(FAVORITES_KEY, JSON.stringify(filtered));
}

/**
 * Check if a station is favorited
 */
export async function isFavorited(stationId: string): Promise<boolean> {
  const favorites = await loadFavorites();
  return favorites.some((f) => f.stationId === stationId);
}

/**
 * Update a favorite station (e.g., rating, notes)
 */
export async function updateFavorite(
  stationId: string,
  updates: Partial<StationFavorite>
): Promise<StationFavorite | null> {
  const favorites = await loadFavorites();
  const index = favorites.findIndex((f) => f.stationId === stationId);
  if (index === -1) return null;

  favorites[index] = { ...favorites[index], ...updates };
  await AsyncStorage.setItem(FAVORITES_KEY, JSON.stringify(favorites));
  return favorites[index];
}

/**
 * Load station visit history
 */
export async function loadHistory(): Promise<StationVisit[]> {
  try {
    const stored = await AsyncStorage.getItem(HISTORY_KEY);
    if (stored) {
      const visits = JSON.parse(stored) as StationVisit[];
      // Sort by date descending (newest first)
      return visits.sort(
        (a, b) => new Date(b.visitDate).getTime() - new Date(a.visitDate).getTime()
      );
    }
    return [];
  } catch (error) {
    console.warn("Failed to load history:", error);
    return [];
  }
}

/**
 * Add a station visit to history
 */
export async function addVisit(visit: StationVisit): Promise<void> {
  const history = await loadHistory();
  history.unshift(visit);
  // Keep only last 100 visits to avoid storage bloat
  if (history.length > 100) {
    history.pop();
  }
  await AsyncStorage.setItem(HISTORY_KEY, JSON.stringify(history));
}

/**
 * Get visit history for a specific station
 */
export async function getStationVisits(stationId: string): Promise<StationVisit[]> {
  const history = await loadHistory();
  return history.filter((v) => v.stationId === stationId);
}

/**
 * Get most visited stations
 */
export async function getMostVisitedStations(limit: number = 10): Promise<Array<{
  stationId: string;
  stationName: string;
  visitCount: number;
  lastVisit: string;
}>> {
  const history = await loadHistory();
  const stationMap = new Map<string, { count: number; lastVisit: string; name: string }>();

  for (const visit of history) {
    const existing = stationMap.get(visit.stationId);
    if (existing) {
      existing.count++;
      existing.lastVisit = visit.visitDate;
    } else {
      stationMap.set(visit.stationId, {
        count: 1,
        lastVisit: visit.visitDate,
        name: visit.stationName,
      });
    }
  }

  return Array.from(stationMap.entries())
    .map(([stationId, data]) => ({
      stationId,
      stationName: data.name,
      visitCount: data.count,
      lastVisit: data.lastVisit,
    }))
    .sort((a, b) => b.visitCount - a.visitCount)
    .slice(0, limit);
}

/**
 * Clear all history
 */
export async function clearHistory(): Promise<void> {
  await AsyncStorage.removeItem(HISTORY_KEY);
}

/**
 * Clear all favorites
 */
export async function clearFavorites(): Promise<void> {
  await AsyncStorage.removeItem(FAVORITES_KEY);
}

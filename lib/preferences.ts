/**
 * User Preferences Storage
 * Persists user settings like tank size, octane rating, units, and search radius
 */

import AsyncStorage from "@react-native-async-storage/async-storage";

export interface UserPreferences {
  tankSize: number; // gallons
  preferredOctane: number; // 87, 91, 93, 98
  units: "imperial" | "metric"; // gallons/liters
  searchRadius: number; // miles
  defaultBlend: number; // E20-E85
  vehicleName?: string;
  vehicleYear?: number;
  vehicleMake?: string;
  vehicleModel?: string;
  mpgRegularGas?: number;
  mpgE85?: number;
  homeScreen?: "calculator" | "garage"; // default landing tab
  showReminders?: boolean; // visibility toggle for Reminders tab
  showGarage?: boolean; // visibility toggle for Garage tab
  showGear?: boolean; // visibility toggle for Recommended Gear tab
  directionsApp?: "apple" | "google" | "waze"; // preferred navigation app
  appLayoutMode?: "simple" | "full"; // onboarding layout preset (can be changed later)
}

const PREFERENCES_KEY = "e85_user_preferences";

const DEFAULT_PREFERENCES: UserPreferences = {
  tankSize: 16,
  preferredOctane: 91,
  units: "imperial",
  searchRadius: 25,
  defaultBlend: 30,
  homeScreen: "calculator",
  showReminders: true,
  showGarage: true,
  showGear: true,
  directionsApp: "apple",
  appLayoutMode: "full",
};

export function applyLayoutModeToPreferences(
  prefs: UserPreferences,
  mode: "simple" | "full",
): UserPreferences {
  if (mode === "simple") {
    return {
      ...prefs,
      appLayoutMode: "simple",
      homeScreen: "calculator",
      showGarage: false,
      showReminders: false,
      showGear: false,
    };
  }

  return {
    ...prefs,
    appLayoutMode: "full",
    showGarage: true,
    showReminders: true,
    showGear: true,
  };
}

/**
 * Load user preferences from AsyncStorage
 */
export async function loadPreferences(): Promise<UserPreferences> {
  try {
    const stored = await AsyncStorage.getItem(PREFERENCES_KEY);
    if (stored) {
      return JSON.parse(stored);
    }
    return DEFAULT_PREFERENCES;
  } catch (error) {
    console.warn("Failed to load preferences:", error);
    return DEFAULT_PREFERENCES;
  }
}

/**
 * Save user preferences to AsyncStorage
 */
export async function savePreferences(prefs: UserPreferences): Promise<void> {
  try {
    await AsyncStorage.setItem(PREFERENCES_KEY, JSON.stringify(prefs));
  } catch (error) {
    console.error("Failed to save preferences:", error);
    throw error;
  }
}

/**
 * Update a single preference field
 */
export async function updatePreference<K extends keyof UserPreferences>(
  key: K,
  value: UserPreferences[K]
): Promise<UserPreferences> {
  const prefs = await loadPreferences();
  prefs[key] = value;
  await savePreferences(prefs);
  return prefs;
}

/**
 * Reset preferences to defaults
 */
export async function resetPreferences(): Promise<UserPreferences> {
  await savePreferences(DEFAULT_PREFERENCES);
  return DEFAULT_PREFERENCES;
}

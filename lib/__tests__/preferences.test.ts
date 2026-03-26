import { describe, it, expect, beforeEach, vi } from "vitest";
import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  loadPreferences,
  savePreferences,
  updatePreference,
  resetPreferences,
  UserPreferences,
} from "../preferences";

vi.mock("@react-native-async-storage/async-storage");

describe("Preferences Storage", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    (AsyncStorage.getItem as any).mockResolvedValue(null);
    (AsyncStorage.setItem as any).mockResolvedValue(undefined);
  });

  it("should load default preferences when storage is empty", async () => {
    (AsyncStorage.getItem as any).mockResolvedValue(null);
    const prefs = await loadPreferences();
    expect(prefs.tankSize).toBe(16);
    expect(prefs.preferredOctane).toBe(91);
    expect(prefs.units).toBe("imperial");
    expect(prefs.searchRadius).toBe(25);
    expect(prefs.defaultBlend).toBe(30);
  });

  it("should save preferences to storage", async () => {
    const prefs: UserPreferences = {
      tankSize: 20,
      preferredOctane: 93,
      units: "imperial",
      searchRadius: 50,
      defaultBlend: 40,
    };
    await savePreferences(prefs);
    expect(AsyncStorage.setItem).toHaveBeenCalledWith(
      "e85_user_preferences",
      JSON.stringify(prefs)
    );
  });

  it("should update a single preference", async () => {
    const defaultPrefs = {
      tankSize: 16,
      preferredOctane: 91,
      units: "imperial" as const,
      searchRadius: 25,
      defaultBlend: 30,
    };
    (AsyncStorage.getItem as any).mockResolvedValueOnce(JSON.stringify(defaultPrefs));
    const updated = await updatePreference("tankSize", 25);
    expect(updated.tankSize).toBe(25);
    expect(AsyncStorage.setItem).toHaveBeenCalled();
  });

  it("should reset preferences to defaults", async () => {
    vi.clearAllMocks();
    (AsyncStorage.getItem as any).mockResolvedValue(null);
    (AsyncStorage.setItem as any).mockResolvedValue(undefined);
    const reset = await resetPreferences();
    expect(reset.tankSize).toBe(16);
    expect(reset.preferredOctane).toBe(91);
  });

  it("should handle storage errors gracefully", async () => {
    vi.clearAllMocks();
    (AsyncStorage.getItem as any).mockRejectedValue(new Error("Storage error"));
    const prefs = await loadPreferences();
    expect(prefs.tankSize).toBe(16); // Should return defaults
  });
});

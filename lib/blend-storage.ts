import AsyncStorage from "@react-native-async-storage/async-storage";
import { BlendInputs, BlendResult } from "./blend-calculator";

const STORAGE_KEY = "e85_saved_blends";
const SETTINGS_KEY = "e85_settings";

export interface SavedBlend {
  id: string;
  date: string;
  inputs: BlendInputs;
  result: BlendResult;
  name?: string;
  isFavorite: boolean;
}

export interface AppSettings {
  defaultTankSize: number;
  defaultE85Ethanol: number;
  defaultGasEthanol: number;
  defaultGasOctane: number;
  defaultE85Octane: number;
  unitSystem: "us" | "metric";
}

export const DEFAULT_SETTINGS: AppSettings = {
  defaultTankSize: 16,
  defaultE85Ethanol: 85,
  defaultGasEthanol: 10,
  defaultGasOctane: 93,
  defaultE85Octane: 105,
  unitSystem: "us",
};

export async function getSavedBlends(): Promise<SavedBlend[]> {
  try {
    const data = await AsyncStorage.getItem(STORAGE_KEY);
    if (data) {
      return JSON.parse(data);
    }
    return [];
  } catch {
    return [];
  }
}

export async function saveBlend(
  inputs: BlendInputs,
  result: BlendResult,
  name?: string
): Promise<SavedBlend> {
  const blends = await getSavedBlends();
  const newBlend: SavedBlend = {
    id: Date.now().toString(),
    date: new Date().toISOString(),
    inputs,
    result,
    name,
    isFavorite: false,
  };
  blends.unshift(newBlend);
  await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(blends));
  return newBlend;
}

export async function deleteBlend(id: string): Promise<void> {
  const blends = await getSavedBlends();
  const filtered = blends.filter((b) => b.id !== id);
  await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(filtered));
}

export async function toggleFavorite(id: string): Promise<void> {
  const blends = await getSavedBlends();
  const blend = blends.find((b) => b.id === id);
  if (blend) {
    blend.isFavorite = !blend.isFavorite;
    await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(blends));
  }
}

export async function clearAllBlends(): Promise<void> {
  await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify([]));
}

export async function getSettings(): Promise<AppSettings> {
  try {
    const data = await AsyncStorage.getItem(SETTINGS_KEY);
    if (data) {
      return { ...DEFAULT_SETTINGS, ...JSON.parse(data) };
    }
    return DEFAULT_SETTINGS;
  } catch {
    return DEFAULT_SETTINGS;
  }
}

export async function saveSettings(settings: AppSettings): Promise<void> {
  await AsyncStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
}

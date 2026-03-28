import AsyncStorage from "@react-native-async-storage/async-storage";

const GARAGE_KEY = "@e85_garage_profiles";
const ACTIVE_CAR_KEY = "@e85_active_car_id";

export interface CarProfile {
  id: string;
  /** Display name, e.g. "Daily Driver" */
  nickname: string;
  year: string;
  make: string;
  model: string;
  trim: string;
  /** Tank capacity in gallons */
  tankSize: number;
  /** City MPG on E85 */
  mpgE85: number;
  /** City MPG on regular gas */
  mpgGas: number;
  /** Minimum octane rating the car requires */
  requiredOctane: number;
  /** Whether the car is a flex-fuel vehicle */
  isFlexFuel: boolean;
  /** Default target blend percentage (20-85) */
  defaultBlend: number;
  /** Hex color for the car card accent */
  color: string;
  /** Emoji icon for the car card */
  icon: string;
  /** Current odometer reading in miles */
  odometer: number;
  createdAt: string;
  updatedAt: string;
}

export type NewCarProfile = Omit<CarProfile, "id" | "createdAt" | "updatedAt">;

const CAR_COLORS = [
  "#10B981", // green
  "#3B82F6", // blue
  "#F59E0B", // amber
  "#EF4444", // red
  "#8B5CF6", // purple
  "#EC4899", // pink
  "#14B8A6", // teal
  "#F97316", // orange
];

const CAR_ICONS = ["🚗", "🏎️", "🚙", "🛻", "🚕", "⚡", "🔥", "💨"];

export function getRandomCarColor(): string {
  return CAR_COLORS[Math.floor(Math.random() * CAR_COLORS.length)];
}

export function getRandomCarIcon(): string {
  return CAR_ICONS[Math.floor(Math.random() * CAR_ICONS.length)];
}

export const DEFAULT_CAR: NewCarProfile = {
  nickname: "",
  year: new Date().getFullYear().toString(),
  make: "",
  model: "",
  trim: "",
  tankSize: 16,
  mpgE85: 22,
  mpgGas: 28,
  requiredOctane: 87,
  isFlexFuel: false,
  defaultBlend: 30,
  color: CAR_COLORS[0],
  icon: "🚗",
  odometer: 0,
};

/** Load all car profiles from storage */
export async function loadGarage(): Promise<CarProfile[]> {
  try {
    const raw = await AsyncStorage.getItem(GARAGE_KEY);
    if (!raw) return [];
    return JSON.parse(raw) as CarProfile[];
  } catch {
    return [];
  }
}

/** Save the full garage array to storage */
async function saveGarage(profiles: CarProfile[]): Promise<void> {
  await AsyncStorage.setItem(GARAGE_KEY, JSON.stringify(profiles));
}

/** Add a new car profile */
export async function addCarProfile(
  data: NewCarProfile
): Promise<CarProfile> {
  const profiles = await loadGarage();
  const now = new Date().toISOString();
  const newProfile: CarProfile = {
    ...data,
    id: `car_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`,
    createdAt: now,
    updatedAt: now,
  };
  profiles.push(newProfile);
  await saveGarage(profiles);
  // If this is the first car, set it as active
  if (profiles.length === 1) {
    await setActiveCarId(newProfile.id);
  }
  return newProfile;
}

/** Update an existing car profile */
export async function updateCarProfile(
  id: string,
  data: Partial<NewCarProfile>
): Promise<CarProfile | null> {
  const profiles = await loadGarage();
  const index = profiles.findIndex((p) => p.id === id);
  if (index === -1) return null;
  const updated: CarProfile = {
    ...profiles[index],
    ...data,
    updatedAt: new Date().toISOString(),
  };
  profiles[index] = updated;
  await saveGarage(profiles);
  return updated;
}

/** Delete a car profile by id */
export async function deleteCarProfile(id: string): Promise<void> {
  const profiles = await loadGarage();
  const filtered = profiles.filter((p) => p.id !== id);
  await saveGarage(filtered);
  // If deleted car was active, set first remaining car as active
  const activeId = await getActiveCarId();
  if (activeId === id) {
    if (filtered.length > 0) {
      await setActiveCarId(filtered[0].id);
    } else {
      await AsyncStorage.removeItem(ACTIVE_CAR_KEY);
    }
  }
}

/** Get the active car id */
export async function getActiveCarId(): Promise<string | null> {
  try {
    return await AsyncStorage.getItem(ACTIVE_CAR_KEY);
  } catch {
    return null;
  }
}

/** Set the active car id */
export async function setActiveCarId(id: string): Promise<void> {
  await AsyncStorage.setItem(ACTIVE_CAR_KEY, id);
}

/** Get the active car profile */
export async function getActiveCar(): Promise<CarProfile | null> {
  const activeId = await getActiveCarId();
  if (!activeId) return null;
  const profiles = await loadGarage();
  return profiles.find((p) => p.id === activeId) ?? null;
}

/** Clear all garage data */
export async function clearGarage(): Promise<void> {
  await AsyncStorage.multiRemove([GARAGE_KEY, ACTIVE_CAR_KEY]);
}

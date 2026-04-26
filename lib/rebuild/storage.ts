import AsyncStorage from "@react-native-async-storage/async-storage";

const REMINDERS_KEY = "rebuild_reminders_v1";
const LOG_KEY = "rebuild_fuel_log_v1";

export type ReminderItem = { id: string; title: string; dueInDays: number; enabled: boolean };
export type FuelLogItem = { id: string; date: string; station: string; blend: string; gallons: number; total: number };

export async function loadReminders(): Promise<ReminderItem[]> {
  const raw = await AsyncStorage.getItem(REMINDERS_KEY);
  return raw ? JSON.parse(raw) : [
    { id: "1", title: "Check ethanol content", dueInDays: 7, enabled: true },
    { id: "2", title: "Log fuel-up", dueInDays: 1, enabled: true },
  ];
}

export async function saveReminders(items: ReminderItem[]) {
  await AsyncStorage.setItem(REMINDERS_KEY, JSON.stringify(items));
}

export async function loadFuelLog(): Promise<FuelLogItem[]> {
  const raw = await AsyncStorage.getItem(LOG_KEY);
  return raw ? JSON.parse(raw) : [];
}

export async function saveFuelLog(items: FuelLogItem[]) {
  await AsyncStorage.setItem(LOG_KEY, JSON.stringify(items));
}

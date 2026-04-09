/**
 * Reminders Storage
 * Maintenance reminders triggered by mileage and/or date, per car profile.
 */

import AsyncStorage from "@react-native-async-storage/async-storage";

const REMINDERS_KEY = "@e85_reminders";

export type ReminderCategory =
  | "oil_change"
  | "tire_rotation"
  | "air_filter"
  | "spark_plugs"
  | "transmission"
  | "brake_fluid"
  | "coolant"
  | "insurance"
  | "registration"
  | "maintenance"
  | "other";

export const REMINDER_CATEGORIES: {
  id: ReminderCategory;
  label: string;
  icon: string;
  color: string;
}[] = [
  { id: "oil_change", label: "Oil Change", icon: "🛢️", color: "#F59E0B" },
  { id: "tire_rotation", label: "Tire Rotation", icon: "🔄", color: "#3B82F6" },
  { id: "air_filter", label: "Air Filter", icon: "💨", color: "#10B981" },
  { id: "spark_plugs", label: "Spark Plugs", icon: "⚡", color: "#8B5CF6" },
  { id: "transmission", label: "Transmission", icon: "⚙️", color: "#EC4899" },
  { id: "brake_fluid", label: "Brake Fluid", icon: "🛑", color: "#EF4444" },
  { id: "coolant", label: "Coolant", icon: "🌡️", color: "#14B8A6" },
  { id: "insurance", label: "Insurance", icon: "📋", color: "#6366F1" },
  { id: "registration", label: "Registration", icon: "📄", color: "#F97316" },
  { id: "maintenance", label: "Maintenance", icon: "🔧", color: "#8B5CF6" },
  { id: "other", label: "Other", icon: "📌", color: "#687076" },
];

export interface Reminder {
  id: string;
  carId: string; // links to CarProfile.id
  name: string;
  category: ReminderCategory;

  // Mileage-based trigger
  mileageEnabled: boolean;
  nextReminderMileage?: number; // absolute odometer reading
  repeatMileageInterval?: number; // miles between repeats (e.g. 5000)

  // Date-based trigger
  dateEnabled: boolean;
  nextReminderDate?: string; // ISO 8601 date string
  repeatDateInterval?: number; // days between repeats

  completedAt?: string; // ISO 8601, set when marked done
  createdAt: string;
  updatedAt: string;
}

export type NewReminder = Omit<Reminder, "id" | "createdAt" | "updatedAt" | "completedAt">;

/**
 * Load all reminders from AsyncStorage
 */
export async function loadReminders(): Promise<Reminder[]> {
  try {
    const stored = await AsyncStorage.getItem(REMINDERS_KEY);
    if (stored) {
      return JSON.parse(stored) as Reminder[];
    }
    return [];
  } catch (error) {
    console.warn("Failed to load reminders:", error);
    return [];
  }
}

/**
 * Load reminders for a specific car
 */
export async function loadRemindersForCar(carId: string): Promise<Reminder[]> {
  const all = await loadReminders();
  return all.filter((r) => r.carId === carId);
}

/**
 * Save a new reminder
 */
export async function addReminder(reminder: NewReminder): Promise<Reminder> {
  const all = await loadReminders();
  const now = new Date().toISOString();
  const newReminder: Reminder = {
    ...reminder,
    id: `reminder_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`,
    createdAt: now,
    updatedAt: now,
  };
  await AsyncStorage.setItem(REMINDERS_KEY, JSON.stringify([...all, newReminder]));
  return newReminder;
}

/**
 * Update an existing reminder
 */
export async function updateReminder(
  id: string,
  updates: Partial<Omit<Reminder, "id" | "createdAt">>
): Promise<void> {
  const all = await loadReminders();
  const updated = all.map((r) =>
    r.id === id ? { ...r, ...updates, updatedAt: new Date().toISOString() } : r
  );
  await AsyncStorage.setItem(REMINDERS_KEY, JSON.stringify(updated));
}

/**
 * Delete a reminder
 */
export async function deleteReminder(id: string): Promise<void> {
  const all = await loadReminders();
  await AsyncStorage.setItem(
    REMINDERS_KEY,
    JSON.stringify(all.filter((r) => r.id !== id))
  );
}

/**
 * Mark a reminder as complete and optionally advance to next interval
 */
export async function completeReminder(id: string, currentMileage: number): Promise<void> {
  const all = await loadReminders();
  const reminder = all.find((r) => r.id === id);
  if (!reminder) return;

  const now = new Date().toISOString();
  const updates: Partial<Reminder> = { completedAt: now, updatedAt: now };

  // Advance mileage trigger if repeat is set
  if (reminder.mileageEnabled && reminder.repeatMileageInterval) {
    updates.nextReminderMileage = currentMileage + reminder.repeatMileageInterval;
    updates.completedAt = undefined; // reset so it shows as active again
  }

  // Advance date trigger if repeat is set
  if (reminder.dateEnabled && reminder.repeatDateInterval && reminder.nextReminderDate) {
    const nextDate = new Date(reminder.nextReminderDate);
    nextDate.setDate(nextDate.getDate() + reminder.repeatDateInterval);
    updates.nextReminderDate = nextDate.toISOString().split("T")[0];
    updates.completedAt = undefined;
  }

  const updated = all.map((r) => (r.id === id ? { ...r, ...updates } : r));
  await AsyncStorage.setItem(REMINDERS_KEY, JSON.stringify(updated));
}

/**
 * Advance/complete mileage-based reminders for a car when a new odometer value is logged.
 * Returns number of reminders that were processed.
 */
export async function syncMileageRemindersForCar(
  carId: string,
  odometer: number
): Promise<number> {
  const reminders = await loadRemindersForCar(carId);
  let processed = 0;

  for (const reminder of reminders) {
    if (
      reminder.mileageEnabled &&
      reminder.nextReminderMileage !== undefined &&
      !reminder.completedAt &&
      odometer >= reminder.nextReminderMileage
    ) {
      await completeReminder(reminder.id, odometer);
      processed += 1;
    }
  }

  return processed;
}

/**
 * Calculate urgency of a reminder given current mileage.
 * Returns miles remaining (negative = overdue) or days remaining for date-based.
 */
export function getReminderUrgency(
  reminder: Reminder,
  currentMileage: number
): { milesLeft?: number; daysLeft?: number; isOverdue: boolean } {
  let milesLeft: number | undefined;
  let daysLeft: number | undefined;
  let isOverdue = false;

  if (reminder.mileageEnabled && reminder.nextReminderMileage !== undefined) {
    milesLeft = reminder.nextReminderMileage - currentMileage;
    if (milesLeft <= 0) isOverdue = true;
  }

  if (reminder.dateEnabled && reminder.nextReminderDate) {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const due = new Date(reminder.nextReminderDate);
    due.setHours(0, 0, 0, 0);
    daysLeft = Math.round((due.getTime() - today.getTime()) / 86400000);
    if (daysLeft <= 0) isOverdue = true;
  }

  return { milesLeft, daysLeft, isOverdue };
}

/**
 * Sort reminders by urgency: overdue first, then by closest trigger
 */
export function sortRemindersByUrgency(
  reminders: Reminder[],
  currentMileage: number
): Reminder[] {
  return [...reminders].sort((a, b) => {
    const ua = getReminderUrgency(a, currentMileage);
    const ub = getReminderUrgency(b, currentMileage);

    // Overdue always first
    if (ua.isOverdue && !ub.isOverdue) return -1;
    if (!ua.isOverdue && ub.isOverdue) return 1;

    // Compare closest trigger
    const scoreA = Math.min(
      ua.milesLeft ?? Infinity,
      ua.daysLeft !== undefined ? ua.daysLeft * 50 : Infinity // rough conversion
    );
    const scoreB = Math.min(
      ub.milesLeft ?? Infinity,
      ub.daysLeft !== undefined ? ub.daysLeft * 50 : Infinity
    );
    return scoreA - scoreB;
  });
}

/**
 * Notification Service for Maintenance Reminders
 *
 * Handles:
 * - Permission requests
 * - Scheduling date-based reminder notifications
 * - Cancelling notifications when reminders are deleted or completed
 * - Android notification channel setup
 */

import * as Notifications from "expo-notifications";
import { Platform } from "react-native";
import type { Reminder } from "./reminders";

// ─── Notification Handler ─────────────────────────────────────────────────────
// Show notifications even when the app is in the foreground
Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowAlert: true,
    shouldPlaySound: true,
    shouldSetBadge: true,
    shouldShowBanner: true,
    shouldShowList: true,
  }),
});

// ─── Android Channel ──────────────────────────────────────────────────────────
const CHANNEL_ID = "maintenance-reminders";

export async function setupNotificationChannel(): Promise<void> {
  if (Platform.OS === "android") {
    await Notifications.setNotificationChannelAsync(CHANNEL_ID, {
      name: "Maintenance Reminders",
      description: "Alerts for upcoming and overdue vehicle maintenance",
      importance: Notifications.AndroidImportance.HIGH,
      vibrationPattern: [0, 250, 250, 250],
      lightColor: "#22C55E",
      sound: "default",
    });
  }
}

// ─── Permission ───────────────────────────────────────────────────────────────
export async function requestNotificationPermission(): Promise<boolean> {
  if (Platform.OS === "web") return false;

  const { status: existing } = await Notifications.getPermissionsAsync();
  if (existing === "granted") return true;

  const { status } = await Notifications.requestPermissionsAsync();
  return status === "granted";
}

export async function getNotificationPermissionStatus(): Promise<"granted" | "denied" | "undetermined"> {
  if (Platform.OS === "web") return "denied";
  const { status } = await Notifications.getPermissionsAsync();
  return status as "granted" | "denied" | "undetermined";
}

// ─── Identifier helpers ───────────────────────────────────────────────────────
// Each reminder gets a deterministic notification identifier so we can cancel it
function notifIdForReminder(reminderId: string): string {
  return `reminder-${reminderId}`;
}

// ─── Schedule ─────────────────────────────────────────────────────────────────
/**
 * Schedule a local notification for a date-based reminder.
 * Fires at 9 AM on the reminder's nextReminderDate.
 * Cancels any existing notification for the same reminder first.
 *
 * Only schedules if:
 * - reminder has dateEnabled and nextReminderDate set
 * - the date is in the future
 * - notification permission is granted
 */
export async function scheduleReminderNotification(reminder: Reminder): Promise<void> {
  if (Platform.OS === "web") return;
  if (!reminder.dateEnabled || !reminder.nextReminderDate) return;

  // Always cancel the old one first to avoid duplicates
  await cancelReminderNotification(reminder.id);

  const permission = await getNotificationPermissionStatus();
  if (permission !== "granted") return;

  const dueDate = new Date(reminder.nextReminderDate);
  dueDate.setHours(9, 0, 0, 0); // Fire at 9 AM on the due date

  const now = new Date();
  if (dueDate <= now) return; // Don't schedule for past dates

  // Also schedule a 3-day advance warning if the date is far enough out
  const warningDate = new Date(dueDate);
  warningDate.setDate(warningDate.getDate() - 3);

  if (warningDate > now) {
    await Notifications.scheduleNotificationAsync({
      identifier: `${notifIdForReminder(reminder.id)}-warning`,
      content: {
        title: `🔧 Upcoming: ${reminder.name}`,
        body: `Due in 3 days — ${new Date(reminder.nextReminderDate).toLocaleDateString("en-US", { month: "short", day: "numeric" })}`,
        data: { reminderId: reminder.id, type: "warning" },
        sound: "default",
      },
      trigger: {
        type: Notifications.SchedulableTriggerInputTypes.DATE,
        date: warningDate,
      },
    });
  }

  // Schedule the due-date notification
  await Notifications.scheduleNotificationAsync({
    identifier: notifIdForReminder(reminder.id),
    content: {
      title: `⚠️ Due Today: ${reminder.name}`,
      body: reminder.mileageEnabled && reminder.nextReminderMileage
        ? `Scheduled for ${reminder.nextReminderMileage.toLocaleString()} mi — tap to mark complete`
        : "Tap to mark complete",
      data: { reminderId: reminder.id, type: "due" },
      sound: "default",
    },
    trigger: {
      type: Notifications.SchedulableTriggerInputTypes.DATE,
      date: dueDate,
    },
  });
}

// ─── Cancel ───────────────────────────────────────────────────────────────────
/**
 * Cancel all scheduled notifications for a reminder (both due and warning).
 */
export async function cancelReminderNotification(reminderId: string): Promise<void> {
  if (Platform.OS === "web") return;
  await Promise.all([
    Notifications.cancelScheduledNotificationAsync(notifIdForReminder(reminderId)).catch(() => {}),
    Notifications.cancelScheduledNotificationAsync(`${notifIdForReminder(reminderId)}-warning`).catch(() => {}),
  ]);
}

// ─── Sync all reminders ───────────────────────────────────────────────────────
/**
 * Sync all reminder notifications — schedule for active date-based reminders,
 * cancel for completed ones. Call this on app start and after any reminder change.
 */
export async function syncAllReminderNotifications(reminders: Reminder[]): Promise<void> {
  if (Platform.OS === "web") return;

  const permission = await getNotificationPermissionStatus();
  if (permission !== "granted") return;

  await Promise.all(
    reminders.map(async (reminder) => {
      if (reminder.completedAt) {
        // Completed — cancel any pending notification
        await cancelReminderNotification(reminder.id);
      } else {
        // Active — schedule (or re-schedule) if date-based
        await scheduleReminderNotification(reminder);
      }
    })
  );
}

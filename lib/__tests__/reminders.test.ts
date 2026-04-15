import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  completeReminder,
  getReminderUrgency,
  Reminder,
} from "../reminders";

vi.mock("@react-native-async-storage/async-storage");

describe("Reminders behavior", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-04-14T12:00:00.000Z"));
    (AsyncStorage.setItem as any).mockResolvedValue(undefined);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("treats exactly-due mileage/date as due, not overdue", () => {
    const reminder: Reminder = {
      id: "r1",
      carId: "car_1",
      name: "Oil Change",
      category: "oil_change",
      mileageEnabled: true,
      nextReminderMileage: 50000,
      dateEnabled: true,
      nextReminderDate: "2026-04-14",
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    };

    const urgency = getReminderUrgency(reminder, 50000);
    expect(urgency.milesLeft).toBe(0);
    expect(urgency.daysLeft).toBe(0);
    expect(urgency.isOverdue).toBe(false);
  });

  it("marks reminder overdue only after threshold is passed", () => {
    const reminder: Reminder = {
      id: "r2",
      carId: "car_1",
      name: "Registration",
      category: "registration",
      mileageEnabled: true,
      nextReminderMileage: 50000,
      dateEnabled: true,
      nextReminderDate: "2026-04-14",
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    };

    const urgency = getReminderUrgency(reminder, 50010);
    expect(urgency.milesLeft).toBe(-10);
    expect(urgency.daysLeft).toBe(0);
    expect(urgency.isOverdue).toBe(true);
  });

  it("advances repeating date reminder from completion date, not stale due date", async () => {
    const reminders: Reminder[] = [
      {
        id: "r3",
        carId: "car_1",
        name: "Insurance",
        category: "insurance",
        mileageEnabled: false,
        dateEnabled: true,
        nextReminderDate: "2026-03-01",
        repeatDateInterval: 30,
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z",
      },
    ];
    (AsyncStorage.getItem as any).mockResolvedValue(JSON.stringify(reminders));

    await completeReminder("r3", 0);

    expect(AsyncStorage.setItem).toHaveBeenCalledTimes(1);
    const [, payload] = (AsyncStorage.setItem as any).mock.calls[0];
    const updated = JSON.parse(payload) as Reminder[];
    expect(updated[0].nextReminderDate).toBe("2026-05-14");
    expect(updated[0].completedAt).toBeUndefined();
  });
});

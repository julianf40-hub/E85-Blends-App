import { beforeEach, describe, expect, it, vi } from "vitest";
import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  addReminder,
  loadRemindersForCar,
  syncMileageRemindersForCar,
  type NewReminder,
} from "../reminders";

let mockStore: Record<string, string> = {};
vi.mock("@react-native-async-storage/async-storage", () => ({
  default: {
    getItem: vi.fn(async (key: string) => mockStore[key] ?? null),
    setItem: vi.fn(async (key: string, value: string) => {
      mockStore[key] = value;
    }),
    clear: vi.fn(async () => {
      mockStore = {};
    }),
  },
}));

const CAR_ID = "car_test_sync";

function baseReminder(overrides: Partial<NewReminder> = {}): NewReminder {
  return {
    carId: CAR_ID,
    name: "Oil Change",
    category: "oil_change",
    mileageEnabled: true,
    nextReminderMileage: 10000,
    repeatMileageInterval: undefined,
    dateEnabled: false,
    nextReminderDate: undefined,
    repeatDateInterval: undefined,
    ...overrides,
  };
}

describe("syncMileageRemindersForCar", () => {
  beforeEach(async () => {
    mockStore = {};
    await AsyncStorage.clear();
  });

  it("completes due non-repeating mileage reminders", async () => {
    await addReminder(baseReminder({ nextReminderMileage: 10000 }));

    const processed = await syncMileageRemindersForCar(CAR_ID, 10050);
    const reminders = await loadRemindersForCar(CAR_ID);

    expect(processed).toBe(1);
    expect(reminders[0]?.completedAt).toBeTruthy();
  });

  it("advances repeating mileage reminders to the next interval", async () => {
    await addReminder(baseReminder({ nextReminderMileage: 10000, repeatMileageInterval: 5000 }));

    const processed = await syncMileageRemindersForCar(CAR_ID, 12000);
    const reminders = await loadRemindersForCar(CAR_ID);

    expect(processed).toBe(1);
    expect(reminders[0]?.nextReminderMileage).toBe(17000);
    expect(reminders[0]?.completedAt).toBeUndefined();
  });

  it("does not process reminders that are not yet due", async () => {
    await addReminder(baseReminder({ nextReminderMileage: 15000 }));

    const processed = await syncMileageRemindersForCar(CAR_ID, 12000);
    const reminders = await loadRemindersForCar(CAR_ID);

    expect(processed).toBe(0);
    expect(reminders[0]?.completedAt).toBeUndefined();
    expect(reminders[0]?.nextReminderMileage).toBe(15000);
  });
});

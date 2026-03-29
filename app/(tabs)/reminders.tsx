import React, { useState, useCallback, useEffect } from "react";
import {
  View,
  Text,
  FlatList,
  Pressable,
  StyleSheet,
  Modal,
  ScrollView,
  TextInput,
  Switch,
  Alert,
  Platform,
} from "react-native";
import Animated, { FadeInDown } from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import { useFocusEffect } from "expo-router";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import { getActiveCar, loadGarage, CarProfile } from "@/lib/garage";
import { loadFuelLog } from "@/lib/fuel-log";
import {
  Reminder,
  NewReminder,
  ReminderCategory,
  REMINDER_CATEGORIES,
  loadRemindersForCar,
  addReminder,
  updateReminder,
  deleteReminder,
  completeReminder,
  getReminderUrgency,
  sortRemindersByUrgency,
} from "@/lib/reminders";

// ─── Helpers ─────────────────────────────────────────────────────────────────

function formatUrgency(
  reminder: Reminder,
  currentMileage: number
): { label: string; color: string } {
  const { milesLeft, daysLeft, isOverdue } = getReminderUrgency(reminder, currentMileage);

  if (isOverdue) {
    if (milesLeft !== undefined && milesLeft <= 0) {
      return { label: `${Math.abs(milesLeft).toLocaleString()} mi overdue`, color: "#EF4444" };
    }
    if (daysLeft !== undefined && daysLeft <= 0) {
      return { label: `${Math.abs(daysLeft)} day${Math.abs(daysLeft) !== 1 ? "s" : ""} overdue`, color: "#EF4444" };
    }
  }

  const parts: string[] = [];
  if (milesLeft !== undefined) {
    parts.push(`in ${milesLeft.toLocaleString()} mi`);
  }
  if (daysLeft !== undefined) {
    if (daysLeft === 0) parts.push("today");
    else if (daysLeft === 1) parts.push("tomorrow");
    else parts.push(`in ${daysLeft} days`);
  }

  const label = parts.join(" · ") || "No trigger set";
  const urgentColor =
    (milesLeft !== undefined && milesLeft < 500) ||
    (daysLeft !== undefined && daysLeft < 7)
      ? "#F59E0B"
      : "#10B981";

  return { label, color: urgentColor };
}

function getCategoryMeta(id: ReminderCategory) {
  return REMINDER_CATEGORIES.find((c) => c.id === id) ?? REMINDER_CATEGORIES[REMINDER_CATEGORIES.length - 1];
}

// ─── New Reminder Modal ───────────────────────────────────────────────────────

interface ReminderModalProps {
  visible: boolean;
  onClose: () => void;
  onSave: (r: NewReminder) => void;
  carId: string;
  carName: string;
  currentMileage: number;
  editingReminder?: Reminder | null;
}

function ReminderModal({
  visible,
  onClose,
  onSave,
  carId,
  carName,
  currentMileage,
  editingReminder,
}: ReminderModalProps) {
  const colors = useColors();

  const [name, setName] = useState("");
  const [category, setCategory] = useState<ReminderCategory>("oil_change");
  const [customCategoryLabel, setCustomCategoryLabel] = useState("");
  const [showCategoryPicker, setShowCategoryPicker] = useState(false);
  const [showCustomCategoryInput, setShowCustomCategoryInput] = useState(false);

  const [mileageEnabled, setMileageEnabled] = useState(true);
  const [nextMileage, setNextMileage] = useState(
    currentMileage > 0 ? (currentMileage + 5000).toString() : ""
  );
  const [repeatMileage, setRepeatMileage] = useState("5000");
  const [mileageRepeat, setMileageRepeat] = useState(false);

  const [dateEnabled, setDateEnabled] = useState(false);
  const [nextDate, setNextDate] = useState(() => {
    const d = new Date();
    d.setFullYear(d.getFullYear() + 1);
    return d.toISOString().split("T")[0];
  });
  const [dateRepeat, setDateRepeat] = useState(false);
  const [repeatDays, setRepeatDays] = useState("365");
  // Preset repeat options: weekly=7, monthly=30, 6months=182, yearly=365, custom
  const [dateRepeatPreset, setDateRepeatPreset] = useState<"weekly"|"monthly"|"6months"|"yearly"|"custom">("yearly");

  useEffect(() => {
    if (editingReminder) {
      setName(editingReminder.name);
      setCategory(editingReminder.category);
      setMileageEnabled(editingReminder.mileageEnabled);
      setNextMileage(editingReminder.nextReminderMileage?.toString() ?? "");
      setRepeatMileage(editingReminder.repeatMileageInterval?.toString() ?? "5000");
      setMileageRepeat(!!editingReminder.repeatMileageInterval);
      setDateEnabled(editingReminder.dateEnabled);
      setNextDate(editingReminder.nextReminderDate ?? new Date().toISOString().split("T")[0]);
      setDateRepeat(!!editingReminder.repeatDateInterval);
      setRepeatDays(editingReminder.repeatDateInterval?.toString() ?? "365");
    } else {
      setName("");
      setCategory("oil_change");
      setCustomCategoryLabel("");
      setMileageEnabled(true);
      setNextMileage(currentMileage > 0 ? (currentMileage + 5000).toString() : "");
      setRepeatMileage("5000");
      setMileageRepeat(false);
      setDateEnabled(false);
      const d = new Date();
      d.setFullYear(d.getFullYear() + 1);
      setNextDate(d.toISOString().split("T")[0]);
      setDateRepeat(false);
      setRepeatDays("365");
      setDateRepeatPreset("yearly");
    }
  }, [editingReminder, visible, currentMileage]);

  const handleSave = () => {
    // Name is optional — default to category label if blank
    const resolvedName = name.trim() || getCategoryMeta(category).label;
    if (!mileageEnabled && !dateEnabled) {
      Alert.alert("Trigger required", "Enable at least one trigger (mileage or date).");
      return;
    }

    const reminder: NewReminder = {
      carId,
      name: resolvedName,
      category,
      mileageEnabled,
      nextReminderMileage: mileageEnabled ? parseInt(nextMileage) || undefined : undefined,
      repeatMileageInterval: mileageEnabled && mileageRepeat ? parseInt(repeatMileage) || undefined : undefined,
      dateEnabled,
      nextReminderDate: dateEnabled ? nextDate : undefined,
      repeatDateInterval: dateEnabled && dateRepeat ? parseInt(repeatDays) || undefined : undefined,
    };

    onSave(reminder);
  };

  const catMeta = getCategoryMeta(category);

  return (
    <Modal visible={visible} animationType="slide" presentationStyle="pageSheet" onRequestClose={onClose}>
      <View style={[styles.modalContainer, { backgroundColor: colors.background }]}>
        {/* Header */}
        <View style={[styles.modalHeader, { borderBottomColor: colors.border }]}>
          <Pressable
            style={styles.modalCloseBtn}
            onPress={onClose}
          >
            <View style={[styles.modalCloseBtnInner, { backgroundColor: colors.surface }]}>
              <IconSymbol name="xmark" size={16} color={colors.foreground} />
            </View>
          </Pressable>
          <Text style={[styles.modalTitle, { color: colors.foreground }]}>
            {editingReminder ? "Edit Reminder" : "New Reminder"}
          </Text>
          <Pressable
            style={[styles.modalSaveBtn, { backgroundColor: colors.primary }]}
            onPress={handleSave}
          >
            <Text style={[styles.modalSaveBtnText, { color: "#fff" }]}>Save</Text>
          </Pressable>
        </View>

        <ScrollView style={styles.modalBody} showsVerticalScrollIndicator={false}>
          {/* Car + Category + Name */}
          <View style={[styles.formSection, { backgroundColor: colors.surface }]}>
            <View style={[styles.formRow, { borderBottomColor: colors.border }]}>
              <Text style={[styles.formRowLabel, { color: colors.foreground }]}>{carName}</Text>
              <IconSymbol name="chevron.right" size={16} color={colors.muted} />
            </View>
            <Pressable
              style={[styles.formRow, { borderBottomColor: colors.border }]}
              onPress={() => setShowCategoryPicker(true)}
            >
              <View style={styles.formRowLeft}>
                <View style={[styles.categoryDot, { backgroundColor: catMeta.color }]}>
                  <Text style={styles.categoryDotIcon}>{catMeta.icon}</Text>
                </View>
                <Text style={[styles.formRowLabel, { color: colors.foreground }]}>{catMeta.label}</Text>
              </View>
              <IconSymbol name="chevron.right" size={16} color={colors.muted} />
            </Pressable>
            <TextInput
              style={[styles.nameInput, { color: colors.foreground }]}
              placeholder="Name"
              placeholderTextColor={colors.muted}
              value={name}
              onChangeText={setName}
              returnKeyType="done"
            />
          </View>

          {/* Mileage trigger */}
          <View style={[styles.formSection, { backgroundColor: colors.surface }]}>
            <View style={[styles.formRow, { borderBottomColor: colors.border }]}>
              <Text style={[styles.formRowLabel, { color: colors.foreground }]}>Remind by mileage</Text>
              <Switch
                value={mileageEnabled}
                onValueChange={setMileageEnabled}
                trackColor={{ false: colors.border, true: colors.primary }}
                thumbColor="#fff"
              />
            </View>
            {mileageEnabled && (
              <>
                <View style={[styles.formRow, { borderBottomColor: colors.border }]}>
                  <Text style={[styles.formRowLabel, { color: colors.foreground }]}>Next Reminder</Text>
                  <View style={styles.formRowRight}>
                    <TextInput
                      style={[styles.inlineInput, { color: colors.foreground, borderColor: colors.border }]}
                      value={nextMileage}
                      onChangeText={setNextMileage}
                      keyboardType="number-pad"
                      returnKeyType="done"
                      placeholder="miles"
                      placeholderTextColor={colors.muted}
                    />
                    <Text style={[styles.unitLabel, { color: colors.muted }]}>miles</Text>
                  </View>
                </View>
                <View style={[styles.formRow, { borderBottomColor: colors.border }]}>
                  <Text style={[styles.formRowLabel, { color: colors.foreground }]}>Repeat every</Text>
                  <View style={styles.formRowRight}>
                    {mileageRepeat && (
                      <TextInput
                        style={[styles.inlineInput, { color: colors.foreground, borderColor: colors.border }]}
                        value={repeatMileage}
                        onChangeText={setRepeatMileage}
                        keyboardType="number-pad"
                        returnKeyType="done"
                        placeholder="5000"
                        placeholderTextColor={colors.muted}
                      />
                    )}
                    {mileageRepeat && (
                      <Text style={[styles.unitLabel, { color: colors.muted }]}>mi</Text>
                    )}
                    <Switch
                      value={mileageRepeat}
                      onValueChange={setMileageRepeat}
                      trackColor={{ false: colors.border, true: colors.primary }}
                      thumbColor="#fff"
                    />
                  </View>
                </View>
              </>
            )}
          </View>

          {/* Date trigger */}
          <View style={[styles.formSection, { backgroundColor: colors.surface }]}>
            <View style={[styles.formRow, { borderBottomColor: colors.border }]}>
              <Text style={[styles.formRowLabel, { color: colors.foreground }]}>Remind on date</Text>
              <Switch
                value={dateEnabled}
                onValueChange={setDateEnabled}
                trackColor={{ false: colors.border, true: colors.primary }}
                thumbColor="#fff"
              />
            </View>
            {dateEnabled && (
              <>
                <View style={[styles.formRow, { borderBottomColor: colors.border }]}>
                  <Text style={[styles.formRowLabel, { color: colors.foreground }]}>Next Reminder</Text>
                  <TextInput
                    style={[styles.inlineInput, { color: colors.foreground, borderColor: colors.border, minWidth: 120 }]}
                    value={nextDate}
                    onChangeText={setNextDate}
                    placeholder="YYYY-MM-DD"
                    placeholderTextColor={colors.muted}
                    returnKeyType="done"
                  />
                </View>
                <View style={[styles.formRow, { borderBottomColor: colors.border }]}>
                  <Text style={[styles.formRowLabel, { color: colors.foreground }]}>Repeat</Text>
                  <Switch
                    value={dateRepeat}
                    onValueChange={setDateRepeat}
                    trackColor={{ false: colors.border, true: colors.primary }}
                    thumbColor="#fff"
                  />
                </View>
                {dateRepeat && (
                  <>
                    {/* Preset repeat chips */}
                    <View style={[styles.formRow, { borderBottomColor: colors.border, flexWrap: "wrap", gap: 8 }]}>
                      {(["weekly", "monthly", "6months", "yearly", "custom"] as const).map((preset) => {
                        const label = preset === "weekly" ? "Weekly" : preset === "monthly" ? "Monthly" : preset === "6months" ? "6 Months" : preset === "yearly" ? "Yearly" : "Custom";
                        const isActive = dateRepeatPreset === preset;
                        return (
                          <Pressable
                            key={preset}
                            onPress={() => {
                              setDateRepeatPreset(preset);
                              if (preset === "weekly") setRepeatDays("7");
                              else if (preset === "monthly") setRepeatDays("30");
                              else if (preset === "6months") setRepeatDays("182");
                              else if (preset === "yearly") setRepeatDays("365");
                            }}
                            style={({ pressed }) => [styles.repeatPresetChip, { backgroundColor: isActive ? colors.primary : colors.background, borderColor: isActive ? colors.primary : colors.border, opacity: pressed ? 0.7 : 1 }]}
                          >
                            <Text style={[styles.repeatPresetText, { color: isActive ? "#fff" : colors.foreground }]}>{label}</Text>
                          </Pressable>
                        );
                      })}
                    </View>
                    {dateRepeatPreset === "custom" && (
                      <View style={[styles.formRow, { borderBottomColor: colors.border }]}>
                        <Text style={[styles.formRowLabel, { color: colors.foreground }]}>Every</Text>
                        <View style={styles.formRowRight}>
                          <TextInput
                            style={[styles.inlineInput, { color: colors.foreground, borderColor: colors.border }]}
                            value={repeatDays}
                            onChangeText={setRepeatDays}
                            keyboardType="number-pad"
                            returnKeyType="done"
                            placeholder="30"
                            placeholderTextColor={colors.muted}
                          />
                          <Text style={[styles.unitLabel, { color: colors.muted }]}>days</Text>
                        </View>
                      </View>
                    )}
                  </>
                )}
              </>
            )}
          </View>

          <View style={{ height: 40 }} />
        </ScrollView>

        {/* Category Picker */}
        <Modal visible={showCategoryPicker} transparent animationType="slide" onRequestClose={() => setShowCategoryPicker(false)}>
          <Pressable style={styles.pickerOverlay} onPress={() => setShowCategoryPicker(false)}>
            <Pressable style={[styles.pickerSheet, { backgroundColor: colors.surface }]} onPress={(e) => e.stopPropagation()}>
              <View style={[styles.pickerDragHandle, { backgroundColor: colors.border }]} />
              <Text style={[styles.pickerTitle, { color: colors.foreground }]}>Category</Text>
              <ScrollView style={{ maxHeight: 380 }} showsVerticalScrollIndicator={true} bounces={false}>
                {REMINDER_CATEGORIES.map((cat) => (
                  <Pressable
                    key={cat.id}
                    style={[styles.pickerRow, { borderBottomColor: colors.border }]}
                    onPress={() => {
                      setCategory(cat.id);
                      setShowCustomCategoryInput(false);
                      setShowCategoryPicker(false);
                    }}
                  >
                    <View style={[styles.categoryDot, { backgroundColor: cat.color }]}>
                      <Text style={styles.categoryDotIcon}>{cat.icon}</Text>
                    </View>
                    <Text style={[styles.pickerRowLabel, { color: colors.foreground }]}>{cat.label}</Text>
                    {category === cat.id && (
                      <IconSymbol name="checkmark" size={18} color={colors.primary} />
                    )}
                  </Pressable>
                ))}
                {/* Custom category option */}
                <Pressable
                  style={[styles.pickerRow, { borderBottomColor: colors.border }]}
                  onPress={() => setShowCustomCategoryInput(true)}
                >
                  <View style={[styles.categoryDot, { backgroundColor: colors.muted }]}>
                    <Text style={styles.categoryDotIcon}>✏️</Text>
                  </View>
                  <Text style={[styles.pickerRowLabel, { color: colors.foreground }]}>Custom…</Text>
                </Pressable>
                {showCustomCategoryInput && (
                  <View style={[styles.pickerRow, { borderBottomColor: colors.border, gap: 8 }]}>
                    <TextInput
                      style={[styles.inlineInput, { flex: 1, color: colors.foreground, borderColor: colors.border }]}
                      placeholder="Category name"
                      placeholderTextColor={colors.muted}
                      value={customCategoryLabel}
                      onChangeText={setCustomCategoryLabel}
                      returnKeyType="done"
                      autoFocus
                    />
                    <Pressable
                      onPress={() => {
                        if (customCategoryLabel.trim()) {
                          // Use "other" category id but override name via reminder name
                          setCategory("other");
                          if (!name.trim()) setName(customCategoryLabel.trim());
                          setShowCustomCategoryInput(false);
                          setShowCategoryPicker(false);
                        }
                      }}
                      style={({ pressed }) => [{ paddingHorizontal: 12, paddingVertical: 8, backgroundColor: colors.primary, borderRadius: 8, opacity: pressed ? 0.7 : 1 }]}
                    >
                      <Text style={{ color: "#fff", fontWeight: "600" }}>Add</Text>
                    </Pressable>
                  </View>
                )}
              </ScrollView>
            </Pressable>
          </Pressable>
        </Modal>
      </View>
    </Modal>
  );
}

// ─── Main Screen ─────────────────────────────────────────────────────────────

export default function RemindersScreen() {
  const colors = useColors();
  const [activeCar, setActiveCar] = useState<CarProfile | null>(null);
  const [reminders, setReminders] = useState<Reminder[]>([]);
  const [currentMileage, setCurrentMileage] = useState(0);
  const [loading, setLoading] = useState(true);
  const [showModal, setShowModal] = useState(false);
  const [editingReminder, setEditingReminder] = useState<Reminder | null>(null);

  const loadData = useCallback(async () => {
    try {
      const car = await getActiveCar();
      setActiveCar(car);
      if (car) {
        const [rems, logs] = await Promise.all([
          loadRemindersForCar(car.id),
          loadFuelLog(),
        ]);
        // Use the highest of: latest fuel log odometer, or car's stored odometer
        const fuelLogMileage = logs.length > 0 ? logs[0].odometer : 0;
        const carOdometer = car.odometer ?? 0;
        const latestMileage = Math.max(fuelLogMileage, carOdometer);
        setCurrentMileage(latestMileage);
        setReminders(sortRemindersByUrgency(rems, latestMileage));
      } else {
        setReminders([]);
      }
    } catch (e) {
      console.warn("Failed to load reminders:", e);
    } finally {
      setLoading(false);
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      loadData();
    }, [loadData])
  );

  const handleSave = useCallback(
    async (data: NewReminder) => {
      if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      if (editingReminder) {
        await updateReminder(editingReminder.id, data);
      } else {
        await addReminder(data);
      }
      setShowModal(false);
      setEditingReminder(null);
      loadData();
    },
    [editingReminder, loadData]
  );

  const handleComplete = useCallback(
    async (reminder: Reminder) => {
      Alert.alert(
        "Mark Complete",
        `Mark "${reminder.name}" as done?`,
        [
          { text: "Cancel", style: "cancel" },
          {
            text: "Complete",
            onPress: async () => {
              if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
              await completeReminder(reminder.id, currentMileage);
              loadData();
            },
          },
        ]
      );
    },
    [currentMileage, loadData]
  );

  const handleDelete = useCallback(
    async (reminder: Reminder) => {
      Alert.alert(
        "Delete Reminder",
        `Delete "${reminder.name}"?`,
        [
          { text: "Cancel", style: "cancel" },
          {
            text: "Delete",
            style: "destructive",
            onPress: async () => {
              await deleteReminder(reminder.id);
              loadData();
            },
          },
        ]
      );
    },
    [loadData]
  );

  const renderReminder = useCallback(
    ({ item, index }: { item: Reminder; index: number }) => {
      const catMeta = getCategoryMeta(item.category);
      const urgency = formatUrgency(item, currentMileage);

      return (
        <Animated.View entering={FadeInDown.delay(index * 40).springify()}>
          <Pressable
            style={[styles.reminderRow, { borderBottomColor: colors.border }]}
            onPress={() => {
              setEditingReminder(item);
              setShowModal(true);
            }}
            onLongPress={() => handleDelete(item)}
          >
            <View style={[styles.reminderIcon, { backgroundColor: catMeta.color }]}>
              <Text style={styles.reminderIconText}>{catMeta.icon}</Text>
            </View>
            <View style={styles.reminderContent}>
              <Text style={[styles.reminderName, { color: colors.foreground }]}>{item.name}</Text>
              <Text style={[styles.reminderUrgency, { color: urgency.color }]}>{urgency.label}</Text>
            </View>
            <Pressable
              style={[styles.completeBtn, { borderColor: colors.border }]}
              onPress={() => handleComplete(item)}
            >
              <IconSymbol name="checkmark.circle" size={22} color={colors.primary} />
            </Pressable>
          </Pressable>
        </Animated.View>
      );
    },
    [colors, currentMileage, handleComplete, handleDelete]
  );

  const carName = activeCar
    ? `${activeCar.year} ${activeCar.make} ${activeCar.model}`.trim() || activeCar.nickname
    : "No car selected";

  return (
    <ScreenContainer>
      {/* Header */}
      <View style={[styles.header, { borderBottomColor: colors.border }]}>
        <View>
          <Text style={[styles.headerTitle, { color: colors.foreground }]}>Reminders</Text>
          {activeCar && (
            <Text style={[styles.headerSubtitle, { color: colors.muted }]}>{carName}</Text>
          )}
        </View>
        <Pressable
          style={[styles.addBtn, { backgroundColor: colors.primary }]}
          onPress={() => {
            if (!activeCar) {
              Alert.alert("No car selected", "Add a car in the Garage tab first.");
              return;
            }
            setEditingReminder(null);
            setShowModal(true);
          }}
        >
          <IconSymbol name="plus" size={20} color="#fff" />
          <Text style={styles.addBtnText}>Add</Text>
        </Pressable>
      </View>

      {/* Mileage chip */}
      {currentMileage > 0 && (
        <View style={[styles.mileageChip, { backgroundColor: colors.surface, borderColor: colors.border }]}>
          <IconSymbol name="speedometer" size={14} color={colors.muted} />
          <Text style={[styles.mileageChipText, { color: colors.muted }]}>
            Current mileage: {currentMileage.toLocaleString()} mi
          </Text>
        </View>
      )}

      {/* List */}
      {!activeCar ? (
        <View style={styles.emptyState}>
          <Text style={styles.emptyEmoji}>🚗</Text>
          <Text style={[styles.emptyTitle, { color: colors.foreground }]}>No car selected</Text>
          <Text style={[styles.emptySubtitle, { color: colors.muted }]}>
            Add a car in the Garage tab to start tracking reminders.
          </Text>
        </View>
      ) : reminders.length === 0 ? (
        <View style={styles.emptyState}>
          <Text style={styles.emptyEmoji}>🔔</Text>
          <Text style={[styles.emptyTitle, { color: colors.foreground }]}>No reminders yet</Text>
          <Text style={[styles.emptySubtitle, { color: colors.muted }]}>
            Tap Add to set up your first maintenance reminder.
          </Text>
        </View>
      ) : (
        <View style={[styles.listCard, { backgroundColor: colors.surface }]}>
          <FlatList
            data={reminders}
            keyExtractor={(item) => item.id}
            renderItem={renderReminder}
            scrollEnabled={false}
          />
        </View>
      )}

      {/* Modal */}
      {activeCar && (
        <ReminderModal
          visible={showModal}
          onClose={() => {
            setShowModal(false);
            setEditingReminder(null);
          }}
          onSave={handleSave}
          carId={activeCar.id}
          carName={carName}
          currentMileage={currentMileage}
          editingReminder={editingReminder}
        />
      )}
    </ScreenContainer>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 20,
    paddingTop: 16,
    paddingBottom: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  headerTitle: {
    fontSize: 28,
    fontWeight: "700",
    letterSpacing: -0.5,
  },
  headerSubtitle: {
    fontSize: 13,
    marginTop: 2,
  },
  addBtn: {
    flexDirection: "row",
    alignItems: "center",
    gap: 4,
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 20,
  },
  addBtnText: {
    color: "#fff",
    fontWeight: "600",
    fontSize: 14,
  },
  mileageChip: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    marginHorizontal: 16,
    marginTop: 12,
    paddingHorizontal: 12,
    paddingVertical: 7,
    borderRadius: 10,
    borderWidth: StyleSheet.hairlineWidth,
  },
  mileageChipText: {
    fontSize: 12,
  },
  listCard: {
    marginHorizontal: 16,
    marginTop: 16,
    borderRadius: 16,
    overflow: "hidden",
  },
  reminderRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 16,
    paddingVertical: 14,
    gap: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  reminderIcon: {
    width: 44,
    height: 44,
    borderRadius: 22,
    alignItems: "center",
    justifyContent: "center",
  },
  reminderIconText: {
    fontSize: 20,
  },
  reminderContent: {
    flex: 1,
  },
  reminderName: {
    fontSize: 15,
    fontWeight: "600",
  },
  reminderUrgency: {
    fontSize: 13,
    marginTop: 2,
  },
  completeBtn: {
    padding: 4,
    borderRadius: 12,
  },
  emptyState: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: 40,
    gap: 8,
  },
  emptyEmoji: {
    fontSize: 48,
    marginBottom: 8,
  },
  emptyTitle: {
    fontSize: 18,
    fontWeight: "700",
    textAlign: "center",
  },
  emptySubtitle: {
    fontSize: 14,
    textAlign: "center",
    lineHeight: 20,
  },
  // Modal
  modalContainer: {
    flex: 1,
  },
  modalHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingTop: 20,
    paddingBottom: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  modalTitle: {
    fontSize: 17,
    fontWeight: "600",
  },
  modalCloseBtn: {
    width: 40,
  },
  modalCloseBtnInner: {
    width: 32,
    height: 32,
    borderRadius: 16,
    alignItems: "center",
    justifyContent: "center",
  },
  modalSaveBtn: {
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 20,
  },
  modalSaveBtnText: {
    fontWeight: "700",
    fontSize: 15,
  },
  modalBody: {
    flex: 1,
    padding: 16,
  },
  formSection: {
    borderRadius: 14,
    overflow: "hidden",
    marginBottom: 16,
  },
  formRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingVertical: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  formRowLeft: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
  },
  formRowLabel: {
    fontSize: 15,
  },
  formRowRight: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
  },
  nameInput: {
    paddingHorizontal: 16,
    paddingVertical: 14,
    fontSize: 15,
  },
  inlineInput: {
    borderWidth: 1,
    borderRadius: 8,
    paddingHorizontal: 10,
    paddingVertical: 6,
    fontSize: 14,
    minWidth: 80,
    textAlign: "right",
  },
  unitLabel: {
    fontSize: 13,
  },
  categoryDot: {
    width: 36,
    height: 36,
    borderRadius: 18,
    alignItems: "center",
    justifyContent: "center",
  },
  categoryDotIcon: {
    fontSize: 18,
  },
  // Category picker
  pickerOverlay: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.5)",
    justifyContent: "flex-end",
  },
  pickerSheet: {
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    paddingTop: 16,
    paddingBottom: 40,
    maxHeight: "70%",
  },
  pickerTitle: {
    fontSize: 17,
    fontWeight: "600",
    textAlign: "center",
    marginBottom: 8,
    paddingHorizontal: 20,
  },
  pickerRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 20,
    paddingVertical: 12,
    gap: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  pickerRowLabel: {
    flex: 1,
    fontSize: 15,
  },
  pickerDragHandle: {
    width: 36,
    height: 4,
    borderRadius: 2,
    alignSelf: "center",
    marginBottom: 12,
  },
  repeatPresetChip: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 20,
    borderWidth: 1,
  },
  repeatPresetText: {
    fontSize: 13,
    fontWeight: "500",
  },
});

import { useCallback, useEffect, useState } from "react";
import {
  ScrollView,
  Text,
  View,
  Pressable,
  Platform,
  StyleSheet,
  FlatList,
  Modal,
  TextInput,
  Alert,
} from "react-native";
import Animated, {
  FadeIn,
  FadeInDown,
  FadeInRight,
} from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import { LinearGradient } from "expo-linear-gradient";
import { useRouter, useFocusEffect } from "expo-router";
import { calculateBlend, DEFAULT_INPUTS, COMMON_BLENDS, type BlendInputs, type BlendResult } from "@/lib/blend-calculator";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import { getActiveCar, CarProfile, updateCarProfile } from "@/lib/garage";
import { loadFuelLog, FuelEntry } from "@/lib/fuel-log";
import {
  loadRemindersForCar,
  Reminder,
  getReminderUrgency,
  sortRemindersByUrgency,
  REMINDER_CATEGORIES,
  ReminderCategory,
  updateReminder,
  syncMileageRemindersForCar,
} from "@/lib/reminders";

// ─── Helpers ─────────────────────────────────────────────────────────────────

function getCategoryMeta(id: ReminderCategory) {
  return REMINDER_CATEGORIES.find((c) => c.id === id) ?? REMINDER_CATEGORIES[REMINDER_CATEGORIES.length - 1];
}

function getUrgencyLabel(reminder: Reminder, currentMileage: number): { label: string; color: string } {
  const { milesLeft, daysLeft, isOverdue } = getReminderUrgency(reminder, currentMileage);

  if (isOverdue) {
    if (milesLeft !== undefined && milesLeft <= 0)
      return { label: `${Math.abs(milesLeft).toLocaleString()} mi overdue`, color: "#EF4444" };
    if (daysLeft !== undefined && daysLeft <= 0)
      return { label: `${Math.abs(daysLeft)}d overdue`, color: "#EF4444" };
  }

  const parts: string[] = [];
  if (milesLeft !== undefined) parts.push(`in ${milesLeft.toLocaleString()} mi`);
  if (daysLeft !== undefined) {
    if (daysLeft === 0) parts.push("today");
    else if (daysLeft === 1) parts.push("1 day");
    else parts.push(`${daysLeft}d`);
  }

  const urgentColor =
    (milesLeft !== undefined && milesLeft < 500) || (daysLeft !== undefined && daysLeft < 7)
      ? "#F59E0B"
      : "#10B981";

  return { label: parts.join(" · ") || "Scheduled", color: urgentColor };
}

function formatDate(iso: string): string {
  const d = new Date(iso);
  const now = new Date();
  const diffMs = now.getTime() - d.getTime();
  const diffDays = Math.floor(diffMs / 86400000);
  if (diffDays === 0) return "Today";
  if (diffDays === 1) return "Yesterday";
  if (diffDays < 7) return `${diffDays} days ago`;
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

// ─── Sub-components ──────────────────────────────────────────────────────────

interface CarHeroProps {
  car: CarProfile;
  currentMileage: number;
  onPress: () => void;
  onOdometerPress: () => void;
}

function CarHero({ car, currentMileage, onPress, onOdometerPress }: CarHeroProps) {
  const colors = useColors();
  const carLabel = car.nickname || `${car.year} ${car.make} ${car.model}`.trim() || "My Car";

  return (
    <Animated.View entering={FadeIn.duration(400)} style={styles.heroWrapper}>
      <Pressable onPress={onPress} style={({ pressed }) => [{ opacity: pressed ? 0.92 : 1 }]}>
        <LinearGradient
          colors={[car.color + "CC", car.color + "66"]}
          start={{ x: 0, y: 0 }}
          end={{ x: 1, y: 1 }}
          style={styles.heroGradient}
        >
          {/* Car emoji + name */}
          <View style={styles.heroTop}>
            <View style={styles.heroEmojiWrap}>
              <Text style={styles.heroEmoji}>{car.icon}</Text>
            </View>
            <View style={styles.heroInfo}>
              <Text style={styles.heroCarName}>{carLabel}</Text>
              {(car.year || car.make || car.model) && (
                <Text style={styles.heroCarSub}>
                  {[car.year, car.make, car.model].filter(Boolean).join(" ")}
                </Text>
              )}
            </View>
            <View style={styles.heroActiveBadge}>
              <Text style={styles.heroActiveBadgeText}>Active</Text>
            </View>
          </View>

          {/* Stats row */}
          <View style={styles.heroStats}>
            <View style={styles.heroStat}>
              <Text style={styles.heroStatValue}>{car.tankSize}</Text>
              <Text style={styles.heroStatLabel}>gal tank</Text>
            </View>
            <View style={styles.heroStatDivider} />
            <View style={styles.heroStat}>
              <Text style={styles.heroStatValue}>E{car.defaultBlend}</Text>
              <Text style={styles.heroStatLabel}>default blend</Text>
            </View>
            <View style={styles.heroStatDivider} />
            <Pressable onPress={onOdometerPress} style={({ pressed }) => [{ opacity: pressed ? 0.7 : 1 }]}>
              <View style={styles.heroStat}>
                <Text style={styles.heroStatValue}>
                  {currentMileage > 0 ? currentMileage.toLocaleString() : "—"}
                </Text>
                <Text style={styles.heroStatLabel}>odometer</Text>
              </View>
            </Pressable>
          </View>
        </LinearGradient>
      </Pressable>
    </Animated.View>
  );
}

interface ReminderCardProps {
  reminder: Reminder;
  currentMileage: number;
  onPress: () => void;
}

function ReminderCard({ reminder, currentMileage, onPress }: ReminderCardProps) {
  const colors = useColors();
  const catMeta = getCategoryMeta(reminder.category);
  const urgency = getUrgencyLabel(reminder, currentMileage);

  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        styles.reminderCard,
        { backgroundColor: colors.surface, borderColor: colors.border, opacity: pressed ? 0.8 : 1 },
      ]}
    >
      <View style={[styles.reminderCardIcon, { backgroundColor: catMeta.color + "22" }]}>
        <Text style={styles.reminderCardIconText}>{catMeta.icon}</Text>
      </View>
      <Text style={[styles.reminderCardName, { color: colors.foreground }]} numberOfLines={1}>
        {reminder.name}
      </Text>
      <View style={[styles.reminderCardBadge, { backgroundColor: urgency.color + "22" }]}>
        <Text style={[styles.reminderCardBadgeText, { color: urgency.color }]}>{urgency.label}</Text>
      </View>
    </Pressable>
  );
}

interface FillUpRowProps {
  entry: FuelEntry;
  isLast: boolean;
}

function FillUpRow({ entry, isLast }: FillUpRowProps) {
  const colors = useColors();
  const blendColor =
    entry.blendRatio >= 70 ? "#10B981" : entry.blendRatio >= 40 ? "#F59E0B" : "#3B82F6";

  return (
    <View style={[styles.fillUpRow, !isLast && { borderBottomColor: colors.border, borderBottomWidth: StyleSheet.hairlineWidth }]}>
      {/* Timeline dot */}
      <View style={styles.timelineDotWrap}>
        <View style={[styles.timelineDot, { backgroundColor: blendColor }]} />
        {!isLast && <View style={[styles.timelineLine, { backgroundColor: colors.border }]} />}
      </View>

      <View style={styles.fillUpContent}>
        <View style={styles.fillUpHeader}>
          <Text style={[styles.fillUpStation, { color: colors.foreground }]} numberOfLines={1}>
            {entry.stationName || "Unknown station"}
          </Text>
          <Text style={[styles.fillUpDate, { color: colors.muted }]}>{formatDate(entry.date)}</Text>
        </View>
        <View style={styles.fillUpMeta}>
          <View style={[styles.blendBadge, { backgroundColor: blendColor + "22" }]}>
            <Text style={[styles.blendBadgeText, { color: blendColor }]}>E{entry.blendRatio}</Text>
          </View>
          <Text style={[styles.fillUpDetail, { color: colors.muted }]}>
            {entry.gallonsAdded.toFixed(1)} gal
          </Text>
          {entry.pricePerGallon > 0 && (
            <Text style={[styles.fillUpDetail, { color: colors.muted }]}>
              ${entry.pricePerGallon.toFixed(2)}/gal
            </Text>
          )}
          {entry.odometer > 0 && (
            <Text style={[styles.fillUpDetail, { color: colors.muted }]}>
              {entry.odometer.toLocaleString()} mi
            </Text>
          )}
        </View>
      </View>
    </View>
  );
}

// ─── Main Screen ─────────────────────────────────────────────────────────────

export default function HomeScreen() {
  const colors = useColors();
  const router = useRouter();
  const [activeCar, setActiveCar] = useState<CarProfile | null>(null);
  const [reminders, setReminders] = useState<Reminder[]>([]);
  const [recentFillUps, setRecentFillUps] = useState<FuelEntry[]>([]);
  const [currentMileage, setCurrentMileage] = useState(0);
  const [loading, setLoading] = useState(true);
  const [odometerModalVisible, setOdometerModalVisible] = useState(false);
  const [odometerInput, setOdometerInput] = useState("");
  const [calculatorModalVisible, setCalculatorModalVisible] = useState(false);
  const [blendInputs, setBlendInputs] = useState<BlendInputs>(DEFAULT_INPUTS);
  const [blendResult, setBlendResult] = useState<BlendResult | null>(null);
  // String-based input state to allow decimal typing without losing trailing dots
  const [calcStrings, setCalcStrings] = useState({
    tankSize: DEFAULT_INPUTS.tankSize.toString(),
    currentFuelLevel: DEFAULT_INPUTS.currentFuelLevel.toString(),
    currentEthanolPercent: DEFAULT_INPUTS.currentEthanolPercent.toString(),
    targetEthanolPercent: DEFAULT_INPUTS.targetEthanolPercent.toString(),
    e85EthanolPercent: DEFAULT_INPUTS.e85EthanolPercent.toString(),
    gasEthanolPercent: DEFAULT_INPUTS.gasEthanolPercent.toString(),
    gasOctane: DEFAULT_INPUTS.gasOctane.toString(),
  });
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [pumpMode, setPumpMode] = useState(false);
  const [blendName, setBlendName] = useState("");
  const [showPumpInstructions, setShowPumpInstructions] = useState(false);
  const [logFillUpModalVisible, setLogFillUpModalVisible] = useState(false);
  const [logFillUpOdometer, setLogFillUpOdometer] = useState("");
  const [logFillUpStation, setLogFillUpStation] = useState("");
  const [logFillUpPriceE85, setLogFillUpPriceE85] = useState("");
  const [logFillUpPriceGas, setLogFillUpPriceGas] = useState("");

  const loadData = useCallback(async () => {
    try {
      const car = await getActiveCar();
      setActiveCar(car);

      const logs = await loadFuelLog();
      const recent = logs.slice(0, 5);
      setRecentFillUps(recent);
      // Use the higher of: latest fuel log odometer or car's manual odometer
      // This ensures manual updates persist and aren't overridden by older fuel logs
      const fuelLogOdometer = logs.length > 0 ? logs[0].odometer : 0;
      const carOdometer = car?.odometer ?? 0;
      const latestMileage = Math.max(fuelLogOdometer, carOdometer);
      setCurrentMileage(latestMileage);

      if (car) {
        const rems = await loadRemindersForCar(car.id);
        const sorted = sortRemindersByUrgency(rems, latestMileage);
        // Show only upcoming/overdue (not completed)
        setReminders(sorted.filter((r) => !r.completedAt).slice(0, 6));
      } else {
        setReminders([]);
      }
    } catch (e) {
      console.warn("Failed to load home data:", e);
    } finally {
      setLoading(false);
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      loadData();
    }, [loadData])
  );

  const handleAddReminder = useCallback(() => {
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    router.push("/(tabs)/reminders");
  }, [router]);

  const handleReminderPress = useCallback(() => {
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    router.push("/(tabs)/reminders");
  }, [router]);

  const handleCarPress = useCallback(() => {
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    router.push("/(tabs)/settings");
  }, [router]);

  const [calcAutoFilled, setCalcAutoFilled] = useState(false);

  const handleCalculatePress = useCallback(async () => {
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    // Load latest fuel log entry to auto-fill current ethanol %
    const { loadFuelLog } = await import("@/lib/fuel-log");
    const logs = await loadFuelLog();
    // Find the most recent entry that has currentEthanolPct stored
    const lastWithEthanol = logs.find((l: any) => l.currentEthanolPct != null);
    const autoEthanolPct = lastWithEthanol?.currentEthanolPct ?? null;
    const inputs: BlendInputs = activeCar ? {
      ...DEFAULT_INPUTS,
      tankSize: activeCar.tankSize,
      currentEthanolPercent: autoEthanolPct !== null ? autoEthanolPct : DEFAULT_INPUTS.currentEthanolPercent,
      targetEthanolPercent: activeCar.defaultBlend,
      gasOctane: activeCar.requiredOctane,
      gasEthanolPercent: activeCar.gasEthanolPercent ?? 0,
    } : DEFAULT_INPUTS;
    setBlendInputs(inputs);
    setCalcStrings({
      tankSize: inputs.tankSize.toString(),
      currentFuelLevel: inputs.currentFuelLevel.toString(),
      currentEthanolPercent: inputs.currentEthanolPercent.toString(),
      targetEthanolPercent: inputs.targetEthanolPercent.toString(),
      e85EthanolPercent: inputs.e85EthanolPercent.toString(),
      gasEthanolPercent: inputs.gasEthanolPercent.toString(),
      gasOctane: inputs.gasOctane.toString(),
    });
    setCalcAutoFilled(autoEthanolPct !== null);
    setBlendResult(calculateBlend(inputs));
    setBlendName("");
    setShowAdvanced(false);
    setCalculatorModalVisible(true);
  }, [activeCar]);

  // Decimal-safe input handler: keep raw string for display, parse for calculation
  const handleCalcStringChange = useCallback((key: keyof typeof calcStrings, text: string) => {
    // Allow digits, one decimal point, and leading minus (not needed but safe)
    const sanitized = text.replace(/[^0-9.]/g, "").replace(/(\..*)\./g, "$1");
    setCalcStrings((prev) => ({ ...prev, [key]: sanitized }));
    const num = parseFloat(sanitized);
    if (!isNaN(num)) {
      const updated = { ...blendInputs, [key]: num };
      setBlendInputs(updated);
      setBlendResult(calculateBlend(updated));
    }
  }, [blendInputs]);

  const handleBlendInputChange = useCallback((key: keyof BlendInputs, value: number) => {
    const updated = { ...blendInputs, [key]: value };
    setBlendInputs(updated);
    setCalcStrings((prev) => ({ ...prev, [key]: value.toString() }));
    setBlendResult(calculateBlend(updated));
  }, [blendInputs]);

  const handleQuickBlend = useCallback((targetEthanol: number) => {
    handleBlendInputChange("targetEthanolPercent", targetEthanol);
  }, [handleBlendInputChange]);

  const handleSaveBlend = useCallback(async () => {
    if (!blendResult) return;
    try {
      const { saveBlend } = await import("@/lib/blend-storage");
      await saveBlend(blendInputs, blendResult, blendName.trim() || undefined);
      if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      Alert.alert("Saved!", `${blendResult.blendLabel} blend saved to My Blends.`);
    } catch (e) {
      Alert.alert("Error", "Failed to save blend.");
    }
  }, [blendInputs, blendResult, blendName]);

  const handleLogFillUp = useCallback(() => {
    if (!blendResult) return;
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    setLogFillUpOdometer(currentMileage > 0 ? currentMileage.toString() : "");
    setLogFillUpStation("");
    setLogFillUpPriceE85("");
    setLogFillUpPriceGas("");
    setLogFillUpModalVisible(true);
  }, [blendResult, currentMileage]);

  const handleConfirmLogFillUp = useCallback(async () => {
    if (!blendResult) return;
    try {
      const { addFuelEntry } = await import("@/lib/fuel-log");
      const totalGallons = blendResult.e85Gallons + blendResult.gasGallons;
      const priceE85 = parseFloat(logFillUpPriceE85) || 0;
      const priceGas = parseFloat(logFillUpPriceGas) || 0;
      const blendedPricePerGal = totalGallons > 0
        ? (priceE85 * blendResult.e85Gallons + priceGas * blendResult.gasGallons) / totalGallons
        : 0;
      const odometer = parseInt(logFillUpOdometer) || currentMileage;
      await addFuelEntry({
        date: new Date().toISOString(),
        stationName: logFillUpStation.trim() || "Unknown station",
        blendRatio: blendResult.finalEthanolPercent,
        gallonsAdded: totalGallons,
        e85Gallons: blendResult.e85Gallons > 0 ? blendResult.e85Gallons : undefined,
        gasGallons: blendResult.gasGallons > 0 ? blendResult.gasGallons : undefined,
        e85PricePerGallon: priceE85 > 0 ? priceE85 : undefined,
        gasPricePerGallon: priceGas > 0 ? priceGas : undefined,
        pricePerGallon: blendedPricePerGal,
        totalPrice: blendedPricePerGal * totalGallons,
        odometer,
        notes: `Calculator blend: ${blendResult.blendLabel}`,
      });
      // Update car odometer if new reading is higher
      if (activeCar && odometer > currentMileage) {
        await updateCarProfile(activeCar.id, { ...activeCar, odometer });
        setCurrentMileage(odometer);
      }
      // Sync mileage reminders
      if (activeCar) {
        const syncCount = await syncMileageRemindersForCar(activeCar.id, odometer);
        if (syncCount > 0) {
          Alert.alert("Maintenance Updated", `${syncCount} reminder${syncCount > 1 ? "s" : ""} advanced based on your new mileage.`);
        }
      }
      setLogFillUpModalVisible(false);
      setCalculatorModalVisible(false);
      if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      Alert.alert("Logged!", `${totalGallons.toFixed(2)} gal fill-up added to Fuel Log.`);
      loadData();
    } catch (e) {
      console.warn("Failed to log fill-up:", e);
      Alert.alert("Error", "Failed to log fill-up.");
    }
  }, [blendResult, logFillUpOdometer, logFillUpStation, logFillUpPriceE85, logFillUpPriceGas, currentMileage, activeCar, loadData]);

  const handleUpdateOdometer = useCallback(() => {
    setOdometerInput(currentMileage.toString());
    setOdometerModalVisible(true);
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  }, [currentMileage]);

  const handleSaveOdometer = useCallback(async () => {
    const newOdometer = parseInt(odometerInput) || 0;
    if (newOdometer < 0) {
      Alert.alert("Invalid Odometer", "Please enter a valid odometer reading.");
      return;
    }
    if (newOdometer === currentMileage) {
      setOdometerModalVisible(false);
      return;
    }

    try {
      // Update the active car's odometer field
      if (activeCar) {
        await updateCarProfile(activeCar.id, { ...activeCar, odometer: newOdometer });
        await syncMileageRemindersForCar(activeCar.id, newOdometer);
        setCurrentMileage(newOdometer);
        setOdometerModalVisible(false);
        if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
        loadData();
      }
    } catch (e) {
      console.warn("Failed to update odometer:", e);
      Alert.alert("Error", "Failed to update odometer. Please try again.");
    }
  }, [odometerInput, currentMileage, activeCar, loadData]);

  return (
    <ScreenContainer>
      {/* ── Calculator Modal ── */}
      <Modal
        visible={calculatorModalVisible}
        animationType="slide"
        presentationStyle="pageSheet"
        onRequestClose={() => setCalculatorModalVisible(false)}
      >
        <View style={[styles.modalContainer, { backgroundColor: colors.background }]}>
          {/* Header */}
          <View style={[styles.modalHeader, { borderBottomColor: colors.border }]}>
            <Pressable
              onPress={() => setCalculatorModalVisible(false)}
              style={({ pressed }) => [styles.modalHeaderBtn, { opacity: pressed ? 0.6 : 1 }]}
            >
              <Text style={[styles.modalCancelText, { color: colors.primary }]}>Close</Text>
            </Pressable>
            <Text style={[styles.modalTitle, { color: colors.foreground }]}>E85 Calculator</Text>
            <Pressable
              onPress={() => { if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium); setPumpMode((v) => !v); }}
              style={({ pressed }) => [styles.modalHeaderBtn, { opacity: pressed ? 0.6 : 1 }]}
            >
              <View style={[{ paddingHorizontal: 10, paddingVertical: 4, borderRadius: 10, backgroundColor: pumpMode ? colors.success + "22" : colors.primary + "18" }]}>
                <Text style={[styles.modalSaveText, { color: pumpMode ? colors.success : colors.primary }]}>{pumpMode ? "⛽ At Pump" : "⛽ Pump Mode"}</Text>
              </View>
            </Pressable>
          </View>

          <ScrollView style={styles.calcScroll} contentContainerStyle={styles.calcScrollContent} keyboardShouldPersistTaps="handled">

            {/* Pump mode hint */}
            {pumpMode && (
              <View style={{ marginHorizontal: 16, marginTop: 12, marginBottom: 0, paddingHorizontal: 12, paddingVertical: 8, backgroundColor: colors.success + "14", borderRadius: 10, flexDirection: "row", alignItems: "center", gap: 6 }}>
                <Text style={{ fontSize: 13 }}>⛽</Text>
                <Text style={{ fontSize: 12, color: colors.success, fontWeight: "600", flex: 1 }}>At-Pump Mode — results show numbered fill instructions</Text>
              </View>
            )}

            {/* Quick Blend Presets */}
            <View style={styles.calcSection}>
              <Text style={[styles.calcSectionTitle, { color: colors.foreground }]}>Target Blend</Text>
              <View style={styles.quickBlendRow}>
                {COMMON_BLENDS.map((blend) => {
                  const isActive = blendInputs.targetEthanolPercent === blend.value;
                  return (
                    <Pressable
                      key={blend.value}
                      onPress={() => handleQuickBlend(blend.value)}
                      style={({ pressed }) => [styles.quickBlendBtn, {
                        backgroundColor: isActive ? colors.primary : colors.surface,
                        borderColor: isActive ? colors.primary : colors.border,
                        opacity: pressed ? 0.75 : 1,
                      }]}
                    >
                      <Text style={[styles.quickBlendText, { color: isActive ? "#fff" : colors.foreground }]}>{blend.label}</Text>
                    </Pressable>
                  );
                })}
              </View>
            </View>

            {/* Core Inputs */}
            <View style={styles.calcSection}>
              <Text style={[styles.calcSectionTitle, { color: colors.foreground }]}>Tank Info</Text>
              <View style={styles.calcInputRow}>
                <View style={styles.calcInputHalf}>
                  <Text style={[styles.calcInputLabel, { color: colors.muted }]}>Tank Size (gal)</Text>
                  <TextInput
                    style={[styles.calcInput, { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground }]}
                    keyboardType="decimal-pad"
                    placeholder="16"
                    placeholderTextColor={colors.muted}
                    value={calcStrings.tankSize}
                    onChangeText={(t) => handleCalcStringChange("tankSize", t)}
                    returnKeyType="done"
                  />
                </View>
                <View style={styles.calcInputHalf}>
                  <Text style={[styles.calcInputLabel, { color: colors.muted }]}>Current Level (%)</Text>
                  <TextInput
                    style={[styles.calcInput, { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground }]}
                    keyboardType="decimal-pad"
                    placeholder="0"
                    placeholderTextColor={colors.muted}
                    value={calcStrings.currentFuelLevel}
                    onChangeText={(t) => handleCalcStringChange("currentFuelLevel", t)}
                    returnKeyType="done"
                  />
                  <View style={{ flexDirection: "row", gap: 5, marginTop: 6, flexWrap: "wrap" }}>
                    {[{l:"E",v:"0"},{l:"1/4",v:"25"},{l:"1/2",v:"50"},{l:"3/4",v:"75"}].map((item) => {
                      const isActive = calcStrings.currentFuelLevel === item.v;
                      return (
                        <Pressable
                          key={item.v}
                          onPress={() => handleCalcStringChange("currentFuelLevel", item.v)}
                          style={({ pressed }) => ({
                            paddingHorizontal: 8, paddingVertical: 3, borderRadius: 7,
                            backgroundColor: isActive ? "#D97706" : colors.surface,
                            borderWidth: 1, borderColor: isActive ? "#D97706" : colors.border,
                            opacity: pressed ? 0.7 : 1,
                          })}
                        >
                          <Text style={{ fontSize: 11, fontWeight: "600", color: isActive ? "#fff" : colors.foreground }}>{item.l}</Text>
                        </Pressable>
                      );
                    })}
                  </View>
                </View>
              </View>
              <View style={styles.calcInputRow}>
                <View style={styles.calcInputHalf}>
                  <View style={{ flexDirection: "row", alignItems: "center", gap: 6, marginBottom: 2 }}>
                    <Text style={[styles.calcInputLabel, { color: colors.muted, marginBottom: 0 }]}>Current Fuel Ethanol %</Text>
                    {calcAutoFilled && (
                      <View style={{ backgroundColor: colors.primary + "22", borderRadius: 4, paddingHorizontal: 5, paddingVertical: 1 }}>
                        <Text style={{ fontSize: 10, color: colors.primary, fontWeight: "700" }}>AUTO</Text>
                      </View>
                    )}
                  </View>
                  <TextInput
                    style={[styles.calcInput, { backgroundColor: colors.surface, borderColor: calcAutoFilled ? colors.primary + "60" : colors.border, color: colors.foreground }]}
                    keyboardType="decimal-pad"
                    placeholder="10"
                    placeholderTextColor={colors.muted}
                    value={calcStrings.currentEthanolPercent}
                    onChangeText={(t) => { handleCalcStringChange("currentEthanolPercent", t); setCalcAutoFilled(false); }}
                    returnKeyType="done"
                  />
                </View>
                <View style={styles.calcInputHalf}>
                  <Text style={[styles.calcInputLabel, { color: colors.muted }]}>Target Ethanol %</Text>
                  <TextInput
                    style={[styles.calcInput, { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground }]}
                    keyboardType="decimal-pad"
                    placeholder="30"
                    placeholderTextColor={colors.muted}
                    value={calcStrings.targetEthanolPercent}
                    onChangeText={(t) => handleCalcStringChange("targetEthanolPercent", t)}
                    returnKeyType="done"
                  />
                </View>
              </View>
            </View>

            {/* Advanced Toggle */}
            <Pressable
              onPress={() => setShowAdvanced((v) => !v)}
              style={({ pressed }) => [styles.advancedToggle, { borderColor: colors.border, opacity: pressed ? 0.7 : 1 }]}
            >
              <Text style={[styles.advancedToggleText, { color: colors.primary }]}>
                {showAdvanced ? "Hide Advanced Settings" : "Show Advanced Settings"}
              </Text>
              <IconSymbol name={showAdvanced ? "chevron.up" : "chevron.down"} size={14} color={colors.primary} />
            </Pressable>

            {/* Advanced Inputs */}
            {showAdvanced && (
              <View style={styles.calcSection}>
                <Text style={[styles.calcSectionTitle, { color: colors.foreground }]}>Fuel Properties</Text>
                <View style={styles.calcInputRow}>
                  <View style={styles.calcInputHalf}>
                    <Text style={[styles.calcInputLabel, { color: colors.muted }]}>E85 Ethanol %</Text>
                    <TextInput
                      style={[styles.calcInput, { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground }]}
                      keyboardType="decimal-pad"
                      placeholder="85"
                      placeholderTextColor={colors.muted}
                      value={calcStrings.e85EthanolPercent}
                      onChangeText={(t) => handleCalcStringChange("e85EthanolPercent", t)}
                      returnKeyType="done"
                    />
                  </View>
                  <View style={styles.calcInputHalf}>
                    <Text style={[styles.calcInputLabel, { color: colors.muted }]}>Gas Ethanol %</Text>
                    <TextInput
                      style={[styles.calcInput, { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground }]}
                      keyboardType="decimal-pad"
                      placeholder="0"
                      placeholderTextColor={colors.muted}
                      value={calcStrings.gasEthanolPercent}
                      onChangeText={(t) => handleCalcStringChange("gasEthanolPercent", t)}
                      returnKeyType="done"
                    />
                    <Text style={[styles.modalHint, { color: colors.muted }]}>0% for pure 91/93 oct</Text>
                  </View>
                </View>
                <View style={styles.calcInputRow}>
                  <View style={styles.calcInputHalf}>
                    <Text style={[styles.calcInputLabel, { color: colors.muted }]}>Gas Octane</Text>
                    <TextInput
                      style={[styles.calcInput, { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground }]}
                      keyboardType="decimal-pad"
                      placeholder="93"
                      placeholderTextColor={colors.muted}
                      value={calcStrings.gasOctane}
                      onChangeText={(t) => handleCalcStringChange("gasOctane", t)}
                      returnKeyType="done"
                    />
                    <View style={{ flexDirection: "row", gap: 6, marginTop: 6 }}>
                      {[87, 89, 91, 93].map((oct) => {
                        const isActive = calcStrings.gasOctane === String(oct);
                        return (
                          <Pressable
                            key={oct}
                            onPress={() => handleCalcStringChange("gasOctane", String(oct))}
                            style={({ pressed }) => ({
                              paddingHorizontal: 10, paddingVertical: 4, borderRadius: 8,
                              backgroundColor: isActive ? colors.primary : colors.surface,
                              borderWidth: 1, borderColor: isActive ? colors.primary : colors.border,
                              opacity: pressed ? 0.7 : 1,
                            })}
                          >
                            <Text style={{ fontSize: 12, fontWeight: "600", color: isActive ? "#fff" : colors.foreground }}>{oct}</Text>
                          </Pressable>
                        );
                      })}
                    </View>
                  </View>
                </View>
              </View>
            )}

            {/* Results Card */}
            {blendResult && pumpMode && (
              <View style={[styles.calcResultCard, { backgroundColor: colors.surface, borderColor: colors.success, borderWidth: 2 }]}>
                <View style={{ backgroundColor: colors.success + "18", borderRadius: 10, padding: 16, marginBottom: 12 }}>
                  <Text style={{ textAlign: "center", fontSize: 13, fontWeight: "600", color: colors.success, marginBottom: 12, letterSpacing: 0.5 }}>⛽ PUMP INSTRUCTIONS</Text>
                  {blendResult.e85Gallons > 0 && (
                    <View style={{ flexDirection: "row", alignItems: "center", marginBottom: 10 }}>
                      <View style={{ width: 28, height: 28, borderRadius: 14, backgroundColor: colors.primary, alignItems: "center", justifyContent: "center", marginRight: 10 }}>
                        <Text style={{ color: "#fff", fontWeight: "700", fontSize: 14 }}>1</Text>
                      </View>
                      <Text style={{ color: colors.foreground, fontSize: 16, flex: 1 }}>
                        Add <Text style={{ fontWeight: "800", fontSize: 20, color: colors.primary }}>{blendResult.e85Gallons.toFixed(2)}</Text> <Text style={{ fontWeight: "700" }}>gal E85</Text>
                      </Text>
                    </View>
                  )}
                  {blendResult.gasGallons > 0 && (
                    <View style={{ flexDirection: "row", alignItems: "center", marginBottom: 10 }}>
                      <View style={{ width: 28, height: 28, borderRadius: 14, backgroundColor: "#D97706", alignItems: "center", justifyContent: "center", marginRight: 10 }}>
                        <Text style={{ color: "#fff", fontWeight: "700", fontSize: 14 }}>{blendResult.e85Gallons > 0 ? "2" : "1"}</Text>
                      </View>
                      <Text style={{ color: colors.foreground, fontSize: 16, flex: 1 }}>
                        Add <Text style={{ fontWeight: "800", fontSize: 20, color: "#D97706" }}>{blendResult.gasGallons.toFixed(2)}</Text> <Text style={{ fontWeight: "700" }}>gal {blendInputs.gasOctane >= 91 ? `${blendInputs.gasOctane} oct` : "regular"}</Text>
                      </Text>
                    </View>
                  )}
                  <View style={{ flexDirection: "row", alignItems: "center" }}>
                    <View style={{ width: 28, height: 28, borderRadius: 14, backgroundColor: colors.success, alignItems: "center", justifyContent: "center", marginRight: 10 }}>
                      <Text style={{ color: "#fff", fontWeight: "700", fontSize: 14 }}>✓</Text>
                    </View>
                    <Text style={{ color: colors.foreground, fontSize: 15 }}>
                      Result: <Text style={{ fontWeight: "700" }}>{blendResult.blendLabel}</Text> · {blendResult.estimatedOctane.toFixed(1)} oct
                    </Text>
                  </View>
                </View>
                {blendResult.errorMessage && (
                  <View style={[styles.calcResultWarning, { backgroundColor: colors.warning + "18" }]}>
                    <Text style={[styles.calcResultWarningText, { color: colors.warning }]}>{blendResult.errorMessage}</Text>
                  </View>
                )}
                <Pressable
                  onPress={handleLogFillUp}
                  style={({ pressed }) => [styles.logFillUpBtn, { backgroundColor: colors.success + "18", borderColor: colors.success + "40", opacity: pressed ? 0.75 : 1 }]}
                >
                  <Text style={[styles.logFillUpBtnText, { color: colors.success }]}>+ Log This Fill-Up</Text>
                </Pressable>
              </View>
            )}

            {blendResult && !pumpMode && (
              <View style={[styles.calcResultCard, { backgroundColor: colors.surface, borderColor: blendResult.isValid ? colors.primary : colors.warning }]}>
                {/* Blend Label Badge */}
                <View style={styles.calcResultHeader}>
                  <LinearGradient
                    colors={blendResult.isValid ? [colors.primary, "#15803D"] : ["#D97706", "#92400E"]}
                    start={{ x: 0, y: 0 }}
                    end={{ x: 1, y: 1 }}
                    style={styles.calcResultBadge}
                  >
                    <Text style={styles.calcResultBadgeText}>{blendResult.blendLabel}</Text>
                  </LinearGradient>
                  <Text style={[styles.calcResultTitle, { color: colors.foreground }]}>Blend Result</Text>
                </View>

                {/* Stats Row */}
                <View style={styles.calcResultStats}>
                  <View style={[styles.calcResultStat, { backgroundColor: colors.primary + "14" }]}>
                    <Text style={[styles.calcResultStatValue, { color: colors.foreground }]}>{blendResult.e85Gallons.toFixed(2)}</Text>
                    <Text style={[styles.calcResultStatLabel, { color: colors.muted }]}>gal E85</Text>
                  </View>
                  <View style={[styles.calcResultStat, { backgroundColor: "#D97706" + "14" }]}>
                    <Text style={[styles.calcResultStatValue, { color: colors.foreground }]}>{blendResult.gasGallons.toFixed(2)}</Text>
                    <Text style={[styles.calcResultStatLabel, { color: colors.muted }]}>gal Gas</Text>
                  </View>
                  <View style={[styles.calcResultStat, { backgroundColor: colors.primary + "14" }]}>
                    <Text style={[styles.calcResultStatValue, { color: colors.foreground }]}>{blendResult.estimatedOctane.toFixed(1)}</Text>
                    <Text style={[styles.calcResultStatLabel, { color: colors.muted }]}>Octane</Text>
                  </View>
                </View>

                {/* Detail rows */}
                <View style={[styles.calcResultDetails, { borderTopColor: colors.border }]}>
                  <View style={styles.calcResultDetailRow}>
                    <Text style={[styles.calcResultDetailLabel, { color: colors.muted }]}>Final Ethanol</Text>
                    <Text style={[styles.calcResultDetailValue, { color: colors.foreground }]}>{blendResult.finalEthanolPercent.toFixed(1)}%</Text>
                  </View>
                  <View style={styles.calcResultDetailRow}>
                    <Text style={[styles.calcResultDetailLabel, { color: colors.muted }]}>Total to Add</Text>
                    <Text style={[styles.calcResultDetailValue, { color: colors.foreground }]}>{(blendResult.e85Gallons + blendResult.gasGallons).toFixed(2)} gal</Text>
                  </View>
                </View>

                {blendResult.errorMessage && (
                  <View style={[styles.calcResultWarning, { backgroundColor: colors.warning + "18" }]}>
                    <Text style={[styles.calcResultWarningText, { color: colors.warning }]}>{blendResult.errorMessage}</Text>
                  </View>
                )}

                {/* Estimate disclaimer */}
                <View style={[styles.calcDisclaimer, { borderTopColor: colors.border }]}>
                  <Text style={[styles.calcDisclaimerText, { color: colors.muted }]}>
                    Results are estimates — E85 ethanol content varies by season (51–83%). Verify compatibility with your tuner.
                  </Text>
                </View>

                {/* Pump Instructions */}
                <Pressable
                  onPress={() => setShowPumpInstructions((v) => !v)}
                  style={({ pressed }) => [styles.pumpInstructionsToggle, { borderTopColor: colors.border, opacity: pressed ? 0.7 : 1 }]}
                >
                  <Text style={[styles.pumpInstructionsToggleText, { color: colors.primary }]}>⛽ Pump Instructions</Text>
                  <Text style={[styles.pumpInstructionsToggleChevron, { color: colors.muted }]}>{showPumpInstructions ? "▲" : "▼"}</Text>
                </Pressable>
                {showPumpInstructions && (
                  <View style={[styles.pumpInstructionsBody, { backgroundColor: colors.primary + "0D" }]}>
                    {blendResult.e85Gallons > 0 && (
                      <View style={styles.pumpStep}>
                        <View style={[styles.pumpStepBadge, { backgroundColor: colors.primary }]}>
                          <Text style={styles.pumpStepNum}>1</Text>
                        </View>
                        <Text style={[styles.pumpStepText, { color: colors.foreground }]}>
                          Fill <Text style={{ fontWeight: "700" }}>{blendResult.e85Gallons.toFixed(2)} gal E85</Text> first
                        </Text>
                      </View>
                    )}
                    {blendResult.gasGallons > 0 && (
                      <View style={styles.pumpStep}>
                        <View style={[styles.pumpStepBadge, { backgroundColor: "#D97706" }]}>
                          <Text style={styles.pumpStepNum}>{blendResult.e85Gallons > 0 ? "2" : "1"}</Text>
                        </View>
                        <Text style={[styles.pumpStepText, { color: colors.foreground }]}>
                          Top off with <Text style={{ fontWeight: "700" }}>{blendResult.gasGallons.toFixed(2)} gal {blendInputs.gasOctane >= 91 ? `${blendInputs.gasOctane} oct` : "regular"} gas</Text>
                        </Text>
                      </View>
                    )}
                    <View style={styles.pumpStep}>
                      <View style={[styles.pumpStepBadge, { backgroundColor: colors.success }]}>
                        <Text style={styles.pumpStepNum}>✓</Text>
                      </View>
                      <Text style={[styles.pumpStepText, { color: colors.foreground }]}>
                        Result: <Text style={{ fontWeight: "700" }}>{blendResult.blendLabel}</Text> · {blendResult.estimatedOctane.toFixed(1)} oct
                      </Text>
                    </View>
                  </View>
                )}

                {/* Log This Fill-Up */}
                <Pressable
                  onPress={handleLogFillUp}
                  style={({ pressed }) => [styles.logFillUpBtn, { backgroundColor: colors.success + "18", borderColor: colors.success + "40", opacity: pressed ? 0.75 : 1 }]}
                >
                  <Text style={[styles.logFillUpBtnText, { color: colors.success }]}>+ Log This Fill-Up</Text>
                </Pressable>
              </View>
            )}

            {/* Save Blend Name */}
            <View style={styles.calcSection}>
              <Text style={[styles.calcInputLabel, { color: colors.muted }]}>Save this blend (optional)</Text>
              <TextInput
                style={[styles.calcInput, { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground }]}
                placeholder="e.g. Track Day E50"
                placeholderTextColor={colors.muted}
                value={blendName}
                onChangeText={setBlendName}
                returnKeyType="done"
              />
            </View>

            {/* Save Button */}
            <Pressable
              onPress={handleSaveBlend}
              style={({ pressed }) => [styles.calcSaveBtn, { backgroundColor: colors.primary, opacity: pressed ? 0.8 : 1 }]}
            >
              <IconSymbol name="bookmark.fill" size={18} color="#fff" />
              <Text style={styles.calcSaveBtnText}>Save Blend</Text>
            </Pressable>

          </ScrollView>
        </View>
      </Modal>

      {/* ── Log Fill-Up Modal ── */}
      <Modal
        visible={logFillUpModalVisible}
        animationType="slide"
        presentationStyle="pageSheet"
        onRequestClose={() => setLogFillUpModalVisible(false)}
      >
        <View style={[styles.modalContainer, { backgroundColor: colors.background }]}>
          <View style={[styles.modalHeader, { borderBottomColor: colors.border }]}>
            <Pressable
              onPress={() => setLogFillUpModalVisible(false)}
              style={({ pressed }) => [styles.modalHeaderBtn, { opacity: pressed ? 0.6 : 1 }]}
            >
              <Text style={[styles.modalCancelText, { color: colors.primary }]}>Cancel</Text>
            </Pressable>
            <Text style={[styles.modalTitle, { color: colors.foreground }]}>Log Fill-Up</Text>
            <Pressable
              onPress={handleConfirmLogFillUp}
              style={({ pressed }) => [styles.modalHeaderBtn, { opacity: pressed ? 0.6 : 1 }]}
            >
              <Text style={[styles.modalSaveText, { color: colors.primary }]}>Log</Text>
            </Pressable>
          </View>
          <ScrollView style={styles.modalContent} keyboardShouldPersistTaps="handled">
            {blendResult && (
              <View style={[styles.logFillUpSummary, { backgroundColor: colors.surface, borderColor: colors.border }]}>
                <Text style={[styles.logFillUpSummaryTitle, { color: colors.foreground }]}>{blendResult.blendLabel} Blend</Text>
                <Text style={[styles.logFillUpSummaryDetail, { color: colors.muted }]}>
                  {blendResult.e85Gallons.toFixed(2)} gal E85 + {blendResult.gasGallons.toFixed(2)} gal Gas = {(blendResult.e85Gallons + blendResult.gasGallons).toFixed(2)} gal total
                </Text>
              </View>
            )}
            <Text style={[styles.modalLabel, { color: colors.foreground, marginTop: 16 }]}>Station Name (optional)</Text>
            <TextInput
              style={[styles.modalInput, { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground }]}
              placeholder="e.g. QuikTrip #123"
              placeholderTextColor={colors.muted}
              value={logFillUpStation}
              onChangeText={setLogFillUpStation}
              returnKeyType="next"
            />
            <Text style={[styles.modalLabel, { color: colors.foreground }]}>Odometer (miles)</Text>
            <TextInput
              style={[styles.modalInput, { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground }]}
              placeholder={currentMileage > 0 ? currentMileage.toString() : "0"}
              placeholderTextColor={colors.muted}
              keyboardType="number-pad"
              value={logFillUpOdometer}
              onChangeText={setLogFillUpOdometer}
              returnKeyType="next"
            />
            <Text style={[styles.modalLabel, { color: colors.foreground }]}>E85 Price / gal (optional)</Text>
            <TextInput
              style={[styles.modalInput, { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground }]}
              placeholder="e.g. 2.89"
              placeholderTextColor={colors.muted}
              keyboardType="decimal-pad"
              value={logFillUpPriceE85}
              onChangeText={setLogFillUpPriceE85}
              returnKeyType="next"
            />
            <Text style={[styles.modalLabel, { color: colors.foreground }]}>Gas Price / gal (optional)</Text>
            <TextInput
              style={[styles.modalInput, { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground }]}
              placeholder="e.g. 3.49"
              placeholderTextColor={colors.muted}
              keyboardType="decimal-pad"
              value={logFillUpPriceGas}
              onChangeText={setLogFillUpPriceGas}
              returnKeyType="done"
            />
          </ScrollView>
        </View>
      </Modal>

      {/* ── Odometer Modal ── */}
      <Modal
        visible={odometerModalVisible}
        animationType="slide"
        presentationStyle="pageSheet"
        onRequestClose={() => setOdometerModalVisible(false)}
      >
        <View style={[styles.modalContainer, { backgroundColor: colors.background }]}>
          <View style={[styles.modalHeader, { borderBottomColor: colors.border }]}>
            <Pressable
              onPress={() => setOdometerModalVisible(false)}
              style={({ pressed }) => [styles.modalHeaderBtn, { opacity: pressed ? 0.6 : 1 }]}
            >
              <Text style={[styles.modalCancelText, { color: colors.primary }]}>Cancel</Text>
            </Pressable>
            <Text style={[styles.modalTitle, { color: colors.foreground }]}>Update Odometer</Text>
            <Pressable
              onPress={handleSaveOdometer}
              style={({ pressed }) => [styles.modalHeaderBtn, { opacity: pressed ? 0.6 : 1 }]}
            >
              <Text style={[styles.modalSaveText, { color: colors.primary }]}>Save</Text>
            </Pressable>
          </View>
          <View style={styles.modalContent}>
            <Text style={[styles.modalLabel, { color: colors.foreground }]}>Current Odometer Reading (miles)</Text>
            <TextInput
              style={[styles.modalInput, { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground }]}
              placeholder="0"
              placeholderTextColor={colors.muted}
              keyboardType="number-pad"
              value={odometerInput}
              onChangeText={setOdometerInput}
              autoFocus
            />
            <Text style={[styles.modalHint, { color: colors.muted }]}>Current: {currentMileage.toLocaleString()} mi</Text>
          </View>
        </View>
      </Modal>

      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        {/* ── Header ── */}
        <View style={styles.header}>
          <View>
            <Text style={[styles.headerTitle, { color: colors.foreground }]}>Garage</Text>
            <Text style={[styles.headerSubtitle, { color: colors.muted }]}>
              Your car & maintenance overview
            </Text>
          </View>
          <Pressable
            style={[styles.headerBtn, { backgroundColor: colors.surface, borderColor: colors.border }]}
            onPress={() => router.push("/(tabs)/settings")}
          >
            <IconSymbol name="gearshape.fill" size={20} color={colors.muted} />
          </Pressable>
        </View>

        {/* ── Car Hero ── */}
        {activeCar ? (
          <CarHero car={activeCar} currentMileage={currentMileage} onPress={handleCarPress} onOdometerPress={handleUpdateOdometer} />
        ) : (
          <Animated.View entering={FadeInDown.duration(300)} style={styles.heroWrapper}>
            <Pressable
              style={[styles.noCarCard, { backgroundColor: colors.surface, borderColor: colors.border }]}
              onPress={() => router.push("/(tabs)/garage")}
            >
              <Text style={styles.noCarEmoji}>🚗</Text>
              <View style={{ flex: 1 }}>
                <Text style={[styles.noCarTitle, { color: colors.foreground }]}>Add your car</Text>
                <Text style={[styles.noCarSub, { color: colors.muted }]}>
                  Set up a profile to track reminders and fill-ups
                </Text>
              </View>
              <IconSymbol name="chevron.right" size={18} color={colors.muted} />
            </Pressable>
          </Animated.View>
        )}

        {/* ── Quick Actions ── */}
        <Animated.View entering={FadeInDown.duration(300).delay(80)} style={styles.quickActions}>
          <Pressable
            style={[styles.quickActionBtn, { backgroundColor: colors.surface, borderColor: colors.border, borderWidth: 1 }]}
            onPress={() => router.push("/(tabs)/stations")}
          >
            <IconSymbol name="map.fill" size={20} color={colors.foreground} />
            <Text style={[styles.quickActionText, { color: colors.foreground }]}>Find E85</Text>
          </Pressable>
          <Pressable
            style={[styles.quickActionBtn, { backgroundColor: colors.surface, borderColor: colors.border, borderWidth: 1 }]}
            onPress={() => router.push("/(tabs)/fuel-log")}
          >
            <IconSymbol name="list.bullet.clipboard.fill" size={20} color={colors.foreground} />
            <Text style={[styles.quickActionText, { color: colors.foreground }]}>Fill-Up Log</Text>
          </Pressable>
          <Pressable
            style={[styles.quickActionBtn, { backgroundColor: colors.surface, borderColor: colors.border, borderWidth: 1 }]}
            onPress={() => router.push("/(tabs)/reminders")}
          >
            <IconSymbol name="bell.fill" size={20} color={colors.foreground} />
            <Text style={[styles.quickActionText, { color: colors.foreground }]}>Reminders</Text>
          </Pressable>
        </Animated.View>

        {/* ── Reminders Strip ── */}
        <Animated.View entering={FadeInDown.duration(300).delay(120)}>
          <View style={styles.sectionHeader}>
            <Text style={[styles.sectionTitle, { color: colors.foreground }]}>Reminders</Text>
            <Pressable onPress={handleAddReminder} style={styles.sectionAction}>
              <IconSymbol name="plus" size={16} color={colors.primary} />
              <Text style={[styles.sectionActionText, { color: colors.primary }]}>Add</Text>
            </Pressable>
          </View>

          {reminders.length > 0 && (() => {
            const next = reminders[0];
            const meta = getCategoryMeta(next.category);
            const { label, color } = getUrgencyLabel(next, currentMileage);
            return (
              <Pressable
                style={[styles.nextServiceRow, { backgroundColor: colors.surface, borderColor: colors.border }]}
                onPress={handleReminderPress}
              >
                <Text style={styles.nextServiceIcon}>{meta.icon}</Text>
                <Text style={[styles.nextServiceLabel, { color: colors.foreground }]} numberOfLines={1}>
                  {next.name}
                </Text>
                <Text style={[styles.nextServiceUrgency, { color }]}>{label}</Text>
                <IconSymbol name="chevron.right" size={14} color={colors.muted} />
              </Pressable>
            );
          })()}

          {reminders.length === 0 ? (
            <Pressable
              style={[styles.emptyRemindersCard, { backgroundColor: colors.surface, borderColor: colors.border }]}
              onPress={handleAddReminder}
            >
              <Text style={styles.emptyRemindersEmoji}>🔔</Text>
              <Text style={[styles.emptyRemindersText, { color: colors.muted }]}>
                {activeCar ? "No reminders — tap Add to create one" : "Add a car to start tracking maintenance"}
              </Text>
            </Pressable>
          ) : (
            <ScrollView
              horizontal
              showsHorizontalScrollIndicator={false}
              contentContainerStyle={styles.remindersStrip}
            >
              {reminders.map((rem, i) => (
                <Animated.View key={rem.id} entering={FadeInRight.delay(i * 50).duration(250)}>
                  <ReminderCard
                    reminder={rem}
                    currentMileage={currentMileage}
                    onPress={handleReminderPress}
                  />
                </Animated.View>
              ))}
              {/* Add button card */}
              <Pressable
                style={[styles.addReminderCard, { backgroundColor: colors.surface, borderColor: colors.border }]}
                onPress={handleAddReminder}
              >
                <View style={[styles.addReminderIcon, { backgroundColor: colors.primary + "22" }]}>
                  <IconSymbol name="plus" size={22} color={colors.primary} />
                </View>
                <Text style={[styles.addReminderText, { color: colors.muted }]}>New</Text>
              </Pressable>
            </ScrollView>
          )}
        </Animated.View>

        <View style={{ height: 32 }} />
      </ScrollView>
    </ScreenContainer>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  scrollContent: {
    paddingBottom: 24,
  },

  // Header
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 20,
    paddingTop: 16,
    paddingBottom: 12,
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
  headerBtn: {
    width: 38,
    height: 38,
    borderRadius: 19,
    alignItems: "center",
    justifyContent: "center",
    borderWidth: StyleSheet.hairlineWidth,
  },

  // Car Hero
  heroWrapper: {
    marginHorizontal: 16,
    marginBottom: 16,
  },
  heroGradient: {
    borderRadius: 20,
    padding: 20,
    gap: 16,
  },
  heroTop: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
  },
  heroEmojiWrap: {
    width: 52,
    height: 52,
    borderRadius: 26,
    backgroundColor: "rgba(255,255,255,0.25)",
    alignItems: "center",
    justifyContent: "center",
  },
  heroEmoji: {
    fontSize: 26,
  },
  heroInfo: {
    flex: 1,
  },
  heroCarName: {
    fontSize: 18,
    fontWeight: "700",
    color: "#fff",
    letterSpacing: -0.3,
  },
  heroCarSub: {
    fontSize: 13,
    color: "rgba(255,255,255,0.75)",
    marginTop: 2,
  },
  heroActiveBadge: {
    backgroundColor: "rgba(255,255,255,0.25)",
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 12,
  },
  heroActiveBadgeText: {
    color: "#fff",
    fontSize: 12,
    fontWeight: "600",
  },
  heroStats: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: "rgba(0,0,0,0.18)",
    borderRadius: 14,
    paddingVertical: 12,
    paddingHorizontal: 8,
  },
  heroStat: {
    flex: 1,
    alignItems: "center",
    gap: 2,
  },
  heroStatValue: {
    fontSize: 17,
    fontWeight: "700",
    color: "#fff",
  },
  heroStatLabel: {
    fontSize: 11,
    color: "rgba(255,255,255,0.7)",
  },
  heroStatDivider: {
    width: 1,
    height: 32,
    backgroundColor: "rgba(255,255,255,0.25)",
  },

  // No car card
  noCarCard: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    borderRadius: 20,
    padding: 20,
    borderWidth: StyleSheet.hairlineWidth,
  },
  noCarEmoji: {
    fontSize: 32,
  },
  noCarTitle: {
    fontSize: 16,
    fontWeight: "600",
  },
  noCarSub: {
    fontSize: 13,
    marginTop: 2,
    lineHeight: 18,
  },

  // Quick actions
  quickActions: {
    flexDirection: "row",
    gap: 10,
    marginHorizontal: 16,
    marginBottom: 20,
  },
  quickActionBtn: {
    flex: 1,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 6,
    paddingVertical: 12,
    borderRadius: 14,
  },
  quickActionText: {
    color: "#fff",
    fontWeight: "600",
    fontSize: 13,
  },

  // Section header
  sectionHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 20,
    marginBottom: 10,
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: "700",
    letterSpacing: -0.3,
  },
  sectionAction: {
    flexDirection: "row",
    alignItems: "center",
    gap: 3,
  },
  sectionActionText: {
    fontSize: 14,
    fontWeight: "500",
  },

  // Reminders strip
  remindersStrip: {
    paddingLeft: 16,
    paddingRight: 8,
    paddingBottom: 4,
    gap: 10,
    flexDirection: "row",
    marginBottom: 20,
  },
  reminderCard: {
    width: 150,
    borderRadius: 16,
    padding: 14,
    gap: 8,
    borderWidth: StyleSheet.hairlineWidth,
  },
  reminderCardIcon: {
    width: 40,
    height: 40,
    borderRadius: 20,
    alignItems: "center",
    justifyContent: "center",
  },
  reminderCardIconText: {
    fontSize: 20,
  },
  reminderCardName: {
    fontSize: 13,
    fontWeight: "600",
    lineHeight: 17,
  },
  reminderCardBadge: {
    alignSelf: "flex-start",
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: 8,
  },
  reminderCardBadgeText: {
    fontSize: 11,
    fontWeight: "600",
  },
  nextServiceRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderRadius: 10,
    borderWidth: StyleSheet.hairlineWidth,
    marginHorizontal: 16,
    marginBottom: 8,
  },
  nextServiceIcon: {
    fontSize: 16,
  },
  nextServiceLabel: {
    flex: 1,
    fontSize: 14,
    fontWeight: "500",
  },
  nextServiceUrgency: {
    fontSize: 13,
    fontWeight: "600",
  },
  addReminderCard: {
    width: 100,
    borderRadius: 16,
    padding: 14,
    gap: 8,
    alignItems: "center",
    justifyContent: "center",
    borderWidth: StyleSheet.hairlineWidth,
    borderStyle: "dashed",
  },
  addReminderIcon: {
    width: 40,
    height: 40,
    borderRadius: 20,
    alignItems: "center",
    justifyContent: "center",
  },
  addReminderText: {
    fontSize: 12,
    fontWeight: "500",
  },
  emptyRemindersCard: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    marginHorizontal: 16,
    marginBottom: 20,
    padding: 16,
    borderRadius: 16,
    borderWidth: StyleSheet.hairlineWidth,
  },
  emptyRemindersEmoji: {
    fontSize: 24,
  },
  emptyRemindersText: {
    flex: 1,
    fontSize: 13,
    lineHeight: 18,
  },

  // Fill-ups
  fillUpsCard: {
    marginHorizontal: 16,
    borderRadius: 16,
    overflow: "hidden",
    marginBottom: 4,
  },
  fillUpRow: {
    flexDirection: "row",
    paddingHorizontal: 16,
    paddingVertical: 12,
    gap: 12,
  },
  timelineDotWrap: {
    width: 12,
    alignItems: "center",
    paddingTop: 4,
  },
  timelineDot: {
    width: 10,
    height: 10,
    borderRadius: 5,
  },
  timelineLine: {
    flex: 1,
    width: 1,
    marginTop: 4,
  },
  fillUpContent: {
    flex: 1,
    gap: 4,
  },
  fillUpHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 8,
  },
  fillUpStation: {
    flex: 1,
    fontSize: 14,
    fontWeight: "600",
  },
  fillUpDate: {
    fontSize: 12,
  },
  fillUpMeta: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    flexWrap: "wrap",
  },
  blendBadge: {
    paddingHorizontal: 7,
    paddingVertical: 2,
    borderRadius: 6,
  },
  blendBadgeText: {
    fontSize: 11,
    fontWeight: "700",
  },
  fillUpDetail: {
    fontSize: 12,
  },
  emptyFillUpsCard: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    marginHorizontal: 16,
    padding: 16,
    borderRadius: 16,
    borderWidth: StyleSheet.hairlineWidth,
  },
  emptyFillUpsEmoji: {
    fontSize: 24,
  },
  emptyFillUpsText: {
    flex: 1,
    fontSize: 13,
    lineHeight: 18,
  },

  // Calculator modal
  calcScroll: {
    flex: 1,
  },
  calcScrollContent: {
    paddingHorizontal: 16,
    paddingTop: 16,
    paddingBottom: 40,
    gap: 4,
  },
  calcSection: {
    marginBottom: 20,
  },
  calcSectionTitle: {
    fontSize: 15,
    fontWeight: "700",
    marginBottom: 10,
    letterSpacing: -0.2,
  },
  quickBlendRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
  },
  quickBlendBtn: {
    flex: 1,
    minWidth: "30%",
    paddingVertical: 11,
    paddingHorizontal: 8,
    borderRadius: 10,
    borderWidth: 1.5,
    alignItems: "center",
  },
  quickBlendText: {
    fontSize: 14,
    fontWeight: "700",
  },
  calcInputRow: {
    flexDirection: "row",
    gap: 10,
    marginBottom: 10,
  },
  calcInputHalf: {
    flex: 1,
  },
  calcInputLabel: {
    fontSize: 12,
    fontWeight: "500",
    marginBottom: 5,
  },
  calcInput: {
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 11,
    fontSize: 15,
    fontWeight: "500",
  },
  advancedToggle: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 6,
    paddingVertical: 10,
    borderWidth: 1,
    borderRadius: 10,
    marginBottom: 16,
  },
  advancedToggleText: {
    fontSize: 13,
    fontWeight: "600",
  },
  calcResultCard: {
    borderRadius: 16,
    borderWidth: 1.5,
    overflow: "hidden",
    marginBottom: 20,
  },
  calcResultHeader: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    padding: 16,
    paddingBottom: 12,
  },
  calcResultBadge: {
    paddingHorizontal: 14,
    paddingVertical: 6,
    borderRadius: 20,
  },
  calcResultBadgeText: {
    color: "#fff",
    fontSize: 16,
    fontWeight: "800",
    letterSpacing: 0.5,
  },
  calcResultTitle: {
    fontSize: 17,
    fontWeight: "700",
  },
  calcResultStats: {
    flexDirection: "row",
    gap: 8,
    paddingHorizontal: 16,
    paddingBottom: 12,
  },
  calcResultStat: {
    flex: 1,
    borderRadius: 10,
    padding: 10,
    alignItems: "center",
  },
  calcResultStatValue: {
    fontSize: 18,
    fontWeight: "800",
    letterSpacing: -0.5,
  },
  calcResultStatLabel: {
    fontSize: 11,
    fontWeight: "500",
    marginTop: 2,
  },
  calcResultDetails: {
    borderTopWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 16,
    paddingVertical: 10,
    gap: 6,
  },
  calcResultDetailRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
  },
  calcResultDetailLabel: {
    fontSize: 13,
  },
  calcResultDetailValue: {
    fontSize: 13,
    fontWeight: "600",
  },
  calcResultWarning: {
    marginHorizontal: 16,
    marginBottom: 12,
    borderRadius: 8,
    padding: 10,
  },
  calcResultWarningText: {
    fontSize: 12,
    fontWeight: "500",
    lineHeight: 17,
  },
  calcDisclaimer: {
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  calcDisclaimerText: {
    fontSize: 11,
    lineHeight: 16,
    textAlign: "center",
  },
  calcSaveBtn: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    paddingVertical: 15,
    borderRadius: 14,
    marginTop: 4,
  },
  calcSaveBtnText: {
    color: "#fff",
    fontSize: 16,
    fontWeight: "700",
  },

  // Odometer modal
  modalContainer: {
    flex: 1,
  },
  modalHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 20,
    paddingTop: Platform.OS === "ios" ? 16 : 12,
    paddingBottom: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  modalHeaderBtn: {
    paddingVertical: 8,
    paddingHorizontal: 12,
  },
  modalCancelText: {
    fontSize: 16,
    fontWeight: "500",
  },
  modalSaveText: {
    fontSize: 16,
    fontWeight: "600",
  },
  modalTitle: {
    fontSize: 18,
    fontWeight: "700",
  },
  modalContent: {
    flex: 1,
    paddingHorizontal: 20,
    paddingTop: 24,
  },
  modalLabel: {
    fontSize: 16,
    fontWeight: "600",
    marginBottom: 12,
  },
  modalInput: {
    borderWidth: 1,
    borderRadius: 12,
    paddingHorizontal: 16,
    paddingVertical: 14,
    fontSize: 16,
    marginBottom: 12,
  },
  modalHint: {
    fontSize: 13,
  },
  pumpInstructionsToggle: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingTop: 12,
    marginTop: 8,
    borderTopWidth: 1,
  },
  pumpInstructionsToggleText: {
    fontSize: 14,
    fontWeight: "600",
  },
  pumpInstructionsToggleChevron: {
    fontSize: 11,
  },
  pumpInstructionsBody: {
    borderRadius: 10,
    padding: 12,
    marginTop: 10,
    gap: 10,
  },
  pumpStep: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
  },
  pumpStepBadge: {
    width: 26,
    height: 26,
    borderRadius: 13,
    justifyContent: "center",
    alignItems: "center",
  },
  pumpStepNum: {
    color: "#fff",
    fontSize: 13,
    fontWeight: "700",
  },
  pumpStepText: {
    flex: 1,
    fontSize: 14,
    lineHeight: 20,
  },
  logFillUpBtn: {
    marginTop: 12,
    borderRadius: 10,
    borderWidth: 1,
    paddingVertical: 12,
    alignItems: "center",
  },
  logFillUpBtnText: {
    fontSize: 15,
    fontWeight: "700",
  },
  logFillUpSummary: {
    borderRadius: 12,
    borderWidth: 1,
    padding: 14,
    marginBottom: 4,
  },
  logFillUpSummaryTitle: {
    fontSize: 16,
    fontWeight: "700",
    marginBottom: 4,
  },
  logFillUpSummaryDetail: {
    fontSize: 13,
    lineHeight: 18,
  },
});

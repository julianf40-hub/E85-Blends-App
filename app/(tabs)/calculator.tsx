import React, { useState, useCallback, useEffect } from "react";
import {
  ScrollView,
  Text,
  View,
  Pressable,
  Platform,
  StyleSheet,
  Modal,
  TextInput,
  Alert,
} from "react-native";
import * as Haptics from "expo-haptics";
import { useFocusEffect, useRouter } from "expo-router";
import {
  calculateBlend,
  DEFAULT_INPUTS,
  COMMON_BLENDS,
  type BlendInputs,
  type BlendResult,
} from "@/lib/blend-calculator";

// ─── Blend Guide Data ────────────────────────────────────────────────────────

const BLEND_GUIDE_TIERS = [
  {
    label: "E20–E30",
    min: 20,
    max: 30,
    range: 5,      // 5 = max range, 1 = min
    power: 2,
    octane: "91–94",
    tag: "Daily / Range",
    tagColor: "#3B82F6",
    desc: "Best MPG retention. Minimal tune required. Safe for most flex-fuel vehicles.",
  },
  {
    label: "E40–E50",
    min: 40,
    max: 50,
    range: 3,
    power: 3,
    octane: "95–98",
    tag: "Balanced",
    tagColor: "#10B981",
    desc: "Good balance of power and range. Popular street/track blend. Moderate tune recommended.",
  },
  {
    label: "E60–E70",
    min: 60,
    max: 70,
    range: 2,
    power: 4,
    octane: "99–102",
    tag: "Performance",
    tagColor: "#F59E0B",
    desc: "Significant power gains. Noticeable MPG drop (~15–25%). Tune and flex-fuel kit required.",
  },
  {
    label: "E85",
    min: 75,
    max: 85,
    range: 1,
    power: 5,
    octane: "105+",
    tag: "Max Power",
    tagColor: "#EF4444",
    desc: "Maximum octane and cooling. ~25–35% MPG reduction. Full E85 tune required.",
  },
];
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import { getActiveCar, type CarProfile, updateCarProfile } from "@/lib/garage";
import { getSavedBlends, type SavedBlend } from "@/lib/blend-storage";

// ─── Helpers ─────────────────────────────────────────────────────────────────

function sanitize(text: string): string {
  return text.replace(/[^0-9.]/g, "").replace(/(\..*)\./g, "$1");
}

// ─── Main Screen ─────────────────────────────────────────────────────────────

export default function CalculatorScreen() {
  const colors = useColors();
  const router = useRouter();

  // Car context (auto-fills tank size, default blend, octane)
  const [activeCar, setActiveCar] = useState<CarProfile | null>(null);
  const [currentMileage, setCurrentMileage] = useState(0);

  // Calculator state
  const [blendInputs, setBlendInputs] = useState<BlendInputs>(DEFAULT_INPUTS);
  const [blendResult, setBlendResult] = useState<BlendResult | null>(
    () => calculateBlend(DEFAULT_INPUTS)
  );
  const [calcStrings, setCalcStrings] = useState({
    tankSize: DEFAULT_INPUTS.tankSize.toString(),
    currentFuelLevel: DEFAULT_INPUTS.currentFuelLevel.toString(),
    currentEthanolPercent: DEFAULT_INPUTS.currentEthanolPercent.toString(),
    targetEthanolPercent: DEFAULT_INPUTS.targetEthanolPercent.toString(),
    e85EthanolPercent: DEFAULT_INPUTS.e85EthanolPercent.toString(),
    gasEthanolPercent: DEFAULT_INPUTS.gasEthanolPercent.toString(),
    gasOctane: DEFAULT_INPUTS.gasOctane.toString(),
  });
  const [calcAutoFilled, setCalcAutoFilled] = useState(false);
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [pumpMode, setPumpMode] = useState(false);
  const [showPumpInstructions, setShowPumpInstructions] = useState(false);
  const [blendName, setBlendName] = useState("");
  const [showBlendGuide, setShowBlendGuide] = useState(false);
  const [savedBlends, setSavedBlends] = useState<SavedBlend[]>([]);
  const [showSavedBlends, setShowSavedBlends] = useState(false);

  // Log fill-up modal
  const [logFillUpModalVisible, setLogFillUpModalVisible] = useState(false);
  const [logFillUpOdometer, setLogFillUpOdometer] = useState("");
  const [logFillUpStation, setLogFillUpStation] = useState("");
  const [logFillUpPriceE85, setLogFillUpPriceE85] = useState("");
  const [logFillUpPriceGas, setLogFillUpPriceGas] = useState("");
  const [logFillUpE85Gallons, setLogFillUpE85Gallons] = useState("");
  const [logFillUpGasGallons, setLogFillUpGasGallons] = useState("");
  const [logFillUpGasOctane, setLogFillUpGasOctane] = useState<"87" | "89" | "91/92" | "93">("91/92");

  // ── Load active car on focus ──────────────────────────────────────────────
  useFocusEffect(
    useCallback(() => {
      (async () => {
        try {
          const car = await getActiveCar();
          setActiveCar(car);
          if (car) {
            // Auto-fill from last fuel log entry
            const { loadFuelLog } = await import("@/lib/fuel-log");
            const logs = await loadFuelLog();
            const lastWithEthanol = logs.find((l: any) => l.currentEthanolPct != null);
            const autoEthanolPct = lastWithEthanol?.currentEthanolPct ?? null;

            const fuelLogOdometer = logs.length > 0 ? logs[0].odometer : 0;
            const carOdometer = car.odometer ?? 0;
            setCurrentMileage(Math.max(fuelLogOdometer, carOdometer));

            const inputs: BlendInputs = {
              ...DEFAULT_INPUTS,
              tankSize: car.tankSize,
              currentEthanolPercent:
                autoEthanolPct !== null
                  ? autoEthanolPct
                  : DEFAULT_INPUTS.currentEthanolPercent,
              targetEthanolPercent: car.defaultBlend,
              gasOctane: car.requiredOctane,
              gasEthanolPercent: car.gasEthanolPercent ?? 0,
            };
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
          }
        } catch (e) {
          console.warn("CalculatorScreen: failed to load car data", e);
        }
        // Load saved blends
        try {
          const blends = await getSavedBlends();
          setSavedBlends(blends);
        } catch (e) {
          console.warn("CalculatorScreen: failed to load saved blends", e);
        }
      })();
    }, [])
  );

  const handleLoadSavedBlend = useCallback(
    (blend: SavedBlend) => {
      const inputs: BlendInputs = {
        ...blendInputs,
        targetEthanolPercent: blend.result.finalEthanolPercent,
      };
      setBlendInputs(inputs);
      setCalcStrings((prev) => ({
        ...prev,
        targetEthanolPercent: blend.result.finalEthanolPercent.toString(),
      }));
      setBlendResult(calculateBlend(inputs));
      setShowSavedBlends(false);
      if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    },
    [blendInputs]
  );

  // ── Input handlers ────────────────────────────────────────────────────────

  const handleCalcStringChange = useCallback(
    (key: keyof typeof calcStrings, text: string) => {
      const s = sanitize(text);
      setCalcStrings((prev) => ({ ...prev, [key]: s }));
      const num = parseFloat(s);
      if (!isNaN(num)) {
        const updated = { ...blendInputs, [key]: num };
        setBlendInputs(updated);
        setBlendResult(calculateBlend(updated));
      }
    },
    [blendInputs]
  );

  const handleBlendInputChange = useCallback(
    (key: keyof BlendInputs, value: number) => {
      const updated = { ...blendInputs, [key]: value };
      setBlendInputs(updated);
      setCalcStrings((prev) => ({ ...prev, [key]: value.toString() }));
      setBlendResult(calculateBlend(updated));
    },
    [blendInputs]
  );

  const handleQuickBlend = useCallback(
    (targetEthanol: number) => {
      if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
      handleBlendInputChange("targetEthanolPercent", targetEthanol);
    },
    [handleBlendInputChange]
  );

  // ── Save blend ────────────────────────────────────────────────────────────

  const handleSaveBlend = useCallback(async () => {
    if (!blendResult) return;
    try {
      const { saveBlend } = await import("@/lib/blend-storage");
      await saveBlend(blendInputs, blendResult, blendName.trim() || undefined);
      if (Platform.OS !== "web")
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      Alert.alert("Saved!", `${blendResult.blendLabel} blend saved to My Blends.`);
      setBlendName("");
    } catch {
      Alert.alert("Error", "Failed to save blend.");
    }
  }, [blendInputs, blendResult, blendName]);

  // ── Log fill-up ───────────────────────────────────────────────────────────

  const handleLogFillUp = useCallback(() => {
    if (!blendResult) return;
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    setLogFillUpOdometer(currentMileage > 0 ? currentMileage.toString() : "");
    setLogFillUpStation("");
    setLogFillUpPriceE85("");
    setLogFillUpPriceGas("");
    setLogFillUpE85Gallons(blendResult.e85Gallons.toFixed(2));
    setLogFillUpGasGallons(blendResult.gasGallons.toFixed(2));
    setLogFillUpGasOctane(
      blendInputs.gasOctane >= 93
        ? "93"
        : blendInputs.gasOctane === 89
          ? "89"
          : blendInputs.gasOctane === 91 || blendInputs.gasOctane === 92
            ? "91/92"
            : "87"
    );
    setLogFillUpModalVisible(true);
  }, [blendResult, currentMileage, blendInputs.gasOctane]);

  const handleConfirmLogFillUp = useCallback(async () => {
    if (!blendResult) return;
    try {
      const { addFuelEntry } = await import("@/lib/fuel-log");
      const actualE85Gallons = parseFloat(logFillUpE85Gallons) || 0;
      const actualGasGallons = parseFloat(logFillUpGasGallons) || 0;
      const totalGallons = actualE85Gallons + actualGasGallons;
      if (totalGallons <= 0) {
        Alert.alert("Invalid gallons", "Please enter actual pumped gallons greater than 0.");
        return;
      }
      const priceE85 = parseFloat(logFillUpPriceE85) || 0;
      const priceGas = parseFloat(logFillUpPriceGas) || 0;
      const blendedPricePerGal =
        totalGallons > 0
          ? (priceE85 * actualE85Gallons + priceGas * actualGasGallons) /
            totalGallons
          : 0;
      const odometer = parseInt(logFillUpOdometer) || currentMileage;
      await addFuelEntry({
        date: new Date().toISOString(),
        stationName: logFillUpStation.trim() || "Unknown station",
        blendRatio: blendResult.finalEthanolPercent,
        gallonsAdded: totalGallons,
        e85Gallons: actualE85Gallons > 0 ? actualE85Gallons : undefined,
        gasGallons: actualGasGallons > 0 ? actualGasGallons : undefined,
        gasOctane: logFillUpGasOctane,
        e85PricePerGallon: priceE85 > 0 ? priceE85 : undefined,
        gasPricePerGallon: priceGas > 0 ? priceGas : undefined,
        pricePerGallon: blendedPricePerGal,
        totalPrice: blendedPricePerGal * totalGallons,
        odometer,
        notes: `Calculator blend: ${blendResult.blendLabel}`,
      });
      if (activeCar && odometer > currentMileage) {
        await updateCarProfile(activeCar.id, { ...activeCar, odometer });
        setCurrentMileage(odometer);
      }
      setLogFillUpModalVisible(false);
      if (Platform.OS !== "web")
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      Alert.alert("Logged!", `${totalGallons.toFixed(2)} gal fill-up added to Fuel Log.`);
    } catch {
      Alert.alert("Error", "Failed to log fill-up.");
    }
  }, [
    blendResult,
    logFillUpOdometer,
    logFillUpStation,
    logFillUpPriceE85,
    logFillUpPriceGas,
    logFillUpE85Gallons,
    logFillUpGasGallons,
    logFillUpGasOctane,
    currentMileage,
    activeCar,
  ]);

  // ─────────────────────────────────────────────────────────────────────────
  // RENDER
  // ─────────────────────────────────────────────────────────────────────────

  return (
    <ScreenContainer>
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
              <View
                style={[
                  styles.logFillUpSummary,
                  { backgroundColor: colors.surface, borderColor: colors.border },
                ]}
              >
                <Text style={[styles.logFillUpSummaryTitle, { color: colors.foreground }]}>
                  {blendResult.blendLabel} Blend
                </Text>
                <Text style={[styles.logFillUpSummaryDetail, { color: colors.muted }]}>
                  {blendResult.e85Gallons.toFixed(2)} gal E85 +{" "}
                  {blendResult.gasGallons.toFixed(2)} gal Gas ={" "}
                  {(blendResult.e85Gallons + blendResult.gasGallons).toFixed(2)} gal total
                </Text>
              </View>
            )}
            <Text style={[styles.modalLabel, { color: colors.foreground, marginTop: 16 }]}>
              Station Name (optional)
            </Text>
            <TextInput
              style={[
                styles.modalInput,
                { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
              ]}
              placeholder="e.g. QuikTrip #123"
              placeholderTextColor={colors.muted}
              value={logFillUpStation}
              onChangeText={setLogFillUpStation}
              returnKeyType="next"
            />
            <Text style={[styles.modalLabel, { color: colors.foreground }]}>
              Actual E85 Gallons Pumped
            </Text>
            <TextInput
              style={[
                styles.modalInput,
                { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
              ]}
              placeholder={blendResult?.e85Gallons.toFixed(2) ?? "0"}
              placeholderTextColor={colors.muted}
              keyboardType="decimal-pad"
              value={logFillUpE85Gallons}
              onChangeText={(v) => setLogFillUpE85Gallons(v.replace(/[^\d.]/g, ""))}
              returnKeyType="next"
            />
            <Text style={[styles.modalLabel, { color: colors.foreground }]}>
              Actual Gasoline Gallons Pumped
            </Text>
            <TextInput
              style={[
                styles.modalInput,
                { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
              ]}
              placeholder={blendResult?.gasGallons.toFixed(2) ?? "0"}
              placeholderTextColor={colors.muted}
              keyboardType="decimal-pad"
              value={logFillUpGasGallons}
              onChangeText={(v) => setLogFillUpGasGallons(v.replace(/[^\d.]/g, ""))}
              returnKeyType="next"
            />
            <Text style={[styles.modalLabel, { color: colors.foreground }]}>
              Gasoline Grade / Octane
            </Text>
            <View style={styles.modalOctaneRow}>
              {(["87", "89", "91/92", "93"] as const).map((opt) => {
                const selected = logFillUpGasOctane === opt;
                return (
                  <Pressable
                    key={opt}
                    onPress={() => setLogFillUpGasOctane(opt)}
                    style={({ pressed }) => [
                      styles.modalOctaneChip,
                      {
                        backgroundColor: selected ? colors.primary + "18" : colors.surface,
                        borderColor: selected ? colors.primary : colors.border,
                        opacity: pressed ? 0.75 : 1,
                      },
                    ]}
                  >
                    <Text
                      style={[
                        styles.modalOctaneChipText,
                        { color: selected ? colors.primary : colors.foreground },
                      ]}
                    >
                      {opt}
                    </Text>
                  </Pressable>
                );
              })}
            </View>
            <Text style={[styles.modalLabel, { color: colors.foreground }]}>
              Odometer (miles)
            </Text>
            <TextInput
              style={[
                styles.modalInput,
                { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
              ]}
              placeholder={currentMileage > 0 ? currentMileage.toString() : "0"}
              placeholderTextColor={colors.muted}
              keyboardType="number-pad"
              value={logFillUpOdometer}
              onChangeText={setLogFillUpOdometer}
              returnKeyType="next"
            />
            <Text style={[styles.modalLabel, { color: colors.foreground }]}>
              E85 Price / gal (optional)
            </Text>
            <TextInput
              style={[
                styles.modalInput,
                { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
              ]}
              placeholder="e.g. 2.89"
              placeholderTextColor={colors.muted}
              keyboardType="decimal-pad"
              value={logFillUpPriceE85}
              onChangeText={setLogFillUpPriceE85}
              returnKeyType="next"
            />
            <Text style={[styles.modalLabel, { color: colors.foreground }]}>
              Gasoline ({logFillUpGasOctane}) Price / gal (optional)
            </Text>
            <TextInput
              style={[
                styles.modalInput,
                { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
              ]}
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

      {/* ── Main Calculator Content ── */}
      <ScrollView
        style={styles.scroll}
        contentContainerStyle={styles.scrollContent}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      >
        {/* Header */}
        <View style={styles.header}>
          <View>
            <Text style={[styles.headerTitle, { color: colors.foreground }]}>E85 Calculator</Text>
            <Text style={[styles.headerSubtitle, { color: colors.muted }]}>
              {activeCar
                ? (activeCar.nickname || `${activeCar.year} ${activeCar.make} ${activeCar.model}`.trim() || "My Car")
                : "Add a car in Garage to auto-fill"}
            </Text>
          </View>
          {/* Pump Mode Toggle */}
          <Pressable
            onPress={() => {
              if (Platform.OS !== "web")
                Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
              setPumpMode((v) => !v);
            }}
            style={({ pressed }) => [
              styles.pumpToggle,
              {
                backgroundColor: pumpMode ? colors.success + "22" : colors.surface,
                borderColor: pumpMode ? colors.success : colors.border,
                opacity: pressed ? 0.7 : 1,
              },
            ]}
          >
            <Text style={{ fontSize: 15 }}>⛽</Text>
            <Text
              style={[
                styles.pumpToggleText,
                { color: pumpMode ? colors.success : colors.muted },
              ]}
            >
              {pumpMode ? "At Pump" : "Pump"}
            </Text>
          </Pressable>
        </View>

        {/* Pump Mode Banner */}
        {pumpMode && (
          <View
            style={[
              styles.pumpBanner,
              { backgroundColor: colors.success + "14", borderColor: colors.success + "30" },
            ]}
          >
            <Text style={{ fontSize: 13 }}>⛽</Text>
            <Text style={[styles.pumpBannerText, { color: colors.success }]}>
              At-Pump Mode — results show numbered fill instructions
            </Text>
          </View>
        )}

        {pumpMode && (
          <View style={[styles.pumpQuickCard, { backgroundColor: colors.surface, borderColor: colors.success + "40" }]}>
            <Text style={[styles.pumpQuickTitle, { color: colors.foreground }]}>Quick Pump Inputs</Text>
            <Text style={[styles.pumpQuickLabel, { color: colors.muted }]}>Current tank level</Text>
            <View style={styles.pumpLevelRow}>
              {[
                { l: "E", v: "0" },
                { l: "¼", v: "25" },
                { l: "½", v: "50" },
                { l: "¾", v: "75" },
              ].map((item) => {
                const isActive = calcStrings.currentFuelLevel === item.v;
                return (
                  <Pressable
                    key={`pump-${item.v}`}
                    onPress={() => handleCalcStringChange("currentFuelLevel", item.v)}
                    style={({ pressed }) => [
                      styles.pumpLevelChip,
                      {
                        backgroundColor: isActive ? colors.success : colors.background,
                        borderColor: isActive ? colors.success : colors.border,
                      },
                      pressed && { opacity: 0.75 },
                    ]}
                  >
                    <Text style={[styles.pumpLevelChipText, { color: isActive ? "#fff" : colors.foreground }]}>
                      {item.l}
                    </Text>
                  </Pressable>
                );
              })}
            </View>
            <Text style={[styles.pumpQuickLabel, { color: colors.muted }]}>Target blend</Text>
            <View style={styles.pumpTargetRow}>
              {COMMON_BLENDS.map((blend) => {
                const isActive = blendInputs.targetEthanolPercent === blend.value;
                return (
                  <Pressable
                    key={`pump-target-${blend.value}`}
                    onPress={() => handleQuickBlend(blend.value)}
                    style={({ pressed }) => [
                      styles.pumpTargetChip,
                      {
                        backgroundColor: isActive ? colors.primary : colors.background,
                        borderColor: isActive ? colors.primary : colors.border,
                      },
                      pressed && { opacity: 0.75 },
                    ]}
                  >
                    <Text style={[styles.pumpTargetChipText, { color: isActive ? "#fff" : colors.foreground }]}>
                      {blend.label}
                    </Text>
                  </Pressable>
                );
              })}
            </View>
          </View>
        )}

        {/* ── Target Blend Presets ── */}
        <View style={styles.section}>
          <Text style={[styles.sectionTitle, { color: colors.foreground }]}>Target Blend</Text>
          <View style={styles.quickBlendRow}>
            {COMMON_BLENDS.map((blend) => {
              const isActive = blendInputs.targetEthanolPercent === blend.value;
              return (
                <Pressable
                  key={blend.value}
                  onPress={() => handleQuickBlend(blend.value)}
                  style={({ pressed }) => [
                    styles.quickBlendBtn,
                    {
                      backgroundColor: isActive ? colors.primary : colors.surface,
                      borderColor: isActive ? colors.primary : colors.border,
                      opacity: pressed ? 0.75 : 1,
                    },
                  ]}
                >
                  <Text
                    style={[
                      styles.quickBlendText,
                      { color: isActive ? "#fff" : colors.foreground },
                    ]}
                  >
                    {blend.label}
                  </Text>
                </Pressable>
              );
            })}
          </View>
        </View>

        {/* ── Saved Blends ── */}
        {!pumpMode && savedBlends.length > 0 && (
          <>
            <Pressable
              onPress={() => {
                if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                setShowSavedBlends((v) => !v);
              }}
              style={({ pressed }) => [
                styles.blendGuideToggle,
                { borderColor: colors.border, opacity: pressed ? 0.7 : 1 },
              ]}
            >
              <Text style={[styles.blendGuideToggleText, { color: colors.primary }]}>
                ⭐ Saved Blends ({savedBlends.length})
              </Text>
              <Text style={[styles.blendGuideToggleChevron, { color: colors.muted }]}>
                {showSavedBlends ? "▲" : "▼"}
              </Text>
            </Pressable>

            {showSavedBlends && (
              <View style={[styles.blendGuideCard, { backgroundColor: colors.surface, borderColor: colors.border }]}>
                {savedBlends.map((blend) => {
                  const label = blend.name || blend.result.blendLabel;
                  const isActive = blendInputs.targetEthanolPercent === blend.result.finalEthanolPercent;
                  return (
                    <Pressable
                      key={blend.id}
                      onPress={() => handleLoadSavedBlend(blend)}
                      style={({ pressed }) => [
                        styles.blendGuideRow,
                        {
                          backgroundColor: isActive ? colors.primary + "14" : "transparent",
                          borderLeftColor: isActive ? colors.primary : "transparent",
                          opacity: pressed ? 0.75 : 1,
                        },
                      ]}
                    >
                      <View style={styles.blendGuideLeft}>
                        <Text style={[styles.blendGuideLabel, { color: colors.foreground }]}>
                          {label}
                        </Text>
                        <Text style={[styles.blendGuideDesc, { color: colors.muted }]}>
                          {blend.result.blendLabel} · {new Date(blend.date).toLocaleDateString()}
                        </Text>
                      </View>
                    </Pressable>
                  );
                })}
              </View>
            )}
          </>
        )}

        {/* ── Blend Guide ── */}
        {!pumpMode && <Pressable
          onPress={() => {
            if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
            setShowBlendGuide((v) => !v);
          }}
          style={({ pressed }) => [
            styles.blendGuideToggle,
            { borderColor: colors.border, opacity: pressed ? 0.7 : 1 },
          ]}
        >
          <Text style={[styles.blendGuideToggleText, { color: colors.primary }]}>
            📊 Blend Guide — Range vs Power
          </Text>
          <Text style={[styles.blendGuideToggleChevron, { color: colors.muted }]}>
            {showBlendGuide ? "▲" : "▼"}
          </Text>
        </Pressable>}

        {!pumpMode && showBlendGuide && (
          <View style={[styles.blendGuideCard, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            {BLEND_GUIDE_TIERS.map((tier) => {
              // Highlight if current target falls in this tier
              const isActive =
                blendInputs.targetEthanolPercent >= tier.min &&
                blendInputs.targetEthanolPercent <= tier.max;
              return (
                <Pressable
                  key={tier.label}
                  onPress={() => {
                    // Tap a tier to jump to its midpoint blend
                    const mid = Math.round((tier.min + tier.max) / 2);
                    handleQuickBlend(mid);
                    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                  }}
                  style={({ pressed }) => [
                    styles.blendGuideRow,
                    {
                      backgroundColor: isActive ? tier.tagColor + "14" : "transparent",
                      borderLeftColor: isActive ? tier.tagColor : "transparent",
                      opacity: pressed ? 0.75 : 1,
                    },
                  ]}
                >
                  {/* Left: label + tag + desc */}
                  <View style={styles.blendGuideLeft}>
                    <View style={styles.blendGuideLabelRow}>
                      <Text style={[styles.blendGuideLabel, { color: colors.foreground }]}>
                        {tier.label}
                      </Text>
                      <View style={[styles.blendGuideTag, { backgroundColor: tier.tagColor + "22" }]}>
                        <Text style={[styles.blendGuideTagText, { color: tier.tagColor }]}>
                          {tier.tag}
                        </Text>
                      </View>
                      <Text style={[styles.blendGuideOctane, { color: colors.muted }]}>
                        {tier.octane} oct
                      </Text>
                    </View>
                    <Text style={[styles.blendGuideDesc, { color: colors.muted }]}>
                      {tier.desc}
                    </Text>
                  </View>

                  {/* Right: range/power bars */}
                  <View style={styles.blendGuideBars}>
                    <View style={styles.blendGuideBarRow}>
                      <Text style={[styles.blendGuideBarLabel, { color: colors.muted }]}>Range</Text>
                      <View style={styles.blendGuideBarTrack}>
                        {[1, 2, 3, 4, 5].map((dot) => (
                          <View
                            key={dot}
                            style={[
                              styles.blendGuideBarDot,
                              {
                                backgroundColor:
                                  dot <= tier.range ? "#3B82F6" : colors.border,
                              },
                            ]}
                          />
                        ))}
                      </View>
                    </View>
                    <View style={styles.blendGuideBarRow}>
                      <Text style={[styles.blendGuideBarLabel, { color: colors.muted }]}>Power</Text>
                      <View style={styles.blendGuideBarTrack}>
                        {[1, 2, 3, 4, 5].map((dot) => (
                          <View
                            key={dot}
                            style={[
                              styles.blendGuideBarDot,
                              {
                                backgroundColor:
                                  dot <= tier.power ? "#EF4444" : colors.border,
                              },
                            ]}
                          />
                        ))}
                      </View>
                    </View>
                  </View>
                </Pressable>
              );
            })}
            <View style={[styles.blendGuideFooter, { borderTopColor: colors.border }]}>
              <Text style={[styles.blendGuideFooterText, { color: colors.muted }]}>
                Tap a tier to set target blend · Estimates only — verify with your tuner
              </Text>
            </View>
          </View>
        )}

        {/* ── Tank Info ── */}
        <View style={styles.section}>
          <Text style={[styles.sectionTitle, { color: colors.foreground }]}>Tank Info</Text>
          <View style={styles.inputRow}>
            {/* Tank Size */}
            <View style={styles.inputHalf}>
              <Text style={[styles.inputLabel, { color: colors.muted }]}>Tank Size (gal)</Text>
              <TextInput
                style={[
                  styles.input,
                  { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
                ]}
                keyboardType="decimal-pad"
                placeholder="16"
                placeholderTextColor={colors.muted}
                value={calcStrings.tankSize}
                onChangeText={(t) => handleCalcStringChange("tankSize", t)}
                returnKeyType="done"
              />
            </View>
            {/* Current Level */}
            <View style={styles.inputHalf}>
              <Text style={[styles.inputLabel, { color: colors.muted }]}>Current Level (%)</Text>
              <TextInput
                style={[
                  styles.input,
                  { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
                ]}
                keyboardType="decimal-pad"
                placeholder="0"
                placeholderTextColor={colors.muted}
                value={calcStrings.currentFuelLevel}
                onChangeText={(t) => handleCalcStringChange("currentFuelLevel", t)}
                returnKeyType="done"
              />
              {/* Level chips */}
              <View style={styles.chipRow}>
                {[
                  { l: "E", v: "0" },
                  { l: "¼", v: "25" },
                  { l: "½", v: "50" },
                  { l: "¾", v: "75" },
                ].map((item) => {
                  const isActive = calcStrings.currentFuelLevel === item.v;
                  return (
                    <Pressable
                      key={item.v}
                      onPress={() => handleCalcStringChange("currentFuelLevel", item.v)}
                      style={({ pressed }) => [
                        styles.chip,
                        {
                          backgroundColor: isActive ? "#D97706" : colors.surface,
                          borderColor: isActive ? "#D97706" : colors.border,
                          opacity: pressed ? 0.7 : 1,
                        },
                      ]}
                    >
                      <Text
                        style={[
                          styles.chipText,
                          { color: isActive ? "#fff" : colors.foreground },
                        ]}
                      >
                        {item.l}
                      </Text>
                    </Pressable>
                  );
                })}
              </View>
            </View>
          </View>

          <View style={styles.inputRow}>
            {/* Current Ethanol */}
            <View style={styles.inputHalf}>
              <View style={{ flexDirection: "row", alignItems: "center", gap: 6, marginBottom: 2 }}>
                <Text style={[styles.inputLabel, { color: colors.muted, marginBottom: 0 }]}>
                  Current Fuel Ethanol %
                </Text>
                {calcAutoFilled && (
                  <View
                    style={{
                      backgroundColor: colors.primary + "22",
                      borderRadius: 4,
                      paddingHorizontal: 5,
                      paddingVertical: 1,
                    }}
                  >
                    <Text style={{ fontSize: 10, color: colors.primary, fontWeight: "700" }}>
                      AUTO
                    </Text>
                  </View>
                )}
              </View>
              <TextInput
                style={[
                  styles.input,
                  {
                    backgroundColor: colors.surface,
                    borderColor: calcAutoFilled ? colors.primary + "60" : colors.border,
                    color: colors.foreground,
                  },
                ]}
                keyboardType="decimal-pad"
                placeholder="10"
                placeholderTextColor={colors.muted}
                value={calcStrings.currentEthanolPercent}
                onChangeText={(t) => {
                  handleCalcStringChange("currentEthanolPercent", t);
                  setCalcAutoFilled(false);
                }}
                returnKeyType="done"
              />
            </View>
            {/* Target Ethanol */}
            <View style={styles.inputHalf}>
              <Text style={[styles.inputLabel, { color: colors.muted }]}>Target Ethanol %</Text>
              <TextInput
                style={[
                  styles.input,
                  { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
                ]}
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

        {/* ── Advanced Toggle ── */}
        {!pumpMode && <Pressable
          onPress={() => setShowAdvanced((v) => !v)}
          style={({ pressed }) => [
            styles.advancedToggle,
            { borderColor: colors.border, opacity: pressed ? 0.7 : 1 },
          ]}
        >
          <Text style={[styles.advancedToggleText, { color: colors.primary }]}>
            {showAdvanced ? "Hide Advanced Settings" : "Show Advanced Settings"}
          </Text>
          <IconSymbol
            name={showAdvanced ? "chevron.up" : "chevron.down"}
            size={14}
            color={colors.primary}
          />
        </Pressable>}

        {/* ── Advanced Inputs ── */}
        {!pumpMode && showAdvanced && (
          <View style={styles.section}>
            <Text style={[styles.sectionTitle, { color: colors.foreground }]}>Fuel Properties</Text>
            <View style={styles.inputRow}>
              <View style={styles.inputHalf}>
                <Text style={[styles.inputLabel, { color: colors.muted }]}>E85 Ethanol %</Text>
                <TextInput
                  style={[
                    styles.input,
                    { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
                  ]}
                  keyboardType="decimal-pad"
                  placeholder="85"
                  placeholderTextColor={colors.muted}
                  value={calcStrings.e85EthanolPercent}
                  onChangeText={(t) => handleCalcStringChange("e85EthanolPercent", t)}
                  returnKeyType="done"
                />
              </View>
              <View style={styles.inputHalf}>
                <Text style={[styles.inputLabel, { color: colors.muted }]}>Gas Ethanol %</Text>
                <TextInput
                  style={[
                    styles.input,
                    { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
                  ]}
                  keyboardType="decimal-pad"
                  placeholder="0"
                  placeholderTextColor={colors.muted}
                  value={calcStrings.gasEthanolPercent}
                  onChangeText={(t) => handleCalcStringChange("gasEthanolPercent", t)}
                  returnKeyType="done"
                />
                <Text style={[styles.hint, { color: colors.muted }]}>0% for pure 91/93 oct</Text>
              </View>
            </View>
            <View style={styles.inputRow}>
              <View style={styles.inputHalf}>
                <Text style={[styles.inputLabel, { color: colors.muted }]}>Gas Octane</Text>
                <TextInput
                  style={[
                    styles.input,
                    { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
                  ]}
                  keyboardType="decimal-pad"
                  placeholder="93"
                  placeholderTextColor={colors.muted}
                  value={calcStrings.gasOctane}
                  onChangeText={(t) => handleCalcStringChange("gasOctane", t)}
                  returnKeyType="done"
                />
                {/* Octane chips */}
                <View style={styles.chipRow}>
                  {[87, 89, 91, 93].map((oct) => {
                    const isActive = calcStrings.gasOctane === String(oct);
                    return (
                      <Pressable
                        key={oct}
                        onPress={() => handleCalcStringChange("gasOctane", String(oct))}
                        style={({ pressed }) => [
                          styles.chip,
                          {
                            backgroundColor: isActive ? colors.primary : colors.surface,
                            borderColor: isActive ? colors.primary : colors.border,
                            opacity: pressed ? 0.7 : 1,
                          },
                        ]}
                      >
                        <Text
                          style={[
                            styles.chipText,
                            { color: isActive ? "#fff" : colors.foreground },
                          ]}
                        >
                          {oct}
                        </Text>
                      </Pressable>
                    );
                  })}
                </View>
              </View>
            </View>
          </View>
        )}

        {/* ── Results ── */}
        {blendResult && !blendResult.isValid && blendResult.errorMessage && (
          <View style={[styles.resultCard, { backgroundColor: colors.surface, borderColor: colors.warning + "40" }]}>
            <View style={{ flexDirection: "row", alignItems: "center", gap: 10, padding: 16 }}>
              <IconSymbol name="info.circle.fill" size={20} color={colors.warning} />
              <Text style={{ color: colors.warning, fontSize: 14, fontWeight: "600", flex: 1 }}>
                {blendResult.errorMessage}
              </Text>
            </View>
          </View>
        )}
        {blendResult && blendResult.isValid && (
          <>
            {/* Pump Mode: large numbered instructions */}
            {pumpMode ? (
              <View
                style={[
                  styles.resultCard,
                  { backgroundColor: colors.surface, borderColor: colors.success, borderWidth: 2 },
                ]}
              >
                <View
                  style={{
                    backgroundColor: colors.success + "18",
                    borderRadius: 10,
                    padding: 16,
                    marginBottom: 12,
                  }}
                >
                  <Text
                    style={{
                      textAlign: "center",
                      fontSize: 13,
                      fontWeight: "600",
                      color: colors.success,
                      marginBottom: 12,
                      letterSpacing: 0.5,
                    }}
                  >
                    ⛽ PUMP INSTRUCTIONS
                  </Text>
                  {blendResult.e85Gallons > 0 && (
                    <View style={{ flexDirection: "row", alignItems: "center", marginBottom: 10 }}>
                      <View
                        style={{
                          width: 28,
                          height: 28,
                          borderRadius: 14,
                          backgroundColor: colors.primary,
                          alignItems: "center",
                          justifyContent: "center",
                          marginRight: 10,
                        }}
                      >
                        <Text style={{ color: "#fff", fontWeight: "700", fontSize: 14 }}>1</Text>
                      </View>
                      <Text style={{ color: colors.foreground, fontSize: 16, flex: 1 }}>
                        Add{" "}
                        <Text style={{ fontWeight: "800", fontSize: 20, color: colors.primary }}>
                          {blendResult.e85Gallons.toFixed(2)}
                        </Text>{" "}
                        <Text style={{ fontWeight: "700" }}>gal E85</Text>
                      </Text>
                    </View>
                  )}
                  {blendResult.gasGallons > 0 && (
                    <View style={{ flexDirection: "row", alignItems: "center", marginBottom: 10 }}>
                      <View
                        style={{
                          width: 28,
                          height: 28,
                          borderRadius: 14,
                          backgroundColor: "#D97706",
                          alignItems: "center",
                          justifyContent: "center",
                          marginRight: 10,
                        }}
                      >
                        <Text style={{ color: "#fff", fontWeight: "700", fontSize: 14 }}>
                          {blendResult.e85Gallons > 0 ? "2" : "1"}
                        </Text>
                      </View>
                      <Text style={{ color: colors.foreground, fontSize: 16, flex: 1 }}>
                        Add{" "}
                        <Text style={{ fontWeight: "800", fontSize: 20, color: "#D97706" }}>
                          {blendResult.gasGallons.toFixed(2)}
                        </Text>{" "}
                        <Text style={{ fontWeight: "700" }}>
                          gal{" "}
                          {blendInputs.gasOctane >= 91
                            ? `${blendInputs.gasOctane} oct`
                            : "regular"}
                        </Text>
                      </Text>
                    </View>
                  )}
                  <View style={{ flexDirection: "row", alignItems: "center" }}>
                    <View
                      style={{
                        width: 28,
                        height: 28,
                        borderRadius: 14,
                        backgroundColor: colors.success,
                        alignItems: "center",
                        justifyContent: "center",
                        marginRight: 10,
                      }}
                    >
                      <Text style={{ color: "#fff", fontWeight: "700", fontSize: 14 }}>✓</Text>
                    </View>
                    <Text style={{ color: colors.foreground, fontSize: 15, flex: 1 }}>
                      Result:{" "}
                      <Text style={{ fontWeight: "700" }}>{blendResult.blendLabel}</Text> ·{" "}
                      {blendResult.estimatedOctane.toFixed(1)} oct
                    </Text>
                  </View>
                </View>
                <Pressable
                  onPress={handleLogFillUp}
                  style={({ pressed }) => [
                    styles.logFillUpBtn,
                    {
                      backgroundColor: colors.success + "18",
                      borderColor: colors.success + "40",
                      opacity: pressed ? 0.75 : 1,
                    },
                  ]}
                >
                  <Text style={[styles.logFillUpBtnText, { color: colors.success }]}>
                    + Log This Fill-Up
                  </Text>
                </Pressable>
              </View>
            ) : (
              /* Standard result card */
              <View
                style={[
                  styles.resultCard,
                  { backgroundColor: colors.surface, borderColor: colors.border },
                ]}
              >
                {/* Badge + title */}
                <View style={styles.resultCardHeader}>
                  <View style={[styles.resultBadge, { backgroundColor: colors.primary }]}>
                    <Text style={styles.resultBadgeText}>{blendResult.blendLabel}</Text>
                  </View>
                  <Text style={[styles.resultCardTitle, { color: colors.foreground }]}>
                    Blend Result
                  </Text>
                </View>

                {/* 3-stat row */}
                <View style={styles.resultStats}>
                  <View
                    style={[styles.resultStat, { backgroundColor: colors.primary + "12" }]}
                  >
                    <Text style={[styles.resultStatValue, { color: colors.primary }]}>
                      {blendResult.e85Gallons.toFixed(2)}
                    </Text>
                    <Text style={[styles.resultStatLabel, { color: colors.muted }]}>gal E85</Text>
                  </View>
                  <View
                    style={[styles.resultStat, { backgroundColor: "#D97706" + "12" }]}
                  >
                    <Text style={[styles.resultStatValue, { color: "#D97706" }]}>
                      {blendResult.gasGallons.toFixed(2)}
                    </Text>
                    <Text style={[styles.resultStatLabel, { color: colors.muted }]}>gal Gas</Text>
                  </View>
                  <View
                    style={[styles.resultStat, { backgroundColor: colors.success + "12" }]}
                  >
                    <Text style={[styles.resultStatValue, { color: colors.success }]}>
                      {blendResult.estimatedOctane.toFixed(1)}
                    </Text>
                    <Text style={[styles.resultStatLabel, { color: colors.muted }]}>Octane</Text>
                  </View>
                </View>

                {/* Detail rows */}
                <View style={[styles.resultDetails, { borderTopColor: colors.border }]}>
                  <View style={styles.resultDetailRow}>
                    <Text style={[styles.resultDetailLabel, { color: colors.muted }]}>
                      Final Ethanol
                    </Text>
                    <Text style={[styles.resultDetailValue, { color: colors.foreground }]}>
                      {blendResult.finalEthanolPercent.toFixed(1)}%
                    </Text>
                  </View>
                  <View style={styles.resultDetailRow}>
                    <Text style={[styles.resultDetailLabel, { color: colors.muted }]}>
                      Total to Add
                    </Text>
                    <Text style={[styles.resultDetailValue, { color: colors.foreground }]}>
                      {(blendResult.e85Gallons + blendResult.gasGallons).toFixed(2)} gal
                    </Text>
                  </View>
                </View>

                {blendResult.errorMessage && (
                  <View
                    style={[
                      styles.resultWarning,
                      { backgroundColor: colors.warning + "18" },
                    ]}
                  >
                    <Text style={[styles.resultWarningText, { color: colors.warning }]}>
                      {blendResult.errorMessage}
                    </Text>
                  </View>
                )}

                {/* Pump Instructions toggle */}
                <Pressable
                  onPress={() => setShowPumpInstructions((v) => !v)}
                  style={({ pressed }) => [
                    styles.pumpInstructionsToggle,
                    { borderTopColor: colors.border, opacity: pressed ? 0.7 : 1 },
                  ]}
                >
                  <Text style={[styles.pumpInstructionsToggleText, { color: colors.primary }]}>
                    ⛽ Pump Instructions
                  </Text>
                  <Text style={[styles.pumpInstructionsToggleChevron, { color: colors.muted }]}>
                    {showPumpInstructions ? "▲" : "▼"}
                  </Text>
                </Pressable>
                {showPumpInstructions && (
                  <View
                    style={[
                      styles.pumpInstructionsBody,
                      { backgroundColor: colors.primary + "0D" },
                    ]}
                  >
                    {blendResult.e85Gallons > 0 && (
                      <View style={styles.pumpStep}>
                        <View style={[styles.pumpStepBadge, { backgroundColor: colors.primary }]}>
                          <Text style={styles.pumpStepNum}>1</Text>
                        </View>
                        <Text style={[styles.pumpStepText, { color: colors.foreground }]}>
                          Fill{" "}
                          <Text style={{ fontWeight: "700" }}>
                            {blendResult.e85Gallons.toFixed(2)} gal E85
                          </Text>{" "}
                          first
                        </Text>
                      </View>
                    )}
                    {blendResult.gasGallons > 0 && (
                      <View style={styles.pumpStep}>
                        <View
                          style={[styles.pumpStepBadge, { backgroundColor: "#D97706" }]}
                        >
                          <Text style={styles.pumpStepNum}>
                            {blendResult.e85Gallons > 0 ? "2" : "1"}
                          </Text>
                        </View>
                        <Text style={[styles.pumpStepText, { color: colors.foreground }]}>
                          Top off with{" "}
                          <Text style={{ fontWeight: "700" }}>
                            {blendResult.gasGallons.toFixed(2)} gal{" "}
                            {blendInputs.gasOctane >= 91
                              ? `${blendInputs.gasOctane} oct`
                              : "regular"}{" "}
                            gas
                          </Text>
                        </Text>
                      </View>
                    )}
                    <View style={styles.pumpStep}>
                      <View style={[styles.pumpStepBadge, { backgroundColor: colors.success }]}>
                        <Text style={styles.pumpStepNum}>✓</Text>
                      </View>
                      <Text style={[styles.pumpStepText, { color: colors.foreground }]}>
                        Result:{" "}
                        <Text style={{ fontWeight: "700" }}>{blendResult.blendLabel}</Text> ·{" "}
                        {blendResult.estimatedOctane.toFixed(1)} oct
                      </Text>
                    </View>
                  </View>
                )}

                {/* Log fill-up */}
                <Pressable
                  onPress={handleLogFillUp}
                  style={({ pressed }) => [
                    styles.logFillUpBtn,
                    {
                      backgroundColor: colors.success + "18",
                      borderColor: colors.success + "40",
                      opacity: pressed ? 0.75 : 1,
                    },
                  ]}
                >
                  <Text style={[styles.logFillUpBtnText, { color: colors.success }]}>
                    + Log This Fill-Up
                  </Text>
                </Pressable>
              </View>
            )}
          </>
        )}

        {/* ── Quick Actions Row ── */}
        {blendResult && (
          <View style={styles.quickActionsRow}>
            {/* Save Blend */}
            <Pressable
              onPress={handleSaveBlend}
              style={({ pressed }) => [
                styles.quickActionBtn,
                {
                  backgroundColor: colors.primary + "18",
                  borderColor: colors.primary + "40",
                  opacity: pressed ? 0.7 : 1,
                },
              ]}
            >
              <IconSymbol name="bookmark.fill" size={18} color={colors.primary} />
              <Text style={[styles.quickActionText, { color: colors.primary }]}>Save Blend</Text>
            </Pressable>

            {/* Find Nearby Station */}
            <Pressable
              onPress={() => {
                if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                router.push("/(tabs)/stations");
              }}
              style={({ pressed }) => [
                styles.quickActionBtn,
                {
                  backgroundColor: colors.warning + "18",
                  borderColor: colors.warning + "40",
                  opacity: pressed ? 0.7 : 1,
                },
              ]}
            >
              <IconSymbol name="map.fill" size={18} color={colors.warning} />
              <Text style={[styles.quickActionText, { color: colors.warning }]}>Find Station</Text>
            </Pressable>
          </View>
        )}

        {/* ── Save Blend Name (optional) ── */}
        <View style={[styles.section, { marginTop: 4 }]}>
          <TextInput
            style={[
              styles.input,
              { backgroundColor: colors.surface, borderColor: colors.border, color: colors.foreground },
            ]}
            placeholder="Name this blend (optional, e.g. Track Day E50)"
            placeholderTextColor={colors.muted}
            value={blendName}
            onChangeText={setBlendName}
            returnKeyType="done"
          />
        </View>

        <View style={{ height: 32 }} />
      </ScrollView>
    </ScreenContainer>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  scroll: { flex: 1 },
  scrollContent: { paddingBottom: 40 },

  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 20,
    paddingTop: 16,
    paddingBottom: 12,
  },
  headerTitle: { fontSize: 26, fontWeight: "700", letterSpacing: -0.5 },
  headerSubtitle: { fontSize: 13, marginTop: 2 },

  pumpToggle: {
    flexDirection: "row",
    alignItems: "center",
    gap: 5,
    paddingHorizontal: 12,
    paddingVertical: 7,
    borderRadius: 20,
    borderWidth: 1,
  },
  pumpToggleText: { fontSize: 13, fontWeight: "600" },

  pumpBanner: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    marginHorizontal: 16,
    marginBottom: 8,
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 10,
    borderWidth: 1,
  },
  pumpBannerText: { fontSize: 12, fontWeight: "600", flex: 1 },
  pumpQuickCard: {
    marginHorizontal: 16,
    marginBottom: 10,
    borderRadius: 12,
    borderWidth: 1,
    padding: 12,
  },
  pumpQuickTitle: {
    fontSize: 15,
    fontWeight: "700",
    marginBottom: 8,
  },
  pumpQuickLabel: {
    fontSize: 12,
    fontWeight: "600",
    marginBottom: 6,
  },
  pumpLevelRow: {
    flexDirection: "row",
    gap: 8,
    marginBottom: 10,
  },
  pumpLevelChip: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    borderWidth: 1,
    borderRadius: 10,
    paddingVertical: 10,
  },
  pumpLevelChipText: {
    fontSize: 18,
    fontWeight: "700",
  },
  pumpTargetRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
  },
  pumpTargetChip: {
    minWidth: 74,
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 10,
    alignItems: "center",
  },
  pumpTargetChipText: {
    fontSize: 14,
    fontWeight: "700",
  },

  section: { paddingHorizontal: 16, marginBottom: 4 },
  sectionTitle: { fontSize: 15, fontWeight: "700", marginBottom: 10 },

  quickBlendRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
    marginBottom: 8,
  },
  quickBlendBtn: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 10,
    borderWidth: 1,
    minWidth: 60,
    alignItems: "center",
  },
  quickBlendText: { fontSize: 14, fontWeight: "600" },

  inputRow: { flexDirection: "row", gap: 12, marginBottom: 12 },
  inputHalf: { flex: 1 },
  inputLabel: { fontSize: 12, fontWeight: "500", marginBottom: 6 },
  input: {
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 16,
    fontWeight: "500",
  },
  hint: { fontSize: 11, marginTop: 4 },

  chipRow: { flexDirection: "row", gap: 5, marginTop: 6, flexWrap: "wrap" },
  chip: {
    paddingHorizontal: 9,
    paddingVertical: 4,
    borderRadius: 7,
    borderWidth: 1,
  },
  chipText: { fontSize: 11, fontWeight: "600" },

  advancedToggle: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 6,
    marginHorizontal: 16,
    marginVertical: 8,
    paddingVertical: 12,
    borderWidth: 1,
    borderRadius: 10,
  },
  advancedToggleText: { fontSize: 14, fontWeight: "600" },

  resultCard: {
    marginHorizontal: 16,
    marginVertical: 8,
    borderRadius: 16,
    borderWidth: 1,
    overflow: "hidden",
  },
  resultCardHeader: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    padding: 16,
    paddingBottom: 12,
  },
  resultBadge: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 8,
  },
  resultBadgeText: { color: "#fff", fontWeight: "700", fontSize: 14 },
  resultCardTitle: { fontSize: 17, fontWeight: "700" },

  resultStats: { flexDirection: "row", gap: 8, paddingHorizontal: 16, paddingBottom: 12 },
  resultStat: {
    flex: 1,
    alignItems: "center",
    paddingVertical: 10,
    borderRadius: 10,
  },
  resultStatValue: { fontSize: 22, fontWeight: "800" },
  resultStatLabel: { fontSize: 11, marginTop: 2 },

  resultDetails: {
    borderTopWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 16,
    paddingVertical: 10,
    gap: 6,
  },
  resultDetailRow: { flexDirection: "row", justifyContent: "space-between" },
  resultDetailLabel: { fontSize: 14 },
  resultDetailValue: { fontSize: 14, fontWeight: "600" },

  resultWarning: {
    marginHorizontal: 16,
    marginBottom: 8,
    padding: 10,
    borderRadius: 8,
  },
  resultWarningText: { fontSize: 13 },

  pumpInstructionsToggle: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  pumpInstructionsToggleText: { fontSize: 14, fontWeight: "600" },
  pumpInstructionsToggleChevron: { fontSize: 11 },

  pumpInstructionsBody: { padding: 16, gap: 10 },
  pumpStep: { flexDirection: "row", alignItems: "center", gap: 10 },
  pumpStepBadge: {
    width: 26,
    height: 26,
    borderRadius: 13,
    alignItems: "center",
    justifyContent: "center",
  },
  pumpStepNum: { color: "#fff", fontWeight: "700", fontSize: 13 },
  pumpStepText: { fontSize: 14, flex: 1 },

  logFillUpBtn: {
    margin: 12,
    paddingVertical: 12,
    borderRadius: 10,
    borderWidth: 1,
    alignItems: "center",
  },
  logFillUpBtnText: { fontSize: 15, fontWeight: "700" },

  saveBtn: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    marginHorizontal: 16,
    marginTop: 8,
    paddingVertical: 14,
    borderRadius: 14,
  },
  saveBtnText: { color: "#fff", fontSize: 16, fontWeight: "700" },

  // Modal styles
  modalContainer: { flex: 1 },
  modalHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingVertical: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  modalHeaderBtn: { minWidth: 60 },
  modalCancelText: { fontSize: 16 },
  modalTitle: { fontSize: 17, fontWeight: "700" },
  modalSaveText: { fontSize: 16, fontWeight: "600", textAlign: "right" },
  modalContent: { padding: 16 },
  modalLabel: { fontSize: 14, fontWeight: "600", marginBottom: 6 },
  modalOctaneRow: { flexDirection: "row", flexWrap: "wrap", gap: 8, marginBottom: 12 },
  modalOctaneChip: {
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 10,
    paddingVertical: 7,
  },
  modalOctaneChipText: { fontSize: 13, fontWeight: "700" },
  modalInput: {
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 16,
    marginBottom: 12,
  },
  logFillUpSummary: {
    padding: 14,
    borderRadius: 12,
    borderWidth: 1,
    marginBottom: 8,
  },
  logFillUpSummaryTitle: { fontSize: 16, fontWeight: "700", marginBottom: 4 },
  logFillUpSummaryDetail: { fontSize: 13 },

  quickActionsRow: {
    flexDirection: "row",
    gap: 8,
    marginHorizontal: 16,
    marginTop: 12,
    marginBottom: 4,
  },
  quickActionBtn: {
    flex: 1,
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    gap: 5,
    paddingVertical: 12,
    borderRadius: 12,
    borderWidth: 1,
  },
  quickActionText: { fontSize: 11, fontWeight: "700", textAlign: "center" },

  // Blend Guide styles
  blendGuideToggle: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginHorizontal: 16,
    marginTop: 4,
    marginBottom: 4,
    paddingHorizontal: 14,
    paddingVertical: 11,
    borderRadius: 10,
    borderWidth: 1,
  },
  blendGuideToggleText: { fontSize: 14, fontWeight: "600", flex: 1 },
  blendGuideToggleChevron: { fontSize: 11, marginLeft: 6 },

  blendGuideCard: {
    marginHorizontal: 16,
    marginBottom: 8,
    borderRadius: 14,
    borderWidth: 1,
    overflow: "hidden",
  },
  blendGuideRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 14,
    paddingVertical: 12,
    gap: 12,
    borderLeftWidth: 3,
  },
  blendGuideLeft: { flex: 1 },
  blendGuideLabelRow: { flexDirection: "row", alignItems: "center", gap: 7, flexWrap: "wrap", marginBottom: 4 },
  blendGuideLabel: { fontSize: 14, fontWeight: "700" },
  blendGuideTag: { paddingHorizontal: 7, paddingVertical: 2, borderRadius: 6 },
  blendGuideTagText: { fontSize: 11, fontWeight: "700" },
  blendGuideOctane: { fontSize: 11 },
  blendGuideDesc: { fontSize: 12, lineHeight: 17 },

  blendGuideBars: { gap: 5, minWidth: 80 },
  blendGuideBarRow: { flexDirection: "row", alignItems: "center", gap: 5 },
  blendGuideBarLabel: { fontSize: 10, width: 36, textAlign: "right" },
  blendGuideBarTrack: { flexDirection: "row", gap: 3 },
  blendGuideBarDot: { width: 8, height: 8, borderRadius: 4 },

  blendGuideFooter: {
    borderTopWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 14,
    paddingVertical: 9,
  },
  blendGuideFooterText: { fontSize: 11, textAlign: "center" },
});

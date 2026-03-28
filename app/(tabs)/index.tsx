import { useCallback, useEffect, useRef, useState } from "react";
import {
  ScrollView,
  Text,
  View,
  TextInput,
  Pressable,
  Platform,
  Alert,
  StyleSheet,
  Dimensions,
} from "react-native";
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withTiming,
  withSequence,
  Easing,
  FadeIn,
  FadeInDown,
} from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import { LinearGradient } from "expo-linear-gradient";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import {
  BlendInputs,
  BlendResult,
  DEFAULT_INPUTS,
  COMMON_BLENDS,
  calculateBlend,
} from "@/lib/blend-calculator";
import { saveBlend, getSettings } from "@/lib/blend-storage";
import { getActiveCar, CarProfile } from "@/lib/garage";
import { useFocusEffect } from "expo-router";

const { width: SCREEN_WIDTH } = Dimensions.get("window");

/**
 * String-based input state for all text fields.
 * This allows users to type "18." without it being converted to "18".
 * Numbers are only parsed when the user presses Calculate.
 */
interface InputTexts {
  tankSize: string;
  currentEthanolPercent: string;
  targetEthanolPercent: string;
  e85EthanolPercent: string;
  gasEthanolPercent: string;
  e85Octane: string;
  gasOctane: string;
}

function toInputTexts(inputs: BlendInputs): InputTexts {
  return {
    tankSize: inputs.tankSize.toString(),
    currentEthanolPercent: inputs.currentEthanolPercent.toString(),
    targetEthanolPercent: inputs.targetEthanolPercent.toString(),
    e85EthanolPercent: inputs.e85EthanolPercent.toString(),
    gasEthanolPercent: inputs.gasEthanolPercent.toString(),
    e85Octane: inputs.e85Octane.toString(),
    gasOctane: inputs.gasOctane.toString(),
  };
}

function textsToInputs(texts: InputTexts, currentFuelLevel: number): BlendInputs {
  return {
    tankSize: parseFloat(texts.tankSize) || 0,
    currentFuelLevel,
    currentEthanolPercent: parseFloat(texts.currentEthanolPercent) || 0,
    targetEthanolPercent: parseFloat(texts.targetEthanolPercent) || 0,
    e85EthanolPercent: parseFloat(texts.e85EthanolPercent) || 0,
    gasEthanolPercent: parseFloat(texts.gasEthanolPercent) || 0,
    e85Octane: parseFloat(texts.e85Octane) || 0,
    gasOctane: parseFloat(texts.gasOctane) || 0,
  };
}

/** Only allow digits, one decimal point, and comma (auto-replaced with dot) */
function sanitizeDecimalInput(text: string): string {
  // Replace comma with dot for locale support
  let cleaned = text.replace(",", ".");
  // Allow only digits and one dot
  const parts = cleaned.split(".");
  if (parts.length > 2) {
    cleaned = parts[0] + "." + parts.slice(1).join("");
  }
  // Remove non-numeric non-dot characters
  cleaned = cleaned.replace(/[^\d.]/g, "");
  return cleaned;
}

export default function CalculatorScreen() {
  const colors = useColors();
  const [inputTexts, setInputTexts] = useState<InputTexts>(toInputTexts(DEFAULT_INPUTS));
  const [currentFuelLevel, setCurrentFuelLevel] = useState(0);
  const [result, setResult] = useState<BlendResult | null>(null);
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [activeCar, setActiveCar] = useState<CarProfile | null>(null);
  const resultScale = useSharedValue(1);
  const tankInputRef = useRef<TextInput>(null);

  // Reload active car and settings whenever this tab is focused
  useFocusEffect(
    useCallback(() => {
      (async () => {
        const [settings, car] = await Promise.all([getSettings(), getActiveCar()]);
        setActiveCar(car);
        const inputs: BlendInputs = {
          ...DEFAULT_INPUTS,
          tankSize: car ? car.tankSize : settings.defaultTankSize,
          targetEthanolPercent: car ? car.defaultBlend : DEFAULT_INPUTS.targetEthanolPercent,
          e85EthanolPercent: settings.defaultE85Ethanol,
          gasEthanolPercent: settings.defaultGasEthanol,
          gasOctane: car ? car.requiredOctane : settings.defaultGasOctane,
          e85Octane: settings.defaultE85Octane,
        };
        setInputTexts(toInputTexts(inputs));
      })();
    }, [])
  );

  const handleCalculate = useCallback(() => {
    if (Platform.OS !== "web") {
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    }
    const inputs = textsToInputs(inputTexts, currentFuelLevel);
    const blendResult = calculateBlend(inputs);
    setResult(blendResult);
    resultScale.value = withSequence(
      withTiming(0.97, { duration: 80 }),
      withTiming(1, { duration: 200, easing: Easing.out(Easing.quad) })
    );
  }, [inputTexts, currentFuelLevel, resultScale]);

  const handleSaveBlend = useCallback(async () => {
    if (!result) return;
    if (Platform.OS !== "web") {
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
    }
    try {
      const inputs = textsToInputs(inputTexts, currentFuelLevel);
      await saveBlend(inputs, result);
      Alert.alert("Saved", "Blend saved to My Blends");
    } catch {
      Alert.alert("Error", "Failed to save blend");
    }
  }, [inputTexts, currentFuelLevel, result]);

  const handleBlendChipPress = useCallback(
    (value: number) => {
      if (Platform.OS !== "web") {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
      }
      setInputTexts((prev) => ({ ...prev, targetEthanolPercent: value.toString() }));
    },
    []
  );

  /** Update a text field - keeps raw string so decimals work */
  const updateText = useCallback(
    (key: keyof InputTexts, value: string) => {
      const sanitized = sanitizeDecimalInput(value);
      setInputTexts((prev) => ({ ...prev, [key]: sanitized }));
    },
    []
  );

  const resultAnimStyle = useAnimatedStyle(() => ({
    transform: [{ scale: resultScale.value }],
  }));

  const targetEthanolNum = parseFloat(inputTexts.targetEthanolPercent) || 0;

  return (
    <ScreenContainer>
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      >
        {/* Header */}
        <View style={styles.header}>
          <View style={styles.headerRow}>
            <View
              style={[
                styles.headerIconBg,
                { backgroundColor: colors.primary + "18" },
              ]}
            >
              <IconSymbol
                name="fuelpump.fill"
                size={24}
                color={colors.primary}
              />
            </View>
            <View>
              <Text style={[styles.headerTitle, { color: colors.foreground }]}>
                E85 Blend Calculator
              </Text>
              <Text style={[styles.headerSubtitle, { color: colors.muted }]}>
                Calculate your perfect fuel mix
              </Text>
            </View>
          </View>
        </View>

        {/* Active Car Banner */}
        {activeCar && (
          <Animated.View
            entering={FadeIn.duration(300)}
            style={[
              styles.carBanner,
              { backgroundColor: activeCar.color + "18", borderColor: activeCar.color + "40" },
            ]}
          >
            <Text style={styles.carBannerEmoji}>{activeCar.icon}</Text>
            <View style={{ flex: 1 }}>
              <Text style={[styles.carBannerName, { color: colors.foreground }]}>
                {activeCar.nickname || `${activeCar.year} ${activeCar.make} ${activeCar.model}`.trim() || "Active Car"}
              </Text>
              <Text style={[styles.carBannerSub, { color: colors.muted }]}>
                {activeCar.tankSize} gal tank · E{activeCar.defaultBlend} default
              </Text>
            </View>
            <View style={[styles.carBannerBadge, { backgroundColor: activeCar.color + "30" }]}>
              <Text style={[styles.carBannerBadgeText, { color: activeCar.color }]}>Active</Text>
            </View>
          </Animated.View>
        )}

        {/* Tank Size Input */}
        <Animated.View
          entering={FadeInDown.duration(300).delay(50)}
          style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}
        >
          <Text style={[styles.cardLabel, { color: colors.muted }]}>Tank Size</Text>
          <View style={styles.inputRow}>
            <TextInput
              ref={tankInputRef}
              style={[
                styles.inputLarge,
                { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
              ]}
              value={inputTexts.tankSize}
              onChangeText={(v) => updateText("tankSize", v)}
              keyboardType="default"
              autoCapitalize="none"
              autoCorrect={false}
              returnKeyType="done"
              placeholder="16.5"
              placeholderTextColor={colors.muted}
              selectTextOnFocus
              maxLength={10}
            />
            <Pressable
              onPress={() => {
                const cur = inputTexts.tankSize;
                if (!cur.includes(".")) {
                  updateText("tankSize", cur === "" ? "0." : cur + ".");
                  tankInputRef.current?.focus();
                }
              }}
              style={({ pressed }) => [
                styles.decimalBtn,
                { backgroundColor: colors.primary + "20" },
                pressed && { opacity: 0.6 },
              ]}
            >
              <Text style={[styles.decimalBtnText, { color: colors.primary }]}>.</Text>
            </Pressable>
            <Text style={[styles.unitLabel, { color: colors.muted }]}>gallons</Text>
          </View>
        </Animated.View>

        {/* Current Fuel Level */}
        <Animated.View
          entering={FadeInDown.duration(300).delay(100)}
          style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}
        >
          <Text style={[styles.cardLabel, { color: colors.muted }]}>
            Current Fuel Level
          </Text>
          <View style={styles.fuelLevelRow}>
            {[0, 25, 50, 75].map((level) => (
              <Pressable
                key={level}
                onPress={() => {
                  if (Platform.OS !== "web") {
                    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                  }
                  setCurrentFuelLevel(level);
                }}
                style={({ pressed }) => [
                  styles.fuelLevelChip,
                  {
                    backgroundColor:
                      currentFuelLevel === level
                        ? colors.primary
                        : colors.background,
                    borderColor:
                      currentFuelLevel === level
                        ? colors.primary
                        : colors.border,
                  },
                  pressed && { transform: [{ scale: 0.97 }] },
                ]}
              >
                <Text
                  style={[
                    styles.fuelLevelText,
                    {
                      color:
                        currentFuelLevel === level
                          ? "#FFFFFF"
                          : colors.foreground,
                    },
                  ]}
                >
                  {level === 0 ? "Empty" : `${level}%`}
                </Text>
              </Pressable>
            ))}
          </View>
          {currentFuelLevel > 0 && (
            <View style={styles.subInputRow}>
              <Text style={[styles.subLabel, { color: colors.muted }]}>
                Current ethanol %
              </Text>
              <View style={styles.inlineInputGroup}>
                <TextInput
                  style={[
                    styles.inputSmall,
                    { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
                  ]}
                  value={inputTexts.currentEthanolPercent}
                  onChangeText={(v) => updateText("currentEthanolPercent", v)}
                  keyboardType="default"
                  autoCapitalize="none"
                  autoCorrect={false}
                  returnKeyType="done"
                  selectTextOnFocus
                  maxLength={6}
                />
                <Pressable
                  onPress={() => {
                    const cur = inputTexts.currentEthanolPercent;
                    if (!cur.includes(".")) {
                      updateText("currentEthanolPercent", cur === "" ? "0." : cur + ".");
                    }
                  }}
                  style={({ pressed }) => [
                    styles.decimalBtnSmall,
                    { backgroundColor: colors.primary + "20" },
                    pressed && { opacity: 0.6 },
                  ]}
                >
                  <Text style={[styles.decimalBtnSmallText, { color: colors.primary }]}>.</Text>
                </Pressable>
              </View>
            </View>
          )}
        </Animated.View>

        {/* Target Blend Selection */}
        <Animated.View
          entering={FadeInDown.duration(300).delay(150)}
          style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}
        >
          <Text style={[styles.cardLabel, { color: colors.muted }]}>
            Target Blend
          </Text>
          <View style={styles.blendChipsRow}>
            {COMMON_BLENDS.map((blend) => (
              <Pressable
                key={blend.value}
                onPress={() => handleBlendChipPress(blend.value)}
                style={({ pressed }) => [
                  styles.blendChip,
                  {
                    backgroundColor:
                      targetEthanolNum === blend.value
                        ? colors.primary
                        : colors.background,
                    borderColor:
                      targetEthanolNum === blend.value
                        ? colors.primary
                        : colors.border,
                  },
                  pressed && { transform: [{ scale: 0.97 }] },
                ]}
              >
                <Text
                  style={[
                    styles.blendChipText,
                    {
                      color:
                        targetEthanolNum === blend.value
                          ? "#FFFFFF"
                          : colors.foreground,
                      fontWeight:
                        targetEthanolNum === blend.value ? "700" : "500",
                    },
                  ]}
                >
                  {blend.label}
                </Text>
              </Pressable>
            ))}
          </View>
          <View style={styles.customTargetRow}>
            <Text style={[styles.subLabel, { color: colors.muted }]}>
              Custom target %
            </Text>
            <View style={styles.inlineInputGroup}>
              <TextInput
                style={[
                  styles.inputSmall,
                  { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
                ]}
                value={inputTexts.targetEthanolPercent}
                onChangeText={(v) => updateText("targetEthanolPercent", v)}
                keyboardType="default"
                autoCapitalize="none"
                autoCorrect={false}
                returnKeyType="done"
                selectTextOnFocus
                maxLength={6}
              />
              <Pressable
                onPress={() => {
                  const cur = inputTexts.targetEthanolPercent;
                  if (!cur.includes(".")) {
                    updateText("targetEthanolPercent", cur === "" ? "0." : cur + ".");
                  }
                }}
                style={({ pressed }) => [
                  styles.decimalBtnSmall,
                  { backgroundColor: colors.primary + "20" },
                  pressed && { opacity: 0.6 },
                ]}
              >
                <Text style={[styles.decimalBtnSmallText, { color: colors.primary }]}>.</Text>
              </Pressable>
            </View>
          </View>
        </Animated.View>

        {/* Advanced Settings Toggle */}
        <Pressable
          onPress={() => {
            if (Platform.OS !== "web") {
              Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
            }
            setShowAdvanced(!showAdvanced);
          }}
          style={({ pressed }) => [
            styles.advancedToggle,
            pressed && { opacity: 0.7 },
          ]}
        >
          <IconSymbol
            name="slider.horizontal.3"
            size={18}
            color={colors.primary}
          />
          <Text style={[styles.advancedToggleText, { color: colors.primary }]}>
            {showAdvanced ? "Hide" : "Show"} Advanced Settings
          </Text>
        </Pressable>

        {/* Advanced Settings */}
        {showAdvanced && (
          <Animated.View
            entering={FadeInDown.duration(200)}
            style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}
          >
            <View style={styles.advancedGrid}>
              <View style={styles.advancedItem}>
                <Text style={[styles.subLabel, { color: colors.muted }]}>
                  E85 Ethanol %
                </Text>
                <View style={styles.inlineInputGroup}>
                  <TextInput
                    style={[
                      styles.inputSmall,
                      { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
                    ]}
                    value={inputTexts.e85EthanolPercent}
                    onChangeText={(v) => updateText("e85EthanolPercent", v)}
                    keyboardType="default"
                    autoCapitalize="none"
                    autoCorrect={false}
                    returnKeyType="done"
                  />
                  <Pressable
                    onPress={() => {
                      const cur = inputTexts.e85EthanolPercent;
                      if (!cur.includes(".")) {
                        updateText("e85EthanolPercent", cur === "" ? "0." : cur + ".");
                      }
                    }}
                    style={({ pressed }) => [
                      styles.decimalBtnSmall,
                      { backgroundColor: colors.primary + "20" },
                      pressed && { opacity: 0.6 },
                    ]}
                  >
                    <Text style={[styles.decimalBtnSmallText, { color: colors.primary }]}>.</Text>
                  </Pressable>
                </View>
              </View>
              <View style={styles.advancedItem}>
                <Text style={[styles.subLabel, { color: colors.muted }]}>
                  Gas Ethanol %
                </Text>
                <View style={styles.inlineInputGroup}>
                  <TextInput
                    style={[
                      styles.inputSmall,
                      { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
                    ]}
                    value={inputTexts.gasEthanolPercent}
                    onChangeText={(v) => updateText("gasEthanolPercent", v)}
                    keyboardType="default"
                    autoCapitalize="none"
                    autoCorrect={false}
                    returnKeyType="done"
                  />
                  <Pressable
                    onPress={() => {
                      const cur = inputTexts.gasEthanolPercent;
                      if (!cur.includes(".")) {
                        updateText("gasEthanolPercent", cur === "" ? "0." : cur + ".");
                      }
                    }}
                    style={({ pressed }) => [
                      styles.decimalBtnSmall,
                      { backgroundColor: colors.primary + "20" },
                      pressed && { opacity: 0.6 },
                    ]}
                  >
                    <Text style={[styles.decimalBtnSmallText, { color: colors.primary }]}>.</Text>
                  </Pressable>
                </View>
              </View>
              <View style={styles.advancedItem}>
                <Text style={[styles.subLabel, { color: colors.muted }]}>
                  E85 Octane
                </Text>
                <View style={styles.inlineInputGroup}>
                  <TextInput
                    style={[
                      styles.inputSmall,
                      { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
                    ]}
                    value={inputTexts.e85Octane}
                    onChangeText={(v) => updateText("e85Octane", v)}
                    keyboardType="default"
                    autoCapitalize="none"
                    autoCorrect={false}
                    returnKeyType="done"
                  />
                  <Pressable
                    onPress={() => {
                      const cur = inputTexts.e85Octane;
                      if (!cur.includes(".")) {
                        updateText("e85Octane", cur === "" ? "0." : cur + ".");
                      }
                    }}
                    style={({ pressed }) => [
                      styles.decimalBtnSmall,
                      { backgroundColor: colors.primary + "20" },
                      pressed && { opacity: 0.6 },
                    ]}
                  >
                    <Text style={[styles.decimalBtnSmallText, { color: colors.primary }]}>.</Text>
                  </Pressable>
                </View>
              </View>
              <View style={styles.advancedItem}>
                <Text style={[styles.subLabel, { color: colors.muted }]}>
                  Gas Octane
                </Text>
                <View style={styles.inlineInputGroup}>
                  <TextInput
                    style={[
                      styles.inputSmall,
                      { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
                    ]}
                    value={inputTexts.gasOctane}
                    onChangeText={(v) => updateText("gasOctane", v)}
                    keyboardType="default"
                    autoCapitalize="none"
                    autoCorrect={false}
                    returnKeyType="done"
                  />
                  <Pressable
                    onPress={() => {
                      const cur = inputTexts.gasOctane;
                      if (!cur.includes(".")) {
                        updateText("gasOctane", cur === "" ? "0." : cur + ".");
                      }
                    }}
                    style={({ pressed }) => [
                      styles.decimalBtnSmall,
                      { backgroundColor: colors.primary + "20" },
                      pressed && { opacity: 0.6 },
                    ]}
                  >
                    <Text style={[styles.decimalBtnSmallText, { color: colors.primary }]}>.</Text>
                  </Pressable>
                </View>
              </View>
            </View>
          </Animated.View>
        )}

        {/* Calculate Button */}
        <Animated.View entering={FadeInDown.duration(300).delay(200)}>
          <Pressable
            onPress={handleCalculate}
            style={({ pressed }) => [
              styles.calculateButton,
              pressed && { transform: [{ scale: 0.97 }], opacity: 0.9 },
            ]}
          >
            <LinearGradient
              colors={[colors.primary, "#15803D"]}
              start={{ x: 0, y: 0 }}
              end={{ x: 1, y: 1 }}
              style={styles.calculateGradient}
            >
              <IconSymbol name="drop.fill" size={20} color="#FFFFFF" />
              <Text style={styles.calculateText}>Calculate Blend</Text>
            </LinearGradient>
          </Pressable>
        </Animated.View>

        {/* Results */}
        {result && (
          <Animated.View style={resultAnimStyle}>
            <Animated.View
              entering={FadeInDown.duration(300)}
              style={[
                styles.resultCard,
                { backgroundColor: colors.surface, borderColor: colors.border },
              ]}
            >
              {/* Blend Gauge */}
              <View style={styles.gaugeContainer}>
                <View
                  style={[styles.gaugeTrack, { backgroundColor: colors.border }]}
                >
                  <LinearGradient
                    colors={[colors.primary, "#D97706"]}
                    start={{ x: 0, y: 0 }}
                    end={{ x: 1, y: 0 }}
                    style={[
                      styles.gaugeFill,
                      {
                        width: `${Math.min(
                          100,
                          (result.finalEthanolPercent / 85) * 100
                        )}%`,
                      },
                    ]}
                  />
                </View>
                <Text
                  style={[styles.gaugeLabel, { color: colors.foreground }]}
                >
                  {result.blendLabel}
                </Text>
              </View>

              {/* Result Grid */}
              <View style={styles.resultGrid}>
                <View
                  style={[
                    styles.resultItem,
                    { backgroundColor: colors.primary + "12" },
                  ]}
                >
                  <IconSymbol
                    name="drop.fill"
                    size={20}
                    color={colors.primary}
                  />
                  <Text
                    style={[styles.resultValue, { color: colors.foreground }]}
                  >
                    {result.e85Gallons}
                  </Text>
                  <Text style={[styles.resultLabel, { color: colors.muted }]}>
                    gal E85
                  </Text>
                </View>
                <View
                  style={[
                    styles.resultItem,
                    { backgroundColor: "#D97706" + "12" },
                  ]}
                >
                  <IconSymbol
                    name="flame.fill"
                    size={20}
                    color="#D97706"
                  />
                  <Text
                    style={[styles.resultValue, { color: colors.foreground }]}
                  >
                    {result.gasGallons}
                  </Text>
                  <Text style={[styles.resultLabel, { color: colors.muted }]}>
                    gal Gas
                  </Text>
                </View>
                <View
                  style={[
                    styles.resultItem,
                    { backgroundColor: colors.primary + "12" },
                  ]}
                >
                  <IconSymbol
                    name="gauge.open.with.lines.needle.33percent"
                    size={20}
                    color={colors.primary}
                  />
                  <Text
                    style={[styles.resultValue, { color: colors.foreground }]}
                  >
                    {result.estimatedOctane}
                  </Text>
                  <Text style={[styles.resultLabel, { color: colors.muted }]}>
                    Octane
                  </Text>
                </View>
                <View
                  style={[
                    styles.resultItem,
                    { backgroundColor: "#D97706" + "12" },
                  ]}
                >
                  <IconSymbol
                    name="checkmark.circle.fill"
                    size={20}
                    color={result.isValid ? colors.primary : colors.warning}
                  />
                  <Text
                    style={[styles.resultValue, { color: colors.foreground }]}
                  >
                    {result.finalEthanolPercent}%
                  </Text>
                  <Text style={[styles.resultLabel, { color: colors.muted }]}>
                    Ethanol
                  </Text>
                </View>
              </View>

              {result.errorMessage && (
                <View
                  style={[
                    styles.warningBanner,
                    { backgroundColor: colors.warning + "18" },
                  ]}
                >
                  <IconSymbol
                    name="info.circle.fill"
                    size={16}
                    color={colors.warning}
                  />
                  <Text
                    style={[styles.warningText, { color: colors.warning }]}
                  >
                    {result.errorMessage}
                  </Text>
                </View>
              )}

              {/* Save Button */}
              <Pressable
                onPress={handleSaveBlend}
                style={({ pressed }) => [
                  styles.saveButton,
                  { borderColor: colors.primary },
                  pressed && { opacity: 0.7, transform: [{ scale: 0.97 }] },
                ]}
              >
                <IconSymbol
                  name="bookmark.fill"
                  size={18}
                  color={colors.primary}
                />
                <Text
                  style={[styles.saveButtonText, { color: colors.primary }]}
                >
                  Save Blend
                </Text>
              </Pressable>
            </Animated.View>
          </Animated.View>
        )}

        <View style={styles.bottomSpacer} />
      </ScrollView>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  scrollContent: {
    paddingHorizontal: 20,
    paddingBottom: 100,
  },
  header: {
    paddingTop: 8,
    paddingBottom: 20,
  },
  headerRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
  },
  headerIconBg: {
    width: 44,
    height: 44,
    borderRadius: 14,
    alignItems: "center",
    justifyContent: "center",
  },
  headerTitle: {
    fontSize: 26,
    fontWeight: "800",
    letterSpacing: -0.5,
  },
  headerSubtitle: {
    fontSize: 14,
    fontWeight: "400",
    marginTop: 2,
  },
  card: {
    borderRadius: 20,
    padding: 18,
    marginBottom: 14,
    borderWidth: 1,
  },
  cardLabel: {
    fontSize: 13,
    fontWeight: "600",
    textTransform: "uppercase",
    letterSpacing: 0.5,
    marginBottom: 12,
  },
  inputRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
  },
  inputLarge: {
    flex: 1,
    fontSize: 28,
    fontWeight: "700",
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 14,
    borderWidth: 1,
  },
  unitLabel: {
    fontSize: 16,
    fontWeight: "500",
  },
  fuelLevelRow: {
    flexDirection: "row",
    gap: 10,
  },
  fuelLevelChip: {
    flex: 1,
    paddingVertical: 10,
    borderRadius: 12,
    alignItems: "center",
    borderWidth: 1,
  },
  fuelLevelText: {
    fontSize: 14,
    fontWeight: "600",
  },
  subInputRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginTop: 14,
  },
  subLabel: {
    fontSize: 14,
    fontWeight: "500",
  },
  inputSmall: {
    width: 72,
    fontSize: 18,
    fontWeight: "600",
    textAlign: "center",
    paddingHorizontal: 10,
    paddingVertical: 8,
    borderRadius: 10,
    borderWidth: 1,
  },
  blendChipsRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 10,
  },
  blendChip: {
    paddingHorizontal: 18,
    paddingVertical: 10,
    borderRadius: 12,
    borderWidth: 1,
  },
  blendChipText: {
    fontSize: 15,
  },
  customTargetRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginTop: 14,
  },
  advancedToggle: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    paddingVertical: 10,
    marginBottom: 14,
  },
  advancedToggleText: {
    fontSize: 14,
    fontWeight: "600",
  },
  advancedGrid: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 14,
  },
  advancedItem: {
    width: "46%",
    gap: 8,
  },
  calculateButton: {
    borderRadius: 18,
    overflow: "hidden",
    marginBottom: 18,
  },
  calculateGradient: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 10,
    paddingVertical: 16,
  },
  calculateText: {
    color: "#FFFFFF",
    fontSize: 17,
    fontWeight: "700",
  },
  resultCard: {
    borderRadius: 20,
    padding: 18,
    borderWidth: 1,
    gap: 16,
  },
  gaugeContainer: {
    alignItems: "center",
    gap: 8,
  },
  gaugeTrack: {
    width: "100%",
    height: 10,
    borderRadius: 5,
    overflow: "hidden",
  },
  gaugeFill: {
    height: "100%",
    borderRadius: 5,
  },
  gaugeLabel: {
    fontSize: 32,
    fontWeight: "800",
    letterSpacing: -1,
  },
  resultGrid: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 10,
  },
  resultItem: {
    width: "47%",
    borderRadius: 16,
    padding: 14,
    alignItems: "center",
    gap: 6,
  },
  resultValue: {
    fontSize: 24,
    fontWeight: "800",
    letterSpacing: -0.5,
  },
  resultLabel: {
    fontSize: 12,
    fontWeight: "500",
  },
  warningBanner: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    padding: 12,
    borderRadius: 12,
  },
  warningText: {
    flex: 1,
    fontSize: 13,
    fontWeight: "500",
  },
  saveButton: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    paddingVertical: 12,
    borderRadius: 14,
    borderWidth: 1.5,
  },
  saveButtonText: {
    fontSize: 15,
    fontWeight: "600",
  },
  bottomSpacer: {
    height: 20,
  },
  decimalBtn: {
    width: 44,
    height: 52,
    borderRadius: 14,
    justifyContent: "center",
    alignItems: "center",
  },
  decimalBtnText: {
    fontSize: 28,
    fontWeight: "800",
    lineHeight: 32,
  },
  decimalBtnSmall: {
    width: 32,
    height: 38,
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
  },
  decimalBtnSmallText: {
    fontSize: 22,
    fontWeight: "800",
    lineHeight: 26,
  },
  inlineInputGroup: {
    flexDirection: "row",
    alignItems: "center",
    gap: 4,
  },
  carBanner: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    padding: 14,
    borderRadius: 16,
    borderWidth: 1,
    marginBottom: 14,
  },
  carBannerEmoji: {
    fontSize: 28,
  },
  carBannerName: {
    fontSize: 15,
    fontWeight: "700",
  },
  carBannerSub: {
    fontSize: 12,
    marginTop: 2,
  },
  carBannerBadge: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 8,
  },
  carBannerBadgeText: {
    fontSize: 12,
    fontWeight: "700",
  },
});

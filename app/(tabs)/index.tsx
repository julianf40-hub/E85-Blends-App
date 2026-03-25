import React, { useState, useCallback, useRef, useEffect } from "react";
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

const { width: SCREEN_WIDTH } = Dimensions.get("window");

export default function CalculatorScreen() {
  const colors = useColors();
  const [inputs, setInputs] = useState<BlendInputs>(DEFAULT_INPUTS);
  const [result, setResult] = useState<BlendResult | null>(null);
  const [showAdvanced, setShowAdvanced] = useState(false);
  const resultScale = useSharedValue(1);
  const tankInputRef = useRef<TextInput>(null);

  useEffect(() => {
    (async () => {
      const settings = await getSettings();
      setInputs((prev) => ({
        ...prev,
        tankSize: settings.defaultTankSize,
        e85EthanolPercent: settings.defaultE85Ethanol,
        gasEthanolPercent: settings.defaultGasEthanol,
        gasOctane: settings.defaultGasOctane,
        e85Octane: settings.defaultE85Octane,
      }));
    })();
  }, []);

  const handleCalculate = useCallback(() => {
    if (Platform.OS !== "web") {
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    }
    const blendResult = calculateBlend(inputs);
    setResult(blendResult);
    resultScale.value = withSequence(
      withTiming(0.97, { duration: 80 }),
      withTiming(1, { duration: 200, easing: Easing.out(Easing.quad) })
    );
  }, [inputs, resultScale]);

  const handleSaveBlend = useCallback(async () => {
    if (!result) return;
    if (Platform.OS !== "web") {
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
    }
    try {
      await saveBlend(inputs, result);
      Alert.alert("Saved", "Blend saved to My Blends");
    } catch {
      Alert.alert("Error", "Failed to save blend");
    }
  }, [inputs, result]);

  const handleBlendChipPress = useCallback(
    (value: number) => {
      if (Platform.OS !== "web") {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
      }
      setInputs((prev) => ({ ...prev, targetEthanolPercent: value }));
    },
    []
  );

  const updateInput = useCallback(
    (key: keyof BlendInputs, value: string) => {
      const num = parseFloat(value) || 0;
      setInputs((prev) => ({ ...prev, [key]: num }));
    },
    []
  );

  const resultAnimStyle = useAnimatedStyle(() => ({
    transform: [{ scale: resultScale.value }],
  }));

  return (
    <ScreenContainer>
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
        keyboardShouldPersistTaps="handled"
      >
        {/* Header */}
        <Animated.View entering={FadeIn.duration(300)} style={styles.header}>
          <View style={styles.headerRow}>
            <View
              style={[styles.headerIconBg, { backgroundColor: colors.primary + "18" }]}
            >
              <IconSymbol name="fuelpump.fill" size={22} color={colors.primary} />
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
        </Animated.View>

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
              value={inputs.tankSize.toString()}
              onChangeText={(v) => updateInput("tankSize", v)}
              keyboardType="decimal-pad"
              returnKeyType="done"
              placeholder="16"
              placeholderTextColor={colors.muted}
            />
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
                  setInputs((prev) => ({
                    ...prev,
                    currentFuelLevel: level,
                    currentEthanolPercent: level === 0 ? 0 : prev.currentEthanolPercent,
                  }));
                }}
                style={({ pressed }) => [
                  styles.fuelLevelChip,
                  {
                    backgroundColor:
                      inputs.currentFuelLevel === level
                        ? colors.primary
                        : colors.background,
                    borderColor:
                      inputs.currentFuelLevel === level
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
                        inputs.currentFuelLevel === level
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
          {inputs.currentFuelLevel > 0 && (
            <View style={styles.subInputRow}>
              <Text style={[styles.subLabel, { color: colors.muted }]}>
                Current ethanol %
              </Text>
              <TextInput
                style={[
                  styles.inputSmall,
                  { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
                ]}
                value={inputs.currentEthanolPercent.toString()}
                onChangeText={(v) => updateInput("currentEthanolPercent", v)}
                keyboardType="decimal-pad"
                returnKeyType="done"
              />
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
                      inputs.targetEthanolPercent === blend.value
                        ? colors.primary
                        : colors.background,
                    borderColor:
                      inputs.targetEthanolPercent === blend.value
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
                        inputs.targetEthanolPercent === blend.value
                          ? "#FFFFFF"
                          : colors.foreground,
                      fontWeight:
                        inputs.targetEthanolPercent === blend.value ? "700" : "500",
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
            <TextInput
              style={[
                styles.inputSmall,
                { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
              ]}
              value={inputs.targetEthanolPercent.toString()}
              onChangeText={(v) => updateInput("targetEthanolPercent", v)}
              keyboardType="decimal-pad"
              returnKeyType="done"
            />
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
                <TextInput
                  style={[
                    styles.inputSmall,
                    { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
                  ]}
                  value={inputs.e85EthanolPercent.toString()}
                  onChangeText={(v) => updateInput("e85EthanolPercent", v)}
                  keyboardType="decimal-pad"
                  returnKeyType="done"
                />
              </View>
              <View style={styles.advancedItem}>
                <Text style={[styles.subLabel, { color: colors.muted }]}>
                  Gas Ethanol %
                </Text>
                <TextInput
                  style={[
                    styles.inputSmall,
                    { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
                  ]}
                  value={inputs.gasEthanolPercent.toString()}
                  onChangeText={(v) => updateInput("gasEthanolPercent", v)}
                  keyboardType="decimal-pad"
                  returnKeyType="done"
                />
              </View>
              <View style={styles.advancedItem}>
                <Text style={[styles.subLabel, { color: colors.muted }]}>
                  E85 Octane
                </Text>
                <TextInput
                  style={[
                    styles.inputSmall,
                    { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
                  ]}
                  value={inputs.e85Octane.toString()}
                  onChangeText={(v) => updateInput("e85Octane", v)}
                  keyboardType="decimal-pad"
                  returnKeyType="done"
                />
              </View>
              <View style={styles.advancedItem}>
                <Text style={[styles.subLabel, { color: colors.muted }]}>
                  Gas Octane
                </Text>
                <TextInput
                  style={[
                    styles.inputSmall,
                    { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background },
                  ]}
                  value={inputs.gasOctane.toString()}
                  onChangeText={(v) => updateInput("gasOctane", v)}
                  keyboardType="decimal-pad"
                  returnKeyType="done"
                />
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
});

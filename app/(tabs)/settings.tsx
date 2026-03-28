import { useState, useCallback, useRef } from "react";
import {
  Text,
  View,
  ScrollView,
  Pressable,
  StyleSheet,
  TextInput,
  Alert,
  Platform,
} from "react-native";
import Animated, { FadeIn, FadeInDown } from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import { router, useFocusEffect } from "expo-router";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import {
  loadPreferences,
  savePreferences,
  resetPreferences,
  UserPreferences,
} from "@/lib/preferences";
import { clearFuelLog } from "@/lib/fuel-log";
import { clearHistory, clearFavorites } from "@/lib/station-favorites";
import { clearReviews } from "@/lib/station-reviews";
import { getActiveCar, CarProfile, clearGarage } from "@/lib/garage";

/** Only allow digits, one decimal point, and comma (auto-replaced with dot) */
function sanitizeDecimal(text: string): string {
  let cleaned = text.replace(",", ".");
  const parts = cleaned.split(".");
  if (parts.length > 2) {
    cleaned = parts[0] + "." + parts.slice(1).join("");
  }
  cleaned = cleaned.replace(/[^\d.]/g, "");
  return cleaned;
}

/**
 * A numeric input that stores text as a string while editing,
 * and only converts to number on blur.
 */
function NumericField({
  value,
  onSave,
  placeholder,
  colors,
  style,
}: {
  value: number;
  onSave: (n: number) => void;
  placeholder: string;
  colors: any;
  style?: any;
}) {
  const [text, setText] = useState(value.toString());
  const inputRef = useRef<TextInput>(null);

  // Sync from parent when value changes externally (e.g., reset)
  useState(() => {
    setText(value.toString());
  });

  return (
    <View style={styles.numericFieldRow}>
      <TextInput
        ref={inputRef}
        editable
        style={[
          style || styles.numberInput,
          {
            color: colors.foreground,
            borderColor: colors.border,
            backgroundColor: colors.background,
          },
        ]}
        placeholder={placeholder}
        placeholderTextColor={colors.muted}
        keyboardType="default"
        autoCapitalize="none"
        autoCorrect={false}
        returnKeyType="done"
        value={text}
        onChangeText={(v) => setText(sanitizeDecimal(v))}
        onBlur={() => {
          const num = parseFloat(text);
          if (!isNaN(num)) {
            onSave(num);
          }
        }}
        selectTextOnFocus
        maxLength={10}
      />
      <Pressable
        onPress={() => {
          if (!text.includes(".")) {
            setText(text === "" ? "0." : text + ".");
            inputRef.current?.focus();
          }
        }}
        style={({ pressed }) => [
          styles.settingsDecimalBtn,
          { backgroundColor: colors.primary + "20" },
          pressed && { opacity: 0.6 },
        ]}
      >
        <Text style={[styles.settingsDecimalBtnText, { color: colors.primary }]}>.</Text>
      </Pressable>
    </View>
  );
}

export default function SettingsScreen() {
  const colors = useColors();
  const [prefs, setPrefs] = useState<UserPreferences | null>(null);
  const [loading, setLoading] = useState(true);
  const [activeCar, setActiveCar] = useState<CarProfile | null>(null);

  // Reload on every focus so changes in Garage tab are reflected
  useFocusEffect(
    useCallback(() => {
      (async () => {
        const [loaded, car] = await Promise.all([loadPreferences(), getActiveCar()]);
        setPrefs(loaded);
        setActiveCar(car);
        setLoading(false);
      })();
    }, [])
  );

  const handleSavePreference = useCallback(
    async <K extends keyof UserPreferences>(
      key: K,
      value: UserPreferences[K]
    ) => {
      if (!prefs) return;
      const updated = { ...prefs, [key]: value };
      setPrefs(updated);
      await savePreferences(updated);
      if (Platform.OS !== "web") {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
      }
    },
    [prefs]
  );

  const handleResetPreferences = useCallback(() => {
    Alert.alert(
      "Reset Preferences?",
      "This will restore all settings to defaults.",
      [
        { text: "Cancel", onPress: () => {} },
        {
          text: "Reset",
          onPress: async () => {
            const defaults = await resetPreferences();
            setPrefs(defaults);
            if (Platform.OS !== "web") {
              Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
            }
          },
          style: "destructive",
        },
      ]
    );
  }, []);

  const handleClearData = useCallback(() => {
    Alert.alert(
      "Clear All Data?",
      "This will delete fuel logs, favorites, history, reviews, and your garage. This cannot be undone.",
      [
        { text: "Cancel", onPress: () => {} },
        {
          text: "Clear",
          onPress: async () => {
            await clearFuelLog();
            await clearHistory();
            await clearFavorites();
            await clearReviews();
            await clearGarage();
            setActiveCar(null);
            if (Platform.OS !== "web") {
              Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
            }
            Alert.alert("Success", "All data has been cleared.");
          },
          style: "destructive",
        },
      ]
    );
  }, []);

  if (loading || !prefs) {
    return (
      <ScreenContainer>
        <Text style={[styles.loadingText, { color: colors.muted }]}>
          Loading settings...
        </Text>
      </ScreenContainer>
    );
  }

  return (
    <ScreenContainer>
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        keyboardShouldPersistTaps="handled"
      >
        {/* Header */}
        <Animated.View entering={FadeInDown.duration(300)} style={styles.header}>
          <View
            style={[
              styles.headerIconBg,
              { backgroundColor: colors.primary + "18" },
            ]}
          >
            <IconSymbol name="gearshape.fill" size={24} color={colors.primary} />
          </View>
          <View style={styles.headerTextCol}>
            <Text style={[styles.headerTitle, { color: colors.foreground }]}>
              Settings
            </Text>
            <Text style={[styles.headerSubtitle, { color: colors.muted }]}>
              Customize your E85 experience
            </Text>
          </View>
        </Animated.View>

        {/* Active Car Section */}
        <Animated.View
          entering={FadeInDown.duration(300).delay(40)}
          style={styles.section}
        >
          <Text style={[styles.sectionTitle, { color: colors.foreground }]}>
            Active Vehicle
          </Text>
          <Pressable
            onPress={() => router.push("/(tabs)/garage")}
            style={({ pressed }) => [
              styles.card,
              {
                backgroundColor: activeCar ? activeCar.color + "12" : colors.surface,
                borderColor: activeCar ? activeCar.color + "50" : colors.border,
                opacity: pressed ? 0.85 : 1,
              },
            ]}
          >
            {activeCar ? (
              <View style={styles.activeCarRow}>
                <Text style={styles.activeCarEmoji}>{activeCar.icon}</Text>
                <View style={{ flex: 1 }}>
                  <Text style={[styles.activeCarName, { color: colors.foreground }]}>
                    {activeCar.nickname || `${activeCar.year} ${activeCar.make} ${activeCar.model}`.trim() || "My Car"}
                  </Text>
                  <Text style={[styles.activeCarSub, { color: colors.muted }]}>
                    {[activeCar.year, activeCar.make, activeCar.model, activeCar.trim]
                      .filter(Boolean)
                      .join(" ")}
                  </Text>
                  <View style={styles.activeCarStats}>
                    <Text style={[styles.activeCarStat, { color: colors.muted }]}>
                      🛢 {activeCar.tankSize} gal
                    </Text>
                    <Text style={[styles.activeCarStat, { color: colors.muted }]}>
                      ⛽ E{activeCar.defaultBlend} default
                    </Text>
                    <Text style={[styles.activeCarStat, { color: colors.muted }]}>
                      🔢 {activeCar.requiredOctane} oct
                    </Text>
                  </View>
                </View>
                <View style={[styles.activeCarBadge, { backgroundColor: activeCar.color + "25" }]}>
                  <Text style={[styles.activeCarBadgeText, { color: activeCar.color }]}>Active</Text>
                </View>
              </View>
            ) : (
              <View style={styles.noCarRow}>
                <View style={[styles.noCarIcon, { backgroundColor: colors.primary + "18" }]}>
                  <IconSymbol name="car.2.fill" size={22} color={colors.primary} />
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={[styles.noCarTitle, { color: colors.foreground }]}>
                    No Active Vehicle
                  </Text>
                  <Text style={[styles.noCarSub, { color: colors.muted }]}>
                    Add a car in the Garage tab to auto-fill calculator settings
                  </Text>
                </View>
                <IconSymbol name="chevron.right" size={18} color={colors.muted} />
              </View>
            )}
            {activeCar && (
              <View style={[styles.manageCarFooter, { borderTopColor: activeCar.color + "30" }]}>
                <Text style={[styles.manageCarText, { color: activeCar.color }]}>
                  Manage in Garage →
                </Text>
              </View>
            )}
          </Pressable>
        </Animated.View>

        {/* Fuel Preferences Section */}
        <Animated.View
          entering={FadeInDown.duration(300).delay(120)}
          style={styles.section}
        >
          <Text style={[styles.sectionTitle, { color: colors.foreground }]}>
            Fuel Preferences
          </Text>

          <View
            style={[
              styles.card,
              {
                backgroundColor: colors.surface,
                borderColor: colors.border,
              },
            ]}
          >
            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>
                  Default Tank Size
                </Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>
                  {activeCar ? `Overridden by active car (${activeCar.tankSize} gal)` : "Gallons — used when no car is active"}
                </Text>
              </View>
              <NumericField
                value={prefs.tankSize || 16}
                onSave={(n) => handleSavePreference("tankSize", n)}
                placeholder="16.5"
                colors={colors}
              />
            </View>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>
                  Preferred Octane
                </Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>
                  {activeCar ? `Overridden by active car (${activeCar.requiredOctane})` : "Minimum octane rating"}
                </Text>
              </View>
              <View style={styles.octaneButtons}>
                {[87, 91, 93, 98].map((octane) => (
                  <Pressable
                    key={octane}
                    onPress={() => handleSavePreference("preferredOctane", octane)}
                    style={({ pressed }) => [
                      styles.octaneButton,
                      {
                        backgroundColor:
                          prefs.preferredOctane === octane
                            ? colors.primary
                            : colors.background,
                        borderColor:
                          prefs.preferredOctane === octane
                            ? colors.primary
                            : colors.border,
                      },
                      pressed && { opacity: 0.8 },
                    ]}
                  >
                    <Text
                      style={[
                        styles.octaneButtonText,
                        {
                          color:
                            prefs.preferredOctane === octane
                              ? "#FFFFFF"
                              : colors.foreground,
                        },
                      ]}
                    >
                      {octane}
                    </Text>
                  </Pressable>
                ))}
              </View>
            </View>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>
                  Default Blend
                </Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>
                  {activeCar ? `Overridden by active car (E${activeCar.defaultBlend})` : "E20–E85"}
                </Text>
              </View>
              <NumericField
                value={prefs.defaultBlend}
                onSave={(n) => handleSavePreference("defaultBlend", n)}
                placeholder="30"
                colors={colors}
              />
            </View>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>
                  Search Radius
                </Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>
                  Miles for station search
                </Text>
              </View>
              <NumericField
                value={prefs.searchRadius}
                onSave={(n) => handleSavePreference("searchRadius", n)}
                placeholder="25"
                colors={colors}
              />
            </View>
          </View>
        </Animated.View>

        {/* Data & Privacy Section */}
        <Animated.View
          entering={FadeInDown.duration(300).delay(200)}
          style={styles.section}
        >
          <Text style={[styles.sectionTitle, { color: colors.foreground }]}>
            Data & Privacy
          </Text>

          <View
            style={[
              styles.card,
              {
                backgroundColor: colors.surface,
                borderColor: colors.border,
              },
            ]}
          >
            <Pressable
              onPress={handleResetPreferences}
              style={({ pressed }) => [
                styles.actionButton,
                pressed && { opacity: 0.8 },
              ]}
            >
              <View style={styles.actionButtonContent}>
                <View
                  style={[
                    styles.actionIconBg,
                    { backgroundColor: colors.warning + "18" },
                  ]}
                >
                  <IconSymbol
                    name="arrow.counterclockwise"
                    size={18}
                    color={colors.warning}
                  />
                </View>
                <View style={styles.actionTextCol}>
                  <Text
                    style={[styles.actionButtonText, { color: colors.foreground }]}
                  >
                    Reset Preferences
                  </Text>
                  <Text style={[styles.actionButtonDesc, { color: colors.muted }]}>
                    Restore default settings
                  </Text>
                </View>
              </View>
              <IconSymbol
                name="chevron.right"
                size={18}
                color={colors.muted}
              />
            </Pressable>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            <Pressable
              onPress={handleClearData}
              style={({ pressed }) => [
                styles.actionButton,
                pressed && { opacity: 0.8 },
              ]}
            >
              <View style={styles.actionButtonContent}>
                <View
                  style={[
                    styles.actionIconBg,
                    { backgroundColor: colors.error + "18" },
                  ]}
                >
                  <IconSymbol
                    name="trash.fill"
                    size={18}
                    color={colors.error}
                  />
                </View>
                <View style={styles.actionTextCol}>
                  <Text
                    style={[styles.actionButtonText, { color: colors.foreground }]}
                  >
                    Clear All Data
                  </Text>
                  <Text style={[styles.actionButtonDesc, { color: colors.muted }]}>
                    Delete logs, favorites, garage, reviews
                  </Text>
                </View>
              </View>
              <IconSymbol
                name="chevron.right"
                size={18}
                color={colors.muted}
              />
            </Pressable>
          </View>
        </Animated.View>

        {/* About Section */}
        <Animated.View
          entering={FadeInDown.duration(300).delay(280)}
          style={styles.section}
        >
          <View
            style={[
              styles.card,
              {
                backgroundColor: colors.surface,
                borderColor: colors.border,
              },
            ]}
          >
            <View style={styles.aboutContent}>
              <Text style={[styles.aboutTitle, { color: colors.foreground }]}>
                E85 Blend Calculator
              </Text>
              <Text style={[styles.aboutVersion, { color: colors.muted }]}>
                Version 2.1.0
              </Text>
              <Text style={[styles.aboutDesc, { color: colors.muted }]}>
                Calculate perfect E85 blends, find nearby stations, manage your garage, and track your fuel economy.
              </Text>
            </View>
          </View>
        </Animated.View>

        <View style={styles.bottomSpacer} />
      </ScrollView>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  scrollContent: {
    paddingHorizontal: 20,
    paddingTop: 12,
    paddingBottom: 100,
  },
  header: {
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
    marginBottom: 24,
  },
  headerIconBg: {
    width: 44,
    height: 44,
    borderRadius: 14,
    alignItems: "center",
    justifyContent: "center",
  },
  headerTextCol: {
    flex: 1,
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
  section: {
    marginBottom: 24,
  },
  sectionTitle: {
    fontSize: 16,
    fontWeight: "700",
    marginBottom: 12,
  },
  card: {
    borderRadius: 16,
    borderWidth: 1,
    overflow: "hidden",
  },
  // Active car card
  activeCarRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
    padding: 16,
  },
  activeCarEmoji: {
    fontSize: 36,
  },
  activeCarName: {
    fontSize: 16,
    fontWeight: "700",
  },
  activeCarSub: {
    fontSize: 12,
    marginTop: 2,
  },
  activeCarStats: {
    flexDirection: "row",
    gap: 10,
    marginTop: 6,
    flexWrap: "wrap",
  },
  activeCarStat: {
    fontSize: 12,
    fontWeight: "500",
  },
  activeCarBadge: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 8,
    alignSelf: "flex-start",
  },
  activeCarBadgeText: {
    fontSize: 12,
    fontWeight: "700",
  },
  manageCarFooter: {
    borderTopWidth: 1,
    paddingHorizontal: 16,
    paddingVertical: 10,
  },
  manageCarText: {
    fontSize: 13,
    fontWeight: "600",
    textAlign: "center",
  },
  noCarRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
    padding: 16,
  },
  noCarIcon: {
    width: 44,
    height: 44,
    borderRadius: 12,
    alignItems: "center",
    justifyContent: "center",
  },
  noCarTitle: {
    fontSize: 15,
    fontWeight: "600",
  },
  noCarSub: {
    fontSize: 12,
    marginTop: 2,
    lineHeight: 16,
  },
  // Settings rows
  settingRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingVertical: 14,
    gap: 12,
  },
  settingLabel: {
    flex: 1,
  },
  settingName: {
    fontSize: 15,
    fontWeight: "600",
  },
  settingDesc: {
    fontSize: 12,
    fontWeight: "400",
    marginTop: 2,
  },
  numberInput: {
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 8,
    fontSize: 14,
    fontWeight: "600",
    minWidth: 80,
    textAlign: "center",
  },
  octaneButtons: {
    flexDirection: "row",
    gap: 8,
  },
  octaneButton: {
    borderWidth: 1.5,
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 8,
    alignItems: "center",
    justifyContent: "center",
  },
  octaneButtonText: {
    fontSize: 13,
    fontWeight: "700",
  },
  divider: {
    height: 1,
    marginHorizontal: 16,
  },
  actionButton: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingVertical: 14,
  },
  actionButtonContent: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    flex: 1,
  },
  actionIconBg: {
    width: 40,
    height: 40,
    borderRadius: 12,
    alignItems: "center",
    justifyContent: "center",
  },
  actionTextCol: {
    flex: 1,
  },
  actionButtonText: {
    fontSize: 15,
    fontWeight: "600",
  },
  actionButtonDesc: {
    fontSize: 12,
    fontWeight: "400",
    marginTop: 2,
  },
  aboutContent: {
    paddingHorizontal: 16,
    paddingVertical: 16,
    alignItems: "center",
  },
  aboutTitle: {
    fontSize: 16,
    fontWeight: "700",
    marginBottom: 4,
  },
  aboutVersion: {
    fontSize: 13,
    fontWeight: "500",
    marginBottom: 8,
  },
  aboutDesc: {
    fontSize: 13,
    fontWeight: "400",
    textAlign: "center",
    lineHeight: 18,
  },
  bottomSpacer: {
    height: 40,
  },
  loadingText: {
    fontSize: 16,
    fontWeight: "500",
    textAlign: "center",
    marginTop: 40,
  },
  numericFieldRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
  },
  settingsDecimalBtn: {
    width: 34,
    height: 38,
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
  },
  settingsDecimalBtnText: {
    fontSize: 22,
    fontWeight: "800",
    lineHeight: 26,
  },
});

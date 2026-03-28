import React, { useState, useEffect, useCallback } from "react";
import {
  Text,
  View,
  ScrollView,
  Pressable,
  StyleSheet,
  TextInput,
  Switch,
  Alert,
  Platform,
} from "react-native";
import Animated, { FadeInDown } from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import { LinearGradient } from "expo-linear-gradient";
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

export default function SettingsScreen() {
  const colors = useColors();
  const [prefs, setPrefs] = useState<UserPreferences | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      const loaded = await loadPreferences();
      setPrefs(loaded);
      setLoading(false);
    })();
  }, []);

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
      "This will delete fuel logs, favorites, history, and reviews. This cannot be undone.",
      [
        { text: "Cancel", onPress: () => {} },
        {
          text: "Clear",
          onPress: async () => {
            await clearFuelLog();
            await clearHistory();
            await clearFavorites();
            await clearReviews();
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
      <ScrollView contentContainerStyle={styles.scrollContent}>
        {/* Header */}
        <Animated.View entering={FadeInDown.duration(300)} style={styles.header}>
          <View
            style={[
              styles.headerIconBg,
              { backgroundColor: colors.primary + "18" },
            ]}
          >
            <IconSymbol name="gear" size={24} color={colors.primary} />
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

        {/* Vehicle Section */}
        <Animated.View
          entering={FadeInDown.duration(300).delay(80)}
          style={styles.section}
        >
          <Text style={[styles.sectionTitle, { color: colors.foreground }]}>
            Vehicle Information
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
                  Vehicle Name
                </Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>
                  e.g., "Daily Driver"
                </Text>
              </View>
              <TextInput
                editable
                style={[
                  styles.textInput,
                  {
                    color: colors.foreground,
                    borderColor: colors.border,
                    backgroundColor: colors.background,
                  },
                ]}
                placeholder="Enter name"
                placeholderTextColor={colors.muted}
                value={prefs.vehicleName || ""}
                onChangeText={(value) =>
                  handleSavePreference("vehicleName", value)
                }
              />
            </View>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>
                  Vehicle Model
                </Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>
                  e.g., "2023 Mustang"
                </Text>
              </View>
              <TextInput
                editable
                style={[
                  styles.textInput,
                  {
                    color: colors.foreground,
                    borderColor: colors.border,
                    backgroundColor: colors.background,
                  },
                ]}
                placeholder="Enter model"
                placeholderTextColor={colors.muted}
                value={`${prefs.vehicleYear || ""} ${prefs.vehicleMake || ""} ${prefs.vehicleModel || ""}`.trim()}
                onChangeText={(value) => {
                  const parts = value.split(" ");
                  if (parts.length >= 3) {
                    handleSavePreference("vehicleYear", parseInt(parts[0]));
                    handleSavePreference("vehicleMake", parts[1]);
                    handleSavePreference("vehicleModel", parts.slice(2).join(" "));
                  }
                }}
              />
            </View>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>
                  MPG (Regular Gas)
                </Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>
                  Typical fuel economy
                </Text>
              </View>
              <TextInput
                editable
                style={[
                  styles.numberInput,
                  {
                    color: colors.foreground,
                    borderColor: colors.border,
                    backgroundColor: colors.background,
                  },
                ]}
                placeholder="20"
                placeholderTextColor={colors.muted}
                keyboardType="numbers-and-punctuation"
                value={prefs.mpgRegularGas?.toString() || ""}
                onChangeText={(value) =>
                  handleSavePreference("mpgRegularGas", parseFloat(value) || 0)
                }
              />
            </View>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>
                  MPG (E85)
                </Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>
                  Typical fuel economy on E85
                </Text>
              </View>
              <TextInput
                editable
                style={[
                  styles.numberInput,
                  {
                    color: colors.foreground,
                    borderColor: colors.border,
                    backgroundColor: colors.background,
                  },
                ]}
                placeholder="25"
                placeholderTextColor={colors.muted}
                keyboardType="numbers-and-punctuation"
                value={prefs.mpgE85?.toString() || ""}
                onChangeText={(value) =>
                  handleSavePreference("mpgE85", parseFloat(value) || 0)
                }
              />
            </View>
          </View>
        </Animated.View>

        {/* Fuel Preferences Section */}
        <Animated.View
          entering={FadeInDown.duration(300).delay(160)}
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
                  Tank Size
                </Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>
                  Gallons
                </Text>
              </View>
              <TextInput
                editable
                style={[
                  styles.numberInput,
                  {
                    color: colors.foreground,
                    borderColor: colors.border,
                    backgroundColor: colors.background,
                  },
                ]}
                placeholder="30"
                placeholderTextColor={colors.muted}
                keyboardType="numbers-and-punctuation"
                value={prefs.defaultBlend.toString()}
                onChangeText={(value) =>
                  handleSavePreference("defaultBlend", parseFloat(value) || 30)
                }
              />
            </View>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>
                  Preferred Octane
                </Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>
                  Minimum octane rating
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
                  E20-E85
                </Text>
              </View>
              <TextInput
                editable
                style={[
                  styles.numberInput,
                  {
                    color: colors.foreground,
                    borderColor: colors.border,
                    backgroundColor: colors.background,
                  },
                ]}
                placeholder="30"
                placeholderTextColor={colors.muted}
                keyboardType="numbers-and-punctuation"
                value={prefs.defaultBlend.toString()}
                onChangeText={(value) =>
                  handleSavePreference("defaultBlend", parseFloat(value) || 30)
                }
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
              <TextInput
                editable
                style={[
                  styles.numberInput,
                  {
                    color: colors.foreground,
                    borderColor: colors.border,
                    backgroundColor: colors.background,
                  },
                ]}
                placeholder="25"
                placeholderTextColor={colors.muted}
                keyboardType="numbers-and-punctuation"
                value={prefs.searchRadius.toString()}
                onChangeText={(value) =>
                  handleSavePreference("searchRadius", parseFloat(value) || 25)
                }
              />           </View>
          </View>
        </Animated.View>

        {/* Data & Privacy Section */}
        <Animated.View
          entering={FadeInDown.duration(300).delay(240)}
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
                    Delete logs, favorites, reviews
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
          entering={FadeInDown.duration(300).delay(320)}
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
                Version 2.0.0
              </Text>
              <Text style={[styles.aboutDesc, { color: colors.muted }]}>
                Calculate perfect E85 blends, find nearby stations, and track your fuel economy.
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
  textInput: {
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 8,
    fontSize: 14,
    fontWeight: "500",
    minWidth: 120,
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
});

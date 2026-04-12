import React, { useState, useEffect, useCallback } from "react";
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  Pressable,
  TextInput,
  Alert,
  Platform,
  Linking,
  useColorScheme,
} from "react-native";
import { Image } from "expo-image";
import * as Haptics from "expo-haptics";
import Animated, { FadeInDown } from "react-native-reanimated";
import { useFocusEffect, useRouter } from "expo-router";

import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import { usePreferencesContext } from "@/lib/preferences-context";
import { loadGarage, CarProfile } from "@/lib/garage";

/**
 * Settings / More Screen
 *
 * Manages user preferences (theme, home screen, tab visibility)
 * and provides access to secondary features like the Garage and Fill-Up History.
 */
export default function SettingsScreen() {
  const colors = useColors();
  const router = useRouter();
  const colorScheme = useColorScheme();
  const { prefs, updatePref } = usePreferencesContext();

  // Garage state (local for this screen, synced on focus)
  const [cars, setCars] = useState<CarProfile[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchGarage = useCallback(async () => {
    const data = await loadGarage();
    setCars(data);
    setLoading(false);
  }, []);

  useFocusEffect(
    useCallback(() => {
      fetchGarage();
    }, [fetchGarage])
  );

  const handleToggleTab = (key: "showGarage" | "showReminders" | "showGear", value: boolean) => {
    updatePref(key, value);
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  };

  const handleSetHome = (tab: string) => {
    updatePref("homeScreen", tab);
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  };

  const openSponsor = () => {
    Linking.openURL("https://rvpsupply.com").catch(() => {});
    Haptics.selectionAsync();
  };

  return (
    <ScreenContainer>
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        <View style={styles.header}>
          <Text style={[styles.headerTitle, { color: colors.foreground }]}>More</Text>
        </View>

        {/* ── Preferences Section ── */}
        <Animated.View entering={FadeInDown.delay(100).duration(400)} style={styles.section}>
          <Text style={[styles.sectionTitle, { color: colors.muted, marginBottom: 12 }]}>Preferences</Text>
          <View style={[styles.card, { backgroundColor: colors.card, borderColor: colors.border }]}>
            {/* Home Screen */}
            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>Default Home Tab</Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>Screen shown on app launch</Text>
              </View>
            </View>
            <View style={styles.themeToggleRow}>
              {["calculator", "garage"].map((tab) => (
                <Pressable
                  key={tab}
                  onPress={() => handleSetHome(tab)}
                  style={[
                    styles.themeOption,
                    {
                      borderColor: prefs?.homeScreen === tab ? colors.primary : colors.border,
                      backgroundColor: prefs?.homeScreen === tab ? colors.primary + "10" : "transparent",
                    },
                  ]}
                >
                  <IconSymbol
                    name={tab === "calculator" ? "fuelpump.fill" : "car.fill"}
                    size={14}
                    color={prefs?.homeScreen === tab ? colors.primary : colors.muted}
                  />
                  <Text
                    style={[
                      styles.themeOptionText,
                      { color: prefs?.homeScreen === tab ? colors.primary : colors.muted },
                    ]}
                  >
                    {tab.charAt(0).toUpperCase() + tab.slice(1)}
                  </Text>
                </Pressable>
              ))}
            </View>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            {/* Tab Visibility */}
            <Pressable
              onPress={() => handleToggleTab("showGarage", !prefs?.showGarage)}
              style={styles.settingRow}
            >
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>Show Garage Tab</Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>Manage multiple car profiles</Text>
              </View>
              <IconSymbol
                name={prefs?.showGarage !== false ? "checkmark.circle.fill" : "circle"}
                size={24}
                color={prefs?.showGarage !== false ? colors.primary : colors.border}
              />
            </Pressable>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            <Pressable
              onPress={() => handleToggleTab("showReminders", !prefs?.showReminders)}
              style={styles.settingRow}
            >
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>Show Reminders Tab</Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>Maintenance & service alerts</Text>
              </View>
              <IconSymbol
                name={prefs?.showReminders !== false ? "checkmark.circle.fill" : "circle"}
                size={24}
                color={prefs?.showReminders !== false ? colors.primary : colors.border}
              />
            </Pressable>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            <Pressable
              onPress={() => handleToggleTab("showGear", !prefs?.showGear)}
              style={styles.settingRow}
            >
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>Show Recommended Gear Tab</Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>Still accessible from More when hidden</Text>
              </View>
              <IconSymbol
                name={prefs?.showGear ? "checkmark.circle.fill" : "circle"}
                size={24}
                color={prefs?.showGear ? colors.primary : colors.border}
              />
            </Pressable>
          </View>
        </Animated.View>

        {/* ── Tools & History ── */}
        <Animated.View entering={FadeInDown.delay(200).duration(400)} style={styles.section}>
          <Text style={[styles.sectionTitle, { color: colors.muted, marginBottom: 12 }]}>Tools</Text>
          <View style={[styles.card, { backgroundColor: colors.card, borderColor: colors.border }]}>
            <Pressable
              onPress={() => router.push("/help/gear")}
              style={({ pressed }) => [styles.actionButton, pressed && { backgroundColor: colors.border + "40" }]}
            >
              <View style={styles.actionButtonContent}>
                <View style={[styles.actionIconBg, { backgroundColor: "#F59E0B15" }]}>
                  <IconSymbol name="gearshape.fill" size={20} color="#F59E0B" />
                </View>
                <View style={styles.actionTextCol}>
                  <Text style={[styles.actionButtonText, { color: colors.foreground }]}>Recommended Gear</Text>
                  <Text style={[styles.actionButtonDesc, { color: colors.muted }]}>Tools & supplies for fuel blending</Text>
                </View>
                <IconSymbol name="chevron.right" size={14} color={colors.border} />
              </View>
            </Pressable>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            <Pressable
              onPress={() => Linking.openURL("https://85blends.com/guide")}
              style={({ pressed }) => [styles.actionButton, pressed && { backgroundColor: colors.border + "40" }]}
            >
              <View style={styles.actionButtonContent}>
                <View style={[styles.actionIconBg, { backgroundColor: colors.primary + "15" }]}>
                  <IconSymbol name="book.fill" size={20} color={colors.primary} />
                </View>
                <View style={styles.actionTextCol}>
                  <Text style={[styles.actionButtonText, { color: colors.foreground }]}>Ethanol Guide</Text>
                  <Text style={[styles.actionButtonDesc, { color: colors.muted }]}>Learn about blending & tuning</Text>
                </View>
                <IconSymbol name="chevron.right" size={14} color={colors.border} />
              </View>
            </Pressable>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            <Pressable
              onPress={() => Linking.openURL("mailto:support@85blends.com")}
              style={({ pressed }) => [styles.actionButton, pressed && { backgroundColor: colors.border + "40" }]}
            >
              <View style={styles.actionButtonContent}>
                <View style={[styles.actionIconBg, { backgroundColor: "#8B5CF615" }]}>
                  <IconSymbol name="envelope.fill" size={20} color="#8B5CF6" />
                </View>
                <View style={styles.actionTextCol}>
                  <Text style={[styles.actionButtonText, { color: colors.foreground }]}>Send Feedback</Text>
                  <Text style={[styles.actionButtonDesc, { color: colors.muted }]}>Report bugs or suggest features</Text>
                </View>
                <IconSymbol name="chevron.right" size={14} color={colors.border} />
              </View>
            </Pressable>
          </View>
        </Animated.View>

        {/* ── Sponsor Section ── */}
        <Animated.View entering={FadeInDown.delay(300).duration(400)}>
          <View style={[styles.sponsorDivider, { backgroundColor: colors.border }]} />
          <Pressable
            onPress={openSponsor}
            style={({ pressed }) => [
              styles.sponsorBlock,
              pressed && { opacity: 0.8 },
            ]}
          >
            <Text style={[styles.sponsorLabel, { color: colors.muted }]}>Sponsored by</Text>
            {colorScheme === "dark" ? (
              <Image
                source={require("../../assets/images/rvpsupply-logo.png")}
                style={styles.sponsorLogo}
                contentFit="contain"
              />
            ) : (
              <View style={[styles.sponsorLogoCard, { backgroundColor: "#1C1C1E" }]}>
                <Image
                  source={require("../../assets/images/rvpsupply-logo-transparent.png")}
                  style={styles.sponsorLogo}
                  contentFit="contain"
                />
              </View>
            )}
          </Pressable>
        </Animated.View>

        {/* ── Version Footer ── */}
        <View style={styles.versionFooter}>
          <Text style={[styles.versionFooterText, { color: colors.muted }]}>85Blends · v1.0.1</Text>
          <Text style={[styles.versionFooterSub, { color: colors.border }]}>Build 7 · {Platform.OS === "ios" ? "iOS" : Platform.OS === "android" ? "Android" : "Web"}</Text>
        </View>

        <View style={{ height: 40 }} />
      </ScrollView>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  scrollContent: { paddingBottom: 24 },
  header: {
    paddingHorizontal: 20,
    paddingTop: 16,
    paddingBottom: 12,
  },
  headerTitle: {
    fontSize: 28,
    fontWeight: "700",
    letterSpacing: -0.5,
  },
  section: { paddingHorizontal: 16, marginBottom: 24 },
  sectionTitle: { fontSize: 13, fontWeight: "600", textTransform: "uppercase", letterSpacing: 0.5 },
  card: { borderRadius: 16, borderWidth: StyleSheet.hairlineWidth, overflow: "hidden" },
  settingRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingHorizontal: 16, paddingVertical: 14, gap: 12 },
  settingLabel: { flex: 1 },
  settingName: { fontSize: 15, fontWeight: "600" },
  settingDesc: { fontSize: 12, marginTop: 2 },
  divider: { height: StyleSheet.hairlineWidth, marginHorizontal: 16 },
  themeToggleRow: { flexDirection: "row", gap: 8, paddingHorizontal: 16, paddingBottom: 14 },
  themeOption: { flex: 1, flexDirection: "row", alignItems: "center", justifyContent: "center", gap: 6, paddingVertical: 10, borderRadius: 12, borderWidth: 1.5 },
  themeOptionText: { fontSize: 13, fontWeight: "600" },
  actionButton: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingHorizontal: 16, paddingVertical: 14 },
  actionButtonContent: { flexDirection: "row", alignItems: "center", gap: 12, flex: 1 },
  actionIconBg: { width: 40, height: 40, borderRadius: 12, alignItems: "center", justifyContent: "center" },
  actionTextCol: { flex: 1 },
  actionButtonText: { fontSize: 15, fontWeight: "600" },
  actionButtonDesc: { fontSize: 12, marginTop: 2 },
  sponsorDivider: {
    height: StyleSheet.hairlineWidth,
    marginHorizontal: 24,
  },
  sponsorBlock: {
    alignItems: "center",
    paddingVertical: 16,
    gap: 10,
  },
  sponsorLabel: {
    fontSize: 11,
    fontWeight: "500",
    letterSpacing: 0.6,
    textTransform: "uppercase",
  },
  sponsorLogo: {
    width: 220,
    height: 168,
  },
  sponsorLogoCard: {
    borderRadius: 14,
    paddingHorizontal: 20,
    paddingVertical: 12,
  },
  versionFooter: { alignItems: "center", paddingVertical: 12, gap: 4 },
  versionFooterText: { fontSize: 13, fontWeight: "500" },
  versionFooterSub: { fontSize: 11 },
});

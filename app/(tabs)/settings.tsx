import React, { useState, useEffect } from "react";
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
import { useGarage } from "../../lib/garage-context";
import { useSettings } from "../../lib/settings-context";
import { useTheme } from "../../lib/theme-context";
import { ScreenContainer } from "../../components/ScreenContainer";
import { IconSymbol } from "../../components/ui/IconSymbol";
import { CarFormModal } from "../../components/CarFormModal";

export default function SettingsScreen() {
  const { cars, addCar, updateCar, deleteCar } = useGarage();
  const { settings, updateSettings, clearAllData } = useSettings();
  const { colors } = useTheme();
  const colorScheme = useColorScheme();

  const [modalVisible, setModalVisible] = useState(false);
  const [editProfile, setEditProfile] = useState<any>(null);

  const handleAddCar = () => {
    setEditProfile(null);
    setModalVisible(true);
  };

  const handleEditCar = (car: any) => {
    setEditProfile(car);
    setModalVisible(true);
  };

  const handleSaveCar = (carData: any) => {
    if (editProfile) {
      updateCar(editProfile.id, carData);
    } else {
      addCar(carData);
    }
    setModalVisible(false);
  };

  const confirmClearData = () => {
    Alert.alert(
      "Clear All Data",
      "This will remove all cars from your garage and reset all settings. This action cannot be undone.",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Clear Everything",
          style: "destructive",
          onPress: () => {
            clearAllData();
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
          },
        },
      ]
    );
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

        {/* ── Garage Section ── */}
        <Animated.View entering={FadeInDown.delay(100).duration(400)} style={styles.section}>
          <View style={styles.sectionHeaderRow}>
            <Text style={[styles.sectionTitle, { color: colors.foreground }]}>Garage</Text>
            <Pressable
              onPress={handleAddCar}
              style={({ pressed }) => [
                styles.sectionAddBtn,
                { backgroundColor: colors.primary, opacity: pressed ? 0.8 : 1 },
              ]}
            >
              <IconSymbol name="plus" size={14} color="#fff" />
              <Text style={styles.sectionAddBtnText}>Add Car</Text>
            </Pressable>
          </View>

          <View style={[styles.card, { backgroundColor: colors.card, borderColor: colors.border }]}>
            {cars.length === 0 ? (
              <View style={styles.emptyGarageCard}>
                <Text style={styles.emptyGarageEmoji}>🏎️</Text>
                <View>
                  <Text style={[styles.emptyGarageTitle, { color: colors.foreground }]}>Your garage is empty</Text>
                  <Text style={[styles.emptyGarageSub, { color: colors.muted }]}>Add your car to save fuel settings</Text>
                </View>
              </View>
            ) : (
              cars.map((car, index) => (
                <React.Fragment key={car.id}>
                  <Pressable
                    onPress={() => handleEditCar(car)}
                    style={({ pressed }) => [
                      styles.settingRow,
                      pressed && { backgroundColor: colors.border + "40" },
                    ]}
                  >
                    <View style={[styles.sectionIcon, { backgroundColor: car.color + "20" }]}>
                      <IconSymbol name="car.fill" size={20} color={car.color} />
                    </View>
                    <View style={styles.settingLabel}>
                      <Text style={[styles.settingName, { color: colors.foreground }]}>{car.name}</Text>
                      <Text style={[styles.settingDesc, { color: colors.muted }]}>
                        {car.year} {car.make} {car.model}
                      </Text>
                    </View>
                    <IconSymbol name="chevron.right" size={16} color={colors.muted} />
                  </Pressable>
                  {index < cars.length - 1 && (
                    <View style={[styles.divider, { backgroundColor: colors.border }]} />
                  )}
                </React.Fragment>
              ))
            )}
          </View>
        </Animated.View>

        {/* ── Fuel Settings Section ── */}
        <Animated.View entering={FadeInDown.delay(200).duration(400)} style={styles.section}>
          <Text style={[styles.sectionTitle, { color: colors.foreground, marginBottom: 12 }]}>Fuel Defaults</Text>
          <View style={[styles.card, { backgroundColor: colors.card, borderColor: colors.border }]}>
            
            {/* Pump E-Content */}
            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>Pump E-Content</Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>Standard pump gas ethanol %</Text>
              </View>
              <View style={styles.numericFieldRow}>
                <Pressable 
                  onPress={() => updateSettings({ pumpEthanol: Math.max(0, settings.pumpEthanol - 1) })}
                  style={[styles.decimalBtn, { backgroundColor: colors.border + "60" }]}
                >
                  <Text style={[styles.decimalBtnText, { color: colors.foreground }]}>-</Text>
                </Pressable>
                <TextInput
                  style={[styles.numberInput, { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background }]}
                  value={String(settings.pumpEthanol)}
                  onChangeText={(val) => updateSettings({ pumpEthanol: parseInt(val) || 0 })}
                  keyboardType="number-pad"
                />
                <Pressable 
                  onPress={() => updateSettings({ pumpEthanol: Math.min(25, settings.pumpEthanol + 1) })}
                  style={[styles.decimalBtn, { backgroundColor: colors.border + "60" }]}
                >
                  <Text style={[styles.decimalBtnText, { color: colors.foreground }]}>+</Text>
                </Pressable>
              </View>
            </View>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            {/* E85 E-Content */}
            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>E85 E-Content</Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>Standard E85 ethanol %</Text>
              </View>
              <View style={styles.numericFieldRow}>
                <Pressable 
                  onPress={() => updateSettings({ e85Ethanol: Math.max(50, settings.e85Ethanol - 1) })}
                  style={[styles.decimalBtn, { backgroundColor: colors.border + "60" }]}
                >
                  <Text style={[styles.decimalBtnText, { color: colors.foreground }]}>-</Text>
                </Pressable>
                <TextInput
                  style={[styles.numberInput, { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background }]}
                  value={String(settings.e85Ethanol)}
                  onChangeText={(val) => updateSettings({ e85Ethanol: parseInt(val) || 0 })}
                  keyboardType="number-pad"
                />
                <Pressable 
                  onPress={() => updateSettings({ e85Ethanol: Math.min(100, settings.e85Ethanol + 1) })}
                  style={[styles.decimalBtn, { backgroundColor: colors.border + "60" }]}
                >
                  <Text style={[styles.decimalBtnText, { color: colors.foreground }]}>+</Text>
                </Pressable>
              </View>
            </View>

          </View>
        </Animated.View>

        {/* ── App Settings Section ── */}
        <Animated.View entering={FadeInDown.delay(300).duration(400)} style={styles.section}>
          <Text style={[styles.sectionTitle, { color: colors.foreground, marginBottom: 12 }]}>App Settings</Text>
          <View style={[styles.card, { backgroundColor: colors.card, borderColor: colors.border }]}>
            
            {/* Theme Toggle */}
            <View style={{ paddingTop: 14 }}>
              <View style={[styles.settingRow, { paddingBottom: 8 }]}>
                <View style={styles.settingLabel}>
                  <Text style={[styles.settingName, { color: colors.foreground }]}>Appearance</Text>
                  <Text style={[styles.settingDesc, { color: colors.muted }]}>Choose your preferred theme</Text>
                </View>
              </View>
              <View style={styles.themeToggleRow}>
                {(["system", "light", "dark"] as const).map((t) => (
                  <Pressable
                    key={t}
                    onPress={() => updateSettings({ theme: t })}
                    style={[
                      styles.themeOption,
                      { 
                        borderColor: settings.theme === t ? colors.primary : colors.border,
                        backgroundColor: settings.theme === t ? colors.primary + "10" : "transparent"
                      }
                    ]}
                  >
                    <IconSymbol 
                      name={t === "system" ? "desktopcomputer" : t === "light" ? "sun.max.fill" : "moon.fill"} 
                      size={14} 
                      color={settings.theme === t ? colors.primary : colors.muted} 
                    />
                    <Text style={[
                      styles.themeOptionText, 
                      { color: settings.theme === t ? colors.primary : colors.muted }
                    ]}>
                      {t.charAt(0).toUpperCase() + t.slice(1)}
                    </Text>
                  </Pressable>
                ))}
              </View>
            </View>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            {/* Clear Data */}
            <Pressable
              onPress={confirmClearData}
              style={({ pressed }) => [
                styles.settingRow,
                pressed && { backgroundColor: colors.border + "40" },
              ]}
            >
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: "#EF4444" }]}>Clear All Data</Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>Reset garage and settings</Text>
              </View>
              <IconSymbol name="trash.fill" size={18} color="#EF4444" />
            </Pressable>

          </View>
        </Animated.View>

        {/* ── Support Section ── */}
        <Animated.View entering={FadeInDown.delay(400).duration(400)} style={styles.section}>
          <Text style={[styles.sectionTitle, { color: colors.foreground, marginBottom: 12 }]}>Support</Text>
          <View style={[styles.card, { backgroundColor: colors.card, borderColor: colors.border }]}>
            
            <Pressable
              onPress={() => Linking.openURL("mailto:support@85blends.app").catch(() => {})}
              style={({ pressed }) => [styles.actionButton, pressed && { opacity: 0.7 }]}
            >
              <View style={styles.actionButtonContent}>
                <View style={[styles.actionIconBg, { backgroundColor: colors.primary + "18" }]}>
                  <IconSymbol name="paperplane.fill" size={20} color={colors.primary} />
                </View>
                <View style={styles.actionTextCol}>
                  <Text style={[styles.actionButtonText, { color: colors.foreground }]}>Send Feedback</Text>
                  <Text style={[styles.actionButtonDesc, { color: colors.muted }]}>Bug reports, ideas & beta feedback</Text>
                </View>
              </View>
              <IconSymbol name="chevron.right" size={16} color={colors.muted} />
            </Pressable>

          </View>
        </Animated.View>

        {/* ── Sponsor Block ── */}
        <View style={[styles.sponsorDivider, { backgroundColor: colors.border }]} />
        <Pressable
          onPress={() => Linking.openURL("https://rvpsupply.com").catch(() => {})}
          style={({ pressed }) => [styles.sponsorBlock, { opacity: pressed ? 0.75 : 1 }]}
        >
          <Text style={[styles.sponsorLabel, { color: colors.muted }]}>Sponsored by</Text>
          {colorScheme === "dark" ? (
            // Dark mode: transparent-background logo
            <Image
              source={require("../../assets/images/rvpsupply-logo-transparent.png")}
              style={styles.sponsorLogo}
              contentFit="contain"
            />
          ) : (
            // Light mode: original black-background logo
            <Image
              source={require("../../assets/images/rvpsupply-logo.png")}
              style={styles.sponsorLogo}
              contentFit="contain"
            />
          )}
        </Pressable>

        {/* ── Version Footer ── */}
        <View style={styles.versionFooter}>
          <Text style={[styles.versionFooterText, { color: colors.muted }]}>85Blends · v1.0.1</Text>
          <Text style={[styles.versionFooterSub, { color: colors.border }]}>Build 7 · {Platform.OS === "ios" ? "iOS" : Platform.OS === "android" ? "Android" : "Web"}</Text>
        </View>

        <View style={{ height: 40 }} />
      </ScrollView>

      <CarFormModal
        visible={modalVisible}
        editProfile={editProfile}
        onClose={() => setModalVisible(false)}
        onSave={handleSaveCar}
        colors={colors}
      />
    </ScreenContainer>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────
const styles = StyleSheet.create({
  scrollContent: { paddingBottom: 24 },
  loadingText: { fontSize: 15, textAlign: "center", marginTop: 40 },
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
  sectionHeaderRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 12,
  },
  sectionTitle: { fontSize: 18, fontWeight: "700", letterSpacing: -0.3 },
  sectionAddBtn: {
    flexDirection: "row",
    alignItems: "center",
    gap: 4,
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 14,
  },
  sectionAddBtnText: { color: "#fff", fontSize: 13, fontWeight: "600" },
  emptyGarageCard: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    padding: 16,
    borderRadius: 14,
    borderWidth: StyleSheet.hairlineWidth,
  },
  emptyGarageEmoji: { fontSize: 28 },
  emptyGarageTitle: { fontSize: 15, fontWeight: "600" },
  emptyGarageSub: { fontSize: 12, marginTop: 2 },
  card: { borderRadius: 16, borderWidth: StyleSheet.hairlineWidth, overflow: "hidden" },
  settingRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingHorizontal: 16, paddingVertical: 14, gap: 12 },
  settingLabel: { flex: 1 },
  settingName: { fontSize: 15, fontWeight: "600" },
  settingDesc: { fontSize: 12, marginTop: 2 },
  numericFieldRow: { flexDirection: "row", alignItems: "center", gap: 6 },
  numberInput: { borderWidth: 1, borderRadius: 10, paddingHorizontal: 12, paddingVertical: 8, fontSize: 14, fontWeight: "600", minWidth: 72, textAlign: "center" },
  decimalBtn: { width: 32, height: 36, borderRadius: 8, alignItems: "center", justifyContent: "center" },
  decimalBtnText: { fontSize: 20, fontWeight: "800" },
  octaneButtons: { flexDirection: "row", gap: 6 },
  octaneButton: { borderWidth: 1.5, borderRadius: 10, paddingHorizontal: 10, paddingVertical: 7, alignItems: "center", justifyContent: "center" },
  octaneButtonText: { fontSize: 13, fontWeight: "700" },
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
  aboutContent: { padding: 20, alignItems: "center", gap: 4 },
  aboutTitle: { fontSize: 16, fontWeight: "700" },
  aboutVersion: { fontSize: 13 },
  aboutDesc: { fontSize: 13, textAlign: "center", lineHeight: 18, marginTop: 4 },
  clearAllBtn: { paddingHorizontal: 10, paddingVertical: 4 },
  clearAllBtnText: { fontSize: 13, fontWeight: "600" },
  disclaimerBox: { padding: 16, borderRadius: 0 },
  disclaimerTitle: { fontSize: 14, fontWeight: "700", marginBottom: 6 },
  sectionIcon: {
    width: 40,
    height: 40,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
  },
  cardRowTitle: {
    fontSize: 15,
    fontWeight: "600",
  },
  cardRowSubtitle: {
    fontSize: 12,
    marginTop: 2,
  },
  disclaimerText: { fontSize: 13, lineHeight: 19 },
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
  versionFooter: { alignItems: "center", paddingVertical: 12, gap: 4 },
  versionFooterText: { fontSize: 13, fontWeight: "500" },
  versionFooterSub: { fontSize: 11 },
});

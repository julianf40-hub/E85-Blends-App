import { useCallback, useEffect, useRef, useState } from "react";
import {
  Text,
  View,
  ScrollView,
  Pressable,
  StyleSheet,
  TextInput,
  Alert,
  Platform,
  FlatList,
  Modal,
  Switch,
} from "react-native";
import Animated, { FadeIn, FadeInDown } from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import { useFocusEffect } from "expo-router";
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
import {
  CarProfile,
  NewCarProfile,
  DEFAULT_CAR,
  loadGarage,
  addCarProfile,
  updateCarProfile,
  deleteCarProfile,
  getActiveCarId,
  setActiveCarId,
  getRandomCarColor,
  getRandomCarIcon,
  clearGarage,
} from "@/lib/garage";
import { useThemeContext } from "@/lib/theme-provider";

// ─── Decimal sanitizer ───────────────────────────────────────────────────────
function sanitizeDecimal(text: string): string {
  let cleaned = text.replace(",", ".");
  const parts = cleaned.split(".");
  if (parts.length > 2) {
    cleaned = parts[0] + "." + parts.slice(1).join("");
  }
  cleaned = cleaned.replace(/[^\d.]/g, "");
  return cleaned;
}

// ─── Numeric field ────────────────────────────────────────────────────────────
function NumericField({
  value,
  onSave,
  placeholder,
  colors,
}: {
  value: number;
  onSave: (n: number) => void;
  placeholder: string;
  colors: ReturnType<typeof useColors>;
}) {
  const [text, setText] = useState(value.toString());
  const inputRef = useRef<TextInput>(null);

  useEffect(() => {
    setText(value.toString());
  }, [value]);

  return (
    <View style={styles.numericFieldRow}>
      <TextInput
        ref={inputRef}
        style={[styles.numberInput, { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background }]}
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
          if (!isNaN(num)) onSave(num);
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
        style={({ pressed }) => [styles.decimalBtn, { backgroundColor: colors.primary + "20" }, pressed && { opacity: 0.6 }]}
      >
        <Text style={[styles.decimalBtnText, { color: colors.primary }]}>.</Text>
      </Pressable>
    </View>
  );
}

// ─── Garage: Car Form Modal ───────────────────────────────────────────────────
const PALETTE = ["#10B981", "#3B82F6", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899", "#14B8A6", "#F97316"];
const ICONS = ["🚗", "🏎️", "🚙", "🛻", "🚕", "⚡", "🔥", "💨"];

interface FormState {
  nickname: string; year: string; make: string; model: string; trim: string;
  tankSize: string; mpgE85: string; mpgGas: string; requiredOctane: string;
  isFlexFuel: boolean; defaultBlend: string; color: string; icon: string;
}

function profileToForm(p: NewCarProfile): FormState {
  return {
    nickname: p.nickname, year: p.year, make: p.make, model: p.model, trim: p.trim,
    tankSize: p.tankSize.toString(), mpgE85: p.mpgE85.toString(), mpgGas: p.mpgGas.toString(),
    requiredOctane: p.requiredOctane.toString(), isFlexFuel: p.isFlexFuel,
    defaultBlend: p.defaultBlend.toString(), color: p.color, icon: p.icon,
  };
}

function formToProfile(f: FormState): NewCarProfile {
  return {
    nickname: f.nickname.trim(), year: f.year.trim(), make: f.make.trim(),
    model: f.model.trim(), trim: f.trim.trim(),
    tankSize: parseFloat(f.tankSize) || 16, mpgE85: parseFloat(f.mpgE85) || 22,
    mpgGas: parseFloat(f.mpgGas) || 28, requiredOctane: parseInt(f.requiredOctane) || 87,
    isFlexFuel: f.isFlexFuel, defaultBlend: parseInt(f.defaultBlend) || 30,
    color: f.color, icon: f.icon,
  };
}

interface FieldProps {
  label: string; value: string; onChangeText: (t: string) => void;
  placeholder?: string; numeric?: boolean; onDecimal?: () => void;
  colors: ReturnType<typeof useColors>;
}
function Field({ label, value, onChangeText, placeholder, numeric, onDecimal, colors }: FieldProps) {
  return (
    <View style={ff.row}>
      <Text style={[ff.label, { color: colors.muted }]}>{label}</Text>
      <View style={ff.inputWrap}>
        <TextInput
          style={[ff.input, { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background }]}
          value={value} onChangeText={onChangeText} placeholder={placeholder ?? label}
          placeholderTextColor={colors.muted} keyboardType={numeric ? "decimal-pad" : "default"}
          autoCapitalize="none" autoCorrect={false} returnKeyType="done"
        />
        {numeric && onDecimal && (
          <Pressable onPress={onDecimal}
            style={({ pressed }) => [ff.dot, { backgroundColor: colors.primary + "20", borderColor: colors.primary + "40", opacity: pressed ? 0.6 : 1 }]}>
            <Text style={[ff.dotText, { color: colors.primary }]}>.</Text>
          </Pressable>
        )}
      </View>
    </View>
  );
}
const ff = StyleSheet.create({
  row: { marginBottom: 14 },
  label: { fontSize: 12, fontWeight: "600", marginBottom: 6, textTransform: "uppercase", letterSpacing: 0.5 },
  inputWrap: { flexDirection: "row", alignItems: "center", gap: 8 },
  input: { flex: 1, height: 44, borderWidth: 1, borderRadius: 10, paddingHorizontal: 12, fontSize: 15 },
  dot: { width: 36, height: 44, borderRadius: 10, borderWidth: 1, justifyContent: "center", alignItems: "center" },
  dotText: { fontSize: 22, fontWeight: "800", lineHeight: 26 },
});

function CarFormModal({ visible, editProfile, onClose, onSave, colors }: {
  visible: boolean; editProfile: CarProfile | null;
  onClose: () => void; onSave: (data: NewCarProfile, id?: string) => Promise<void>;
  colors: ReturnType<typeof useColors>;
}) {
  const [form, setForm] = useState<FormState>(() =>
    profileToForm(editProfile ?? { ...DEFAULT_CAR, color: getRandomCarColor(), icon: getRandomCarIcon() })
  );
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (visible) {
      setForm(profileToForm(editProfile ?? { ...DEFAULT_CAR, color: getRandomCarColor(), icon: getRandomCarIcon() }));
    }
  }, [visible, editProfile]);

  const set = useCallback((key: keyof FormState, value: string | boolean) => {
    setForm((prev) => ({ ...prev, [key]: value }));
  }, []);

  const addDecimal = useCallback((key: keyof FormState) => {
    setForm((prev) => {
      const cur = prev[key] as string;
      if (!cur.includes(".")) return { ...prev, [key]: cur === "" ? "0." : cur + "." };
      return prev;
    });
  }, []);

  const handleSave = useCallback(async () => {
    if (!form.make.trim() || !form.model.trim()) {
      Alert.alert("Missing Info", "Please enter at least a Make and Model.");
      return;
    }
    setSaving(true);
    try {
      await onSave(formToProfile(form), editProfile?.id);
      onClose();
    } finally {
      setSaving(false);
    }
  }, [form, editProfile, onSave, onClose]);

  return (
    <Modal visible={visible} animationType="slide" presentationStyle="pageSheet" onRequestClose={onClose}>
      <View style={[mf.container, { backgroundColor: colors.background }]}>
        <View style={[mf.header, { borderBottomColor: colors.border }]}>
          <Pressable onPress={onClose} style={({ pressed }) => [mf.headerBtn, { opacity: pressed ? 0.6 : 1 }]}>
            <Text style={[mf.cancelText, { color: colors.primary }]}>Cancel</Text>
          </Pressable>
          <Text style={[mf.title, { color: colors.foreground }]}>{editProfile ? "Edit Car" : "Add Car"}</Text>
          <Pressable onPress={handleSave} disabled={saving} style={({ pressed }) => [mf.headerBtn, { opacity: pressed || saving ? 0.6 : 1 }]}>
            <Text style={[mf.saveText, { color: colors.primary }]}>{saving ? "Saving…" : "Save"}</Text>
          </Pressable>
        </View>
        <ScrollView style={mf.scroll} contentContainerStyle={mf.scrollContent} keyboardShouldPersistTaps="handled" showsVerticalScrollIndicator={false}>
          <View style={[mf.section, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            <Text style={[mf.sectionTitle, { color: colors.muted }]}>APPEARANCE</Text>
            <Text style={[mf.subLabel, { color: colors.muted }]}>Icon</Text>
            <ScrollView horizontal showsHorizontalScrollIndicator={false} style={mf.iconRow}>
              {ICONS.map((ic) => (
                <Pressable key={ic} onPress={() => set("icon", ic)}
                  style={[mf.iconChip, { backgroundColor: form.icon === ic ? form.color + "30" : colors.background, borderColor: form.icon === ic ? form.color : colors.border }]}>
                  <Text style={mf.iconEmoji}>{ic}</Text>
                </Pressable>
              ))}
            </ScrollView>
            <Text style={[mf.subLabel, { color: colors.muted, marginTop: 12 }]}>Accent Color</Text>
            <View style={mf.colorRow}>
              {PALETTE.map((c) => (
                <Pressable key={c} onPress={() => set("color", c)}
                  style={[mf.colorDot, { backgroundColor: c, borderWidth: form.color === c ? 3 : 0, borderColor: colors.foreground }]} />
              ))}
            </View>
          </View>
          <View style={[mf.section, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            <Text style={[mf.sectionTitle, { color: colors.muted }]}>VEHICLE INFO</Text>
            <Field label="Nickname" value={form.nickname} onChangeText={(t) => set("nickname", t)} placeholder="e.g. Daily Driver" colors={colors} />
            <Field label="Year" value={form.year} onChangeText={(t) => set("year", t)} placeholder="2024" colors={colors} />
            <Field label="Make" value={form.make} onChangeText={(t) => set("make", t)} placeholder="e.g. Ford" colors={colors} />
            <Field label="Model" value={form.model} onChangeText={(t) => set("model", t)} placeholder="e.g. Mustang" colors={colors} />
            <Field label="Trim" value={form.trim} onChangeText={(t) => set("trim", t)} placeholder="e.g. GT500" colors={colors} />
          </View>
          <View style={[mf.section, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            <Text style={[mf.sectionTitle, { color: colors.muted }]}>FUEL & PERFORMANCE</Text>
            <Field label="Tank Size (gal)" value={form.tankSize} onChangeText={(t) => set("tankSize", sanitizeDecimal(t))} placeholder="16.0" numeric onDecimal={() => addDecimal("tankSize")} colors={colors} />
            <Field label="MPG on E85" value={form.mpgE85} onChangeText={(t) => set("mpgE85", sanitizeDecimal(t))} placeholder="22.0" numeric onDecimal={() => addDecimal("mpgE85")} colors={colors} />
            <Field label="MPG on Gas" value={form.mpgGas} onChangeText={(t) => set("mpgGas", sanitizeDecimal(t))} placeholder="28.0" numeric onDecimal={() => addDecimal("mpgGas")} colors={colors} />
            <Field label="Required Octane" value={form.requiredOctane} onChangeText={(t) => set("requiredOctane", t.replace(/[^\d]/g, ""))} placeholder="87" numeric colors={colors} />
            <Field label="Default Blend %" value={form.defaultBlend} onChangeText={(t) => set("defaultBlend", t.replace(/[^\d]/g, ""))} placeholder="30" numeric colors={colors} />
            <View style={mf.toggleRow}>
              <View style={mf.toggleLabel}>
                <Text style={[mf.toggleTitle, { color: colors.foreground }]}>Flex-Fuel Vehicle</Text>
                <Text style={[mf.toggleSub, { color: colors.muted }]}>Certified to run E85 blends</Text>
              </View>
              <Switch value={form.isFlexFuel} onValueChange={(v) => set("isFlexFuel", v)} trackColor={{ false: colors.border, true: colors.primary }} thumbColor="#fff" />
            </View>
          </View>
        </ScrollView>
      </View>
    </Modal>
  );
}
const mf = StyleSheet.create({
  container: { flex: 1 },
  header: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", paddingHorizontal: 20, paddingTop: Platform.OS === "ios" ? 16 : 12, paddingBottom: 14, borderBottomWidth: 1 },
  headerBtn: { minWidth: 60 },
  title: { fontSize: 17, fontWeight: "700" },
  cancelText: { fontSize: 16 },
  saveText: { fontSize: 16, fontWeight: "700", textAlign: "right" },
  scroll: { flex: 1 },
  scrollContent: { padding: 16, gap: 16, paddingBottom: 40 },
  section: { borderRadius: 16, padding: 16, borderWidth: 1 },
  sectionTitle: { fontSize: 11, fontWeight: "700", letterSpacing: 0.8, marginBottom: 14 },
  subLabel: { fontSize: 12, fontWeight: "600", marginBottom: 8 },
  iconRow: { marginBottom: 4 },
  iconChip: { width: 48, height: 48, borderRadius: 12, borderWidth: 2, justifyContent: "center", alignItems: "center", marginRight: 8 },
  iconEmoji: { fontSize: 24 },
  colorRow: { flexDirection: "row", flexWrap: "wrap", gap: 10 },
  colorDot: { width: 32, height: 32, borderRadius: 16 },
  toggleRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", marginTop: 4 },
  toggleLabel: { flex: 1, marginRight: 16 },
  toggleTitle: { fontSize: 15, fontWeight: "600" },
  toggleSub: { fontSize: 12, marginTop: 2 },
});

// ─── Garage: Car Card (compact inline version) ────────────────────────────────
function InlineCarCard({ profile, isActive, onSetActive, onEdit, onDelete, colors }: {
  profile: CarProfile; isActive: boolean;
  onSetActive: () => void; onEdit: () => void; onDelete: () => void;
  colors: ReturnType<typeof useColors>;
}) {
  const carLabel = profile.nickname || `${profile.year} ${profile.make} ${profile.model}`.trim() || "My Car";

  return (
    <View style={[cc.container, {
      backgroundColor: isActive ? profile.color + "12" : colors.background,
      borderColor: isActive ? profile.color + "60" : colors.border,
      borderWidth: isActive ? 1.5 : StyleSheet.hairlineWidth,
    }]}>
      <View style={cc.row}>
        <View style={[cc.iconWrap, { backgroundColor: profile.color + "22" }]}>
          <Text style={cc.iconEmoji}>{profile.icon}</Text>
        </View>
        <View style={cc.info}>
          <View style={cc.nameRow}>
            <Text style={[cc.name, { color: colors.foreground }]} numberOfLines={1}>{carLabel}</Text>
            {isActive && (
              <View style={[cc.activeBadge, { backgroundColor: profile.color }]}>
                <Text style={cc.activeBadgeText}>ACTIVE</Text>
              </View>
            )}
          </View>
          <Text style={[cc.sub, { color: colors.muted }]} numberOfLines={1}>
            {[profile.year, profile.make, profile.model].filter(Boolean).join(" ")} · {profile.tankSize} gal
          </Text>
        </View>
      </View>
      <View style={[cc.actions, { borderTopColor: colors.border }]}>
        {!isActive && (
          <Pressable onPress={onSetActive} style={({ pressed }) => [cc.actionBtn, { backgroundColor: profile.color + "20", opacity: pressed ? 0.7 : 1 }]}>
            <IconSymbol name="checkmark.circle.fill" size={14} color={profile.color} />
            <Text style={[cc.actionText, { color: profile.color }]}>Set Active</Text>
          </Pressable>
        )}
        <Pressable onPress={onEdit} style={({ pressed }) => [cc.actionBtn, { backgroundColor: colors.surface, opacity: pressed ? 0.7 : 1 }]}>
          <IconSymbol name="pencil" size={14} color={colors.muted} />
          <Text style={[cc.actionText, { color: colors.muted }]}>Edit</Text>
        </Pressable>
        <Pressable onPress={onDelete} style={({ pressed }) => [cc.actionBtn, { backgroundColor: "#EF444415", opacity: pressed ? 0.7 : 1 }]}>
          <IconSymbol name="trash.fill" size={14} color="#EF4444" />
          <Text style={[cc.actionText, { color: "#EF4444" }]}>Delete</Text>
        </Pressable>
      </View>
    </View>
  );
}
const cc = StyleSheet.create({
  container: { borderRadius: 14, overflow: "hidden", marginBottom: 10 },
  row: { flexDirection: "row", alignItems: "center", padding: 14, gap: 12 },
  iconWrap: { width: 44, height: 44, borderRadius: 12, justifyContent: "center", alignItems: "center" },
  iconEmoji: { fontSize: 22 },
  info: { flex: 1 },
  nameRow: { flexDirection: "row", alignItems: "center", gap: 8 },
  name: { fontSize: 15, fontWeight: "700", flexShrink: 1 },
  activeBadge: { paddingHorizontal: 6, paddingVertical: 2, borderRadius: 5 },
  activeBadgeText: { fontSize: 9, fontWeight: "800", color: "#fff", letterSpacing: 0.5 },
  sub: { fontSize: 12, marginTop: 2 },
  actions: { flexDirection: "row", borderTopWidth: StyleSheet.hairlineWidth, paddingHorizontal: 10, paddingVertical: 8, gap: 6 },
  actionBtn: { flex: 1, flexDirection: "row", alignItems: "center", justifyContent: "center", gap: 5, paddingVertical: 7, borderRadius: 8 },
  actionText: { fontSize: 12, fontWeight: "600" },
});

// ─── Main Screen ──────────────────────────────────────────────────────────────
export default function MoreScreen() {
  const colors = useColors();
  const { colorScheme, setColorScheme } = useThemeContext();
  const [prefs, setPrefs] = useState<UserPreferences | null>(null);
  const [loading, setLoading] = useState(true);

  // Garage state
  const [profiles, setProfiles] = useState<CarProfile[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [modalVisible, setModalVisible] = useState(false);
  const [editProfile, setEditProfile] = useState<CarProfile | null>(null);

  const loadAll = useCallback(async () => {
    const [loaded, cars, aid] = await Promise.all([loadPreferences(), loadGarage(), getActiveCarId()]);
    setPrefs(loaded);
    setProfiles(cars);
    setActiveId(aid);
    setLoading(false);
  }, []);

  useFocusEffect(useCallback(() => { loadAll(); }, [loadAll]));

  const handleSavePreference = useCallback(async <K extends keyof UserPreferences>(key: K, value: UserPreferences[K]) => {
    if (!prefs) return;
    const updated = { ...prefs, [key]: value };
    setPrefs(updated);
    await savePreferences(updated);
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  }, [prefs]);

  // Garage handlers
  const handleAddCar = useCallback(() => {
    setEditProfile(null);
    setModalVisible(true);
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  }, []);

  const handleSaveCar = useCallback(async (data: NewCarProfile, id?: string) => {
    if (id) await updateCarProfile(id, data);
    else await addCarProfile(data);
    await loadAll();
    if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
  }, [loadAll]);

  const handleSetActive = useCallback(async (id: string) => {
    await setActiveCarId(id);
    setActiveId(id);
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
  }, []);

  const handleDeleteCar = useCallback((profile: CarProfile) => {
    Alert.alert(
      "Delete Car",
      `Remove "${profile.nickname || `${profile.make} ${profile.model}`}" from your garage?`,
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Delete", style: "destructive",
          onPress: async () => {
            await deleteCarProfile(profile.id);
            await loadAll();
            if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
          },
        },
      ]
    );
  }, [loadAll]);

  const handleResetPreferences = useCallback(() => {
    Alert.alert("Reset Preferences?", "This will restore all settings to defaults.", [
      { text: "Cancel" },
      {
        text: "Reset", style: "destructive",
        onPress: async () => {
          const defaults = await resetPreferences();
          setPrefs(defaults);
          if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
        },
      },
    ]);
  }, []);

  const handleClearData = useCallback(() => {
    Alert.alert(
      "Clear All Data?",
      "This will delete fuel logs, favorites, history, reviews, and your garage. This cannot be undone.",
      [
        { text: "Cancel" },
        {
          text: "Clear", style: "destructive",
          onPress: async () => {
            await clearFuelLog();
            await clearHistory();
            await clearFavorites();
            await clearReviews();
            await clearGarage();
            setProfiles([]);
            setActiveId(null);
            if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
            Alert.alert("Success", "All data has been cleared.");
          },
        },
      ]
    );
  }, []);

  if (loading || !prefs) {
    return (
      <ScreenContainer>
        <Text style={[styles.loadingText, { color: colors.muted }]}>Loading…</Text>
      </ScreenContainer>
    );
  }

  return (
    <ScreenContainer>
      <ScrollView contentContainerStyle={styles.scrollContent} keyboardShouldPersistTaps="handled" showsVerticalScrollIndicator={false}>

        {/* ── Header ── */}
        <View style={styles.header}>
          <Text style={[styles.headerTitle, { color: colors.foreground }]}>More</Text>
        </View>

        {/* ── My Garage Section ── */}
        <Animated.View entering={FadeInDown.duration(300)} style={styles.section}>
          <View style={styles.sectionHeaderRow}>
            <Text style={[styles.sectionTitle, { color: colors.foreground }]}>My Garage</Text>
            <Pressable
              onPress={handleAddCar}
              style={[styles.sectionAddBtn, { backgroundColor: colors.primary }]}
            >
              <IconSymbol name="plus" size={14} color="#fff" />
              <Text style={styles.sectionAddBtnText}>Add Car</Text>
            </Pressable>
          </View>

          {profiles.length === 0 ? (
            <Pressable
              onPress={handleAddCar}
              style={[styles.emptyGarageCard, { backgroundColor: colors.surface, borderColor: colors.border }]}
            >
              <Text style={styles.emptyGarageEmoji}>🚗</Text>
              <View style={{ flex: 1 }}>
                <Text style={[styles.emptyGarageTitle, { color: colors.foreground }]}>No cars yet</Text>
                <Text style={[styles.emptyGarageSub, { color: colors.muted }]}>Add a car to auto-fill the calculator</Text>
              </View>
              <IconSymbol name="chevron.right" size={16} color={colors.muted} />
            </Pressable>
          ) : (
            profiles.map((profile) => (
              <InlineCarCard
                key={profile.id}
                profile={profile}
                isActive={profile.id === activeId}
                onSetActive={() => handleSetActive(profile.id)}
                onEdit={() => { setEditProfile(profile); setModalVisible(true); }}
                onDelete={() => handleDeleteCar(profile)}
                colors={colors}
              />
            ))
          )}
        </Animated.View>

        {/* ── Appearance ── */}
        <Animated.View entering={FadeInDown.duration(300).delay(60)} style={styles.section}>
          <Text style={[styles.sectionTitle, { color: colors.foreground }]}>Appearance</Text>
          <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            <View style={styles.settingRow}>
              <Text style={[styles.settingName, { color: colors.foreground }]}>Theme</Text>
            </View>
            <View style={styles.themeToggleRow}>
              {(["light", "dark", "system"] as const).map((mode) => {
                const label = mode === "light" ? "Light" : mode === "dark" ? "Dark" : "System";
                const iconName = mode === "light" ? "sun.max.fill" : mode === "dark" ? "moon.fill" : "circle.lefthalf.filled";
                const isActive = colorScheme === mode;
                return (
                  <Pressable
                    key={mode}
                    onPress={() => {
                      if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                      setColorScheme(mode === "system" ? (colorScheme === "dark" ? "light" : "dark") : mode);
                    }}
                    style={({ pressed }) => [
                      styles.themeOption,
                      { backgroundColor: isActive ? colors.primary : colors.background, borderColor: isActive ? colors.primary : colors.border },
                      pressed && { opacity: 0.75 },
                    ]}
                  >
                    <IconSymbol name={iconName} size={18} color={isActive ? "#fff" : colors.muted} />
                    <Text style={[styles.themeOptionText, { color: isActive ? "#fff" : colors.foreground }]}>{label}</Text>
                  </Pressable>
                );
              })}
            </View>
          </View>
        </Animated.View>

        {/* ── Fuel Preferences ── */}
        <Animated.View entering={FadeInDown.duration(300).delay(100)} style={styles.section}>
          <Text style={[styles.sectionTitle, { color: colors.foreground }]}>Fuel Preferences</Text>
          <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>Default Tank Size</Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>Gallons — used when no car is active</Text>
              </View>
              <NumericField value={prefs.tankSize || 16} onSave={(n) => handleSavePreference("tankSize", n)} placeholder="16.5" colors={colors} />
            </View>
            <View style={[styles.divider, { backgroundColor: colors.border }]} />
            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>Preferred Octane</Text>
              </View>
              <View style={styles.octaneButtons}>
                {[87, 91, 93, 98].map((octane) => (
                  <Pressable
                    key={octane}
                    onPress={() => handleSavePreference("preferredOctane", octane)}
                    style={({ pressed }) => [
                      styles.octaneButton,
                      { backgroundColor: prefs.preferredOctane === octane ? colors.primary : colors.background, borderColor: prefs.preferredOctane === octane ? colors.primary : colors.border },
                      pressed && { opacity: 0.8 },
                    ]}
                  >
                    <Text style={[styles.octaneButtonText, { color: prefs.preferredOctane === octane ? "#fff" : colors.foreground }]}>{octane}</Text>
                  </Pressable>
                ))}
              </View>
            </View>
            <View style={[styles.divider, { backgroundColor: colors.border }]} />
            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>Default Blend</Text>
              </View>
              <NumericField value={prefs.defaultBlend} onSave={(n) => handleSavePreference("defaultBlend", n)} placeholder="30" colors={colors} />
            </View>
            <View style={[styles.divider, { backgroundColor: colors.border }]} />
            <View style={styles.settingRow}>
              <View style={styles.settingLabel}>
                <Text style={[styles.settingName, { color: colors.foreground }]}>Search Radius</Text>
                <Text style={[styles.settingDesc, { color: colors.muted }]}>Miles for station search</Text>
              </View>
              <NumericField value={prefs.searchRadius} onSave={(n) => handleSavePreference("searchRadius", n)} placeholder="25" colors={colors} />
            </View>
          </View>
        </Animated.View>

        {/* ── Data & Privacy ── */}
        <Animated.View entering={FadeInDown.duration(300).delay(140)} style={styles.section}>
          <Text style={[styles.sectionTitle, { color: colors.foreground }]}>Data & Privacy</Text>
          <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            <Pressable onPress={handleResetPreferences} style={({ pressed }) => [styles.actionButton, pressed && { opacity: 0.8 }]}>
              <View style={styles.actionButtonContent}>
                <View style={[styles.actionIconBg, { backgroundColor: colors.warning + "18" }]}>
                  <IconSymbol name="arrow.counterclockwise" size={18} color={colors.warning} />
                </View>
                <View style={styles.actionTextCol}>
                  <Text style={[styles.actionButtonText, { color: colors.foreground }]}>Reset Preferences</Text>
                  <Text style={[styles.actionButtonDesc, { color: colors.muted }]}>Restore default settings</Text>
                </View>
              </View>
              <IconSymbol name="chevron.right" size={18} color={colors.muted} />
            </Pressable>
            <View style={[styles.divider, { backgroundColor: colors.border }]} />
            <Pressable onPress={handleClearData} style={({ pressed }) => [styles.actionButton, pressed && { opacity: 0.8 }]}>
              <View style={styles.actionButtonContent}>
                <View style={[styles.actionIconBg, { backgroundColor: colors.error + "18" }]}>
                  <IconSymbol name="trash.fill" size={18} color={colors.error} />
                </View>
                <View style={styles.actionTextCol}>
                  <Text style={[styles.actionButtonText, { color: colors.foreground }]}>Clear All Data</Text>
                  <Text style={[styles.actionButtonDesc, { color: colors.muted }]}>Delete logs, favorites, garage, reviews</Text>
                </View>
              </View>
              <IconSymbol name="chevron.right" size={18} color={colors.muted} />
            </Pressable>
          </View>
        </Animated.View>

        {/* ── About ── */}
        <Animated.View entering={FadeInDown.duration(300).delay(180)} style={styles.section}>
          <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            <View style={styles.aboutContent}>
              <Text style={[styles.aboutTitle, { color: colors.foreground }]}>E85 Blend Calculator</Text>
              <Text style={[styles.aboutVersion, { color: colors.muted }]}>Version 2.1.0</Text>
              <Text style={[styles.aboutDesc, { color: colors.muted }]}>
                Calculate perfect E85 blends, find nearby stations, manage your garage, and track your fuel economy.
              </Text>
            </View>
          </View>
        </Animated.View>

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
});

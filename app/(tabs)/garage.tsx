import React, { useCallback, useEffect, useState } from "react";
import {
  View,
  Text,
  FlatList,
  Pressable,
  StyleSheet,
  Alert,
  Modal,
  ScrollView,
  TextInput,
  Switch,
  Platform,
} from "react-native";
import * as Haptics from "expo-haptics";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
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
} from "@/lib/garage";

// ─── Decimal sanitizer ───────────────────────────────────────────────────────
function sanitizeDecimal(text: string): string {
  let cleaned = text.replace(/,/g, ".").replace(/[^\d.]/g, "");
  const dot = cleaned.indexOf(".");
  if (dot !== -1) {
    cleaned = cleaned.slice(0, dot + 1) + cleaned.slice(dot + 1).replace(/\./g, "");
  }
  return cleaned;
}

// ─── Colour palette ──────────────────────────────────────────────────────────
const PALETTE = [
  "#10B981", "#3B82F6", "#F59E0B", "#EF4444",
  "#8B5CF6", "#EC4899", "#14B8A6", "#F97316",
];
const ICONS = ["🚗", "🏎️", "🚙", "🛻", "🚕", "⚡", "🔥", "💨"];

// ─── Field helper ─────────────────────────────────────────────────────────────
interface FieldProps {
  label: string;
  value: string;
  onChangeText: (t: string) => void;
  placeholder?: string;
  numeric?: boolean;
  onDecimal?: () => void;
  colors: ReturnType<typeof useColors>;
}
function Field({ label, value, onChangeText, placeholder, numeric, onDecimal, colors }: FieldProps) {
  return (
    <View style={ff.row}>
      <Text style={[ff.label, { color: colors.muted }]}>{label}</Text>
      <View style={ff.inputWrap}>
        <TextInput
          style={[ff.input, { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.background }]}
          value={value}
          onChangeText={onChangeText}
          placeholder={placeholder ?? label}
          placeholderTextColor={colors.muted}
          keyboardType={numeric ? "decimal-pad" : "default"}
          autoCapitalize="none"
          autoCorrect={false}
          returnKeyType="done"
        />
        {numeric && onDecimal && (
          <Pressable
            onPress={onDecimal}
            style={({ pressed }) => [ff.dot, { backgroundColor: colors.primary + "20", borderColor: colors.primary + "40", opacity: pressed ? 0.6 : 1 }]}
          >
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

// ─── Form state ───────────────────────────────────────────────────────────────
interface FormState {
  nickname: string;
  year: string;
  make: string;
  model: string;
  trim: string;
  tankSize: string;
  mpgE85: string;
  mpgGas: string;
  requiredOctane: string;
  isFlexFuel: boolean;
  defaultBlend: string;
  color: string;
  icon: string;
  odometer: string;
}

function profileToForm(p: CarProfile | NewCarProfile): FormState {
  return {
    nickname: p.nickname,
    year: p.year,
    make: p.make,
    model: p.model,
    trim: p.trim,
    tankSize: p.tankSize.toString(),
    mpgE85: p.mpgE85.toString(),
    mpgGas: p.mpgGas.toString(),
    requiredOctane: p.requiredOctane.toString(),
    isFlexFuel: p.isFlexFuel,
    defaultBlend: p.defaultBlend.toString(),
    color: p.color,
    icon: p.icon,
    odometer: p.odometer.toString(),
  };
}

function formToProfile(f: FormState): NewCarProfile {
  return {
    nickname: f.nickname.trim(),
    year: f.year.trim(),
    make: f.make.trim(),
    model: f.model.trim(),
    trim: f.trim.trim(),
    tankSize: parseFloat(f.tankSize) || 16,
    mpgE85: parseFloat(f.mpgE85) || 22,
    mpgGas: parseFloat(f.mpgGas) || 28,
    requiredOctane: parseInt(f.requiredOctane) || 87,
    isFlexFuel: f.isFlexFuel,
    defaultBlend: parseInt(f.defaultBlend) || 30,
    color: f.color,
    icon: f.icon,
    odometer: parseInt(f.odometer) || 0,
  };
}

// ─── Car Form Modal ───────────────────────────────────────────────────────────
interface CarFormModalProps {
  visible: boolean;
  editProfile: CarProfile | null;
  onClose: () => void;
  onSave: (data: NewCarProfile, id?: string) => Promise<void>;
  colors: ReturnType<typeof useColors>;
}

function CarFormModal({ visible, editProfile, onClose, onSave, colors }: CarFormModalProps) {
  const [form, setForm] = useState<FormState>(() => {
    const profile = editProfile ? editProfile : ({ ...DEFAULT_CAR, color: getRandomCarColor(), icon: getRandomCarIcon() } as NewCarProfile);
    return profileToForm(profile);
  });
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (visible) {
      const profile = editProfile ? editProfile : ({ ...DEFAULT_CAR, color: getRandomCarColor(), icon: getRandomCarIcon() } as NewCarProfile);
      setForm(profileToForm(profile));
    }
  }, [visible, editProfile]);

  const set = useCallback((key: keyof FormState, value: string | boolean) => {
    setForm((prev) => ({ ...prev, [key]: value }));
  }, []);

  const addDecimal = useCallback((key: keyof FormState) => {
    setForm((prev) => {
      const cur = prev[key] as string;
      if (!cur.includes(".")) {
        return { ...prev, [key]: cur === "" ? "0." : cur + "." };
      }
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
        {/* Header */}
        <View style={[mf.header, { borderBottomColor: colors.border }]}>
          <Pressable onPress={onClose} style={({ pressed }) => [mf.headerBtn, { opacity: pressed ? 0.6 : 1 }]}>
            <Text style={[mf.cancelText, { color: colors.primary }]}>Cancel</Text>
          </Pressable>
          <Text style={[mf.title, { color: colors.foreground }]}>
            {editProfile ? "Edit Car" : "Add Car"}
          </Text>
          <Pressable
            onPress={handleSave}
            disabled={saving}
            style={({ pressed }) => [mf.headerBtn, { opacity: pressed || saving ? 0.6 : 1 }]}
          >
            <Text style={[mf.saveText, { color: colors.primary }]}>
              {saving ? "Saving…" : "Save"}
            </Text>
          </Pressable>
        </View>

        <ScrollView
          style={mf.scroll}
          contentContainerStyle={mf.scrollContent}
          keyboardShouldPersistTaps="handled"
          showsVerticalScrollIndicator={false}
        >
          {/* Icon & Colour picker */}
          <View style={[mf.section, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            <Text style={[mf.sectionTitle, { color: colors.muted }]}>APPEARANCE</Text>
            {/* Icon row */}
            <Text style={[mf.subLabel, { color: colors.muted }]}>Icon</Text>
            <ScrollView horizontal showsHorizontalScrollIndicator={false} style={mf.iconRow}>
              {ICONS.map((ic) => (
                <Pressable
                  key={ic}
                  onPress={() => set("icon", ic)}
                  style={[
                    mf.iconChip,
                    {
                      backgroundColor: form.icon === ic ? form.color + "30" : colors.background,
                      borderColor: form.icon === ic ? form.color : colors.border,
                    },
                  ]}
                >
                  <Text style={mf.iconEmoji}>{ic}</Text>
                </Pressable>
              ))}
            </ScrollView>
            {/* Colour row */}
            <Text style={[mf.subLabel, { color: colors.muted, marginTop: 12 }]}>Accent Color</Text>
            <View style={mf.colorRow}>
              {PALETTE.map((c) => (
                <Pressable
                  key={c}
                  onPress={() => set("color", c)}
                  style={[mf.colorDot, { backgroundColor: c, borderWidth: form.color === c ? 3 : 0, borderColor: colors.foreground }]}
                />
              ))}
            </View>
          </View>

          {/* Identity */}
          <View style={[mf.section, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            <Text style={[mf.sectionTitle, { color: colors.muted }]}>VEHICLE INFO</Text>
            <Field label="Nickname" value={form.nickname} onChangeText={(t) => set("nickname", t)} placeholder="e.g. Daily Driver" colors={colors} />
            <Field label="Year" value={form.year} onChangeText={(t) => set("year", t)} placeholder="2024" colors={colors} />
            <Field label="Make" value={form.make} onChangeText={(t) => set("make", t)} placeholder="e.g. Ford" colors={colors} />
            <Field label="Model" value={form.model} onChangeText={(t) => set("model", t)} placeholder="e.g. Mustang" colors={colors} />
            <Field label="Trim" value={form.trim} onChangeText={(t) => set("trim", t)} placeholder="e.g. GT500" colors={colors} />
          </View>

          {/* Fuel & Performance */}
          <View style={[mf.section, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            <Text style={[mf.sectionTitle, { color: colors.muted }]}>FUEL & PERFORMANCE</Text>
            <Field
              label="Tank Size (gal)"
              value={form.tankSize}
              onChangeText={(t) => set("tankSize", sanitizeDecimal(t))}
              placeholder="16.0"
              numeric
              onDecimal={() => addDecimal("tankSize")}
              colors={colors}
            />
            <Field
              label="MPG on E85"
              value={form.mpgE85}
              onChangeText={(t) => set("mpgE85", sanitizeDecimal(t))}
              placeholder="22.0"
              numeric
              onDecimal={() => addDecimal("mpgE85")}
              colors={colors}
            />
            <Field
              label="MPG on Gas"
              value={form.mpgGas}
              onChangeText={(t) => set("mpgGas", sanitizeDecimal(t))}
              placeholder="28.0"
              numeric
              onDecimal={() => addDecimal("mpgGas")}
              colors={colors}
            />
            <Field
              label="Required Octane"
              value={form.requiredOctane}
              onChangeText={(t) => set("requiredOctane", t.replace(/[^\d]/g, ""))}
              placeholder="87"
              numeric
              colors={colors}
            />
            <Field
              label="Default Blend %"
              value={form.defaultBlend}
              onChangeText={(t) => set("defaultBlend", t.replace(/[^\d]/g, ""))}
              placeholder="30"
              numeric
              colors={colors}
            />
            <Field
              label="Current Odometer (miles)"
              value={form.odometer}
              onChangeText={(t) => set("odometer", t.replace(/[^\d]/g, ""))}
              placeholder="0"
              numeric
              colors={colors}
            />
            {/* Flex-fuel toggle */}
            <View style={mf.toggleRow}>
              <View style={mf.toggleLabel}>
                <Text style={[mf.toggleTitle, { color: colors.foreground }]}>Flex-Fuel Vehicle</Text>
                <Text style={[mf.toggleSub, { color: colors.muted }]}>Certified to run E85 blends</Text>
              </View>
              <Switch
                value={form.isFlexFuel}
                onValueChange={(v) => set("isFlexFuel", v)}
                trackColor={{ false: colors.border, true: colors.primary }}
                thumbColor="#fff"
              />
            </View>
          </View>
        </ScrollView>
      </View>
    </Modal>
  );
}

const mf = StyleSheet.create({
  container: { flex: 1 },
  header: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 20,
    paddingTop: Platform.OS === "ios" ? 16 : 12,
    paddingBottom: 14,
    borderBottomWidth: 1,
  },
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

// ─── Car Card ─────────────────────────────────────────────────────────────────
interface CarCardProps {
  profile: CarProfile;
  isActive: boolean;
  onSetActive: () => void;
  onEdit: () => void;
  onDelete: () => void;
  colors: ReturnType<typeof useColors>;
}

function CarCard({ profile, isActive, onSetActive, onEdit, onDelete, colors }: CarCardProps) {
  const [expanded, setExpanded] = useState(false);

  return (
    <View
      style={[
        card.container,
        {
          backgroundColor: colors.surface,
          borderColor: isActive ? profile.color : colors.border,
          borderWidth: isActive ? 2 : 1,
        },
      ]}
    >
      {/* Top row */}
      <Pressable
        onPress={() => setExpanded((e) => !e)}
        style={({ pressed }) => [card.topRow, { opacity: pressed ? 0.85 : 1 }]}
      >
        {/* Icon + accent */}
        <View style={[card.iconWrap, { backgroundColor: profile.color + "20" }]}>
          <Text style={card.iconEmoji}>{profile.icon}</Text>
        </View>

        {/* Name + details */}
        <View style={card.info}>
          <View style={card.nameRow}>
            <Text style={[card.name, { color: colors.foreground }]} numberOfLines={1}>
              {profile.nickname || `${profile.year} ${profile.make} ${profile.model}`}
            </Text>
            {isActive && (
              <View style={[card.activeBadge, { backgroundColor: profile.color }]}>
                <Text style={card.activeBadgeText}>ACTIVE</Text>
              </View>
            )}
          </View>
          <Text style={[card.sub, { color: colors.muted }]} numberOfLines={1}>
            {[profile.year, profile.make, profile.model, profile.trim].filter(Boolean).join(" ")}
          </Text>
          <Text style={[card.meta, { color: colors.muted }]}>
            {profile.tankSize} gal · {profile.isFlexFuel ? "Flex-Fuel" : `${profile.requiredOctane} oct`}
          </Text>
        </View>

        <IconSymbol
          name={expanded ? "chevron.up" : "chevron.down"}
          size={18}
          color={colors.muted}
        />
      </Pressable>

      {/* Expanded stats */}
      {expanded && (
        <View style={[card.stats, { borderTopColor: colors.border }]}>
          <View style={card.statRow}>
            <View style={card.stat}>
              <Text style={[card.statVal, { color: profile.color }]}>{profile.mpgGas}</Text>
              <Text style={[card.statLabel, { color: colors.muted }]}>MPG Gas</Text>
            </View>
            <View style={[card.statDivider, { backgroundColor: colors.border }]} />
            <View style={card.stat}>
              <Text style={[card.statVal, { color: profile.color }]}>{profile.mpgE85}</Text>
              <Text style={[card.statLabel, { color: colors.muted }]}>MPG E85</Text>
            </View>
            <View style={[card.statDivider, { backgroundColor: colors.border }]} />
            <View style={card.stat}>
              <Text style={[card.statVal, { color: profile.color }]}>E{profile.defaultBlend}</Text>
              <Text style={[card.statLabel, { color: colors.muted }]}>Default</Text>
            </View>
          </View>

          {/* Action buttons */}
          <View style={card.actions}>
            {!isActive && (
              <Pressable
                onPress={onSetActive}
                style={({ pressed }) => [
                  card.actionBtn,
                  { backgroundColor: profile.color, opacity: pressed ? 0.8 : 1 },
                ]}
              >
                <IconSymbol name="checkmark.circle.fill" size={16} color="#fff" />
                <Text style={card.actionBtnText}>Set Active</Text>
              </Pressable>
            )}
            <Pressable
              onPress={onEdit}
              style={({ pressed }) => [
                card.actionBtn,
                { backgroundColor: colors.primary + "20", borderColor: colors.primary + "40", borderWidth: 1, opacity: pressed ? 0.8 : 1 },
              ]}
            >
              <IconSymbol name="pencil" size={16} color={colors.primary} />
              <Text style={[card.actionBtnText, { color: colors.primary }]}>Edit</Text>
            </Pressable>
            <Pressable
              onPress={onDelete}
              style={({ pressed }) => [
                card.actionBtn,
                { backgroundColor: "#EF444420", borderColor: "#EF444440", borderWidth: 1, opacity: pressed ? 0.8 : 1 },
              ]}
            >
              <IconSymbol name="trash.fill" size={16} color="#EF4444" />
              <Text style={[card.actionBtnText, { color: "#EF4444" }]}>Delete</Text>
            </Pressable>
          </View>
        </View>
      )}
    </View>
  );
}

const card = StyleSheet.create({
  container: { borderRadius: 16, overflow: "hidden", marginBottom: 12 },
  topRow: { flexDirection: "row", alignItems: "center", padding: 16, gap: 12 },
  iconWrap: { width: 52, height: 52, borderRadius: 14, justifyContent: "center", alignItems: "center" },
  iconEmoji: { fontSize: 28 },
  info: { flex: 1 },
  nameRow: { flexDirection: "row", alignItems: "center", gap: 8, flexWrap: "wrap" },
  name: { fontSize: 16, fontWeight: "700", flexShrink: 1 },
  activeBadge: { paddingHorizontal: 7, paddingVertical: 2, borderRadius: 6 },
  activeBadgeText: { fontSize: 10, fontWeight: "800", color: "#fff", letterSpacing: 0.5 },
  sub: { fontSize: 13, marginTop: 2 },
  meta: { fontSize: 12, marginTop: 2 },
  stats: { borderTopWidth: 1, paddingHorizontal: 16, paddingVertical: 14 },
  statRow: { flexDirection: "row", justifyContent: "space-around", marginBottom: 14 },
  stat: { alignItems: "center", flex: 1 },
  statVal: { fontSize: 20, fontWeight: "700" },
  statLabel: { fontSize: 11, marginTop: 2 },
  statDivider: { width: 1, height: 36, alignSelf: "center" },
  actions: { flexDirection: "row", gap: 8 },
  actionBtn: { flex: 1, flexDirection: "row", alignItems: "center", justifyContent: "center", gap: 6, height: 38, borderRadius: 10 },
  actionBtnText: { fontSize: 13, fontWeight: "600", color: "#fff" },
});

// ─── Empty State ──────────────────────────────────────────────────────────────
function EmptyGarage({ onAdd, colors }: { onAdd: () => void; colors: ReturnType<typeof useColors> }) {
  return (
    <View style={empty.container}>
      <Text style={empty.emoji}>🚗</Text>
      <Text style={[empty.title, { color: colors.foreground }]}>Your Garage is Empty</Text>
      <Text style={[empty.sub, { color: colors.muted }]}>
        Add your car to auto-fill tank size in the calculator and track fuel economy per vehicle.
      </Text>
      <Pressable
        onPress={onAdd}
        style={({ pressed }) => [empty.btn, { backgroundColor: colors.primary, opacity: pressed ? 0.8 : 1 }]}
      >
        <IconSymbol name="plus" size={18} color="#fff" />
        <Text style={empty.btnText}>Add Your First Car</Text>
      </Pressable>
    </View>
  );
}

const empty = StyleSheet.create({
  container: { flex: 1, justifyContent: "center", alignItems: "center", padding: 32 },
  emoji: { fontSize: 64, marginBottom: 16 },
  title: { fontSize: 22, fontWeight: "700", textAlign: "center", marginBottom: 8 },
  sub: { fontSize: 15, textAlign: "center", lineHeight: 22, marginBottom: 28 },
  btn: { flexDirection: "row", alignItems: "center", gap: 8, paddingHorizontal: 24, paddingVertical: 14, borderRadius: 14 },
  btnText: { fontSize: 16, fontWeight: "700", color: "#fff" },
});

// ─── Main Screen ──────────────────────────────────────────────────────────────
export default function GarageScreen() {
  const colors = useColors();
  const [profiles, setProfiles] = useState<CarProfile[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [modalVisible, setModalVisible] = useState(false);
  const [editProfile, setEditProfile] = useState<CarProfile | null>(null);

  const refresh = useCallback(async () => {
    const [cars, aid] = await Promise.all([loadGarage(), getActiveCarId()]);
    setProfiles(cars);
    setActiveId(aid);
    setLoading(false);
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const handleAdd = useCallback(() => {
    setEditProfile(null);
    setModalVisible(true);
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  }, []);

  const handleEdit = useCallback((profile: CarProfile) => {
    setEditProfile(profile);
    setModalVisible(true);
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  }, []);

  const handleSave = useCallback(async (data: NewCarProfile, id?: string) => {
    if (id) {
      await updateCarProfile(id, data);
    } else {
      await addCarProfile(data);
    }
    await refresh();
    if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
  }, [refresh]);

  const handleSetActive = useCallback(async (id: string) => {
    await setActiveCarId(id);
    setActiveId(id);
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
  }, []);

  const handleDelete = useCallback((profile: CarProfile) => {
    Alert.alert(
      "Delete Car",
      `Remove "${profile.nickname || `${profile.make} ${profile.model}`}" from your garage?`,
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Delete",
          style: "destructive",
          onPress: async () => {
            await deleteCarProfile(profile.id);
            await refresh();
            if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
          },
        },
      ]
    );
  }, [refresh]);

  return (
    <ScreenContainer>
      {/* Header */}
      <View style={[s.header, { borderBottomColor: colors.border }]}>
        <View>
          <Text style={[s.headerTitle, { color: colors.foreground }]}>My Garage</Text>
          <Text style={[s.headerSub, { color: colors.muted }]}>
            {profiles.length === 0
              ? "No cars yet"
              : `${profiles.length} car${profiles.length !== 1 ? "s" : ""} · tap a card to expand`}
          </Text>
        </View>
        <Pressable
          onPress={handleAdd}
          style={({ pressed }) => [s.addBtn, { backgroundColor: colors.primary, opacity: pressed ? 0.8 : 1 }]}
        >
          <IconSymbol name="plus" size={20} color="#fff" />
          <Text style={s.addBtnText}>Add Car</Text>
        </Pressable>
      </View>

      {loading ? (
        <View style={s.center}>
          <Text style={[s.loadingText, { color: colors.muted }]}>Loading garage…</Text>
        </View>
      ) : profiles.length === 0 ? (
        <EmptyGarage onAdd={handleAdd} colors={colors} />
      ) : (
        <FlatList
          data={profiles}
          keyExtractor={(item) => item.id}
          contentContainerStyle={s.list}
          showsVerticalScrollIndicator={false}
          renderItem={({ item }) => (
            <CarCard
              profile={item}
              isActive={item.id === activeId}
              onSetActive={() => handleSetActive(item.id)}
              onEdit={() => handleEdit(item)}
              onDelete={() => handleDelete(item)}
              colors={colors}
            />
          )}
        />
      )}

      <CarFormModal
        visible={modalVisible}
        editProfile={editProfile}
        onClose={() => setModalVisible(false)}
        onSave={handleSave}
        colors={colors}
      />
    </ScreenContainer>
  );
}

const s = StyleSheet.create({
  header: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 20,
    paddingTop: 16,
    paddingBottom: 14,
    borderBottomWidth: 1,
  },
  headerTitle: { fontSize: 28, fontWeight: "800" },
  headerSub: { fontSize: 13, marginTop: 2 },
  addBtn: { flexDirection: "row", alignItems: "center", gap: 6, paddingHorizontal: 16, paddingVertical: 10, borderRadius: 12 },
  addBtnText: { fontSize: 14, fontWeight: "700", color: "#fff" },
  list: { padding: 16, paddingBottom: 32 },
  center: { flex: 1, justifyContent: "center", alignItems: "center" },
  loadingText: { fontSize: 15 },
});

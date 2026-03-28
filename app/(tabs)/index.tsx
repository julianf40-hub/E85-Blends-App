import { useCallback, useEffect, useState } from "react";
import {
  ScrollView,
  Text,
  View,
  Pressable,
  Platform,
  StyleSheet,
  FlatList,
} from "react-native";
import Animated, {
  FadeIn,
  FadeInDown,
  FadeInRight,
} from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import { LinearGradient } from "expo-linear-gradient";
import { useRouter, useFocusEffect } from "expo-router";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import { getActiveCar, CarProfile } from "@/lib/garage";
import { loadFuelLog, FuelEntry } from "@/lib/fuel-log";
import {
  loadRemindersForCar,
  Reminder,
  getReminderUrgency,
  sortRemindersByUrgency,
  REMINDER_CATEGORIES,
  ReminderCategory,
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
  if (milesLeft !== undefined) parts.push(`${milesLeft.toLocaleString()} mi`);
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
}

function CarHero({ car, currentMileage, onPress }: CarHeroProps) {
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
            <View style={styles.heroStat}>
              <Text style={styles.heroStatValue}>
                {currentMileage > 0 ? currentMileage.toLocaleString() : "—"}
              </Text>
              <Text style={styles.heroStatLabel}>last odometer</Text>
            </View>
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

  const loadData = useCallback(async () => {
    try {
      const car = await getActiveCar();
      setActiveCar(car);

      const logs = await loadFuelLog();
      const recent = logs.slice(0, 5);
      setRecentFillUps(recent);
      const latestMileage = logs.length > 0 ? logs[0].odometer : 0;
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
    router.push("/(tabs)/garage");
  }, [router]);

  return (
    <ScreenContainer>
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        {/* ── Header ── */}
        <View style={styles.header}>
          <View>
            <Text style={[styles.headerTitle, { color: colors.foreground }]}>Dashboard</Text>
            <Text style={[styles.headerSubtitle, { color: colors.muted }]}>
              {new Date().toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" })}
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
          <CarHero car={activeCar} currentMileage={currentMileage} onPress={handleCarPress} />
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
            style={[styles.quickActionBtn, { backgroundColor: colors.primary }]}
            onPress={() => router.push("/(tabs)")}
          >
            <IconSymbol name="fuelpump.fill" size={20} color="#fff" />
            <Text style={styles.quickActionText}>Calculate</Text>
          </Pressable>
          <Pressable
            style={[styles.quickActionBtn, { backgroundColor: colors.surface, borderColor: colors.border, borderWidth: 1 }]}
            onPress={() => router.push("/(tabs)/stations")}
          >
            <IconSymbol name="map.fill" size={20} color={colors.foreground} />
            <Text style={[styles.quickActionText, { color: colors.foreground }]}>Stations</Text>
          </Pressable>
          <Pressable
            style={[styles.quickActionBtn, { backgroundColor: colors.surface, borderColor: colors.border, borderWidth: 1 }]}
            onPress={() => router.push("/(tabs)/fuel-log")}
          >
            <IconSymbol name="list.bullet.clipboard.fill" size={20} color={colors.foreground} />
            <Text style={[styles.quickActionText, { color: colors.foreground }]}>Fuel Log</Text>
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

        {/* ── Recent Fill-ups ── */}
        <Animated.View entering={FadeInDown.duration(300).delay(160)}>
          <View style={styles.sectionHeader}>
            <Text style={[styles.sectionTitle, { color: colors.foreground }]}>Recent Fill-ups</Text>
            <Pressable onPress={() => router.push("/(tabs)/fuel-log")} style={styles.sectionAction}>
              <Text style={[styles.sectionActionText, { color: colors.primary }]}>See all</Text>
              <IconSymbol name="chevron.right" size={14} color={colors.primary} />
            </Pressable>
          </View>

          {recentFillUps.length === 0 ? (
            <Pressable
              style={[styles.emptyFillUpsCard, { backgroundColor: colors.surface, borderColor: colors.border }]}
              onPress={() => router.push("/(tabs)/fuel-log")}
            >
              <Text style={styles.emptyFillUpsEmoji}>⛽</Text>
              <Text style={[styles.emptyFillUpsText, { color: colors.muted }]}>
                No fill-ups logged yet — tap to add your first
              </Text>
            </Pressable>
          ) : (
            <View style={[styles.fillUpsCard, { backgroundColor: colors.surface }]}>
              {recentFillUps.map((entry, i) => (
                <FillUpRow key={entry.id} entry={entry} isLast={i === recentFillUps.length - 1} />
              ))}
            </View>
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
});

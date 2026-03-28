import React, { useState, useEffect, useCallback } from "react";
import {
  Text,
  View,
  FlatList,
  Pressable,
  StyleSheet,
  Modal,
  TextInput,
  ScrollView,
  Alert,
  Platform,
} from "react-native";
import Animated, { FadeInDown, FadeIn } from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import { LinearGradient } from "expo-linear-gradient";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import {
  loadFuelLog,
  addFuelEntry,
  deleteFuelEntry,
  FuelEntry,
  getFuelLogStats,
} from "@/lib/fuel-log";
import { getActiveCar } from "@/lib/garage";
import { loadRemindersForCar } from "@/lib/reminders";

export default function FuelLogScreen() {
  const colors = useColors();
  const [entries, setEntries] = useState<FuelEntry[]>([]);
  const [stats, setStats] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [showModal, setShowModal] = useState(false);
  const [formData, setFormData] = useState({
    stationName: "",
    blendRatio: "30",
    gallonsAdded: "",
    pricePerGallon: "",
    odometer: "",
    notes: "",
  });

  useEffect(() => {
    loadData();
  }, []);

  const loadData = useCallback(async () => {
    try {
      const logs = await loadFuelLog();
      const stats = await getFuelLogStats();
      setEntries(logs);
      setStats(stats);
    } catch (error) {
      console.error("Failed to load fuel log:", error);
    } finally {
      setLoading(false);
    }
  }, []);

  const handleAddEntry = useCallback(async () => {
    if (
      !formData.stationName ||
      !formData.gallonsAdded ||
      !formData.pricePerGallon ||
      !formData.odometer
    ) {
      Alert.alert("Missing Fields", "Please fill in all required fields.");
      return;
    }

    try {
      const newEntry = await addFuelEntry({
        date: new Date().toISOString(),
        stationName: formData.stationName,
        blendRatio: parseFloat(formData.blendRatio),
        gallonsAdded: parseFloat(formData.gallonsAdded),
        pricePerGallon: parseFloat(formData.pricePerGallon),
        totalPrice:
          parseFloat(formData.gallonsAdded) *
          parseFloat(formData.pricePerGallon),
        odometer: parseFloat(formData.odometer),
        notes: formData.notes || undefined,
      });

      if (Platform.OS !== "web") {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      }

      // Auto-check reminders after fuel entry is added
      try {
        const car = await getActiveCar();
        if (car) {
          const rems = await loadRemindersForCar(car.id);
          // Reminders will automatically show as due/overdue in the UI based on the new odometer
          // No need to update reminder status here; the UI will recalculate based on getReminderUrgency
        }
      } catch (e) {
        console.warn("Failed to check reminders after fuel entry:", e);
      }

      setFormData({
        stationName: "",
        blendRatio: "30",
        gallonsAdded: "",
        pricePerGallon: "",
        odometer: "",
        notes: "",
      });
      setShowModal(false);
      await loadData();
    } catch (error) {
      Alert.alert("Error", "Failed to add fuel entry.");
    }
  }, [formData, loadData]);

  const handleDeleteEntry = useCallback(
    (id: string) => {
      Alert.alert("Delete Entry?", "This cannot be undone.", [
        { text: "Cancel" },
        {
          text: "Delete",
          onPress: async () => {
            await deleteFuelEntry(id);
            await loadData();
            if (Platform.OS !== "web") {
              Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
            }
          },
          style: "destructive",
        },
      ]);
    },
    [loadData]
  );

  const renderEntryCard = useCallback(
    ({ item, index }: { item: FuelEntry; index: number }) => (
      <Animated.View entering={FadeInDown.duration(250).delay(Math.min(index * 40, 400))}>
        <Pressable
          onLongPress={() => handleDeleteEntry(item.id)}
          style={({ pressed }) => [
            styles.entryCard,
            {
              backgroundColor: colors.surface,
              borderColor: colors.border,
            },
            pressed && { opacity: 0.8 },
          ]}
        >
          <View style={styles.entryHeader}>
            <View style={styles.entryInfo}>
              <View
                style={[
                  styles.entryIconBg,
                  { backgroundColor: colors.primary + "18" },
                ]}
              >
                <IconSymbol
                  name="fuelpump.fill"
                  size={18}
                  color={colors.primary}
                />
              </View>
              <View style={styles.entryTextCol}>
                <Text
                  style={[styles.entryStation, { color: colors.foreground }]}
                  numberOfLines={1}
                >
                  {item.stationName}
                </Text>
                <Text style={[styles.entryDate, { color: colors.muted }]}>
                  {new Date(item.date).toLocaleDateString()} •{" "}
                  {new Date(item.date).toLocaleTimeString([], {
                    hour: "2-digit",
                    minute: "2-digit",
                  })}
                </Text>
              </View>
            </View>
            <View
              style={[
                styles.blendBadge,
                { backgroundColor: colors.primary + "18" },
              ]}
            >
              <Text
                style={[styles.blendBadgeText, { color: colors.primary }]}
              >
                E{item.blendRatio}
              </Text>
            </View>
          </View>

          <View style={styles.entryStats}>
            <View style={styles.statItem}>
              <Text style={[styles.statLabel, { color: colors.muted }]}>
                Gallons
              </Text>
              <Text style={[styles.statValue, { color: colors.foreground }]}>
                {item.gallonsAdded.toFixed(2)}
              </Text>
            </View>
            <View style={styles.statDivider} />
            <View style={styles.statItem}>
              <Text style={[styles.statLabel, { color: colors.muted }]}>
                Price
              </Text>
              <Text style={[styles.statValue, { color: colors.foreground }]}>
                ${item.totalPrice.toFixed(2)}
              </Text>
            </View>
            <View style={styles.statDivider} />
            <View style={styles.statItem}>
              <Text style={[styles.statLabel, { color: colors.muted }]}>
                $/gal
              </Text>
              <Text style={[styles.statValue, { color: colors.foreground }]}>
                ${item.pricePerGallon.toFixed(2)}
              </Text>
            </View>
            {item.mpg && (
              <>
                <View style={styles.statDivider} />
                <View style={styles.statItem}>
                  <Text style={[styles.statLabel, { color: colors.muted }]}>
                    MPG
                  </Text>
                  <Text style={[styles.statValue, { color: colors.foreground }]}>
                    {item.mpg.toFixed(1)}
                  </Text>
                </View>
              </>
            )}
          </View>

          {item.notes && (
            <Text style={[styles.entryNotes, { color: colors.muted }]}>
              {item.notes}
            </Text>
          )}
        </Pressable>
      </Animated.View>
    ),
    [colors, handleDeleteEntry]
  );

  return (
    <ScreenContainer>
      {/* Header */}
      <Animated.View entering={FadeInDown.duration(300)} style={styles.header}>
        <View
          style={[
            styles.headerIconBg,
            { backgroundColor: colors.primary + "18" },
          ]}
        >
          <IconSymbol name="list.bullet.clipboard.fill" size={24} color={colors.primary} />
        </View>
        <View style={styles.headerTextCol}>
          <Text style={[styles.headerTitle, { color: colors.foreground }]}>
            Fuel Log
          </Text>
          <Text style={[styles.headerSubtitle, { color: colors.muted }]}>
            Track every fill-up
          </Text>
        </View>
      </Animated.View>

      {/* Stats Cards */}
      {stats && (
        <Animated.View
          entering={FadeInDown.duration(300).delay(80)}
          style={styles.statsContainer}
        >
          <View style={styles.statsRow}>
            <View
              style={[
                styles.statCard,
                { backgroundColor: colors.surface, borderColor: colors.border },
              ]}
            >
              <Text style={[styles.statCardLabel, { color: colors.muted }]}>
                Total Entries
              </Text>
              <Text style={[styles.statCardValue, { color: colors.primary }]}>
                {stats.totalEntries}
              </Text>
            </View>
            <View
              style={[
                styles.statCard,
                { backgroundColor: colors.surface, borderColor: colors.border },
              ]}
            >
              <Text style={[styles.statCardLabel, { color: colors.muted }]}>
                Avg MPG
              </Text>
              <Text style={[styles.statCardValue, { color: colors.primary }]}>
                {stats.averageMPG.toFixed(1)}
              </Text>
            </View>
            <View
              style={[
                styles.statCard,
                { backgroundColor: colors.surface, borderColor: colors.border },
              ]}
            >
              <Text style={[styles.statCardLabel, { color: colors.muted }]}>
                Total Spent
              </Text>
              <Text style={[styles.statCardValue, { color: colors.primary }]}>
                ${stats.totalSpent.toFixed(0)}
              </Text>
            </View>
          </View>
        </Animated.View>
      )}

      {/* Add Entry Button */}
      <Animated.View
        entering={FadeInDown.duration(300).delay(160)}
        style={styles.addButtonContainer}
      >
        <Pressable
          onPress={() => setShowModal(true)}
          style={({ pressed }) => [
            styles.addButton,
            pressed && { transform: [{ scale: 0.97 }] },
          ]}
        >
          <LinearGradient
            colors={[colors.primary, "#15803D"]}
            start={{ x: 0, y: 0 }}
            end={{ x: 1, y: 1 }}
            style={styles.addButtonGradient}
          >
            <IconSymbol name="plus.circle.fill" size={20} color="#FFFFFF" />
            <Text style={styles.addButtonText}>Add Fuel Entry</Text>
          </LinearGradient>
        </Pressable>
      </Animated.View>

      {/* Fuel Log List */}
      {loading ? (
        <Text style={[styles.loadingText, { color: colors.muted }]}>
          Loading fuel log...
        </Text>
      ) : entries.length === 0 ? (
        <View style={styles.emptyState}>
          <View
            style={[
              styles.emptyIconBg,
              { backgroundColor: colors.primary + "15" },
            ]}
          >
            <IconSymbol
              name="fuelpump.fill"
              size={40}
              color={colors.primary}
            />
          </View>
          <Text style={[styles.emptyTitle, { color: colors.foreground }]}>
            No Fuel Entries
          </Text>
          <Text style={[styles.emptySubtitle, { color: colors.muted }]}>
            Start tracking your fuel-ups to see analytics and MPG trends
          </Text>
        </View>
      ) : (
        <FlatList
          data={entries}
          renderItem={renderEntryCard}
          keyExtractor={(item) => item.id}
          contentContainerStyle={styles.listContent}
          showsVerticalScrollIndicator={false}
          ItemSeparatorComponent={() => <View style={styles.separator} />}
        />
      )}

      {/* Add Entry Modal */}
      <Modal
        visible={showModal}
        animationType="slide"
        transparent
        onRequestClose={() => setShowModal(false)}
      >
        <View
          style={[
            styles.modalOverlay,
            { backgroundColor: colors.background + "CC" },
          ]}
        >
          <View
            style={[
              styles.modalContent,
              { backgroundColor: colors.background },
            ]}
          >
            <View style={styles.modalHeader}>
              <Text style={[styles.modalTitle, { color: colors.foreground }]}>
                Add Fuel Entry
              </Text>
              <Pressable onPress={() => setShowModal(false)}>
                <IconSymbol
                  name="xmark.circle.fill"
                  size={28}
                  color={colors.muted}
                />
              </Pressable>
            </View>

            <ScrollView
              contentContainerStyle={styles.modalForm}
              showsVerticalScrollIndicator={false}
            >
              <View style={styles.formGroup}>
                <Text style={[styles.formLabel, { color: colors.foreground }]}>
                  Station Name *
                </Text>
                <TextInput
                  style={[
                    styles.formInput,
                    {
                      color: colors.foreground,
                      borderColor: colors.border,
                      backgroundColor: colors.surface,
                    },
                  ]}
                  placeholder="e.g., Shell, Chevron"
                  placeholderTextColor={colors.muted}
                  value={formData.stationName}
                  onChangeText={(value) =>
                    setFormData({ ...formData, stationName: value })
                  }
                />
              </View>

              <View style={styles.formGroup}>
                <Text style={[styles.formLabel, { color: colors.foreground }]}>
                  Blend Ratio *
                </Text>
                <TextInput
                  style={[
                    styles.formInput,
                    {
                      color: colors.foreground,
                      borderColor: colors.border,
                      backgroundColor: colors.surface,
                    },
                  ]}
                  placeholder="30"
                  placeholderTextColor={colors.muted}
                  keyboardType="default"
                  autoCapitalize="none"
                  autoCorrect={false}
                  value={formData.blendRatio}
                  onChangeText={(value) =>
                    setFormData({ ...formData, blendRatio: value.replace(/[^\d.]/g, "") })
                  }
                />
                <Pressable
                  onPress={() => {
                    const cur = formData.blendRatio;
                    if (!cur.includes(".")) {
                      setFormData({ ...formData, blendRatio: cur === "" ? "0." : cur + "." });
                    }
                  }}
                  style={({ pressed }) => [
                    styles.fuelLogDecimalBtn,
                    { backgroundColor: colors.primary + "20" },
                    pressed && { opacity: 0.6 },
                  ]}
                >
                  <Text style={[styles.fuelLogDecimalBtnText, { color: colors.primary }]}>.</Text>
                </Pressable>
              </View>

              <View style={styles.formGroup}>
                <Text style={[styles.formLabel, { color: colors.foreground }]}>
                  Gallons Added *
                </Text>
                <TextInput
                  style={[
                    styles.formInput,
                    {
                      color: colors.foreground,
                      borderColor: colors.border,
                      backgroundColor: colors.surface,
                    },
                  ]}
                  placeholder="12.5"
                  placeholderTextColor={colors.muted}
                  keyboardType="default"
                  autoCapitalize="none"
                  autoCorrect={false}
                  value={formData.gallonsAdded}
                  onChangeText={(value) =>
                    setFormData({ ...formData, gallonsAdded: value.replace(/[^\d.]/g, "") })
                  }
                />
                <Pressable
                  onPress={() => {
                    const cur = formData.gallonsAdded;
                    if (!cur.includes(".")) {
                      setFormData({ ...formData, gallonsAdded: cur === "" ? "0." : cur + "." });
                    }
                  }}
                  style={({ pressed }) => [
                    styles.fuelLogDecimalBtn,
                    { backgroundColor: colors.primary + "20" },
                    pressed && { opacity: 0.6 },
                  ]}
                >
                  <Text style={[styles.fuelLogDecimalBtnText, { color: colors.primary }]}>.</Text>
                </Pressable>
              </View>

              <View style={styles.formGroup}>
                <Text style={[styles.formLabel, { color: colors.foreground }]}>
                  Price Per Gallon *
                </Text>
                <TextInput
                  style={[
                    styles.formInput,
                    {
                      color: colors.foreground,
                      borderColor: colors.border,
                      backgroundColor: colors.surface,
                    },
                  ]}
                  placeholder="3.49"
                  placeholderTextColor={colors.muted}
                  keyboardType="default"
                  autoCapitalize="none"
                  autoCorrect={false}
                  value={formData.pricePerGallon}
                  onChangeText={(value) =>
                    setFormData({ ...formData, pricePerGallon: value.replace(/[^\d.]/g, "") })
                  }
                />
                <Pressable
                  onPress={() => {
                    const cur = formData.pricePerGallon;
                    if (!cur.includes(".")) {
                      setFormData({ ...formData, pricePerGallon: cur === "" ? "0." : cur + "." });
                    }
                  }}
                  style={({ pressed }) => [
                    styles.fuelLogDecimalBtn,
                    { backgroundColor: colors.primary + "20" },
                    pressed && { opacity: 0.6 },
                  ]}
                >
                  <Text style={[styles.fuelLogDecimalBtnText, { color: colors.primary }]}>.</Text>
                </Pressable>
              </View>

              <View style={styles.formGroup}>
                <Text style={[styles.formLabel, { color: colors.foreground }]}>
                  Odometer Reading *
                </Text>
                <TextInput
                  style={[
                    styles.formInput,
                    {
                      color: colors.foreground,
                      borderColor: colors.border,
                      backgroundColor: colors.surface,
                    },
                  ]}
                  placeholder="45230"
                  placeholderTextColor={colors.muted}
                  keyboardType="default"
                  autoCapitalize="none"
                  autoCorrect={false}
                  value={formData.odometer}
                  onChangeText={(value) =>
                    setFormData({ ...formData, odometer: value.replace(/[^\d.]/g, "") })
                  }
                />
              </View>

              <View style={styles.formGroup}>
                <Text style={[styles.formLabel, { color: colors.foreground }]}>
                  Notes
                </Text>
                <TextInput
                  style={[
                    styles.formInputMulti,
                    {
                      color: colors.foreground,
                      borderColor: colors.border,
                      backgroundColor: colors.surface,
                    },
                  ]}
                  placeholder="Optional notes about this fill-up"
                  placeholderTextColor={colors.muted}
                  multiline
                  numberOfLines={3}
                  value={formData.notes}
                  onChangeText={(value) =>
                    setFormData({ ...formData, notes: value })
                  }
                />
              </View>

              <Pressable
                onPress={handleAddEntry}
                style={({ pressed }) => [
                  styles.submitButton,
                  pressed && { opacity: 0.9 },
                ]}
              >
                <LinearGradient
                  colors={[colors.primary, "#15803D"]}
                  start={{ x: 0, y: 0 }}
                  end={{ x: 1, y: 1 }}
                  style={styles.submitButtonGradient}
                >
                  <Text style={styles.submitButtonText}>Add Entry</Text>
                </LinearGradient>
              </Pressable>
            </ScrollView>
          </View>
        </View>
      </Modal>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  header: {
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
    paddingHorizontal: 20,
    paddingTop: 8,
    paddingBottom: 16,
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
  statsContainer: {
    paddingHorizontal: 20,
    paddingBottom: 12,
  },
  statsRow: {
    flexDirection: "row",
    gap: 10,
  },
  statCard: {
    flex: 1,
    borderRadius: 14,
    borderWidth: 1,
    paddingHorizontal: 12,
    paddingVertical: 10,
    alignItems: "center",
  },
  statCardLabel: {
    fontSize: 11,
    fontWeight: "500",
  },
  statCardValue: {
    fontSize: 18,
    fontWeight: "800",
    marginTop: 4,
  },
  addButtonContainer: {
    paddingHorizontal: 20,
    paddingBottom: 12,
  },
  addButton: {
    borderRadius: 14,
    overflow: "hidden",
  },
  addButtonGradient: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    paddingVertical: 12,
  },
  addButtonText: {
    color: "#FFFFFF",
    fontSize: 15,
    fontWeight: "700",
  },
  listContent: {
    paddingHorizontal: 20,
    paddingBottom: 100,
  },
  separator: {
    height: 10,
  },
  entryCard: {
    borderRadius: 16,
    borderWidth: 1,
    padding: 14,
    gap: 10,
  },
  entryHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
  },
  entryInfo: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    flex: 1,
  },
  entryIconBg: {
    width: 36,
    height: 36,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
  },
  entryTextCol: {
    flex: 1,
  },
  entryStation: {
    fontSize: 15,
    fontWeight: "700",
  },
  entryDate: {
    fontSize: 12,
    fontWeight: "400",
    marginTop: 2,
  },
  blendBadge: {
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 8,
  },
  blendBadgeText: {
    fontSize: 13,
    fontWeight: "700",
  },
  entryStats: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
  },
  statItem: {
    flex: 1,
    alignItems: "center",
  },
  statLabel: {
    fontSize: 11,
    fontWeight: "500",
  },
  statValue: {
    fontSize: 14,
    fontWeight: "700",
    marginTop: 2,
  },
  statDivider: {
    width: 1,
    height: 30,
    backgroundColor: "#E5E7EB",
    opacity: 0.3,
  },
  entryNotes: {
    fontSize: 12,
    fontWeight: "400",
    fontStyle: "italic",
  },
  emptyState: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: 40,
    gap: 14,
  },
  emptyIconBg: {
    width: 80,
    height: 80,
    borderRadius: 24,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 8,
  },
  emptyTitle: {
    fontSize: 20,
    fontWeight: "700",
    textAlign: "center",
  },
  emptySubtitle: {
    fontSize: 15,
    textAlign: "center",
    lineHeight: 22,
  },
  loadingText: {
    fontSize: 16,
    fontWeight: "500",
    textAlign: "center",
    marginTop: 40,
  },
  modalOverlay: {
    flex: 1,
    justifyContent: "flex-end",
  },
  modalContent: {
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    paddingTop: 20,
    paddingHorizontal: 20,
    paddingBottom: 40,
    maxHeight: "90%",
  },
  modalHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 20,
  },
  modalTitle: {
    fontSize: 20,
    fontWeight: "800",
  },
  modalForm: {
    gap: 16,
  },
  formGroup: {
    gap: 8,
  },
  formLabel: {
    fontSize: 14,
    fontWeight: "600",
  },
  formInput: {
    borderWidth: 1,
    borderRadius: 12,
    paddingHorizontal: 14,
    paddingVertical: 10,
    fontSize: 15,
    fontWeight: "500",
  },
  formInputMulti: {
    borderWidth: 1,
    borderRadius: 12,
    paddingHorizontal: 14,
    paddingVertical: 10,
    fontSize: 15,
    fontWeight: "500",
    textAlignVertical: "top",
  },
  submitButton: {
    borderRadius: 14,
    overflow: "hidden",
    marginTop: 20,
    marginBottom: 20,
  },
  submitButtonGradient: {
    alignItems: "center",
    justifyContent: "center",
    paddingVertical: 14,
  },
  submitButtonText: {
    color: "#FFFFFF",
    fontSize: 16,
    fontWeight: "700",
  },
  fuelLogDecimalBtn: {
    width: 36,
    height: 42,
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
    marginTop: 4,
    alignSelf: "flex-end",
  },
  fuelLogDecimalBtnText: {
    fontSize: 22,
    fontWeight: "800",
    lineHeight: 26,
  },
});

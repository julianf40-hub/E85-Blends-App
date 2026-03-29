import React, { useState, useEffect, useCallback, useRef } from "react";
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
import { getActiveCar, updateCarProfile } from "@/lib/garage";
import { getSavedBlends, deleteBlend, toggleFavorite, SavedBlend } from "@/lib/blend-storage";
import * as Location from "expo-location";
import { fetchNearbyStations } from "@/lib/station-data";

export default function FuelLogScreen() {
  const colors = useColors();
  const [entries, setEntries] = useState<FuelEntry[]>([]);
  const [stats, setStats] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [showModal, setShowModal] = useState(false);
  const [blends, setBlends] = useState<SavedBlend[]>([]);
  const [blendsExpanded, setBlendsExpanded] = useState(true);

  const loadBlends = useCallback(async () => {
    const b = await getSavedBlends();
    setBlends(b);
  }, []);

  const handleDeleteBlend = useCallback(async (id: string) => {
    Alert.alert("Delete Blend", "Remove this saved blend?", [
      { text: "Cancel", style: "cancel" },
      { text: "Delete", style: "destructive", onPress: async () => { await deleteBlend(id); loadBlends(); } },
    ]);
  }, [loadBlends]);

  const handleToggleFavorite = useCallback(async (id: string) => {
    await toggleFavorite(id);
    loadBlends();
  }, [loadBlends]);
  const [locationLoading, setLocationLoading] = useState(false);
  const locationFetchedRef = useRef(false);

  // Auto-populate station name from nearest E85 station when modal opens
  const autoPopulateStation = useCallback(async () => {
    if (locationFetchedRef.current) return; // only fetch once per modal open
    locationFetchedRef.current = true;
    setLocationLoading(true);
    try {
      const { status } = await Location.requestForegroundPermissionsAsync();
      if (status !== "granted") return;
      const loc = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
      const nearby = await fetchNearbyStations(loc.coords.latitude, loc.coords.longitude, 5, 1);
      if (nearby.length > 0) {
        setFormData((prev) => ({
          ...prev,
          stationName: prev.stationName === "" ? nearby[0].name : prev.stationName,
        }));
      }
    } catch {
      // silently fail — user can type manually
    } finally {
      setLocationLoading(false);
    }
  }, []);

  const [formData, setFormData] = useState({
    stationName: "",
    e85Gallons: "",
    gasGallons: "",
    e85Price: "",
    gasPrice: "",
    currentEthanolPct: "",
    odometer: "",
    notes: "",
  });

  // Derived values computed from e85Gallons + gasGallons
  const derivedE85 = parseFloat(formData.e85Gallons) || 0;
  const derivedGas = parseFloat(formData.gasGallons) || 0;
  const derivedTotal = derivedE85 + derivedGas;
  const E85_ETHANOL_PCT = 0.85; // E85 = 85% ethanol
  const derivedEthanolPct = derivedTotal > 0
    ? Math.round(((derivedE85 * E85_ETHANOL_PCT) / derivedTotal) * 100)
    : 0;
  const derivedE85Price = parseFloat(formData.e85Price) || 0;
  const derivedGasPrice = parseFloat(formData.gasPrice) || 0;
  const derivedBlendedPrice = derivedTotal > 0
    ? (derivedE85Price * derivedE85 + derivedGasPrice * derivedGas) / derivedTotal
    : 0;
  const derivedTotalCost = derivedE85Price * derivedE85 + derivedGasPrice * derivedGas;

  useEffect(() => {
    loadData();
  }, []);

  const loadData = useCallback(async () => {
    try {
      const logs = await loadFuelLog();
      const stats = await getFuelLogStats();
      setEntries(logs);
      setStats(stats);
      await loadBlends();
    } catch (error) {
      console.error("Failed to load fuel log:", error);
    } finally {
      setLoading(false);
    }
  }, [loadBlends]);

  const handleAddEntry = useCallback(async () => {
    if (
      !formData.stationName ||
      (!formData.e85Gallons && !formData.gasGallons) ||
      !formData.odometer
    ) {
      Alert.alert("Missing Fields", "Please enter station name, at least one gallons field, and odometer.");
      return;
    }
    if (derivedTotal <= 0) {
      Alert.alert("Invalid Gallons", "Total gallons must be greater than 0.");
      return;
    }

    try {
      const newEntry = await addFuelEntry({
        date: new Date().toISOString(),
        stationName: formData.stationName,
        blendRatio: derivedEthanolPct,
        gallonsAdded: derivedTotal,
        e85Gallons: derivedE85 > 0 ? derivedE85 : undefined,
        gasGallons: derivedGas > 0 ? derivedGas : undefined,
        e85PricePerGallon: derivedE85Price > 0 ? derivedE85Price : undefined,
        gasPricePerGallon: derivedGasPrice > 0 ? derivedGasPrice : undefined,
        pricePerGallon: derivedBlendedPrice,
        totalPrice: derivedTotalCost,
        odometer: parseFloat(formData.odometer),
        currentEthanolPct: formData.currentEthanolPct ? parseFloat(formData.currentEthanolPct) : undefined,
        notes: formData.notes || undefined,
      });

      if (Platform.OS !== "web") {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      }

      // Auto-update active car odometer from fuel log entry
      try {
        const car = await getActiveCar();
        if (car) {
          const newOdometer = parseFloat(formData.odometer);
          if (!isNaN(newOdometer) && newOdometer > (car.odometer ?? 0)) {
            await updateCarProfile(car.id, { odometer: newOdometer });
          }
        }
      } catch (e) {
        console.warn("Failed to update car odometer after fuel entry:", e);
      }

      setFormData({
        stationName: "",
        e85Gallons: "",
        gasGallons: "",
        e85Price: "",
        gasPrice: "",
        currentEthanolPct: "",
        odometer: "",
        notes: "",
      });
      setShowModal(false);
      await loadData();
    } catch (error) {
      Alert.alert("Error", "Failed to add fuel entry.");
    }
  }, [formData, derivedTotal, derivedE85, derivedGas, derivedE85Price, derivedGasPrice, derivedEthanolPct, derivedBlendedPrice, derivedTotalCost, loadData]);

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
            {item.e85Gallons != null ? (
              <>
                <View style={styles.statItem}>
                  <Text style={[styles.statLabel, { color: colors.muted }]}>E85 gal</Text>
                  <Text style={[styles.statValue, { color: colors.foreground }]}>{item.e85Gallons.toFixed(2)}</Text>
                </View>
                <View style={styles.statDivider} />
                <View style={styles.statItem}>
                  <Text style={[styles.statLabel, { color: colors.muted }]}>Gas gal</Text>
                  <Text style={[styles.statValue, { color: colors.foreground }]}>{(item.gasGallons ?? 0).toFixed(2)}</Text>
                </View>
              </>
            ) : (
              <View style={styles.statItem}>
                <Text style={[styles.statLabel, { color: colors.muted }]}>Gallons</Text>
                <Text style={[styles.statValue, { color: colors.foreground }]}>{item.gallonsAdded.toFixed(2)}</Text>
              </View>
            )}
            <View style={styles.statDivider} />
            <View style={styles.statItem}>
              <Text style={[styles.statLabel, { color: colors.muted }]}>
                Total
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

      {/* Saved Blends Section — pinned to very top, above stats */}
      {blends.length > 0 && (
        <Animated.View entering={FadeInDown.duration(300).delay(60)} style={[styles.blendsSection, { backgroundColor: colors.surface, borderColor: colors.border }]}>
          <Pressable
            onPress={() => setBlendsExpanded(!blendsExpanded)}
            style={styles.blendsSectionHeader}
          >
            <View style={styles.blendsSectionLeft}>
              <Text style={styles.blendsSectionIcon}>⚗️</Text>
              <Text style={[styles.blendsSectionTitle, { color: colors.foreground }]}>Saved Blends</Text>
              <View style={[styles.blendsBadge, { backgroundColor: colors.primary + "20" }]}>
                <Text style={[styles.blendsBadgeText, { color: colors.primary }]}>{blends.length}</Text>
              </View>
            </View>
            <IconSymbol name={blendsExpanded ? "chevron.up" : "chevron.down"} size={16} color={colors.muted} />
          </Pressable>
          {blendsExpanded && (
            <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.blendsScroll} contentContainerStyle={styles.blendsScrollContent}>
              {blends.map((blend) => {
                const ethanol = blend.result.finalEthanolPercent;
                const badgeColor = ethanol >= 60 ? "#10B981" : ethanol >= 40 ? "#F59E0B" : "#3B82F6";
                return (
                  <View key={blend.id} style={[styles.blendCard, { backgroundColor: colors.background, borderColor: colors.border }]}>
                    <View style={[styles.blendCardBadge, { backgroundColor: badgeColor + "20" }]}>
                      <Text style={[styles.blendCardBadgeText, { color: badgeColor }]}>E{Math.round(ethanol)}</Text>
                    </View>
                    <Text style={[styles.blendCardName, { color: colors.foreground }]} numberOfLines={1}>
                      {blend.name ?? `E${Math.round(ethanol)} Blend`}
                    </Text>
                    <Text style={[styles.blendCardDetail, { color: colors.muted }]}>
                      {blend.result.e85Gallons.toFixed(1)} gal E85 · {blend.result.gasGallons.toFixed(1)} gal gas
                    </Text>
                    <Text style={[styles.blendCardDate, { color: colors.muted }]}>
                      {new Date(blend.date).toLocaleDateString()}
                    </Text>
                    <View style={styles.blendCardActions}>
                      <Pressable
                        onPress={() => handleToggleFavorite(blend.id)}
                        style={({ pressed }) => [styles.blendCardAction, { opacity: pressed ? 0.6 : 1 }]}
                      >
                        <Text style={{ fontSize: 16 }}>{blend.isFavorite ? "🔖" : "📌"}</Text>
                      </Pressable>
                      <Pressable
                        onPress={() => handleDeleteBlend(blend.id)}
                        style={({ pressed }) => [styles.blendCardAction, { opacity: pressed ? 0.6 : 1 }]}
                      >
                        <IconSymbol name="trash" size={14} color={colors.error} />
                      </Pressable>
                    </View>
                  </View>
                );
              })}
            </ScrollView>
          )}
        </Animated.View>
      )}

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
          onPress={() => {
            locationFetchedRef.current = false;
            setShowModal(true);
            autoPopulateStation();
          }}
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
                <View style={{ position: "relative" }}>
                  <TextInput
                    style={[
                      styles.formInput,
                      {
                        color: colors.foreground,
                        borderColor: locationLoading ? colors.primary : colors.border,
                        backgroundColor: colors.surface,
                        paddingRight: locationLoading ? 40 : 12,
                      },
                    ]}
                    placeholder={locationLoading ? "Finding nearest station..." : "e.g., Shell, Chevron"}
                    placeholderTextColor={locationLoading ? colors.primary : colors.muted}
                    value={formData.stationName}
                    onChangeText={(value) =>
                      setFormData({ ...formData, stationName: value })
                    }
                  />
                  {locationLoading && (
                    <View style={{ position: "absolute", right: 10, top: 0, bottom: 0, justifyContent: "center" }}>
                      <IconSymbol name="location.fill" size={16} color={colors.primary} />
                    </View>
                  )}
                </View>
              </View>

              {/* ── Gallons Section ── */}
              <Text style={[styles.formSectionHeader, { color: colors.muted }]}>GALLONS ADDED</Text>
              <View style={styles.formRow}>
                <View style={[styles.formGroupHalf, { marginRight: 8 }]}>
                  <Text style={[styles.formLabel, { color: colors.foreground }]}>E85 Gallons</Text>
                  <TextInput
                    style={[styles.formInput, { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.surface }]}
                    placeholder="13.15"
                    placeholderTextColor={colors.muted}
                    keyboardType="decimal-pad"
                    value={formData.e85Gallons}
                    onChangeText={(v) => setFormData({ ...formData, e85Gallons: v.replace(/[^\d.]/g, "") })}
                    returnKeyType="next"
                  />
                </View>
                <View style={styles.formGroupHalf}>
                  <Text style={[styles.formLabel, { color: colors.foreground }]}>Gas Gallons</Text>
                  <TextInput
                    style={[styles.formInput, { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.surface }]}
                    placeholder="1.60"
                    placeholderTextColor={colors.muted}
                    keyboardType="decimal-pad"
                    value={formData.gasGallons}
                    onChangeText={(v) => setFormData({ ...formData, gasGallons: v.replace(/[^\d.]/g, "") })}
                    returnKeyType="next"
                  />
                </View>
              </View>

              {/* Live computed summary */}
              {derivedTotal > 0 && (
                <View style={[styles.derivedSummary, { backgroundColor: colors.primary + "10", borderColor: colors.primary + "30" }]}>
                  <Text style={[styles.derivedSummaryText, { color: colors.primary }]}>
                    Total: {derivedTotal.toFixed(2)} gal  ·  Blend: E{derivedEthanolPct}
                  </Text>
                </View>
              )}

              {/* ── Price Section ── */}
              <Text style={[styles.formSectionHeader, { color: colors.muted }]}>PRICE PER GALLON (optional)</Text>
              <View style={styles.formRow}>
                <View style={[styles.formGroupHalf, { marginRight: 8 }]}>
                  <Text style={[styles.formLabel, { color: colors.foreground }]}>E85 $/gal</Text>
                  <TextInput
                    style={[styles.formInput, { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.surface }]}
                    placeholder="2.89"
                    placeholderTextColor={colors.muted}
                    keyboardType="decimal-pad"
                    value={formData.e85Price}
                    onChangeText={(v) => setFormData({ ...formData, e85Price: v.replace(/[^\d.]/g, "") })}
                    returnKeyType="next"
                  />
                </View>
                <View style={styles.formGroupHalf}>
                  <Text style={[styles.formLabel, { color: colors.foreground }]}>Gas $/gal</Text>
                  <TextInput
                    style={[styles.formInput, { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.surface }]}
                    placeholder="3.49"
                    placeholderTextColor={colors.muted}
                    keyboardType="decimal-pad"
                    value={formData.gasPrice}
                    onChangeText={(v) => setFormData({ ...formData, gasPrice: v.replace(/[^\d.]/g, "") })}
                    returnKeyType="next"
                  />
                </View>
              </View>
              {derivedTotalCost > 0 && (
                <View style={[styles.derivedSummary, { backgroundColor: colors.success + "10", borderColor: colors.success + "30" }]}>
                  <Text style={[styles.derivedSummaryText, { color: colors.success }]}>
                    Total cost: ${derivedTotalCost.toFixed(2)}  ·  Avg: ${derivedBlendedPrice.toFixed(3)}/gal
                  </Text>
                </View>
              )}

              {/* ── Current Ethanol in Tank ── */}
              <Text style={[styles.formSectionHeader, { color: colors.muted }]}>CURRENT TANK (optional)</Text>
              <View style={styles.formGroup}>
                <Text style={[styles.formLabel, { color: colors.foreground }]}>Ethanol % in Tank Before Fill-Up</Text>
                <TextInput
                  style={[styles.formInput, { color: colors.foreground, borderColor: colors.border, backgroundColor: colors.surface }]}
                  placeholder="e.g. 55  (leave blank if unknown)"
                  placeholderTextColor={colors.muted}
                  keyboardType="decimal-pad"
                  value={formData.currentEthanolPct}
                  onChangeText={(v) => setFormData({ ...formData, currentEthanolPct: v.replace(/[^\d.]/g, "") })}
                  returnKeyType="next"
                />
                <Text style={[styles.formHint, { color: colors.muted }]}>Stored and used to auto-fill the calculator next time</Text>
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
  formRow: {
    flexDirection: "row",
    marginBottom: 12,
  },
  formGroupHalf: {
    flex: 1,
  },
  formSectionHeader: {
    fontSize: 11,
    fontWeight: "700",
    letterSpacing: 0.8,
    marginBottom: 8,
    marginTop: 4,
  },
  derivedSummary: {
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 8,
    marginBottom: 12,
  },
  derivedSummaryText: {
    fontSize: 13,
    fontWeight: "600",
  },
  formHint: {
    fontSize: 12,
    marginTop: 4,
    lineHeight: 16,
  },
  // Saved Blends section
  blendsSection: {
    marginHorizontal: 16,
    marginBottom: 8,
    borderRadius: 14,
    borderWidth: 1,
    overflow: "hidden",
  },
  blendsSectionHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 14,
    paddingVertical: 10,
  },
  blendsSectionLeft: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
  },
  blendsSectionIcon: {
    fontSize: 16,
  },
  blendsSectionTitle: {
    fontSize: 14,
    fontWeight: "600",
  },
  blendsBadge: {
    paddingHorizontal: 7,
    paddingVertical: 2,
    borderRadius: 10,
  },
  blendsBadgeText: {
    fontSize: 11,
    fontWeight: "700",
  },
  blendsScroll: {
    paddingBottom: 12,
  },
  blendsScrollContent: {
    paddingHorizontal: 12,
    gap: 8,
    paddingBottom: 4,
  },
  blendCard: {
    width: 160,
    borderRadius: 12,
    borderWidth: 1,
    padding: 12,
    gap: 4,
  },
  blendCardBadge: {
    alignSelf: "flex-start",
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: 8,
    marginBottom: 2,
  },
  blendCardBadgeText: {
    fontSize: 12,
    fontWeight: "700",
  },
  blendCardName: {
    fontSize: 13,
    fontWeight: "600",
  },
  blendCardDetail: {
    fontSize: 11,
    lineHeight: 15,
  },
  blendCardDate: {
    fontSize: 10,
    marginTop: 2,
  },
  blendCardActions: {
    flexDirection: "row",
    justifyContent: "flex-end",
    gap: 8,
    marginTop: 6,
  },
  blendCardAction: {
    padding: 4,
  },
});

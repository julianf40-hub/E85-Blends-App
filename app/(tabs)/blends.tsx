import React, { useState, useCallback } from "react";
import {
  Text,
  View,
  FlatList,
  Pressable,
  Platform,
  Alert,
  StyleSheet,
} from "react-native";
import Animated, { FadeIn, FadeInDown, FadeOut } from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import { useFocusEffect } from "expo-router";
import { LinearGradient } from "expo-linear-gradient";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import {
  SavedBlend,
  getSavedBlends,
  deleteBlend,
  toggleFavorite,
  clearAllBlends,
} from "@/lib/blend-storage";

export default function BlendsScreen() {
  const colors = useColors();
  const [blends, setBlends] = useState<SavedBlend[]>([]);
  const [loading, setLoading] = useState(true);

  useFocusEffect(
    useCallback(() => {
      (async () => {
        setLoading(true);
        const saved = await getSavedBlends();
        // Sort: favorites first, then by date
        saved.sort((a, b) => {
          if (a.isFavorite && !b.isFavorite) return -1;
          if (!a.isFavorite && b.isFavorite) return 1;
          return new Date(b.date).getTime() - new Date(a.date).getTime();
        });
        setBlends(saved);
        setLoading(false);
      })();
    }, [])
  );

  const handleDelete = useCallback(
    async (id: string) => {
      if (Platform.OS !== "web") {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
      }
      Alert.alert("Delete Blend", "Are you sure you want to delete this saved blend?", [
        { text: "Cancel", style: "cancel" },
        {
          text: "Delete",
          style: "destructive",
          onPress: async () => {
            await deleteBlend(id);
            setBlends((prev) => prev.filter((b) => b.id !== id));
            if (Platform.OS !== "web") {
              Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
            }
          },
        },
      ]);
    },
    []
  );

  const handleToggleFavorite = useCallback(
    async (id: string) => {
      if (Platform.OS !== "web") {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
      }
      await toggleFavorite(id);
      setBlends((prev) => {
        const updated = prev.map((b) =>
          b.id === id ? { ...b, isFavorite: !b.isFavorite } : b
        );
        updated.sort((a, b) => {
          if (a.isFavorite && !b.isFavorite) return -1;
          if (!a.isFavorite && b.isFavorite) return 1;
          return new Date(b.date).getTime() - new Date(a.date).getTime();
        });
        return updated;
      });
    },
    []
  );

  const handleClearAll = useCallback(() => {
    if (blends.length === 0) return;
    Alert.alert(
      "Clear All Blends",
      "This will permanently delete all saved blends. Are you sure?",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Clear All",
          style: "destructive",
          onPress: async () => {
            await clearAllBlends();
            setBlends([]);
            if (Platform.OS !== "web") {
              Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
            }
          },
        },
      ]
    );
  }, [blends.length]);

  const formatDate = (dateStr: string) => {
    const date = new Date(dateStr);
    return date.toLocaleDateString("en-US", {
      month: "short",
      day: "numeric",
      year: "numeric",
      hour: "numeric",
      minute: "2-digit",
    });
  };

  const renderBlendCard = useCallback(
    ({ item, index }: { item: SavedBlend; index: number }) => (
      <Animated.View entering={FadeInDown.duration(250).delay(index * 40)}>
        <View
          style={[
            styles.blendCard,
            {
              backgroundColor: colors.surface,
              borderColor: item.isFavorite ? colors.primary : colors.border,
              borderWidth: item.isFavorite ? 2 : 1,
            },
          ]}
        >
          {/* Card Header */}
          <View style={styles.cardHeader}>
            <View style={styles.blendLabelRow}>
              <LinearGradient
                colors={[colors.primary, "#15803D"]}
                start={{ x: 0, y: 0 }}
                end={{ x: 1, y: 1 }}
                style={styles.blendBadge}
              >
                <Text style={styles.blendBadgeText}>
                  {item.result.blendLabel}
                </Text>
              </LinearGradient>
              <View>
                <Text
                  style={[styles.blendTitle, { color: colors.foreground }]}
                >
                  {item.name || `${item.result.blendLabel} Blend`}
                </Text>
                <Text style={[styles.blendDate, { color: colors.muted }]}>
                  {formatDate(item.date)}
                </Text>
              </View>
            </View>
            <View style={styles.cardActions}>
              <Pressable
                onPress={() => handleToggleFavorite(item.id)}
                style={({ pressed }) => [
                  styles.iconButton,
                  pressed && { opacity: 0.6 },
                ]}
              >
                <IconSymbol
                  name="bookmark.fill"
                  size={20}
                  color={item.isFavorite ? colors.primary : colors.muted}
                />
              </Pressable>
              <Pressable
                onPress={() => handleDelete(item.id)}
                style={({ pressed }) => [
                  styles.iconButton,
                  pressed && { opacity: 0.6 },
                ]}
              >
                <IconSymbol
                  name="trash.fill"
                  size={18}
                  color={colors.error}
                />
              </Pressable>
            </View>
          </View>

          {/* Result Summary */}
          <View style={styles.resultSummary}>
            <View
              style={[
                styles.summaryItem,
                { backgroundColor: colors.primary + "12" },
              ]}
            >
              <Text style={[styles.summaryValue, { color: colors.foreground }]}>
                {item.result.e85Gallons}
              </Text>
              <Text style={[styles.summaryLabel, { color: colors.muted }]}>
                gal E85
              </Text>
            </View>
            <View
              style={[
                styles.summaryItem,
                { backgroundColor: "#D97706" + "12" },
              ]}
            >
              <Text style={[styles.summaryValue, { color: colors.foreground }]}>
                {item.result.gasGallons}
              </Text>
              <Text style={[styles.summaryLabel, { color: colors.muted }]}>
                gal Gas
              </Text>
            </View>
            <View
              style={[
                styles.summaryItem,
                { backgroundColor: colors.primary + "12" },
              ]}
            >
              <Text style={[styles.summaryValue, { color: colors.foreground }]}>
                {item.result.estimatedOctane}
              </Text>
              <Text style={[styles.summaryLabel, { color: colors.muted }]}>
                Octane
              </Text>
            </View>
          </View>

          {/* Tank Details */}
          <View style={styles.tankDetails}>
            <Text style={[styles.tankDetailText, { color: colors.muted }]}>
              {item.inputs.tankSize} gal tank
              {item.inputs.currentFuelLevel > 0
                ? ` · ${item.inputs.currentFuelLevel}% full`
                : " · Empty"}
              {` · ${item.result.finalEthanolPercent}% ethanol`}
            </Text>
          </View>
        </View>
      </Animated.View>
    ),
    [colors, handleDelete, handleToggleFavorite]
  );

  const renderEmptyState = () => (
    <Animated.View entering={FadeIn.duration(300)} style={styles.emptyState}>
      <View
        style={[styles.emptyIconBg, { backgroundColor: colors.primary + "15" }]}
      >
        <IconSymbol name="bookmark.fill" size={40} color={colors.primary} />
      </View>
      <Text style={[styles.emptyTitle, { color: colors.foreground }]}>
        No Saved Blends
      </Text>
      <Text style={[styles.emptySubtitle, { color: colors.muted }]}>
        Calculate a blend and tap Save Blend to keep it here for quick
        reference.
      </Text>
    </Animated.View>
  );

  return (
    <ScreenContainer>
      {/* Header */}
      <View style={styles.header}>
        <View style={styles.headerRow}>
          <View
            style={[
              styles.headerIconBg,
              { backgroundColor: colors.primary + "18" },
            ]}
          >
            <IconSymbol
              name="bookmark.fill"
              size={22}
              color={colors.primary}
            />
          </View>
          <View style={styles.headerTextCol}>
            <Text style={[styles.headerTitle, { color: colors.foreground }]}>
              My Blends
            </Text>
            <Text style={[styles.headerSubtitle, { color: colors.muted }]}>
              {blends.length} saved blend{blends.length !== 1 ? "s" : ""}
            </Text>
          </View>
          {blends.length > 0 && (
            <Pressable
              onPress={handleClearAll}
              style={({ pressed }) => [
                styles.clearButton,
                { borderColor: colors.error },
                pressed && { opacity: 0.7 },
              ]}
            >
              <Text style={[styles.clearButtonText, { color: colors.error }]}>
                Clear All
              </Text>
            </Pressable>
          )}
        </View>
      </View>

      {/* Blend List */}
      <FlatList
        data={blends}
        renderItem={renderBlendCard}
        keyExtractor={(item) => item.id}
        contentContainerStyle={styles.listContent}
        showsVerticalScrollIndicator={false}
        ItemSeparatorComponent={() => <View style={styles.separator} />}
        ListEmptyComponent={loading ? null : renderEmptyState}
      />
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  header: {
    paddingHorizontal: 20,
    paddingTop: 8,
    paddingBottom: 16,
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
  clearButton: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 10,
    borderWidth: 1,
  },
  clearButtonText: {
    fontSize: 13,
    fontWeight: "600",
  },
  listContent: {
    paddingHorizontal: 20,
    paddingBottom: 100,
    flexGrow: 1,
  },
  separator: {
    height: 10,
  },
  blendCard: {
    borderRadius: 18,
    padding: 16,
    gap: 14,
  },
  cardHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "flex-start",
  },
  blendLabelRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    flex: 1,
  },
  blendBadge: {
    width: 48,
    height: 48,
    borderRadius: 14,
    alignItems: "center",
    justifyContent: "center",
  },
  blendBadgeText: {
    color: "#FFFFFF",
    fontSize: 14,
    fontWeight: "800",
  },
  blendTitle: {
    fontSize: 17,
    fontWeight: "700",
  },
  blendDate: {
    fontSize: 12,
    fontWeight: "400",
    marginTop: 2,
  },
  cardActions: {
    flexDirection: "row",
    gap: 4,
  },
  iconButton: {
    padding: 6,
  },
  resultSummary: {
    flexDirection: "row",
    gap: 8,
  },
  summaryItem: {
    flex: 1,
    borderRadius: 12,
    padding: 10,
    alignItems: "center",
    gap: 2,
  },
  summaryValue: {
    fontSize: 18,
    fontWeight: "800",
  },
  summaryLabel: {
    fontSize: 11,
    fontWeight: "500",
  },
  tankDetails: {
    paddingTop: 2,
  },
  tankDetailText: {
    fontSize: 12,
    fontWeight: "500",
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
});

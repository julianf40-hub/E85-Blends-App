import React from "react";
import { Platform, Pressable, Text, View } from "react-native";
import * as Haptics from "expo-haptics";
import { IconSymbol } from "@/components/ui/icon-symbol";

type Props = {
  colors: any;
  styles: any;
  searchRadius: number;
  onRadiusChange: (radius: number) => void;
  filterConfirmed: boolean;
  onToggleConfirmed: () => void;
  sortMode: "distance" | "price";
  onSortModeChange: (mode: "distance" | "price") => void;
  viewMode: "list" | "map";
  onViewModeChange: (mode: "list" | "map") => void;
};

export function StationsControls({
  colors,
  styles,
  searchRadius,
  onRadiusChange,
  filterConfirmed,
  onToggleConfirmed,
  sortMode,
  onSortModeChange,
  viewMode,
  onViewModeChange,
}: Props) {
  return (
    <>
      <View style={styles.controlsRow}>
        <View style={styles.radiusChips}>
          {[10, 25, 50, 100].map((radius) => (
            <Pressable
              key={radius}
              onPress={() => onRadiusChange(radius)}
              style={({ pressed }) => [
                styles.radiusChip,
                {
                  backgroundColor: searchRadius === radius ? colors.primary : colors.background,
                  borderColor: searchRadius === radius ? colors.primary : colors.border,
                },
                pressed && { transform: [{ scale: 0.97 }] },
              ]}
            >
              <Text
                style={[
                  styles.radiusChipText,
                  { color: searchRadius === radius ? "#FFFFFF" : colors.foreground },
                ]}
              >
                {radius} mi
              </Text>
            </Pressable>
          ))}
        </View>
      </View>

      <View style={styles.filtersRow}>
        <Pressable
          onPress={() => {
            if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
            onToggleConfirmed();
          }}
          style={({ pressed }) => [{
            paddingHorizontal: 12, paddingVertical: 7, borderRadius: 10, borderWidth: 1,
            backgroundColor: filterConfirmed ? colors.success + "20" : colors.surface,
            borderColor: filterConfirmed ? colors.success : colors.border,
            opacity: pressed ? 0.7 : 1,
          }]}
        >
          <Text style={{ fontSize: 13, fontWeight: "600", color: filterConfirmed ? colors.success : colors.muted }}>
            {filterConfirmed ? "✅ Confirmed" : "All Stations"}
          </Text>
        </Pressable>

        <View style={{ flex: 1 }} />

        <View
          style={[
            styles.viewToggle,
            { backgroundColor: colors.surface, borderColor: colors.border, marginRight: 8 },
          ]}
        >
          <Pressable
            onPress={() => {
              if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
              onSortModeChange("distance");
            }}
            style={[styles.toggleBtn, sortMode === "distance" && { backgroundColor: colors.primary }]}
          >
            <IconSymbol
              name="location.fill"
              size={14}
              color={sortMode === "distance" ? "#FFFFFF" : colors.muted}
            />
          </Pressable>
          <Pressable
            onPress={() => {
              if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
              onSortModeChange("price");
            }}
            style={[styles.toggleBtn, sortMode === "price" && { backgroundColor: colors.primary }]}
          >
            <IconSymbol
              name="dollarsign.circle.fill"
              size={14}
              color={sortMode === "price" ? "#FFFFFF" : colors.muted}
            />
          </Pressable>
        </View>

        <View
          style={[
            styles.viewToggle,
            { backgroundColor: colors.surface, borderColor: colors.border },
          ]}
        >
          <Pressable
            onPress={() => {
              if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
              onViewModeChange("list");
            }}
            style={[styles.toggleBtn, viewMode === "list" && { backgroundColor: colors.primary }]}
          >
            <IconSymbol
              name="list.bullet"
              size={16}
              color={viewMode === "list" ? "#FFFFFF" : colors.muted}
            />
          </Pressable>
          <Pressable
            onPress={() => {
              if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
              onViewModeChange("map");
            }}
            style={[styles.toggleBtn, viewMode === "map" && { backgroundColor: colors.primary }]}
          >
            <IconSymbol
              name="map"
              size={16}
              color={viewMode === "map" ? "#FFFFFF" : colors.muted}
            />
          </Pressable>
        </View>
      </View>
    </>
  );
}

import React from "react";
import { Pressable, Text, View } from "react-native";
import { IconSymbol } from "@/components/ui/icon-symbol";

type Props = {
  colors: any;
  styles: any;
  loading: boolean;
  cacheAgeMin: number | null;
  stationsCount: number;
  onRefresh: () => void;
};

export function StationsHeader({ colors, styles, loading, cacheAgeMin, stationsCount, onRefresh }: Props) {
  return (
    <View style={styles.header}>
      <View style={styles.headerRow}>
        <View style={[styles.headerIconBg, { backgroundColor: colors.primary + "18" }]}>
          <IconSymbol name="map.fill" size={22} color={colors.primary} />
        </View>
        <View style={styles.headerTextCol}>
          <Text style={[styles.headerTitle, { color: colors.foreground }]}>E85 Stations</Text>
          <Text
            style={[
              styles.headerSubtitle,
              { color: cacheAgeMin !== null && cacheAgeMin > 30 ? colors.warning : colors.muted },
            ]}
          >
            {loading
              ? "Searching..."
              : cacheAgeMin !== null
              ? `${stationsCount} station${stationsCount !== 1 ? "s" : ""} · AFDC${cacheAgeMin === 0 ? " · just updated" : cacheAgeMin > 30 ? ` · cached ${cacheAgeMin}m ago — tap ↻` : ` · cached ${cacheAgeMin}m ago`}`
              : `${stationsCount} station${stationsCount !== 1 ? "s" : ""} found · AFDC`}
          </Text>
        </View>
        {!loading && (
          <Pressable
            onPress={onRefresh}
            style={({ pressed }) => [
              styles.refreshButton,
              { backgroundColor: colors.primary + "15" },
              pressed && { opacity: 0.7 },
            ]}
          >
            <IconSymbol name="arrow.clockwise" size={18} color={colors.primary} />
          </Pressable>
        )}
      </View>
    </View>
  );
}

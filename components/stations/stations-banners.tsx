import React from "react";
import { Pressable, Text, View } from "react-native";
import { IconSymbol } from "@/components/ui/icon-symbol";

type LocationDeniedProps = {
  colors: any;
  styles: any;
  visible: boolean;
  onOpenSettings: () => void;
  onDismiss: () => void;
};

export function LocationDeniedBanner({
  colors,
  styles,
  visible,
  onOpenSettings,
  onDismiss,
}: LocationDeniedProps) {
  if (!visible) return null;

  return (
    <View style={styles.bannerContainer}>
      <View style={[styles.infoBanner, { backgroundColor: colors.surface, borderColor: colors.border, borderWidth: 1, flexDirection: "column", alignItems: "stretch", gap: 10 }]}>
        <View style={{ flexDirection: "row", alignItems: "flex-start", gap: 10 }}>
          <IconSymbol name="location.slash.fill" size={18} color={colors.warning} style={{ marginTop: 1 }} />
          <View style={{ flex: 1 }}>
            <Text style={[styles.infoBannerText, { color: colors.foreground, fontWeight: "700", marginBottom: 2 }]}>
              Location Access Off
            </Text>
            <Text style={[styles.infoBannerText, { color: colors.muted, fontWeight: "400" }]}>
              Showing stations near Phoenix, AZ as a preview. Enable location to find stations near you.
            </Text>
          </View>
        </View>
        <View style={{ flexDirection: "row", gap: 8 }}>
          <Pressable
            onPress={onOpenSettings}
            style={({ pressed }) => [styles.bannerBtn, { backgroundColor: colors.primary, flex: 1, opacity: pressed ? 0.8 : 1 }]}
          >
            <IconSymbol name="gear" size={14} color="#fff" />
            <Text style={styles.bannerBtnText}>Open Settings</Text>
          </Pressable>
          <Pressable
            onPress={onDismiss}
            style={({ pressed }) => [styles.bannerBtn, { backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, opacity: pressed ? 0.7 : 1 }]}
          >
            <Text style={[styles.bannerBtnText, { color: colors.muted }]}>Dismiss</Text>
          </Pressable>
        </View>
      </View>
    </View>
  );
}

type ErrorBannerProps = {
  colors: any;
  styles: any;
  message: string | null;
  loading: boolean;
  onRetry: () => void;
};

export function StationsErrorBanner({ colors, styles, message, loading, onRetry }: ErrorBannerProps) {
  if (!message || message === "LOCATION_DENIED" || loading) return null;

  return (
    <View style={styles.bannerContainer}>
      <View style={[styles.infoBanner, { backgroundColor: colors.warning + "18", flexDirection: "column", alignItems: "flex-start", gap: 8 }]}>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
          <IconSymbol name="info.circle.fill" size={16} color={colors.warning} />
          <Text style={[styles.infoBannerText, { color: colors.warning, flex: 1 }]}>
            {message}
          </Text>
        </View>
        <Pressable
          onPress={onRetry}
          style={({ pressed }) => [{ paddingHorizontal: 12, paddingVertical: 6, backgroundColor: colors.warning, borderRadius: 8, opacity: pressed ? 0.7 : 1 }]}
        >
          <Text style={{ color: "#fff", fontWeight: "700", fontSize: 13 }}>Retry</Text>
        </Pressable>
      </View>
    </View>
  );
}

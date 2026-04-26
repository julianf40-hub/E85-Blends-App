import {
  Text,
  View,
  ScrollView,
  Pressable,
  StyleSheet,
  Platform,
  Linking,
} from "react-native";
import * as Haptics from "expo-haptics";
import { useRouter } from "expo-router";
import Constants from "expo-constants";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";

// ─── Feature pill ─────────────────────────────────────────────────────────────

function FeaturePill({ icon, label, colors }: { icon: string; label: string; colors: ReturnType<typeof useColors> }) {
  return (
    <View style={[styles.pill, { backgroundColor: colors.surface, borderColor: colors.border }]}>
      <Text style={styles.pillIcon}>{icon}</Text>
      <Text style={[styles.pillLabel, { color: colors.foreground }]}>{label}</Text>
    </View>
  );
}

// ─── Info row ─────────────────────────────────────────────────────────────────

function InfoRow({ label, value, colors }: { label: string; value: string; colors: ReturnType<typeof useColors> }) {
  return (
    <View style={styles.infoRow}>
      <Text style={[styles.infoLabel, { color: colors.muted }]}>{label}</Text>
      <Text style={[styles.infoValue, { color: colors.foreground }]}>{value}</Text>
    </View>
  );
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function AboutScreen() {
  const colors = useColors();
  const router = useRouter();

  const version = Constants.expoConfig?.version ?? "1.0.0";
  const buildNumber =
    (Constants.expoConfig?.ios?.buildNumber as string | undefined) ??
    (Constants.expoConfig?.android?.versionCode as number | undefined)?.toString() ??
    "1";

  return (
    <ScreenContainer>
      {/* Header */}
      <View style={[styles.header, { borderBottomColor: colors.border }]}>
        <Pressable
          onPress={() => router.back()}
          style={({ pressed }) => [styles.backBtn, pressed && { opacity: 0.6 }]}
        >
          <IconSymbol name="chevron.left" size={20} color={colors.primary} />
          <Text style={[styles.backLabel, { color: colors.primary }]}>More</Text>
        </Pressable>
        <Text style={[styles.headerTitle, { color: colors.foreground }]}>About</Text>
        <View style={styles.backBtn} />
      </View>

      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        {/* Brand hero */}
        <View style={[styles.hero, { backgroundColor: colors.surface, borderColor: colors.border }]}>
          <View style={[styles.logoCircle, { backgroundColor: colors.primary + "18", borderColor: colors.primary + "40" }]}>
            <Text style={styles.logoEmoji}>⛽</Text>
          </View>
          <Text style={[styles.appName, { color: colors.foreground }]}>85Blends</Text>
          <Text style={[styles.tagline, { color: colors.primary }]}>
            The flex-fuel companion for enthusiasts
          </Text>
          <View style={[styles.versionBadge, { backgroundColor: colors.primary + "18", borderColor: colors.primary + "30" }]}>
            <Text style={[styles.versionText, { color: colors.primary }]}>
              v{version}
            </Text>
          </View>
        </View>

        {/* Mission */}
        <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
          <Text style={[styles.cardTitle, { color: colors.foreground }]}>Our Mission</Text>
          <Text style={[styles.cardBody, { color: colors.muted }]}>
            85Blends was built for flex-fuel drivers and enthusiasts who want precise control over their fuel blends. Whether you’re chasing power on a built motor, maximizing savings at the pump, or just curious about ethanol content — 85Blends gives you the tools to do it right.
          </Text>
          <Text style={[styles.cardBody, { color: colors.muted, marginTop: 8 }]}>
            No ads. No accounts. No cloud required. Your data stays on your device.
          </Text>
        </View>

        {/* Features */}
        <View style={styles.section}>
          <Text style={[styles.sectionTitle, { color: colors.foreground }]}>What’s Inside</Text>
          <View style={styles.pillGrid}>
            <FeaturePill icon="⛽" label="Blend Calculator" colors={colors} />
            <FeaturePill icon="🗺️" label="Station Finder" colors={colors} />
            <FeaturePill icon="🚗" label="Garage" colors={colors} />
            <FeaturePill icon="📋" label="Fuel Log" colors={colors} />
            <FeaturePill icon="🔔" label="Reminders" colors={colors} />
            <FeaturePill icon="📊" label="MPG Analytics" colors={colors} />
          </View>
        </View>

        {/* Data attribution */}
        <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
          <Text style={[styles.cardTitle, { color: colors.foreground }]}>Data Attribution</Text>
          <InfoRow label="Station data" value="U.S. DOE AFDC / NREL" colors={colors} />
          <View style={[styles.divider, { backgroundColor: colors.border }]} />
          <InfoRow label="Gas prices" value="U.S. EIA Weekly Survey" colors={colors} />
          <View style={[styles.divider, { backgroundColor: colors.border }]} />
          <InfoRow label="E85 state avg" value="U.S. DOE AFDC Monthly" colors={colors} />
        </View>

        {/* Build info */}
        <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
          <Text style={[styles.cardTitle, { color: colors.foreground }]}>Build Info</Text>
          <InfoRow label="Version" value={version} colors={colors} />
          <View style={[styles.divider, { backgroundColor: colors.border }]} />
          <InfoRow label="Build" value={buildNumber} colors={colors} />
          <View style={[styles.divider, { backgroundColor: colors.border }]} />
          <InfoRow label="Platform" value={Platform.OS === "ios" ? "iOS" : Platform.OS === "android" ? "Android" : "Web"} colors={colors} />
        </View>

        {/* Legal */}
        <Text style={[styles.legal, { color: colors.muted }]}>
          85Blends is an independent app. It is not affiliated with, endorsed by, or sponsored by the U.S. Department of Energy, NREL, EIA, or any fuel retailer. All data is provided for informational purposes only.
        </Text>

        <View style={{ height: 40 }} />
      </ScrollView>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingVertical: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  backBtn: {
    flexDirection: "row",
    alignItems: "center",
    gap: 4,
    minWidth: 64,
  },
  backLabel: { fontSize: 15, fontWeight: "500" },
  headerTitle: { fontSize: 17, fontWeight: "700" },
  scrollContent: { paddingHorizontal: 16, paddingBottom: 24, gap: 16 },
  hero: {
    borderRadius: 20,
    borderWidth: StyleSheet.hairlineWidth,
    padding: 24,
    alignItems: "center",
    gap: 8,
    marginTop: 16,
  },
  logoCircle: {
    width: 80,
    height: 80,
    borderRadius: 24,
    borderWidth: 1.5,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 4,
  },
  logoEmoji: { fontSize: 40 },
  appName: { fontSize: 28, fontWeight: "800", letterSpacing: -0.5 },
  tagline: { fontSize: 14, fontWeight: "600", textAlign: "center" },
  versionBadge: {
    marginTop: 4,
    paddingHorizontal: 14,
    paddingVertical: 6,
    borderRadius: 20,
    borderWidth: 1,
  },
  versionText: { fontSize: 13, fontWeight: "700" },
  card: {
    borderRadius: 16,
    borderWidth: StyleSheet.hairlineWidth,
    padding: 16,
    gap: 8,
  },
  cardTitle: { fontSize: 15, fontWeight: "700", marginBottom: 4 },
  cardBody: { fontSize: 13, lineHeight: 20 },
  section: { gap: 10 },
  sectionTitle: { fontSize: 15, fontWeight: "700" },
  pillGrid: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  pill: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 20,
    borderWidth: StyleSheet.hairlineWidth,
  },
  pillIcon: { fontSize: 16 },
  pillLabel: { fontSize: 13, fontWeight: "600" },
  infoRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingVertical: 4,
  },
  infoLabel: { fontSize: 13 },
  infoValue: { fontSize: 13, fontWeight: "600" },
  divider: { height: StyleSheet.hairlineWidth },
  legal: { fontSize: 12, lineHeight: 18, textAlign: "center", paddingHorizontal: 8 },
});

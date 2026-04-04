import {
  Text,
  View,
  ScrollView,
  Pressable,
  StyleSheet,
} from "react-native";
import { useRouter } from "expo-router";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";

// ─── Data ─────────────────────────────────────────────────────────────────────

interface DataSourceEntry {
  label: string;
  source: string;
  detail: string;
  freshness: string;
  color: string;
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function DataSourcesScreen() {
  const colors = useColors();
  const router = useRouter();

  const entries: DataSourceEntry[] = [
    {
      label: "Station Locations",
      source: "U.S. DOE — AFDC",
      detail:
        "E85 and flex-fuel station listings come from the U.S. Department of Energy's Alternative Fuels Station Locator (AFDC). This is the most comprehensive public database of alternative fuel stations in the United States, maintained by the National Renewable Energy Laboratory (NREL).",
      freshness: "Updated continuously by NREL. The app fetches fresh results each time you search, with a 30-minute local cache to reduce data usage.",
      color: "#3B82F6",
    },
    {
      label: "Gas Prices",
      source: "U.S. EIA — Weekly Retail Survey",
      detail:
        "Regular unleaded and premium gas prices are sourced from the U.S. Energy Information Administration (EIA) Weekly Retail Gasoline and Diesel Prices survey. Prices are state-level averages, not per-station prices.",
      freshness: "Published every Monday for the prior week. Prices shown are the most recent available weekly average for your state.",
      color: "#F59E0B",
    },
    {
      label: "E85 State Average Price",
      source: "U.S. DOE — AFDC",
      detail:
        "The E85 state average price is sourced from the AFDC's monthly alternative fuel price report, which aggregates retail E85 prices by state from participating stations.",
      freshness: "Updated monthly. May not reflect current pump prices at specific stations.",
      color: "#10B981",
    },
    {
      label: "Community-Reported Prices",
      source: "User-submitted (this device only)",
      detail:
        "When you or another user taps \"Update Price\" on a station card, that price is stored locally on the device. These prices are not shared with other users or sent to any server. They are your personal records of prices you observed at the pump.",
      freshness: "Shown with a timestamp (e.g. \"Updated 2h ago\"). Prices older than 7 days are highlighted in amber as a staleness warning.",
      color: "#8B5CF6",
    },
    {
      label: "\"Confirmed E85\" Status",
      source: "User votes (this device only)",
      detail:
        "The \"Confirmed E85\" badge means you have personally voted that this station sells E85 or flex fuel. Votes are stored on your device only — they are not crowdsourced or shared with other users. The badge helps you remember which stations you have personally verified.",
      freshness: "Persists until you change your vote or clear app data.",
      color: "#22C55E",
    },
    {
      label: "Blend Calculations",
      source: "On-device math",
      detail:
        "All blend calculations are performed entirely on your device using the ethanol mixing formula. No data is sent to a server. Results depend entirely on the values you enter — tank size, current fuel level, target ethanol %, and fuel ethanol percentages.",
      freshness: "Instant. No network required.",
      color: "#EF4444",
    },
  ];

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
        <Text style={[styles.headerTitle, { color: colors.foreground }]}>Data Sources</Text>
        <View style={styles.backBtn} />
      </View>

      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        <Text style={[styles.intro, { color: colors.muted }]}>
          Where 85Blends gets its data, how fresh it is, and what it means.
        </Text>

        {entries.map((entry, idx) => (
          <View key={idx} style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            {/* Label row */}
            <View style={styles.cardHeader}>
              <View style={[styles.dot, { backgroundColor: entry.color }]} />
              <View style={{ flex: 1 }}>
                <Text style={[styles.cardLabel, { color: colors.foreground }]}>{entry.label}</Text>
                <Text style={[styles.cardSource, { color: entry.color }]}>{entry.source}</Text>
              </View>
            </View>

            <View style={[styles.divider, { backgroundColor: colors.border }]} />

            {/* Detail */}
            <Text style={[styles.cardDetail, { color: colors.muted }]}>{entry.detail}</Text>

            {/* Freshness */}
            <View style={[styles.freshnessBox, { backgroundColor: colors.background, borderColor: colors.border }]}>
              <Text style={[styles.freshnessLabel, { color: colors.primary }]}>Freshness</Text>
              <Text style={[styles.freshnessText, { color: colors.muted }]}>{entry.freshness}</Text>
            </View>
          </View>
        ))}

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
  scrollContent: { paddingHorizontal: 16, paddingBottom: 24, gap: 14 },
  intro: { fontSize: 14, lineHeight: 20, paddingVertical: 16 },
  card: {
    borderRadius: 16,
    borderWidth: StyleSheet.hairlineWidth,
    overflow: "hidden",
    padding: 16,
    gap: 12,
  },
  cardHeader: { flexDirection: "row", alignItems: "flex-start", gap: 12 },
  dot: { width: 10, height: 10, borderRadius: 5, marginTop: 4 },
  cardLabel: { fontSize: 15, fontWeight: "700" },
  cardSource: { fontSize: 12, fontWeight: "600", marginTop: 2 },
  divider: { height: StyleSheet.hairlineWidth },
  cardDetail: { fontSize: 13, lineHeight: 20 },
  freshnessBox: {
    borderRadius: 10,
    borderWidth: StyleSheet.hairlineWidth,
    padding: 12,
    gap: 4,
  },
  freshnessLabel: { fontSize: 11, fontWeight: "700", textTransform: "uppercase", letterSpacing: 0.5 },
  freshnessText: { fontSize: 13, lineHeight: 18 },
});

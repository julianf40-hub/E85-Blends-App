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

interface DisclaimerBlock {
  icon: string;
  title: string;
  body: string;
  accent: "warning" | "error" | "primary" | "muted";
}

export default function DisclaimersScreen() {
  const colors = useColors();
  const router = useRouter();

  const accentColor = (key: DisclaimerBlock["accent"]) => {
    switch (key) {
      case "warning": return colors.warning;
      case "error":   return colors.error;
      case "primary": return colors.primary;
      default:        return colors.muted;
    }
  };

  const blocks: DisclaimerBlock[] = [
    {
      icon: "⚗️",
      title: "Blend Calculations Are Estimates",
      body: "The calculator uses the ethanol mixing formula based on values you enter. Results depend entirely on the accuracy of your inputs — tank size, current fuel level, and ethanol percentages. Small measurement errors at the pump will shift the actual blend.",
      accent: "warning",
    },
    {
      icon: "🔢",
      title: "Octane Estimates Are Approximate",
      body: "Octane ratings shown are calculated from the weighted average of E85 and gasoline octane values. Actual octane can vary between E85 batches, fuel brands, and blending facilities. Treat displayed octane as a guide, not a guaranteed rating.",
      accent: "warning",
    },
    {
      icon: "🌡️",
      title: "Ethanol Content Varies by Season and Region",
      body: "E85 is not always 85% ethanol. By ASTM standard, E85 can range from 51% to 83% ethanol depending on the season and geographic region. Winter blends in cold climates often contain less ethanol to improve cold-start performance. The calculator defaults to 85% — adjust this if you know your local blend.",
      accent: "warning",
    },
    {
      icon: "💰",
      title: "Station Prices May Be Outdated",
      body: "Gas prices shown are weekly state averages from the EIA and monthly E85 averages from the AFDC. They are not real-time pump prices. Community-reported prices are user-submitted and may not reflect current pricing. Always verify the price on the pump before fueling.",
      accent: "primary",
    },
    {
      icon: "📍",
      title: "Station Availability Is Not Guaranteed",
      body: "Station listings come from the U.S. DOE AFDC database. Stations may have closed, changed fuel offerings, or stopped carrying E85 since the database was last updated. Always confirm E85 availability before making a special trip.",
      accent: "primary",
    },
    {
      icon: "🔧",
      title: "Verify Vehicle Compatibility",
      body: "Not all vehicles can safely run high-ethanol blends. Only Flex Fuel Vehicles (FFVs) are factory-certified for E85. Non-FFV vehicles may require fuel system upgrades, injector sizing, and an ethanol-compatible tune before running E85 blends. Running high-ethanol blends in an incompatible vehicle can cause damage.",
      accent: "error",
    },
    {
      icon: "⚙️",
      title: "Not Professional Mechanical or Tuning Advice",
      body: "85Blends is an informational tool for flex-fuel enthusiasts. Nothing in this app constitutes professional mechanical, tuning, or engineering advice. Consult a qualified tuner or mechanic before making fuel system modifications or running high-ethanol blends in a modified vehicle.",
      accent: "error",
    },
    {
      icon: "📱",
      title: "App Is Provided As-Is",
      body: "85Blends is provided for informational purposes only. The developers make no warranties, express or implied, regarding the accuracy, completeness, or fitness for a particular purpose of any information provided. Use of this app is at your own risk.",
      accent: "muted",
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
        <Text style={[styles.headerTitle, { color: colors.foreground }]}>Disclaimers</Text>
        <View style={styles.backBtn} />
      </View>

      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        <Text style={[styles.intro, { color: colors.muted }]}>
          Important information about the accuracy and limitations of 85Blends.
        </Text>

        {blocks.map((block, idx) => {
          const accent = accentColor(block.accent);
          return (
            <View
              key={idx}
              style={[
                styles.block,
                {
                  backgroundColor: colors.surface,
                  borderColor: colors.border,
                  borderLeftColor: accent,
                },
              ]}
            >
              <Text style={styles.blockIcon}>{block.icon}</Text>
              <View style={{ flex: 1, gap: 6 }}>
                <Text style={[styles.blockTitle, { color: colors.foreground }]}>{block.title}</Text>
                <Text style={[styles.blockBody, { color: colors.muted }]}>{block.body}</Text>
              </View>
            </View>
          );
        })}

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
  scrollContent: { paddingHorizontal: 16, paddingBottom: 24, gap: 12 },
  intro: { fontSize: 14, lineHeight: 20, paddingVertical: 16 },
  block: {
    flexDirection: "row",
    gap: 12,
    padding: 14,
    borderRadius: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderLeftWidth: 3,
  },
  blockIcon: { fontSize: 22, marginTop: 1 },
  blockTitle: { fontSize: 14, fontWeight: "700", lineHeight: 20 },
  blockBody: { fontSize: 13, lineHeight: 20 },
});

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

interface PolicySection {
  title: string;
  body: string;
}

const SECTIONS: PolicySection[] = [
  {
    title: "Overview",
    body: "85Blends is a local-first app. It does not require an account, does not collect personal information, and does not transmit your data to any third-party analytics or advertising service.",
  },
  {
    title: "Data Stored on Your Device",
    body: "All data you enter — vehicles, fuel logs, blend history, reminders, station votes, and preferences — is stored exclusively on your device using AsyncStorage. This data never leaves your device unless you explicitly export it.",
  },
  {
    title: "Network Requests",
    body: "The app makes outbound requests only to fetch station listings and fuel price data from public government APIs (U.S. DOE AFDC and U.S. EIA). These requests do not include any personal identifiers, account information, or device fingerprints. No user data is sent outbound.",
  },
  {
    title: "Location",
    body: "If you grant location permission, your device coordinates are used solely to find nearby E85 stations. Location data is not stored, logged, or transmitted beyond the immediate station search request. You can deny location permission and enter a ZIP code manually instead.",
  },
  {
    title: "No Analytics or Advertising",
    body: "85Blends does not include any analytics SDKs, crash reporters, advertising networks, or tracking libraries. There are no third-party SDKs that observe your usage.",
  },
  {
    title: "No Accounts or Cloud Sync",
    body: "There are no user accounts. No email address, name, or personal identifier is collected at any point. Your data is not synced to any cloud service.",
  },
  {
    title: "Beta Period",
    body: "This is a public beta release. If you choose to send feedback via the Send Feedback option, your message is sent through your device's email client directly to the developer. No feedback data is collected automatically.",
  },
  {
    title: "Data Deletion",
    body: "You can delete all app data at any time from More → Data & Privacy → Clear All Data. Uninstalling the app also removes all locally stored data.",
  },
  {
    title: "Changes to This Policy",
    body: "If this policy changes in a future release, the updated version will appear in this screen. The app version and date of the policy will be noted at the bottom.",
  },
];

export default function PrivacyScreen() {
  const colors = useColors();
  const router = useRouter();

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
        <Text style={[styles.headerTitle, { color: colors.foreground }]}>Privacy Policy</Text>
        <View style={styles.backBtn} />
      </View>

      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        {/* Summary badge */}
        <View style={[styles.summaryBadge, { backgroundColor: colors.success + "14", borderColor: colors.success + "40" }]}>
          <Text style={[styles.summaryIcon]}>🔒</Text>
          <View style={{ flex: 1 }}>
            <Text style={[styles.summaryTitle, { color: colors.success }]}>Your data stays on your device</Text>
            <Text style={[styles.summaryBody, { color: colors.muted }]}>
              No accounts. No analytics. No advertising. No cloud sync.
            </Text>
          </View>
        </View>

        {/* Policy sections */}
        {SECTIONS.map((section, idx) => (
          <View key={idx} style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
            <Text style={[styles.cardTitle, { color: colors.foreground }]}>{section.title}</Text>
            <Text style={[styles.cardBody, { color: colors.muted }]}>{section.body}</Text>
          </View>
        ))}

        {/* Footer */}
        <Text style={[styles.footer, { color: colors.muted }]}>
          Effective: April 2026 · 85Blends v1.0.0 Public Beta
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
  scrollContent: { paddingHorizontal: 16, paddingBottom: 24, gap: 12 },
  summaryBadge: {
    flexDirection: "row",
    alignItems: "flex-start",
    gap: 12,
    padding: 14,
    borderRadius: 14,
    borderWidth: StyleSheet.hairlineWidth,
    marginTop: 16,
  },
  summaryIcon: { fontSize: 22, marginTop: 1 },
  summaryTitle: { fontSize: 14, fontWeight: "700", marginBottom: 3 },
  summaryBody: { fontSize: 13, lineHeight: 18 },
  card: {
    borderRadius: 14,
    borderWidth: StyleSheet.hairlineWidth,
    padding: 14,
    gap: 6,
  },
  cardTitle: { fontSize: 14, fontWeight: "700" },
  cardBody: { fontSize: 13, lineHeight: 20 },
  footer: { fontSize: 12, textAlign: "center", paddingTop: 4 },
});

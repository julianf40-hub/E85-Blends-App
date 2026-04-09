import {
  Text,
  View,
  ScrollView,
  Pressable,
  StyleSheet,
  Linking,
  Platform,
  Alert,
} from "react-native";
import * as Haptics from "expo-haptics";
import * as Clipboard from "expo-clipboard";
import { useRouter } from "expo-router";
import Constants from "expo-constants";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";

const FEEDBACK_EMAIL = "feedback@85blends.app";

export default function FeedbackScreen() {
  const colors = useColors();
  const router = useRouter();

  const version = Constants.expoConfig?.version ?? "1.0.0";
  const buildNumber =
    Platform.OS === "ios"
      ? (Constants.expoConfig?.ios?.buildNumber ?? "1")
      : Platform.OS === "android"
        ? String(Constants.expoConfig?.android?.versionCode ?? 1)
        : "web";
  const platform = Platform.OS === "ios" ? "iOS" : Platform.OS === "android" ? "Android" : "Web";
  const subject = encodeURIComponent(`85Blends v${version} (${platform} build ${buildNumber}) — Feedback`);
  const body = encodeURIComponent(
    `Hi,\n\nI'm using 85Blends v${version} (build ${buildNumber}) on ${platform}.\n\n[Your feedback here]\n\n---\nApp: 85Blends v${version}\nBuild: ${buildNumber}\nPlatform: ${platform}`
  );
  const mailtoUrl = `mailto:${FEEDBACK_EMAIL}?subject=${subject}&body=${body}`;

  const handleOpenEmail = async () => {
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    try {
      const supported = await Linking.canOpenURL(mailtoUrl);
      if (supported) {
        await Linking.openURL(mailtoUrl);
      } else {
        Alert.alert(
          "No Email App Found",
          `Copy the address below and send your feedback manually:\n\n${FEEDBACK_EMAIL}`,
          [
            {
              text: "Copy Address",
              onPress: () => {
                Clipboard.setStringAsync(FEEDBACK_EMAIL);
                if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
              },
            },
            { text: "OK", style: "cancel" },
          ]
        );
      }
    } catch {
      Alert.alert("Error", "Could not open email app. Please email us at " + FEEDBACK_EMAIL);
    }
  };

  const handleCopyEmail = async () => {
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    await Clipboard.setStringAsync(FEEDBACK_EMAIL);
    Alert.alert("Copied", "Email address copied to clipboard.");
  };

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
        <Text style={[styles.headerTitle, { color: colors.foreground }]}>Send Feedback</Text>
        <View style={styles.backBtn} />
      </View>

      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        {/* Intro */}
        <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
          <Text style={[styles.cardTitle, { color: colors.foreground }]}>We'd love to hear from you</Text>
          <Text style={[styles.cardBody, { color: colors.muted }]}>
            Your feedback directly shapes what gets built next. Bug reports, feature ideas, and general impressions are all welcome.
          </Text>
        </View>

        {/* What to include */}
        <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
          <Text style={[styles.cardTitle, { color: colors.foreground }]}>Helpful to include</Text>
          {[
            "What you were trying to do",
            "What happened vs. what you expected",
            "Your vehicle type (FFV, modified, stock)",
            "Feature requests or UX suggestions",
          ].map((item, idx) => (
            <View key={idx} style={styles.bulletRow}>
              <View style={[styles.bullet, { backgroundColor: colors.primary }]} />
              <Text style={[styles.bulletText, { color: colors.muted }]}>{item}</Text>
            </View>
          ))}
        </View>

        {/* CTA */}
        <Pressable
          onPress={handleOpenEmail}
          style={({ pressed }) => [
            styles.ctaButton,
            { backgroundColor: colors.primary, opacity: pressed ? 0.85 : 1 },
          ]}
        >
          <IconSymbol name="paperplane.fill" size={18} color="#fff" />
          <Text style={styles.ctaText}>Open Email App</Text>
        </Pressable>

        {/* Email address row */}
        <View style={[styles.emailRow, { backgroundColor: colors.surface, borderColor: colors.border }]}>
          <Text style={[styles.emailLabel, { color: colors.muted }]}>Or email directly:</Text>
          <Pressable
            onPress={handleCopyEmail}
            style={({ pressed }) => [styles.emailAddress, pressed && { opacity: 0.6 }]}
          >
            <Text style={[styles.emailText, { color: colors.primary }]}>{FEEDBACK_EMAIL}</Text>
            <IconSymbol name="square.and.arrow.up" size={14} color={colors.primary} />
          </Pressable>
        </View>

        {/* Note */}
        <View style={[styles.betaBadge, { backgroundColor: colors.surface, borderColor: colors.border }]}>
          <Text style={[styles.betaText, { color: colors.muted }]}>
            <Text style={{ fontWeight: "700", color: colors.foreground }}>Note: </Text>
            Feedback is read by the developer personally. Response times may vary, but every message is reviewed.
          </Text>
        </View>

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
  card: {
    borderRadius: 14,
    borderWidth: StyleSheet.hairlineWidth,
    padding: 14,
    gap: 8,
    marginTop: 4,
  },
  cardTitle: { fontSize: 15, fontWeight: "700" },
  cardBody: { fontSize: 13, lineHeight: 20 },
  bulletRow: { flexDirection: "row", alignItems: "flex-start", gap: 10 },
  bullet: { width: 6, height: 6, borderRadius: 3, marginTop: 7 },
  bulletText: { flex: 1, fontSize: 13, lineHeight: 20 },
  ctaButton: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 10,
    paddingVertical: 15,
    borderRadius: 14,
  },
  ctaText: { color: "#fff", fontSize: 16, fontWeight: "700" },
  emailRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    padding: 14,
    borderRadius: 14,
    borderWidth: StyleSheet.hairlineWidth,
    gap: 8,
  },
  emailLabel: { fontSize: 13 },
  emailAddress: { flexDirection: "row", alignItems: "center", gap: 6 },
  emailText: { fontSize: 13, fontWeight: "600" },
  betaBadge: {
    padding: 12,
    borderRadius: 12,
    borderWidth: StyleSheet.hairlineWidth,
  },
  betaText: { fontSize: 13, lineHeight: 19 },
});

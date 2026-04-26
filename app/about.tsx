import Constants from "expo-constants";
import { ScrollView, Text } from "react-native";
import { palette } from "@/lib/rebuild/theme";

export default function AboutScreen() {
  const appVersion = Constants.expoConfig?.version ?? "2.0.0";
  const buildNumber = Constants.expoConfig?.ios?.buildNumber ?? "1";

  return (
    <ScrollView style={{ flex: 1, backgroundColor: palette.background }} contentContainerStyle={{ padding: 16, gap: 10 }}>
      <Text style={{ color: palette.text, fontSize: 28, fontWeight: "800" }}>About 85Blends</Text>
      <Text style={{ color: palette.muted }}>Version {appVersion} ({buildNumber})</Text>
      <Text style={{ color: palette.muted }}>Privacy, feedback, and legal links are retained for full polish in Phase 2.</Text>
    </ScrollView>
  );
}

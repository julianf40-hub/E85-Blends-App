import { ScrollView, Text } from "react-native";
import { palette } from "@/lib/rebuild/theme";

export default function HelpScreen() {
  return (
    <ScrollView style={{ flex: 1, backgroundColor: palette.background }} contentContainerStyle={{ padding: 16, gap: 10 }}>
      <Text style={{ color: palette.text, fontSize: 28, fontWeight: "800" }}>Help & Support</Text>
      <Text style={{ color: palette.muted }}>FAQ, data sources, and support resources will be refined in Phase 2.</Text>
    </ScrollView>
  );
}

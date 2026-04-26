import { ScrollView, Text, View } from "react-native";
import { palette } from "@/lib/rebuild/theme";

export default function RecommendedGearScreen() {
  return (
    <ScrollView style={{ flex: 1, backgroundColor: palette.background }} contentContainerStyle={{ padding: 16, gap: 12 }}>
      <Text style={{ color: palette.text, fontSize: 28, fontWeight: "800" }}>Recommended Gear</Text>
      {[
        "Ethanol test kit",
        "Flex fuel sensor",
        "OBD scanner",
      ].map((item) => (
        <View key={item} style={{ backgroundColor: palette.surface, borderWidth: 1, borderColor: palette.border, borderRadius: 12, padding: 12 }}>
          <Text style={{ color: palette.text, fontWeight: "700" }}>{item}</Text>
        </View>
      ))}
    </ScrollView>
  );
}

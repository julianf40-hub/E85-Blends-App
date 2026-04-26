import { router } from "expo-router";
import { Pressable, ScrollView, Text, View } from "react-native";
import { palette } from "@/lib/rebuild/theme";

export default function GarageTab() {
  return (
    <ScrollView style={{ flex: 1, backgroundColor: palette.background }} contentContainerStyle={{ padding: 16, gap: 12, paddingBottom: 120 }}>
      <Text style={{ color: palette.text, fontSize: 28, fontWeight: "800" }}>My Garage</Text>
      <View style={{ backgroundColor: palette.surface, borderColor: palette.border, borderWidth: 1, borderRadius: 14, padding: 14 }}>
        <Text style={{ color: palette.text, fontWeight: "700" }}>2018 VW GTI</Text>
        <Text style={{ color: palette.muted, marginTop: 4 }}>Default blend E40 · Requires 91+ octane</Text>
      </View>
      <Pressable onPress={() => router.push("/fuel-log")} style={{ backgroundColor: palette.elevated, borderRadius: 12, padding: 14 }}>
        <Text style={{ color: palette.text, fontWeight: "700", textAlign: "center" }}>Open Fuel Log</Text>
      </Pressable>
    </ScrollView>
  );
}

import { router } from "expo-router";
import { Pressable, ScrollView, Text, View } from "react-native";
import { palette } from "@/lib/rebuild/theme";

const links = [
  { label: "My Garage", href: "/(tabs)/garage" as const },
  { label: "Fuel Log / History", href: "/fuel-log" as const },
  { label: "Recommended Gear", href: "/recommended-gear" as const },
  { label: "Preferences", href: "/preferences" as const },
  { label: "Help & Support", href: "/help" as const },
  { label: "About / Version", href: "/about" as const },
];

export default function MoreTab() {
  return (
    <ScrollView style={{ flex: 1, backgroundColor: palette.background }} contentContainerStyle={{ padding: 16, gap: 12, paddingBottom: 120 }}>
      <Text style={{ color: palette.text, fontSize: 28, fontWeight: "800" }}>More</Text>
      <Text style={{ color: palette.muted }}>Control center for appearance, navigation, fuel preferences, and support.</Text>
      {links.map((item) => (
        <Pressable key={item.label} onPress={() => router.push(item.href)} style={{ backgroundColor: palette.surface, borderColor: palette.border, borderWidth: 1, borderRadius: 12, padding: 14 }}>
          <Text style={{ color: palette.text, fontWeight: "700" }}>{item.label}</Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

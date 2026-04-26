import { useMemo, useState } from "react";
import { Pressable, ScrollView, Text, TextInput, View } from "react-native";
import { palette } from "@/lib/rebuild/theme";
import { usePrefs } from "@/lib/rebuild/preferences";

const stations = [
  { id: "1", name: "Shell", city: "Austin", distance: 2.1, price: 2.89, trust: "Community verified" },
  { id: "2", name: "Chevron", city: "Austin", distance: 4.8, price: 3.05, trust: "State average fallback" },
  { id: "3", name: "Murphy USA", city: "Austin", distance: 8.3, price: 2.79, trust: "Fresh user report" },
];

export default function StationsTab() {
  const { prefs } = usePrefs();
  const [query, setQuery] = useState("");
  const filtered = useMemo(() => stations.filter((s) => `${s.name} ${s.city}`.toLowerCase().includes(query.toLowerCase())), [query]);

  return (
    <ScrollView style={{ flex: 1, backgroundColor: palette.background }} contentContainerStyle={{ padding: 16, gap: 12, paddingBottom: 120 }}>
      <Text style={{ color: palette.text, fontSize: 28, fontWeight: "800" }}>Stations</Text>
      <Text style={{ color: palette.muted }}>Within {prefs.searchRadius} miles · trust-focused pricing and direction shortcuts.</Text>
      <TextInput
        placeholder="Search city or station"
        placeholderTextColor="#65758A"
        value={query}
        onChangeText={setQuery}
        style={{ backgroundColor: palette.surface, borderWidth: 1, borderColor: palette.border, borderRadius: 12, color: palette.text, padding: 12 }}
      />
      {filtered.map((station) => (
        <View key={station.id} style={{ backgroundColor: palette.surface, borderColor: palette.border, borderWidth: 1, borderRadius: 14, padding: 14, gap: 5 }}>
          <Text style={{ color: palette.text, fontSize: 16, fontWeight: "700" }}>{station.name}</Text>
          <Text style={{ color: palette.muted }}>{station.city} · {station.distance} mi away</Text>
          <Text style={{ color: palette.primary, fontWeight: "700" }}>${station.price.toFixed(2)} / gal E85</Text>
          <Text style={{ color: palette.muted, fontSize: 12 }}>{station.trust}</Text>
          <Pressable style={{ marginTop: 8, backgroundColor: palette.elevated, borderRadius: 10, paddingVertical: 8 }}>
            <Text style={{ color: palette.text, textAlign: "center", fontWeight: "600" }}>Open Directions</Text>
          </Pressable>
        </View>
      ))}
    </ScrollView>
  );
}

import { useEffect, useState } from "react";
import { Pressable, ScrollView, Text, View } from "react-native";
import { palette } from "@/lib/rebuild/theme";
import { loadFuelLog, saveFuelLog, type FuelLogItem } from "@/lib/rebuild/storage";

export default function FuelLogScreen() {
  const [items, setItems] = useState<FuelLogItem[]>([]);

  useEffect(() => {
    loadFuelLog().then(setItems);
  }, []);

  const addMock = async () => {
    const next = [{ id: Date.now().toString(), date: new Date().toLocaleDateString(), station: "Shell", blend: "E40", gallons: 11.2, total: 35.44 }, ...items];
    setItems(next);
    await saveFuelLog(next);
  };

  return (
    <ScrollView style={{ flex: 1, backgroundColor: palette.background }} contentContainerStyle={{ padding: 16, gap: 12 }}>
      <Text style={{ color: palette.text, fontSize: 28, fontWeight: "800" }}>Fuel Log</Text>
      <Pressable onPress={addMock} style={{ backgroundColor: palette.primary, borderRadius: 12, padding: 12 }}>
        <Text style={{ color: "#00170B", textAlign: "center", fontWeight: "700" }}>Quick Add Fill-Up</Text>
      </Pressable>
      {items.length === 0 ? <Text style={{ color: palette.muted }}>No entries yet.</Text> : null}
      {items.map((item) => (
        <View key={item.id} style={{ backgroundColor: palette.surface, borderColor: palette.border, borderWidth: 1, borderRadius: 12, padding: 12 }}>
          <Text style={{ color: palette.text, fontWeight: "700" }}>{item.date} · {item.station}</Text>
          <Text style={{ color: palette.muted }}>{item.blend} · {item.gallons} gal · ${item.total.toFixed(2)}</Text>
        </View>
      ))}
    </ScrollView>
  );
}

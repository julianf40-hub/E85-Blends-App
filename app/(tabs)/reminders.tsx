import { useEffect, useState } from "react";
import { Pressable, ScrollView, Switch, Text, View } from "react-native";
import { palette } from "@/lib/rebuild/theme";
import { loadReminders, saveReminders, type ReminderItem } from "@/lib/rebuild/storage";

export default function RemindersTab() {
  const [items, setItems] = useState<ReminderItem[]>([]);

  useEffect(() => {
    loadReminders().then(setItems);
  }, []);

  const toggle = async (id: string) => {
    const next = items.map((item) => (item.id === id ? { ...item, enabled: !item.enabled } : item));
    setItems(next);
    await saveReminders(next);
  };

  return (
    <ScrollView style={{ flex: 1, backgroundColor: palette.background }} contentContainerStyle={{ padding: 16, gap: 12, paddingBottom: 120 }}>
      <Text style={{ color: palette.text, fontSize: 28, fontWeight: "800" }}>Reminders</Text>
      {items.map((item) => (
        <View key={item.id} style={{ backgroundColor: palette.surface, borderColor: palette.border, borderWidth: 1, borderRadius: 14, padding: 14, flexDirection: "row", justifyContent: "space-between", alignItems: "center" }}>
          <View style={{ flex: 1, paddingRight: 8 }}>
            <Text style={{ color: palette.text, fontWeight: "700" }}>{item.title}</Text>
            <Text style={{ color: palette.muted }}>Due every {item.dueInDays} day(s)</Text>
          </View>
          <Switch value={item.enabled} onValueChange={() => toggle(item.id)} />
        </View>
      ))}
      <Pressable style={{ backgroundColor: palette.elevated, borderRadius: 12, padding: 14 }}>
        <Text style={{ color: palette.text, textAlign: "center", fontWeight: "700" }}>Add Reminder (Phase 2)</Text>
      </Pressable>
    </ScrollView>
  );
}

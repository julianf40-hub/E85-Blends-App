import { ScrollView, Switch, Text, View } from "react-native";
import { palette } from "@/lib/rebuild/theme";
import { usePrefs } from "@/lib/rebuild/preferences";

export default function PreferencesScreen() {
  const { prefs, update } = usePrefs();

  return (
    <ScrollView style={{ flex: 1, backgroundColor: palette.background }} contentContainerStyle={{ padding: 16, gap: 12 }}>
      <Text style={{ color: palette.text, fontSize: 28, fontWeight: "800" }}>Preferences</Text>

      <View style={{ backgroundColor: palette.surface, borderColor: palette.border, borderWidth: 1, borderRadius: 12, padding: 12, flexDirection: "row", justifyContent: "space-between", alignItems: "center" }}>
        <Text style={{ color: palette.text }}>Show Garage tab</Text>
        <Switch value={prefs.showGarageTab} onValueChange={(v) => update("showGarageTab", v)} />
      </View>
      <View style={{ backgroundColor: palette.surface, borderColor: palette.border, borderWidth: 1, borderRadius: 12, padding: 12, flexDirection: "row", justifyContent: "space-between", alignItems: "center" }}>
        <Text style={{ color: palette.text }}>Show Reminders tab</Text>
        <Switch value={prefs.showRemindersTab} onValueChange={(v) => update("showRemindersTab", v)} />
      </View>
      <Text style={{ color: palette.muted }}>Theme is locked to dark for iOS-first visual consistency in Phase 1.</Text>
    </ScrollView>
  );
}

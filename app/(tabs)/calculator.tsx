import { useMemo, useState } from "react";
import { Pressable, ScrollView, Switch, Text, TextInput, View } from "react-native";
import { palette } from "@/lib/rebuild/theme";
import { usePrefs } from "@/lib/rebuild/preferences";

function cardStyle() {
  return { backgroundColor: palette.surface, borderColor: palette.border, borderWidth: 1, borderRadius: 14, padding: 14 } as const;
}

export default function CalculatorTab() {
  const { prefs } = usePrefs();
  const [tankSize, setTankSize] = useState(String(prefs.defaultTankSize));
  const [currentPct, setCurrentPct] = useState("10");
  const [targetPct, setTargetPct] = useState(String(prefs.defaultBlend));
  const [pumpMode, setPumpMode] = useState(false);

  const result = useMemo(() => {
    const tank = Number(tankSize) || 0;
    const current = Number(currentPct) || 0;
    const target = Number(targetPct) || 0;
    const e85Gallons = Math.max(0, ((target - current) / 75) * tank);
    const gasGallons = Math.max(0, tank - e85Gallons);
    return { e85Gallons, gasGallons, octane: target >= 60 ? "99+" : target >= 40 ? "95-98" : "91-94" };
  }, [tankSize, currentPct, targetPct]);

  return (
    <ScrollView style={{ flex: 1, backgroundColor: palette.background }} contentContainerStyle={{ padding: 16, gap: 12, paddingBottom: 120 }}>
      <Text style={{ color: palette.text, fontSize: 28, fontWeight: "800" }}>Blend Calculator</Text>
      <View style={cardStyle()}>
        <Text style={{ color: palette.muted }}>Tank Size (gal)</Text>
        <TextInput value={tankSize} onChangeText={setTankSize} keyboardType="decimal-pad" style={{ color: palette.text, fontSize: 20, marginTop: 6 }} />
      </View>
      <View style={cardStyle()}>
        <Text style={{ color: palette.muted }}>Current Ethanol %</Text>
        <TextInput value={currentPct} onChangeText={setCurrentPct} keyboardType="decimal-pad" style={{ color: palette.text, fontSize: 20, marginTop: 6 }} />
      </View>
      <View style={cardStyle()}>
        <Text style={{ color: palette.muted }}>Target Ethanol %</Text>
        <TextInput value={targetPct} onChangeText={setTargetPct} keyboardType="decimal-pad" style={{ color: palette.text, fontSize: 20, marginTop: 6 }} />
        <View style={{ flexDirection: "row", marginTop: 8, gap: 8 }}>
          {[30, 50, 70, 85].map((b) => (
            <Pressable key={b} onPress={() => setTargetPct(String(b))} style={{ backgroundColor: palette.elevated, borderRadius: 10, paddingHorizontal: 10, paddingVertical: 6 }}>
              <Text style={{ color: palette.text }}>E{b}</Text>
            </Pressable>
          ))}
        </View>
      </View>
      <View style={[cardStyle(), { flexDirection: "row", justifyContent: "space-between", alignItems: "center" }]}>
        <View>
          <Text style={{ color: palette.text, fontWeight: "700" }}>Pump Mode</Text>
          <Text style={{ color: palette.muted }}>Track fueling in order at the pump.</Text>
        </View>
        <Switch value={pumpMode} onValueChange={setPumpMode} />
      </View>
      <View style={[cardStyle(), { borderColor: "#234A31" }]}>
        <Text style={{ color: palette.primary, fontWeight: "800", fontSize: 18 }}>Fill Recommendation</Text>
        <Text style={{ color: palette.text, marginTop: 8 }}>E85: {result.e85Gallons.toFixed(2)} gal</Text>
        <Text style={{ color: palette.text }}>Gas: {result.gasGallons.toFixed(2)} gal</Text>
        <Text style={{ color: palette.muted, marginTop: 6 }}>Estimated blend octane: {result.octane}</Text>
        {pumpMode ? <Text style={{ color: palette.warning, marginTop: 6 }}>Pump Mode on: start with gas then top with E85 for smoother adjustment.</Text> : null}
      </View>
    </ScrollView>
  );
}

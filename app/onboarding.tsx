import { router } from "expo-router";
import { Pressable, Text, View } from "react-native";
import { palette } from "@/lib/rebuild/theme";
import { usePrefs } from "@/lib/rebuild/preferences";

export default function OnboardingScreen() {
  const { update } = usePrefs();

  const complete = async (homeTab: "calculator" | "stations") => {
    await update("homeTab", homeTab);
    await update("hasOnboarded", true);
    router.replace(`/(tabs)/${homeTab}` as never);
  };

  return (
    <View style={{ flex: 1, backgroundColor: palette.background, padding: 24, justifyContent: "center", gap: 16 }}>
      <Text style={{ color: palette.text, fontSize: 30, fontWeight: "800" }}>85Blends</Text>
      <Text style={{ color: palette.muted, fontSize: 16 }}>Clean iOS-first rebuild foundation. Pick your default home tab.</Text>
      <Pressable onPress={() => complete("calculator")} style={{ backgroundColor: palette.primary, padding: 14, borderRadius: 12 }}>
        <Text style={{ color: "#00170B", fontWeight: "700", textAlign: "center" }}>Start on Calculator</Text>
      </Pressable>
      <Pressable onPress={() => complete("stations")} style={{ backgroundColor: palette.surface, borderWidth: 1, borderColor: palette.border, padding: 14, borderRadius: 12 }}>
        <Text style={{ color: palette.text, fontWeight: "700", textAlign: "center" }}>Start on Stations</Text>
      </Pressable>
    </View>
  );
}

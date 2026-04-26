import { Redirect } from "expo-router";
import { ActivityIndicator, View } from "react-native";
import { usePrefs } from "@/lib/rebuild/preferences";

export default function Index() {
  const { prefs, loading } = usePrefs();

  if (loading) {
    return (
      <View style={{ flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: "#000" }}>
        <ActivityIndicator color="#22C55E" />
      </View>
    );
  }

  if (!prefs.hasOnboarded) return <Redirect href="/onboarding" />;
  return <Redirect href={`/(tabs)/${prefs.homeTab}` as never} />;
}

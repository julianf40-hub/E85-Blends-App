import { BlurView } from "expo-blur";
import { Tabs } from "expo-router";
import { Platform, Text } from "react-native";
import { usePrefs } from "@/lib/rebuild/preferences";

function Icon({ glyph, color }: { glyph: string; color: string }) {
  return <Text style={{ color, fontSize: 16 }}>{glyph}</Text>;
}

export default function TabsLayout() {
  const { prefs } = usePrefs();

  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: "#22C55E",
        tabBarInactiveTintColor: "#8391A6",
        tabBarStyle: {
          height: 74,
          paddingTop: 8,
          backgroundColor: "transparent",
          borderTopColor: "rgba(255,255,255,0.12)",
          position: "absolute",
        },
        tabBarBackground: () =>
          Platform.OS === "ios" ? <BlurView intensity={85} tint="dark" style={{ flex: 1 }} /> : undefined,
      }}
    >
      <Tabs.Screen name="calculator" options={{ title: "Calculator", tabBarIcon: ({ color }) => <Icon color={color} glyph="⛽" /> }} />
      <Tabs.Screen name="stations" options={{ title: "Stations", tabBarIcon: ({ color }) => <Icon color={color} glyph="📍" /> }} />
      <Tabs.Screen name="garage" options={{ href: prefs.showGarageTab ? undefined : null, title: "Garage", tabBarIcon: ({ color }) => <Icon color={color} glyph="🚗" /> }} />
      <Tabs.Screen name="reminders" options={{ href: prefs.showRemindersTab ? undefined : null, title: "Reminders", tabBarIcon: ({ color }) => <Icon color={color} glyph="🔔" /> }} />
      <Tabs.Screen name="more" options={{ title: "More", tabBarIcon: ({ color }) => <Icon color={color} glyph="⋯" /> }} />
    </Tabs>
  );
}

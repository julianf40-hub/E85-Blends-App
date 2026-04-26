import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { PreferencesProvider } from "@/lib/rebuild/preferences";

export default function RootLayout() {
  return (
    <PreferencesProvider>
      <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: "#000" } }}>
        <Stack.Screen name="index" />
        <Stack.Screen name="onboarding" options={{ presentation: "modal" }} />
        <Stack.Screen name="(tabs)" />
        <Stack.Screen name="fuel-log" />
        <Stack.Screen name="preferences" />
        <Stack.Screen name="recommended-gear" />
        <Stack.Screen name="help" />
        <Stack.Screen name="about" />
      </Stack>
      <StatusBar style="light" />
    </PreferencesProvider>
  );
}

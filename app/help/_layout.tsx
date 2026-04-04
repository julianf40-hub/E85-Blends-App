import { Stack } from "expo-router";

export default function HelpLayout() {
  return (
    <Stack screenOptions={{ headerShown: false }}>
      <Stack.Screen name="faq" />
      <Stack.Screen name="data-sources" />
      <Stack.Screen name="disclaimers" />
      <Stack.Screen name="about" />
      <Stack.Screen name="privacy" />
      <Stack.Screen name="feedback" />
    </Stack>
  );
}

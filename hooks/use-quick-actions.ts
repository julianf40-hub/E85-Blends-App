/**
 * Hook that registers Android App Shortcuts at runtime and handles routing
 * when the user taps a shortcut from the home screen.
 */
import { useEffect } from "react";
import { Platform } from "react-native";
import QuickActions from "expo-quick-actions";
import { useQuickActionRouting } from "expo-quick-actions/router";

export function useQuickActions() {
  // Handle routing when a shortcut is tapped
  useQuickActionRouting();

  // Register shortcuts on mount (Android only — iOS uses static actions in app.config)
  useEffect(() => {
    if (Platform.OS !== "android") return;
    QuickActions.setItems([
      {
        id: "open_calculator",
        title: "E85 Calculator",
        subtitle: "Calculate your blend",
        icon: "calculator_icon",
        params: { href: "/(tabs)/" },
      },
      {
        id: "open_stations",
        title: "Find Stations",
        subtitle: "E85 near you",
        icon: "calculator_icon",
        params: { href: "/(tabs)/stations" },
      },
    ]);
  }, []);
}

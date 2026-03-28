/**
 * Hook that listens for Android App Shortcuts (expo-quick-actions) and
 * navigates to the correct tab when the user taps a shortcut.
 */
import { useEffect } from "react";
import { Platform } from "react-native";
import { router } from "expo-router";
import QuickActions from "expo-quick-actions";
import { useQuickActionRouting } from "expo-quick-actions/router";

export function useQuickActions() {
  // expo-quick-actions/router handles deep-link routing automatically
  useQuickActionRouting();
}

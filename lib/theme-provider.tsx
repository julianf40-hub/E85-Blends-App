import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { Appearance, View, useColorScheme as useSystemColorScheme } from "react-native";
import { colorScheme as nativewindColorScheme, vars } from "nativewind";
import AsyncStorage from "@react-native-async-storage/async-storage";

import { SchemeColors, type ColorScheme } from "@/constants/theme";

const THEME_PREF_KEY = "@e85app/themePref";

type ThemeMode = "light" | "dark" | "system";

type ThemeContextValue = {
  colorScheme: ColorScheme;   // resolved scheme: "light" | "dark"
  themeMode: ThemeMode;       // user's chosen mode: "light" | "dark" | "system"
  setColorScheme: (mode: ThemeMode) => void;
};

const ThemeContext = createContext<ThemeContextValue | null>(null);

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const systemScheme = (useSystemColorScheme() ?? "light") as ColorScheme;
  const [themeMode, setThemeModeState] = useState<ThemeMode>("system");

  // Resolved scheme: when mode is "system", follow the OS
  const resolvedScheme: ColorScheme = themeMode === "system" ? systemScheme : themeMode;

  const applyScheme = useCallback((scheme: ColorScheme, isSystemMode: boolean) => {
    // Only update NativeWind color scheme — never call Appearance.setColorScheme in system mode
    // because that would override the OS setting and break automatic switching.
    nativewindColorScheme.set(scheme);
    if (!isSystemMode) {
      // In manual light/dark mode, lock the appearance at OS level too
      Appearance.setColorScheme?.(scheme);
    } else {
      // In system mode, reset any previous lock so the OS can control it
      Appearance.setColorScheme?.(null as any);
    }
    if (typeof document !== "undefined") {
      const root = document.documentElement;
      root.dataset.theme = scheme;
      root.classList.toggle("dark", scheme === "dark");
      const palette = SchemeColors[scheme];
      Object.entries(palette).forEach(([token, value]) => {
        root.style.setProperty(`--color-${token}`, value);
      });
    }
  }, []);

  // Load persisted preference on mount
  useEffect(() => {
    AsyncStorage.getItem(THEME_PREF_KEY).then((saved) => {
      if (saved === "light" || saved === "dark" || saved === "system") {
        setThemeModeState(saved);
      }
    }).catch(() => {});
  }, []);

  // Apply scheme whenever resolved scheme changes (covers system mode OS changes too)
  useEffect(() => {
    applyScheme(resolvedScheme, themeMode === "system");
  }, [applyScheme, resolvedScheme, themeMode]);

  const setColorScheme = useCallback((mode: ThemeMode) => {
    setThemeModeState(mode);
    AsyncStorage.setItem(THEME_PREF_KEY, mode).catch(() => {});
  }, []);

  const themeVariables = useMemo(
    () =>
      vars({
        "color-primary": SchemeColors[resolvedScheme].primary,
        "color-background": SchemeColors[resolvedScheme].background,
        "color-surface": SchemeColors[resolvedScheme].surface,
        "color-foreground": SchemeColors[resolvedScheme].foreground,
        "color-muted": SchemeColors[resolvedScheme].muted,
        "color-border": SchemeColors[resolvedScheme].border,
        "color-success": SchemeColors[resolvedScheme].success,
        "color-warning": SchemeColors[resolvedScheme].warning,
        "color-error": SchemeColors[resolvedScheme].error,
      }),
    [resolvedScheme],
  );

  const value = useMemo(
    () => ({
      colorScheme: resolvedScheme,
      themeMode,
      setColorScheme,
    }),
    [resolvedScheme, themeMode, setColorScheme],
  );

  return (
    <ThemeContext.Provider value={value}>
      <View style={[{ flex: 1 }, themeVariables]}>{children}</View>
    </ThemeContext.Provider>
  );
}

export function useThemeContext(): ThemeContextValue {
  const ctx = useContext(ThemeContext);
  if (!ctx) {
    throw new Error("useThemeContext must be used within ThemeProvider");
  }
  return ctx;
}

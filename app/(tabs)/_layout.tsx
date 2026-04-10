import { Tabs } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Platform, StyleSheet, View } from "react-native";

import { BlurView } from "expo-blur";

import { HapticTab } from "@/components/haptic-tab";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import { useColorScheme } from "@/hooks/use-color-scheme";
import { usePreferencesContext } from "@/lib/preferences-context";

/**
 * Liquid Glass tab bar background component.
 * On iOS: uses BlurView with a light/dark tint for the frosted glass look.
 * On Android/Web: falls back to a semi-transparent solid surface.
 */
function GlassTabBarBackground() {
  const colorScheme = useColorScheme();
  const colors = useColors();

  if (Platform.OS === "ios") {
    return (
      <BlurView
        intensity={85}
        tint={colorScheme === "dark" ? "dark" : "light"}
        experimentalBlurMethod="dimezisBlurView"
        style={StyleSheet.absoluteFill}
      />
    );
  }

  // Android / Web fallback: semi-transparent surface
  return (
    <View
      style={[
        StyleSheet.absoluteFill,
        {
          backgroundColor:
            colorScheme === "dark"
              ? "rgba(21,23,24,0.92)"
              : "rgba(255,255,255,0.92)",
        },
      ]}
    />
  );
}

export default function TabLayout() {
  const colors = useColors();
  const colorScheme = useColorScheme();
  const insets = useSafeAreaInsets();
  const bottomPadding = Platform.OS === "web" ? 12 : Math.max(insets.bottom, 8);
  const tabBarHeight = 56 + bottomPadding;
  const { prefs } = usePreferencesContext();
  const showReminders = prefs?.showReminders !== false;
  const showGarage = prefs?.showGarage !== false;

  // Border color adapts to scheme: subtle on glass
  const borderColor =
    colorScheme === "dark"
      ? "rgba(255,255,255,0.10)"
      : "rgba(0,0,0,0.08)";

  return (
    <Tabs
      screenOptions={{
        tabBarActiveTintColor: colors.primary,
        headerShown: false,
        tabBarButton: HapticTab,
        tabBarBackground: () => <GlassTabBarBackground />,
        tabBarStyle: {
          paddingTop: 8,
          paddingBottom: bottomPadding,
          height: tabBarHeight,
          // Transparent so the BlurView background shows through
          backgroundColor: "transparent",
          borderTopColor: borderColor,
          borderTopWidth: StyleSheet.hairlineWidth,
          // Elevation shadow on Android
          elevation: 16,
          shadowColor: "#000",
          shadowOffset: { width: 0, height: -2 },
          shadowOpacity: colorScheme === "dark" ? 0.4 : 0.08,
          shadowRadius: 12,
          position: "absolute",
        },
      }}
    >
      {/* ── Calculator (default / first tab) ── */}
      <Tabs.Screen
        name="calculator"
        options={{
          title: "Calculator",
          tabBarIcon: ({ color }) => (
            <IconSymbol size={26} name="fuelpump.fill" color={color} />
          ),
        }}
      />

      {/* ── Stations ── */}
      <Tabs.Screen
        name="stations"
        options={{
          title: "Stations",
          tabBarIcon: ({ color }) => (
            <IconSymbol size={26} name="map.fill" color={color} />
          ),
        }}
      />

      {/* ── Garage (conditionally shown based on preference) ── */}
      {showGarage && (
        <Tabs.Screen
          name="garage"
          options={{
            title: "Garage",
            tabBarIcon: ({ color }) => (
              <IconSymbol size={26} name="car.fill" color={color} />
            ),
          }}
        />
      )}

      {/* ── Reminders (conditionally shown based on preference) ── */}
      {showReminders && (
        <Tabs.Screen
          name="reminders"
          options={{
            title: "Reminders",
            tabBarIcon: ({ color }) => (
              <IconSymbol size={26} name="bell.fill" color={color} />
            ),
          }}
        />
      )}

      {/* ── More / Settings ── */}
      <Tabs.Screen
        name="settings"
        options={{
          title: "More",
          tabBarIcon: ({ color }) => (
            <IconSymbol size={26} name="ellipsis.circle.fill" color={color} />
          ),
        }}
      />

      {/* ── Hidden screens (routable but not shown in tab bar) ── */}
      <Tabs.Screen
        name="fuel-log"
        options={{
          href: null, // Fuel Log accessible via More tab → Fill-Up History
        }}
      />
      <Tabs.Screen
        name="blends"
        options={{
          href: null,
        }}
      />
    </Tabs>
  );
}

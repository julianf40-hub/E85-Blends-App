/**
 * Quick Start — shown on first launch only.
 * 5 slides: Welcome, Set Up Car, Home Screen, Location, You're Ready.
 * Completion is persisted in AsyncStorage so it only shows once.
 */
import React, { useRef, useState, useCallback } from "react";
import {
  View,
  Text,
  Pressable,
  StyleSheet,
  Dimensions,
  FlatList,
  Platform,
  Alert,
} from "react-native";
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withTiming,
  interpolate,
  Extrapolation,
  type SharedValue,
} from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import * as Location from "expo-location";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { router } from "expo-router";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import { savePreferences, loadPreferences } from "@/lib/preferences";

const { width: SCREEN_WIDTH } = Dimensions.get("window");
const ONBOARDING_KEY = "e85_onboarding_complete";

export async function hasCompletedOnboarding(): Promise<boolean> {
  try {
    const val = await AsyncStorage.getItem(ONBOARDING_KEY);
    return val === "true";
  } catch {
    return false;
  }
}

export async function markOnboardingComplete(): Promise<void> {
  await AsyncStorage.setItem(ONBOARDING_KEY, "true");
}

// ─── Slide definitions ────────────────────────────────────────────────────────

type SlideId = "welcome" | "vehicle" | "homescreen" | "location" | "ready";

interface Slide {
  id: SlideId;
  emoji: string;
  accent: string;
  title: string;
  subtitle: string;
  bullets?: string[];
  supportText?: string;
}

const SLIDES: Slide[] = [
  {
    id: "welcome",
    emoji: "⛽",
    accent: "#00C853",
    title: "Welcome to 85Blends",
    subtitle: "Plan your blend, find E85 stations, and keep track of your car — all in one place.",
    bullets: [
      "Calculate E85 + gas mixes",
      "Find nearby E85 stations",
      "Track fill-ups and reminders",
    ],
  },
  {
    id: "vehicle",
    emoji: "🚗",
    accent: "#FF6D00",
    title: "Set up your car",
    subtitle: "Add a vehicle so 85Blends can fill in your tank size, preferred octane, and default blend more quickly.",
    supportText: "You can always change this later in Garage.",
  },
  {
    id: "homescreen",
    emoji: "🏠",
    accent: "#00B0FF",
    title: "Choose your starting screen",
    subtitle: "Choose which screen opens first when you launch the app.",
  },
  {
    id: "location",
    emoji: "📍",
    accent: "#9C27B0",
    title: "Use location for nearby E85",
    subtitle: "Allow location access to find nearby E85 stations and make fill-up logging faster.",
    supportText: "You can still use the calculator without location access.",
  },
  {
    id: "ready",
    emoji: "✅",
    accent: "#00C853",
    title: "You're all set",
    subtitle: "Start with the calculator, find a nearby station, or finish setting up your car anytime in Garage.",
  },
];

// ─── Main Screen ──────────────────────────────────────────────────────────────

export default function OnboardingScreen() {
  const colors = useColors();
  const flatListRef = useRef<FlatList>(null);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [homeScreenChoice, setHomeScreenChoice] = useState<"calculator" | "garage">("calculator");
  const scrollX = useSharedValue(0);

  const currentSlide = SLIDES[currentIndex];
  const isLastSlide = currentIndex === SLIDES.length - 1;

  const goToIndex = useCallback((index: number) => {
    flatListRef.current?.scrollToIndex({ index, animated: true });
    setCurrentIndex(index);
  }, []);

  const handleSkip = useCallback(async () => {
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    await markOnboardingComplete();
    router.replace("/(tabs)/calculator" as never);
  }, []);

  const handleNext = useCallback(async () => {
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);

    // On homescreen slide — save the preference before advancing
    if (currentSlide.id === "homescreen") {
      try {
        const prefs = await loadPreferences();
        await savePreferences({ ...prefs, homeScreen: homeScreenChoice });
      } catch { /* non-fatal */ }
    }

    if (!isLastSlide) {
      goToIndex(currentIndex + 1);
    }
  }, [currentSlide.id, currentIndex, isLastSlide, homeScreenChoice, goToIndex]);

  const handleAddVehicle = useCallback(async () => {
    if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
    // Mark onboarding complete and send user straight to Garage to add their car
    await markOnboardingComplete();
    router.replace("/(tabs)/index" as never);
  }, []);

  const handleEnableLocation = useCallback(async () => {
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    try {
      const { status } = await Location.requestForegroundPermissionsAsync();
      if (status === "granted") {
        if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      }
    } catch { /* non-fatal */ }
    goToIndex(currentIndex + 1);
  }, [currentIndex, goToIndex]);

  const handleFinish = useCallback(async (destination: "calculator" | "stations" | "garage") => {
    if (Platform.OS !== "web") Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
    await markOnboardingComplete();
    if (destination === "calculator") {
      router.replace("/(tabs)/calculator" as never);
    } else if (destination === "stations") {
      router.replace("/(tabs)/stations" as never);
    } else {
      router.replace("/(tabs)/index" as never);
    }
  }, []);

  // ── Render bottom action area per slide ──────────────────────────────────────
  const renderActions = () => {
    switch (currentSlide.id) {
      case "welcome":
        return (
          <View style={styles.actionsCol}>
            <Pressable
              onPress={handleNext}
              style={({ pressed }) => [styles.ctaBtn, { backgroundColor: currentSlide.accent }, pressed && { opacity: 0.85, transform: [{ scale: 0.97 }] }]}
            >
              <Text style={styles.ctaBtnText}>Continue</Text>
              <IconSymbol name="arrow.right" size={18} color="#FFFFFF" />
            </Pressable>
            <Pressable onPress={handleSkip} style={({ pressed }) => [styles.ghostBtn, pressed && { opacity: 0.6 }]}>
              <Text style={[styles.ghostBtnText, { color: colors.muted }]}>Skip</Text>
            </Pressable>
          </View>
        );

      case "vehicle":
        return (
          <View style={styles.actionsCol}>
            <Pressable
              onPress={handleAddVehicle}
              style={({ pressed }) => [styles.ctaBtn, { backgroundColor: currentSlide.accent }, pressed && { opacity: 0.85, transform: [{ scale: 0.97 }] }]}
            >
              <IconSymbol name="car.fill" size={18} color="#FFFFFF" />
              <Text style={styles.ctaBtnText}>Set Up in Garage</Text>
            </Pressable>
            <Pressable onPress={handleNext} style={({ pressed }) => [styles.ghostBtn, pressed && { opacity: 0.6 }]}>
              <Text style={[styles.ghostBtnText, { color: colors.muted }]}>Skip for now</Text>
            </Pressable>
          </View>
        );

      case "homescreen":
        return (
          <View style={styles.actionsCol}>
            {/* Picker */}
            <View style={[styles.pickerCard, { backgroundColor: colors.surface, borderColor: colors.border }]}>
              <Pressable
                style={[styles.pickerRow, homeScreenChoice === "calculator" && { backgroundColor: currentSlide.accent + "18" }]}
                onPress={() => {
                  if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                  setHomeScreenChoice("calculator");
                }}
              >
                <Text style={styles.pickerEmoji}>🧮</Text>
                <View style={{ flex: 1 }}>
                  <Text style={[styles.pickerLabel, { color: colors.foreground }]}>Calculator</Text>
                  <Text style={[styles.pickerDesc, { color: colors.muted }]}>Best for quick blend calculations</Text>
                </View>
                {homeScreenChoice === "calculator" && (
                  <IconSymbol name="checkmark.circle.fill" size={22} color={currentSlide.accent} />
                )}
              </Pressable>
              <View style={[styles.divider, { backgroundColor: colors.border }]} />
              <Pressable
                style={[styles.pickerRow, homeScreenChoice === "garage" && { backgroundColor: currentSlide.accent + "18" }]}
                onPress={() => {
                  if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                  setHomeScreenChoice("garage");
                }}
              >
                <Text style={styles.pickerEmoji}>🚗</Text>
                <View style={{ flex: 1 }}>
                  <Text style={[styles.pickerLabel, { color: colors.foreground }]}>Garage</Text>
                  <Text style={[styles.pickerDesc, { color: colors.muted }]}>Overview of car, reminders & fill-ups</Text>
                </View>
                {homeScreenChoice === "garage" && (
                  <IconSymbol name="checkmark.circle.fill" size={22} color={currentSlide.accent} />
                )}
              </Pressable>
            </View>
            <Pressable
              onPress={handleNext}
              style={({ pressed }) => [styles.ctaBtn, { backgroundColor: currentSlide.accent }, pressed && { opacity: 0.85, transform: [{ scale: 0.97 }] }]}
            >
              <Text style={styles.ctaBtnText}>Continue</Text>
              <IconSymbol name="arrow.right" size={18} color="#FFFFFF" />
            </Pressable>
          </View>
        );

      case "location":
        return (
          <View style={styles.actionsCol}>
            <Pressable
              onPress={handleEnableLocation}
              style={({ pressed }) => [styles.ctaBtn, { backgroundColor: currentSlide.accent }, pressed && { opacity: 0.85, transform: [{ scale: 0.97 }] }]}
            >
              <IconSymbol name="location.fill" size={18} color="#FFFFFF" />
              <Text style={styles.ctaBtnText}>Enable Location</Text>
            </Pressable>
            <Pressable onPress={handleNext} style={({ pressed }) => [styles.ghostBtn, pressed && { opacity: 0.6 }]}>
              <Text style={[styles.ghostBtnText, { color: colors.muted }]}>Not now</Text>
            </Pressable>
          </View>
        );

      case "ready":
        return (
          <View style={styles.actionsCol}>
            <Pressable
              onPress={() => handleFinish("calculator")}
              style={({ pressed }) => [styles.ctaBtn, { backgroundColor: currentSlide.accent }, pressed && { opacity: 0.85, transform: [{ scale: 0.97 }] }]}
            >
              <Text style={styles.ctaBtnText}>Open Calculator</Text>
            </Pressable>
            <Pressable
              onPress={() => handleFinish("stations")}
              style={({ pressed }) => [styles.ctaBtnOutline, { borderColor: currentSlide.accent }, pressed && { opacity: 0.7 }]}
            >
              <Text style={[styles.ctaBtnOutlineText, { color: currentSlide.accent }]}>Find Stations</Text>
            </Pressable>
            <Pressable onPress={() => handleFinish("garage")} style={({ pressed }) => [styles.ghostBtn, pressed && { opacity: 0.6 }]}>
              <Text style={[styles.ghostBtnText, { color: colors.muted }]}>Go to Garage</Text>
            </Pressable>
          </View>
        );

      default:
        return null;
    }
  };

  return (
    <ScreenContainer edges={["top", "bottom", "left", "right"]} containerClassName="bg-background">
      {/* Skip button — visible on slides 1–3 */}
      {!isLastSlide && currentSlide.id !== "ready" && (
        <Pressable
          onPress={handleSkip}
          style={({ pressed }) => [styles.skipBtn, pressed && { opacity: 0.6 }]}
        >
          <Text style={[styles.skipText, { color: colors.muted }]}>Skip</Text>
        </Pressable>
      )}

      {/* Slides */}
      <FlatList
        ref={flatListRef}
        data={SLIDES}
        horizontal
        pagingEnabled
        showsHorizontalScrollIndicator={false}
        scrollEnabled={false}
        keyExtractor={(item) => item.id}
        onScroll={(e) => { scrollX.value = e.nativeEvent.contentOffset.x; }}
        renderItem={({ item, index }) => (
          <SlideView
            slide={item}
            index={index}
            scrollX={scrollX}
            colors={colors}
            homeScreenChoice={homeScreenChoice}
          />
        )}
      />

      {/* Dots */}
      <View style={styles.dotsRow}>
        {SLIDES.map((_, i) => {
          const isActive = i === currentIndex;
          return (
            <View
              key={i}
              style={[
                styles.dot,
                {
                  backgroundColor: isActive ? currentSlide.accent : colors.border,
                  width: isActive ? 24 : 8,
                },
              ]}
            />
          );
        })}
      </View>

      {/* Actions */}
      <View style={styles.footer}>
        {renderActions()}
      </View>
    </ScreenContainer>
  );
}

// ─── Slide View ───────────────────────────────────────────────────────────────

function SlideView({
  slide,
  index,
  scrollX,
  colors,
  homeScreenChoice,
}: {
  slide: Slide;
  index: number;
  scrollX: SharedValue<number>;
  colors: any;
  homeScreenChoice: "calculator" | "garage";
}) {
  const animatedStyle = useAnimatedStyle(() => {
    const inputRange = [
      (index - 1) * SCREEN_WIDTH,
      index * SCREEN_WIDTH,
      (index + 1) * SCREEN_WIDTH,
    ];
    const opacity = interpolate(scrollX.value, inputRange, [0.3, 1, 0.3], Extrapolation.CLAMP);
    const translateY = interpolate(scrollX.value, inputRange, [30, 0, 30], Extrapolation.CLAMP);
    return { opacity, transform: [{ translateY }] };
  });

  return (
    <View style={[styles.slide, { width: SCREEN_WIDTH }]}>
      <Animated.View style={[styles.slideContent, animatedStyle]}>
        {/* Emoji */}
        <View style={[styles.emojiContainer, { backgroundColor: slide.accent + "18" }]}>
          <Text style={styles.emoji}>{slide.emoji}</Text>
        </View>

        {/* Title + subtitle */}
        <Text style={[styles.slideTitle, { color: colors.foreground }]}>{slide.title}</Text>
        <Text style={[styles.slideSubtitle, { color: colors.muted }]}>{slide.subtitle}</Text>

        {/* Bullet points (welcome slide) */}
        {slide.bullets && (
          <View style={styles.bulletList}>
            {slide.bullets.map((b, i) => (
              <View key={i} style={styles.bulletRow}>
                <View style={[styles.bulletDot, { backgroundColor: slide.accent }]} />
                <Text style={[styles.bulletText, { color: colors.foreground }]}>{b}</Text>
              </View>
            ))}
          </View>
        )}

        {/* Support text */}
        {slide.supportText && (
          <Text style={[styles.supportText, { color: colors.muted }]}>{slide.supportText}</Text>
        )}
      </Animated.View>
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  skipBtn: {
    position: "absolute",
    top: 16,
    right: 20,
    zIndex: 10,
    paddingVertical: 8,
    paddingHorizontal: 12,
  },
  skipText: {
    fontSize: 15,
    fontWeight: "500",
  },
  slide: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: 32,
  },
  slideContent: {
    alignItems: "center",
    gap: 16,
    paddingBottom: 20,
  },
  emojiContainer: {
    width: 120,
    height: 120,
    borderRadius: 36,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 4,
  },
  emoji: {
    fontSize: 60,
  },
  slideTitle: {
    fontSize: 26,
    fontWeight: "800",
    textAlign: "center",
    lineHeight: 32,
  },
  slideSubtitle: {
    fontSize: 15,
    fontWeight: "400",
    textAlign: "center",
    lineHeight: 24,
    maxWidth: 300,
  },
  bulletList: {
    alignSelf: "stretch",
    gap: 10,
    marginTop: 4,
  },
  bulletRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
  },
  bulletDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
  },
  bulletText: {
    fontSize: 15,
    fontWeight: "500",
  },
  supportText: {
    fontSize: 13,
    textAlign: "center",
    fontStyle: "italic",
    marginTop: 4,
  },
  dotsRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 6,
    marginBottom: 16,
  },
  dot: {
    height: 8,
    borderRadius: 4,
  },
  footer: {
    paddingHorizontal: 24,
    paddingBottom: 32,
  },
  actionsCol: {
    gap: 12,
    alignItems: "stretch",
  },
  ctaBtn: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    paddingVertical: 16,
    borderRadius: 16,
  },
  ctaBtnText: {
    fontSize: 17,
    fontWeight: "700",
    color: "#FFFFFF",
  },
  ctaBtnOutline: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    paddingVertical: 15,
    borderRadius: 16,
    borderWidth: 1.5,
  },
  ctaBtnOutlineText: {
    fontSize: 17,
    fontWeight: "600",
  },
  ghostBtn: {
    alignItems: "center",
    paddingVertical: 10,
  },
  ghostBtnText: {
    fontSize: 15,
    fontWeight: "500",
  },
  pickerCard: {
    borderRadius: 14,
    borderWidth: 1,
    overflow: "hidden",
  },
  pickerRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingHorizontal: 16,
    paddingVertical: 14,
  },
  pickerEmoji: {
    fontSize: 24,
  },
  pickerLabel: {
    fontSize: 15,
    fontWeight: "600",
  },
  pickerDesc: {
    fontSize: 13,
    marginTop: 1,
  },
  divider: {
    height: 1,
  },
});

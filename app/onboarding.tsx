/**
 * Onboarding screen — shown on first launch only.
 * 4 slides: Welcome, Calculator, Stations, Garage.
 * Completion is persisted in AsyncStorage so it only shows once.
 */
import React, { useRef, useState } from "react";
import {
  View,
  Text,
  Pressable,
  StyleSheet,
  Dimensions,
  FlatList,
  Platform,
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
import AsyncStorage from "@react-native-async-storage/async-storage";
import { router } from "expo-router";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";

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

const SLIDES = [
  {
    id: "welcome",
    emoji: "⛽",
    title: "Welcome to 85Blends",
    subtitle:
      "The smart companion for flex-fuel drivers. Calculate perfect E85 blends, find nearby stations, and track your fuel savings.",
    cta: "Get Started",
    icon: "drop.fill" as const,
    accent: "#00C853",
  },
  {
    id: "calculator",
    emoji: "🧮",
    title: "Smart Blend Calculator",
    subtitle:
      "Tell us your tank size and current ethanol level. We'll calculate exactly how much E85 and gas to add for your target blend.",
    cta: "Next",
    icon: "drop.fill" as const,
    accent: "#00C853",
  },
  {
    id: "stations",
    emoji: "🗺️",
    title: "Find E85 Stations",
    subtitle:
      "Discover E85 stations near you. Prices shown are state averages from AFDC or prices you report at the pump — always verify at the station.",
    cta: "Next",
    icon: "map.fill" as const,
    accent: "#00B0FF",
  },
  {
    id: "garage",
    emoji: "🚗",
    title: "Set Up Your Garage",
    subtitle:
      "Add your flex-fuel vehicle to auto-fill your tank size and preferred blend. You can do this now or any time from the Garage tab.",
    cta: "Set Up My Car",
    icon: "car.2.fill" as const,
    accent: "#FF6D00",
  },
];

export default function OnboardingScreen() {
  const colors = useColors();
  const flatListRef = useRef<FlatList>(null);
  const [currentIndex, setCurrentIndex] = useState(0);
  const scrollX = useSharedValue(0);

  const handleNext = async () => {
    if (Platform.OS !== "web") {
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    }
    if (currentIndex < SLIDES.length - 1) {
      const nextIndex = currentIndex + 1;
      flatListRef.current?.scrollToIndex({ index: nextIndex, animated: true });
      setCurrentIndex(nextIndex);
    } else {
      await markOnboardingComplete();
      if (Platform.OS !== "web") {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      }
      // Navigate to Garage tab so user can immediately add their car
      // Garage tab is the `index` screen inside (tabs)
      router.replace("/(tabs)" as never);
    }
  };

  const handleSkipToHome = async () => {
    await markOnboardingComplete();
    // Default to Calculator on skip
    router.replace("/(tabs)/calculator" as never);
  };

  return (
    <ScreenContainer edges={["top", "bottom", "left", "right"]} containerClassName="bg-background">
      {/* Skip button — always visible except on last slide */}
      {currentIndex < SLIDES.length - 1 && (
        <Pressable
          onPress={handleSkipToHome}
          style={({ pressed }) => [styles.skipBtn, pressed && { opacity: 0.6 }]}
        >
          <Text style={[styles.skipText, { color: colors.muted }]}>Skip</Text>
        </Pressable>
      )}
      {/* On last slide, show a subtle "Maybe Later" link */}
      {currentIndex === SLIDES.length - 1 && (
        <Pressable
          onPress={handleSkipToHome}
          style={({ pressed }) => [styles.skipBtn, pressed && { opacity: 0.6 }]}
        >
          <Text style={[styles.skipText, { color: colors.muted }]}>Maybe Later</Text>
        </Pressable>
      )}

      {/* Slides */}
      <FlatList
        ref={flatListRef}
        data={SLIDES}
        horizontal
        pagingEnabled
        showsHorizontalScrollIndicator={false}
        scrollEnabled
        onMomentumScrollEnd={(e) => {
          const newIndex = Math.round(e.nativeEvent.contentOffset.x / SCREEN_WIDTH);
          if (newIndex !== currentIndex) setCurrentIndex(newIndex);
        }}
        keyExtractor={(item) => item.id}
        onScroll={(e) => {
          scrollX.value = e.nativeEvent.contentOffset.x;
        }}
        renderItem={({ item, index }) => (
          <SlideView
            slide={item}
            index={index}
            scrollX={scrollX}
            colors={colors}
          />
        )}
      />

      {/* Dots + CTA */}
      <View style={styles.footer}>
        {/* Pagination dots */}
        <View style={styles.dotsRow}>
          {SLIDES.map((_, i) => {
            const isActive = i === currentIndex;
            return (
              <View
                key={i}
                style={[
                  styles.dot,
                  {
                    backgroundColor: isActive
                      ? SLIDES[currentIndex].accent
                      : colors.border,
                    width: isActive ? 24 : 8,
                  },
                ]}
              />
            );
          })}
        </View>

        {/* CTA button */}
        <Pressable
          onPress={handleNext}
          style={({ pressed }) => [
            styles.ctaBtn,
            { backgroundColor: SLIDES[currentIndex].accent },
            pressed && { opacity: 0.85, transform: [{ scale: 0.97 }] },
          ]}
        >
          <Text style={styles.ctaBtnText}>{SLIDES[currentIndex].cta}</Text>
          <IconSymbol name="arrow.right" size={18} color="#FFFFFF" />
        </Pressable>
      </View>
    </ScreenContainer>
  );
}

function SlideView({
  slide,
  index,
  scrollX,
  colors,
}: {
  slide: (typeof SLIDES)[0];
  index: number;
  scrollX: SharedValue<number>;
  colors: any;
}) {
  const animatedStyle = useAnimatedStyle(() => {
    const inputRange = [
      (index - 1) * SCREEN_WIDTH,
      index * SCREEN_WIDTH,
      (index + 1) * SCREEN_WIDTH,
    ];
    const opacity = interpolate(
      scrollX.value,
      inputRange,
      [0.3, 1, 0.3],
      Extrapolation.CLAMP
    );
    const translateY = interpolate(
      scrollX.value,
      inputRange,
      [30, 0, 30],
      Extrapolation.CLAMP
    );
    return { opacity, transform: [{ translateY }] };
  });

  return (
    <View style={[styles.slide, { width: SCREEN_WIDTH }]}>
      <Animated.View style={[styles.slideContent, animatedStyle]}>
        {/* Emoji illustration */}
        <View
          style={[
            styles.emojiContainer,
            { backgroundColor: slide.accent + "18" },
          ]}
        >
          <Text style={styles.emoji}>{slide.emoji}</Text>
        </View>

        {/* Text */}
        <Text style={[styles.slideTitle, { color: colors.foreground }]}>
          {slide.title}
        </Text>
        <Text style={[styles.slideSubtitle, { color: colors.muted }]}>
          {slide.subtitle}
        </Text>
      </Animated.View>
    </View>
  );
}

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
    gap: 20,
    paddingBottom: 40,
  },
  emojiContainer: {
    width: 140,
    height: 140,
    borderRadius: 40,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 8,
  },
  emoji: {
    fontSize: 72,
  },
  slideTitle: {
    fontSize: 28,
    fontWeight: "800",
    textAlign: "center",
    lineHeight: 34,
  },
  slideSubtitle: {
    fontSize: 16,
    fontWeight: "400",
    textAlign: "center",
    lineHeight: 26,
    maxWidth: 320,
  },
  footer: {
    paddingHorizontal: 24,
    paddingBottom: 32,
    gap: 24,
    alignItems: "center",
  },
  dotsRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
  },
  dot: {
    height: 8,
    borderRadius: 4,
  },
  ctaBtn: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    width: "100%",
    paddingVertical: 16,
    borderRadius: 16,
  },
  ctaBtnText: {
    fontSize: 17,
    fontWeight: "700",
    color: "#FFFFFF",
  },
});

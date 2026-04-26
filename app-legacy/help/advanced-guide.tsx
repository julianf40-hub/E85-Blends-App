/**
 * Advanced Guide — accessible from More → Help & Support.
 * 14 sections covering all major app features in depth.
 * Uses the same accordion pattern as faq.tsx.
 */
import React, { useState, useCallback } from "react";
import {
  Text,
  View,
  ScrollView,
  Pressable,
  StyleSheet,
  Platform,
} from "react-native";
import Animated, {
  FadeIn,
  useAnimatedStyle,
  useSharedValue,
  withTiming,
} from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import { useRouter } from "expo-router";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";

// ─── Data ─────────────────────────────────────────────────────────────────────

interface GuideSection {
  id: string;
  emoji: string;
  title: string;
  body: string;
  bullets?: string[];
  note?: string;
}

interface GuideGroup {
  id: string;
  label: string;
  sections: GuideSection[];
}

const GUIDE_GROUPS: GuideGroup[] = [
  {
    id: "overview",
    label: "Overview",
    sections: [
  {
    id: "what",
    emoji: "⛽",
    title: "What 85Blends helps you do",
    body: "85Blends helps you plan fuel blends, find nearby E85 stations, save vehicle-specific defaults, log fill-ups, and track reminders.",
    bullets: [
      "A quick blend calculator",
      "A station finder",
      "A garage and fuel log",
      "A lightweight maintenance companion",
    ],
  },
  ],
  },
  {
    id: "calculator",
    label: "Calculator",
    sections: [
  {
    id: "calculator",
    emoji: "🧮",
    title: "Calculator basics",
    body: "The calculator estimates how much E85 and gasoline to add based on your tank size, current fuel level, current ethanol content, and target blend.",
    bullets: [
      "Tank Size — your fuel tank capacity",
      "Current Fuel Level — how much fuel is left",
      "Current Fuel Ethanol % — your current blend, if known",
      "Target Ethanol % — the blend you want to reach",
      "E85 Ethanol % — the actual ethanol content of the E85 pump",
      "Gas Ethanol % — often E0 or E10, depending on your fuel",
    ],
    note: "Results are estimates based on your inputs. Actual pump ethanol content and octane can vary.",
  },
  {
    id: "pump-mode",
    emoji: "⛽",
    title: "Pump Mode",
    body: "Pump Mode is designed for fast, one-handed use at the gas station. It simplifies the result into direct instructions:",
    bullets: [
      "Add X gal E85",
      "Add Y gal gasoline",
    ],
    note: "Use Pump Mode when you want the quickest answer without extra detail.",
  },
  {
    id: "octane",
    emoji: "🔢",
    title: "Estimated octane",
    body: "85Blends can estimate octane based on your fuel inputs and resulting blend.",
    note: "Estimated octane is a helpful approximation, not a lab-tested value. Use it as guidance, not as a guarantee. If your setup is tuned or fuel-sensitive, always use the assumptions recommended for your vehicle and tune.",
  },
  {
    id: "vehicle-defaults",
    emoji: "🚗",
    title: "Vehicle defaults",
    body: "Your active vehicle can make the calculator faster by filling in common values automatically.",
    bullets: [
      "Tank size",
      "Preferred octane",
      "Default target blend",
      "Gas ethanol %",
      "Odometer",
    ],
    note: "If you switch cars often, keep the correct active vehicle selected in Garage.",
  },
  {
    id: "saved-blends",
    emoji: "💾",
    title: "Saved Blends",
    body: "Saved Blends let you reuse your most common setups quickly.",
    bullets: [
      "Daily E50",
      "Street E60",
      "Track E70",
      "Winter E40",
    ],
    note: "Saved Blends are best for repeat use when you usually aim for the same target blend.",
  },
  ],
  },
  {
    id: "stations-log",
    label: "Stations & Fuel Log",
    sections: [
  {
    id: "fuel-log",
    emoji: "📋",
    title: "Fuel Log",
    body: "Fuel Log helps you track each fill-up in detail. Over time, this can help you understand your driving patterns and fuel costs.",
    bullets: [
      "Station used",
      "Gallons added",
      "Blend result",
      "Odometer",
      "Fuel prices",
      "Total cost",
      "Notes",
    ],
  },
  {
    id: "station-prices",
    emoji: "💰",
    title: "Understanding station prices",
    body: "Station pricing in 85Blends may come from different sources. Always check source labels before assuming a price is current or exact.",
    bullets: [
      "Your log — a price you logged yourself",
      "Community — a price shared anonymously by users",
      "Average — fallback or regional average data",
      "Stale — older data that may no longer be accurate",
    ],
    note: "Not every station has station-specific live pricing.",
  },
  {
    id: "community-prices",
    emoji: "🤝",
    title: "Community prices",
    body: "When enabled, anonymous user-submitted fuel prices can help improve station pricing data. Community prices should be treated as helpful real-world data, but not guaranteed live station pricing.",
    note: "Freshness, report count, and source labels help show how trustworthy the displayed price is.",
  },
  {
    id: "station-matching",
    emoji: "📍",
    title: "Station matching",
    body: "When logging a fill-up, 85Blends may try to detect a nearby station automatically.",
    bullets: [
      "The station field may be prefilled",
      "Prices can update your local station data",
      "You can still edit the station manually if needed",
    ],
    note: "If the detected station is wrong, just change it before saving.",
  },
  ],
  },
  {
    id: "settings-tips",
    label: "Settings & Tips",
    sections: [
  {
    id: "reminders",
    emoji: "🔔",
    title: "Reminders",
    body: "Reminders can be tied to a vehicle and triggered by mileage, date, or both.",
    bullets: [
      "Oil change",
      "Tire rotation",
      "Spark plugs",
      "Custom reminders",
    ],
    note: "Logging fill-ups and updating odometer values can help mileage-based reminders stay more accurate.",
  },
  {
    id: "navigation",
    emoji: "🗂️",
    title: "Navigation preferences",
    body: "You can customize how 85Blends feels when you open it.",
    bullets: [
      "Default home screen",
      "Which tabs appear in the tab bar",
      "Preferred directions app",
    ],
    note: "These settings are meant to help you shape the app around how you actually use it.",
  },
  {
    id: "best-practices",
    emoji: "✅",
    title: "Best practices",
    body: "For the best experience:",
    bullets: [
      "Save your main vehicle first",
      "Keep your active vehicle accurate",
      "Use Saved Blends for common setups",
      "Log fill-ups regularly if you want better tracking and reminders",
      "Verify tune and fuel-system compatibility before running higher ethanol blends",
    ],
  },
  {
    id: "safety",
    emoji: "⚠️",
    title: "Safety and accuracy",
    body: "85Blends is designed to be a helpful planning and tracking tool. Fuel blend calculations, octane estimates, and station price data are informational only and may vary based on real-world conditions.",
    note: "Always verify your setup, fuel quality, and tune requirements before making changes that could affect vehicle performance or reliability.",
  },
  ],
  },
];

// ─── Accordion Item ───────────────────────────────────────────────────────────

function AccordionItem({
  section,
  colors,
  isFirst,
  isLast,
}: {
  section: GuideSection;
  colors: any;
  isFirst: boolean;
  isLast: boolean;
}) {
  const [open, setOpen] = useState(false);
  const rotation = useSharedValue(0);

  const chevronStyle = useAnimatedStyle(() => ({
    transform: [{ rotate: `${rotation.value}deg` }],
  }));

  const toggle = useCallback(() => {
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    setOpen((prev) => {
      rotation.value = withTiming(prev ? 0 : 90, { duration: 200 });
      return !prev;
    });
  }, [rotation]);

  return (
    <View>
      {!isFirst && <View style={[styles.divider, { backgroundColor: colors.border }]} />}
      <Pressable
        onPress={toggle}
        style={({ pressed }) => [styles.accordionHeader, pressed && { opacity: 0.7 }]}
      >
        <View style={styles.accordionLeft}>
          <Text style={styles.sectionEmoji}>{section.emoji}</Text>
          <Text style={[styles.sectionTitle, { color: colors.foreground }]}>{section.title}</Text>
        </View>
        <Animated.View style={chevronStyle}>
          <IconSymbol name="chevron.right" size={16} color={colors.muted} />
        </Animated.View>
      </Pressable>

      {open && (
        <Animated.View entering={FadeIn.duration(200)} style={styles.accordionBody}>
          <Text style={[styles.bodyText, { color: colors.muted }]}>{section.body}</Text>

          {section.bullets && (
            <View style={styles.bulletList}>
              {section.bullets.map((b, i) => (
                <View key={i} style={styles.bulletRow}>
                  <View style={[styles.bulletDot, { backgroundColor: colors.primary }]} />
                  <Text style={[styles.bulletText, { color: colors.foreground }]}>{b}</Text>
                </View>
              ))}
            </View>
          )}

          {section.note && (
            <View style={[styles.noteBox, { backgroundColor: colors.warning + "14", borderColor: colors.warning + "40" }]}>
              <IconSymbol name="info.circle.fill" size={14} color={colors.warning} />
              <Text style={[styles.noteText, { color: colors.muted }]}>{section.note}</Text>
            </View>
          )}
        </Animated.View>
      )}
    </View>
  );
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function AdvancedGuideScreen() {
  const colors = useColors();
  const router = useRouter();

  return (
    <ScreenContainer containerClassName="bg-background">
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        {/* Header */}
        <Animated.View entering={FadeIn.duration(300)} style={styles.header}>
          <Pressable
            onPress={() => router.back()}
            style={({ pressed }) => [styles.backBtn, pressed && { opacity: 0.6 }]}
          >
            <IconSymbol name="chevron.left.forwardslash.chevron.right" size={20} color={colors.primary} />
            <Text style={[styles.backText, { color: colors.primary }]}>Help & Support</Text>
          </Pressable>

          <View style={styles.titleRow}>
            <Text style={styles.titleEmoji}>📖</Text>
            <View>
              <Text style={[styles.title, { color: colors.foreground }]}>Advanced Guide</Text>
              <Text style={[styles.subtitle, { color: colors.muted }]}>
                {GUIDE_GROUPS.reduce((acc, g) => acc + g.sections.length, 0)} topics · tap any section to expand
              </Text>
            </View>
          </View>
        </Animated.View>

        {/* Grouped Sections */}
        {GUIDE_GROUPS.map((group, gIndex) => (
          <Animated.View
            key={group.id}
            entering={FadeIn.duration(300).delay(80 + gIndex * 60)}
          >
            <Text style={[styles.groupLabel, { color: colors.muted }]}>{group.label.toUpperCase()}</Text>
            <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
              {group.sections.map((section, index) => (
                <AccordionItem
                  key={section.id}
                  section={section}
                  colors={colors}
                  isFirst={index === 0}
                  isLast={index === group.sections.length - 1}
                />
              ))}
            </View>
          </Animated.View>
        ))}

        {/* Footer note */}
        <Animated.View entering={FadeIn.duration(300).delay(200)} style={styles.footer}>
          <Text style={[styles.footerText, { color: colors.muted }]}>
            For quick answers, see Help & FAQ. For feedback, use Send Feedback.
          </Text>
        </Animated.View>
      </ScrollView>
    </ScreenContainer>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  scrollContent: {
    padding: 16,
    gap: 16,
    paddingBottom: 40,
  },
  header: {
    gap: 16,
    paddingBottom: 4,
  },
  backBtn: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    alignSelf: "flex-start",
  },
  backText: {
    fontSize: 15,
    fontWeight: "500",
  },
  titleRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
  },
  titleEmoji: {
    fontSize: 40,
  },
  title: {
    fontSize: 24,
    fontWeight: "800",
    lineHeight: 30,
  },
  subtitle: {
    fontSize: 13,
    marginTop: 2,
  },
  groupLabel: {
    fontSize: 11,
    fontWeight: "700",
    letterSpacing: 0.8,
    marginBottom: 8,
    marginLeft: 4,
  },
  card: {
    borderRadius: 16,
    borderWidth: 1,
    overflow: "hidden",
  },
  divider: {
    height: 1,
    marginLeft: 16,
  },
  accordionHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingVertical: 14,
  },
  accordionLeft: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    flex: 1,
  },
  sectionEmoji: {
    fontSize: 20,
  },
  sectionTitle: {
    fontSize: 15,
    fontWeight: "600",
    flex: 1,
  },
  accordionBody: {
    paddingHorizontal: 16,
    paddingBottom: 16,
    gap: 12,
  },
  bodyText: {
    fontSize: 14,
    lineHeight: 22,
  },
  bulletList: {
    gap: 8,
  },
  bulletRow: {
    flexDirection: "row",
    alignItems: "flex-start",
    gap: 10,
  },
  bulletDot: {
    width: 6,
    height: 6,
    borderRadius: 3,
    marginTop: 7,
  },
  bulletText: {
    fontSize: 14,
    lineHeight: 22,
    flex: 1,
  },
  noteBox: {
    flexDirection: "row",
    alignItems: "flex-start",
    gap: 8,
    padding: 12,
    borderRadius: 10,
    borderWidth: 1,
  },
  noteText: {
    fontSize: 13,
    lineHeight: 20,
    flex: 1,
  },
  footer: {
    alignItems: "center",
    paddingTop: 4,
  },
  footerText: {
    fontSize: 13,
    textAlign: "center",
    lineHeight: 20,
  },
});

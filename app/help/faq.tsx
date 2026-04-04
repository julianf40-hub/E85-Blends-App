import { useState } from "react";
import {
  Text,
  View,
  ScrollView,
  Pressable,
  StyleSheet,
  Platform,
} from "react-native";
import Animated, { FadeIn, useAnimatedStyle, useSharedValue, withTiming } from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import { useRouter } from "expo-router";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";

// ─── FAQ Data ─────────────────────────────────────────────────────────────────

interface FAQItem {
  q: string;
  a: string;
}

interface FAQSection {
  title: string;
  icon: string;
  items: FAQItem[];
}

const FAQ_SECTIONS: FAQSection[] = [
  {
    title: "Calculator",
    icon: "⛽",
    items: [
      {
        q: "How does the blend calculator work?",
        a: "Enter your tank size, how much fuel is currently in the tank, and your target ethanol percentage. The calculator estimates how many gallons of E85 and regular gas to add to reach your target blend. Results are estimates based on your inputs — small measurement errors at the pump will shift the actual blend.",
      },
      {
        q: "What is Pump Mode?",
        a: "Pump Mode gives you step-by-step at-the-pump instructions. It tells you which fuel to add first, how many gallons of each, and confirms your estimated final blend. Designed to be used hands-free while fueling. Always verify the pump meter matches the suggested amounts.",
      },
      {
        q: "What should I enter for Gas Ethanol %?",
        a: "Most premium 91/93 octane gas in the US contains 0% ethanol. Regular 87 octane often contains 10% ethanol (E10). Check the pump label — it is required by law to disclose ethanol content. When in doubt, use 0% for premium and 10% for regular. Using the wrong value will shift your blend result.",
      },
      {
        q: "How accurate are the blend results?",
        a: "The calculator uses the standard ethanol mixing formula. Accuracy depends on the precision of your inputs. E85 ethanol content also varies by season and region (typically 51–83%, not always exactly 85%). For critical tuning applications, verify your actual ethanol content with an ethanol content analyzer.",
      },
      {
        q: "Why does my result say I need more E85 than expected?",
        a: "If your current tank already has ethanol in it, the calculator accounts for that. The higher your starting ethanol %, the less E85 you need to add. Make sure the \"Current Ethanol %\" field reflects what's actually in your tank.",
      },
      {
        q: "How do I save a blend?",
        a: "After calculating, tap \"Save This Blend\" and give it an optional name. Saved blends appear in the Fuel Log tab under Saved Blends, and can be reloaded into the calculator any time.",
      },
    ],
  },
  {
    title: "Fuel Log",
    icon: "📋",
    items: [
      {
        q: "What does the Fuel Log track?",
        a: "Each fill-up entry records the date, station, odometer, E85 gallons, gas gallons, price paid, and computed ethanol %. The log calculates your average MPG, total spend, and average blend over time. MPG figures are estimates based on odometer readings you enter.",
      },
      {
        q: "How is MPG calculated?",
        a: "MPG is calculated from consecutive fill-ups: miles driven (odometer difference) divided by total gallons added. At least two fill-ups are needed before MPG appears. Ethanol blends typically reduce MPG compared to pure gasoline — this is normal and expected.",
      },
      {
        q: "Can I log a fill-up directly from the calculator?",
        a: "Yes. After calculating a blend, tap \"Log This Fill-Up\" to pre-fill the entry with your blend details. You can add the station, odometer, and prices before saving.",
      },
    ],
  },
  {
    title: "Reminders",
    icon: "🔔",
    items: [
      {
        q: "How do maintenance reminders work?",
        a: "You can set reminders by date, mileage, or both. When your odometer (updated via fuel log or manually) crosses the mileage threshold, or the date arrives, the reminder shows as due on the Reminders tab. Reminders are informational — always follow your vehicle manufacturer's recommended service intervals.",
      },
      {
        q: "Can reminders repeat?",
        a: "Yes. When creating a reminder, choose a repeat interval such as every 3,000 miles or every 6 months. After you mark a reminder complete, it automatically advances to the next due date or mileage.",
      },
      {
        q: "How does the app know my current mileage?",
        a: "The app reads the odometer from your most recent fuel log entry. You can also update it manually from the Garage tab using the odometer update button on your active vehicle card. Mileage is not read from your vehicle automatically.",
      },
    ],
  },
  {
    title: "Garage & Vehicles",
    icon: "🚗",
    items: [
      {
        q: "How do I add a vehicle?",
        a: "Go to the Garage tab and tap the + button. Enter your vehicle's year, make, model, tank size, and other details. You can add multiple vehicles and switch between them.",
      },
      {
        q: "What does \"Active Vehicle\" mean?",
        a: "The active vehicle is the one the calculator and reminders use by default. Its tank size auto-fills the calculator, and its odometer drives mileage-based reminders. Tap \"Set Active\" on any vehicle card to switch.",
      },
      {
        q: "Is my vehicle compatible with E85 or high-ethanol blends?",
        a: "Only Flex Fuel Vehicles (FFVs) are factory-certified for E85. Non-FFV vehicles may require fuel system upgrades and an ethanol-compatible tune before running high-ethanol blends. Always verify compatibility with a qualified tuner or mechanic before fueling with E85.",
      },
      {
        q: "Can I store the Gas Ethanol % per vehicle?",
        a: "Yes. When editing a vehicle, set the \"Gas Ethanol %\" field to match the fuel you typically use (e.g. 0% for premium, 10% for E10 regular). The calculator will auto-fill from this value.",
      },
    ],
  },
];

// ─── Accordion Item ────────────────────────────────────────────────────────────

function AccordionItem({ item, colors }: { item: FAQItem; colors: ReturnType<typeof useColors> }) {
  const [open, setOpen] = useState(false);

  return (
    <View>
      <Pressable
        onPress={() => {
          if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
          setOpen((v) => !v);
        }}
        style={({ pressed }) => [
          styles.questionRow,
          pressed && { opacity: 0.75 },
        ]}
      >
        <Text style={[styles.questionText, { color: colors.foreground, flex: 1 }]}>
          {item.q}
        </Text>
        <IconSymbol
          name={open ? "chevron.down" : "chevron.right"}
          size={14}
          color={colors.muted}
        />
      </Pressable>
      {open && (
        <Animated.View entering={FadeIn.duration(180)} style={[styles.answerBox, { backgroundColor: colors.primary + "0D" }]}>
          <Text style={[styles.answerText, { color: colors.muted }]}>{item.a}</Text>
        </Animated.View>
      )}
    </View>
  );
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function FAQScreen() {
  const colors = useColors();
  const router = useRouter();

  return (
    <ScreenContainer>
      {/* Header */}
      <View style={[styles.header, { borderBottomColor: colors.border }]}>
        <Pressable
          onPress={() => router.back()}
          style={({ pressed }) => [styles.backBtn, pressed && { opacity: 0.6 }]}
        >
          <IconSymbol name="chevron.left" size={20} color={colors.primary} />
          <Text style={[styles.backLabel, { color: colors.primary }]}>More</Text>
        </Pressable>
        <Text style={[styles.headerTitle, { color: colors.foreground }]}>Help & FAQ</Text>
        <View style={styles.backBtn} />
      </View>

      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        <Text style={[styles.intro, { color: colors.muted }]}>
          Common questions about using 85Blends.
        </Text>

        {FAQ_SECTIONS.map((section) => (
          <View key={section.title} style={styles.section}>
            <Text style={[styles.sectionTitle, { color: colors.foreground }]}>
              {section.icon}  {section.title}
            </Text>
            <View style={[styles.card, { backgroundColor: colors.surface, borderColor: colors.border }]}>
              {section.items.map((item, idx) => (
                <View key={idx}>
                  {idx > 0 && <View style={[styles.divider, { backgroundColor: colors.border }]} />}
                  <AccordionItem item={item} colors={colors} />
                </View>
              ))}
            </View>
          </View>
        ))}

        <View style={{ height: 40 }} />
      </ScrollView>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingVertical: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  backBtn: {
    flexDirection: "row",
    alignItems: "center",
    gap: 4,
    minWidth: 64,
  },
  backLabel: { fontSize: 15, fontWeight: "500" },
  headerTitle: { fontSize: 17, fontWeight: "700" },
  scrollContent: { paddingBottom: 24 },
  intro: { fontSize: 14, lineHeight: 20, paddingHorizontal: 20, paddingVertical: 16 },
  section: { paddingHorizontal: 16, marginBottom: 24 },
  sectionTitle: { fontSize: 16, fontWeight: "700", marginBottom: 10, letterSpacing: -0.2 },
  card: { borderRadius: 16, borderWidth: StyleSheet.hairlineWidth, overflow: "hidden" },
  divider: { height: StyleSheet.hairlineWidth, marginHorizontal: 16 },
  questionRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 16,
    paddingVertical: 14,
    gap: 10,
  },
  questionText: { fontSize: 14, fontWeight: "600", lineHeight: 20 },
  answerBox: { paddingHorizontal: 16, paddingBottom: 14, paddingTop: 2 },
  answerText: { fontSize: 13, lineHeight: 20 },
});

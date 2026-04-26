import {
  Text,
  View,
  ScrollView,
  Pressable,
  StyleSheet,
  Linking,
  Platform,
} from "react-native";
import Animated, { FadeIn, FadeInDown } from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import { useRouter } from "expo-router";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";

// ─── Mock Product Data ────────────────────────────────────────────────────────
// Source: product names and categories inspired by rvpsupply.com
// Images: placeholder blocks — swap for real Image URIs when sourcing actual affiliate products

interface MockProduct {
  id: string;
  name: string;
  subtitle: string;
  category: string;
  price: string;
  emoji: string;
  accentColor: string;
  url: string; // placeholder — real affiliate URL goes here
}

interface GearSection {
  id: string;
  title: string;
  icon: string;
  products: MockProduct[];
}

const GEAR_SECTIONS: GearSection[] = [
  {
    id: "fuel_tools",
    title: "Fuel Tools",
    icon: "⛽",
    products: [
      {
        id: "ethanol_tester",
        name: "Ethanol Content Analyzer",
        subtitle: "Test your E85 percentage on the spot before fueling",
        category: "Fuel Testing",
        price: "~$24",
        emoji: "🔬",
        accentColor: "#F59E0B",
        url: "https://rvpsupply.com",
      },
      {
        id: "fuel_can",
        name: "No-Spill Safety Fuel Can — 5 Gal",
        subtitle: "HDPE sealed container with child-safe nozzle",
        category: "Fuel Storage",
        price: "~$38",
        emoji: "🪣",
        accentColor: "#EF4444",
        url: "https://rvpsupply.com",
      },
      {
        id: "transfer_pump",
        name: "Hand-Operated Transfer Pump",
        subtitle: "Siphon pump for quick fuel transfers and drain jobs",
        category: "Fuel Handling",
        price: "~$18",
        emoji: "🔩",
        accentColor: "#10B981",
        url: "https://rvpsupply.com",
      },
    ],
  },
  {
    id: "maintenance",
    title: "Maintenance Supplies",
    icon: "🔧",
    products: [
      {
        id: "air_filter_kit",
        name: "Air Filter Cleaner & Recharger Kit",
        subtitle: "Restore high-flow performance filters to factory spec",
        category: "Air & Intake",
        price: "~$14",
        emoji: "💨",
        accentColor: "#3B82F6",
        url: "https://rvpsupply.com",
      },
      {
        id: "nitrile_gloves",
        name: "Nitrile Disposable Gloves — 100 pk",
        subtitle: "Chemical-resistant, powder-free, one-size-fits-most",
        category: "Safety",
        price: "~$12",
        emoji: "🧤",
        accentColor: "#14B8A6",
        url: "https://rvpsupply.com",
      },
      {
        id: "shop_towels",
        name: "Microfiber Shop Towels — 12 pk",
        subtitle: "Lint-free, reusable, safe on painted surfaces",
        category: "Cleaning",
        price: "~$16",
        emoji: "🧹",
        accentColor: "#8B5CF6",
        url: "https://rvpsupply.com",
      },
    ],
  },
  {
    id: "garage_essentials",
    title: "Garage Essentials",
    icon: "🏎️",
    products: [
      {
        id: "obd2_scanner",
        name: "Bluetooth OBD2 Scanner",
        subtitle: "Wireless diagnostics for iOS and Android — reads & clears codes",
        category: "Diagnostics",
        price: "~$29",
        emoji: "📡",
        accentColor: "#6366F1",
        url: "https://rvpsupply.com",
      },
      {
        id: "tire_gauge",
        name: "Digital Tire Pressure Gauge",
        subtitle: "Backlit display, 0–150 PSI, easy bleed valve",
        category: "Tires",
        price: "~$15",
        emoji: "🔘",
        accentColor: "#F97316",
        url: "https://rvpsupply.com",
      },
      {
        id: "work_light",
        name: "LED Rechargeable Work Light",
        subtitle: "2000-lumen foldable light with magnetic base and USB-C charging",
        category: "Lighting",
        price: "~$32",
        emoji: "💡",
        accentColor: "#EAB308",
        url: "https://rvpsupply.com",
      },
    ],
  },
];

// ─── Product Card ─────────────────────────────────────────────────────────────

function ProductCard({ product, colors }: { product: MockProduct; colors: ReturnType<typeof useColors> }) {
  const handleOpen = () => {
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    Linking.openURL(product.url).catch(() => {});
  };

  return (
    <View style={[styles.productCard, { backgroundColor: colors.surface, borderColor: colors.border }]}>
      {/* Image placeholder — swap for <Image source={{ uri: product.imageUrl }} /> */}
      <View style={[styles.productImageBlock, { backgroundColor: product.accentColor + "18" }]}>
        <Text style={styles.productEmoji}>{product.emoji}</Text>
      </View>

      {/* Info */}
      <View style={styles.productInfo}>
        <View style={styles.productHeader}>
          <Text style={[styles.productCategory, { color: product.accentColor }]}>
            {product.category}
          </Text>
          <Text style={[styles.productPrice, { color: colors.muted }]}>{product.price}</Text>
        </View>
        <Text style={[styles.productName, { color: colors.foreground }]} numberOfLines={2}>
          {product.name}
        </Text>
        <Text style={[styles.productSubtitle, { color: colors.muted }]} numberOfLines={2}>
          {product.subtitle}
        </Text>

        {/* CTA */}
        <Pressable
          onPress={handleOpen}
          style={({ pressed }) => [
            styles.viewBtn,
            { borderColor: product.accentColor + "50", opacity: pressed ? 0.7 : 1 },
          ]}
        >
          <Text style={[styles.viewBtnText, { color: product.accentColor }]}>View Product</Text>
          <IconSymbol name="arrow.up.right" size={13} color={product.accentColor} />
        </Pressable>

        <Text style={[styles.mockTag, { color: colors.muted }]}>Mock affiliate link</Text>
      </View>
    </View>
  );
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function GearScreen() {
  const colors = useColors();
  const router = useRouter();

  return (
    <ScreenContainer>
      {/* Header */}
      <View style={[styles.header, { borderBottomColor: colors.border }]}>
        {router.canGoBack() ? (
          <Pressable
            onPress={() => router.back()}
            style={({ pressed }) => [styles.backBtn, pressed && { opacity: 0.6 }]}
          >
            <IconSymbol name="chevron.left" size={20} color={colors.primary} />
            <Text style={[styles.backLabel, { color: colors.primary }]}>More</Text>
          </Pressable>
        ) : (
          <View style={styles.backBtn} />
        )}
        <Text style={[styles.headerTitle, { color: colors.foreground }]}>Recommended Gear</Text>
        <View style={styles.backBtn} />
      </View>

      <ScrollView
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        <Animated.View entering={FadeIn.duration(300)}>
          <Text style={[styles.intro, { color: colors.muted }]}>
            Tools and supplies that pair well with fuel blending, maintenance, and everyday garage use.
          </Text>
        </Animated.View>

        {GEAR_SECTIONS.map((section, sIdx) => (
          <Animated.View
            key={section.id}
            entering={FadeInDown.duration(280).delay(sIdx * 80)}
            style={styles.section}
          >
            <Text style={[styles.sectionTitle, { color: colors.foreground }]}>
              {section.icon}{"  "}{section.title}
            </Text>
            {section.products.map((product) => (
              <ProductCard key={product.id} product={product} colors={colors} />
            ))}
          </Animated.View>
        ))}

        {/* Footer disclosure */}
        <View style={[styles.footer, { borderTopColor: colors.border }]}>
          <IconSymbol name="info.circle" size={14} color={colors.muted} />
          <Text style={[styles.footerText, { color: colors.muted }]}>
            Some links may eventually become affiliate links. This section is currently a mockup for testing only. Products sourced from rvpsupply.com.
          </Text>
        </View>

        <View style={{ height: 40 }} />
      </ScrollView>
    </ScreenContainer>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  // Header
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

  // Scroll
  scrollContent: { paddingBottom: 24 },
  intro: {
    fontSize: 14,
    lineHeight: 20,
    paddingHorizontal: 20,
    paddingVertical: 16,
  },

  // Section
  section: {
    paddingHorizontal: 16,
    marginBottom: 28,
  },
  sectionTitle: {
    fontSize: 16,
    fontWeight: "700",
    marginBottom: 12,
    letterSpacing: -0.2,
  },

  // Product card
  productCard: {
    flexDirection: "row",
    borderRadius: 14,
    borderWidth: StyleSheet.hairlineWidth,
    overflow: "hidden",
    marginBottom: 10,
    padding: 12,
    gap: 12,
  },
  productImageBlock: {
    width: 72,
    height: 72,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
  },
  productEmoji: {
    fontSize: 28,
  },
  productInfo: {
    flex: 1,
    gap: 3,
  },
  productHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
  },
  productCategory: {
    fontSize: 11,
    fontWeight: "700",
    letterSpacing: 0.3,
    textTransform: "uppercase",
  },
  productPrice: {
    fontSize: 12,
    fontWeight: "500",
  },
  productName: {
    fontSize: 14,
    fontWeight: "600",
    lineHeight: 19,
    marginTop: 1,
  },
  productSubtitle: {
    fontSize: 12,
    lineHeight: 17,
  },

  // CTA button
  viewBtn: {
    flexDirection: "row",
    alignItems: "center",
    gap: 4,
    alignSelf: "flex-start",
    marginTop: 6,
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 6,
    borderWidth: 1,
  },
  viewBtnText: {
    fontSize: 12,
    fontWeight: "600",
  },
  mockTag: {
    fontSize: 10,
    marginTop: 3,
    opacity: 0.6,
  },

  // Footer
  footer: {
    flexDirection: "row",
    alignItems: "flex-start",
    gap: 8,
    marginHorizontal: 16,
    marginTop: 8,
    paddingTop: 16,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  footerText: {
    fontSize: 12,
    lineHeight: 17,
    flex: 1,
    opacity: 0.7,
  },
});

import React, { useCallback, useRef, useState } from "react";
import {
  Modal,
  View,
  Text,
  TextInput,
  Pressable,
  StyleSheet,
  Platform,
  KeyboardAvoidingView,
  ScrollView,
} from "react-native";
import { useColors } from "@/hooks/use-colors";
import { IconSymbol } from "./ui/icon-symbol";

export interface PriceUpdateModalProps {
  visible: boolean;
  stationName: string;
  onClose: () => void;
  onSubmit: (
    e85Price?: number,
    octane87Price?: number,
    octane89Price?: number,
    octane9194Price?: number
  ) => void;
  isLoading?: boolean;
}

const FUEL_GRADES = [
  { id: "e85", label: "E85", color: "#10B981", placeholder: "2.63" },
  { id: "octane87", label: "87 Octane", color: "#3B82F6", placeholder: "3.14" },
  { id: "octane89", label: "89 Octane", color: "#F59E0B", placeholder: "3.29" },
  { id: "octane9194", label: "91/94 Oct", color: "#EF4444", placeholder: "3.49" },
] as const;

/** Only allow digits and one decimal point */
function sanitizePrice(text: string): string {
  let cleaned = text.replace(/,/g, ".");
  cleaned = cleaned.replace(/[^\d.]/g, "");
  const dotIndex = cleaned.indexOf(".");
  if (dotIndex !== -1) {
    cleaned =
      cleaned.substring(0, dotIndex + 1) +
      cleaned.substring(dotIndex + 1).replace(/\./g, "");
  }
  return cleaned;
}

export function PriceUpdateModal({
  visible,
  stationName,
  onClose,
  onSubmit,
  isLoading = false,
}: PriceUpdateModalProps) {
  const colors = useColors();
  const [prices, setPrices] = useState({
    e85: "",
    octane87: "",
    octane89: "",
    octane9194: "",
  });

  // Refs for each input to manage focus
  const inputRefs = useRef<Record<string, TextInput | null>>({});

  const handleSubmit = useCallback(() => {
    const e85 = prices.e85 ? parseFloat(prices.e85) : undefined;
    const octane87 = prices.octane87 ? parseFloat(prices.octane87) : undefined;
    const octane89 = prices.octane89 ? parseFloat(prices.octane89) : undefined;
    const octane9194 = prices.octane9194
      ? parseFloat(prices.octane9194)
      : undefined;

    if (!e85 && !octane87 && !octane89 && !octane9194) return;

    onSubmit(e85, octane87, octane89, octane9194);
    setPrices({ e85: "", octane87: "", octane89: "", octane9194: "" });
  }, [prices, onSubmit]);

  const handleClose = useCallback(() => {
    setPrices({ e85: "", octane87: "", octane89: "", octane9194: "" });
    onClose();
  }, [onClose]);

  const handlePriceChange = useCallback((fuelType: string, text: string) => {
    const sanitized = sanitizePrice(text);
    setPrices((prev) => ({ ...prev, [fuelType]: sanitized }));
  }, []);

  /** Insert decimal point into the active input field */
  const handleDecimalPress = useCallback(
    (gradeId: string) => {
      const currentVal = prices[gradeId as keyof typeof prices] || "";
      if (!currentVal.includes(".")) {
        const newVal = currentVal === "" ? "0." : currentVal + ".";
        setPrices((prev) => ({ ...prev, [gradeId]: newVal }));
        // Re-focus the input
        inputRefs.current[gradeId]?.focus();
      }
    },
    [prices]
  );

  if (!visible) return null;

  return (
    <Modal
      visible={visible}
      transparent
      animationType="slide"
      onRequestClose={handleClose}
    >
      <KeyboardAvoidingView
        style={styles.keyboardView}
        behavior={Platform.OS === "ios" ? "padding" : "height"}
      >
        <View style={styles.overlay}>
          <Pressable style={styles.overlayTouchable} onPress={handleClose} />

          <View
            style={[
              styles.sheet,
              {
                backgroundColor: colors.surface,
                borderColor: colors.border,
              },
            ]}
          >
            {/* Header */}
            <View style={[styles.header, { borderBottomColor: colors.border }]}>
              <View style={styles.headerLeft}>
                <Text style={[styles.title, { color: colors.foreground }]}>
                  Update Fuel Prices
                </Text>
                <Text
                  style={[styles.subtitle, { color: colors.muted }]}
                  numberOfLines={1}
                >
                  {stationName}
                </Text>
              </View>
              <Pressable
                onPress={handleClose}
                style={({ pressed }) => [
                  styles.closeBtn,
                  {
                    backgroundColor: colors.background,
                    opacity: pressed ? 0.7 : 1,
                  },
                ]}
              >
                <IconSymbol name="xmark" size={16} color={colors.foreground} />
              </Pressable>
            </View>

            {/* Scrollable content area for fuel grade inputs */}
            <ScrollView
              style={styles.scrollArea}
              contentContainerStyle={styles.scrollContent}
              keyboardShouldPersistTaps="handled"
              showsVerticalScrollIndicator={false}
            >
              {/* Fuel Grade Inputs */}
              {FUEL_GRADES.map((grade) => (
                <View key={grade.id} style={styles.gradeRow}>
                  <View style={styles.gradeLabel}>
                    <View
                      style={[styles.dot, { backgroundColor: grade.color }]}
                    />
                    <Text
                      style={[styles.gradeName, { color: colors.foreground }]}
                    >
                      {grade.label}
                    </Text>
                  </View>
                  <View style={styles.inputGroup}>
                    <View
                      style={[
                        styles.priceField,
                        {
                          borderColor: colors.border,
                          backgroundColor: colors.background,
                        },
                      ]}
                    >
                      <Text style={[styles.dollar, { color: colors.muted }]}>
                        $
                      </Text>
                      <TextInput
                        ref={(ref) => {
                          inputRefs.current[grade.id] = ref;
                        }}
                        style={[styles.priceInput, { color: colors.foreground }]}
                        placeholder={grade.placeholder}
                        placeholderTextColor={colors.muted}
                        keyboardType="default"
                        autoCapitalize="none"
                        autoCorrect={false}
                        value={prices[grade.id as keyof typeof prices]}
                        onChangeText={(text) =>
                          handlePriceChange(grade.id, text)
                        }
                        editable={!isLoading}
                        maxLength={6}
                        returnKeyType="done"
                      />
                      <Text style={[styles.perGal, { color: colors.muted }]}>
                        /gal
                      </Text>
                    </View>
                    {/* Decimal point button */}
                    <Pressable
                      onPress={() => handleDecimalPress(grade.id)}
                      style={({ pressed }) => [
                        styles.decimalBtn,
                        {
                          backgroundColor: grade.color + "20",
                          borderColor: grade.color + "40",
                        },
                        pressed && { opacity: 0.6 },
                      ]}
                    >
                      <Text
                        style={[styles.decimalBtnText, { color: grade.color }]}
                      >
                        .
                      </Text>
                    </Pressable>
                  </View>
                </View>
              ))}

              {/* Info */}
              <View
                style={[
                  styles.infoRow,
                  {
                    backgroundColor: colors.primary + "12",
                    borderColor: colors.primary + "30",
                  },
                ]}
              >
                <IconSymbol
                  name="info.circle.fill"
                  size={14}
                  color={colors.primary}
                />
                <Text style={[styles.infoText, { color: colors.muted }]}>
                  Enter prices you see at the pump. Leave blank to skip a grade.
                </Text>
              </View>
            </ScrollView>

            {/* Buttons */}
            <View style={[styles.footer, { borderTopColor: colors.border }]}>
              <Pressable
                onPress={handleClose}
                disabled={isLoading}
                style={({ pressed }) => [
                  styles.cancelBtn,
                  {
                    backgroundColor: colors.background,
                    borderColor: colors.border,
                    opacity: pressed ? 0.7 : 1,
                  },
                ]}
              >
                <Text
                  style={[styles.cancelText, { color: colors.foreground }]}
                >
                  Cancel
                </Text>
              </Pressable>
              <Pressable
                onPress={handleSubmit}
                disabled={isLoading}
                style={({ pressed }) => [
                  styles.saveBtn,
                  {
                    backgroundColor: colors.primary,
                    opacity: pressed || isLoading ? 0.7 : 1,
                  },
                ]}
              >
                <IconSymbol name="checkmark" size={16} color="#fff" />
                <Text style={styles.saveText}>
                  {isLoading ? "Saving..." : "Save Prices"}
                </Text>
              </Pressable>
            </View>
          </View>
        </View>
      </KeyboardAvoidingView>
    </Modal>
  );
}

const styles = StyleSheet.create({
  keyboardView: {
    flex: 1,
  },
  overlay: {
    flex: 1,
    justifyContent: "flex-end",
    backgroundColor: "rgba(0,0,0,0.5)",
  },
  overlayTouchable: {
    flex: 1,
  },
  sheet: {
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    borderTopWidth: 1,
    minHeight: 420,
    maxHeight: "85%",
    paddingBottom: Platform.OS === "ios" ? 34 : 16,
  },
  header: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 20,
    paddingTop: 16,
    paddingBottom: 14,
    borderBottomWidth: 1,
  },
  headerLeft: {
    flex: 1,
    marginRight: 12,
  },
  title: {
    fontSize: 18,
    fontWeight: "700",
  },
  subtitle: {
    fontSize: 13,
    marginTop: 2,
  },
  closeBtn: {
    width: 30,
    height: 30,
    borderRadius: 15,
    justifyContent: "center",
    alignItems: "center",
  },
  scrollArea: {
    flex: 1,
    minHeight: 200,
  },
  scrollContent: {
    paddingHorizontal: 20,
    paddingTop: 16,
    paddingBottom: 8,
    gap: 14,
  },
  gradeRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 8,
  },
  gradeLabel: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    minWidth: 90,
  },
  dot: {
    width: 10,
    height: 10,
    borderRadius: 5,
  },
  gradeName: {
    fontSize: 13,
    fontWeight: "600",
  },
  inputGroup: {
    flex: 1,
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
  },
  priceField: {
    flex: 1,
    flexDirection: "row",
    alignItems: "center",
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 10,
    height: 42,
    gap: 4,
  },
  dollar: {
    fontSize: 16,
    fontWeight: "600",
  },
  priceInput: {
    flex: 1,
    fontSize: 16,
    fontWeight: "500",
    paddingVertical: 0,
  },
  perGal: {
    fontSize: 11,
    fontWeight: "500",
  },
  decimalBtn: {
    width: 36,
    height: 42,
    borderRadius: 10,
    borderWidth: 1,
    justifyContent: "center",
    alignItems: "center",
  },
  decimalBtnText: {
    fontSize: 22,
    fontWeight: "800",
    lineHeight: 26,
  },
  infoRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    marginTop: 4,
    padding: 10,
    borderRadius: 10,
    borderWidth: 1,
  },
  infoText: {
    flex: 1,
    fontSize: 12,
    lineHeight: 16,
  },
  footer: {
    flexDirection: "row",
    gap: 12,
    paddingHorizontal: 20,
    paddingTop: 12,
    borderTopWidth: 1,
  },
  cancelBtn: {
    flex: 1,
    height: 46,
    borderRadius: 12,
    justifyContent: "center",
    alignItems: "center",
    borderWidth: 1,
  },
  cancelText: {
    fontSize: 15,
    fontWeight: "600",
  },
  saveBtn: {
    flex: 1,
    height: 46,
    borderRadius: 12,
    justifyContent: "center",
    alignItems: "center",
    flexDirection: "row",
    gap: 6,
  },
  saveText: {
    fontSize: 15,
    fontWeight: "600",
    color: "#fff",
  },
});

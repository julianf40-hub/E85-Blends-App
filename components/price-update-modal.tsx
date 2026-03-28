import React, { useState } from "react";
import {
  Modal,
  View,
  Text,
  TextInput,
  Pressable,
  StyleSheet,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
} from "react-native";
import { useColors } from "@/hooks/use-colors";
import { IconSymbol } from "./ui/icon-symbol";

export interface PriceUpdateModalProps {
  visible: boolean;
  stationName: string;
  onClose: () => void;
  onSubmit: (e85Price?: number, octane87Price?: number, octane89Price?: number, octane9194Price?: number) => void;
  isLoading?: boolean;
}

const FUEL_GRADES = [
  { id: "e85", label: "E85", color: "#10B981" },
  { id: "octane87", label: "87 Octane", color: "#3B82F6" },
  { id: "octane89", label: "89 Octane", color: "#F59E0B" },
  { id: "octane9194", label: "91/94 Octane", color: "#EF4444" },
];

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

  const handleSubmit = () => {
    const e85 = prices.e85 ? parseFloat(prices.e85) : undefined;
    const octane87 = prices.octane87 ? parseFloat(prices.octane87) : undefined;
    const octane89 = prices.octane89 ? parseFloat(prices.octane89) : undefined;
    const octane9194 = prices.octane9194 ? parseFloat(prices.octane9194) : undefined;

    if (!e85 && !octane87 && !octane89 && !octane9194) {
      alert("Please enter at least one price");
      return;
    }

    onSubmit(e85, octane87, octane89, octane9194);
    setPrices({ e85: "", octane87: "", octane89: "", octane9194: "" });
  };

  const handleClose = () => {
    setPrices({ e85: "", octane87: "", octane89: "", octane9194: "" });
    onClose();
  };

  const handlePriceChange = (fuelType: string, text: string) => {
    // Allow only numbers and one decimal point
    if (/^\d*\.?\d*$/.test(text) || text === "") {
      setPrices((prev) => ({
        ...prev,
        [fuelType]: text,
      }));
    }
  };

  return (
    <Modal
      visible={visible}
      transparent
      animationType="slide"
      onRequestClose={handleClose}
    >
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : "height"}
        style={[styles.container, { backgroundColor: colors.background + "CC" }]}
      >
        <View
          style={[
            styles.content,
            { backgroundColor: colors.surface, borderColor: colors.border },
          ]}
        >
          {/* Header */}
          <View style={styles.header}>
            <View style={styles.headerContent}>
              <Text style={[styles.title, { color: colors.foreground }]}>
                Update Fuel Prices
              </Text>
              <Text style={[styles.subtitle, { color: colors.muted }]}>
                {stationName}
              </Text>
            </View>
            <Pressable
              onPress={handleClose}
              style={({ pressed }) => [
                styles.closeButton,
                {
                  backgroundColor: colors.background,
                  opacity: pressed ? 0.7 : 1,
                },
              ]}
            >
              <IconSymbol name="xmark" size={18} color={colors.foreground} />
            </Pressable>
          </View>

          {/* Fuel Grade Selector */}
          <ScrollView
            style={styles.scrollContent}
            contentContainerStyle={styles.scrollContentContainer}
            showsVerticalScrollIndicator={false}
          >
            {FUEL_GRADES.map((grade) => (
              <View key={grade.id} style={styles.priceInputGroup}>
                {/* Grade Label */}
                <View style={styles.gradeHeader}>
                  <View
                    style={[
                      styles.colorIndicator,
                      { backgroundColor: grade.color },
                    ]}
                  />
                  <Text style={[styles.gradeLabel, { color: colors.foreground }]}>
                    {grade.label}
                  </Text>
                </View>

                {/* Price Input */}
                <View
                  style={[
                    styles.priceInputContainer,
                    { borderColor: colors.border, backgroundColor: colors.background },
                  ]}
                >
                  <Text style={[styles.currencySymbol, { color: colors.muted }]}>
                    $
                  </Text>
                  <TextInput
                    style={[styles.priceInput, { color: colors.foreground }]}
                    placeholder={
                      grade.id === "e85"
                        ? "2.63"
                        : grade.id === "octane87"
                          ? "3.14"
                          : grade.id === "octane89"
                            ? "3.29"
                            : "3.49"
                    }
                    placeholderTextColor={colors.muted}
                    keyboardType="decimal-pad"
                    value={prices[grade.id as keyof typeof prices]}
                    onChangeText={(text) => handlePriceChange(grade.id, text)}
                    editable={!isLoading}
                    maxLength={6}
                  />
                  <Text style={[styles.unitLabel, { color: colors.muted }]}>
                    /gal
                  </Text>
                </View>
              </View>
            ))}

            {/* Info Box */}
            <View
              style={[
                styles.infoBox,
                { backgroundColor: colors.primary + "15", borderColor: colors.primary },
              ]}
            >
              <IconSymbol
                name="info.circle.fill"
                size={16}
                color={colors.primary}
              />
              <Text style={[styles.infoText, { color: colors.muted }]}>
                Your prices help other drivers find the best fuel deals
              </Text>
            </View>
          </ScrollView>

          {/* Action Buttons */}
          <View style={[styles.footer, { borderTopColor: colors.border }]}>
            <Pressable
              onPress={handleClose}
              disabled={isLoading}
              style={({ pressed }) => [
                styles.cancelButton,
                {
                  backgroundColor: colors.background,
                  borderColor: colors.border,
                  opacity: pressed ? 0.7 : 1,
                },
              ]}
            >
              <Text style={[styles.cancelButtonText, { color: colors.foreground }]}>
                Cancel
              </Text>
            </Pressable>

            <Pressable
              onPress={handleSubmit}
              disabled={isLoading}
              style={({ pressed }) => [
                styles.submitButton,
                {
                  backgroundColor: colors.primary,
                  opacity: pressed || isLoading ? 0.7 : 1,
                },
              ]}
            >
              <IconSymbol name="checkmark" size={18} color="#fff" />
              <Text style={styles.submitButtonText}>
                {isLoading ? "Saving..." : "Save Prices"}
              </Text>
            </Pressable>
          </View>
        </View>
      </KeyboardAvoidingView>
    </Modal>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: "flex-end",
  },
  content: {
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    maxHeight: "90%",
    borderTopWidth: 1,
  },
  header: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 20,
    paddingTop: 16,
    paddingBottom: 12,
  },
  headerContent: {
    flex: 1,
  },
  title: {
    fontSize: 18,
    fontWeight: "600",
    marginBottom: 4,
  },
  subtitle: {
    fontSize: 14,
    fontWeight: "400",
  },
  closeButton: {
    width: 32,
    height: 32,
    borderRadius: 16,
    justifyContent: "center",
    alignItems: "center",
  },
  scrollContent: {
    flex: 1,
  },
  scrollContentContainer: {
    paddingHorizontal: 20,
    paddingVertical: 16,
    gap: 16,
  },
  priceInputGroup: {
    gap: 8,
  },
  gradeHeader: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
  },
  colorIndicator: {
    width: 12,
    height: 12,
    borderRadius: 6,
  },
  gradeLabel: {
    fontSize: 14,
    fontWeight: "500",
  },
  priceInputContainer: {
    flexDirection: "row",
    alignItems: "center",
    borderWidth: 1,
    borderRadius: 12,
    paddingHorizontal: 12,
    height: 44,
    gap: 6,
  },
  currencySymbol: {
    fontSize: 16,
    fontWeight: "600",
  },
  priceInput: {
    flex: 1,
    fontSize: 16,
    fontWeight: "500",
  },
  unitLabel: {
    fontSize: 12,
    fontWeight: "500",
  },
  infoBox: {
    flexDirection: "row",
    alignItems: "flex-start",
    gap: 10,
    padding: 12,
    borderRadius: 12,
    borderWidth: 1,
    marginTop: 8,
  },
  infoText: {
    flex: 1,
    fontSize: 12,
    fontWeight: "400",
    lineHeight: 16,
  },
  footer: {
    flexDirection: "row",
    gap: 12,
    paddingHorizontal: 20,
    paddingVertical: 12,
    borderTopWidth: 1,
  },
  cancelButton: {
    flex: 1,
    height: 48,
    borderRadius: 12,
    justifyContent: "center",
    alignItems: "center",
    borderWidth: 1,
  },
  cancelButtonText: {
    fontSize: 16,
    fontWeight: "600",
  },
  submitButton: {
    flex: 1,
    height: 48,
    borderRadius: 12,
    justifyContent: "center",
    alignItems: "center",
    flexDirection: "row",
    gap: 8,
  },
  submitButtonText: {
    fontSize: 16,
    fontWeight: "600",
    color: "#fff",
  },
});

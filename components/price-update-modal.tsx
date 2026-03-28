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
import { FUEL_GRADES } from "@/lib/station-prices";

export interface PriceUpdateModalProps {
  visible: boolean;
  stationName: string;
  onClose: () => void;
  onSubmit: (e85Price?: number, octane87Price?: number, octane89Price?: number, octane9194Price?: number) => void;
  isLoading?: boolean;
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

  const handleSubmit = () => {
    const e85 = prices.e85 ? parseFloat(prices.e85) : undefined;
    const octane87 = prices.octane87 ? parseFloat(prices.octane87) : undefined;
    const octane89 = prices.octane89 ? parseFloat(prices.octane89) : undefined;
    const octane9194 = prices.octane9194 ? parseFloat(prices.octane9194) : undefined;

    if (!e85 && !octane87 && !octane89 && !octane9194) {
      alert("Please enter at least one price");
      return;
    }

    if (
      (e85 && isNaN(e85)) ||
      (octane87 && isNaN(octane87)) ||
      (octane89 && isNaN(octane89)) ||
      (octane9194 && isNaN(octane9194))
    ) {
      alert("Please enter valid prices");
      return;
    }

    onSubmit(e85, octane87, octane89, octane9194);
    setPrices({ e85: "", octane87: "", octane89: "", octane9194: "" });
  };

  const handleClose = () => {
    setPrices({ e85: "", octane87: "", octane89: "", octane9194: "" });
    onClose();
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
        <Pressable style={styles.backdrop} onPress={handleClose} />

        <View
          style={[
            styles.modal,
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

          {/* Input Fields */}
          <ScrollView
            style={styles.content}
            contentContainerStyle={styles.contentContainer}
            showsVerticalScrollIndicator={false}
          >
            {FUEL_GRADES.map((grade) => (
              <View key={grade.id} style={styles.inputGroup}>
                <Text style={[styles.label, { color: colors.foreground }]}>
                  {grade.label} ($/gal)
                </Text>
                <View
                  style={[
                    styles.inputContainer,
                    { borderColor: colors.border, backgroundColor: colors.background },
                  ]}
                >
                  <Text style={[styles.currencySymbol, { color: colors.muted }]}>
                    $
                  </Text>
                  <TextInput
                    style={[styles.input, { color: colors.foreground }]}
                    placeholder={grade.id === "e85" ? "2.63" : grade.id === "octane87" ? "3.14" : grade.id === "octane89" ? "3.29" : "3.49"}
                    placeholderTextColor={colors.muted}
                    keyboardType="numbers-and-punctuation"
                    value={prices[grade.id as keyof typeof prices]}
                    onChangeText={(text) =>
                      setPrices((prev) => ({
                        ...prev,
                        [grade.id]: text,
                      }))
                    }
                    editable={!isLoading}
                    maxLength={6}
                  />
                </View>
              </View>
            ))}

            {/* Info Text */}
            <View style={styles.infoBox}>
              <IconSymbol
                name="info.circle.fill"
                size={14}
                color={colors.primary}
              />
              <Text style={[styles.infoText, { color: colors.muted }]}>
                Your prices help other drivers find the best fuel deals
              </Text>
            </View>
          </ScrollView>

          {/* Action Buttons */}
          <View style={styles.footer}>
            <Pressable
              onPress={handleClose}
              disabled={isLoading}
              style={({ pressed }) => [
                styles.cancelButton,
                {
                  borderColor: colors.border,
                  opacity: pressed || isLoading ? 0.7 : 1,
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
                  opacity: pressed || isLoading ? 0.8 : 1,
                },
              ]}
            >
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
  backdrop: {
    flex: 1,
  },
  modal: {
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    borderWidth: 1,
    maxHeight: "85%",
  },
  header: {
    flexDirection: "row",
    alignItems: "flex-start",
    justifyContent: "space-between",
    paddingHorizontal: 20,
    paddingTop: 20,
    paddingBottom: 16,
    borderBottomWidth: 1,
  },
  headerContent: {
    flex: 1,
  },
  title: {
    fontSize: 18,
    fontWeight: "700",
    marginBottom: 4,
  },
  subtitle: {
    fontSize: 13,
    fontWeight: "500",
  },
  closeButton: {
    width: 36,
    height: 36,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
  },
  content: {
    flex: 1,
  },
  contentContainer: {
    paddingHorizontal: 20,
    paddingVertical: 16,
    gap: 16,
  },
  inputGroup: {
    gap: 8,
  },
  label: {
    fontSize: 14,
    fontWeight: "600",
  },
  inputContainer: {
    flexDirection: "row",
    alignItems: "center",
    borderWidth: 1,
    borderRadius: 12,
    paddingHorizontal: 12,
    height: 48,
  },
  currencySymbol: {
    fontSize: 16,
    fontWeight: "600",
    marginRight: 4,
  },
  input: {
    flex: 1,
    fontSize: 16,
    fontWeight: "500",
  },
  infoBox: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 12,
    paddingVertical: 12,
    borderRadius: 12,
    marginTop: 4,
  },
  infoText: {
    flex: 1,
    fontSize: 12,
    fontWeight: "500",
    lineHeight: 16,
  },
  footer: {
    flexDirection: "row",
    gap: 12,
    paddingHorizontal: 20,
    paddingTop: 16,
    paddingBottom: 20,
    borderTopWidth: 1,
  },
  cancelButton: {
    flex: 1,
    paddingVertical: 12,
    borderRadius: 12,
    borderWidth: 1.5,
    alignItems: "center",
    justifyContent: "center",
  },
  cancelButtonText: {
    fontSize: 15,
    fontWeight: "700",
  },
  submitButton: {
    flex: 1,
    paddingVertical: 12,
    borderRadius: 12,
    alignItems: "center",
    justifyContent: "center",
  },
  submitButtonText: {
    color: "#FFFFFF",
    fontSize: 15,
    fontWeight: "700",
  },
});

import { useCallback, useEffect, useRef, useState } from "react";
import {
  TextInput,
  View,
  Pressable,
  Text,
  StyleSheet,
  Platform,
  type TextInputProps,
  type StyleProp,
  type ViewStyle,
  type TextStyle,
} from "react-native";

/**
 * A decimal-friendly numeric input that works reliably on Samsung and all Android devices.
 *
 * Samsung keyboards have a known bug where `keyboardType="decimal-pad"` and `"numeric"`
 * don't show a decimal point key. This component:
 * 1. Uses `keyboardType="default"` to get a full keyboard with decimal point
 * 2. Filters input to only allow numbers and one decimal point
 * 3. Adds a convenient "." button next to the input for quick decimal entry
 * 4. Stores text as string to preserve trailing dots while typing
 * 5. Only converts to number on blur or when the parent requests it
 */

interface DecimalInputProps {
  /** Current numeric value */
  value: string;
  /** Called when text changes (raw string, may end with ".") */
  onChangeText: (text: string) => void;
  /** Called when editing is done (on blur) with the parsed number */
  onBlurValue?: (num: number) => void;
  /** Placeholder text */
  placeholder?: string;
  /** Style for the outer container */
  containerStyle?: StyleProp<ViewStyle>;
  /** Style for the TextInput */
  inputStyle?: StyleProp<TextStyle>;
  /** Color for the decimal button text */
  accentColor?: string;
  /** Color for the decimal button background */
  buttonBgColor?: string;
  /** Color for the input text */
  textColor?: string;
  /** Color for the input border */
  borderColor?: string;
  /** Color for the input background */
  backgroundColor?: string;
  /** Color for placeholder text */
  placeholderTextColor?: string;
  /** Whether to show the decimal button (default: true) */
  showDecimalButton?: boolean;
  /** Max length of input */
  maxLength?: number;
  /** Select text on focus */
  selectTextOnFocus?: boolean;
  /** Additional TextInput props */
  textInputProps?: Partial<TextInputProps>;
}

/** Only allow digits and one decimal point */
function sanitize(text: string): string {
  // Replace comma with dot for locale support
  let cleaned = text.replace(/,/g, ".");
  // Remove all non-digit, non-dot characters
  cleaned = cleaned.replace(/[^\d.]/g, "");
  // Allow only one decimal point
  const dotIndex = cleaned.indexOf(".");
  if (dotIndex !== -1) {
    cleaned =
      cleaned.substring(0, dotIndex + 1) +
      cleaned.substring(dotIndex + 1).replace(/\./g, "");
  }
  return cleaned;
}

export function DecimalInput({
  value,
  onChangeText,
  onBlurValue,
  placeholder = "0",
  containerStyle,
  inputStyle,
  accentColor = "#22C55E",
  buttonBgColor = "rgba(34, 197, 94, 0.15)",
  textColor = "#FFFFFF",
  borderColor = "#334155",
  backgroundColor = "#151718",
  placeholderTextColor = "#9BA1A6",
  showDecimalButton = true,
  maxLength = 10,
  selectTextOnFocus = true,
  textInputProps,
}: DecimalInputProps) {
  const inputRef = useRef<TextInput>(null);

  const handleChangeText = useCallback(
    (text: string) => {
      onChangeText(sanitize(text));
    },
    [onChangeText]
  );

  const handleDecimalPress = useCallback(() => {
    // Only add decimal if there isn't one already
    if (!value.includes(".")) {
      const newValue = value === "" ? "0." : value + ".";
      onChangeText(newValue);
      // Focus the input after pressing decimal
      inputRef.current?.focus();
    }
  }, [value, onChangeText]);

  const handleBlur = useCallback(() => {
    if (onBlurValue) {
      const num = parseFloat(value);
      if (!isNaN(num)) {
        onBlurValue(num);
      }
    }
  }, [value, onBlurValue]);

  return (
    <View style={[styles.container, containerStyle]}>
      <TextInput
        ref={inputRef}
        style={[
          styles.input,
          {
            color: textColor,
            borderColor: borderColor,
            backgroundColor: backgroundColor,
          },
          inputStyle,
        ]}
        value={value}
        onChangeText={handleChangeText}
        onBlur={handleBlur}
        keyboardType="default"
        returnKeyType="done"
        placeholder={placeholder}
        placeholderTextColor={placeholderTextColor}
        selectTextOnFocus={selectTextOnFocus}
        maxLength={maxLength}
        autoCapitalize="none"
        autoCorrect={false}
        {...textInputProps}
      />
      {showDecimalButton && (
        <Pressable
          onPress={handleDecimalPress}
          style={({ pressed }) => [
            styles.decimalButton,
            { backgroundColor: buttonBgColor },
            pressed && { opacity: 0.7 },
          ]}
        >
          <Text style={[styles.decimalButtonText, { color: accentColor }]}>
            .
          </Text>
        </Pressable>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
  },
  input: {
    flex: 1,
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 8,
    fontSize: 14,
    fontWeight: "600",
    textAlign: "center",
    minWidth: 70,
  },
  decimalButton: {
    width: 36,
    height: 36,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
  },
  decimalButtonText: {
    fontSize: 22,
    fontWeight: "800",
    lineHeight: 26,
  },
});

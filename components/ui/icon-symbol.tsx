// Fallback for using MaterialIcons on Android and web.

import MaterialIcons from "@expo/vector-icons/MaterialIcons";
import { SymbolWeight } from "expo-symbols";
import { ComponentProps } from "react";
import { OpaqueColorValue, type StyleProp, type TextStyle } from "react-native";

type MaterialIconName = ComponentProps<typeof MaterialIcons>["name"];

const MAPPING: Record<string, MaterialIconName> = {
  "house.fill": "home",
  "paperplane.fill": "send",
  "chevron.left.forwardslash.chevron.right": "code",
  "chevron.right": "chevron-right",
  "list.bullet.clipboard.fill": "list",
  "arrow.counterclockwise": "refresh",
  "xmark.circle.fill": "close",
  "plus.circle.fill": "add-circle",
  "location.fill": "location-on",
  "star.fill": "star",
  "fuelpump.fill": "local-gas-station",
  "map.fill": "map",
  "bookmark.fill": "bookmark",
  "slider.horizontal.3": "tune",
  "magnifyingglass": "search",
  "xmark": "close",
  "trash.fill": "delete",
  "plus": "add",
  "info.circle.fill": "info",
  "gearshape.fill": "settings",
  "arrow.right": "arrow-forward",
  "drop.fill": "water-drop",
  "flame.fill": "local-fire-department",
  "gauge.open.with.lines.needle.33percent": "speed",
  "checkmark.circle.fill": "check-circle",
  "arrow.clockwise": "refresh",
  "square.and.arrow.up": "share",
  "navigation.fill": "navigation",
  "car.fill": "directions-car",
  "car.2.fill": "garage",
  "wrench.fill": "build",
  "pencil": "edit",
  "checkmark": "check",
  "chevron.down": "expand-more",
  "chevron.up": "expand-less",
  "ellipsis": "more-horiz",
  "crown.fill": "star",
  "gear": "settings",
  "list.bullet": "format-list-bulleted",
  "map": "map",
  "location.circle.fill": "my-location",
  "pin.fill": "push-pin",
  "sun.max.fill": "wb-sunny",
  "moon.fill": "nightlight-round",
  "circle.lefthalf.filled": "brightness-medium",
  "star": "star-outline",
  "heart.fill": "favorite",
  "heart": "favorite-border",
  "bell.fill": "notifications",
  "bell": "notifications-none",
  "bell.badge.fill": "notifications-active",
  "speedometer": "speed",
  "clock.fill": "schedule",
  "calendar": "calendar-today",
  "repeat": "repeat",
  "checkmark.circle": "check-circle-outline",
  "exclamationmark.triangle.fill": "warning",
  "arrow.up.right": "open-in-new",
};

export type IconSymbolName = keyof typeof MAPPING;

/**
 * An icon component that uses native SF Symbols on iOS, and Material Icons on Android and web.
 */
export function IconSymbol({
  name,
  size = 24,
  color,
  style,
}: {
  name: IconSymbolName;
  size?: number;
  color: string | OpaqueColorValue;
  style?: StyleProp<TextStyle>;
  weight?: SymbolWeight;
}) {
  const iconName = MAPPING[name as string] || "help-outline";
  return <MaterialIcons color={color} size={size} name={iconName} style={style} />;
}

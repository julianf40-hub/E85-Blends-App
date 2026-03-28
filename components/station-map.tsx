/**
 * StationMap — web fallback
 * react-native-maps is not available on web, so we render a placeholder.
 */
import React from "react";
import { View, Text, StyleSheet } from "react-native";
import { IconSymbol } from "@/components/ui/icon-symbol";

export interface StationMapStation {
  id: string;
  name: string;
  address: string;
  city: string;
  state: string;
  zip: string;
  latitude: number;
  longitude: number;
  distance: number;
  hasBlenderPump: boolean;
  [key: string]: any;
}

export interface StationMapRegion {
  latitude: number;
  longitude: number;
  latitudeDelta: number;
  longitudeDelta: number;
}

interface StationMapProps {
  mapRef: React.RefObject<any>;
  initialRegion: StationMapRegion;
  userLocation: { latitude: number; longitude: number } | null;
  stations: StationMapStation[];
  selectedStationId: string | null;
  primaryColor: string;
  surfaceColor: string;
  borderColor: string;
  hasLocationPermission: boolean;
  onMarkerPress: (station: StationMapStation) => void;
  onRecenter: () => void;
}

export function StationMap({ primaryColor }: StationMapProps) {
  return (
    <View style={styles.container}>
      <IconSymbol name="map.fill" size={48} color={primaryColor + "60"} />
      <Text style={[styles.text, { color: primaryColor + "80" }]}>
        Map view is available on iOS and Android
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: 12,
  },
  text: {
    fontSize: 15,
    textAlign: "center",
    paddingHorizontal: 40,
  },
});

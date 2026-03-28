/**
 * StationMap — native (iOS/Android) implementation
 * Uses react-native-maps with OpenStreetMap tiles (no Google API key required).
 * PROVIDER_DEFAULT uses Apple Maps on iOS and the built-in map on Android,
 * then UrlTile overlays OpenStreetMap tiles on top for a consistent look.
 */
import React from "react";
import { StyleSheet, View, Pressable } from "react-native";
import MapView, { Marker, Circle, UrlTile, PROVIDER_DEFAULT } from "react-native-maps";
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

export function StationMap({
  mapRef,
  initialRegion,
  userLocation,
  stations,
  selectedStationId,
  primaryColor,
  surfaceColor,
  borderColor,
  hasLocationPermission,
  onMarkerPress,
  onRecenter,
}: StationMapProps) {
  return (
    <View style={styles.container}>
      <MapView
        ref={mapRef}
        provider={PROVIDER_DEFAULT}
        style={StyleSheet.absoluteFillObject}
        initialRegion={initialRegion}
        // Only enable showsUserLocation when permission is confirmed to avoid SecurityException
        showsUserLocation={hasLocationPermission}
        showsMyLocationButton={false}
        // Disable Google-specific features that require an API key
        showsTraffic={false}
        showsIndoors={false}
      >
        {/* OpenStreetMap tile overlay — free, no API key needed */}
        <UrlTile
          urlTemplate="https://tile.openstreetmap.org/{z}/{x}/{y}.png"
          maximumZ={19}
          flipY={false}
          tileSize={256}
          zIndex={-1}
        />

        {/* User accuracy circle (shown even without showsUserLocation for visual feedback) */}
        {userLocation && hasLocationPermission && (
          <Circle
            center={userLocation}
            radius={800}
            strokeColor={primaryColor + "60"}
            fillColor={primaryColor + "15"}
            strokeWidth={1.5}
          />
        )}

        {/* Station pins */}
        {stations.map((station) => (
          <Marker
            key={station.id}
            coordinate={{
              latitude: station.latitude,
              longitude: station.longitude,
            }}
            title={station.name}
            description={`${station.distance.toFixed(1)} mi · ${station.address}`}
            pinColor={selectedStationId === station.id ? "#F59E0B" : primaryColor}
            onPress={() => onMarkerPress(station)}
          />
        ))}
      </MapView>

      {/* Re-center button */}
      <Pressable
        onPress={onRecenter}
        style={({ pressed }) => [
          styles.recenterBtn,
          { backgroundColor: surfaceColor, borderColor },
          pressed && { opacity: 0.7 },
        ]}
      >
        <IconSymbol name="location.circle.fill" size={22} color={primaryColor} />
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    position: "relative",
  },
  recenterBtn: {
    position: "absolute",
    top: 12,
    right: 12,
    width: 42,
    height: 42,
    borderRadius: 12,
    borderWidth: 1,
    alignItems: "center",
    justifyContent: "center",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.1,
    shadowRadius: 6,
    elevation: 4,
  },
});

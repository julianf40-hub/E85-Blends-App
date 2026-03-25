import React, { useState, useEffect, useRef, useCallback } from "react";
import {
  Text,
  View,
  FlatList,
  Pressable,
  Platform,
  Linking,
  ActivityIndicator,
  StyleSheet,
  Dimensions,
} from "react-native";
import Animated, { FadeIn, FadeInDown } from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import * as Location from "expo-location";
import { LinearGradient } from "expo-linear-gradient";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import {
  E85Station,
  SAMPLE_STATIONS,
  getStationsByDistance,
} from "@/lib/station-data";

const { width: SCREEN_WIDTH } = Dimensions.get("window");

interface StationWithDistance extends E85Station {
  distance: number;
}

export default function StationsScreen() {
  const colors = useColors();
  const [location, setLocation] = useState<{
    latitude: number;
    longitude: number;
  } | null>(null);
  const [stations, setStations] = useState<StationWithDistance[]>([]);
  const [loading, setLoading] = useState(true);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [selectedStation, setSelectedStation] =
    useState<StationWithDistance | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const { status } = await Location.requestForegroundPermissionsAsync();
        if (status !== "granted") {
          setErrorMsg("Location permission denied");
          // Use default location (center of US)
          const defaultLat = 39.8283;
          const defaultLon = -98.5795;
          setLocation({ latitude: defaultLat, longitude: defaultLon });
          setStations(getStationsByDistance(defaultLat, defaultLon));
          setLoading(false);
          return;
        }

        const loc = await Location.getCurrentPositionAsync({
          accuracy: Location.Accuracy.Balanced,
        });
        setLocation({
          latitude: loc.coords.latitude,
          longitude: loc.coords.longitude,
        });
        setStations(
          getStationsByDistance(loc.coords.latitude, loc.coords.longitude)
        );
      } catch {
        // Fallback to default location
        const defaultLat = 39.8283;
        const defaultLon = -98.5795;
        setLocation({ latitude: defaultLat, longitude: defaultLon });
        setStations(getStationsByDistance(defaultLat, defaultLon));
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  const openDirections = useCallback((station: E85Station) => {
    if (Platform.OS !== "web") {
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    }
    const url = Platform.select({
      ios: `maps:0,0?q=${station.latitude},${station.longitude}`,
      android: `geo:0,0?q=${station.latitude},${station.longitude}(${encodeURIComponent(station.name)})`,
      default: `https://www.google.com/maps/dir/?api=1&destination=${station.latitude},${station.longitude}`,
    });
    if (url) Linking.openURL(url);
  }, []);

  const renderStationCard = useCallback(
    ({ item, index }: { item: StationWithDistance; index: number }) => (
      <Animated.View entering={FadeInDown.duration(250).delay(index * 50)}>
        <Pressable
          onPress={() => {
            if (Platform.OS !== "web") {
              Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
            }
            setSelectedStation(
              selectedStation?.id === item.id ? null : item
            );
          }}
          style={({ pressed }) => [
            styles.stationCard,
            {
              backgroundColor: colors.surface,
              borderColor:
                selectedStation?.id === item.id
                  ? colors.primary
                  : colors.border,
              borderWidth: selectedStation?.id === item.id ? 2 : 1,
            },
            pressed && { opacity: 0.8 },
          ]}
        >
          <View style={styles.stationCardTop}>
            <View style={styles.stationInfo}>
              <View style={styles.stationNameRow}>
                <View
                  style={[
                    styles.stationIconBg,
                    { backgroundColor: colors.primary + "18" },
                  ]}
                >
                  <IconSymbol
                    name="fuelpump.fill"
                    size={18}
                    color={colors.primary}
                  />
                </View>
                <View style={styles.stationNameCol}>
                  <Text
                    style={[styles.stationName, { color: colors.foreground }]}
                    numberOfLines={1}
                  >
                    {item.name}
                  </Text>
                  {item.brand && (
                    <Text
                      style={[styles.stationBrand, { color: colors.muted }]}
                    >
                      {item.brand}
                    </Text>
                  )}
                </View>
              </View>
              <View style={styles.distanceBadge}>
                <Text
                  style={[styles.distanceText, { color: colors.primary }]}
                >
                  {item.distance < 1
                    ? `${(item.distance * 5280).toFixed(0)} ft`
                    : `${item.distance.toFixed(1)} mi`}
                </Text>
              </View>
            </View>

            <Text
              style={[styles.stationAddress, { color: colors.muted }]}
              numberOfLines={1}
            >
              {item.address}, {item.city}, {item.state} {item.zip}
            </Text>

            <View style={styles.stationMeta}>
              {item.pricePerGallon && (
                <View
                  style={[
                    styles.priceBadge,
                    { backgroundColor: colors.primary + "15" },
                  ]}
                >
                  <Text
                    style={[styles.priceText, { color: colors.primary }]}
                  >
                    ${item.pricePerGallon.toFixed(2)}/gal
                  </Text>
                </View>
              )}
              {item.hours && (
                <View
                  style={[
                    styles.hoursBadge,
                    { backgroundColor: colors.muted + "15" },
                  ]}
                >
                  <Text
                    style={[styles.hoursText, { color: colors.muted }]}
                  >
                    {item.hours}
                  </Text>
                </View>
              )}
            </View>
          </View>

          {selectedStation?.id === item.id && (
            <Animated.View
              entering={FadeIn.duration(200)}
              style={styles.stationActions}
            >
              <Pressable
                onPress={() => openDirections(item)}
                style={({ pressed }) => [
                  styles.directionButton,
                  pressed && { opacity: 0.8, transform: [{ scale: 0.97 }] },
                ]}
              >
                <LinearGradient
                  colors={[colors.primary, "#15803D"]}
                  start={{ x: 0, y: 0 }}
                  end={{ x: 1, y: 1 }}
                  style={styles.directionGradient}
                >
                  <IconSymbol
                    name="navigation.fill"
                    size={16}
                    color="#FFFFFF"
                  />
                  <Text style={styles.directionText}>Get Directions</Text>
                </LinearGradient>
              </Pressable>
              {item.phone && (
                <Pressable
                  onPress={() => {
                    Linking.openURL(`tel:${item.phone}`);
                  }}
                  style={({ pressed }) => [
                    styles.callButton,
                    { borderColor: colors.primary },
                    pressed && { opacity: 0.7 },
                  ]}
                >
                  <Text
                    style={[styles.callButtonText, { color: colors.primary }]}
                  >
                    Call
                  </Text>
                </Pressable>
              )}
            </Animated.View>
          )}
        </Pressable>
      </Animated.View>
    ),
    [colors, selectedStation, openDirections]
  );

  return (
    <ScreenContainer>
      {/* Header */}
      <View style={styles.header}>
        <View style={styles.headerRow}>
          <View
            style={[
              styles.headerIconBg,
              { backgroundColor: colors.primary + "18" },
            ]}
          >
            <IconSymbol name="map.fill" size={22} color={colors.primary} />
          </View>
          <View>
            <Text style={[styles.headerTitle, { color: colors.foreground }]}>
              E85 Stations
            </Text>
            <Text style={[styles.headerSubtitle, { color: colors.muted }]}>
              {stations.length} stations found
              {location && !errorMsg ? " near you" : ""}
            </Text>
          </View>
        </View>
      </View>

      {/* Map Placeholder / Info Banner */}
      <View style={styles.mapContainer}>
        <LinearGradient
          colors={[colors.primary + "20", colors.primary + "08"]}
          style={styles.mapPlaceholder}
        >
          <IconSymbol name="map.fill" size={40} color={colors.primary} />
          <Text style={[styles.mapPlaceholderTitle, { color: colors.foreground }]}>
            Station Map
          </Text>
          <Text style={[styles.mapPlaceholderText, { color: colors.muted }]}>
            {Platform.OS === "web"
              ? "Map view available on iOS and Android devices"
              : "Tap a station below for directions"}
          </Text>
          {errorMsg && (
            <View
              style={[
                styles.locationWarning,
                { backgroundColor: colors.warning + "20" },
              ]}
            >
              <IconSymbol
                name="info.circle.fill"
                size={14}
                color={colors.warning}
              />
              <Text
                style={[styles.locationWarningText, { color: colors.warning }]}
              >
                {errorMsg}. Showing all stations.
              </Text>
            </View>
          )}
        </LinearGradient>
      </View>

      {/* Station List */}
      {loading ? (
        <View style={styles.loadingContainer}>
          <ActivityIndicator size="large" color={colors.primary} />
          <Text style={[styles.loadingText, { color: colors.muted }]}>
            Finding nearby stations...
          </Text>
        </View>
      ) : (
        <FlatList
          data={stations}
          renderItem={renderStationCard}
          keyExtractor={(item) => item.id}
          contentContainerStyle={styles.listContent}
          showsVerticalScrollIndicator={false}
          ItemSeparatorComponent={() => <View style={styles.separator} />}
        />
      )}
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  header: {
    paddingHorizontal: 20,
    paddingTop: 8,
    paddingBottom: 16,
  },
  headerRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
  },
  headerIconBg: {
    width: 44,
    height: 44,
    borderRadius: 14,
    alignItems: "center",
    justifyContent: "center",
  },
  headerTitle: {
    fontSize: 26,
    fontWeight: "800",
    letterSpacing: -0.5,
  },
  headerSubtitle: {
    fontSize: 14,
    fontWeight: "400",
    marginTop: 2,
  },
  mapContainer: {
    paddingHorizontal: 20,
    marginBottom: 16,
  },
  mapPlaceholder: {
    borderRadius: 20,
    padding: 28,
    alignItems: "center",
    gap: 10,
  },
  mapPlaceholderTitle: {
    fontSize: 18,
    fontWeight: "700",
  },
  mapPlaceholderText: {
    fontSize: 14,
    textAlign: "center",
  },
  locationWarning: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 10,
    marginTop: 8,
  },
  locationWarningText: {
    fontSize: 12,
    fontWeight: "500",
  },
  loadingContainer: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: 12,
  },
  loadingText: {
    fontSize: 15,
    fontWeight: "500",
  },
  listContent: {
    paddingHorizontal: 20,
    paddingBottom: 100,
  },
  separator: {
    height: 10,
  },
  stationCard: {
    borderRadius: 18,
    padding: 16,
    gap: 12,
  },
  stationCardTop: {
    gap: 8,
  },
  stationInfo: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "flex-start",
  },
  stationNameRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    flex: 1,
  },
  stationIconBg: {
    width: 36,
    height: 36,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
  },
  stationNameCol: {
    flex: 1,
  },
  stationName: {
    fontSize: 16,
    fontWeight: "700",
  },
  stationBrand: {
    fontSize: 12,
    fontWeight: "500",
    marginTop: 1,
  },
  distanceBadge: {
    paddingHorizontal: 10,
    paddingVertical: 4,
  },
  distanceText: {
    fontSize: 14,
    fontWeight: "700",
  },
  stationAddress: {
    fontSize: 13,
    marginLeft: 46,
  },
  stationMeta: {
    flexDirection: "row",
    gap: 8,
    marginLeft: 46,
  },
  priceBadge: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 8,
  },
  priceText: {
    fontSize: 13,
    fontWeight: "700",
  },
  hoursBadge: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 8,
  },
  hoursText: {
    fontSize: 13,
    fontWeight: "500",
  },
  stationActions: {
    flexDirection: "row",
    gap: 10,
    paddingTop: 4,
  },
  directionButton: {
    flex: 1,
    borderRadius: 12,
    overflow: "hidden",
  },
  directionGradient: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    paddingVertical: 12,
  },
  directionText: {
    color: "#FFFFFF",
    fontSize: 14,
    fontWeight: "700",
  },
  callButton: {
    paddingHorizontal: 20,
    paddingVertical: 12,
    borderRadius: 12,
    borderWidth: 1.5,
    alignItems: "center",
    justifyContent: "center",
  },
  callButtonText: {
    fontSize: 14,
    fontWeight: "700",
  },
});

import React, { useState, useEffect, useCallback } from "react";
import {
  Text,
  View,
  FlatList,
  Pressable,
  Platform,
  Linking,
  ActivityIndicator,
  StyleSheet,
  TextInput,
} from "react-native";
import Animated, { FadeIn, FadeInDown } from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import * as Location from "expo-location";
import { LinearGradient } from "expo-linear-gradient";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import { E85Station, fetchNearbyStations } from "@/lib/station-data";
import { FuelPrices, fetchFuelPrices } from "@/lib/fuel-prices";
import { PriceUpdateModal } from "@/components/price-update-modal";
import {
  getLatestStationPrice,
  getAverageStationPrices,
  addStationPrice,
  formatPriceAge,
} from "@/lib/station-prices";

export default function StationsScreen() {
  const colors = useColors();
  const [location, setLocation] = useState<{
    latitude: number;
    longitude: number;
  } | null>(null);
  const [stations, setStations] = useState<E85Station[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [selectedStation, setSelectedStation] = useState<E85Station | null>(null);
  const [searchRadius, setSearchRadius] = useState(25);
  const [fuelPrices, setFuelPrices] = useState<FuelPrices | null>(null);
  const [priceModalVisible, setPriceModalVisible] = useState(false);
  const [priceModalStation, setPriceModalStation] = useState<E85Station | null>(null);
  const [userPrices, setUserPrices] = useState<Record<string, any>>({}); // stationId -> latest price
  const [submittingPrice, setSubmittingPrice] = useState(false);

  const loadStations = useCallback(
    async (lat: number, lon: number, radius: number = searchRadius) => {
      try {
        const results = await fetchNearbyStations(lat, lon, radius, 30);
        setStations(results);
        if (results.length === 0) {
          setErrorMsg(`No E85 stations found within ${radius} miles. Try increasing the search radius.`);
        } else {
          setErrorMsg(null);
        }
      } catch (err: any) {
        if (err?.message === "RATE_LIMITED") {
          setErrorMsg("API rate limit reached. Pull down to refresh in a moment.");
        } else {
          setErrorMsg("Failed to load stations. Check your internet connection.");
        }
      }
    },
    [searchRadius]
  );

  useEffect(() => {
    (async () => {
      // Fetch fuel prices
      const prices = await fetchFuelPrices();
      setFuelPrices(prices);

      try {
        const { status } = await Location.requestForegroundPermissionsAsync();
        if (status !== "granted") {
          setErrorMsg("Location permission denied. Showing stations near Phoenix, AZ.");
          const defaultLat = 33.4484;
          const defaultLon = -112.074;
          setLocation({ latitude: defaultLat, longitude: defaultLon });
          await loadStations(defaultLat, defaultLon);
          setLoading(false);
          return;
        }

        const loc = await Location.getCurrentPositionAsync({
          accuracy: Location.Accuracy.Balanced,
        });
        const coords = {
          latitude: loc.coords.latitude,
          longitude: loc.coords.longitude,
        };
        setLocation(coords);
        await loadStations(coords.latitude, coords.longitude);
      } catch {
        const defaultLat = 33.4484;
        const defaultLon = -112.074;
        setLocation({ latitude: defaultLat, longitude: defaultLon });
        await loadStations(defaultLat, defaultLon);
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  const handleRefresh = useCallback(async () => {
    if (!location) return;
    setRefreshing(true);
    await loadStations(location.latitude, location.longitude);
    setRefreshing(false);
  }, [location, loadStations]);

  const handleRadiusChange = useCallback(
    async (newRadius: number) => {
      if (Platform.OS !== "web") {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
      }
      setSearchRadius(newRadius);
      if (location) {
        setLoading(true);
        await loadStations(location.latitude, location.longitude, newRadius);
        setLoading(false);
      }
    },
    [location, loadStations]
  );

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

  const handlePriceUpdate = useCallback(
    (station: E85Station) => {
      setPriceModalStation(station);
      setPriceModalVisible(true);
    },
    []
  );

  const handlePriceSubmit = useCallback(
    async (e85Price?: number, octane87Price?: number, octane89Price?: number, octane9194Price?: number) => {
      if (!priceModalStation) return;

      setSubmittingPrice(true);
      try {
        await addStationPrice({
          stationId: priceModalStation.id,
          e85Price,
          octane87Price,
          octane89Price,
          octane9194Price,
        });

        const latestPrice = await getLatestStationPrice(priceModalStation.id);
        if (latestPrice) {
          setUserPrices((prev) => ({
            ...prev,
            [priceModalStation.id]: latestPrice,
          }));
        }

        setPriceModalVisible(false);
        if (Platform.OS !== "web") {
          Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
        }
      } catch (error) {
        console.error("Failed to submit price:", error);
        alert("Failed to save price. Please try again.");
      } finally {
        setSubmittingPrice(false);
      }
    },
    [priceModalStation]
  );

  const renderStationCard = useCallback(
    ({ item, index }: { item: E85Station; index: number }) => (
      <Animated.View entering={FadeInDown.duration(250).delay(Math.min(index * 40, 400))}>
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
              {item.hours && (
                <View
                  style={[
                    styles.hoursBadge,
                    { backgroundColor: colors.muted + "15" },
                  ]}
                >
                  <Text
                    style={[styles.hoursText, { color: colors.muted }]}
                    numberOfLines={1}
                  >
                    {item.hours}
                  </Text>
                </View>
              )}
              {item.hasBlenderPump && (
                <View
                  style={[
                    styles.blenderBadge,
                    { backgroundColor: colors.primary + "15" },
                  ]}
                >
                  <Text
                    style={[styles.blenderText, { color: colors.primary }]}
                  >
                    Blender Pump
                  </Text>
                </View>
              )}
              {item.facilityType && (
                <View
                  style={[
                    styles.hoursBadge,
                    { backgroundColor: colors.muted + "15" },
                  ]}
                >
                  <Text
                    style={[styles.hoursText, { color: colors.muted }]}
                  >
                    {item.facilityType}
                  </Text>
                </View>
              )}
            </View>
          </View>

          {/* User-Submitted Prices Section */}
          {userPrices[item.id] && (
            <View
              style={[
                styles.pricesSection,
                { backgroundColor: colors.primary + "10", borderTopColor: colors.primary },
              ]}
            >
              <View style={styles.priceRow}>
                {userPrices[item.id].e85Price && (
                  <View style={styles.priceItem}>
                    <Text style={[styles.priceLabel, { color: colors.muted }]}>
                      E85
                    </Text>
                    <Text style={[styles.priceValue, { color: "#10B981" }]}>
                      ${userPrices[item.id].e85Price.toFixed(2)}
                    </Text>
                  </View>
                )}
                {userPrices[item.id].octane87Price && (
                  <View style={styles.priceItem}>
                    <Text style={[styles.priceLabel, { color: colors.muted }]}>
                      87
                    </Text>
                    <Text style={[styles.priceValue, { color: "#3B82F6" }]}>
                      ${userPrices[item.id].octane87Price.toFixed(2)}
                    </Text>
                  </View>
                )}
                {userPrices[item.id].octane89Price && (
                  <View style={styles.priceItem}>
                    <Text style={[styles.priceLabel, { color: colors.muted }]}>
                      89
                    </Text>
                    <Text style={[styles.priceValue, { color: "#F59E0B" }]}>
                      ${userPrices[item.id].octane89Price.toFixed(2)}
                    </Text>
                  </View>
                )}
                {userPrices[item.id].octane9194Price && (
                  <View style={styles.priceItem}>
                    <Text style={[styles.priceLabel, { color: colors.muted }]}>
                      91/94
                    </Text>
                    <Text style={[styles.priceValue, { color: "#EF4444" }]}>
                      ${userPrices[item.id].octane9194Price.toFixed(2)}
                    </Text>
                  </View>
                )}
              </View>
              <Text style={[styles.priceSource, { color: colors.muted }]}>
                Updated {formatPriceAge(userPrices[item.id].timestamp)}
              </Text>
            </View>
          )}

          {/* AFDC National Average Prices */}
          {fuelPrices && (
            <View
              style={[
                styles.pricesSection,
                { backgroundColor: colors.background, borderTopColor: colors.border },
              ]}
            >
              <View style={styles.priceRow}>
                <View style={styles.priceItem}>
                  <Text style={[styles.priceLabel, { color: colors.muted }]}>
                    E85 Avg
                  </Text>
                  <Text style={[styles.priceValue, { color: colors.primary }]}>
                    ${fuelPrices.e85Price.toFixed(2)}/gal
                  </Text>
                </View>
                <View style={styles.priceItem}>
                  <Text style={[styles.priceLabel, { color: colors.muted }]}>
                    Gas Avg
                  </Text>
                  <Text style={[styles.priceValue, { color: colors.foreground }]}>
                    ${fuelPrices.gasolinePrice.toFixed(2)}/gal
                  </Text>
                </View>
                <View style={styles.priceItem}>
                  <Text style={[styles.priceLabel, { color: colors.muted }]}>
                    Savings
                  </Text>
                  <Text style={[styles.priceValue, { color: colors.success }]}>
                    {((1 - fuelPrices.e85Price / fuelPrices.gasolinePrice) * 100).toFixed(0)}%
                  </Text>
                </View>
              </View>
              <Text style={[styles.priceSource, { color: colors.muted }]}>
                {fuelPrices.source}
              </Text>
            </View>
          )}

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
              <Pressable
                onPress={() => handlePriceUpdate(item)}
                style={({ pressed }) => [
                  styles.callButton,
                  { borderColor: colors.primary },
                  pressed && { opacity: 0.7 },
                ]}
              >
                <IconSymbol
                  name="dollarsign.circle.fill"
                  size={16}
                  color={colors.primary}
                />
                <Text
                  style={[styles.callButtonText, { color: colors.primary }]}
                >
                  Update Price
                </Text>
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

          {selectedStation?.id === item.id && item.lastConfirmed && (
            <Text style={[styles.confirmedText, { color: colors.muted }]}>
              Last confirmed: {item.lastConfirmed}
            </Text>
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
          <View style={styles.headerTextCol}>
            <Text style={[styles.headerTitle, { color: colors.foreground }]}>
              E85 Stations
            </Text>
            <Text style={[styles.headerSubtitle, { color: colors.muted }]}>
              {loading
                ? "Searching..."
                : `${stations.length} station${stations.length !== 1 ? "s" : ""} found nearby`}
            </Text>
          </View>
          {!loading && (
            <Pressable
              onPress={handleRefresh}
              style={({ pressed }) => [
                styles.refreshButton,
                { backgroundColor: colors.primary + "15" },
                pressed && { opacity: 0.7 },
              ]}
            >
              <IconSymbol
                name="arrow.clockwise"
                size={18}
                color={colors.primary}
              />
            </Pressable>
          )}
        </View>
      </View>

      {/* Search Radius Selector */}
      <View style={styles.radiusContainer}>
        <Text style={[styles.radiusLabel, { color: colors.muted }]}>
          Search radius:
        </Text>
        <View style={styles.radiusChips}>
          {[10, 25, 50, 100].map((radius) => (
            <Pressable
              key={radius}
              onPress={() => handleRadiusChange(radius)}
              style={({ pressed }) => [
                styles.radiusChip,
                {
                  backgroundColor:
                    searchRadius === radius
                      ? colors.primary
                      : colors.background,
                  borderColor:
                    searchRadius === radius ? colors.primary : colors.border,
                },
                pressed && { transform: [{ scale: 0.97 }] },
              ]}
            >
              <Text
                style={[
                  styles.radiusChipText,
                  {
                    color:
                      searchRadius === radius ? "#FFFFFF" : colors.foreground,
                  },
                ]}
              >
                {radius} mi
              </Text>
            </Pressable>
          ))}
        </View>
      </View>

      {/* Error/Info Banner */}
      {errorMsg && !loading && (
        <View style={styles.bannerContainer}>
          <View
            style={[
              styles.infoBanner,
              { backgroundColor: colors.warning + "18" },
            ]}
          >
            <IconSymbol
              name="info.circle.fill"
              size={16}
              color={colors.warning}
            />
            <Text style={[styles.infoBannerText, { color: colors.warning }]}>
              {errorMsg}
            </Text>
          </View>
        </View>
      )}

      {/* Station List */}
      {loading ? (
        <View style={styles.loadingContainer}>
          <ActivityIndicator size="large" color={colors.primary} />
          <Text style={[styles.loadingText, { color: colors.muted }]}>
            Finding E85 stations near you...
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
          refreshing={refreshing}
          onRefresh={handleRefresh}
          ListEmptyComponent={
            !errorMsg ? (
              <View style={styles.emptyState}>
                <View
                  style={[
                    styles.emptyIconBg,
                    { backgroundColor: colors.primary + "15" },
                  ]}
                >
                  <IconSymbol
                    name="map.fill"
                    size={40}
                    color={colors.primary}
                  />
                </View>
                <Text
                  style={[styles.emptyTitle, { color: colors.foreground }]}
                >
                  No Stations Found
                </Text>
                <Text
                  style={[styles.emptySubtitle, { color: colors.muted }]}
                >
                  Try increasing the search radius or check your internet
                  connection.
                </Text>
              </View>
            ) : null
          }
        />
      )}

      {/* Data Attribution */}
      {stations.length > 0 && (
        <View style={styles.attribution}>
          <Text style={[styles.attributionText, { color: colors.muted }]}>
            Data from U.S. Department of Energy AFDC
          </Text>
        </View>
      )}

      {/* Price Update Modal */}
      <PriceUpdateModal
        visible={priceModalVisible}
        stationName={priceModalStation?.name || "Station"}
        onClose={() => setPriceModalVisible(false)}
        onSubmit={handlePriceSubmit}
        isLoading={submittingPrice}
      />
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  header: {
    paddingHorizontal: 20,
    paddingTop: 8,
    paddingBottom: 12,
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
  headerTextCol: {
    flex: 1,
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
  refreshButton: {
    width: 40,
    height: 40,
    borderRadius: 12,
    alignItems: "center",
    justifyContent: "center",
  },
  radiusContainer: {
    paddingHorizontal: 20,
    paddingBottom: 14,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
  },
  radiusLabel: {
    fontSize: 13,
    fontWeight: "500",
  },
  radiusChips: {
    flexDirection: "row",
    gap: 8,
    flex: 1,
  },
  radiusChip: {
    paddingHorizontal: 14,
    paddingVertical: 7,
    borderRadius: 10,
    borderWidth: 1,
  },
  radiusChipText: {
    fontSize: 13,
    fontWeight: "600",
  },
  bannerContainer: {
    paddingHorizontal: 20,
    paddingBottom: 12,
  },
  infoBanner: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    padding: 12,
    borderRadius: 12,
  },
  infoBannerText: {
    flex: 1,
    fontSize: 13,
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
    flexGrow: 1,
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
    flexWrap: "wrap",
    gap: 8,
    marginLeft: 46,
  },
  hoursBadge: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 8,
  },
  hoursText: {
    fontSize: 12,
    fontWeight: "500",
  },
  blenderBadge: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 8,
  },
  blenderText: {
    fontSize: 12,
    fontWeight: "600",
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
  confirmedText: {
    fontSize: 11,
    fontWeight: "400",
    marginLeft: 46,
  },
  emptyState: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: 40,
    gap: 14,
    paddingTop: 60,
  },
  emptyIconBg: {
    width: 80,
    height: 80,
    borderRadius: 24,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 8,
  },
  emptyTitle: {
    fontSize: 20,
    fontWeight: "700",
    textAlign: "center",
  },
  emptySubtitle: {
    fontSize: 15,
    textAlign: "center",
    lineHeight: 22,
  },
  pricesSection: {
    borderTopWidth: 1,
    paddingHorizontal: 16,
    paddingVertical: 12,
    marginTop: 8,
  },
  priceRow: {
    flexDirection: "row",
    justifyContent: "space-around",
    marginBottom: 8,
  },
  priceItem: {
    alignItems: "center",
    gap: 4,
  },
  priceLabel: {
    fontSize: 11,
    fontWeight: "500",
  },
  priceValue: {
    fontSize: 14,
    fontWeight: "700",
  },
  priceSource: {
    fontSize: 10,
    fontWeight: "400",
    textAlign: "center",
  },
  attribution: {
    paddingHorizontal: 20,
    paddingVertical: 8,
    alignItems: "center",
  },
  attributionText: {
    fontSize: 11,
    fontWeight: "400",
  },
});

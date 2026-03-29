import React, { useState, useEffect, useCallback, useRef } from "react";
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
import { StationMap } from "@/components/station-map";
type Region = { latitude: number; longitude: number; latitudeDelta: number; longitudeDelta: number };
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
  addStationPrice,
  formatPriceAge,
  isPriceStale,
} from "@/lib/station-prices";
import {
  getCachedStations,
  setCachedStations,
  invalidateStationCache,
  getStationCacheAge,
} from "@/lib/station-cache";
import {
  loadFavorites,
  addFavorite,
  removeFavorite,
  isFavorited,
  type StationFavorite,
} from "@/lib/station-favorites";
import {
  getStationVotes,
  castVote,
  getConfidenceScore,
  type StationVote,
} from "@/lib/station-votes";

const SCREEN_WIDTH = Dimensions.get("window").width;

/** Compute a region that fits all station markers plus the user location */
function computeRegion(
  userLat: number,
  userLon: number,
  stations: E85Station[]
): Region {
  if (stations.length === 0) {
    return {
      latitude: userLat,
      longitude: userLon,
      latitudeDelta: 0.3,
      longitudeDelta: 0.3,
    };
  }
  const lats = [userLat, ...stations.map((s) => s.latitude)];
  const lons = [userLon, ...stations.map((s) => s.longitude)];
  const minLat = Math.min(...lats);
  const maxLat = Math.max(...lats);
  const minLon = Math.min(...lons);
  const maxLon = Math.max(...lons);
  const padding = 0.15;
  return {
    latitude: (minLat + maxLat) / 2,
    longitude: (minLon + maxLon) / 2,
    latitudeDelta: maxLat - minLat + padding,
    longitudeDelta: maxLon - minLon + padding,
  };
}

export default function StationsScreen() {
  const colors = useColors();
  const mapRef = useRef<any>(null);

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
  const [userPrices, setUserPrices] = useState<Record<string, any>>({});
  const [submittingPrice, setSubmittingPrice] = useState(false);
  const [viewMode, setViewMode] = useState<"list" | "map">("list");
  const [cacheAgeMin, setCacheAgeMin] = useState<number | null>(null);
  const [hasLocationPermission, setHasLocationPermission] = useState(false);
  const [favoriteIds, setFavoriteIds] = useState<Set<string>>(new Set());
  const [stationVotes, setStationVotes] = useState<Record<string, StationVote>>({});

  // Load favorites on mount
  useEffect(() => {
    loadFavorites().then((favs) => {
      setFavoriteIds(new Set(favs.map((f) => f.stationId)));
    });
  }, []);

  // Load votes whenever stations change
  useEffect(() => {
    if (stations.length > 0) {
      getStationVotes(stations.map((s) => s.id)).then(setStationVotes);
    }
  }, [stations]);

  const handleVote = useCallback(async (stationId: string, vote: "yes" | "no") => {
    if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    const updated = await castVote(stationId, vote);
    setStationVotes((prev) => ({ ...prev, [stationId]: updated }));
  }, []);

  const handleToggleFavorite = useCallback(
    async (station: E85Station) => {
      if (Platform.OS !== "web") {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
      }
      const alreadyFav = favoriteIds.has(station.id);
      if (alreadyFav) {
        await removeFavorite(station.id);
        setFavoriteIds((prev) => {
          const next = new Set(prev);
          next.delete(station.id);
          return next;
        });
      } else {
        await addFavorite({
          stationId: station.id,
          stationName: station.name,
          city: station.city,
          state: station.state,
          latitude: station.latitude,
          longitude: station.longitude,
          addedDate: new Date().toISOString(),
        });
        setFavoriteIds((prev) => new Set([...prev, station.id]));
      }
    },
    [favoriteIds]
  );

  const loadStations = useCallback(
    async (
      lat: number,
      lon: number,
      radius: number = searchRadius,
      forceRefresh = false
    ) => {
      try {
        // Try cache first (unless forced refresh)
        if (!forceRefresh) {
          const cached = await getCachedStations(lat, lon, radius);
          if (cached) {
            setStations(cached);
            const age = await getStationCacheAge(lat, lon, radius);
            setCacheAgeMin(age);
            if (cached.length === 0) {
              setErrorMsg(
                `No E85 stations found within ${radius} miles. Try increasing the search radius.`
              );
            } else {
              setErrorMsg(null);
            }
            return;
          }
        }

        // Cache miss or forced refresh — hit the API
        setCacheAgeMin(null);
        const results = await fetchNearbyStations(lat, lon, radius, 30);
        setStations(results);

        // Write to cache
        await setCachedStations(lat, lon, radius, results);
        setCacheAgeMin(0);

        if (results.length === 0) {
          setErrorMsg(
            `No E85 stations found within ${radius} miles. Try increasing the search radius.`
          );
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
      const prices = await fetchFuelPrices();
      setFuelPrices(prices);

      try {
        const { status } = await Location.requestForegroundPermissionsAsync();
        if (status !== "granted") {
          setHasLocationPermission(false);
          setErrorMsg("Location permission denied. Showing stations near Phoenix, AZ.");
          const defaultLat = 33.4484;
          const defaultLon = -112.074;
          setLocation({ latitude: defaultLat, longitude: defaultLon });
          await loadStations(defaultLat, defaultLon);
          setLoading(false);
          return;
        }
        setHasLocationPermission(true);

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

  // Animate map to fit all pins when switching to map view
  useEffect(() => {
    if (viewMode === "map" && location && stations.length > 0 && mapRef.current) {
      const region = computeRegion(location.latitude, location.longitude, stations);
      setTimeout(() => {
        mapRef.current?.animateToRegion(region, 600);
      }, 300);
    }
  }, [viewMode, stations, location]);

  const handleRefresh = useCallback(async () => {
    if (!location) return;
    setRefreshing(true);
    await invalidateStationCache(location.latitude, location.longitude, searchRadius);
    await loadStations(location.latitude, location.longitude, searchRadius, true);
    setRefreshing(false);
  }, [location, loadStations, searchRadius]);

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

  const handlePriceUpdate = useCallback((station: E85Station) => {
    setPriceModalStation(station);
    setPriceModalVisible(true);
  }, []);

  const handlePriceSubmit = useCallback(
    async (
      e85Price?: number,
      octane87Price?: number,
      octane89Price?: number,
      octane9194Price?: number
    ) => {
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

  const handleMarkerPress = useCallback(
    (station: E85Station) => {
      if (Platform.OS !== "web") {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
      }
      setSelectedStation((prev) => (prev?.id === station.id ? null : station));
      // Animate map to the tapped station
      mapRef.current?.animateToRegion(
        {
          latitude: station.latitude,
          longitude: station.longitude,
          latitudeDelta: 0.04,
          longitudeDelta: 0.04,
        },
        400
      );
    },
    []
  );

  const renderStationCard = useCallback(
    ({ item, index }: { item: E85Station; index: number }) => (
      <Animated.View entering={FadeInDown.duration(250).delay(Math.min(index * 40, 400))}>
        <Pressable
          onPress={() => {
            if (Platform.OS !== "web") {
              Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
            }
            setSelectedStation(selectedStation?.id === item.id ? null : item);
          }}
          style={({ pressed }) => [
            styles.stationCard,
            {
              backgroundColor: colors.surface,
              borderColor:
                selectedStation?.id === item.id ? colors.primary : colors.border,
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
                  <IconSymbol name="fuelpump.fill" size={18} color={colors.primary} />
                </View>
                <View style={styles.stationNameCol}>
                  <Text
                    style={[styles.stationName, { color: colors.foreground }]}
                    numberOfLines={1}
                  >
                    {item.name}
                  </Text>
                  {item.brand && (
                    <Text style={[styles.stationBrand, { color: colors.muted }]}>
                      {item.brand}
                    </Text>
                  )}
                </View>
              </View>
              <View style={styles.distanceBadge}>
                <Text style={[styles.distanceText, { color: colors.primary }]}>
                  {item.distance < 1
                    ? `${(item.distance * 5280).toFixed(0)} ft`
                    : `${item.distance.toFixed(1)} mi`}
                </Text>
              </View>
              <Pressable
                onPress={(e) => {
                  e.stopPropagation?.();
                  handleToggleFavorite(item);
                }}
                style={({ pressed }) => [styles.starBtn, pressed && { opacity: 0.6 }]}
                hitSlop={8}
              >
                <IconSymbol
                  name={favoriteIds.has(item.id) ? "star.fill" : "star"}
                  size={20}
                  color={favoriteIds.has(item.id) ? "#F59E0B" : colors.muted}
                />
              </Pressable>
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
                  style={[styles.hoursBadge, { backgroundColor: colors.muted + "15" }]}
                >
                  <Text style={[styles.hoursText, { color: colors.muted }]} numberOfLines={1}>
                    {item.hours}
                  </Text>
                </View>
              )}
              {item.hasBlenderPump && (
                <View
                  style={[styles.blenderBadge, { backgroundColor: colors.primary + "15" }]}
                >
                  <Text style={[styles.blenderText, { color: colors.primary }]}>
                    Blender Pump
                  </Text>
                </View>
              )}
              {item.facilityType && (
                <View
                  style={[styles.hoursBadge, { backgroundColor: colors.muted + "15" }]}
                >
                  <Text style={[styles.hoursText, { color: colors.muted }]}>
                    {item.facilityType}
                  </Text>
                </View>
              )}
            </View>
          </View>

          {/* User-Submitted Prices */}
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
                    <Text style={[styles.priceLabel, { color: colors.muted }]}>E85</Text>
                    <View style={styles.priceValueRow}>
                      <Text style={[styles.priceValue, { color: "#10B981" }]}>
                        ${userPrices[item.id].e85Price.toFixed(2)}
                      </Text>
                      <Text
                        style={[
                          styles.priceFreshness,
                          {
                            color: isPriceStale(userPrices[item.id].timestamp)
                              ? colors.warning
                              : colors.muted,
                          },
                        ]}
                      >
                        {isPriceStale(userPrices[item.id].timestamp) ? "⚠ " : "· "}
                        {formatPriceAge(userPrices[item.id].timestamp)}
                      </Text>
                    </View>
                  </View>
                )}
                {userPrices[item.id].octane87Price && (
                  <View style={styles.priceItem}>
                    <Text style={[styles.priceLabel, { color: colors.muted }]}>87</Text>
                    <Text style={[styles.priceValue, { color: "#3B82F6" }]}>
                      ${userPrices[item.id].octane87Price.toFixed(2)}
                    </Text>
                  </View>
                )}
                {userPrices[item.id].octane89Price && (
                  <View style={styles.priceItem}>
                    <Text style={[styles.priceLabel, { color: colors.muted }]}>89</Text>
                    <Text style={[styles.priceValue, { color: "#F59E0B" }]}>
                      ${userPrices[item.id].octane89Price.toFixed(2)}
                    </Text>
                  </View>
                )}
                {userPrices[item.id].octane9194Price && (
                  <View style={styles.priceItem}>
                    <Text style={[styles.priceLabel, { color: colors.muted }]}>91/94</Text>
                    <Text style={[styles.priceValue, { color: "#EF4444" }]}>
                      ${userPrices[item.id].octane9194Price.toFixed(2)}
                    </Text>
                  </View>
                )}
              </View>
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
                  <Text style={[styles.priceLabel, { color: colors.muted }]}>E85 Avg</Text>
                  <Text style={[styles.priceValue, { color: colors.primary }]}>
                    ${fuelPrices.e85Price.toFixed(2)}/gal
                  </Text>
                </View>
                <View style={styles.priceItem}>
                  <Text style={[styles.priceLabel, { color: colors.muted }]}>Gas Avg</Text>
                  <Text style={[styles.priceValue, { color: colors.foreground }]}>
                    ${fuelPrices.gasolinePrice.toFixed(2)}/gal
                  </Text>
                </View>
                <View style={styles.priceItem}>
                  <Text style={[styles.priceLabel, { color: colors.muted }]}>Savings</Text>
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

          {/* E85 Availability Voting Row */}
          {(() => {
            const vote = stationVotes[item.id];
            const confidence = vote ? getConfidenceScore(vote) : -1;
            const total = vote ? vote.yesCount + vote.noCount : 0;
            return (
              <View style={[styles.votingRow, { borderTopColor: colors.border }]}>
                <View style={styles.votingLeft}>
                  <Text style={[styles.votingLabel, { color: colors.muted }]}>
                    E85 Available?
                  </Text>
                  {total > 0 && confidence >= 0 && (
                    <Text style={[styles.votingStats, {
                      color: confidence >= 70 ? colors.success : confidence >= 40 ? colors.warning : colors.error
                    }]}>
                      {confidence}% yes · {total} vote{total !== 1 ? "s" : ""}
                    </Text>
                  )}
                  {total === 0 && (
                    <Text style={[styles.votingStats, { color: colors.muted }]}>No votes yet</Text>
                  )}
                </View>
                <View style={styles.votingButtons}>
                  <Pressable
                    onPress={(e) => { e.stopPropagation?.(); handleVote(item.id, "yes"); }}
                    style={({ pressed }) => [
                      styles.voteBtn,
                      {
                        backgroundColor: vote?.userVote === "yes" ? colors.success + "22" : colors.surface,
                        borderColor: vote?.userVote === "yes" ? colors.success : colors.border,
                      },
                      pressed && { opacity: 0.7, transform: [{ scale: 0.95 }] },
                    ]}
                    hitSlop={6}
                  >
                    <Text style={[styles.voteBtnText, { color: vote?.userVote === "yes" ? colors.success : colors.muted }]}>
                      👍 {vote?.yesCount ?? 0}
                    </Text>
                  </Pressable>
                  <Pressable
                    onPress={(e) => { e.stopPropagation?.(); handleVote(item.id, "no"); }}
                    style={({ pressed }) => [
                      styles.voteBtn,
                      {
                        backgroundColor: vote?.userVote === "no" ? colors.error + "22" : colors.surface,
                        borderColor: vote?.userVote === "no" ? colors.error : colors.border,
                      },
                      pressed && { opacity: 0.7, transform: [{ scale: 0.95 }] },
                    ]}
                    hitSlop={6}
                  >
                    <Text style={[styles.voteBtnText, { color: vote?.userVote === "no" ? colors.error : colors.muted }]}>
                      👎 {vote?.noCount ?? 0}
                    </Text>
                  </Pressable>
                </View>
              </View>
            );
          })()}

          {selectedStation?.id === item.id && (
            <Animated.View entering={FadeIn.duration(200)} style={styles.stationActions}>
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
                  <IconSymbol name="navigation.fill" size={16} color="#FFFFFF" />
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
                <IconSymbol name="dollarsign.circle.fill" size={16} color={colors.primary} />
                <Text style={[styles.callButtonText, { color: colors.primary }]}>
                  Update Price
                </Text>
              </Pressable>
              {item.phone && (
                <Pressable
                  onPress={() => Linking.openURL(`tel:${item.phone}`)}
                  style={({ pressed }) => [
                    styles.callButton,
                    { borderColor: colors.primary },
                    pressed && { opacity: 0.7 },
                  ]}
                >
                  <Text style={[styles.callButtonText, { color: colors.primary }]}>Call</Text>
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
    [colors, selectedStation, openDirections, fuelPrices, userPrices, handlePriceUpdate, stationVotes, handleVote, favoriteIds, handleToggleFavorite]
  );

  return (
    <ScreenContainer>
      {/* Header */}
      <View style={styles.header}>
        <View style={styles.headerRow}>
          <View
            style={[styles.headerIconBg, { backgroundColor: colors.primary + "18" }]}
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
                : cacheAgeMin !== null
                ? `${stations.length} stations · cached ${cacheAgeMin === 0 ? "just now" : `${cacheAgeMin}m ago`}`
                : `${stations.length} station${stations.length !== 1 ? "s" : ""} found`}
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
              <IconSymbol name="arrow.clockwise" size={18} color={colors.primary} />
            </Pressable>
          )}
        </View>
      </View>

      {/* Controls Row: radius chips + view toggle */}
      <View style={styles.controlsRow}>
        <View style={styles.radiusChips}>
          {[10, 25, 50, 100].map((radius) => (
            <Pressable
              key={radius}
              onPress={() => handleRadiusChange(radius)}
              style={({ pressed }) => [
                styles.radiusChip,
                {
                  backgroundColor:
                    searchRadius === radius ? colors.primary : colors.background,
                  borderColor:
                    searchRadius === radius ? colors.primary : colors.border,
                },
                pressed && { transform: [{ scale: 0.97 }] },
              ]}
            >
              <Text
                style={[
                  styles.radiusChipText,
                  { color: searchRadius === radius ? "#FFFFFF" : colors.foreground },
                ]}
              >
                {radius} mi
              </Text>
            </Pressable>
          ))}
        </View>

        {/* List / Map toggle */}
        <View
          style={[
            styles.viewToggle,
            { backgroundColor: colors.surface, borderColor: colors.border },
          ]}
        >
          <Pressable
            onPress={() => {
              if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
              setViewMode("list");
            }}
            style={[
              styles.toggleBtn,
              viewMode === "list" && { backgroundColor: colors.primary },
            ]}
          >
            <IconSymbol
              name="list.bullet"
              size={16}
              color={viewMode === "list" ? "#FFFFFF" : colors.muted}
            />
          </Pressable>
          <Pressable
            onPress={() => {
              if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
              setViewMode("map");
            }}
            style={[
              styles.toggleBtn,
              viewMode === "map" && { backgroundColor: colors.primary },
            ]}
          >
            <IconSymbol
              name="map"
              size={16}
              color={viewMode === "map" ? "#FFFFFF" : colors.muted}
            />
          </Pressable>
        </View>
      </View>

      {/* Error/Info Banner */}
      {errorMsg && !loading && (
        <View style={styles.bannerContainer}>
          <View style={[styles.infoBanner, { backgroundColor: colors.warning + "18" }]}>
            <IconSymbol name="info.circle.fill" size={16} color={colors.warning} />
            <Text style={[styles.infoBannerText, { color: colors.warning }]}>
              {errorMsg}
            </Text>
          </View>
        </View>
      )}

      {/* Content: Loading / Map / List */}
      {loading ? (
        <View style={styles.loadingContainer}>
          <ActivityIndicator size="large" color={colors.primary} />
          <Text style={[styles.loadingText, { color: colors.muted }]}>
            Finding E85 stations near you...
          </Text>
        </View>
      ) : viewMode === "map" ? (
        /* ── MAP VIEW ── */
        <View style={styles.mapContainer}>
          <StationMap
            mapRef={mapRef}
            initialRegion={
              location
                ? computeRegion(location.latitude, location.longitude, stations)
                : {
                    latitude: 33.4484,
                    longitude: -112.074,
                    latitudeDelta: 0.5,
                    longitudeDelta: 0.5,
                  }
            }
            userLocation={location}
            stations={stations}
            selectedStationId={selectedStation?.id ?? null}
            primaryColor={colors.primary}
            surfaceColor={colors.surface}
            borderColor={colors.border}
            hasLocationPermission={hasLocationPermission}
            onMarkerPress={handleMarkerPress}
            onRecenter={() => {
              if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
              if (location) {
                const region = computeRegion(location.latitude, location.longitude, stations);
                mapRef.current?.animateToRegion(region, 600);
              }
            }}
          />

          {/* Selected station card overlay */}
          {selectedStation && (
            <Animated.View
              entering={FadeInDown.duration(250)}
              style={[
                styles.mapCallout,
                {
                  backgroundColor: colors.surface,
                  borderColor: colors.primary,
                },
              ]}
            >
              <View style={styles.mapCalloutHeader}>
                <View style={{ flex: 1 }}>
                  <Text
                    style={[styles.mapCalloutName, { color: colors.foreground }]}
                    numberOfLines={1}
                  >
                    {selectedStation.name}
                  </Text>
                  <Text style={[styles.mapCalloutAddr, { color: colors.muted }]} numberOfLines={1}>
                    {selectedStation.address}, {selectedStation.city}
                  </Text>
                </View>
                <Text style={[styles.mapCalloutDist, { color: colors.primary }]}>
                  {selectedStation.distance.toFixed(1)} mi
                </Text>
              </View>
              <View style={styles.mapCalloutActions}>
                <Pressable
                  onPress={() => openDirections(selectedStation)}
                  style={({ pressed }) => [
                    styles.mapCalloutBtn,
                    { backgroundColor: colors.primary },
                    pressed && { opacity: 0.8 },
                  ]}
                >
                  <IconSymbol name="navigation.fill" size={14} color="#FFFFFF" />
                  <Text style={styles.mapCalloutBtnText}>Directions</Text>
                </Pressable>
                <Pressable
                  onPress={() => handlePriceUpdate(selectedStation)}
                  style={({ pressed }) => [
                    styles.mapCalloutBtn,
                    {
                      backgroundColor: colors.primary + "18",
                      borderWidth: 1,
                      borderColor: colors.primary,
                    },
                    pressed && { opacity: 0.8 },
                  ]}
                >
                  <IconSymbol name="dollarsign.circle.fill" size={14} color={colors.primary} />
                  <Text style={[styles.mapCalloutBtnText, { color: colors.primary }]}>
                    Price
                  </Text>
                </Pressable>
                <Pressable
                  onPress={() => setSelectedStation(null)}
                  style={({ pressed }) => [
                    styles.mapCalloutCloseBtn,
                    { backgroundColor: colors.border },
                    pressed && { opacity: 0.7 },
                  ]}
                >
                  <IconSymbol name="xmark" size={14} color={colors.muted} />
                </Pressable>
              </View>
            </Animated.View>
          )}

          {/* Re-center button */}
          {location && (
            <Pressable
              onPress={() => {
                if (Platform.OS !== "web") Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                const region = computeRegion(location.latitude, location.longitude, stations);
                mapRef.current?.animateToRegion(region, 600);
              }}
              style={({ pressed }) => [
                styles.recenterBtn,
                { backgroundColor: colors.surface, borderColor: colors.border },
                pressed && { opacity: 0.7 },
              ]}
            >
              <IconSymbol name="location.circle.fill" size={22} color={colors.primary} />
            </Pressable>
          )}
        </View>
      ) : (
        /* ── LIST VIEW ── */
        <FlatList
          data={[...stations].sort((a, b) => {
            const aFav = favoriteIds.has(a.id) ? 0 : 1;
            const bFav = favoriteIds.has(b.id) ? 0 : 1;
            return aFav - bFav;
          })}
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
                  style={[styles.emptyIconBg, { backgroundColor: colors.primary + "15" }]}
                >
                  <IconSymbol name="map.fill" size={40} color={colors.primary} />
                </View>
                <Text style={[styles.emptyTitle, { color: colors.foreground }]}>
                  No Stations Found
                </Text>
                <Text style={[styles.emptySubtitle, { color: colors.muted }]}>
                  Try increasing the search radius or check your internet connection.
                </Text>
              </View>
            ) : null
          }
          ListFooterComponent={
            stations.length > 0 ? (
              <View style={styles.attribution}>
                <Text style={[styles.attributionText, { color: colors.muted }]}>
                  Data from U.S. Department of Energy AFDC
                </Text>
              </View>
            ) : null
          }
        />
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
  // Controls row
  controlsRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 20,
    paddingBottom: 14,
    gap: 10,
  },
  radiusChips: {
    flexDirection: "row",
    gap: 8,
    flex: 1,
  },
  radiusChip: {
    paddingHorizontal: 12,
    paddingVertical: 7,
    borderRadius: 10,
    borderWidth: 1,
  },
  radiusChipText: {
    fontSize: 13,
    fontWeight: "600",
  },
  viewToggle: {
    flexDirection: "row",
    borderRadius: 10,
    borderWidth: 1,
    overflow: "hidden",
  },
  toggleBtn: {
    width: 36,
    height: 34,
    alignItems: "center",
    justifyContent: "center",
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
  // Map view
  mapContainer: {
    flex: 1,
    position: "relative",
  },
  mapWebFallback: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: 12,
  },
  mapWebText: {
    fontSize: 15,
    textAlign: "center",
    paddingHorizontal: 40,
  },
  mapCallout: {
    position: "absolute",
    bottom: 100,
    left: 16,
    right: 16,
    borderRadius: 16,
    borderWidth: 1.5,
    padding: 14,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.15,
    shadowRadius: 12,
    elevation: 8,
  },
  mapCalloutHeader: {
    flexDirection: "row",
    alignItems: "flex-start",
    gap: 10,
    marginBottom: 10,
  },
  mapCalloutName: {
    fontSize: 15,
    fontWeight: "700",
  },
  mapCalloutAddr: {
    fontSize: 12,
    marginTop: 2,
  },
  mapCalloutDist: {
    fontSize: 14,
    fontWeight: "700",
  },
  mapCalloutActions: {
    flexDirection: "row",
    gap: 8,
    alignItems: "center",
  },
  mapCalloutBtn: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
    paddingHorizontal: 14,
    paddingVertical: 9,
    borderRadius: 10,
  },
  mapCalloutBtnText: {
    fontSize: 13,
    fontWeight: "700",
    color: "#FFFFFF",
  },
  mapCalloutCloseBtn: {
    width: 34,
    height: 34,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
    marginLeft: "auto",
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
  // List view
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
    paddingHorizontal: 14,
    paddingVertical: 14,
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
    flexWrap: "wrap",
    gap: 8,
    paddingTop: 4,
  },
  directionButton: {
    flex: 1,
    minWidth: 140,
    borderRadius: 12,
    overflow: "hidden",
  },
  directionGradient: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 6,
    paddingVertical: 11,
    paddingHorizontal: 12,
  },
  directionText: {
    color: "#FFFFFF",
    fontSize: 13,
    fontWeight: "700",
  },
  callButton: {
    paddingHorizontal: 12,
    paddingVertical: 11,
    borderRadius: 12,
    borderWidth: 1.5,
    alignItems: "center",
    justifyContent: "center",
    flexDirection: "row",
    gap: 5,
  },
  callButtonText: {
    fontSize: 13,
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
  priceValueRow: {
    flexDirection: "row",
    alignItems: "baseline",
    gap: 4,
  },
  priceFreshness: {
    fontSize: 11,
    fontWeight: "400",
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
  starBtn: {
    padding: 4,
    marginLeft: 4,
  },
  votingRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
    marginTop: 4,
  },
  votingLeft: {
    flex: 1,
    gap: 2,
  },
  votingLabel: {
    fontSize: 12,
    fontWeight: "600",
  },
  votingStats: {
    fontSize: 11,
    fontWeight: "500",
  },
  votingButtons: {
    flexDirection: "row",
    gap: 8,
  },
  voteBtn: {
    paddingHorizontal: 12,
    paddingVertical: 7,
    borderRadius: 20,
    borderWidth: 1.5,
    alignItems: "center",
    justifyContent: "center",
    minWidth: 60,
  },
  voteBtnText: {
    fontSize: 13,
    fontWeight: "600",
  },
});

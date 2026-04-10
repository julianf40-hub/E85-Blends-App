import React, { useEffect, useCallback, useRef } from "react";
import { useFocusEffect } from "expo-router";
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
  RefreshControl,
} from "react-native";
import { StationMap } from "@/components/station-map";
type Region = { latitude: number; longitude: number; latitudeDelta: number; longitudeDelta: number };
import Animated, { FadeIn, FadeInDown } from "react-native-reanimated";
import * as Haptics from "expo-haptics";
import * as Location from "expo-location";
import { ScreenContainer } from "@/components/screen-container";
import { IconSymbol } from "@/components/ui/icon-symbol";
import { useColors } from "@/hooks/use-colors";
import { E85Station } from "@/lib/station-data";
import { getE85StateAverage } from "@/lib/fuel-prices";
import { PriceUpdateModal } from "@/components/price-update-modal";
import { formatPriceAge, isPriceStale } from "@/lib/station-prices";
import { getConfidenceScore } from "@/lib/station-votes";
import { useStationsData } from "@/hooks/use-stations-data";
import { useStationsInteractions } from "@/hooks/use-stations-interactions";
import { usePreferencesContext } from "@/lib/preferences-context";
import { StationsHeader } from "@/components/stations/stations-header";
import { StationsControls } from "@/components/stations/stations-controls";
import { LocationDeniedBanner, StationsErrorBanner } from "@/components/stations/stations-banners";

const SCREEN_WIDTH = Dimensions.get("window").width;
const DAY_MS = 24 * 60 * 60 * 1000;

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

type StationPriceSummary = {
  price: number;
  sourceLabel: string;
  sublabel: string;
  stale: boolean;
  updatedLabel?: string;
  isEstimate: boolean;
};

function getStationPriceSummary(
  station: E85Station,
  userPrice: { e85Price?: number; timestamp?: number } | undefined,
  communityPrice: { e85Price?: number; reportCount: number; freshestTimestamp?: number } | undefined,
  localPrices: { e85Price: number | null; gasPrice: number | null; gasPricePeriod: string | null } | null,
): StationPriceSummary {
  // Tier 1: User's own logged price
  if (userPrice?.e85Price != null && userPrice.timestamp != null) {
    const stale = isPriceStale(userPrice.timestamp);
    return {
      price: userPrice.e85Price,
      sourceLabel: "Your logged E85",
      sublabel: stale ? "Your pump report (stale)" : "Your pump report",
      stale,
      updatedLabel: formatPriceAge(userPrice.timestamp),
      isEstimate: false,
    };
  }

  // Tier 2: Community price (aggregated local reports)
  if (communityPrice?.e85Price != null && communityPrice.reportCount > 0) {
    const stale = communityPrice.freshestTimestamp != null && isPriceStale(communityPrice.freshestTimestamp);
    const countLabel = communityPrice.reportCount === 1 ? "1 report" : `${communityPrice.reportCount} reports`;
    return {
      price: communityPrice.e85Price,
      sourceLabel: "Community E85",
      sublabel: stale ? `Community (stale · ${countLabel})` : `Community · ${countLabel}`,
      stale,
      updatedLabel: communityPrice.freshestTimestamp != null ? formatPriceAge(communityPrice.freshestTimestamp) : undefined,
      isEstimate: false,
    };
  }

  // Tier 3: State/regional average fallback
  const stateAvg = localPrices?.e85Price ?? getE85StateAverage(station.state);
  return {
    price: stateAvg,
    sourceLabel: `${station.state} avg`,
    sublabel: "EIA estimate — no reports yet",
    stale: false,
    isEstimate: true,
  };
}

function getTrustBadges(
  station: E85Station,
  summary: StationPriceSummary,
  confidence: number,
  voteTotal: number,
) {
  const badges: Array<{ label: string; tone: "success" | "warn" | "muted" | "accent" }> = [];
  if (!summary.isEstimate) {
    if (summary.sourceLabel === "Community E85") {
      badges.push({ label: summary.stale ? "Community (stale)" : "Community", tone: summary.stale ? "warn" : "accent" });
    } else {
      badges.push({ label: summary.stale ? "Price stale" : "Your log", tone: summary.stale ? "warn" : "success" });
    }
  } else {
    badges.push({ label: "Estimated", tone: "muted" });
  }

  if (station.lastConfirmed) {
    const confirmedAt = new Date(station.lastConfirmed).getTime();
    if (!Number.isNaN(confirmedAt)) {
      const ageDays = Math.floor((Date.now() - confirmedAt) / DAY_MS);
      if (ageDays <= 1) badges.push({ label: "Confirmed today", tone: "success" });
      else if (ageDays <= 30) badges.push({ label: `Confirmed ${ageDays}d`, tone: "accent" });
    }
  }

  if (voteTotal > 0) {
    if (confidence >= 70) badges.push({ label: `Local votes ${confidence}%`, tone: "success" });
    else if (confidence <= 40) badges.push({ label: `Mixed votes ${confidence}%`, tone: "warn" });
    else badges.push({ label: `Local votes ${confidence}%`, tone: "accent" });
  }
  return badges.slice(0, 3);
}

export default function StationsScreen() {
  const colors = useColors();
  const mapRef = useRef<any>(null);
  const { prefs } = usePreferencesContext();
  const {
    location,
    stations,
    loading,
    refreshing,
    errorMsg,
    searchRadius,
    fuelPrices,
    localPrices,
    cacheAgeMin,
    hasLocationPermission,
    setErrorMsg,
    setHasLocationPermission,
    setLoading,
    setLocation,
    loadStations,
    handleRefresh,
    handleRadiusChange,
  } = useStationsData();

  const {
    selectedStation,
    setSelectedStation,
    sortMode,
    setSortMode,
    priceModalVisible,
    setPriceModalVisible,
    priceModalStation,
    userPrices,
    communityPrices,
    submittingPrice,
    viewMode,
    setViewMode,
    favoriteIds,
    stationVotes,
    filterConfirmed,
    setFilterConfirmed,
    handleVote,
    handleToggleFavorite,
    handlePriceUpdate,
    handlePriceSubmit,
    sortedStations,
    refreshUserPrices,
  } = useStationsInteractions(stations, localPrices);

  // Refresh user/community prices every time this tab comes into focus
  // (e.g. after a fuel log save writes a new price)
  useFocusEffect(
    useCallback(() => {
      refreshUserPrices();
    }, [refreshUserPrices])
  );

  // Animate map to fit all pins when switching to map view
  useEffect(() => {
    if (viewMode === "map" && location && stations.length > 0 && mapRef.current) {
      const region = computeRegion(location.latitude, location.longitude, stations);
      setTimeout(() => {
        mapRef.current?.animateToRegion(region, 600);
      }, 300);
    }
  }, [viewMode, stations, location]);

  const openDirections = useCallback((station: E85Station) => {
    if (Platform.OS !== "web") {
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    }
    const directionsApp = prefs?.directionsApp ?? "apple";
    const lat = station.latitude;
    const lon = station.longitude;
    const name = encodeURIComponent(station.name);
    let url: string | undefined;
    if (directionsApp === "google") {
      url = `https://www.google.com/maps/dir/?api=1&destination=${lat},${lon}`;
    } else if (directionsApp === "waze") {
      url = `https://waze.com/ul?ll=${lat},${lon}&navigate=yes`;
    } else {
      // Apple Maps (default) — native on iOS, fallback to Google Maps on Android/web
      url = Platform.select({
        ios: `maps:0,0?q=${lat},${lon}`,
        android: `geo:0,0?q=${lat},${lon}(${name})`,
        default: `https://www.google.com/maps/dir/?api=1&destination=${lat},${lon}`,
      });
    }
    if (url) Linking.openURL(url);
  }, [prefs?.directionsApp]);

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

	          {(() => {
	            const vote = stationVotes[item.id];
	            const confidence = vote ? getConfidenceScore(vote) : -1;
	            const total = vote ? vote.yesCount + vote.noCount : 0;
	            const summary = getStationPriceSummary(item, userPrices[item.id], communityPrices[item.id], localPrices);
	            const gasFallback = localPrices?.gasPrice ?? (fuelPrices?.gasolinePrice ?? null);
	            const savings =
	              gasFallback != null ? (1 - summary.price / gasFallback) * 100 : null;
	            const trustBadges = getTrustBadges(item, summary, confidence, total);
	            return (
	              <>
	                <View style={[styles.priceFocusRow, { borderTopColor: colors.border }]}>
	                  <View style={{ flex: 1 }}>
	                    <Text style={[styles.priceSource, { color: colors.muted }]}>
	                      {summary.sourceLabel}
	                    </Text>
	                    <Text style={[styles.priceFocusValue, { color: colors.primary }]}>
	                      ${summary.price.toFixed(2)}
	                      <Text style={[styles.pricePerGalText, { color: colors.muted }]}> /gal</Text>
	                    </Text>
	                    <Text style={[styles.priceMetaText, { color: summary.stale ? colors.warning : colors.muted }]}>
	                      {summary.sublabel}
	                      {summary.updatedLabel ? ` · ${summary.updatedLabel}` : ""}
	                    </Text>
	                  </View>
                  <Pressable
                    onPress={(e) => {
                      e.stopPropagation?.();
                      openDirections(item);
                    }}
                    style={({ pressed }) => [
                      styles.inlineDirectionsBtn,
                      { backgroundColor: colors.primary },
                      pressed && { opacity: 0.82, transform: [{ scale: 0.96 }] },
                    ]}
                  >
                    <IconSymbol name="navigation.fill" size={16} color="#fff" />
                    <Text style={[styles.inlineDirectionsText, { color: "#fff" }]}>Directions</Text>
                  </Pressable>
	                </View>

	                {trustBadges.length > 0 && (
	                  <View style={styles.badgeRow}>
	                    {trustBadges.map((badge) => {
	                      const badgeColor =
	                        badge.tone === "success"
	                          ? colors.success
	                          : badge.tone === "warn"
	                            ? colors.warning
	                            : badge.tone === "accent"
	                              ? colors.primary
	                              : colors.muted;
	                      return (
	                        <View
	                          key={badge.label}
	                          style={[
	                            styles.trustBadge,
	                            {
	                              backgroundColor: badgeColor + "20",
	                              borderColor: badgeColor + "50",
	                            },
	                          ]}
	                        >
	                          <Text style={[styles.trustBadgeText, { color: badgeColor }]}>
	                            {badge.label}
	                          </Text>
	                        </View>
	                      );
	                    })}
	                  </View>
	                )}

	                {selectedStation?.id === item.id && (
	                  <>
	                    {gasFallback != null && (
	                      <View
	                        style={[
	                          styles.pricesSection,
	                          { backgroundColor: colors.background, borderTopColor: colors.border },
	                        ]}
	                      >
	                        <View style={styles.priceRow}>
	                          <View style={styles.priceItem}>
	                            <Text style={[styles.priceLabel, { color: colors.muted }]}>
	                              Gas benchmark ({item.state})
	                            </Text>
	                            <Text style={[styles.priceValue, { color: colors.foreground }]}>
	                              ${gasFallback.toFixed(2)}/gal
	                            </Text>
	                          </View>
	                          {savings != null && (
	                            <View style={styles.priceItem}>
	                              <Text style={[styles.priceLabel, { color: colors.muted }]}>
	                                E85 vs gas
	                              </Text>
	                              <Text style={[styles.priceValue, { color: colors.success }]}>
	                                {savings.toFixed(0)}%
	                              </Text>
	                            </View>
	                          )}
	                        </View>
	                        <Text style={[styles.priceSource, { color: colors.muted }]}>
	                          {localPrices?.gasPricePeriod
	                            ? `Gas: EIA weekly (week of ${localPrices.gasPricePeriod}) · E85 avg: AFDC`
	                            : "Benchmarks are AFDC/EIA estimates — verify at pump"}
	                        </Text>
	                      </View>
	                    )}
	                    <View style={[styles.votingRow, { borderTopColor: colors.border }]}>
	                      <View style={styles.votingLeft}>
	                        <Text style={[styles.votingLabel, { color: colors.muted }]}>
	                          E85 Available?
	                        </Text>
	                        {total > 0 && confidence >= 0 && (
	                          <Text
	                            style={[
	                              styles.votingStats,
	                              {
	                                color:
	                                  confidence >= 70
	                                    ? colors.success
	                                    : confidence >= 40
	                                      ? colors.warning
	                                      : colors.error,
	                              },
	                            ]}
	                          >
	                            {confidence}% yes · {total} vote{total !== 1 ? "s" : ""}
	                          </Text>
	                        )}
	                        {total === 0 && (
	                          <Text style={[styles.votingStats, { color: colors.muted }]}>
	                            No votes yet — be first!
	                          </Text>
	                        )}
	                        <Text
	                          style={[
	                            styles.votingStats,
	                            { color: colors.muted, fontSize: 10, marginTop: 2 },
	                          ]}
	                        >
	                          Votes are local to this device
	                        </Text>
	                      </View>
	                      <View style={styles.votingButtons}>
	                        <Pressable
	                          onPress={(e) => {
	                            e.stopPropagation?.();
	                            handleVote(item.id, "yes");
	                          }}
	                          style={({ pressed }) => [
	                            styles.voteBtn,
	                            {
	                              backgroundColor:
	                                vote?.userVote === "yes" ? colors.success + "22" : colors.surface,
	                              borderColor:
	                                vote?.userVote === "yes" ? colors.success : colors.border,
	                            },
	                            pressed && { opacity: 0.7, transform: [{ scale: 0.95 }] },
	                          ]}
	                          hitSlop={6}
	                        >
	                          <Text
	                            style={[
	                              styles.voteBtnText,
	                              { color: vote?.userVote === "yes" ? colors.success : colors.muted },
	                            ]}
	                          >
	                            👍 {vote?.yesCount ?? 0}
	                          </Text>
	                        </Pressable>
	                        <Pressable
	                          onPress={(e) => {
	                            e.stopPropagation?.();
	                            handleVote(item.id, "no");
	                          }}
	                          style={({ pressed }) => [
	                            styles.voteBtn,
	                            {
	                              backgroundColor:
	                                vote?.userVote === "no" ? colors.error + "22" : colors.surface,
	                              borderColor:
	                                vote?.userVote === "no" ? colors.error : colors.border,
	                            },
	                            pressed && { opacity: 0.7, transform: [{ scale: 0.95 }] },
	                          ]}
	                          hitSlop={6}
	                        >
	                          <Text
	                            style={[
	                              styles.voteBtnText,
	                              { color: vote?.userVote === "no" ? colors.error : colors.muted },
	                            ]}
	                          >
	                            👎 {vote?.noCount ?? 0}
	                          </Text>
	                        </Pressable>
	                      </View>
	                    </View>
	                  </>
	                )}
	              </>
	            );
	          })()}

          {selectedStation?.id === item.id && (
            <Animated.View entering={FadeIn.duration(200)} style={styles.stationActions}>
              <View style={styles.stationActionsSecondary}>
                <Pressable
                  onPress={() => handlePriceUpdate(item)}
                  style={({ pressed }) => [
                    styles.callButton,
                    { borderColor: colors.border, flex: 1 },
                    pressed && { opacity: 0.7 },
                  ]}
                >
                  <IconSymbol name="dollarsign.circle.fill" size={15} color={colors.muted} />
                  <Text style={[styles.callButtonText, { color: colors.muted }]}>
                    Update Price
                  </Text>
                </Pressable>
                {item.phone && (
                  <Pressable
                    onPress={() => Linking.openURL(`tel:${item.phone}`)}
                    style={({ pressed }) => [
                      styles.callButton,
                      { borderColor: colors.border },
                      pressed && { opacity: 0.7 },
                    ]}
                  >
                    <IconSymbol name="phone.fill" size={15} color={colors.muted} />
                    <Text style={[styles.callButtonText, { color: colors.muted }]}>Call</Text>
                  </Pressable>
                )}
              </View>
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
    [colors, selectedStation, openDirections, fuelPrices, localPrices, userPrices, handlePriceUpdate, stationVotes, handleVote, favoriteIds, handleToggleFavorite]
  );

  const handleOpenLocationSettings = useCallback(async () => {
    if (Platform.OS === "ios") {
      Linking.openURL("app-settings:");
      return;
    }

    const { status } = await Location.requestForegroundPermissionsAsync();
    if (status === "granted") {
      setHasLocationPermission(true);
      setErrorMsg(null);
      setLoading(true);
      try {
        const loc = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
        const coords = { latitude: loc.coords.latitude, longitude: loc.coords.longitude };
        setLocation(coords);
        await loadStations(coords.latitude, coords.longitude, searchRadius, true);
      } finally {
        setLoading(false);
      }
    }
  }, [loadStations, searchRadius, setErrorMsg, setHasLocationPermission, setLoading, setLocation]);

  return (
    <ScreenContainer>
      <StationsHeader
        colors={colors}
        styles={styles}
        loading={loading}
        cacheAgeMin={cacheAgeMin}
        stationsCount={stations.length}
        onRefresh={handleRefresh}
      />

      <StationsControls
        colors={colors}
        styles={styles}
        searchRadius={searchRadius}
        onRadiusChange={handleRadiusChange}
        filterConfirmed={filterConfirmed}
        onToggleConfirmed={() => setFilterConfirmed((v) => !v)}
        sortMode={sortMode}
        onSortModeChange={setSortMode}
        viewMode={viewMode}
        onViewModeChange={setViewMode}
      />

      <LocationDeniedBanner
        colors={colors}
        styles={styles}
        visible={errorMsg === "LOCATION_DENIED" && !loading}
        onOpenSettings={handleOpenLocationSettings}
        onDismiss={() => setErrorMsg(null)}
      />

      <StationsErrorBanner
        colors={colors}
        styles={styles}
        message={errorMsg}
        loading={loading}
        onRetry={handleRefresh}
      />

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
          data={sortedStations}
          renderItem={renderStationCard}
          keyExtractor={(item) => item.id}
          contentContainerStyle={styles.listContent}
          showsVerticalScrollIndicator={false}
          ItemSeparatorComponent={() => <View style={styles.separator} />}
          refreshControl={
            <RefreshControl
              refreshing={refreshing}
              onRefresh={handleRefresh}
              tintColor={colors.primary}
              colors={[colors.primary]}
              title="Refreshing stations…"
              titleColor={colors.muted}
            />
          }
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
                  Station locations: U.S. DOE AFDC · Prices: EIA weekly avg + community-reported
                </Text>
                <Text style={[styles.attributionSub, { color: colors.border }]}>
                  Prices are estimates — always verify at the pump
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
    paddingBottom: 8,
    gap: 10,
  },
  filtersRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 20,
    paddingBottom: 12,
    gap: 8,
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
    flexDirection: "column",
    gap: 0,
    paddingTop: 2,
  },
  stationActionsSecondary: {
    flexDirection: "row",
    gap: 8,
  },
  callButton: {
    paddingHorizontal: 12,
    paddingVertical: 9,
    borderRadius: 10,
    borderWidth: StyleSheet.hairlineWidth,
    alignItems: "center",
    justifyContent: "center",
    flexDirection: "row",
    gap: 5,
  },
  callButtonText: {
    fontSize: 12,
    fontWeight: "500",
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
  priceFocusRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
    marginTop: 8,
    paddingHorizontal: 16,
    paddingTop: 12,
  },
  priceFocusValue: {
    fontSize: 22,
    fontWeight: "800",
    letterSpacing: 0.2,
    marginTop: 2,
  },
  pricePerGalText: {
    fontSize: 12,
    fontWeight: "500",
  },
  priceMetaText: {
    fontSize: 10,
    fontWeight: "400",
    marginTop: 2,
    opacity: 0.8,
  },
  inlineDirectionsBtn: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 6,
    paddingHorizontal: 16,
    paddingVertical: 11,
    borderRadius: 12,
    minWidth: 120,
    minHeight: 44,
  },
  inlineDirectionsText: {
    fontSize: 13,
    fontWeight: "700",
    letterSpacing: 0.1,
  },
  badgeRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 4,
    paddingHorizontal: 16,
    paddingTop: 4,
    paddingBottom: 2,
  },
  trustBadge: {
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 999,
    paddingHorizontal: 6,
    paddingVertical: 2,
  },
  trustBadgeText: {
    fontSize: 9,
    fontWeight: "500",
    letterSpacing: 0.1,
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
    fontStyle: "italic",
    textAlign: "center",
    opacity: 0.75,
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
  attributionSub: {
    fontSize: 10,
    marginTop: 2,
    textAlign: "center",
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
  bannerBtn: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 6,
    paddingHorizontal: 14,
    paddingVertical: 9,
    borderRadius: 10,
  },
  bannerBtnText: {
    fontSize: 14,
    fontWeight: "700",
    color: "#fff",
  },
});

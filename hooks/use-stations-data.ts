import { useCallback, useEffect, useState } from "react";
import * as Location from "expo-location";
import { E85Station, fetchNearbyStations } from "@/lib/station-data";
import {
  FuelPrices,
  fetchFuelPrices,
  fetchLocalPrices,
  LocalFuelPrices,
} from "@/lib/fuel-prices";
import {
  getCachedStations,
  setCachedStations,
  invalidateStationCache,
  getStationCacheAge,
} from "@/lib/station-cache";

export function useStationsData() {
  const [location, setLocation] = useState<{ latitude: number; longitude: number } | null>(null);
  const [stations, setStations] = useState<E85Station[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [searchRadius, setSearchRadius] = useState(25);
  const [fuelPrices, setFuelPrices] = useState<FuelPrices | null>(null);
  const [localPrices, setLocalPrices] = useState<LocalFuelPrices | null>(null);
  const [cacheAgeMin, setCacheAgeMin] = useState<number | null>(null);
  const [hasLocationPermission, setHasLocationPermission] = useState(false);

  const loadStations = useCallback(
    async (
      lat: number,
      lon: number,
      radius: number = searchRadius,
      forceRefresh = false
    ) => {
      try {
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

        setCacheAgeMin(null);
        const results = await fetchNearbyStations(lat, lon, radius, 30);
        setStations(results);
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
        const errorType = err?.message;
        if (errorType === "RATE_LIMITED") {
          setErrorMsg("Station search is temporarily rate-limited. Please wait about 60 seconds, then pull to refresh.");
        } else if (errorType === "CONFIG_ERROR") {
          setErrorMsg("Station search is not configured on this server. Please contact support or try again later.");
        } else if (errorType === "NETWORK_ERROR") {
          setErrorMsg("Cannot reach server. Check your internet connection and retry now.");
        } else if (errorType === "NREL_API_ERROR") {
          setErrorMsg("E85 station data service is temporarily unavailable. Please retry in a few minutes.");
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
          setErrorMsg("LOCATION_DENIED");
          const defaultLat = 33.4484;
          const defaultLon = -112.074;
          setLocation({ latitude: defaultLat, longitude: defaultLon });
          await loadStations(defaultLat, defaultLon);
          fetchLocalPrices("AZ").then(setLocalPrices);
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
  }, [loadStations]);

  useEffect(() => {
    if (stations.length > 0) {
      const state = stations[0].state;
      if (state) {
        fetchLocalPrices(state).then(setLocalPrices);
      }
    }
  }, [stations]);

  const handleRefresh = useCallback(async () => {
    if (!location) return;
    setRefreshing(true);
    await invalidateStationCache(location.latitude, location.longitude, searchRadius);
    await loadStations(location.latitude, location.longitude, searchRadius, true);
    setRefreshing(false);
  }, [location, loadStations, searchRadius]);

  const handleRadiusChange = useCallback(
    async (newRadius: number) => {
      setSearchRadius(newRadius);
      if (location) {
        setLoading(true);
        await loadStations(location.latitude, location.longitude, newRadius);
        setLoading(false);
      }
    },
    [location, loadStations]
  );

  return {
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
  };
}

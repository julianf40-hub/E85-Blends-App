import { useCallback, useEffect, useMemo, useState } from "react";
import { Platform } from "react-native";
import * as Haptics from "expo-haptics";
import type { E85Station } from "@/lib/station-data";
import type { LocalFuelPrices } from "@/lib/fuel-prices";
import { getE85StateAverage } from "@/lib/fuel-prices";
import { getLatestStationPrice, addStationPrice, getAverageStationPrices, getStationPrices, isPriceStale, type StationPrice } from "@/lib/station-prices";
import { loadFavorites, addFavorite, removeFavorite } from "@/lib/station-favorites";
import { getStationVotes, castVote, type StationVote } from "@/lib/station-votes";

export function useStationsInteractions(stations: E85Station[], localPrices: LocalFuelPrices | null) {
  const [selectedStation, setSelectedStation] = useState<E85Station | null>(null);
  const [sortMode, setSortMode] = useState<"distance" | "price">("distance");
  const [priceModalVisible, setPriceModalVisible] = useState(false);
  const [priceModalStation, setPriceModalStation] = useState<E85Station | null>(null);
  const [userPrices, setUserPrices] = useState<Record<string, any>>({});
  const [communityPrices, setCommunityPrices] = useState<Record<string, { e85Price?: number; reportCount: number; freshestTimestamp?: number }>>({});
  const [submittingPrice, setSubmittingPrice] = useState(false);
  const [viewMode, setViewMode] = useState<"list" | "map">("list");
  const [favoriteIds, setFavoriteIds] = useState<Set<string>>(new Set());
  const [stationVotes, setStationVotes] = useState<Record<string, StationVote>>({});
  const [filterConfirmed, setFilterConfirmed] = useState(false);

  useEffect(() => {
    loadFavorites().then((favs) => {
      setFavoriteIds(new Set(favs.map((f) => f.stationId)));
    });
  }, []);

  useEffect(() => {
    if (stations.length > 0) {
      getStationVotes(stations.map((s) => s.id)).then(setStationVotes);
    }
  }, [stations]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      if (stations.length === 0) {
        setUserPrices({});
        setCommunityPrices({});
        return;
      }
      const entries = await Promise.all(
        stations.map(async (station) => {
          const [latest, allPrices] = await Promise.all([
            getLatestStationPrice(station.id),
            getStationPrices(station.id),
          ]);
          return [station.id, latest, allPrices] as const;
        })
      );
      if (cancelled) return;
      const nextUser: Record<string, StationPrice> = {};
      const nextCommunity: Record<string, { e85Price?: number; reportCount: number; freshestTimestamp?: number }> = {};
      for (const [stationId, latest, allPrices] of entries) {
        if (latest) nextUser[stationId] = latest;
        // Build community summary: aggregate all e85 reports (excluding own latest if only 1)
        const e85Reports = allPrices.filter((p) => p.e85Price != null);
        if (e85Reports.length > 0) {
          const avg = e85Reports.reduce((sum, p) => sum + (p.e85Price ?? 0), 0) / e85Reports.length;
          const freshest = e85Reports.reduce((max, p) => Math.max(max, p.timestamp), 0);
          nextCommunity[stationId] = {
            e85Price: Math.round(avg * 100) / 100,
            reportCount: e85Reports.length,
            freshestTimestamp: freshest,
          };
        }
      }
      setUserPrices(nextUser);
      setCommunityPrices(nextCommunity);
    })();
    return () => {
      cancelled = true;
    };
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

  const sortedStations = useMemo(() => {
    const sorted = [...stations];
    if (sortMode === "price") {
      sorted.sort((a, b) => {
        const aPrice = (userPrices[a.id]?.e85Price as number | undefined)
          ?? localPrices?.e85Price
          ?? getE85StateAverage(a.state);
        const bPrice = (userPrices[b.id]?.e85Price as number | undefined)
          ?? localPrices?.e85Price
          ?? getE85StateAverage(b.state);
        const aFav = favoriteIds.has(a.id) ? 0 : 1;
        const bFav = favoriteIds.has(b.id) ? 0 : 1;
        if (aFav !== bFav) return aFav - bFav;
        return aPrice - bPrice;
      });
    } else {
      sorted.sort((a, b) => {
        const aFav = favoriteIds.has(a.id) ? 0 : 1;
        const bFav = favoriteIds.has(b.id) ? 0 : 1;
        if (aFav !== bFav) return aFav - bFav;
        return a.distance - b.distance;
      });
    }
    if (filterConfirmed) {
      return sorted.filter((s) => {
        const vote = stationVotes[s.id];
        if (!vote) return false;
        const total = vote.yesCount + vote.noCount;
        if (total === 0) return false;
        return vote.yesCount / total >= 0.5;
      });
    }
    return sorted;
  }, [stations, sortMode, userPrices, localPrices, favoriteIds, filterConfirmed, stationVotes]);

  return {
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
  };
}

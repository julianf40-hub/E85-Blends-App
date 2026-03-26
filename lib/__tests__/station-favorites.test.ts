import { describe, it, expect, beforeEach, vi } from "vitest";
import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  loadFavorites,
  addFavorite,
  removeFavorite,
  isFavorited,
  getMostVisitedStations,
  addVisit,
  StationFavorite,
} from "../station-favorites";

vi.mock("@react-native-async-storage/async-storage");

describe("Station Favorites & History", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should load empty favorites when storage is empty", async () => {
    (AsyncStorage.getItem as any).mockResolvedValue(null);
    const favorites = await loadFavorites();
    expect(favorites).toEqual([]);
  });

  it("should add a favorite station", async () => {
    (AsyncStorage.getItem as any).mockResolvedValue(null);
    (AsyncStorage.setItem as any).mockResolvedValue(undefined);

    const station: StationFavorite = {
      stationId: "station-1",
      stationName: "Shell Downtown",
      city: "Phoenix",
      state: "AZ",
      latitude: 33.4484,
      longitude: -112.074,
      addedDate: new Date().toISOString(),
    };

    await addFavorite(station);
    expect(AsyncStorage.setItem).toHaveBeenCalled();
  });

  it("should check if a station is favorited", async () => {
    const mockFavorites = [
      {
        stationId: "station-1",
        stationName: "Shell Downtown",
        city: "Phoenix",
        state: "AZ",
        latitude: 33.4484,
        longitude: -112.074,
        addedDate: new Date().toISOString(),
      },
    ];
    (AsyncStorage.getItem as any).mockResolvedValue(JSON.stringify(mockFavorites));

    const isFav = await isFavorited("station-1");
    expect(isFav).toBe(true);

    const isNotFav = await isFavorited("station-2");
    expect(isNotFav).toBe(false);
  });

  it("should remove a favorite station", async () => {
    const mockFavorites = [
      {
        stationId: "station-1",
        stationName: "Shell Downtown",
        city: "Phoenix",
        state: "AZ",
        latitude: 33.4484,
        longitude: -112.074,
        addedDate: new Date().toISOString(),
      },
    ];
    (AsyncStorage.getItem as any).mockResolvedValue(JSON.stringify(mockFavorites));
    (AsyncStorage.setItem as any).mockResolvedValue(undefined);

    await removeFavorite("station-1");
    expect(AsyncStorage.setItem).toHaveBeenCalled();
  });

  it("should add a station visit to history", async () => {
    (AsyncStorage.getItem as any).mockResolvedValue(null);
    (AsyncStorage.setItem as any).mockResolvedValue(undefined);

    await addVisit({
      stationId: "station-1",
      stationName: "Shell Downtown",
      visitDate: new Date().toISOString(),
      blendUsed: 30,
      gallonsAdded: 12.5,
      pricePerGallon: 3.49,
    });

    expect(AsyncStorage.setItem).toHaveBeenCalled();
  });

  it("should get most visited stations", async () => {
    const mockHistory = [
      {
        stationId: "station-1",
        stationName: "Shell Downtown",
        visitDate: new Date().toISOString(),
        blendUsed: 30,
        gallonsAdded: 12.5,
        pricePerGallon: 3.49,
      },
      {
        stationId: "station-1",
        stationName: "Shell Downtown",
        visitDate: new Date().toISOString(),
        blendUsed: 40,
        gallonsAdded: 10,
        pricePerGallon: 3.59,
      },
      {
        stationId: "station-2",
        stationName: "Chevron Midtown",
        visitDate: new Date().toISOString(),
        blendUsed: 30,
        gallonsAdded: 15,
        pricePerGallon: 3.45,
      },
    ];
    (AsyncStorage.getItem as any).mockResolvedValue(JSON.stringify(mockHistory));

    const mostVisited = await getMostVisitedStations(5);
    expect(mostVisited.length).toBeGreaterThan(0);
    expect(mostVisited[0].visitCount).toBeGreaterThanOrEqual(
      mostVisited[mostVisited.length - 1].visitCount
    );
  });
});

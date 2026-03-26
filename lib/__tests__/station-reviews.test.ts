import { describe, it, expect, beforeEach, vi } from "vitest";
import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  loadReviews,
  addReview,
  getStationReviews,
  getStationAverageRating,
  deleteReview,
  getTopRatedStations,
} from "../station-reviews";

vi.mock("@react-native-async-storage/async-storage");

describe("Station Reviews & Ratings", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("should load empty reviews when storage is empty", async () => {
    (AsyncStorage.getItem as any).mockResolvedValue(null);
    const reviews = await loadReviews();
    expect(reviews).toEqual([]);
  });

  it("should add a new review", async () => {
    (AsyncStorage.getItem as any).mockResolvedValue(null);
    (AsyncStorage.setItem as any).mockResolvedValue(undefined);

    const review = await addReview({
      stationId: "station-1",
      stationName: "Shell Downtown",
      rating: 4.5,
      fuelQuality: "good",
      pumpReliability: "excellent",
      cleanliness: "good",
      priceAccuracy: "accurate",
      title: "Great fuel quality",
      comment: "Consistent E85 blend, pumps work well",
      reviewDate: new Date().toISOString(),
      helpful: 0,
      unhelpful: 0,
    });

    expect(review.rating).toBe(4.5);
    expect(review.stationId).toBe("station-1");
    expect(review.id).toBeDefined();
    expect(AsyncStorage.setItem).toHaveBeenCalled();
  });

  it("should get reviews for a specific station", async () => {
    const mockReviews = [
      {
        id: "review-1",
        stationId: "station-1",
        stationName: "Shell Downtown",
        rating: 4.5,
        fuelQuality: "good",
        pumpReliability: "excellent",
        cleanliness: "good",
        priceAccuracy: "accurate",
        title: "Great fuel quality",
        comment: "Consistent E85 blend",
        reviewDate: new Date().toISOString(),
        helpful: 5,
        unhelpful: 1,
      },
      {
        id: "review-2",
        stationId: "station-2",
        stationName: "Chevron Midtown",
        rating: 3.5,
        fuelQuality: "fair",
        pumpReliability: "good",
        cleanliness: "fair",
        priceAccuracy: "slightly_high",
        title: "Average experience",
        comment: "Pumps sometimes slow",
        reviewDate: new Date().toISOString(),
        helpful: 2,
        unhelpful: 0,
      },
    ];
    (AsyncStorage.getItem as any).mockResolvedValue(JSON.stringify(mockReviews));

    const stationReviews = await getStationReviews("station-1");
    expect(stationReviews.length).toBe(1);
    expect(stationReviews[0].stationId).toBe("station-1");
    expect(stationReviews[0].rating).toBe(4.5);
  });

  it("should calculate average rating for a station", async () => {
    const mockReviews = [
      {
        id: "review-1",
        stationId: "station-1",
        stationName: "Shell Downtown",
        rating: 5,
        fuelQuality: "excellent",
        pumpReliability: "excellent",
        cleanliness: "excellent",
        priceAccuracy: "accurate",
        title: "Perfect",
        comment: "Best E85 station",
        reviewDate: new Date().toISOString(),
        helpful: 10,
        unhelpful: 0,
      },
      {
        id: "review-2",
        stationId: "station-1",
        stationName: "Shell Downtown",
        rating: 4,
        fuelQuality: "good",
        pumpReliability: "good",
        cleanliness: "good",
        priceAccuracy: "accurate",
        title: "Good",
        comment: "Reliable station",
        reviewDate: new Date().toISOString(),
        helpful: 5,
        unhelpful: 1,
      },
    ];
    (AsyncStorage.getItem as any).mockResolvedValue(JSON.stringify(mockReviews));

    const stats = await getStationAverageRating("station-1");
    expect(stats.averageRating).toBe(4.5);
    expect(stats.reviewCount).toBe(2);
  });

  it("should delete a review", async () => {
    const mockReviews = [
      {
        id: "review-1",
        stationId: "station-1",
        stationName: "Shell Downtown",
        rating: 4.5,
        fuelQuality: "good",
        pumpReliability: "excellent",
        cleanliness: "good",
        priceAccuracy: "accurate",
        title: "Great fuel quality",
        comment: "Consistent E85 blend",
        reviewDate: new Date().toISOString(),
        helpful: 5,
        unhelpful: 1,
      },
    ];
    (AsyncStorage.getItem as any).mockResolvedValue(JSON.stringify(mockReviews));
    (AsyncStorage.setItem as any).mockResolvedValue(undefined);

    const deleted = await deleteReview("review-1");
    expect(deleted).toBe(true);
    expect(AsyncStorage.setItem).toHaveBeenCalled();
  });

  it("should get top-rated stations", async () => {
    const mockReviews = [
      {
        id: "review-1",
        stationId: "station-1",
        stationName: "Shell Downtown",
        rating: 5,
        fuelQuality: "excellent",
        pumpReliability: "excellent",
        cleanliness: "excellent",
        priceAccuracy: "accurate",
        title: "Perfect",
        comment: "Best E85 station",
        reviewDate: new Date().toISOString(),
        helpful: 10,
        unhelpful: 0,
      },
      {
        id: "review-2",
        stationId: "station-2",
        stationName: "Chevron Midtown",
        rating: 3,
        fuelQuality: "fair",
        pumpReliability: "good",
        cleanliness: "fair",
        priceAccuracy: "slightly_high",
        title: "Average",
        comment: "Okay station",
        reviewDate: new Date().toISOString(),
        helpful: 2,
        unhelpful: 1,
      },
    ];
    (AsyncStorage.getItem as any).mockResolvedValue(JSON.stringify(mockReviews));

    const topRated = await getTopRatedStations(10);
    expect(topRated.length).toBeGreaterThan(0);
    expect(topRated[0].averageRating).toBeGreaterThanOrEqual(
      topRated[topRated.length - 1].averageRating
    );
  });
});

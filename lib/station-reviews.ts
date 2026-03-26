/**
 * Station Reviews & Ratings Storage
 * Community feedback on E85 stations
 */

import AsyncStorage from "@react-native-async-storage/async-storage";

export interface StationReview {
  id: string;
  stationId: string;
  stationName: string;
  rating: number; // 1-5 stars
  fuelQuality: "excellent" | "good" | "fair" | "poor";
  pumpReliability: "excellent" | "good" | "fair" | "poor";
  cleanliness: "excellent" | "good" | "fair" | "poor";
  priceAccuracy: "accurate" | "slightly_high" | "high" | "very_high";
  title: string;
  comment: string;
  reviewDate: string; // ISO 8601
  helpful: number; // upvotes
  unhelpful: number; // downvotes
}

const REVIEWS_KEY = "e85_station_reviews";

/**
 * Load all reviews
 */
export async function loadReviews(): Promise<StationReview[]> {
  try {
    const stored = await AsyncStorage.getItem(REVIEWS_KEY);
    if (stored) {
      const reviews = JSON.parse(stored) as StationReview[];
      // Sort by date descending (newest first)
      return reviews.sort(
        (a, b) => new Date(b.reviewDate).getTime() - new Date(a.reviewDate).getTime()
      );
    }
    return [];
  } catch (error) {
    console.warn("Failed to load reviews:", error);
    return [];
  }
}

/**
 * Add a new review
 */
export async function addReview(review: Omit<StationReview, "id">): Promise<StationReview> {
  const reviews = await loadReviews();
  const newReview: StationReview = {
    ...review,
    id: Date.now().toString(),
    helpful: 0,
    unhelpful: 0,
  };
  reviews.unshift(newReview);
  await AsyncStorage.setItem(REVIEWS_KEY, JSON.stringify(reviews));
  return newReview;
}

/**
 * Get reviews for a specific station
 */
export async function getStationReviews(stationId: string): Promise<StationReview[]> {
  const reviews = await loadReviews();
  return reviews.filter((r) => r.stationId === stationId);
}

/**
 * Get average rating for a station
 */
export async function getStationAverageRating(stationId: string): Promise<{
  averageRating: number;
  reviewCount: number;
  fuelQualityBreakdown: Record<string, number>;
  pumpReliabilityBreakdown: Record<string, number>;
  cleanlinessBreakdown: Record<string, number>;
  priceAccuracyBreakdown: Record<string, number>;
}> {
  const reviews = await getStationReviews(stationId);
  if (reviews.length === 0) {
    return {
      averageRating: 0,
      reviewCount: 0,
      fuelQualityBreakdown: {},
      pumpReliabilityBreakdown: {},
      cleanlinessBreakdown: {},
      priceAccuracyBreakdown: {},
    };
  }

  const avgRating = reviews.reduce((sum, r) => sum + r.rating, 0) / reviews.length;

  const fuelQualityBreakdown = countBreakdown(reviews.map((r) => r.fuelQuality));
  const pumpReliabilityBreakdown = countBreakdown(reviews.map((r) => r.pumpReliability));
  const cleanlinessBreakdown = countBreakdown(reviews.map((r) => r.cleanliness));
  const priceAccuracyBreakdown = countBreakdown(reviews.map((r) => r.priceAccuracy));

  return {
    averageRating: Math.round(avgRating * 10) / 10,
    reviewCount: reviews.length,
    fuelQualityBreakdown,
    pumpReliabilityBreakdown,
    cleanlinessBreakdown,
    priceAccuracyBreakdown,
  };
}

/**
 * Update a review
 */
export async function updateReview(id: string, updates: Partial<StationReview>): Promise<StationReview | null> {
  const reviews = await loadReviews();
  const index = reviews.findIndex((r) => r.id === id);
  if (index === -1) return null;

  reviews[index] = { ...reviews[index], ...updates };
  await AsyncStorage.setItem(REVIEWS_KEY, JSON.stringify(reviews));
  return reviews[index];
}

/**
 * Delete a review
 */
export async function deleteReview(id: string): Promise<boolean> {
  const reviews = await loadReviews();
  const filtered = reviews.filter((r) => r.id !== id);
  if (filtered.length === reviews.length) return false;
  await AsyncStorage.setItem(REVIEWS_KEY, JSON.stringify(filtered));
  return true;
}

/**
 * Mark a review as helpful
 */
export async function markHelpful(reviewId: string): Promise<void> {
  const review = await getReviewById(reviewId);
  if (review) {
    await updateReview(reviewId, { helpful: review.helpful + 1 });
  }
}

/**
 * Mark a review as unhelpful
 */
export async function markUnhelpful(reviewId: string): Promise<void> {
  const review = await getReviewById(reviewId);
  if (review) {
    await updateReview(reviewId, { unhelpful: review.unhelpful + 1 });
  }
}

/**
 * Get a review by ID
 */
export async function getReviewById(id: string): Promise<StationReview | null> {
  const reviews = await loadReviews();
  return reviews.find((r) => r.id === id) || null;
}

/**
 * Get top-rated stations
 */
export async function getTopRatedStations(limit: number = 10): Promise<Array<{
  stationId: string;
  stationName: string;
  averageRating: number;
  reviewCount: number;
}>> {
  const reviews = await loadReviews();
  const stationMap = new Map<string, { ratings: number[]; name: string }>();

  for (const review of reviews) {
    const existing = stationMap.get(review.stationId);
    if (existing) {
      existing.ratings.push(review.rating);
    } else {
      stationMap.set(review.stationId, {
        ratings: [review.rating],
        name: review.stationName,
      });
    }
  }

  return Array.from(stationMap.entries())
    .map(([stationId, data]) => ({
      stationId,
      stationName: data.name,
      averageRating: Math.round((data.ratings.reduce((a, b) => a + b) / data.ratings.length) * 10) / 10,
      reviewCount: data.ratings.length,
    }))
    .sort((a, b) => b.averageRating - a.averageRating)
    .slice(0, limit);
}

/**
 * Clear all reviews
 */
export async function clearReviews(): Promise<void> {
  await AsyncStorage.removeItem(REVIEWS_KEY);
}

// Helper function to count occurrences
function countBreakdown(items: string[]): Record<string, number> {
  const breakdown: Record<string, number> = {};
  for (const item of items) {
    breakdown[item] = (breakdown[item] || 0) + 1;
  }
  return breakdown;
}

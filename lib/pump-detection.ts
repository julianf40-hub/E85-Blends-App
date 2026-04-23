/**
 * Smart Pump Detection
 * Detects when the user is likely at a gas station and suggests opening At-Pump Mode
 */

import { calculateDistance } from "./station-data";

export interface PumpDetectionResult {
  isNearStation: boolean;
  stationName?: string;
  distance?: number;
  confidence: "high" | "medium" | "low";
}

/**
 * Detect if user is near a known station
 * Uses location and nearby stations to determine if user is likely at a pump
 */
export function detectNearbyStation(
  userLat: number,
  userLon: number,
  nearbyStations: Array<{ name: string; latitude: number; longitude: number; distance?: number }>
): PumpDetectionResult {
  if (!nearbyStations || nearbyStations.length === 0) {
    return {
      isNearStation: false,
      confidence: "low",
    };
  }

  // Find the closest station
  let closestStation = nearbyStations[0];
  let minDistance = closestStation.distance ?? calculateDistance(
    userLat,
    userLon,
    closestStation.latitude,
    closestStation.longitude
  );

  for (const station of nearbyStations.slice(1)) {
    const dist = station.distance ?? calculateDistance(
      userLat,
      userLon,
      station.latitude,
      station.longitude
    );
    if (dist < minDistance) {
      minDistance = dist;
      closestStation = station;
    }
  }

  // Determine confidence based on distance
  // High confidence: within 0.1 miles (~500 feet)
  // Medium confidence: within 0.25 miles (~1300 feet)
  // Low confidence: further away
  let confidence: "high" | "medium" | "low" = "low";
  let isNearStation = false;

  if (minDistance <= 0.1) {
    confidence = "high";
    isNearStation = true;
  } else if (minDistance <= 0.25) {
    confidence = "medium";
    isNearStation = true;
  }

  return {
    isNearStation,
    stationName: closestStation.name,
    distance: minDistance,
    confidence,
  };
}

/**
 * Check if enough time has passed since last suggestion
 * Prevents nagging the user with repeated suggestions
 */
export function shouldShowSuggestion(
  lastSuggestionTime: number | null,
  minIntervalMs: number = 5 * 60 * 1000 // 5 minutes default
): boolean {
  if (!lastSuggestionTime) {
    return true;
  }

  const now = Date.now();
  return now - lastSuggestionTime >= minIntervalMs;
}

/**
 * Format distance for display
 */
export function formatDistance(miles: number): string {
  if (miles < 0.1) {
    const feet = Math.round(miles * 5280);
    return `${feet} ft`;
  }
  return `${miles.toFixed(2)} mi`;
}

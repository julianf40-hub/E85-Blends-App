/**
 * E85 Station Data - AFDC API Integration (via Server Proxy)
 *
 * Calls the backend server proxy at /api/trpc/stations.search
 * The server proxy handles the NREL API key securely (server-only env variable).
 * This prevents the API key from being exposed in the client bundle.
 * API Docs: https://developer.nlr.gov/docs/transportation/alt-fuel-stations-v1/nearest/
 */

import { trpc, createTRPCClient } from "@/lib/trpc";

export interface E85Station {
  id: string;
  name: string;
  address: string;
  city: string;
  state: string;
  zip: string;
  latitude: number;
  longitude: number;
  phone?: string;
  hours?: string;
  distance: number;
  distanceKm?: number;
  brand?: string;
  hasBlenderPump: boolean;
  otherBlends?: string;
  lastConfirmed?: string;
  facilityType?: string;
}

/**
 * Fetch nearby E85 stations via the backend server proxy.
 * The server proxy uses a server-only NREL_API_KEY env variable.
 *
 * NOTE: This function is called from React components (stations.tsx).
 * It uses the tRPC client created in the root layout.
 */
export async function fetchNearbyStations(
  latitude: number,
  longitude: number,
  radiusMiles: number = 25,
  limit: number = 20
): Promise<E85Station[]> {
  try {
    // Create the tRPC client with proper configuration (links, headers, auth)
    const client = createTRPCClient();
    
    // Call the server proxy via tRPC
    // The server handles the API key securely and returns the NREL API response
    const response = await client.stations.search.query({
      latitude,
      longitude,
      radius: radiusMiles,
      fuelType: "E85",
    });

    if (!response.fuel_stations || !Array.isArray(response.fuel_stations)) {
      return [];
    }

    return response.fuel_stations.slice(0, limit).map((station: any) => ({
      id: station.id?.toString() || "",
      name: station.station_name || "Unknown Station",
      address: station.street_address || "",
      city: station.city || "",
      state: station.state || "",
      zip: station.zip || "",
      latitude: station.latitude,
      longitude: station.longitude,
      phone: station.station_phone || undefined,
      hours: station.access_days_time || undefined,
      distance: station.distance || 0,
      distanceKm: station.distance_km || undefined,
      brand: extractBrand(station.station_name),
      hasBlenderPump: station.e85_blender_pump || false,
      otherBlends: station.e85_other_ethanol_blends || undefined,
      lastConfirmed: station.date_last_confirmed || undefined,
      facilityType: formatFacilityType(station.facility_type),
    }));
  } catch (error) {
    // Surface meaningful error instead of silently returning empty array
    const errorMsg = error instanceof Error ? error.message : String(error);
    
    // Distinguish between different failure modes
    if (errorMsg.includes("Failed to fetch") || errorMsg.includes("Network")) {
      console.error("[Stations] Network error - API server unreachable:", error);
      throw new Error("NETWORK_ERROR");
    } else if (errorMsg.includes("API rate limit")) {
      console.error("[Stations] API rate limited:", error);
      throw new Error("RATE_LIMITED");
    } else if (errorMsg.includes("NREL API")) {
      console.error("[Stations] NREL API error:", error);
      throw new Error("NREL_API_ERROR");
    } else {
      console.error("[Stations] Failed to fetch stations:", error);
      throw error;
    }
  }
}

/**
 * Extract a brand name from the station name
 */
function extractBrand(name: string): string | undefined {
  if (!name) return undefined;
  const knownBrands = [
    "Shell", "Chevron", "BP", "ExxonMobil", "Mobil", "Exxon",
    "Speedway", "Casey's", "Kwik Trip", "Kum & Go", "QuikTrip",
    "Meijer", "Sheetz", "Wawa", "GetGo", "Murphy USA", "Murphy",
    "Thorntons", "Holiday", "Cenex", "Buc-ee's", "Circle K",
    "7-Eleven", "Pilot", "Love's", "Flying J", "Costco",
    "Sam's Club", "Walmart", "Kroger", "HyVee", "Hy-Vee",
    "Protec", "RaceTrac", "Raceway", "Sunoco", "Valero",
    "Phillips 66", "Conoco", "Marathon", "Sinclair", "ARCO",
  ];
  for (const brand of knownBrands) {
    if (name.toLowerCase().includes(brand.toLowerCase())) {
      return brand;
    }
  }
  return undefined;
}

/**
 * Format facility type for display
 */
function formatFacilityType(type: string | null): string | undefined {
  if (!type) return undefined;
  const mapping: Record<string, string> = {
    CONVENIENCE_STORE: "Convenience Store",
    GAS_STATION: "Gas Station",
    FUEL_RESELLER: "Fuel Reseller",
    TRUCK_STOP: "Truck Stop",
    CARDLOCK: "Cardlock",
    GOVERNMENT: "Government",
    FLEET_GARAGE: "Fleet Garage",
    OFFICE_BLDG: "Office Building",
  };
  return mapping[type] || type.replace(/_/g, " ").toLowerCase().replace(/\b\w/g, (c) => c.toUpperCase());
}

/**
 * Calculate distance between two coordinates using Haversine formula
 */
export function calculateDistance(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number
): number {
  const R = 3959;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

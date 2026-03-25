/**
 * E85 Station Data - AFDC API Integration
 *
 * Uses the NREL Alternative Fuel Station Locator API to fetch
 * real E85 stations near the user's location.
 * API Docs: https://developer.nrel.gov/docs/transportation/alt-fuel-stations-v1/nearest/
 */

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
  distance: number; // miles from search location
  distanceKm?: number;
  brand?: string;
  hasBlenderPump: boolean;
  otherBlends?: string;
  lastConfirmed?: string;
  facilityType?: string;
}

const AFDC_API_BASE = "https://developer.nrel.gov/api/alt-fuel-stations/v1/nearest.json";
const AFDC_API_KEY = "DEMO_KEY"; // Free public key; rate-limited but sufficient for mobile app usage

/**
 * Fetch nearby E85 stations from the AFDC API
 */
export async function fetchNearbyStations(
  latitude: number,
  longitude: number,
  radiusMiles: number = 25,
  limit: number = 20
): Promise<E85Station[]> {
  try {
    const params = new URLSearchParams({
      api_key: AFDC_API_KEY,
      latitude: latitude.toString(),
      longitude: longitude.toString(),
      fuel_type: "E85",
      status: "E", // Available stations only
      access: "public",
      radius: radiusMiles.toString(),
      limit: limit.toString(),
    });

    const response = await fetch(`${AFDC_API_BASE}?${params.toString()}`);

    if (!response.ok) {
      throw new Error(`API error: ${response.status}`);
    }

    const data = await response.json();

    if (!data.fuel_stations || !Array.isArray(data.fuel_stations)) {
      return [];
    }

    return data.fuel_stations.map((station: any) => ({
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
    console.warn("Failed to fetch stations from AFDC API:", error);
    return [];
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
  const R = 3959; // Earth's radius in miles
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

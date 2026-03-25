/**
 * E85 Station Data
 *
 * Sample E85 station data for demonstration. In a production app,
 * this would be fetched from the AFDC (Alternative Fuels Data Center) API
 * or a similar service.
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
  pricePerGallon?: number;
  lastUpdated?: string;
  brand?: string;
}

// Sample E85 stations across major US cities
export const SAMPLE_STATIONS: E85Station[] = [
  {
    id: "1",
    name: "Meijer Gas Station",
    address: "3825 Carpenter Rd",
    city: "Ypsilanti",
    state: "MI",
    zip: "48197",
    latitude: 42.2411,
    longitude: -83.6989,
    phone: "(734) 677-2000",
    hours: "24 Hours",
    pricePerGallon: 2.49,
    brand: "Meijer",
  },
  {
    id: "2",
    name: "Sheetz",
    address: "1201 N Atherton St",
    city: "State College",
    state: "PA",
    zip: "16803",
    latitude: 40.8048,
    longitude: -77.8617,
    phone: "(814) 238-2015",
    hours: "24 Hours",
    pricePerGallon: 2.69,
    brand: "Sheetz",
  },
  {
    id: "3",
    name: "Kum & Go",
    address: "2501 SE 14th St",
    city: "Des Moines",
    state: "IA",
    zip: "50320",
    latitude: 41.5725,
    longitude: -93.6036,
    phone: "(515) 285-6555",
    hours: "24 Hours",
    pricePerGallon: 2.29,
    brand: "Kum & Go",
  },
  {
    id: "4",
    name: "Casey's General Store",
    address: "1100 E Lincoln Way",
    city: "Ames",
    state: "IA",
    zip: "50010",
    latitude: 42.0236,
    longitude: -93.6044,
    phone: "(515) 232-1784",
    hours: "5:00 AM - 11:00 PM",
    pricePerGallon: 2.35,
    brand: "Casey's",
  },
  {
    id: "5",
    name: "Thorntons",
    address: "4600 Poplar Level Rd",
    city: "Louisville",
    state: "KY",
    zip: "40213",
    latitude: 38.1781,
    longitude: -85.7149,
    phone: "(502) 459-0880",
    hours: "24 Hours",
    pricePerGallon: 2.55,
    brand: "Thorntons",
  },
  {
    id: "6",
    name: "Protec Fuel",
    address: "3900 W Broward Blvd",
    city: "Fort Lauderdale",
    state: "FL",
    zip: "33312",
    latitude: 26.1224,
    longitude: -80.1873,
    phone: "(954) 587-7722",
    hours: "6:00 AM - 10:00 PM",
    pricePerGallon: 2.79,
    brand: "Protec",
  },
  {
    id: "7",
    name: "QuikTrip",
    address: "2140 E 21st St",
    city: "Tulsa",
    state: "OK",
    zip: "74114",
    latitude: 36.1395,
    longitude: -95.9468,
    phone: "(918) 742-3681",
    hours: "24 Hours",
    pricePerGallon: 2.19,
    brand: "QuikTrip",
  },
  {
    id: "8",
    name: "Murphy USA",
    address: "6225 S 27th St",
    city: "Lincoln",
    state: "NE",
    zip: "68512",
    latitude: 40.7608,
    longitude: -96.6937,
    phone: "(402) 423-3400",
    hours: "24 Hours",
    pricePerGallon: 2.25,
    brand: "Murphy USA",
  },
  {
    id: "9",
    name: "Kwik Trip",
    address: "1500 S Park St",
    city: "Madison",
    state: "WI",
    zip: "53715",
    latitude: 43.0544,
    longitude: -89.3998,
    phone: "(608) 251-7744",
    hours: "24 Hours",
    pricePerGallon: 2.39,
    brand: "Kwik Trip",
  },
  {
    id: "10",
    name: "GetGo",
    address: "1025 Washington Rd",
    city: "Pittsburgh",
    state: "PA",
    zip: "15228",
    latitude: 40.3729,
    longitude: -80.0399,
    phone: "(412) 344-5000",
    hours: "24 Hours",
    pricePerGallon: 2.59,
    brand: "GetGo",
  },
  {
    id: "11",
    name: "Speedway",
    address: "5455 W 86th St",
    city: "Indianapolis",
    state: "IN",
    zip: "46268",
    latitude: 39.9084,
    longitude: -86.2336,
    phone: "(317) 872-7700",
    hours: "24 Hours",
    pricePerGallon: 2.45,
    brand: "Speedway",
  },
  {
    id: "12",
    name: "Holiday Station",
    address: "2300 University Ave W",
    city: "Saint Paul",
    state: "MN",
    zip: "55114",
    latitude: 44.9632,
    longitude: -93.1918,
    phone: "(651) 646-7755",
    hours: "24 Hours",
    pricePerGallon: 2.35,
    brand: "Holiday",
  },
  {
    id: "13",
    name: "Cenex",
    address: "1200 S Broadway",
    city: "Fargo",
    state: "ND",
    zip: "58103",
    latitude: 46.8652,
    longitude: -96.7898,
    phone: "(701) 232-4455",
    hours: "6:00 AM - 10:00 PM",
    pricePerGallon: 2.29,
    brand: "Cenex",
  },
  {
    id: "14",
    name: "Buc-ee's",
    address: "4155 I-35 S",
    city: "New Braunfels",
    state: "TX",
    zip: "78132",
    latitude: 29.6544,
    longitude: -98.0908,
    phone: "(979) 238-6390",
    hours: "24 Hours",
    pricePerGallon: 2.39,
    brand: "Buc-ee's",
  },
  {
    id: "15",
    name: "Wawa",
    address: "1601 S Broad St",
    city: "Philadelphia",
    state: "PA",
    zip: "19148",
    latitude: 39.9276,
    longitude: -75.1677,
    phone: "(215) 336-7788",
    hours: "24 Hours",
    pricePerGallon: 2.65,
    brand: "Wawa",
  },
];

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

/**
 * Get stations sorted by distance from a given location
 */
export function getStationsByDistance(
  latitude: number,
  longitude: number,
  stations: E85Station[] = SAMPLE_STATIONS
): (E85Station & { distance: number })[] {
  return stations
    .map((station) => ({
      ...station,
      distance: calculateDistance(
        latitude,
        longitude,
        station.latitude,
        station.longitude
      ),
    }))
    .sort((a, b) => a.distance - b.distance);
}

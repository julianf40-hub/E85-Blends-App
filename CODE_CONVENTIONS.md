# Code Conventions & Style Guide

Follow these patterns to keep the codebase consistent and maintainable.

---

## TypeScript

### Strict Mode
```typescript
// ✅ Good: Explicit types
interface Vehicle {
  id: string;
  name: string;
  tankSize: number;
}

// ❌ Bad: Implicit any
const vehicle = { id: "1", name: "My Car" };
```

### Imports
```typescript
// ✅ Good: Organized imports
import { useState, useEffect } from "react";
import { View, Text } from "react-native";
import { useColors } from "@/hooks/use-colors";
import { calculateDistance } from "@/lib/station-data";

// ❌ Bad: Disorganized
import { calculateDistance } from "@/lib/station-data";
import { useState } from "react";
import { useColors } from "@/hooks/use-colors";
```

---

## React Components

### File Naming
```
// ✅ Good: PascalCase for components
components/
  screen-container.tsx
  ui/
    icon-symbol.tsx

// ❌ Bad: lowercase or inconsistent
components/
  ScreenContainer.tsx
  UI/
    IconSymbol.tsx
```

### Component Structure
```typescript
// ✅ Good: Clear structure
import { Text, View } from "react-native";
import { ScreenContainer } from "@/components/screen-container";

interface Props {
  title: string;
  onPress: () => void;
}

export function MyScreen({ title, onPress }: Props) {
  const [count, setCount] = useState(0);

  useEffect(() => {
    // Side effects here
  }, []);

  return (
    <ScreenContainer className="p-4">
      <Text className="text-2xl font-bold">{title}</Text>
      <Text className="text-base text-muted">{count}</Text>
    </ScreenContainer>
  );
}
```

### Styling
```typescript
// ✅ Good: Use className with Tailwind
<View className="flex-1 items-center justify-center p-4">
  <Text className="text-lg font-semibold text-foreground">Hello</Text>
</View>

// ❌ Bad: Inline styles
<View style={{ flex: 1, alignItems: "center", justifyContent: "center", padding: 16 }}>
  <Text style={{ fontSize: 18, fontWeight: "600", color: "#000" }}>Hello</Text>
</View>

// ❌ Bad: Pressable with className (doesn't work)
<Pressable className="bg-primary p-4">
  <Text>Button</Text>
</Pressable>

// ✅ Good: Pressable with style
<Pressable
  style={({ pressed }) => [
    { backgroundColor: "#007AFF", padding: 16 },
    pressed && { opacity: 0.7 }
  ]}
>
  <Text>Button</Text>
</Pressable>
```

---

## State Management

### Local State
```typescript
// ✅ Good: useState for local state
const [isLoading, setIsLoading] = useState(false);
const [error, setError] = useState<string | null>(null);

// ✅ Good: useReducer for complex state
const [state, dispatch] = useReducer(reducer, initialState);
```

### Persistent State
```typescript
// ✅ Good: AsyncStorage for persistence
import AsyncStorage from "@react-native-async-storage/async-storage";

async function savePreference(key: string, value: string) {
  await AsyncStorage.setItem(key, value);
}

async function loadPreference(key: string) {
  return await AsyncStorage.getItem(key);
}
```

### Context
```typescript
// ✅ Good: Create context with clear type
interface ThemeContextType {
  isDark: boolean;
  toggleTheme: () => void;
}

const ThemeContext = createContext<ThemeContextType | undefined>(undefined);

export function useTheme() {
  const context = useContext(ThemeContext);
  if (!context) {
    throw new Error("useTheme must be used within ThemeProvider");
  }
  return context;
}
```

---

## API & tRPC

### Calling tRPC Procedures
```typescript
// ✅ Good: Proper error handling
try {
  const stations = await trpc.stations.search.query({
    latitude: 33.4484,
    longitude: -112.074,
    radius: 25,
  });
  setStations(stations);
} catch (error) {
  setError("Failed to load stations");
  console.error(error);
}

// ❌ Bad: No error handling
const stations = await trpc.stations.search.query({ ... });
setStations(stations);
```

### Creating New Endpoints
```typescript
// ✅ Good: In server/routers.ts
export const appRouter = t.router({
  stations: t.router({
    search: t.procedure
      .input(z.object({
        latitude: z.number(),
        longitude: z.number(),
        radius: z.number().default(25),
      }))
      .query(async ({ input }) => {
        // Implementation
        return stations;
      }),
  }),
});
```

---

## Testing

### Test Structure
```typescript
// ✅ Good: Clear test names
import { describe, it, expect } from "vitest";

describe("calculateDistance", () => {
  it("should return 0 for same coordinates", () => {
    const dist = calculateDistance(40.0, -80.0, 40.0, -80.0);
    expect(dist).toBe(0);
  });

  it("should calculate positive distance", () => {
    const dist = calculateDistance(40.0, -80.0, 41.0, -81.0);
    expect(dist).toBeGreaterThan(0);
  });
});
```

### Mocking
```typescript
// ✅ Good: Mock external dependencies
import { vi } from "vitest";

vi.mock("@/lib/trpc", () => ({
  createTRPCClient: vi.fn(),
  trpc: {},
}));
```

---

## Comments & Documentation

### Inline Comments
```typescript
// ✅ Good: Explain WHY, not WHAT
// Retry logic: NREL API can be flaky, so we retry up to 3 times
async function fetchStationsWithRetry(lat: number, lon: number) {
  for (let i = 0; i < 3; i++) {
    try {
      return await fetchStations(lat, lon);
    } catch (error) {
      if (i === 2) throw error;
      await new Promise(resolve => setTimeout(resolve, 1000 * (i + 1)));
    }
  }
}

// ❌ Bad: Obvious comments
// Fetch stations
async function fetchStations(lat: number, lon: number) {
  return await api.get("/stations", { lat, lon });
}
```

### JSDoc for Public Functions
```typescript
// ✅ Good: Document public APIs
/**
 * Calculate distance between two coordinates using Haversine formula.
 * @param lat1 - Latitude of first point
 * @param lon1 - Longitude of first point
 * @param lat2 - Latitude of second point
 * @param lon2 - Longitude of second point
 * @returns Distance in miles
 */
export function calculateDistance(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number
): number {
  // Implementation
}
```

---

## File Organization

### Lib Files (Business Logic)
```typescript
// ✅ Good structure
// lib/my-feature.ts

// 1. Types
interface MyData {
  id: string;
  value: number;
}

// 2. Constants
const DEFAULT_VALUE = 0;

// 3. Helper functions
function validateData(data: unknown): data is MyData {
  // Validation logic
}

// 4. Main functions
export async function fetchMyData(): Promise<MyData> {
  // Implementation
}

// 5. Exports
export type { MyData };
```

### Component Files
```typescript
// ✅ Good structure
// app/(tabs)/my-screen.tsx

// 1. Imports
import { useState } from "react";
import { View, Text } from "react-native";

// 2. Types
interface Props {
  title: string;
}

// 3. Component
export default function MyScreen({ title }: Props) {
  const [state, setState] = useState(null);

  return (
    <View>
      <Text>{title}</Text>
    </View>
  );
}
```

---

## Error Handling

### User-Facing Errors
```typescript
// ✅ Good: Clear, actionable messages
try {
  const stations = await fetchStations(lat, lon);
} catch (error) {
  if (error.message.includes("rate limit")) {
    setError("Too many requests. Try again in a few minutes.");
  } else if (error.message.includes("network")) {
    setError("Check your internet connection and try again.");
  } else {
    setError("Failed to load stations. Please try again.");
  }
}

// ❌ Bad: Vague or technical errors
setError("Error: ECONNREFUSED");
setError("API Error");
```

### Console Logging
```typescript
// ✅ Good: Structured logging
console.info("[Stations] Loaded 5 stations");
console.warn("[API] Rate limit approaching");
console.error("[tRPC] Connection failed:", error);

// ❌ Bad: Unstructured
console.log("stations loaded");
console.log(error);
```

---

## Performance

### Avoid Unnecessary Re-renders
```typescript
// ✅ Good: Memoize expensive computations
const memoizedValue = useMemo(() => {
  return expensiveCalculation(data);
}, [data]);

// ✅ Good: Memoize callbacks
const handlePress = useCallback(() => {
  doSomething(id);
}, [id]);

// ❌ Bad: Recreate on every render
const value = expensiveCalculation(data);
const handlePress = () => doSomething(id);
```

### Lists
```typescript
// ✅ Good: Use FlatList
<FlatList
  data={stations}
  keyExtractor={(item) => item.id}
  renderItem={({ item }) => <StationCard station={item} />}
/>

// ❌ Bad: Use ScrollView with map
<ScrollView>
  {stations.map((station) => (
    <StationCard key={station.id} station={station} />
  ))}
</ScrollView>
```

---

## Naming Conventions

### Variables & Functions
```typescript
// ✅ Good: Descriptive names
const isLoading = true;
const errorMessage = "Failed to load";
const handleStationPress = () => {};
const fetchNearbyStations = async () => {};

// ❌ Bad: Vague names
const loading = true;
const err = "Failed to load";
const onPress = () => {};
const fetch = async () => {};
```

### Constants
```typescript
// ✅ Good: UPPER_SNAKE_CASE
const MAX_STATIONS = 50;
const DEFAULT_RADIUS = 25;
const API_TIMEOUT = 5000;

// ❌ Bad: lowercase
const maxStations = 50;
const defaultRadius = 25;
```

---

## Git Commits

### Commit Messages
```
// ✅ Good: Clear, descriptive
feat: Add swipe-to-delete gesture for reminders

- Implemented Swipeable wrapper from react-native-gesture-handler
- Red delete action appears on swipe right
- Includes haptic feedback

// ✅ Good: Bug fix
fix: Stations API not loading on TestFlight

- Added automatic Manus backend fallback for native builds
- Removed silent error swallowing
- Updated error messages

// ❌ Bad: Vague
fixed stuff
updated code
```

---

## Before Submitting Code

Checklist:
- [ ] `pnpm check` passes (0 TypeScript errors)
- [ ] `pnpm test` passes (all tests green)
- [ ] `pnpm format` has been run
- [ ] Code follows conventions in this file
- [ ] Comments explain WHY, not WHAT
- [ ] Error messages are user-friendly
- [ ] No console.log left in production code
- [ ] Git commit message is clear and descriptive

---

**Follow these conventions and the codebase will stay clean and maintainable! 🚀**

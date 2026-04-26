import AsyncStorage from "@react-native-async-storage/async-storage";
import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";

const KEY = "rebuild_preferences_v1";

export type AppPreferences = {
  hasOnboarded: boolean;
  homeTab: "calculator" | "stations";
  theme: "dark";
  showGarageTab: boolean;
  showRemindersTab: boolean;
  searchRadius: number;
  defaultTankSize: number;
  preferredOctane: 91 | 93;
  defaultBlend: number;
};

const defaults: AppPreferences = {
  hasOnboarded: false,
  homeTab: "calculator",
  theme: "dark",
  showGarageTab: true,
  showRemindersTab: true,
  searchRadius: 25,
  defaultTankSize: 16,
  preferredOctane: 91,
  defaultBlend: 30,
};

type PrefsContextValue = {
  prefs: AppPreferences;
  loading: boolean;
  update: <K extends keyof AppPreferences>(key: K, value: AppPreferences[K]) => Promise<void>;
};

const PrefsContext = createContext<PrefsContextValue | null>(null);

export function PreferencesProvider({ children }: { children: ReactNode }) {
  const [prefs, setPrefs] = useState<AppPreferences>(defaults);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      const raw = await AsyncStorage.getItem(KEY);
      if (raw) {
        setPrefs({ ...defaults, ...JSON.parse(raw) });
      }
      setLoading(false);
    })();
  }, []);

  const update: PrefsContextValue["update"] = async (key, value) => {
    const next = { ...prefs, [key]: value };
    setPrefs(next);
    await AsyncStorage.setItem(KEY, JSON.stringify(next));
  };

  const value = useMemo(() => ({ prefs, loading, update }), [prefs, loading]);
  return <PrefsContext.Provider value={value}>{children}</PrefsContext.Provider>;
}

export function usePrefs() {
  const ctx = useContext(PrefsContext);
  if (!ctx) throw new Error("usePrefs must be used within PreferencesProvider");
  return ctx;
}

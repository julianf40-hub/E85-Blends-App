/**
 * PreferencesContext
 *
 * Provides a single reactive source of truth for user preferences.
 * Any component that calls usePreferencesContext() will re-render
 * immediately when preferences are saved — including the tab bar.
 */

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import {
  loadPreferences,
  savePreferences,
  type UserPreferences,
} from "@/lib/preferences";

interface PreferencesContextValue {
  prefs: UserPreferences | null;
  /** Update a single key and persist immediately */
  updatePref: <K extends keyof UserPreferences>(key: K, value: UserPreferences[K]) => Promise<void>;
  /** Replace all preferences at once */
  setAllPrefs: (prefs: UserPreferences) => void;
}

const PreferencesContext = createContext<PreferencesContextValue | null>(null);

export function PreferencesProvider({ children }: { children: ReactNode }) {
  const [prefs, setPrefs] = useState<UserPreferences | null>(null);

  useEffect(() => {
    loadPreferences().then(setPrefs);
  }, []);

  const updatePref = useCallback(async <K extends keyof UserPreferences>(
    key: K,
    value: UserPreferences[K],
  ) => {
    setPrefs((prev) => {
      if (!prev) return prev;
      const updated = { ...prev, [key]: value };
      savePreferences(updated).catch(() => {});
      return updated;
    });
  }, []);

  const setAllPrefs = useCallback((next: UserPreferences) => {
    setPrefs(next);
  }, []);

  return (
    <PreferencesContext.Provider value={{ prefs, updatePref, setAllPrefs }}>
      {children}
    </PreferencesContext.Provider>
  );
}

export function usePreferencesContext(): PreferencesContextValue {
  const ctx = useContext(PreferencesContext);
  if (!ctx) {
    throw new Error("usePreferencesContext must be used inside <PreferencesProvider>");
  }
  return ctx;
}

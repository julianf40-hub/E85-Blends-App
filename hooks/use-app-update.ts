/**
 * Hook that checks for OTA updates on app launch and notifies the user
 * when a new version is available. Uses expo-updates.
 */
import { useEffect, useState } from "react";
import { Platform } from "react-native";
import * as Updates from "expo-updates";

export type UpdateStatus =
  | "idle"
  | "checking"
  | "available"
  | "downloading"
  | "ready"
  | "error"
  | "upToDate";

export function useAppUpdate() {
  const [status, setStatus] = useState<UpdateStatus>("idle");
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    // OTA updates only work in production builds, not in Expo Go or dev mode
    if (__DEV__ || Platform.OS === "web") return;

    async function checkForUpdate() {
      try {
        setStatus("checking");
        const result = await Updates.checkForUpdateAsync();
        if (result.isAvailable) {
          setStatus("downloading");
          await Updates.fetchUpdateAsync();
          setStatus("ready");
        } else {
          setStatus("upToDate");
        }
      } catch (err) {
        // Don't crash the app if update check fails
        setStatus("error");
        setErrorMessage(err instanceof Error ? err.message : "Update check failed");
      }
    }

    checkForUpdate();
  }, []);

  async function applyUpdate() {
    if (status !== "ready") return;
    try {
      await Updates.reloadAsync();
    } catch {
      // Reload failed — user can restart manually
    }
  }

  return { status, errorMessage, applyUpdate };
}

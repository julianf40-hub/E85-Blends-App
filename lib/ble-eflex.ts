/**
 * BLE eFlexPlus Integration
 *
 * This module handles Bluetooth Low Energy communication with the eFlexPlus device.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * TODO: Replace placeholder UUIDs with real values from your eFlexPlus device.
 *
 * HOW TO FIND YOUR UUIDS:
 *   1. Install "nRF Connect" from the App Store / Play Store (free)
 *   2. Power on your car (eFlexPlus needs power to advertise BLE)
 *   3. Open nRF Connect → tap "SCAN"
 *   4. Find the device named "eFlexFuel" or "eFlex" in the list
 *   5. Tap "CONNECT" → tap "SERVICE" to expand
 *   6. Note the Service UUID and the Characteristic UUIDs listed under it
 *   7. Replace EFLEX_SERVICE_UUID and EFLEX_CHARACTERISTIC_UUID below
 *
 * Alternatively, email support@eflexfuel.com and ask for the BLE GATT profile.
 * ─────────────────────────────────────────────────────────────────────────────
 */

import { BleManager, Device, State } from "react-native-ble-plx";
import { Platform } from "react-native";
// atob is globally available in React Native's Hermes engine

// ── Placeholder UUIDs — REPLACE THESE with real values from nRF Connect ──────
export const EFLEX_DEVICE_NAME_PREFIXES = ["eFlexFuel", "eFlex", "eFlexPlus"];

// TODO: Replace with the actual Service UUID from nRF Connect
export const EFLEX_SERVICE_UUID = "0000FFE0-0000-1000-8000-00805F9B34FB";

// TODO: Replace with the actual Characteristic UUID that streams sensor data
export const EFLEX_CHARACTERISTIC_UUID = "0000FFE1-0000-1000-8000-00805F9B34FB";
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Parsed live data from the eFlexPlus device.
 * Fields will be null if the device hasn't sent that value yet.
 */
export interface EFlexLiveData {
  ethanolPercent: number | null;   // e.g. 68.5
  fuelTempC: number | null;        // Celsius
  fuelTempF: number | null;        // Fahrenheit (derived)
  injectorDutyCycle: number | null; // 0–100 %
  rpm: number | null;
  rawPacket: string | null;        // raw hex for debugging
}

export const EMPTY_LIVE_DATA: EFlexLiveData = {
  ethanolPercent: null,
  fuelTempC: null,
  fuelTempF: null,
  injectorDutyCycle: null,
  rpm: null,
  rawPacket: null,
};

/**
 * Parse a base64-encoded BLE notification packet from the eFlexPlus.
 *
 * NOTE: The byte layout below is a best-guess based on community reports.
 * Once you have confirmed UUIDs and can capture real packets, update this
 * function to match the actual protocol.
 *
 * Typical eFlexFuel packet (UART-style, ASCII CSV or binary):
 *   Some devices send ASCII like "68.5,25.3,45.2,2800\n"
 *   Others send binary structs.
 *
 * This parser tries ASCII CSV first, then falls back to raw hex display.
 */
export function parseEFlexPacket(base64Value: string): Partial<EFlexLiveData> {
  try {
    // Decode base64 → string
    const raw = atob(base64Value);
    const hex = Array.from(raw)
      .map((c) => (c as string).charCodeAt(0).toString(16).padStart(2, "0"))
      .join(" ");

    // Try ASCII CSV format: "ethanol,tempC,dutyCycle,rpm"
    const trimmed = raw.trim();
    const parts = trimmed.split(",");
    if (parts.length >= 1) {
      const ethanolPercent = parseFloat(parts[0]);
      const fuelTempC = parts[1] ? parseFloat(parts[1]) : null;
      const injectorDutyCycle = parts[2] ? parseFloat(parts[2]) : null;
      const rpm = parts[3] ? parseFloat(parts[3]) : null;

      if (!isNaN(ethanolPercent) && ethanolPercent >= 0 && ethanolPercent <= 100) {
        return {
          ethanolPercent,
          fuelTempC: fuelTempC !== null && !isNaN(fuelTempC) ? fuelTempC : null,
          fuelTempF: fuelTempC !== null && !isNaN(fuelTempC) ? Math.round(fuelTempC * 9 / 5 + 32) : null,
          injectorDutyCycle: injectorDutyCycle !== null && !isNaN(injectorDutyCycle) ? injectorDutyCycle : null,
          rpm: rpm !== null && !isNaN(rpm) ? Math.round(rpm) : null,
          rawPacket: hex,
        };
      }
    }

    // Fallback: just show raw hex for debugging
    return { rawPacket: hex };
  } catch {
    return { rawPacket: "parse error" };
  }
}

// Singleton BLE manager — created once, reused across the app
let _manager: BleManager | null = null;

export function getBleManager(): BleManager {
  if (!_manager) {
    _manager = new BleManager();
  }
  return _manager;
}

export function destroyBleManager(): void {
  if (_manager) {
    _manager.destroy();
    _manager = null;
  }
}

/** Check if a scanned device looks like an eFlexPlus */
export function isEFlexDevice(device: Device): boolean {
  const name = device.name ?? device.localName ?? "";
  return EFLEX_DEVICE_NAME_PREFIXES.some((prefix) =>
    name.toLowerCase().includes(prefix.toLowerCase())
  );
}

/** BLE is not available on web */
export const BLE_SUPPORTED = Platform.OS !== "web";

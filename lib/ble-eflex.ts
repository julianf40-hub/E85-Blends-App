/**
 * BLE eFlexPlus Integration
 *
 * This module handles Bluetooth Low Energy communication with the eFlexPlus device.
 *
 * ⚠️  FEATURE GATE: This module is currently gated behind ENABLE_BLE_MONITOR feature flag.
 * The Live Monitor tab will not be visible until real eFlexPlus GATT UUIDs are confirmed.
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
 * Manages BLE connection to eFlexPlus device.
 * Usage:
 *   const manager = new EFlexBleManager();
 *   await manager.scanAndConnect();
 *   manager.onDataReceived((data) => console.log(data));
 *   await manager.disconnect();
 */
export class EFlexBleManager {
  private bleManager: BleManager;
  private device: Device | null = null;
  private dataCallback: ((data: EFlexLiveData) => void) | null = null;

  constructor() {
    this.bleManager = new BleManager();
  }

  /**
   * Scan for eFlexPlus device and connect.
   * Throws if device not found or connection fails.
   */
  async scanAndConnect(timeoutMs: number = 10000): Promise<void> {
    if (Platform.OS === "web") {
      throw new Error("BLE not supported on web");
    }

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.bleManager.stopDeviceScan();
        reject(new Error("eFlexPlus device not found within timeout"));
      }, timeoutMs);

      this.bleManager.startDeviceScan(null, null, (error, device) => {
        if (error) {
          clearTimeout(timeout);
          reject(error);
          return;
        }

        if (!device) return;

        const isEFlex = EFLEX_DEVICE_NAME_PREFIXES.some((prefix) =>
          device.name?.startsWith(prefix)
        );

        if (isEFlex) {
          clearTimeout(timeout);
          this.bleManager.stopDeviceScan();
          this.connectToDevice(device).then(resolve).catch(reject);
        }
      });
    });
  }

  private async connectToDevice(device: Device): Promise<void> {
    this.device = device;
    await device.connect();
    await device.discoverAllServicesAndCharacteristics();
    this.startListening();
  }

  private startListening(): void {
    if (!this.device) return;

    this.device.monitorCharacteristicForService(
      EFLEX_SERVICE_UUID,
      EFLEX_CHARACTERISTIC_UUID,
      (error, characteristic) => {
        if (error) {
          console.error("BLE read error:", error);
          return;
        }

        if (characteristic?.value) {
          const data = this.parseEFlexData(characteristic.value);
          this.dataCallback?.(data);
        }
      }
    );
  }

  /**
   * Parse raw BLE packet from eFlexPlus.
   * Format is device-specific; adjust based on actual GATT profile.
   */
  private parseEFlexData(base64Data: string): EFlexLiveData {
    try {
      // Decode base64 to hex string
      const binaryString = atob(base64Data);
      const hexString = Array.from(binaryString)
        .map((c) => c.charCodeAt(0).toString(16).padStart(2, "0"))
        .join("");

      // Parse based on eFlexPlus protocol (placeholder logic)
      // Adjust offsets and bit shifts based on actual device spec
      const ethanolPercent = parseInt(hexString.substring(0, 2), 16) / 2.55;
      const fuelTempC = parseInt(hexString.substring(2, 4), 16) - 40;
      const injectorDutyCycle = parseInt(hexString.substring(4, 6), 16) / 2.55;
      const rpm = parseInt(hexString.substring(6, 10), 16);

      return {
        ethanolPercent: isNaN(ethanolPercent) ? null : ethanolPercent,
        fuelTempC: isNaN(fuelTempC) ? null : fuelTempC,
        fuelTempF: fuelTempC !== null ? fuelTempC * 1.8 + 32 : null,
        injectorDutyCycle: isNaN(injectorDutyCycle) ? null : injectorDutyCycle,
        rpm: isNaN(rpm) ? null : rpm,
        rawPacket: hexString,
      };
    } catch (error) {
      console.error("Failed to parse eFlexPlus data:", error);
      return EMPTY_LIVE_DATA;
    }
  }

  /**
   * Register callback for live data updates.
   */
  onDataReceived(callback: (data: EFlexLiveData) => void): void {
    this.dataCallback = callback;
  }

  /**
   * Disconnect from device and clean up.
   */
  async disconnect(): Promise<void> {
    if (this.device) {
      await this.device.cancelConnection();
      this.device = null;
    }
  }
}

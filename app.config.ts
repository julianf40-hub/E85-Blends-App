// Load environment variables with proper priority (system > .env)
import "./scripts/load-env.js";
import type { ExpoConfig } from "expo/config";

// Clean production bundle ID — no template/manus namespace
const bundleId = "com.e85blends.app.ios";
// Deep link scheme for the app
const schemeFromBundleId = "e85blends";

const env = {
  // App branding - update these values directly (do not use env vars)
  appName: "85Blends",
  appSlug: "e85-blend-app",
  // S3 URL of the app logo - set this to the URL returned by generate_image when creating custom logo
  // Leave empty to use the default icon from assets/images/icon.png
  logoUrl: "", // User-provided icon stored in assets/images/icon.png
  scheme: schemeFromBundleId,
  iosBundleId: bundleId,
  androidPackage: bundleId,
};

const config: ExpoConfig = {
  name: env.appName,
  slug: env.appSlug,
  version: "1.0.0",
  orientation: "portrait",
  icon: "./assets/images/icon.png",
  scheme: env.scheme,
  userInterfaceStyle: "automatic",
  newArchEnabled: true,
  ios: {
    supportsTablet: true,
    bundleIdentifier: env.iosBundleId,
    "infoPlist": {
        "ITSAppUsesNonExemptEncryption": false
      }
  },
  android: {
    adaptiveIcon: {
      backgroundColor: "#000000",
      foregroundImage: "./assets/images/android-icon-foreground.png",
      backgroundImage: "./assets/images/android-icon-background.png",
      monochromeImage: "./assets/images/android-icon-monochrome.png",
    },
    edgeToEdgeEnabled: true,
    predictiveBackGestureEnabled: false,
    package: env.androidPackage,
    permissions: [
      "POST_NOTIFICATIONS",
      "ACCESS_FINE_LOCATION",
      "ACCESS_COARSE_LOCATION",
    ],
    intentFilters: [
      {
        action: "VIEW",
        autoVerify: true,
        data: [
          {
            scheme: env.scheme,
            host: "*",
          },
        ],
        category: ["BROWSABLE", "DEFAULT"],
      },
    ],
  },
  web: {
    bundler: "metro",
    output: "static",
    favicon: "./assets/images/favicon.png",
  },
  plugins: [
    "expo-router",
    [
      "expo-notifications",
      {
        icon: "./assets/images/icon.png",
        color: "#10B981",
        sounds: [],
        iosDisplayInForeground: true,
      },
    ],
    "expo-updates",
    [
      "expo-quick-actions",
      {
        androidIcons: {
          calculator_icon: {
            foregroundImage: "./assets/images/android-icon-foreground.png",
            backgroundColor: "#00C853",
          },
        },
      },
    ],
    [
      "expo-location",
      {
        locationAlwaysAndWhenInUsePermission: "Allow E85 Blend to use your location to find nearby stations.",
        locationWhenInUsePermission: "Allow E85 Blend to use your location to find nearby stations.",
      },
    ],
    // react-native-maps uses PROVIDER_DEFAULT with OpenStreetMap tiles (no config plugin needed)
    [
      "expo-splash-screen",
      {
        image: "./assets/images/splash-icon.png",
        imageWidth: 240,
        resizeMode: "contain",
        // Match the icon's dark olive/charcoal border color
        backgroundColor: "#3a3a2e",
        dark: {
          backgroundColor: "#3a3a2e",
        },
      },
    ],
    [
      "expo-build-properties",
      {
        android: {
          buildArchs: ["armeabi-v7a", "arm64-v8a"],
          minSdkVersion: 24,
        },
      },
    ],
  ],
  extra: {
    eas: {
      projectId: "b97e3134-95c6-4f69-bb9a-664aa59a7ebc"
    }
  },
  experiments: {
    typedRoutes: true,
    reactCompiler: true,
  },
};

export default config;

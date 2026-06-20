import { ConfigContext, ExpoConfig } from "expo/config";

// ---------------------------------------------------------------------------
// Build-time validation of required Supabase environment variables.
//
// The mobile app selects a Supabase project through these two variables only.
// It never selects Plaid or Dwolla environment — those are controlled
// exclusively by Edge Function secrets (PLAID_ENV, DWOLLA_ENV) in each
// Supabase project.
//
// Local development (npx expo start):
//   Copy .env.example → .env.local and fill in the DEV project values.
//   .env.local is gitignored and must never be committed.
//
// EAS builds:
//   Configure EXPO_PUBLIC_SUPABASE_URL and EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY
//   as EAS environment variables per build environment (development / preview /
//   production) via the EAS dashboard or:
//     eas env:create --scope project --environment development
//     eas env:create --scope project --environment production
//   Do not put actual values in eas.json or in committed files.
// ---------------------------------------------------------------------------

if (!process.env.EXPO_PUBLIC_SUPABASE_URL) {
  throw new Error(
    "[app.config.ts] EXPO_PUBLIC_SUPABASE_URL is not set.\n" +
      "For local development: copy .env.example to .env.local and fill in values.\n" +
      "For EAS builds: configure via EAS dashboard → Environment Variables."
  );
}

if (!process.env.EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY) {
  throw new Error(
    "[app.config.ts] EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY is not set.\n" +
      "For local development: copy .env.example to .env.local and fill in values.\n" +
      "For EAS builds: configure via EAS dashboard → Environment Variables."
  );
}

export default ({ config }: ConfigContext): ExpoConfig => ({
  ...config,
  name: "mobile",
  owner: "Alexandrino7",
  slug: "mobile",
  scheme: "iou",
  version: "1.0.0",
  orientation: "portrait",
  icon: "./assets/icon.png",
  userInterfaceStyle: "light",
  newArchEnabled: true,
  splash: {
    image: "./assets/splash-icon.png",
    resizeMode: "contain",
    backgroundColor: "#ffffff",
  },
  ios: {
    supportsTablet: true,
    bundleIdentifier: "com.alexandrino7.mobile",
    infoPlist: {
      NSCalendarsUsageDescription:
        "IOU needs calendar access to add your payment due dates",
      NSCalendarsFullAccessUsageDescription:
        "IOU needs calendar access to add your payment due dates",
    },
  },
  android: {
    adaptiveIcon: {
      foregroundImage: "./assets/adaptive-icon.png",
      backgroundColor: "#ffffff",
    },
    edgeToEdgeEnabled: true,
    predictiveBackGestureEnabled: false,
    package: "com.alexandrino7.mobile",
  },
  web: {
    favicon: "./assets/favicon.png",
  },
  plugins: [
    [
      "expo-calendar",
      {
        calendarPermission:
          "IOU needs calendar access to add your payment due dates",
      },
    ],
  ],
});

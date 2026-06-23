// App.tsx
import React from "react";
import { Appearance, StatusBar } from "react-native";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { SafeAreaProvider, initialWindowMetrics } from "react-native-safe-area-context";
import Routes from "./src/routes";
import { ColorSchemeProvider, useAppTheme } from "./src/theme";

// Reads effective scheme from context and keeps the root StatusBar in sync.
// Native-stack screenOptions.statusBarStyle overrides this per-screen when set.
function RootStatusBar() {
  const { isDark } = useAppTheme();
  return <StatusBar barStyle={isDark ? 'light-content' : 'dark-content'} />;
}

export default function App() {
  return (
    <SafeAreaProvider initialMetrics={initialWindowMetrics}>
      <GestureHandlerRootView style={{ flex: 1 }}>
        <ColorSchemeProvider>
          <RootStatusBar />
          <Routes />
        </ColorSchemeProvider>
      </GestureHandlerRootView>
    </SafeAreaProvider>
  );
}

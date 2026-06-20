// App.tsx
import React from "react";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import Routes from "./src/routes";

export default function App() {
  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <Routes />
    </GestureHandlerRootView>
  );
}
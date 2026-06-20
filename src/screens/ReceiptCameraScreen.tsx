import React, { useState } from "react";
import {
  ActivityIndicator,
  Alert,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from "react-native";
import * as ImagePicker from "expo-image-picker";
import Constants from "expo-constants";
import { createEmptyDraft, parseReceiptImage } from "../services/receiptParser";
import { useReceiptSplit } from "../context/receiptSplitContext";

const BRAND = "#1B5E20";

// expo-constants v18: isDevice is true on physical hardware, false in simulators
const IS_DEVICE = (Constants as any).isDevice === true;

type Props = { navigation: any };

export default function ReceiptCameraScreen({ navigation }: Props) {
  const [scanning, setScanning] = useState(false);
  const { setDraft } = useReceiptSplit();

  // ─── Common post-pick handler ─────────────────────────────────────────────

  async function processImage(uri: string) {
    setScanning(true);
    try {
      const result = await parseReceiptImage(uri);
      if (result.ok) {
        setDraft(result.draft);
        navigation.navigate("ReceiptReview");
      } else {
        Alert.alert("Parse Error", result.error);
      }
    } catch (e: any) {
      Alert.alert("Error", e.message ?? "Something went wrong.");
    } finally {
      setScanning(false);
    }
  }

  // ─── Take Photo ───────────────────────────────────────────────────────────

  async function handleTakePhoto() {
    try {
      const perm = await ImagePicker.requestCameraPermissionsAsync();
      if (perm.status !== "granted") {
        Alert.alert(
          "Camera Permission Required",
          "Please allow camera access in Settings to take a photo."
        );
        return;
      }
      const result = await ImagePicker.launchCameraAsync({
        mediaTypes: "images",
        quality: 0.85,
        allowsEditing: true,
        aspect: [3, 4],
      });
      if (!result.canceled && result.assets.length > 0) {
        await processImage(result.assets[0].uri);
      }
    } catch {
      // Camera unavailable — most common on simulators
      Alert.alert(
        "Camera Unavailable",
        "Camera is not available in the simulator. Use Photo Library or Sample Receipt instead."
      );
    }
  }

  // ─── Photo Library ────────────────────────────────────────────────────────

  async function handlePickFromLibrary() {
    try {
      const perm = await ImagePicker.requestMediaLibraryPermissionsAsync();
      if (perm.status !== "granted") {
        Alert.alert(
          "Photo Library Permission Required",
          "Please allow photo library access in Settings."
        );
        return;
      }
      const result = await ImagePicker.launchImageLibraryAsync({
        mediaTypes: "images",
        quality: 0.85,
        allowsEditing: true,
        aspect: [3, 4],
      });
      if (!result.canceled && result.assets.length > 0) {
        await processImage(result.assets[0].uri);
      }
    } catch (e: any) {
      Alert.alert("Error", e.message ?? "Could not open photo library.");
    }
  }

  // ─── Sample Receipt (demo/testing) ────────────────────────────────────────

  async function handleSampleReceipt() {
    setScanning(true);
    try {
      const result = await parseReceiptImage("mock");
      if (result.ok) {
        setDraft(result.draft);
        navigation.navigate("ReceiptReview");
      } else {
        Alert.alert("Error", result.error);
      }
    } catch (e: any) {
      Alert.alert("Error", e.message ?? "Something went wrong.");
    } finally {
      setScanning(false);
    }
  }

  function handleManual() {
    setDraft(createEmptyDraft());
    navigation.navigate("ReceiptReview");
  }

  // ─── UI ───────────────────────────────────────────────────────────────────

  const disabled = scanning;

  return (
    <View style={styles.container}>
      {/* Viewfinder */}
      <View style={styles.viewfinder}>
        <View style={styles.cornerTL} />
        <View style={styles.cornerTR} />
        <View style={styles.cornerBL} />
        <View style={styles.cornerBR} />

        <View style={styles.frameCenter}>
          {scanning ? (
            <View style={styles.scanningWrap}>
              <ActivityIndicator size="large" color="#fff" />
              <Text style={styles.scanningText}>Reading receipt…</Text>
            </View>
          ) : (
            <View style={styles.framePlaceholder}>
              {[100, 78, 100, 65, 100].map((w, i) => (
                <View
                  key={i}
                  style={[
                    styles.frameLine,
                    { width: `${w}%` as any },
                    i % 2 === 1 && styles.frameLineFaint,
                  ]}
                />
              ))}
            </View>
          )}
        </View>

        <View style={styles.scanLine} />

        {/* Simulator notice — shown inline inside the dark area */}
        {!IS_DEVICE && (
          <View style={styles.simBanner}>
            <Text style={styles.simBannerText}>
              Camera unavailable in simulator — use library or sample receipt
            </Text>
          </View>
        )}
      </View>

      {/* Bottom action panel */}
      <View style={styles.bottomPanel}>
        <Text style={styles.heading}>Scan Receipt</Text>
        <Text style={styles.subtext}>
          Take a photo, upload from your library, or use a sample to get started.
        </Text>

        {/* Take Photo — primary action, only meaningful on device */}
        <TouchableOpacity
          style={[
            styles.btn,
            styles.btnPrimary,
            (!IS_DEVICE || disabled) && styles.btnMuted,
          ]}
          onPress={handleTakePhoto}
          disabled={disabled}
          activeOpacity={0.85}
        >
          {scanning ? (
            <ActivityIndicator color="#fff" size="small" />
          ) : (
            <Text style={styles.btnPrimaryText}>
              {IS_DEVICE ? "Take Photo" : "Take Photo (device only)"}
            </Text>
          )}
        </TouchableOpacity>

        {/* Choose from Library — works everywhere */}
        <TouchableOpacity
          style={[styles.btn, styles.btnSecondary, disabled && styles.btnDisabled]}
          onPress={handlePickFromLibrary}
          disabled={disabled}
          activeOpacity={0.8}
        >
          <Text style={styles.btnSecondaryText}>Choose from Library</Text>
        </TouchableOpacity>

        {/* Divider */}
        <View style={styles.dividerRow}>
          <View style={styles.dividerLine} />
          <Text style={styles.dividerLabel}>or</Text>
          <View style={styles.dividerLine} />
        </View>

        {/* Sample Receipt — always available */}
        <TouchableOpacity
          style={[styles.btn, styles.btnGhost, disabled && styles.btnDisabled]}
          onPress={handleSampleReceipt}
          disabled={disabled}
          activeOpacity={0.75}
        >
          <Text style={styles.btnGhostText}>Use Sample Receipt</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={styles.manualLink}
          onPress={handleManual}
          disabled={disabled}
          activeOpacity={0.6}
        >
          <Text style={styles.manualLinkText}>Enter items manually →</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const CORNER = 20;
const CT = 3; // corner thickness

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#0D1117" },

  // Viewfinder
  viewfinder: { flex: 1, alignItems: "center", justifyContent: "center" },
  cornerTL: { position: "absolute", top: "25%", left: "12%", width: CORNER, height: CORNER, borderTopWidth: CT, borderLeftWidth: CT, borderColor: "#fff", borderRadius: 2 },
  cornerTR: { position: "absolute", top: "25%", right: "12%", width: CORNER, height: CORNER, borderTopWidth: CT, borderRightWidth: CT, borderColor: "#fff", borderRadius: 2 },
  cornerBL: { position: "absolute", bottom: "10%", left: "12%", width: CORNER, height: CORNER, borderBottomWidth: CT, borderLeftWidth: CT, borderColor: "#fff", borderRadius: 2 },
  cornerBR: { position: "absolute", bottom: "10%", right: "12%", width: CORNER, height: CORNER, borderBottomWidth: CT, borderRightWidth: CT, borderColor: "#fff", borderRadius: 2 },

  frameCenter: {
    width: "76%",
    height: "62%",
    borderWidth: 1.5,
    borderColor: "rgba(255,255,255,0.2)",
    borderStyle: "dashed",
    borderRadius: 8,
    alignItems: "center",
    justifyContent: "center",
    overflow: "hidden",
  },
  framePlaceholder: { width: "70%", gap: 10, alignItems: "flex-start" },
  frameLine: { height: 3, backgroundColor: "rgba(255,255,255,0.18)", borderRadius: 2 },
  frameLineFaint: { backgroundColor: "rgba(255,255,255,0.09)" },

  scanLine: {
    position: "absolute",
    left: "12%",
    right: "12%",
    height: 2,
    backgroundColor: BRAND,
    opacity: 0.75,
    top: "50%",
    shadowColor: BRAND,
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.9,
    shadowRadius: 8,
  },

  scanningWrap: { alignItems: "center", gap: 12 },
  scanningText: { color: "#fff", fontWeight: "700", fontSize: 14 },

  simBanner: {
    position: "absolute",
    bottom: 16,
    left: 24,
    right: 24,
    backgroundColor: "rgba(0,0,0,0.6)",
    borderRadius: 10,
    paddingVertical: 8,
    paddingHorizontal: 12,
  },
  simBannerText: {
    color: "#FCD34D",
    fontWeight: "700",
    fontSize: 12,
    textAlign: "center",
    lineHeight: 17,
  },

  // Bottom panel
  bottomPanel: {
    backgroundColor: "#fff",
    borderTopLeftRadius: 28,
    borderTopRightRadius: 28,
    padding: 24,
    paddingBottom: 36,
    gap: 10,
  },
  heading: { fontSize: 22, fontWeight: "900", color: "#111827", marginBottom: 2 },
  subtext: { fontSize: 13, fontWeight: "600", color: "#6B7280", lineHeight: 19, marginBottom: 6 },

  btn: { borderRadius: 14, paddingVertical: 15, alignItems: "center" },
  btnPrimary: { backgroundColor: BRAND },
  btnMuted: { backgroundColor: "#4E8050" }, // dimmed green for simulator hint
  btnSecondary: { backgroundColor: "#F3F4F6" },
  btnGhost: { borderWidth: 1.5, borderColor: "#E5E7EB" },
  btnDisabled: { opacity: 0.55 },

  btnPrimaryText: { color: "#fff", fontWeight: "800", fontSize: 16 },
  btnSecondaryText: { color: "#111827", fontWeight: "700", fontSize: 15 },
  btnGhostText: { color: "#6B7280", fontWeight: "700", fontSize: 14 },

  dividerRow: { flexDirection: "row", alignItems: "center", gap: 10, marginVertical: 2 },
  dividerLine: { flex: 1, height: 1, backgroundColor: "#E5E7EB" },
  dividerLabel: { fontSize: 12, fontWeight: "700", color: "#9CA3AF" },

  manualLink: { alignItems: "center", paddingVertical: 4 },
  manualLinkText: { fontSize: 13, fontWeight: "700", color: "#9CA3AF" },
});

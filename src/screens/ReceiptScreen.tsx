// src/screens/ReceiptScreen.tsx
import React, { useEffect, useMemo, useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  ActivityIndicator,
  ScrollView,
  TouchableOpacity,
  Alert,
} from "react-native";
import { supabase } from "../supabase";

type Receipt = {
  payment_id: string;
  amount_cents: number;
  paid_at: string;
  receipt_hash: string;
};

const IOU_GREEN = "#77B777";

const currency = (cents: number) => `$${(cents / 100).toFixed(2)}`;

const formatHash = (hash: string) => {
  if (!hash) return "";
  const chunks = hash.match(/.{1,16}/g);
  return chunks ? chunks.join("\n") : hash;
};

export default function ReceiptScreen({ route, navigation }: any) {
  const paymentId: string | undefined = route?.params?.paymentId;

  const [receipt, setReceipt] = useState<Receipt | null>(null);
  const [loading, setLoading] = useState(true);

  const shortHash = useMemo(() => {
    if (!receipt?.receipt_hash) return "";
    return `${receipt.receipt_hash.slice(0, 16)}...${receipt.receipt_hash.slice(-16)}`;
  }, [receipt]);

  useEffect(() => {
    void fetchReceipt();
  }, [paymentId]);

  const fetchReceipt = async () => {
    if (!paymentId) {
      setLoading(false);
      return;
    }

    setLoading(true);

    const { data, error } = await supabase
      .from("payment_receipts")
      .select("*")
      .eq("payment_id", paymentId)
      .single();

    if (error) {
      console.log(error);
      setReceipt(null);
    } else {
      setReceipt(data);
    }

    setLoading(false);
  };

  const copyHash = () => {
    if (!receipt?.receipt_hash) return;
    Alert.alert("Receipt Hash", receipt.receipt_hash);
  };

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" />
        <Text style={styles.loadingText}>Loading receipt...</Text>
      </View>
    );
  }

  if (!paymentId) {
    return (
      <View style={styles.center}>
        <Text style={styles.emptyTitle}>Missing payment id</Text>
        <Text style={styles.emptyText}>
          This receipt screen was opened without a payment reference.
        </Text>
      </View>
    );
  }

  if (!receipt) {
    return (
      <View style={styles.center}>
        <Text style={styles.emptyTitle}>No receipt found</Text>
        <Text style={styles.emptyText}>
          We couldn’t find a receipt for this payment yet.
        </Text>
      </View>
    );
  }

  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={styles.content}
      showsVerticalScrollIndicator={false}
    >
      <View style={styles.heroCard}>
        <Text style={styles.heroEyebrow}>Verified payment</Text>
        <Text style={styles.heroTitle}>Payment Verified</Text>
        <Text style={styles.heroSubtitle}>
          This payment has been recorded and tied to a tamper-evident receipt hash.
        </Text>
      </View>

      <View style={styles.card}>
        <Text style={styles.sectionTitle}>Receipt Summary</Text>

        <View style={styles.row}>
          <Text style={styles.label}>Amount</Text>
          <Text style={styles.valueStrong}>{currency(receipt.amount_cents)}</Text>
        </View>

        <View style={styles.row}>
          <Text style={styles.label}>Paid At</Text>
          <Text style={styles.value}>{new Date(receipt.paid_at).toLocaleString()}</Text>
        </View>

        <View style={styles.row}>
          <Text style={styles.label}>Payment ID</Text>
          <Text style={styles.valueMono}>{receipt.payment_id}</Text>
        </View>
      </View>

      <View style={styles.card}>
        <Text style={styles.sectionTitle}>Receipt Hash</Text>
        <Text style={styles.hashPreview}>{shortHash}</Text>

        <View style={styles.hashBox}>
          <Text style={styles.hashFull}>{formatHash(receipt.receipt_hash)}</Text>
        </View>

        <TouchableOpacity style={styles.secondaryButton} onPress={copyHash}>
          <Text style={styles.secondaryButtonText}>Show Full Hash</Text>
        </TouchableOpacity>
      </View>

      <View style={styles.infoCard}>
        <Text style={styles.infoTitle}>What this means</Text>
        <Text style={styles.infoText}>
          This receipt hash is a deterministic fingerprint of the recorded payment event.
          It helps prove the payment record exists in a tamper-evident form.
        </Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: {
    flex: 1,
    backgroundColor: "#F5F7F9",
  },
  content: {
    padding: 16,
    paddingBottom: 28,
  },
  center: {
    flex: 1,
    backgroundColor: "#F5F7F9",
    justifyContent: "center",
    alignItems: "center",
    padding: 24,
  },
  loadingText: {
    marginTop: 12,
    color: "#666",
    fontSize: 15,
  },
  emptyTitle: {
    fontSize: 22,
    fontWeight: "800",
    color: "#111",
    marginBottom: 8,
  },
  emptyText: {
    fontSize: 15,
    color: "#666",
    textAlign: "center",
    lineHeight: 21,
  },
  heroCard: {
    backgroundColor: "#FFFFFF",
    borderRadius: 16,
    padding: 18,
    borderWidth: 1,
    borderColor: "#EAEAEA",
    marginBottom: 14,
  },
  heroEyebrow: {
    fontSize: 12,
    fontWeight: "800",
    textTransform: "uppercase",
    color: IOU_GREEN,
    letterSpacing: 0.5,
    marginBottom: 8,
  },
  heroTitle: {
    fontSize: 32,
    fontWeight: "800",
    color: "#111",
  },
  heroSubtitle: {
    marginTop: 8,
    fontSize: 15,
    lineHeight: 22,
    color: "#666",
  },
  card: {
    backgroundColor: "#FFFFFF",
    borderRadius: 16,
    padding: 18,
    borderWidth: 1,
    borderColor: "#EAEAEA",
    marginBottom: 14,
  },
  infoCard: {
    backgroundColor: "#F1FFF1",
    borderRadius: 16,
    padding: 18,
    borderWidth: 1,
    borderColor: "#D8EFD8",
  },
  infoTitle: {
    fontSize: 16,
    fontWeight: "800",
    color: "#1F1F1F",
    marginBottom: 8,
  },
  infoText: {
    fontSize: 14,
    lineHeight: 21,
    color: "#4D4D4D",
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: "800",
    color: "#111",
    marginBottom: 14,
  },
  row: {
    marginBottom: 14,
  },
  label: {
    fontSize: 13,
    fontWeight: "700",
    color: "#666",
    marginBottom: 4,
    textTransform: "uppercase",
  },
  value: {
    fontSize: 16,
    color: "#111",
    lineHeight: 22,
  },
  valueStrong: {
    fontSize: 28,
    fontWeight: "800",
    color: IOU_GREEN,
  },
  valueMono: {
    fontSize: 13,
    color: "#222",
  },
  hashPreview: {
    fontSize: 14,
    fontWeight: "700",
    color: "#444",
    marginBottom: 12,
  },
  hashBox: {
    backgroundColor: "#FAFAFA",
    borderRadius: 12,
    padding: 14,
    borderWidth: 1,
    borderColor: "#EAEAEA",
  },
  hashFull: {
    fontSize: 12,
    lineHeight: 19,
    color: "#222",
  },
  secondaryButton: {
    marginTop: 14,
    alignSelf: "flex-start",
    backgroundColor: "#EEF7EE",
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 10,
  },
  secondaryButtonText: {
    color: "#2E7D32",
    fontWeight: "800",
    fontSize: 14,
  },
});
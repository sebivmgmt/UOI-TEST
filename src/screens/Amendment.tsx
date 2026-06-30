// src/screens/Amendment.tsx
import React, { useEffect, useMemo, useState } from "react";
import { View, Text, TextInput, TouchableOpacity, StyleSheet, Alert, ActivityIndicator, ScrollView } from "react-native";
import { supabase } from "../supabase";
import { usePersonalIouPolicy } from "../hooks/usePersonalIouPolicy";
import {
  mapPersonalIouPolicyError,
  policyStatusMessage,
  MSG_POLICY_LOAD_FAILED,
} from "../utils/personalIouPolicyErrors";

const GREEN = "#77B777";

type Frequency = "weekly" | "biweekly" | "monthly";
type Iou = {
  id: string;
  title: string | null;
  lender_id: string;
  borrower_id: string | null;
  apr_bps: number;
  term_months: number;
  frequency: Frequency;
};

export default function Amendment({ route, navigation }: any) {
  const id = route?.params?.id as string | undefined;

  const [me, setMe] = useState<string | null>(null);
  const [iou, setIou] = useState<Iou | null>(null);
  const [loading, setLoading] = useState(true);

  // fields user can propose (all optional)
  const [aprPct, setAprPct] = useState<string>("");             // e.g. "6.5"
  const [aprInlineError, setAprInlineError] = useState<string | null>(null);
  const [termMonths, setTermMonths] = useState<string>("");     // e.g. "18"
  const [nextDueDate, setNextDueDate] = useState<string>("");   // YYYY-MM-DD
  const [note, setNote] = useState<string>("");

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => setMe(data.user?.id ?? null));
  }, []);

  const load = async () => {
    if (!id) return;
    setLoading(true);
    const { data, error } = await supabase.from("ious").select("id,title,lender_id,borrower_id,apr_bps,term_months,frequency").eq("id", id).single();
    if (error) {
      Alert.alert("Load error", error.message);
      setLoading(false);
      return;
    }
    setIou(data as Iou);
    setLoading(false);
  };

  useEffect(() => { load(); }, [id]);

  const role = useMemo<"lender" | "borrower" | "viewer">(() => {
    if (!me || !iou) return "viewer";
    if (iou.lender_id === me) return "lender";
    if (iou.borrower_id === me) return "borrower";
    return "viewer";
  }, [me, iou]);

  const {
    policyStatus,
    supported: policySupported,
    maxAprBps,
    loading: policyLoading,
    error: policyError,
    refresh: refreshPolicy,
  } = usePersonalIouPolicy(iou?.borrower_id ?? null);

  async function submit() {
    if (!id || !me || !iou) return;
    const proposed: any = {};

    if (aprPct.trim()) {
      const rawApr = Number(aprPct.trim());
      if (!Number.isFinite(rawApr) || rawApr < 0) {
        setAprInlineError("Enter a valid APR percentage (e.g., 5.5).");
        return;
      }
      const val = Math.round(rawApr * 100);
      if (!Number.isFinite(val) || !Number.isInteger(val) || val < 0) {
        setAprInlineError("Enter a valid APR percentage (e.g., 5.5).");
        return;
      }

      // Policy gate required for APR changes only — non-APR amendments proceed without this
      if (policyLoading) return Alert.alert("Please wait", "Checking Personal IOU availability…");
      if (!policySupported) {
        return Alert.alert(
          "Not available",
          policyStatus ? policyStatusMessage(policyStatus) : MSG_POLICY_LOAD_FAILED
        );
      }
      if (maxAprBps === null) return Alert.alert("Not available", MSG_POLICY_LOAD_FAILED);
      if (val > maxAprBps) {
        setAprInlineError(`APR exceeds the ${(maxAprBps / 100).toFixed(2)}% limit for this borrower.`);
        return;
      }
      setAprInlineError(null);
      proposed.apr_bps = val;
    }

    if (termMonths.trim()) {
      const tm = parseInt(termMonths, 10);
      if (!tm || tm < 1) return Alert.alert("Invalid term", "Term must be at least 1 month.");
      proposed.term_months = tm;
    }
    if (nextDueDate.trim()) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(nextDueDate.trim()))
        return Alert.alert("Invalid date", "Use YYYY-MM-DD format.");
      proposed.next_due_date = nextDueDate.trim();
    }
    if (Object.keys(proposed).length === 0 && !note.trim()) {
      return Alert.alert("No changes", "Add at least one change or a note.");
    }

    const { error } = await supabase.from("loan_amendments").insert([{
      iou_id: id,
      proposer_id: me,
      proposed,
      note: note.trim() || null,
      status: "proposed",
    }]);
    if (error) return Alert.alert("Submit failed", mapPersonalIouPolicyError(error));

    Alert.alert(
      role === "lender" ? "Amendment sent" : "Request sent",
      "The other party will review and accept or reject."
    );
    navigation.goBack();
  }

  if (!id) return <View style={s.center}><Text>Missing IOU id.</Text></View>;
  if (loading) return <View style={s.center}><ActivityIndicator /></View>;
  if (!iou) return <View style={s.center}><Text>IOU not found.</Text></View>;

  return (
    <ScrollView contentContainerStyle={{ padding: 20 }}>
      <Text style={s.h1}>{role === "lender" ? "Amend IOU" : role === "borrower" ? "Request Amendment" : "View Amendment"}</Text>
      <Text style={s.sub}>{iou.title ?? "IOU"}</Text>

      <View style={{ height: 12 }} />

      <Text style={s.label}>APR % (optional)</Text>
      <TextInput
        style={s.input}
        placeholder={(iou.apr_bps/100).toFixed(2)}
        keyboardType="decimal-pad"
        value={aprPct}
        onChangeText={(v) => { setAprPct(v); setAprInlineError(null); }}
        editable={!policyLoading}
      />
      {aprInlineError ? (
        <Text style={s.policyNoticeError} accessibilityRole="alert">{aprInlineError}</Text>
      ) : null}
      {policyLoading && (
        <Text style={s.policyNotice} accessibilityLiveRegion="polite">Checking Personal IOU availability…</Text>
      )}
      {!policyLoading && policySupported && maxAprBps !== null && (
        <Text style={s.policyNoticeOk}>Max APR: {(maxAprBps / 100).toFixed(2)}% for this borrower</Text>
      )}
      {!policyLoading && !policySupported && policyStatus !== null && (
        <>
          <Text style={s.policyNoticeError} accessibilityRole="alert">{policyStatusMessage(policyStatus)}</Text>
          <Text style={s.policyNotice}>APR amendments are unavailable. Term and date changes can still be proposed.</Text>
        </>
      )}
      {!policyLoading && policyError && policyStatus === null && (
        <View style={s.policyErrorRow}>
          <Text style={s.policyNoticeError} accessibilityRole="alert">{MSG_POLICY_LOAD_FAILED}</Text>
          <TouchableOpacity onPress={() => { void refreshPolicy(); }}>
            <Text style={s.retryText}>Retry</Text>
          </TouchableOpacity>
        </View>
      )}

      <Text style={s.label}>Term months (optional)</Text>
      <TextInput style={s.input} placeholder={String(iou.term_months)} keyboardType="number-pad" value={termMonths} onChangeText={setTermMonths} />

      <Text style={s.label}>Next due date (YYYY-MM-DD, optional)</Text>
      <TextInput style={s.input} placeholder="2025-11-01" keyboardType="numbers-and-punctuation" value={nextDueDate} onChangeText={setNextDueDate} />

      <Text style={s.label}>Note (optional)</Text>
      <TextInput style={[s.input, { height: 100 }]} multiline placeholder="Explain the change…" value={note} onChangeText={setNote} />

      <TouchableOpacity style={s.btn} onPress={submit}>
        <Text style={s.btnTxt}>{role === "lender" ? "Send Amendment" : "Send Request"}</Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

const s = StyleSheet.create({
  center: { flex: 1, alignItems: "center", justifyContent: "center" },
  h1: { fontSize: 22, fontWeight: "800" },
  sub: { color: "#666", marginTop: 4 },
  label: { marginTop: 12, fontWeight: "700", color: "#333" },
  input: {
    borderWidth: 1, borderColor: "#ddd", borderRadius: 10,
    paddingHorizontal: 14, paddingVertical: 12, marginTop: 6, fontSize: 16, backgroundColor: "#fff",
  },
  btn: { marginTop: 18, backgroundColor: GREEN, paddingVertical: 14, borderRadius: 10, alignItems: "center" },
  btnTxt: { color: "#fff", fontWeight: "800" },
  policyNotice: { marginTop: 4, fontSize: 12, color: "#667085", fontWeight: "600" },
  policyNoticeOk: { marginTop: 4, fontSize: 12, color: GREEN, fontWeight: "600" },
  policyNoticeError: { marginTop: 4, fontSize: 12, color: "#D9534F", fontWeight: "600" },
  policyErrorRow: { flexDirection: "row", alignItems: "center", gap: 8, marginTop: 4, flexWrap: "wrap" },
  retryText: { fontSize: 12, fontWeight: "800", color: "#D9534F", textDecorationLine: "underline" },
});
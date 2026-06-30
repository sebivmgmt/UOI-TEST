// src/screens/AmendmentsList.tsx
import React, { useEffect, useState, useCallback } from "react";
import { View, Text, StyleSheet, FlatList, TouchableOpacity, Alert, ActivityIndicator } from "react-native";
import { supabase } from "../supabase";
import { fetchPersonalIouPolicy } from "../services/personalIouPolicyService";
import {
  mapPersonalIouPolicyError,
  policyStatusMessage,
  MSG_BORROWER_UNAVAILABLE,
} from "../utils/personalIouPolicyErrors";

const GREEN = "#77B777";
const RED = "#D9534F";
const BLUE = "#3B82F6";

type Row = {
  id: string;               // amendment id
  iou_id: string;
  title: string | null;
  proposer_id: string;
  status: "proposed" | "accepted" | "rejected" | "canceled";
  proposed: any;            // jsonb
  created_at: string;
  lender_id: string | null;
  borrower_id: string | null;
};

export default function AmendmentsList({ navigation }: any) {
  const [me, setMe] = useState<string | null>(null);
  const [rows, setRows] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => setMe(data.user?.id ?? null));
  }, []);

  const load = useCallback(async () => {
    setLoading(true);
    const meId = (await supabase.auth.getUser()).data.user?.id;
    if (!meId) { setRows([]); setLoading(false); return; }

    // Show proposals for IOUs I’m a party to, that I did NOT propose, still 'proposed'
    const { data, error } = await supabase
      .from("loan_amendments")
      .select("id,iou_id,proposer_id,status,proposed,created_at,ious!inner(title,lender_id,borrower_id)")
      .eq("status", "proposed")
      .neq("proposer_id", meId)
      .or(`ious.lender_id.eq.${meId},ious.borrower_id.eq.${meId}`)
      .order("created_at", { ascending: false });

    if (error) Alert.alert("Load failed", error.message);
    const mapped = (data ?? []).map((r: any) => ({
      id: r.id,
      iou_id: r.iou_id,
      title: r.ious?.title ?? "IOU",
      proposer_id: r.proposer_id,
      status: r.status,
      proposed: r.proposed || {},
      created_at: r.created_at,
      lender_id: r.ious?.lender_id ?? null,
      borrower_id: r.ious?.borrower_id ?? null,
    })) as Row[];

    setRows(mapped);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  // Apply an accepted amendment (simple rules: update IOU fields; optionally push next due date of earliest scheduled payment)
  async function accept(amend: Row) {
    try {
      const meId = (await supabase.auth.getUser()).data.user?.id;
      if (!meId) throw new Error("Not signed in");

      const p = amend.proposed || {};

      // If this amendment changes APR, verify borrower policy before accepting.
      // Hook-level state cannot be used in callbacks — use shared service directly.
      if (p.apr_bps !== undefined) {
        const proposedAprBps = Number(p.apr_bps);

        if (!Number.isFinite(proposedAprBps) || !Number.isInteger(proposedAprBps) || proposedAprBps < 0) {
          Alert.alert("Cannot accept", "The proposed APR is invalid.");
          return;
        }

        // Fetch borrower_id directly from ious — do not rely on join field
        const { data: iouRow, error: iouErr } = await supabase
          .from("ious")
          .select("borrower_id")
          .eq("id", amend.iou_id)
          .single();

        if (iouErr || !iouRow?.borrower_id) {
          Alert.alert("Cannot accept", MSG_BORROWER_UNAVAILABLE);
          return;
        }

        let policy;
        try {
          policy = await fetchPersonalIouPolicy(iouRow.borrower_id);
        } catch {
          Alert.alert("Cannot accept", MSG_BORROWER_UNAVAILABLE);
          return;
        }

        if (!policy.supported || policy.policyStatus !== "supported") {
          Alert.alert("Cannot accept", policyStatusMessage(policy.policyStatus));
          return;
        }

        if (policy.maxAprBps === null) {
          Alert.alert("Cannot accept", MSG_BORROWER_UNAVAILABLE);
          return;
        }

        if (proposedAprBps > policy.maxAprBps) {
          Alert.alert(
            "Cannot accept",
            `The proposed APR exceeds the ${(policy.maxAprBps / 100).toFixed(2)}% limit for this borrower.`
          );
          return;
        }
      }

      const iouUpdates: any = {};
      if (p.apr_bps !== undefined) iouUpdates.apr_bps = Number(p.apr_bps);
      if (p.term_months !== undefined) iouUpdates.term_months = Number(p.term_months);
      if (p.frequency !== undefined) iouUpdates.frequency = String(p.frequency);

      if (Object.keys(iouUpdates).length > 0) {
        const { error: u1 } = await supabase.from("ious").update(iouUpdates).eq("id", amend.iou_id);
        if (u1) throw u1;
      }

      if (p.next_due_date) {
        const { data: nextRow, error: selErr } = await supabase
          .from("payments")
          .select("id,due_date")
          .eq("iou_id", amend.iou_id)
          .eq("status", "scheduled")
          .order("due_date", { ascending: true })
          .limit(1)
          .maybeSingle();
        if (selErr) throw selErr;
        if (nextRow?.id) {
          const { error: updPay } = await supabase
            .from("payments")
            .update({ due_date: String(p.next_due_date) })
            .eq("id", nextRow.id);
          if (updPay) throw updPay;
        }
      }

      const { error: u2 } = await supabase
        .from("loan_amendments")
        .update({ status: "accepted", decided_at: new Date().toISOString(), decided_by: meId })
        .eq("id", amend.id);
      if (u2) throw u2;

      Alert.alert("Accepted", "Amendment applied.");
      load();
    } catch (e: any) {
      Alert.alert("Accept failed", mapPersonalIouPolicyError(e));
    }
  }

  async function reject(amend: Row) {
    try {
      const meId = (await supabase.auth.getUser()).data.user?.id;
      if (!meId) throw new Error("Not signed in");
      const { error } = await supabase
        .from("loan_amendments")
        .update({ status: "rejected", decided_at: new Date().toISOString(), decided_by: meId })
        .eq("id", amend.id);
      if (error) throw error;
      Alert.alert("Rejected", "Amendment rejected.");
      load();
    } catch (e: any) {
      Alert.alert("Reject failed", e.message ?? String(e));
    }
  }

  const Item = ({ item }: { item: Row }) => {
    const p = item.proposed || {};
    const bits: string[] = [];
    if (p.apr_bps !== undefined) bits.push(`APR ${(Number(p.apr_bps) / 100).toFixed(2)}%`);
    if (p.term_months !== undefined) bits.push(`Term ${p.term_months}m`);
    if (p.frequency !== undefined) bits.push(`Freq ${p.frequency}`);
    if (p.next_due_date) bits.push(`Next due ${p.next_due_date}`);

    return (
      <View style={s.card}>
        <TouchableOpacity onPress={() => navigation.navigate("LoanDetail", { id: item.iou_id })}>
          <Text style={s.title}>{item.title ?? "IOU"}</Text>
        </TouchableOpacity>
        <Text style={s.sub}>{bits.length ? bits.join(" · ") : "No field changes (note only)"}</Text>
        <View style={s.row}>
          <TouchableOpacity style={[s.btn, { backgroundColor: GREEN }]} onPress={() => accept(item)}>
            <Text style={s.btnTxt}>Accept</Text>
          </TouchableOpacity>
          <TouchableOpacity style={[s.btn, { backgroundColor: RED }]} onPress={() => reject(item)}>
            <Text style={s.btnTxt}>Reject</Text>
          </TouchableOpacity>
        </View>
      </View>
    );
  };

  if (loading) return <View style={s.center}><ActivityIndicator /></View>;

  return (
    <View style={{ flex: 1 }}>
      <Text style={s.header}>Amendments</Text>
      {rows.length === 0 ? (
        <Text style={{ color: "#777", paddingHorizontal: 20 }}>No pending amendments.</Text>
      ) : (
        <FlatList
          data={rows}
          keyExtractor={(r) => r.id}
          ItemSeparatorComponent={() => <View style={{ height: 12 }} />}
          contentContainerStyle={{ padding: 20, paddingBottom: 40 }}
          renderItem={Item}
        />
      )}
    </View>
  );
}

const s = StyleSheet.create({
  center: { flex: 1, justifyContent: "center", alignItems: "center" },
  header: { fontSize: 24, fontWeight: "800", padding: 20, paddingBottom: 8 },
  card: { backgroundColor: "#f8fafc", borderRadius: 12, padding: 16, borderWidth: StyleSheet.hairlineWidth, borderColor: "#e5e7eb" },
  title: { fontSize: 16, fontWeight: "700" },
  sub: { marginTop: 6, color: "#555" },
  row: { flexDirection: "row", gap: 10, marginTop: 12 },
  btn: { flex: 1, borderRadius: 10, paddingVertical: 10, alignItems: "center" },
  btnTxt: { color: "#fff", fontWeight: "800" },
});
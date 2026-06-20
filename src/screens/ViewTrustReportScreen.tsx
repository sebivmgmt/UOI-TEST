// src/screens/ViewTrustReportScreen.tsx
import React, { useCallback, useEffect, useState } from "react";
import {
  ActivityIndicator,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { supabase } from "../supabase";

const GREEN = "#77B777";
const GREEN_DARK = "#5F9F5F";
const RED = "#D9534F";
const BLUE = "#3B82F6";
const AMBER = "#B7791F";
const BG = "#F5F7F9";

type ViewerReportRow = {
  user_id: string;
  email: string | null;
  public_score: number;
  visible_trust: number;
  trust_tier: string;
  proof_depth: number;
  proof_depth_label: string;
  confidence_score: number;
  confidence_label: string;
  active_score_affecting_agreements: number;
  active_score_affecting_counterparties: number;
  active_score_ceiling_total: number;
  active_risk_flag_count: number;
  private_risk_summary: string;
  sylienn_private_note: string;
  latest_snapshot_at: string | null;
};

function tierColor(tier: string): string {
  switch ((tier ?? "").toLowerCase()) {
    case "lending": return GREEN_DARK;
    case "strong": return GREEN;
    case "rising":
    case "starter": return BLUE;
    case "watch": return AMBER;
    case "critical": return RED;
    default: return "#667085";
  }
}

function scopeLabel(scope: string): string {
  if (scope === "full_report") return "Full Report";
  if (scope === "agreement_only") return "Agreements Only";
  return "Summary";
}

function relativeTime(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  if (diff < 60000) return "just now";
  const m = Math.floor(diff / 60000);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}

export default function ViewTrustReportScreen({ route }: any) {
  const ownerUserId: string | undefined = route.params?.ownerUserId;

  const [loading, setLoading] = useState(true);
  const [report, setReport] = useState<ViewerReportRow | null>(null);
  const [grantedScope, setGrantedScope] = useState<string | null>(null);
  const [noAccess, setNoAccess] = useState(false);

  const load = useCallback(async () => {
    if (!ownerUserId) { setNoAccess(true); setLoading(false); return; }
    setLoading(true);
    try {
      const me = (await supabase.auth.getUser()).data.user;
      if (!me?.id) { setNoAccess(true); return; }

      const now = new Date().toISOString();
      const { data: shareRows } = await supabase
        .from("trust_report_shares")
        .select("id, scope")
        .eq("owner_user_id", ownerUserId)
        .eq("viewer_user_id", me.id)
        .is("revoked_at", null)
        .or(`expires_at.is.null,expires_at.gt.${now}`)
        .order("created_at", { ascending: false })
        .limit(1);

      if (!shareRows || shareRows.length === 0) { setNoAccess(true); return; }

      const shareScope = (shareRows[0] as any).scope as string;
      setGrantedScope(shareScope);

      console.log("[ViewTrustReport] calling get_trust_report_for_viewer", {
        ownerUserId,
        viewerUserId: me.id,
        scope: shareScope,
      });

      const { data: rows, error } = await supabase.rpc("get_trust_report_for_viewer", {
        p_owner_user_id: ownerUserId,
        p_viewer_user_id: me.id,
        p_scope: shareScope,
      });

      console.log("[ViewTrustReport] RPC result", {
        error: error ?? null,
        rowCount: Array.isArray(rows) ? rows.length : 0,
      });

      if (error || !rows || (rows as any[]).length === 0) {
        if (error) console.error("[ViewTrustReport] RPC error:", error);
        setNoAccess(true);
        return;
      }

      setReport((rows as any[])[0] as ViewerReportRow);
    } finally {
      setLoading(false);
    }
  }, [ownerUserId]);

  useEffect(() => { void load(); }, [load]);

  if (loading) {
    return <View style={s.center}><ActivityIndicator /></View>;
  }

  if (noAccess || !report) {
    return (
      <View style={s.center}>
        <Text style={s.noAccessTitle}>Trust Report not available</Text>
        <Text style={s.noAccessBody}>
          This Trust Report is no longer accessible. The share may have expired or been revoked.
        </Text>
      </View>
    );
  }

  const tc = tierColor(report.trust_tier);
  const showPrivateNotes = grantedScope === "full_report";

  return (
    <ScrollView
      style={{ flex: 1, backgroundColor: BG }}
      contentContainerStyle={s.content}
      showsVerticalScrollIndicator={false}
    >
      {grantedScope && (
        <View style={s.scopeBanner}>
          <Text style={s.scopeBannerText}>Access granted: {scopeLabel(grantedScope)}</Text>
        </View>
      )}

      <View style={s.scoreCard}>
        <View style={s.rowBetween}>
          <Text style={s.eyebrow}>Trust Score</Text>
          <View style={[s.tierPill, { backgroundColor: tc + "22" }]}>
            <Text style={[s.tierPillText, { color: tc }]}>{report.trust_tier}</Text>
          </View>
        </View>
        <Text style={[s.scoreValue, { color: tc }]}>{report.public_score}</Text>
        <View style={s.metricsRow}>
          <View style={s.metricBox}>
            <Text style={s.metricLabel}>Visible Trust</Text>
            <Text style={s.metricValueLg}>{report.visible_trust}</Text>
          </View>
          <View style={s.metricBox}>
            <Text style={s.metricLabel}>Proof Depth</Text>
            <Text style={s.metricValueSm}>{report.proof_depth_label}</Text>
          </View>
        </View>
        {report.latest_snapshot_at && (
          <Text style={s.snapshotLabel}>Snapshot {relativeTime(report.latest_snapshot_at)}</Text>
        )}
      </View>

      <View style={s.card}>
        <Text style={s.sectionTitle}>Confidence & Activity</Text>
        <View style={s.metricsRow}>
          <View style={s.metricBox}>
            <Text style={s.metricLabel}>Confidence</Text>
            <Text style={s.metricValueSm}>{report.confidence_label}</Text>
          </View>
          <View style={s.metricBox}>
            <Text style={s.metricLabel}>Active Agreements</Text>
            <Text style={s.metricValueLg}>{report.active_score_affecting_agreements}</Text>
          </View>
        </View>
        <View style={[s.metricsRow, { marginTop: 8 }]}>
          <View style={s.metricBox}>
            <Text style={s.metricLabel}>Counterparties</Text>
            <Text style={s.metricValueLg}>{report.active_score_affecting_counterparties}</Text>
          </View>
          <View style={{ flex: 1 }} />
        </View>
      </View>

      {showPrivateNotes && (
        <View style={s.card}>
          <Text style={s.sectionTitle}>Private Notes</Text>
          <Text style={s.noteText}>{report.sylienn_private_note}</Text>
          {report.active_risk_flag_count > 0 && (
            <>
              <View style={s.divider} />
              <Text style={[s.sectionTitle, { color: AMBER, marginTop: 4 }]}>Risk Summary</Text>
              <Text style={s.noteText}>{report.private_risk_summary}</Text>
            </>
          )}
        </View>
      )}

      <View style={s.disclaimerCard}>
        <Text style={s.disclaimerText}>
          This report was shared by the account holder. Data reflects their live trust profile at time of access.
        </Text>
      </View>
    </ScrollView>
  );
}

const s = StyleSheet.create({
  center: { flex: 1, alignItems: "center", justifyContent: "center", padding: 28 },
  content: { padding: 16, paddingBottom: 28 },

  noAccessTitle: {
    fontSize: 20,
    fontWeight: "800",
    color: "#111",
    marginBottom: 12,
    textAlign: "center",
  },
  noAccessBody: {
    fontSize: 15,
    color: "#667085",
    lineHeight: 22,
    textAlign: "center",
  },

  scopeBanner: {
    backgroundColor: "#EEF4FF",
    borderRadius: 10,
    paddingVertical: 10,
    paddingHorizontal: 14,
    marginBottom: 14,
    alignItems: "center",
  },
  scopeBannerText: { fontSize: 13, fontWeight: "800", color: BLUE },

  scoreCard: {
    backgroundColor: "#fff",
    borderRadius: 16,
    padding: 16,
    marginBottom: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#E5E7EB",
  },
  rowBetween: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
  },
  eyebrow: {
    fontSize: 11,
    fontWeight: "800",
    textTransform: "uppercase",
    letterSpacing: 0.5,
    color: "#667085",
  },
  scoreValue: { fontSize: 56, fontWeight: "900", lineHeight: 62, marginTop: 4 },
  snapshotLabel: { fontSize: 12, color: "#667085", marginTop: 10, fontWeight: "600" },

  metricsRow: { flexDirection: "row", gap: 10, marginTop: 14 },
  metricBox: {
    flex: 1,
    backgroundColor: "#F6F8FA",
    borderRadius: 12,
    padding: 12,
    borderWidth: 1,
    borderColor: "#E8EBEF",
  },
  metricLabel: {
    fontSize: 11,
    fontWeight: "800",
    color: "#667085",
    textTransform: "uppercase",
    marginBottom: 4,
  },
  metricValueLg: { fontSize: 24, fontWeight: "900", color: "#111" },
  metricValueSm: { fontSize: 15, fontWeight: "800", color: "#111" },
  tierPill: { borderRadius: 999, paddingHorizontal: 10, paddingVertical: 6 },
  tierPillText: { fontWeight: "800", fontSize: 12 },

  card: {
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 14,
    marginBottom: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#E5E7EB",
  },
  sectionTitle: { fontSize: 16, fontWeight: "800", color: "#111", marginBottom: 10 },
  noteText: { color: "#444", lineHeight: 22, fontSize: 14 },
  divider: { height: 1, backgroundColor: "#E5E7EB", marginVertical: 14 },

  disclaimerCard: {
    borderRadius: 10,
    padding: 14,
    backgroundColor: "#F9FAFB",
    borderWidth: 1,
    borderColor: "#E5E7EB",
    marginBottom: 14,
  },
  disclaimerText: {
    fontSize: 12,
    color: "#9CA3AF",
    lineHeight: 18,
    textAlign: "center",
  },
});

// src/screens/TrustReportScreen.tsx
import React, { useCallback, useEffect, useState } from "react";
import { useFocusEffect } from "@react-navigation/native";
import {
  ActivityIndicator,
  Alert,
  Modal,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { supabase } from "../supabase";

const GREEN = "#77B777";
const GREEN_DARK = "#5F9F5F";
const RED = "#D9534F";
const BLUE = "#3B82F6";
const AMBER = "#B7791F";
const BG = "#F5F7F9";

type TrustReportRow = {
  user_id: string;
  public_score: number;
  visible_trust: number;
  active_exposure_points: number;
  trust_tier: string;
  proof_depth: number;
  proof_depth_label: string;
  confidence_score: number;
  confidence_label: string;
  freshness_score: number;
  public_trend_30d: string;
  active_score_affecting_agreements: number;
  active_score_affecting_counterparties: number;
  active_score_ceiling_total: number;
  active_risk_flag_count: number;
  private_risk_summary: string;
  sylienn_private_note: string;
  latest_snapshot_at: string | null;
};

type ShareRow = {
  id: string;
  owner_user_id: string;
  viewer_user_id: string;
  scope: string;
  reason: string | null;
  expires_at: string | null;
  revoked_at: string | null;
  created_at: string;
  viewer_name: string;
};

type SharedWithMeRow = {
  share_id: string;
  owner_user_id: string;
  owner_email: string | null;
  owner_full_name: string | null;
  owner_iou_hash: string | null;
  scope: string;
  reason: string | null;
  expires_at: string | null;
  created_at: string;
  metadata: Record<string, unknown> | null;
  owner_name: string;
};

type AccessLogRow = {
  id: string;
  owner_user_id: string;
  viewer_user_id: string;
  viewer_email: string | null;
  viewer_full_name: string | null;
  viewer_iou_hash: string | null;
  access_type: string;
  scope: string | null;
  created_at: string;
  viewer_name: string;
};

type SearchResult = {
  id: string;
  display_name: string | null;
  email: string | null;
  iou_hash: string | null;
  avatar_url: string | null;
};

type ScopeValue = "summary" | "full_report" | "agreement_only";
type ExpiryValue = "24h" | "7d" | "30d" | "never";
type Tab = "report" | "shared" | "sharing";

const SCOPE_OPTIONS: { value: ScopeValue; label: string; desc: string }[] = [
  { value: "summary", label: "Summary", desc: "Score, tier, and trust overview" },
  { value: "full_report", label: "Full Report", desc: "Complete report including coaching notes" },
  { value: "agreement_only", label: "Agreements Only", desc: "Active agreement count and ceiling" },
];

const EXPIRY_OPTIONS: { value: ExpiryValue; label: string }[] = [
  { value: "24h", label: "24 hours" },
  { value: "7d", label: "7 days" },
  { value: "30d", label: "30 days" },
  { value: "never", label: "Until revoked" },
];

const PILLARS = [
  {
    n: "1",
    title: "Payment Reliability",
    body: "Whether payments are completed early, on time, late, missed, reversed, or recovered.",
  },
  {
    n: "2",
    title: "Obligation Strength",
    body: "How serious the obligation was, including amount, term length, repayment speed, and difficulty.",
  },
  {
    n: "3",
    title: "Proof Depth",
    body: "How strongly IOU can verify what happened, from manual confirmation to verified payment rails.",
  },
  {
    n: "4",
    title: "Housing & Recurring Stability",
    body: "Consistency with rent, phone bills, utilities, and other recurring responsibilities.",
  },
  {
    n: "5",
    title: "Relationship Trust",
    body: "Whether trust is broad, healthy, and real, including counterparty diversity and no-score family/private lanes.",
  },
  {
    n: "6",
    title: "Fairness & Conduct",
    body: "How borrowers and lenders behave, including fair terms, extensions, disputes, and confirmation behavior.",
  },
  {
    n: "7",
    title: "Trust Intelligence",
    body: "How IOU learns from outcomes, explains trust, tracks model versions, and keeps reports auditable.",
  },
];

function formatDbLabel(s: string | null | undefined): string {
  if (!s) return "—";
  const map: Record<string, string> = {
    very_thin: "Very Thin",
    thin: "Thin",
    developing_trust: "Developing Trust",
    established: "Established",
    deep: "Deep",
    verified_user: "Verified User",
    standard_score_affecting: "Standard Score-Affecting",
    access_denied: "Access denied",
    share_created: "Share created",
    share_revoked: "Share revoked",
    share_expired_denied: "Access expired",
    view: "Viewed",
    summary: "Summary",
    full_report: "Full Report",
    agreement_only: "Agreements Only",
    stable: "Stable",
    rising: "Rising",
    falling: "Falling",
    starter: "Starter",
    strong: "Strong",
    watch: "Watch",
    critical: "Critical",
    lending: "Lending",
    low: "Low",
    medium: "Medium",
    high: "High",
  };
  return map[s.toLowerCase()] ?? s.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

function expiryMs(v: ExpiryValue): number | null {
  if (v === "24h") return 86400000;
  if (v === "7d") return 604800000;
  if (v === "30d") return 2592000000;
  return null;
}

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

function relativeTime(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  if (diff < 60000) return "just now";
  const m = Math.floor(diff / 60000);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}

function expiryLabel(iso: string | null): string {
  if (!iso) return "Until revoked";
  const diff = new Date(iso).getTime() - Date.now();
  if (diff <= 0) return "Expired";
  const d = Math.floor(diff / 86400000);
  if (d > 0) return `${d}d remaining`;
  return `${Math.floor(diff / 3600000)}h remaining`;
}

function initials(name: string | null, email: string | null): string {
  if (name) {
    const parts = name.trim().split(/\s+/);
    if (parts.length >= 2) return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
    return parts[0][0].toUpperCase();
  }
  if (email) return email[0].toUpperCase();
  return "?";
}

export default function TrustReportScreen({ navigation }: any) {
  const [meId, setMeId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [report, setReport] = useState<TrustReportRow | null>(null);
  const [shares, setShares] = useState<ShareRow[]>([]);
  const [sharedWithMe, setSharedWithMe] = useState<SharedWithMeRow[]>([]);
  const [sharedWithMeError, setSharedWithMeError] = useState(false);
  const [log, setLog] = useState<AccessLogRow[]>([]);
  const [logSessionError, setLogSessionError] = useState(false);
  const [tab, setTab] = useState<Tab>("report");

  // Share modal state
  const [modalOpen, setModalOpen] = useState(false);
  const [searchQ, setSearchQ] = useState("");
  const [searchRes, setSearchRes] = useState<SearchResult[]>([]);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [searching, setSearching] = useState(false);
  const [hasSearched, setHasSearched] = useState(false);
  const [target, setTarget] = useState<SearchResult | null>(null);
  const [scope, setScope] = useState<ScopeValue>("summary");
  const [expiry, setExpiry] = useState<ExpiryValue>("7d");
  const [sharing, setSharing] = useState(false);

  // Pillars info modal
  const [pillarsOpen, setPillarsOpen] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setLogSessionError(false);
    setSharedWithMeError(false);
    try {
      const me = (await supabase.auth.getUser()).data.user;
      if (!me?.id) return;
      setMeId(me.id);

      const now = new Date().toISOString();
      const [reportRes, sharesRes] = await Promise.all([
        supabase.from("trust_report_shadow_v").select("*").eq("user_id", me.id).single(),
        supabase
          .from("trust_report_shares")
          .select("*")
          .eq("owner_user_id", me.id)
          .is("revoked_at", null)
          .or(`expires_at.is.null,expires_at.gt.${now}`),
      ]);

      const rawShares = (sharesRes.data ?? []) as any[];

      const shareViewerIds = rawShares
        .map((r: any) => r.viewer_user_id as string)
        .filter(Boolean) as string[];

      const nameMap: Record<string, string | null> = {};
      if (shareViewerIds.length > 0) {
        const { data: profiles } = await supabase
          .from("profile_directory")
          .select("id, public_name, iou_hash")
          .in("id", shareViewerIds);
        for (const p of profiles ?? []) {
          nameMap[(p as any).id] =
            (p as any).public_name ??
            (p as any).iou_hash ??
            null;
        }
      }

      const resolveShareName = (uid: string) =>
        nameMap[uid] ?? `User ···${uid.slice(-6)}`;

      if (reportRes.data) setReport(reportRes.data as TrustReportRow);
      setShares(rawShares.map((r) => ({ ...r, viewer_name: resolveShareName(r.viewer_user_id) })));

      // Shared with me
      const { data: sharedRows, error: sharedError } = await supabase.rpc(
        "get_trust_reports_shared_with_me"
      );
      if (sharedError) {
        console.error("get_trust_reports_shared_with_me error:", sharedError);
        if (sharedError.message?.toLowerCase().includes("not authenticated")) {
          setSharedWithMeError(true);
        }
      } else {
        setSharedWithMe(
          ((sharedRows ?? []) as any[]).map((r) => ({
            ...r,
            owner_name:
              r.owner_full_name ??
              r.owner_email ??
              r.owner_iou_hash ??
              `User ···${(r.owner_user_id ?? "------").slice(-6)}`,
          }))
        );
      }

      // Access log
      const { data: logRows, error: logError } = await supabase.rpc(
        "get_my_trust_report_access_logs"
      );
      if (logError) {
        console.error("get_my_trust_report_access_logs error:", logError);
        if (logError.message?.toLowerCase().includes("not authenticated")) {
          setLogSessionError(true);
        }
      } else {
        setLog(
          ((logRows ?? []) as any[]).map((r) => ({
            ...r,
            viewer_name:
              r.viewer_full_name ??
              r.viewer_email ??
              r.viewer_iou_hash ??
              `User ···${(r.viewer_user_id ?? "------").slice(-6)}`,
          }))
        );
      }
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  // Reload when screen comes back into focus (e.g. returning from ViewTrustReport)
  // so the Access Log reflects any view events that were just logged.
  useFocusEffect(useCallback(() => { void load(); }, [load]));

  async function doSearch() {
    const q = searchQ.trim();
    if (!q) { setSearchRes([]); setHasSearched(false); return; }
    setSearching(true);
    setSearchError(null);
    setHasSearched(true);
    try {
      const { data, error } = await supabase.functions.invoke("search-counterparty", {
        body: { query: q },
      });
      if (error) {
        console.error("search-counterparty error:", error);
        setSearchError("Search failed. Please try again.");
        setSearchRes([]);
        return;
      }
      const users: any[] = data?.results ?? [];
      setSearchRes(
        users
          .filter((u) => u.id !== meId)
          .map((u) => ({
            id: u.id,
            display_name: u.display_name ?? u.full_name ?? null,
            email: u.email ?? null,
            iou_hash: u.iou_hash ?? null,
            avatar_url: u.avatar_url ?? null,
          }))
      );
    } finally {
      setSearching(false);
    }
  }

  async function createShare() {
    if (!meId || !target) return;
    setSharing(true);
    try {
      const ms = expiryMs(expiry);
      const { error } = await supabase.rpc("create_trust_report_share", {
        p_owner_user_id: meId,
        p_viewer_user_id: target.id,
        p_scope: scope,
        p_expires_at: ms ? new Date(Date.now() + ms).toISOString() : null,
        p_reason: null,
        p_metadata: {},
      });
      if (error) { Alert.alert("Share failed", error.message); return; }
      closeModal();
      void load();
    } finally {
      setSharing(false);
    }
  }

  function revokeShare(shareId: string) {
    Alert.alert(
      "Revoke access",
      "This person will no longer be able to view your Trust Report.",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Revoke",
          style: "destructive",
          onPress: async () => {
            const { error } = await supabase.rpc("revoke_trust_report_share", {
              p_share_id: shareId,
            });
            if (error) Alert.alert("Revoke failed", error.message);
            else void load();
          },
        },
      ]
    );
  }

  function closeModal() {
    setModalOpen(false);
    setSearchQ("");
    setSearchRes([]);
    setSearchError(null);
    setHasSearched(false);
    setTarget(null);
    setScope("summary");
    setExpiry("7d");
  }

  if (loading) {
    return <View style={s.center}><ActivityIndicator /></View>;
  }

  const tc = report ? tierColor(report.trust_tier) : "#667085";

  return (
    <View style={{ flex: 1, backgroundColor: BG }}>
      {/* ── Fixed 3-tab bar ── */}
      <View style={s.tabRow}>
        {(
          [
            { key: "report", label: "My Report" },
            { key: "shared", label: "Shared With Me" },
            { key: "sharing", label: "Sharing" },
          ] as { key: Tab; label: string }[]
        ).map((t) => (
          <TouchableOpacity
            key={t.key}
            style={[s.tabBtn, tab === t.key && s.tabActive]}
            onPress={() => setTab(t.key)}
          >
            <Text style={[s.tabText, tab === t.key && s.tabTextActive]}>{t.label}</Text>
          </TouchableOpacity>
        ))}
      </View>

      {/* Privacy strip */}
      <View style={s.privacyHeader}>
        <Text style={s.privacyHeaderText}>
          Private by default. You control who can view this report.
        </Text>
      </View>

      <ScrollView contentContainerStyle={s.content} showsVerticalScrollIndicator={false}>

        {/* ── My Report ── */}
        {tab === "report" && !report && (
          <View style={s.card}>
            <Text style={s.emptyText}>
              Your Trust Report is being built. Complete a verified IOU to start generating trust data.
            </Text>
          </View>
        )}

        {tab === "report" && report && (
          <>
            <TouchableOpacity
              style={s.pillarsLink}
              onPress={() => setPillarsOpen(true)}
              activeOpacity={0.8}
            >
              <Text style={s.pillarsLinkText}>The 7 Pillars of IOU Trust</Text>
              <Text style={s.pillarsLinkArrow}>→</Text>
            </TouchableOpacity>

            <View style={s.scoreCard}>
              <View style={s.rowBetween}>
                <Text style={s.eyebrow}>Trust Score</Text>
                <View style={[s.tierPill, { backgroundColor: tc + "22" }]}>
                  <Text style={[s.tierPillText, { color: tc }]}>
                    {formatDbLabel(report.trust_tier)}
                  </Text>
                </View>
              </View>
              <Text style={[s.scoreValue, { color: tc }]}>{report.public_score}</Text>
              <View style={s.metricsRow}>
                <View style={s.metricBox}>
                  <Text style={s.metricLabel}>Visible Trust</Text>
                  <Text style={s.metricValueLg}>{report.visible_trust}</Text>
                </View>
                <View style={s.metricBox}>
                  <Text style={s.metricLabel}>Active Exposure</Text>
                  <Text style={[s.metricValueLg, { color: report.active_exposure_points > 0 ? AMBER : "#111" }]}>
                    {report.active_exposure_points > 0 ? `-${report.active_exposure_points}` : "0"}
                  </Text>
                </View>
              </View>
              {report.latest_snapshot_at && (
                <Text style={s.snapshotLabel}>Snapshot {relativeTime(report.latest_snapshot_at)}</Text>
              )}
            </View>

            <View style={s.card}>
              <Text style={s.sectionTitle}>Proof & Confidence</Text>
              <View style={s.metricsRow}>
                <View style={s.metricBox}>
                  <Text style={s.metricLabel}>Proof Depth</Text>
                  <Text style={s.metricValueSm}>{formatDbLabel(report.proof_depth_label)}</Text>
                </View>
                <View style={s.metricBox}>
                  <Text style={s.metricLabel}>Confidence</Text>
                  <Text style={s.metricValueSm}>{formatDbLabel(report.confidence_label)}</Text>
                </View>
              </View>
              <View style={[s.metricsRow, { marginTop: 8 }]}>
                <View style={s.metricBox}>
                  <Text style={s.metricLabel}>Active Agreements</Text>
                  <Text style={s.metricValueLg}>{report.active_score_affecting_agreements}</Text>
                </View>
                <View style={s.metricBox}>
                  <Text style={s.metricLabel}>Counterparties</Text>
                  <Text style={s.metricValueLg}>{report.active_score_affecting_counterparties}</Text>
                </View>
              </View>
            </View>

            <View style={s.card}>
              <Text style={s.sectionTitle}>Private Coaching Note</Text>
              <Text style={s.noteText}>{report.sylienn_private_note}</Text>
            </View>

            {report.active_risk_flag_count > 0 && (
              <View style={[s.card, { borderColor: AMBER, borderWidth: 1 }]}>
                <Text style={[s.sectionTitle, { color: AMBER }]}>Private Risk Summary</Text>
                <Text style={s.noteText}>{report.private_risk_summary}</Text>
              </View>
            )}

            <TouchableOpacity style={s.primaryBtn} onPress={() => setModalOpen(true)}>
              <Text style={s.primaryBtnText}>Share My Trust Report</Text>
            </TouchableOpacity>
          </>
        )}

        {/* ── Shared With Me ── */}
        {tab === "shared" && (
          <>
            {sharedWithMeError ? (
              <View style={s.card}>
                <Text style={s.emptyText}>
                  Session error. Please sign out and back in to view shared reports.
                </Text>
              </View>
            ) : sharedWithMe.length === 0 ? (
              <View style={s.card}>
                <Text style={s.emptyText}>
                  No active Trust Reports are shared with you right now. A previous share may have expired or been revoked.
                </Text>
              </View>
            ) : (
              sharedWithMe.map((item) => (
                <View key={item.share_id} style={s.sharedRow}>
                  <View style={{ flex: 1 }}>
                    <Text style={s.shareName}>{item.owner_name}</Text>
                    <View style={s.shareMetaRow}>
                      <View style={s.scopePill}>
                        <Text style={s.scopePillText}>{formatDbLabel(item.scope)}</Text>
                      </View>
                      <Text style={s.shareExpiry}>{expiryLabel(item.expires_at)}</Text>
                    </View>
                    <Text style={s.shareDate}>Shared {relativeTime(item.created_at)}</Text>
                  </View>
                  <TouchableOpacity
                    style={s.viewReportBtn}
                    onPress={() =>
                      navigation.navigate("ViewTrustReport", {
                        ownerUserId: item.owner_user_id,
                        ownerName: item.owner_name,
                      })
                    }
                  >
                    <Text style={s.viewReportBtnText}>View Report</Text>
                  </TouchableOpacity>
                </View>
              ))
            )}
          </>
        )}

        {/* ── Sharing (Active Shares + Access Log) ── */}
        {tab === "sharing" && (
          <>
            {/* Section: Active Shares */}
            <View style={s.sectionHeaderRow}>
              <Text style={s.sectionHeaderLabel}>Active Shares</Text>
              <TouchableOpacity style={s.shareInlineBtn} onPress={() => setModalOpen(true)}>
                <Text style={s.shareInlineBtnText}>+ Share</Text>
              </TouchableOpacity>
            </View>

            {shares.length === 0 ? (
              <View style={s.card}>
                <Text style={s.emptyText}>
                  No active shares. Your Trust Report is private until you share it.
                </Text>
              </View>
            ) : (
              shares.map((share) => (
                <View key={share.id} style={s.shareRow}>
                  <View style={{ flex: 1 }}>
                    <Text style={s.shareName}>{share.viewer_name}</Text>
                    <View style={s.shareMetaRow}>
                      <View style={s.scopePill}>
                        <Text style={s.scopePillText}>{formatDbLabel(share.scope)}</Text>
                      </View>
                      <Text style={s.shareExpiry}>{expiryLabel(share.expires_at)}</Text>
                    </View>
                    <Text style={s.shareDate}>Shared {relativeTime(share.created_at)}</Text>
                  </View>
                  <TouchableOpacity style={s.revokeBtn} onPress={() => revokeShare(share.id)}>
                    <Text style={s.revokeBtnText}>Revoke</Text>
                  </TouchableOpacity>
                </View>
              ))
            )}

            {/* Section: Access Log */}
            <View style={[s.sectionHeaderRow, { marginTop: 10 }]}>
              <Text style={s.sectionHeaderLabel}>Access Log</Text>
            </View>

            {logSessionError ? (
              <View style={s.card}>
                <Text style={s.emptyText}>
                  Session error. Please sign out and back in to view your access log.
                </Text>
              </View>
            ) : log.length === 0 ? (
              <View style={s.card}>
                <Text style={s.emptyText}>No access activity yet.</Text>
              </View>
            ) : (
              log.map((entry) => (
                <View key={entry.id} style={s.logRow}>
                  <View style={{ flex: 1 }}>
                    <Text style={s.logAction}>{formatDbLabel(entry.access_type)}</Text>
                    <Text style={s.logName}>{entry.viewer_name}</Text>
                    {entry.scope && (
                      <Text style={s.logMeta}>Scope: {formatDbLabel(entry.scope)}</Text>
                    )}
                  </View>
                  <Text style={s.logTime}>{relativeTime(entry.created_at)}</Text>
                </View>
              ))
            )}
          </>
        )}
      </ScrollView>

      {/* ── Share modal ── */}
      <Modal visible={modalOpen} animationType="slide" presentationStyle="pageSheet">
        <View style={s.modal}>
          <View style={s.modalHeader}>
            <Text style={s.modalTitle}>Share Trust Report</Text>
            <TouchableOpacity onPress={closeModal}>
              <Text style={s.modalClose}>Cancel</Text>
            </TouchableOpacity>
          </View>

          <ScrollView
            contentContainerStyle={s.modalContent}
            keyboardShouldPersistTaps="handled"
            showsVerticalScrollIndicator={false}
          >
            <Text style={s.modalLabel}>Find person</Text>

            {!target ? (
              <>
                <View style={s.searchRow}>
                  <TextInput
                    style={s.searchInput}
                    value={searchQ}
                    onChangeText={(t) => {
                      setSearchQ(t);
                      if (!t.trim()) { setSearchRes([]); setHasSearched(false); setSearchError(null); }
                    }}
                    placeholder="Name, email, or IOU hash"
                    autoCapitalize="none"
                    returnKeyType="search"
                    onSubmitEditing={doSearch}
                  />
                  <TouchableOpacity style={s.searchBtn} onPress={doSearch} disabled={searching}>
                    {searching
                      ? <ActivityIndicator color="#fff" size="small" />
                      : <Text style={s.searchBtnText}>Search</Text>
                    }
                  </TouchableOpacity>
                </View>

                {!hasSearched && (
                  <Text style={s.searchHint}>Search by name, email, or IOU hash.</Text>
                )}

                {searchError && (
                  <Text style={s.searchErrorText}>{searchError}</Text>
                )}

                {searchRes.map((u) => {
                  const name = u.display_name;
                  const sub = u.email ?? (u.iou_hash ? `#${u.iou_hash}` : null);
                  const ini = initials(name, u.email);
                  return (
                    <TouchableOpacity key={u.id} style={s.resultRow} onPress={() => setTarget(u)}>
                      <View style={s.resultAvatar}>
                        <Text style={s.resultAvatarText}>{ini}</Text>
                      </View>
                      <View style={{ flex: 1 }}>
                        <Text style={s.resultName}>{name ?? sub ?? "Unknown"}</Text>
                        {name && sub && <Text style={s.resultEmail}>{sub}</Text>}
                      </View>
                      <Text style={s.resultSelect}>Select</Text>
                    </TouchableOpacity>
                  );
                })}

                {hasSearched && !searching && searchRes.length === 0 && !searchError && (
                  <Text style={[s.emptyText, { marginTop: 12 }]}>No users found.</Text>
                )}
              </>
            ) : (
              <View style={s.selectedTarget}>
                <View style={s.resultAvatar}>
                  <Text style={s.resultAvatarText}>
                    {initials(target.display_name, target.email)}
                  </Text>
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={s.selectedName}>
                    {target.display_name ?? target.email ?? target.iou_hash ?? "Unknown"}
                  </Text>
                  {target.display_name && target.email && (
                    <Text style={s.selectedEmail}>{target.email}</Text>
                  )}
                </View>
                <TouchableOpacity onPress={() => setTarget(null)}>
                  <Text style={s.clearTarget}>Change</Text>
                </TouchableOpacity>
              </View>
            )}

            <Text style={[s.modalLabel, { marginTop: 24 }]}>Scope</Text>
            {SCOPE_OPTIONS.map((opt) => (
              <TouchableOpacity
                key={opt.value}
                style={[s.optionRow, scope === opt.value && s.optionRowActive]}
                onPress={() => setScope(opt.value)}
              >
                <View style={{ flex: 1 }}>
                  <Text style={[s.optionLabel, scope === opt.value && { color: BLUE }]}>
                    {opt.label}
                  </Text>
                  <Text style={s.optionDesc}>{opt.desc}</Text>
                </View>
                {scope === opt.value && <Text style={s.optionCheck}>✓</Text>}
              </TouchableOpacity>
            ))}

            <Text style={[s.modalLabel, { marginTop: 24 }]}>Expires</Text>
            <View style={s.expiryRow}>
              {EXPIRY_OPTIONS.map((opt) => (
                <TouchableOpacity
                  key={opt.value}
                  style={[s.expiryChip, expiry === opt.value && s.expiryChipActive]}
                  onPress={() => setExpiry(opt.value)}
                >
                  <Text style={[s.expiryChipText, expiry === opt.value && { color: BLUE }]}>
                    {opt.label}
                  </Text>
                </TouchableOpacity>
              ))}
            </View>

            <TouchableOpacity
              style={[s.primaryBtn, { marginTop: 28 }, (!target || sharing) && s.primaryBtnDisabled]}
              onPress={createShare}
              disabled={!target || sharing}
            >
              {sharing
                ? <ActivityIndicator color="#fff" />
                : <Text style={s.primaryBtnText}>Share</Text>
              }
            </TouchableOpacity>

            <Text style={s.privacyNote}>
              You can revoke this share at any time from the Sharing tab.
            </Text>
          </ScrollView>
        </View>
      </Modal>

      {/* ── 7 Pillars info modal ── */}
      <Modal visible={pillarsOpen} animationType="slide" presentationStyle="pageSheet">
        <View style={s.modal}>
          <View style={s.modalHeader}>
            <Text style={s.modalTitle}>The 7 Pillars of IOU Trust</Text>
            <TouchableOpacity onPress={() => setPillarsOpen(false)}>
              <Text style={s.modalClose}>Done</Text>
            </TouchableOpacity>
          </View>
          <ScrollView
            contentContainerStyle={s.modalContent}
            showsVerticalScrollIndicator={false}
          >
            <Text style={s.pillarsIntro}>
              IOU Trust is built from real obligations, proof, relationships, and outcomes. Not guesses.
            </Text>
            {PILLARS.map((p) => (
              <View key={p.n} style={s.pillarRow}>
                <View style={s.pillarNum}>
                  <Text style={s.pillarNumText}>{p.n}</Text>
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={s.pillarTitle}>{p.title}</Text>
                  <Text style={s.pillarBody}>{p.body}</Text>
                </View>
              </View>
            ))}
          </ScrollView>
        </View>
      </Modal>
    </View>
  );
}

const s = StyleSheet.create({
  center: { flex: 1, alignItems: "center", justifyContent: "center" },
  content: { padding: 16, paddingBottom: 100 },

  tabRow: {
    flexDirection: "row",
    backgroundColor: "#fff",
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#E5E7EB",
  },
  tabBtn: { flex: 1, paddingVertical: 13, alignItems: "center" },
  tabActive: { borderBottomWidth: 2, borderBottomColor: BLUE },
  tabText: { fontSize: 13, fontWeight: "600", color: "#667085" },
  tabTextActive: { color: BLUE, fontWeight: "800" },

  privacyHeader: {
    backgroundColor: "#F0FDF4",
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#BBF7D0",
    paddingVertical: 8,
    paddingHorizontal: 16,
    alignItems: "center",
  },
  privacyHeaderText: { fontSize: 12, fontWeight: "700", color: GREEN_DARK },

  pillarsLink: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    backgroundColor: "#F0F4FF",
    borderRadius: 10,
    paddingVertical: 10,
    paddingHorizontal: 14,
    marginBottom: 14,
    borderWidth: 1,
    borderColor: "#DBEAFE",
  },
  pillarsLinkText: { fontSize: 13, fontWeight: "800", color: BLUE },
  pillarsLinkArrow: { fontSize: 15, fontWeight: "900", color: BLUE },

  scoreCard: {
    backgroundColor: "#fff",
    borderRadius: 16,
    padding: 16,
    marginBottom: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#E5E7EB",
  },
  rowBetween: { flexDirection: "row", justifyContent: "space-between", alignItems: "center" },
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
  emptyText: { color: "#667085", lineHeight: 22, fontSize: 14 },

  primaryBtn: {
    backgroundColor: BLUE,
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: "center",
    marginBottom: 14,
  },
  primaryBtnDisabled: { opacity: 0.5 },
  primaryBtnText: { color: "#fff", fontWeight: "800", fontSize: 15 },

  // Section headers inside Sharing tab
  sectionHeaderRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 10,
  },
  sectionHeaderLabel: {
    fontSize: 12,
    fontWeight: "800",
    color: "#6B7280",
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
  shareInlineBtn: {
    backgroundColor: BLUE,
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  shareInlineBtnText: { color: "#fff", fontWeight: "800", fontSize: 13 },

  sharedRow: {
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 14,
    marginBottom: 10,
    flexDirection: "row",
    alignItems: "center",
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#E5E7EB",
  },
  viewReportBtn: {
    marginLeft: 12,
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 8,
    backgroundColor: BLUE,
  },
  viewReportBtnText: { color: "#fff", fontWeight: "800", fontSize: 13 },

  shareRow: {
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 14,
    marginBottom: 10,
    flexDirection: "row",
    alignItems: "center",
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#E5E7EB",
  },
  shareName: { fontSize: 15, fontWeight: "800", color: "#111" },
  shareMetaRow: { flexDirection: "row", alignItems: "center", marginTop: 6, gap: 8 },
  scopePill: {
    backgroundColor: "#EEF4FF",
    borderRadius: 999,
    paddingHorizontal: 8,
    paddingVertical: 4,
  },
  scopePillText: { color: BLUE, fontWeight: "700", fontSize: 11 },
  shareExpiry: { color: "#667085", fontSize: 12, fontWeight: "600" },
  shareDate: { color: "#9CA3AF", fontSize: 11, marginTop: 4 },
  revokeBtn: {
    marginLeft: 12,
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: RED,
  },
  revokeBtnText: { color: RED, fontWeight: "800", fontSize: 13 },

  logRow: {
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 14,
    marginBottom: 8,
    flexDirection: "row",
    alignItems: "flex-start",
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#E5E7EB",
  },
  logAction: { fontSize: 14, fontWeight: "800", color: "#111" },
  logName: { fontSize: 13, color: "#444", marginTop: 2 },
  logMeta: { fontSize: 12, color: "#667085", marginTop: 2 },
  logTime: { fontSize: 12, color: "#9CA3AF", fontWeight: "600", marginLeft: 10 },

  modal: { flex: 1, backgroundColor: "#fff" },
  modalHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    padding: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#E5E7EB",
  },
  modalTitle: { fontSize: 18, fontWeight: "800", color: "#111" },
  modalClose: { fontSize: 15, color: BLUE, fontWeight: "700" },
  modalContent: { padding: 16, paddingBottom: 40 },
  modalLabel: {
    fontSize: 12,
    fontWeight: "800",
    color: "#333",
    textTransform: "uppercase",
    letterSpacing: 0.4,
    marginBottom: 10,
  },

  searchRow: { flexDirection: "row", gap: 8, marginBottom: 8 },
  searchInput: {
    flex: 1,
    borderWidth: 1,
    borderColor: "#E5E7EB",
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 10,
    backgroundColor: "#F9FAFB",
    fontSize: 15,
  },
  searchBtn: {
    backgroundColor: BLUE,
    borderRadius: 10,
    paddingHorizontal: 16,
    justifyContent: "center",
    alignItems: "center",
    minWidth: 70,
  },
  searchBtnText: { color: "#fff", fontWeight: "800" },
  searchHint: { fontSize: 13, color: "#9CA3AF", marginBottom: 12 },
  searchErrorText: { fontSize: 13, color: RED, marginBottom: 12 },

  resultRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingVertical: 10,
    gap: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#F0F0F0",
  },
  resultAvatar: {
    width: 38,
    height: 38,
    borderRadius: 19,
    backgroundColor: "#EEF4FF",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
  },
  resultAvatarText: { color: BLUE, fontWeight: "900", fontSize: 15 },
  resultName: { fontSize: 15, fontWeight: "700", color: "#111" },
  resultEmail: { fontSize: 13, color: "#667085", marginTop: 2 },
  resultSelect: { color: BLUE, fontWeight: "800", fontSize: 14, marginLeft: 10 },

  selectedTarget: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: "#EEF4FF",
    borderRadius: 12,
    padding: 12,
    marginBottom: 4,
    gap: 10,
  },
  selectedName: { fontSize: 15, fontWeight: "800", color: "#111" },
  selectedEmail: { fontSize: 13, color: "#667085", marginTop: 2 },
  clearTarget: { color: BLUE, fontWeight: "700", fontSize: 14, marginLeft: 10 },

  optionRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingVertical: 12,
    paddingHorizontal: 14,
    borderRadius: 10,
    marginBottom: 6,
    borderWidth: 1,
    borderColor: "#E5E7EB",
    backgroundColor: "#fff",
  },
  optionRowActive: { borderColor: BLUE, backgroundColor: "#EEF4FF" },
  optionLabel: { fontSize: 15, fontWeight: "700", color: "#111" },
  optionDesc: { fontSize: 12, color: "#667085", marginTop: 2 },
  optionCheck: { fontSize: 16, fontWeight: "900", color: BLUE, marginLeft: 10 },

  expiryRow: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  expiryChip: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 999,
    borderWidth: 1,
    borderColor: "#E5E7EB",
    backgroundColor: "#fff",
  },
  expiryChipActive: { borderColor: BLUE, backgroundColor: "#EEF4FF" },
  expiryChipText: { fontSize: 13, fontWeight: "700", color: "#667085" },

  privacyNote: {
    fontSize: 12,
    color: "#9CA3AF",
    textAlign: "center",
    marginTop: 12,
    lineHeight: 18,
  },

  pillarsIntro: { fontSize: 14, color: "#555", lineHeight: 22, marginBottom: 20 },
  pillarRow: { flexDirection: "row", gap: 14, marginBottom: 20, alignItems: "flex-start" },
  pillarNum: {
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: BLUE,
    alignItems: "center",
    justifyContent: "center",
    marginTop: 1,
    flexShrink: 0,
  },
  pillarNumText: { color: "#fff", fontWeight: "900", fontSize: 13 },
  pillarTitle: { fontSize: 15, fontWeight: "800", color: "#111", marginBottom: 4 },
  pillarBody: { fontSize: 13, color: "#555", lineHeight: 20 },
});

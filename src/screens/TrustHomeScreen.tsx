// src/screens/TrustHomeScreen.tsx
// Future root of the Trust bottom tab.
// Step 1: created as a standalone screen, temporarily reachable from Profile dev card.
// Step 2 (pending): promoted to TrustStack tab root; IOUsTab replaced.
import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  ActivityIndicator,
  Modal,
  ScrollView,
  StyleSheet,
  Text,
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

type PublicProfileRow = {
  id: string;
  iou_hash: string | null;
  display_name: string | null;
  name: string | null;
  iou_score: number | null;
  active_exposure_points: number | null;
  score_cap: number | null;
  lifetime_score_cap: number | null;
  strike_count: number | null;
};

const PILLARS = [
  { n: "1", title: "Payment Reliability", body: "Whether payments are completed early, on time, late, missed, reversed, or recovered." },
  { n: "2", title: "Obligation Strength", body: "How serious the obligation was, including amount, term length, repayment speed, and difficulty." },
  { n: "3", title: "Proof Depth", body: "How strongly IOU can verify what happened, from manual confirmation to verified payment rails." },
  { n: "4", title: "Housing & Recurring Stability", body: "Consistency with rent, phone bills, utilities, and other recurring responsibilities." },
  { n: "5", title: "Relationship Trust", body: "Whether trust is broad, healthy, and real, including counterparty diversity and no-score family/private lanes." },
  { n: "6", title: "Fairness & Conduct", body: "How borrowers and lenders behave, including fair terms, extensions, disputes, and confirmation behavior." },
  { n: "7", title: "Trust Intelligence", body: "How IOU learns from outcomes, explains trust, tracks model versions, and keeps reports auditable." },
];

function scoreLabel(v: number | null): string {
  if (v === null) return "Not live yet";
  if (v >= 1400) return "Lending";
  if (v >= 1000) return "Strong";
  if (v >= 800) return "Rising";
  if (v >= 700) return "Starter";
  if (v >= 500) return "Watch";
  return "Critical";
}

function scoreColor(v: number | null): string {
  if (v === null) return "#111";
  if (v >= 1000) return GREEN_DARK;
  if (v >= 800) return GREEN;
  if (v >= 700) return BLUE;
  if (v >= 500) return AMBER;
  return RED;
}

function EntryCard({
  title,
  subtitle,
  accent = BLUE,
  onPress,
}: {
  title: string;
  subtitle: string;
  accent?: string;
  onPress: () => void;
}) {
  return (
    <TouchableOpacity
      style={[s.entryCard, { borderLeftColor: accent }]}
      onPress={onPress}
      activeOpacity={0.88}
    >
      <View style={{ flex: 1 }}>
        <Text style={[s.entryCardTitle, { color: accent }]}>{title}</Text>
        <Text style={s.entryCardSub}>{subtitle}</Text>
      </View>
      <Text style={[s.entryCardArrow, { color: accent }]}>→</Text>
    </TouchableOpacity>
  );
}

export default function TrustHomeScreen({ navigation }: any) {
  const [loading, setLoading] = useState(true);
  const [profile, setProfile] = useState<PublicProfileRow | null>(null);
  const [pillarsOpen, setPillarsOpen] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const me = (await supabase.auth.getUser()).data.user;
      if (!me?.id) return;

      const { data } = await supabase
        .from("profiles")
        .select("id, iou_hash, display_name, name, iou_score, active_exposure_points, score_cap, lifetime_score_cap, strike_count")
        .eq("id", me.id)
        .single();

      if (data) setProfile(data as PublicProfileRow);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const score = useMemo(() => {
    if (typeof profile?.iou_score !== "number") return null;
    return Math.max(0, Math.round(profile.iou_score));
  }, [profile]);

  const exposure = useMemo(() => {
    if (typeof profile?.active_exposure_points !== "number") return 0;
    return Math.max(0, Math.round(profile.active_exposure_points));
  }, [profile]);

  const visibleTrust = useMemo(() => {
    if (score === null) return null;
    return Math.max(0, score - exposure);
  }, [score, exposure]);

  const label = scoreLabel(score);
  const color = scoreColor(score);

  if (loading) {
    return <View style={s.center}><ActivityIndicator color={GREEN} /></View>;
  }

  return (
    <ScrollView
      style={{ flex: 1, backgroundColor: BG }}
      contentContainerStyle={s.content}
      showsVerticalScrollIndicator={false}
    >
      {/* Score hero */}
      <TouchableOpacity
        style={s.scoreCard}
        onPress={() => navigation.navigate("ScoreHistory")}
        activeOpacity={0.95}
      >
        <View style={s.scoreCardTop}>
          <Text style={s.scoreEyebrow}>IOU Trust Score</Text>
          <View style={[s.tierPill, { backgroundColor: color + "22" }]}>
            <Text style={[s.tierPillText, { color }]}>{label}</Text>
          </View>
        </View>

        <Text style={[s.scoreValue, { color }]}>
          {score === null ? "—" : score}
        </Text>

        <Text style={s.scoreHint}>
          {score === null ? "Waiting for live score fields." : "Your base IOU trust score."}
        </Text>

        <View style={s.metricsRow}>
          <View style={s.metricBox}>
            <Text style={s.metricLabel}>Visible Trust</Text>
            <Text style={s.metricValue}>
              {visibleTrust === null ? "—" : visibleTrust}
            </Text>
          </View>
          <View style={s.metricBox}>
            <Text style={s.metricLabel}>Active Exposure</Text>
            <Text style={[s.metricValue, exposure > 0 ? { color: AMBER } : { color: GREEN_DARK }]}>
              {exposure > 0 ? `-${exposure}` : "0"}
            </Text>
          </View>
        </View>

        <View style={s.scoreHistoryCta}>
          <Text style={s.scoreHistoryCtaText}>Open score history</Text>
          <Text style={s.scoreHistoryCtaArrow}>→</Text>
        </View>
      </TouchableOpacity>

      {/* Trust data entry points */}
      <Text style={s.sectionLabel}>Your Trust</Text>

      <EntryCard
        title="Trust Report"
        subtitle="Proof depth, visible trust, coaching note, risk summary"
        accent={BLUE}
        onPress={() => navigation.navigate("TrustReport")}
      />

      <EntryCard
        title="Shared With Me"
        subtitle="Trust Reports other people have shared with you"
        accent={BLUE}
        onPress={() => navigation.navigate("TrustReport")}
      />

      <EntryCard
        title="Sharing and Access Log"
        subtitle="Manage active shares and see who has viewed your report"
        accent={BLUE}
        onPress={() => navigation.navigate("TrustReport")}
      />

      {/* Education entry points */}
      <Text style={[s.sectionLabel, { marginTop: 8 }]}>Learn</Text>

      <EntryCard
        title="The 7 Pillars of IOU Trust"
        subtitle="What IOU measures and how each pillar works"
        accent={GREEN_DARK}
        onPress={() => setPillarsOpen(true)}
      />

      <EntryCard
        title="How IOU Trust Works"
        subtitle="The full intro: what helps, what hurts, and your privacy rights"
        accent={GREEN_DARK}
        onPress={() => navigation.navigate("TrustIntro")}
      />

      {/* 7 Pillars modal */}
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
    </ScrollView>
  );
}

const s = StyleSheet.create({
  center: { flex: 1, alignItems: "center", justifyContent: "center" },
  content: { padding: 16, paddingBottom: 100 },

  scoreCard: {
    backgroundColor: "#fff",
    borderRadius: 16,
    padding: 16,
    marginBottom: 20,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#E5E7EB",
  },
  scoreCardTop: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
  },
  scoreEyebrow: {
    fontSize: 11,
    fontWeight: "800",
    textTransform: "uppercase",
    letterSpacing: 0.5,
    color: "#667085",
  },
  tierPill: {
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 5,
  },
  tierPillText: { fontWeight: "800", fontSize: 12 },
  scoreValue: { fontSize: 56, fontWeight: "900", lineHeight: 62, marginTop: 4 },
  scoreHint: { color: "#666", fontSize: 14, marginTop: 2 },

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
  metricValue: { fontSize: 24, fontWeight: "900", color: "#111" },

  scoreHistoryCta: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginTop: 14,
    paddingTop: 12,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#E5E7EB",
  },
  scoreHistoryCtaText: { color: BLUE, fontWeight: "800", fontSize: 14 },
  scoreHistoryCtaArrow: { color: BLUE, fontWeight: "900", fontSize: 16 },

  sectionLabel: {
    fontSize: 12,
    fontWeight: "800",
    color: "#6B7280",
    textTransform: "uppercase",
    letterSpacing: 0.5,
    marginBottom: 10,
  },

  entryCard: {
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 14,
    marginBottom: 10,
    flexDirection: "row",
    alignItems: "center",
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#E5E7EB",
    borderLeftWidth: 3,
  },
  entryCardTitle: { fontSize: 15, fontWeight: "800", marginBottom: 3 },
  entryCardSub: { fontSize: 12, color: "#667085", lineHeight: 18 },
  entryCardArrow: { fontSize: 18, fontWeight: "900", marginLeft: 12 },

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
  pillarsIntro: { fontSize: 14, color: "#555", lineHeight: 22, marginBottom: 20 },
  pillarRow: { flexDirection: "row", gap: 14, marginBottom: 20, alignItems: "flex-start" },
  pillarNum: {
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: GREEN_DARK,
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    marginTop: 1,
  },
  pillarNumText: { color: "#fff", fontWeight: "900", fontSize: 13 },
  pillarTitle: { fontSize: 15, fontWeight: "800", color: "#111", marginBottom: 4 },
  pillarBody: { fontSize: 13, color: "#555", lineHeight: 20 },
});

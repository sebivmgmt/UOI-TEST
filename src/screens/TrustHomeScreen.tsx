// src/screens/TrustHomeScreen.tsx
// Future root of the Trust bottom tab.
// Step 1: created as a standalone screen, temporarily reachable from Profile dev card.
// Step 2 (pending): promoted to TrustStack tab root; IOUsTab replaced.
import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  ActivityIndicator,
  Modal,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from "react-native";
import { supabase } from "../supabase";
import { useAppTheme, AppTheme } from "../theme";
import { getMyOfficialIouScoreV22, tierColor, formatTierLabel } from "../services/iouScoreV22";

const GREEN = "#77B777";
const GREEN_DARK = "#5F9F5F";
const RED = "#D9534F";
const BLUE = "#3B82F6";
const AMBER = "#B7791F";
const PURPLE = "#7C3AED";

type ShadowScoreRow = {
  model_version: string;
  base_score: number;
  effective_contribution_total: number;
  shadow_score: number;
  active_exposure_points: number;
  freshness_score: number;
  visible_trust: number;
  trust_tier: string;
  proof_depth: number;
  proof_depth_label: string;
  confidence_score: number;
  confidence_label: string;
  qualifying_agreement_count: number;
  qualifying_ceiling_total: number;
  lifetime_reward_total: number;
  lifetime_penalty_total: number;
  contribution_window_start: string;
  days_on_platform: number;
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
  const theme = useAppTheme();
  const es = useMemo(() => makeS(theme), [theme]);
  return (
    <TouchableOpacity
      style={[es.entryCard, { borderLeftColor: accent }]}
      onPress={onPress}
      activeOpacity={0.88}
    >
      <View style={{ flex: 1 }}>
        <Text style={[es.entryCardTitle, { color: accent }]}>{title}</Text>
        <Text style={es.entryCardSub}>{subtitle}</Text>
      </View>
      <Text style={[es.entryCardArrow, { color: accent }]}>→</Text>
    </TouchableOpacity>
  );
}

export default function TrustHomeScreen({ navigation }: any) {
  const theme = useAppTheme();
  const s = useMemo(() => makeS(theme), [theme]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [shadowData, setShadowData] = useState<ShadowScoreRow | null>(null);
  const [shadowLoading, setShadowLoading] = useState(true);
  const [shadowError, setShadowError] = useState<string | null>(null);
  const [pillarsOpen, setPillarsOpen] = useState(false);

  const load = useCallback(async () => {
    try {
      const me = (await supabase.auth.getUser()).data.user;
      if (!me?.id) return;

      const result = await getMyOfficialIouScoreV22();
      if (result === null) {
        setShadowError("Score unavailable");
        setShadowData(null);
      } else {
        setShadowData(result as unknown as ShadowScoreRow);
        setShadowError(null);
      }
    } finally {
      setLoading(false);
      setShadowLoading(false);
      setRefreshing(false);
    }
  }, []);

  const onRefresh = useCallback(() => {
    setRefreshing(true);
    void load();
  }, [load]);

  useEffect(() => {
    setLoading(true);
    setShadowLoading(true);
    void load();
  }, [load]);

  const score = shadowData?.shadow_score ?? null;
  const exposure = shadowData?.active_exposure_points ?? 0;
  const visibleTrust = shadowData?.visible_trust ?? null;
  const label = formatTierLabel(shadowData?.trust_tier);
  const color = tierColor(shadowData?.trust_tier, {
    strong: GREEN_DARK,
    rising: GREEN,
    starter: BLUE,
    watch: AMBER,
    muted: "#9CA3AF",
    critical: RED,
  });

  if (loading) {
    return <View style={[s.center, { backgroundColor: theme.background }]}><ActivityIndicator color={GREEN} /></View>;
  }

  return (
    <ScrollView
      style={{ flex: 1, backgroundColor: theme.background }}
      contentContainerStyle={s.content}
      showsVerticalScrollIndicator={false}
      refreshControl={
        <RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={GREEN} />
      }
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
          {score === null ? "No score yet." : "Your base IOU trust score."}
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

      {/* Score v2.1 Shadow — DEV only */}
      <View style={s.shadowCard}>
        <View style={s.shadowHeader}>
          <Text style={s.shadowTitle}>Score v2.2 — Shadow</Text>
          <View style={s.shadowBadge}>
            <Text style={s.shadowBadgeText}>DEV</Text>
          </View>
        </View>

        {shadowLoading && !shadowData ? (
          <ActivityIndicator color={PURPLE} style={{ marginTop: 12 }} />
        ) : shadowError ? (
          <View style={s.shadowErrorBlock}>
            <Text style={s.shadowErrorText}>{shadowError}</Text>
            <TouchableOpacity
              style={s.retryBtn}
              onPress={() => { setShadowLoading(true); void load(); }}
              activeOpacity={0.8}
            >
              <Text style={s.retryBtnText}>Retry</Text>
            </TouchableOpacity>
          </View>
        ) : shadowData ? (
          <>
            <View style={s.shadowScoreRow}>
              <Text style={s.shadowScoreValue}>{shadowData.shadow_score}</Text>
              <View style={s.shadowTierPill}>
                <Text style={s.shadowTierPillText}>{shadowData.trust_tier.replace(/_/g, " ")}</Text>
              </View>
            </View>
            <Text style={s.shadowModelLabel}>{shadowData.model_version}</Text>

            <View style={s.shadowMetrics}>
              <View style={s.shadowMetric}>
                <Text style={s.shadowMetricLabel}>Visible Trust</Text>
                <Text style={s.shadowMetricValue}>{shadowData.visible_trust}</Text>
              </View>
              <View style={s.shadowMetric}>
                <Text style={s.shadowMetricLabel}>Exposure</Text>
                <Text style={[s.shadowMetricValue, shadowData.active_exposure_points > 0 && { color: AMBER }]}>
                  {shadowData.active_exposure_points > 0 ? `-${shadowData.active_exposure_points}` : "0"}
                </Text>
              </View>
              <View style={s.shadowMetric}>
                <Text style={s.shadowMetricLabel}>Contributions</Text>
                <Text style={[s.shadowMetricValue, shadowData.effective_contribution_total >= 0 ? { color: GREEN_DARK } : { color: RED }]}>
                  {shadowData.effective_contribution_total >= 0 ? `+${shadowData.effective_contribution_total}` : `${shadowData.effective_contribution_total}`}
                </Text>
              </View>
            </View>

            <View style={s.shadowMetrics}>
              <View style={s.shadowMetric}>
                <Text style={s.shadowMetricLabel}>Proof Depth</Text>
                <Text style={s.shadowMetricValue}>{shadowData.proof_depth}</Text>
                <Text style={s.shadowMetricSub}>{shadowData.proof_depth_label.replace(/_/g, " ")}</Text>
              </View>
              <View style={s.shadowMetric}>
                <Text style={s.shadowMetricLabel}>Confidence</Text>
                <Text style={s.shadowMetricValue}>{shadowData.confidence_score}</Text>
                <Text style={s.shadowMetricSub}>{shadowData.confidence_label.replace(/_/g, " ")}</Text>
              </View>
              <View style={s.shadowMetric}>
                <Text style={s.shadowMetricLabel}>Agreements</Text>
                <Text style={s.shadowMetricValue}>{shadowData.qualifying_agreement_count}</Text>
                <Text style={s.shadowMetricSub}>in window</Text>
              </View>
            </View>

            <View style={s.shadowFooter}>
              <Text style={s.shadowFooterText}>
                Rewards +{shadowData.lifetime_reward_total} · Penalties −{shadowData.lifetime_penalty_total} · Base {shadowData.base_score}
              </Text>
            </View>
          </>
        ) : null}
      </View>

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

const makeS = (t: AppTheme) => StyleSheet.create({
  center: { flex: 1, alignItems: "center", justifyContent: "center" },
  content: { padding: 16, paddingBottom: 100 },

  scoreCard: {
    backgroundColor: t.surface,
    borderRadius: 16,
    padding: 16,
    marginBottom: 20,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: t.border,
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
    color: t.textMuted,
  },
  tierPill: {
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 5,
  },
  tierPillText: { fontWeight: "800", fontSize: 12 },
  scoreValue: { fontSize: 56, fontWeight: "900", lineHeight: 62, marginTop: 4 },
  scoreHint: { color: t.textMuted, fontSize: 14, marginTop: 2 },

  metricsRow: { flexDirection: "row", gap: 10, marginTop: 14 },
  metricBox: {
    flex: 1,
    backgroundColor: t.surfaceMuted,
    borderRadius: 12,
    padding: 12,
    borderWidth: 1,
    borderColor: t.border,
  },
  metricLabel: {
    fontSize: 11,
    fontWeight: "800",
    color: t.textMuted,
    textTransform: "uppercase",
    marginBottom: 4,
  },
  metricValue: { fontSize: 24, fontWeight: "900", color: t.textPrimary },

  scoreHistoryCta: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginTop: 14,
    paddingTop: 12,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: t.border,
  },
  scoreHistoryCtaText: { color: BLUE, fontWeight: "800", fontSize: 14 },
  scoreHistoryCtaArrow: { color: BLUE, fontWeight: "900", fontSize: 16 },

  sectionLabel: {
    fontSize: 12,
    fontWeight: "800",
    color: t.textMuted,
    textTransform: "uppercase",
    letterSpacing: 0.5,
    marginBottom: 10,
  },

  entryCard: {
    backgroundColor: t.surface,
    borderRadius: 12,
    padding: 14,
    marginBottom: 10,
    flexDirection: "row",
    alignItems: "center",
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: t.border,
    borderLeftWidth: 3,
  },
  entryCardTitle: { fontSize: 15, fontWeight: "800", marginBottom: 3 },
  entryCardSub: { fontSize: 12, color: t.textMuted, lineHeight: 18 },
  entryCardArrow: { fontSize: 18, fontWeight: "900", marginLeft: 12 },

  shadowCard: {
    backgroundColor: t.surface,
    borderRadius: 16,
    padding: 16,
    marginBottom: 20,
    borderWidth: 1.5,
    borderColor: PURPLE + "33",
  },
  shadowHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 4,
  },
  shadowTitle: {
    fontSize: 11,
    fontWeight: "800",
    textTransform: "uppercase",
    letterSpacing: 0.5,
    color: PURPLE,
  },
  shadowBadge: {
    backgroundColor: PURPLE + "18",
    borderRadius: 6,
    paddingHorizontal: 7,
    paddingVertical: 3,
  },
  shadowBadgeText: {
    fontSize: 10,
    fontWeight: "800",
    color: PURPLE,
    letterSpacing: 0.5,
  },
  shadowScoreRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    marginTop: 6,
  },
  shadowScoreValue: {
    fontSize: 48,
    fontWeight: "900",
    color: PURPLE,
    lineHeight: 54,
  },
  shadowTierPill: {
    backgroundColor: PURPLE + "18",
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 5,
  },
  shadowTierPillText: {
    fontSize: 12,
    fontWeight: "800",
    color: PURPLE,
    textTransform: "capitalize",
  },
  shadowModelLabel: {
    fontSize: 11,
    color: t.textMuted,
    marginBottom: 12,
    marginTop: 2,
  },
  shadowMetrics: {
    flexDirection: "row",
    gap: 8,
    marginBottom: 8,
  },
  shadowMetric: {
    flex: 1,
    backgroundColor: t.isDark ? "#130D1E" : "#F6F4FD",
    borderRadius: 10,
    padding: 10,
  },
  shadowMetricLabel: {
    fontSize: 10,
    fontWeight: "800",
    color: PURPLE + "AA",
    textTransform: "uppercase",
    marginBottom: 3,
  },
  shadowMetricValue: {
    fontSize: 20,
    fontWeight: "900",
    color: t.textPrimary,
  },
  shadowMetricSub: {
    fontSize: 10,
    color: t.textMuted,
    marginTop: 2,
    textTransform: "capitalize",
  },
  shadowFooter: {
    marginTop: 4,
    paddingTop: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: PURPLE + "22",
  },
  shadowFooterText: {
    fontSize: 11,
    color: t.textMuted,
  },
  shadowErrorBlock: {
    marginTop: 12,
    alignItems: "flex-start",
  },
  shadowErrorText: {
    fontSize: 13,
    color: RED,
    marginBottom: 10,
  },
  retryBtn: {
    backgroundColor: PURPLE + "18",
    borderRadius: 8,
    paddingHorizontal: 14,
    paddingVertical: 7,
  },
  retryBtnText: {
    fontSize: 13,
    fontWeight: "800",
    color: PURPLE,
  },

  modal: { flex: 1, backgroundColor: t.surface },
  modalHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    padding: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: t.border,
  },
  modalTitle: { fontSize: 18, fontWeight: "800", color: t.textPrimary },
  modalClose: { fontSize: 15, color: BLUE, fontWeight: "700" },
  modalContent: { padding: 16, paddingBottom: 40 },
  pillarsIntro: { fontSize: 14, color: t.textSecondary, lineHeight: 22, marginBottom: 20 },
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
  pillarTitle: { fontSize: 15, fontWeight: "800", color: t.textPrimary, marginBottom: 4 },
  pillarBody: { fontSize: 13, color: t.textSecondary, lineHeight: 20 },
});

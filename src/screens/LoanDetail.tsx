// src/screens/LoanDetail.tsx

import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useAppTheme, AppTheme } from '../theme';
import {
  View,
  Text,
  Alert,
  ActivityIndicator,
  Animated,
  FlatList,
  ScrollView,
  SectionList,
  TouchableOpacity,
  StyleSheet,
  RefreshControl,
  Share,
} from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import Swipeable from 'react-native-gesture-handler/Swipeable';
import { RectButton } from 'react-native-gesture-handler';
import { supabase } from '../supabase';

// ---------------------------------------------
// TYPES
// ---------------------------------------------

type Frequency = 'weekly' | 'biweekly' | 'monthly';
type ViewDirection = 'in' | 'out';

type Iou = {
  id: string;
  title: string | null;
  lender_id: string;
  borrower_id: string | null;
  principal_cents: number;
  apr_bps: number;
  start_date: string | null;
  term_months: number;
  frequency: Frequency;
  status: 'draft' | 'open' | 'late' | 'paid' | 'archived' | string;
  archived_at: string | null;
  deleted_at: string | null;
  activated_at: string | null;
  total_installments?: number | null;
  paid_installments?: number | null;
  progress_percent?: number | null;
};

type PaymentRow = {
  id: string;
  iou_id: string;
  amount_cents: number;
  status: 'scheduled' | 'pending_confirmation' | 'paid' | 'late' | string;
  paid_at: string | null;
  due: string;
  payment_method?: string | null;
  extension_status?: string | null;
  extension_requested_until?: string | null;
  extension_requested_at?: string | null;
};

type BorrowerProfile = {
  iou_score?: number | null;
  active_exposure_points?: number | null;
  public_name?: string | null;
} | null;

// DEV-only — Score v2.2 in-progress view
type ScoreV22Progress = {
  score_agreement_id: string;
  model_version: string;
  principal_cents: number;
  paid_cents: number;
  repayment_fraction: number;
  completion_progress_points: number;
  completion_reward_max: number;
  early_bonus_earned: number;
  early_bonus_max: number;
  pending_positive_points: number;
  active_penalties: number;
  projected_completed_contribution: number;
  current_public_score_effect: number;
  agreement_completed: boolean;
  positive_points_unlocked: boolean;
  positive_points_unlock_condition: string;
};

function isScoreV22Progress(v: unknown): v is ScoreV22Progress {
  if (typeof v !== 'object' || v === null) return false;
  const r = v as Record<string, unknown>;
  return (
    typeof r.model_version === 'string' &&
    typeof r.principal_cents === 'number' &&
    typeof r.paid_cents === 'number' &&
    typeof r.repayment_fraction === 'number' &&
    typeof r.completion_progress_points === 'number' &&
    typeof r.completion_reward_max === 'number' &&
    typeof r.early_bonus_earned === 'number' &&
    typeof r.early_bonus_max === 'number' &&
    typeof r.pending_positive_points === 'number' &&
    typeof r.active_penalties === 'number' &&
    typeof r.projected_completed_contribution === 'number' &&
    typeof r.current_public_score_effect === 'number' &&
    typeof r.agreement_completed === 'boolean' &&
    typeof r.positive_points_unlocked === 'boolean' &&
    typeof r.positive_points_unlock_condition === 'string'
  );
}

// ---------------------------------------------
// TAB / SCENARIO TYPES
// ---------------------------------------------

type TabId = 'overview' | 'payments' | 'score';
type ScenarioId = 'pay_next_today' | 'payoff_today' | 'complete_on_schedule';

type IouScoreScenario = {
  scenario: ScenarioId;
  eligible: boolean;
  paymentAmountCents: number | null;
  currentScore: number;
  projectedScore: number;
  scoreDelta: number;
  currentVisibleTrust: number;
  projectedVisibleTrust: number;
  visibleTrustDelta: number;
  currentIouEffect: number;
  projectedIouEffect: number;
  currentExposure: number;
  projectedExposure: number;
  exposureReleased: number;
  completionCreditUnlocked: number;
  earlyBonusUnlocked: number;
  retainedPenalty: number;
  completesIou: boolean;
  explanation: string[];
};

function isIouScoreScenario(v: unknown): v is IouScoreScenario {
  if (typeof v !== 'object' || v === null) return false;
  const r = v as Record<string, unknown>;
  return (
    typeof r.scenario === 'string' &&
    typeof r.eligible === 'boolean' &&
    typeof r.currentScore === 'number' &&
    typeof r.projectedScore === 'number' &&
    typeof r.scoreDelta === 'number' &&
    typeof r.currentVisibleTrust === 'number' &&
    typeof r.projectedVisibleTrust === 'number' &&
    typeof r.visibleTrustDelta === 'number' &&
    typeof r.completesIou === 'boolean' &&
    Array.isArray(r.explanation)
  );
}

// Payment section data for the Payments tab SectionList
type PaymentSectionData = { title: string; data: PaymentRow[] };

// ---------------------------------------------
// CONSTANTS
// ---------------------------------------------

const GREEN = '#77B777';
const BLUE = '#3b82f6';
const ORANGE = '#f59e0b';
const SOFT_BG = '#F5F7F9';

// These were legacy-system constants and are NOT backed by Score v2.
// Score v2 is ceiling-based, not per-payment additive — no authoritative
// per-event point value exists at read time. Do not restore numeric promises.
// const EARLY_REWARD = 27;
// const ON_TIME_REWARD = 7;
// const COMPLETION_REWARD = 77;

const currency = (c: number) => `$${(c / 100).toFixed(2)}`;

// Plain date strings (YYYY-MM-DD) must be parsed in local time, NOT UTC.
// new Date("2026-06-23") parses as UTC midnight → shows Jun 22 in US timezones.
const parseDateLocal = (dateStr: string): Date => {
  const [y, m, d] = dateStr.split('-').map(Number);
  return new Date(y, m - 1, d);
};

const formatDate = (dateStr: string): string => {
  if (!dateStr) return '';
  return parseDateLocal(dateStr).toLocaleDateString(undefined, {
    month: 'long',
    day: 'numeric',
    year: 'numeric',
  });
};

// ── DEV-only Score v2.2 progress card ────────────────────────────────────────

const makeSv = (t: AppTheme) => StyleSheet.create({
  card: {
    marginTop: 14,
    backgroundColor: t.surface,
    borderRadius: 14,
    padding: 16,
    borderWidth: 1,
    borderColor: t.border,
    shadowColor: '#000',
    shadowOpacity: t.isDark ? 0 : 0.05,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 2 },
    elevation: t.isDark ? 0 : 1,
  },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 16,
  },
  headerTitle: {
    fontSize: 13,
    fontWeight: '800',
    color: t.textSecondary,
  },
  headerRight: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  devBadge: {
    backgroundColor: '#1C1C1E',
    borderRadius: 4,
    paddingHorizontal: 5,
    paddingVertical: 2,
  },
  devBadgeText: {
    color: '#FFD60A',
    fontSize: 10,
    fontWeight: '800',
    letterSpacing: 0.5,
  },
  refreshBtn: {
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: t.surfaceMuted,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 1,
    borderColor: t.border,
  },
  refreshBtnText: {
    color: t.textSecondary,
    fontWeight: '700',
    fontSize: 16,
    lineHeight: 20,
  },
  stateRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 8,
  },
  stateText: {
    color: t.textSecondary,
    fontSize: 14,
  },
  unavailableBox: {
    backgroundColor: t.negativeSurface,
    borderRadius: 8,
    padding: 12,
    borderWidth: 1,
    borderColor: t.isDark ? '#3A0D0D' : '#FECACA',
  },
  unavailableText: {
    color: t.negative,
    fontSize: 13,
    fontWeight: '600',
    lineHeight: 19,
  },
  divider: {
    height: 1,
    backgroundColor: t.divider,
    marginVertical: 16,
  },
  sectionLabel: {
    fontSize: 11,
    fontWeight: '700',
    color: t.textMuted,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginBottom: 8,
  },
  heroRow: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: 4,
    marginBottom: 8,
  },
  heroValue: {
    fontSize: 56,
    fontWeight: '900',
    letterSpacing: -1.5,
    lineHeight: 60,
  },
  heroUnit: {
    fontSize: 20,
    fontWeight: '700',
    paddingBottom: 8,
  },
  heroCaption: {
    fontSize: 13,
    fontWeight: '500',
    color: t.textSecondary,
    lineHeight: 20,
  },
  repayRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'baseline',
    marginBottom: 10,
  },
  repayAmount: {
    fontSize: 17,
    fontWeight: '800',
    color: t.textPrimary,
  },
  repayPct: {
    fontSize: 13,
    fontWeight: '700',
    color: t.textMuted,
  },
  bar: {
    height: 8,
    borderRadius: 999,
    backgroundColor: t.isDark ? '#1A1A1A' : '#EAEAEA',
    overflow: 'hidden',
  },
  barFillGreen: {
    height: '100%',
    borderRadius: 999,
    backgroundColor: GREEN,
  },
  miniBar: {
    height: 5,
    borderRadius: 999,
    backgroundColor: t.isDark ? '#1A1A1A' : '#EAEAEA',
    overflow: 'hidden',
    marginTop: 6,
  },
  barFillBlue: {
    height: '100%',
    borderRadius: 999,
    backgroundColor: BLUE,
  },
  pendingSectionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 12,
  },
  lockedChip: {
    backgroundColor: t.isDark ? '#1A1000' : '#FFF7ED',
    borderRadius: 5,
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderWidth: 1,
    borderColor: t.isDark ? '#2A1400' : '#FED7AA',
  },
  lockedChipText: {
    color: t.isDark ? t.warning : '#C2410C',
    fontSize: 11,
    fontWeight: '700',
  },
  unlockedChip: {
    backgroundColor: t.positiveSurface,
    borderRadius: 5,
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderWidth: 1,
    borderColor: t.isDark ? '#0D3A15' : '#BBF7D0',
  },
  unlockedChipText: {
    color: t.positive,
    fontSize: 11,
    fontWeight: '700',
  },
  metricLine: {
    fontSize: 15,
    fontWeight: '800',
    color: t.textPrimary,
    marginBottom: 2,
  },
  earlyBonusLine: {
    fontSize: 14,
    fontWeight: '600',
    color: t.textSecondary,
    marginBottom: 2,
  },
  projectedRow: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: 4,
    marginBottom: 4,
  },
  projectedValue: {
    fontSize: 32,
    fontWeight: '900',
    color: t.textPrimary,
    letterSpacing: -0.5,
  },
  projectedUnit: {
    fontSize: 15,
    fontWeight: '700',
    color: t.textMuted,
    paddingBottom: 4,
  },
  projectedNote: {
    fontSize: 13,
    fontWeight: '500',
    color: t.textSecondary,
    lineHeight: 19,
  },
  lockedExplanation: {
    marginTop: 12,
    paddingTop: 12,
    borderTopWidth: 1,
    borderTopColor: t.divider,
    fontSize: 13,
    fontWeight: '500',
    color: t.textSecondary,
    lineHeight: 20,
  },
  penaltyBlock: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    backgroundColor: t.negativeSurface,
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 12,
  },
  penaltyLabel: {
    fontSize: 13,
    fontWeight: '700',
    color: t.negative,
  },
  penaltyNote: {
    fontSize: 12,
    fontWeight: '500',
    color: t.textMuted,
    marginTop: 2,
  },
  penaltyValue: {
    fontSize: 22,
    fontWeight: '900',
    color: t.negative,
  },
  techToggle: {
    marginTop: 14,
    paddingTop: 12,
    borderTopWidth: 1,
    borderTopColor: t.border,
  },
  techToggleText: {
    fontSize: 12,
    fontWeight: '600',
    color: t.textMuted,
  },
  techBox: {
    marginTop: 8,
    backgroundColor: t.surfaceMuted,
    borderRadius: 8,
    padding: 10,
    gap: 3,
  },
  techLine: {
    fontSize: 11,
    fontWeight: '500',
    color: t.textMuted,
    lineHeight: 17,
  },
});

function ScoreV22DevCard({
  data,
  loading,
  error,
  onRefresh,
  showDevBadge = true,
}: {
  data: ScoreV22Progress | null;
  loading: boolean;
  error: string | null;
  onRefresh: () => void;
  showDevBadge?: boolean;
}) {
  const theme = useAppTheme();
  const sv = useMemo(() => makeSv(theme), [theme]);
  const [techOpen, setTechOpen] = useState(false);

  const repayPct = data ? Math.min(100, Math.round(data.repayment_fraction * 100)) : 0;
  const completionPct =
    data && data.completion_reward_max > 0
      ? Math.min(100, Math.round((data.completion_progress_points / data.completion_reward_max) * 100))
      : 0;
  const earlyPct =
    data && data.early_bonus_max > 0
      ? Math.min(100, Math.round((data.early_bonus_earned / data.early_bonus_max) * 100))
      : 0;

  const effectColor =
    !data || data.current_public_score_effect === 0
      ? theme.textMuted
      : data.current_public_score_effect < 0
        ? theme.negative
        : GREEN;

  const heroCaption = !data
    ? ''
    : (() => {
        const parts: string[] = [];
        if (data.active_penalties > 0) {
          parts.push('An active penalty is affecting your score now.');
        }
        if (!data.positive_points_unlocked) {
          if (data.pending_positive_points > 0) {
            parts.push(
              `${data.pending_positive_points} positive points are pending until this IOU is completed.`
            );
          } else {
            parts.push(
              data.positive_points_unlock_condition ||
                'Positive points are pending until this IOU is completed.'
            );
          }
        } else if (data.active_penalties === 0) {
          parts.push('Positive points from this IOU are contributing to your score.');
        }
        return parts.join(' ');
      })();

  return (
    <View style={sv.card}>

      {/* Header */}
      <View style={sv.header}>
        <Text style={sv.headerTitle}>IOU Score Progress</Text>
        <View style={sv.headerRight}>
          {showDevBadge && (
            <View style={sv.devBadge}>
              <Text style={sv.devBadgeText}>DEV</Text>
            </View>
          )}
          <TouchableOpacity
            onPress={onRefresh}
            style={sv.refreshBtn}
            activeOpacity={loading ? 1 : 0.7}
            disabled={loading}
            accessibilityRole="button"
            accessibilityLabel="Refresh score progress"
          >
            <Text style={[sv.refreshBtnText, loading ? { opacity: 0.35 } : undefined]}>↻</Text>
          </TouchableOpacity>
        </View>
      </View>

      {/* Loading */}
      {loading && (
        <View style={sv.stateRow}>
          <ActivityIndicator size="small" color={BLUE} />
          <Text style={sv.stateText}>Loading…</Text>
        </View>
      )}

      {/* Unavailable */}
      {!loading && !!error && (
        <View style={sv.unavailableBox}>
          <Text style={sv.unavailableText}>{error}</Text>
        </View>
      )}

      {/* Empty */}
      {!loading && !error && !data && (
        <Text style={sv.stateText}>Score progress is unavailable for this IOU.</Text>
      )}

      {/* Success */}
      {!loading && !error && !!data && (
        <View>

          {/* 1. Current score effect — hero */}
          <Text style={sv.sectionLabel}>Current score effect</Text>
          <View style={sv.heroRow}>
            <Text style={[sv.heroValue, { color: effectColor }]}>
              {data.current_public_score_effect > 0 ? '+' : ''}
              {data.current_public_score_effect}
            </Text>
            <Text style={[sv.heroUnit, { color: effectColor }]}>pts</Text>
          </View>
          {!!heroCaption && <Text style={sv.heroCaption}>{heroCaption}</Text>}

          <View style={sv.divider} />

          {/* 2. Repayment progress */}
          <Text style={sv.sectionLabel}>Repayment</Text>
          <View style={sv.repayRow}>
            <Text style={sv.repayAmount}>
              {currency(data.paid_cents)} of {currency(data.principal_cents)}
            </Text>
            <Text style={sv.repayPct}>{repayPct}%</Text>
          </View>
          <View style={sv.bar}>
            <View style={[sv.barFillGreen, { width: `${repayPct}%` }]} />
          </View>

          <View style={sv.divider} />

          {/* 3 + 4. Completion progress + early bonus */}
          <View style={sv.pendingSectionHeader}>
            <Text style={[sv.sectionLabel, { marginBottom: 0 }]}>
              {data.positive_points_unlocked ? 'Score progress' : 'Pending progress'}
            </Text>
            <View style={data.positive_points_unlocked ? sv.unlockedChip : sv.lockedChip}>
              <Text style={data.positive_points_unlocked ? sv.unlockedChipText : sv.lockedChipText}>
                {data.positive_points_unlocked ? 'Unlocked' : 'Locked'}
              </Text>
            </View>
          </View>

          <Text style={sv.metricLine}>
            {data.completion_progress_points} of {data.completion_reward_max} completion points
            {!data.positive_points_unlocked ? ' progressing' : ''}
          </Text>
          <View style={sv.miniBar}>
            <View style={[sv.barFillBlue, { width: `${completionPct}%` }]} />
          </View>

          {data.early_bonus_max > 0 && (
            <View style={{ marginTop: 12 }}>
              <Text style={sv.earlyBonusLine}>
                {data.early_bonus_earned} of {data.early_bonus_max} early-payment bonus
              </Text>
              <View style={sv.miniBar}>
                <View style={[sv.barFillBlue, { width: `${earlyPct}%` }]} />
              </View>
            </View>
          )}

          {/* 5. Active penalty — shown only when > 0, before projected */}
          {data.active_penalties > 0 && (
            <>
              <View style={sv.divider} />
              <View style={sv.penaltyBlock}>
                <View>
                  <Text style={sv.penaltyLabel}>Active penalty</Text>
                  <Text style={sv.penaltyNote}>Applying to your score now</Text>
                </View>
                <Text style={sv.penaltyValue}>−{data.active_penalties}</Text>
              </View>
            </>
          )}

          <View style={sv.divider} />

          {/* 6. Projected / completion result */}
          <Text style={sv.sectionLabel}>
            {data.positive_points_unlocked ? 'Completion result' : 'Projected at completion'}
          </Text>
          <View style={sv.projectedRow}>
            <Text style={[
              sv.projectedValue,
              data.positive_points_unlocked ? { color: GREEN } : undefined,
            ]}>
              {data.projected_completed_contribution > 0 ? '+' : ''}
              {data.projected_completed_contribution}
            </Text>
            <Text style={[
              sv.projectedUnit,
              data.positive_points_unlocked ? { color: GREEN } : undefined,
            ]}>pts</Text>
          </View>
          <Text style={[
            sv.projectedNote,
            data.positive_points_unlocked ? { color: '#15803D' } : undefined,
          ]}>
            {data.positive_points_unlocked
              ? 'Applied to your IOU Score'
              : 'Pending until this IOU is completed'}
          </Text>

          {/* 7. Locked-state explanation */}
          {!data.positive_points_unlocked && (
            <Text style={sv.lockedExplanation}>
              {data.positive_points_unlock_condition || 'Positive points will apply to your IOU Score when this IOU is completed.'}
            </Text>
          )}

          {/* Technical details — collapsible */}
          <TouchableOpacity
            onPress={() => setTechOpen(o => !o)}
            style={sv.techToggle}
            activeOpacity={0.7}
          >
            <Text style={sv.techToggleText}>{techOpen ? '▾' : '▸'} Technical details</Text>
          </TouchableOpacity>

          {techOpen && (
            <View style={sv.techBox}>
              <Text style={sv.techLine}>model: {data.model_version}</Text>
              <Text style={sv.techLine}>agreement: {data.score_agreement_id}</Text>
              <Text style={sv.techLine}>
                completion pts: {data.completion_progress_points} / {data.completion_reward_max}
              </Text>
              <Text style={sv.techLine}>
                early bonus: {data.early_bonus_earned} / {data.early_bonus_max}
              </Text>
              <Text style={sv.techLine}>pending pts: +{data.pending_positive_points}</Text>
              <Text style={sv.techLine}>active penalties: −{data.active_penalties}</Text>
              <Text style={sv.techLine}>repayment: {(data.repayment_fraction * 100).toFixed(1)}%</Text>
              <Text style={sv.techLine}>
                completed: {String(data.agreement_completed)} · unlocked: {String(data.positive_points_unlocked)}
              </Text>
            </View>
          )}

        </View>
      )}
    </View>
  );
}

// ---------------------------------------------
// SCORE PROJECTION CARD
// ---------------------------------------------

const makeSp = (t: AppTheme) => StyleSheet.create({
  card: {
    marginTop: 14,
    backgroundColor: t.surface,
    borderRadius: 14,
    padding: 16,
    borderWidth: 1,
    borderColor: t.border,
    shadowColor: '#000',
    shadowOpacity: t.isDark ? 0 : 0.04,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 2 },
    elevation: t.isDark ? 0 : 1,
  },
  centerRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginVertical: 8 },
  loadingText: { color: t.textMuted, fontSize: 14, fontWeight: '500', marginTop: 8 },
  unavailTitle: { fontSize: 15, fontWeight: '800', color: t.textPrimary, marginBottom: 6 },
  unavailBody: { fontSize: 13, fontWeight: '500', color: t.textSecondary, lineHeight: 20 },
  retryBtn: {
    marginTop: 12, alignSelf: 'flex-start',
    backgroundColor: t.surfaceMuted, borderRadius: 8,
    paddingHorizontal: 14, paddingVertical: 8,
    borderWidth: 1, borderColor: t.border,
  },
  retryBtnText: { fontSize: 13, fontWeight: '700', color: t.textSecondary },
  ineligibleTitle: { fontSize: 14, fontWeight: '700', color: t.textMuted, marginBottom: 6 },
  ineligibleBody: { fontSize: 13, fontWeight: '500', color: t.textSecondary, lineHeight: 20 },
  projLabel: { fontSize: 12, fontWeight: '600', color: t.textMuted, lineHeight: 18, marginBottom: 10 },
  scoreArrow: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 4 },
  scoreFrom: { fontSize: 36, fontWeight: '900', color: t.textMuted, letterSpacing: -1 },
  scoreArrowText: { fontSize: 22, fontWeight: '700', color: t.textMuted },
  scoreTo: { fontSize: 36, fontWeight: '900', letterSpacing: -1 },
  scoreDelta: { fontSize: 16, fontWeight: '700', alignSelf: 'flex-end', paddingBottom: 4 },
  trustDelta: { fontSize: 16, fontWeight: '700', marginBottom: 12 },
  detailsSection: { marginTop: 12, borderTopWidth: 1, borderTopColor: t.divider, paddingTop: 12, gap: 8 },
  detailRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  detailLabel: { fontSize: 13, fontWeight: '500', color: t.textSecondary },
  detailValue: { fontSize: 13, fontWeight: '700' },
  completesRow: { marginTop: 4, paddingTop: 8, borderTopWidth: 1, borderTopColor: t.divider },
  completesText: { fontSize: 13, fontWeight: '700' },
  explanationSection: { marginTop: 12, borderTopWidth: 1, borderTopColor: t.divider, paddingTop: 12, gap: 4 },
  explanationLine: { fontSize: 12, fontWeight: '500', color: t.textSecondary, lineHeight: 19 },
});

function ScoreProjectionCard({
  data,
  loading,
  error,
  onRetry,
}: {
  data: IouScoreScenario | null;
  loading: boolean;
  error: string | null;
  onRetry?: () => void;
}) {
  const theme = useAppTheme();
  const sp = useMemo(() => makeSp(theme), [theme]);

  if (loading) {
    return (
      <View style={sp.card}>
        <View style={sp.centerRow}>
          <ActivityIndicator size="small" color={BLUE} />
          <Text style={sp.loadingText}>Loading estimate…</Text>
        </View>
      </View>
    );
  }

  if (!data || error) {
    return (
      <View style={sp.card}>
        <Text style={sp.unavailTitle}>Score estimate unavailable</Text>
        <Text style={sp.unavailBody}>
          Unable to load the projection for this scenario.
        </Text>
        {!!onRetry && (
          <TouchableOpacity
            style={sp.retryBtn}
            onPress={onRetry}
            accessibilityRole="button"
            accessibilityLabel="Retry score estimate"
          >
            <Text style={sp.retryBtnText}>Retry</Text>
          </TouchableOpacity>
        )}
      </View>
    );
  }

  // Backend returned eligible: false — scenario not currently available for this IOU
  if (!data.eligible) {
    return (
      <View style={sp.card}>
        <Text style={sp.ineligibleTitle}>Not available</Text>
        <Text style={sp.ineligibleBody}>
          {data.explanation[0] ?? 'This scenario is not currently eligible for this IOU.'}
        </Text>
      </View>
    );
  }

  const deltaSign = data.scoreDelta >= 0 ? '+' : '';
  const trustDeltaSign = data.visibleTrustDelta >= 0 ? '+' : '';

  return (
    <View style={sp.card}>
      <Text style={sp.projLabel}>
        Estimated after this payment is successfully confirmed
      </Text>

      {/* Score hero */}
      <View style={sp.scoreArrow}>
        <Text style={sp.scoreFrom}>{data.currentScore}</Text>
        <Text style={sp.scoreArrowText}>→</Text>
        <Text style={[sp.scoreTo, { color: data.scoreDelta >= 0 ? theme.positive : theme.negative }]}>
          {data.projectedScore}
        </Text>
        <Text style={[sp.scoreDelta, { color: data.scoreDelta >= 0 ? theme.positive : theme.negative }]}>
          ({deltaSign}{data.scoreDelta})
        </Text>
      </View>

      {/* Visible Trust delta */}
      {data.visibleTrustDelta !== 0 && (
        <Text style={[sp.trustDelta, { color: data.visibleTrustDelta >= 0 ? theme.positive : theme.negative }]}>
          Estimated {trustDeltaSign}{data.visibleTrustDelta} Visible Trust
        </Text>
      )}

      {/* Details */}
      <View style={sp.detailsSection}>
        {data.exposureReleased > 0 && (
          <View style={sp.detailRow}>
            <Text style={sp.detailLabel}>Exposure released</Text>
            <Text style={[sp.detailValue, { color: theme.positive }]}>−{data.exposureReleased} pts</Text>
          </View>
        )}
        {data.completionCreditUnlocked > 0 && (
          <View style={sp.detailRow}>
            <Text style={sp.detailLabel}>Completion credit</Text>
            <Text style={[sp.detailValue, { color: theme.positive }]}>+{data.completionCreditUnlocked} pts</Text>
          </View>
        )}
        {data.earlyBonusUnlocked > 0 && (
          <View style={sp.detailRow}>
            <Text style={sp.detailLabel}>Early-payment bonus</Text>
            <Text style={[sp.detailValue, { color: theme.positive }]}>+{data.earlyBonusUnlocked} pts</Text>
          </View>
        )}
        {data.retainedPenalty > 0 && (
          <View style={sp.detailRow}>
            <Text style={sp.detailLabel}>Penalty remains</Text>
            <Text style={[sp.detailValue, { color: theme.negative }]}>−{data.retainedPenalty} pts</Text>
          </View>
        )}
        {data.completesIou && (
          <View style={sp.completesRow}>
            <Text style={[sp.completesText, { color: theme.positive }]}>This payment completes the IOU</Text>
          </View>
        )}
      </View>

      {/* Explanation bullet lines */}
      {data.explanation.length > 0 && (
        <View style={sp.explanationSection}>
          {data.explanation.map((line, i) => (
            <Text key={i} style={sp.explanationLine}>· {line}</Text>
          ))}
        </View>
      )}
    </View>
  );
}

// Tracks which IOU ids have already shown the swipe nudge this session
const shownSwipeNudge = new Set<string>();
const shownConfirmNudge = new Set<string>();

// ---------------------------------------------
// SCREEN
// ---------------------------------------------

export default function LoanDetail({ route, navigation }: any) {
  const theme = useAppTheme();
  const s = useMemo(() => makeS(theme), [theme]);

  // -------------------------------------------
  // ROUTE PARAMS
  // -------------------------------------------

  const iouId: string | undefined =
    route?.params?.iouId ??
    route?.params?.iou_id ??
    route?.params?.loanId ??
    route?.params?.loan_id ??
    route?.params?.id;

  const routeDirection: ViewDirection | undefined =
    route?.params?.direction === 'in' || route?.params?.direction === 'out'
      ? route.params.direction
      : undefined;

  // -------------------------------------------
  // STATE
  // -------------------------------------------

  const [me, setMe] = useState<string | null>(null);
  const [iou, setIou] = useState<Iou | null>(null);
  const [rows, setRows] = useState<PaymentRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [borrowerProfile, setBorrowerProfile] = useState<BorrowerProfile>(null);

  // DEV-only — Score v2.2 progress
  const [scoreV22Data, setScoreV22Data] = useState<ScoreV22Progress | null>(null);
  const [scoreV22Loading, setScoreV22Loading] = useState(false);
  const [scoreV22Error, setScoreV22Error] = useState<string | null>(null);

  // Tab state
  const [activeTab, setActiveTab] = useState<TabId>('overview');

  // Score Impact scenario state
  const [scoreScenario, setScoreScenario] = useState<ScenarioId>('pay_next_today');
  const [scenarioData, setScenarioData] = useState<Partial<Record<ScenarioId, IouScoreScenario>>>({});
  const [scenarioLoading, setScenarioLoading] = useState(false);
  const [scenarioError, setScenarioError] = useState<string | null>(null);

  // -------------------------------------------
  // AUTH
  // -------------------------------------------

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      setMe(data.user?.id ?? null);
    });
  }, []);

  useLayoutEffect(() => {
    navigation.setOptions({
      title: iou?.title ?? 'IOU Details',
      statusBarStyle: (theme.isDark ? 'light' : 'dark') as 'light' | 'dark',
    });
  }, [iou, navigation, theme.isDark]);

  // -------------------------------------------
  // DATA FETCHING
  // -------------------------------------------

  const fetchIou = useCallback(async () => {
    if (!iouId) return;

    const { data, error } = await supabase
      .from('ious')
      .select('*')
      .eq('id', iouId)
      .single();

    if (error) throw error;

    const nextIou = data as Iou;
    setIou(nextIou);

    if (!nextIou?.borrower_id) {
      setBorrowerProfile(null);
      return;
    }

    const { data: profileData, error: profileError } = await supabase
      .from('profile_directory')
      .select('iou_score, active_exposure_points, public_name')
      .eq('id', nextIou.borrower_id)
      .single();

    if (profileError || !profileData) {
      setBorrowerProfile(null);
      return;
    }

    setBorrowerProfile({
      iou_score:
        typeof profileData.iou_score === 'number' ? profileData.iou_score : null,
      active_exposure_points:
        typeof profileData.active_exposure_points === 'number'
          ? profileData.active_exposure_points
          : null,
      public_name: (profileData as any).public_name ?? null,
    });
  }, [iouId]);

  const fetchPayments = useCallback(async () => {
    if (!iouId) return;

    const EXT = 'payment_method, extension_status, extension_requested_until, extension_requested_at';
    const selects = [
      `id, iou_id, amount_cents, status, paid_at, due_date, ${EXT}`,
      `id, iou_id, amount_cents, status, paid_at, due_at, ${EXT}`,
      `id, iou_id, amount_cents, status, paid_at, scheduled_at, ${EXT}`,
      'id, iou_id, amount_cents, status, paid_at, payment_method, due_date',
      'id, iou_id, amount_cents, status, paid_at, payment_method, due_at',
      'id, iou_id, amount_cents, status, paid_at, payment_method, scheduled_at',
    ];

    let lastErr: any = null;

    for (const sel of selects) {
      const orderCol =
        sel.includes('due_date')
          ? 'due_date'
          : sel.includes('due_at')
            ? 'due_at'
            : 'scheduled_at';

      const { data, error } = await supabase
        .from('payments')
        .select(sel)
        .eq('iou_id', iouId)
        .order(orderCol as any, { ascending: true });

      if (!error) {
        const normalized: PaymentRow[] = (data ?? []).map((p: any) => ({
          id: p.id,
          iou_id: p.iou_id,
          amount_cents: p.amount_cents,
          status: p.status,
          paid_at: p.paid_at,
          due:
            p.due_date ??
            (typeof p.due_at === 'string' ? p.due_at.slice(0, 10) : null) ??
            (typeof p.scheduled_at === 'string'
              ? p.scheduled_at.slice(0, 10)
              : null) ??
            '',
          payment_method: p.payment_method ?? null,
          extension_status: p.extension_status ?? null,
          extension_requested_until: p.extension_requested_until ?? null,
          extension_requested_at: p.extension_requested_at ?? null,
        }));

        setRows(normalized);
        return;
      }

      lastErr = error;
    }

    throw lastErr;
  }, [iouId]);

  const checkAchReady = useCallback(async (): Promise<boolean> => {
    if (!me) return false;
    try {
      const { data, error } = await supabase
        .from('profiles')
        .select('ach_status')
        .eq('id', me)
        .single();
      if (error || !data) return false;
      return (data as any).ach_status === 'ready';
    } catch {
      return false;
    }
  }, [me]);

  const fetchAll = useCallback(async () => {
    if (!iouId) return;

    setLoading(true);

    try {
      await Promise.all([fetchIou(), fetchPayments()]);
    } catch (e: any) {
      Alert.alert('Load failed', e?.message ?? String(e));
    } finally {
      setLoading(false);
    }
  }, [fetchIou, fetchPayments, iouId]);

  useFocusEffect(
    useCallback(() => {
      void fetchAll();
      // Clear scenario cache on focus — screen may have been left for a payment flow.
      setScenarioData({});
      setScenarioError(null);
    }, [fetchAll])
  );

  // DEV-only: fetch Score v2.2 progress for this IOU when the caller is the borrower.
  // get_my_iou_score_v22_progress resolves score_agreement_id server-side and
  // verifies auth.uid() is the score subject — no direct score_agreements access.
  const fetchScoreV22Progress = useCallback(async () => {
    if (!iouId) return;
    setScoreV22Loading(true);
    setScoreV22Error(null);
    try {
      const { data: rawProgress, error: rpcErr } = await supabase
        .rpc('get_my_iou_score_v22_progress', { p_iou_id: iouId });

      if (rpcErr) {
        setScoreV22Error(`Score v2.2 progress is unavailable for this IOU.`);
        return;
      }

      if (!isScoreV22Progress(rawProgress)) {
        setScoreV22Error('Score v2.2 progress is unavailable for this IOU.');
        return;
      }

      setScoreV22Data(rawProgress);
    } catch {
      setScoreV22Error('Score v2.2 progress is unavailable for this IOU.');
    } finally {
      setScoreV22Loading(false);
    }
  }, [iouId]);

  // Fetch a score scenario projection from the backend.
  // If the RPC doesn't exist yet, surfaces "Score estimate unavailable" gracefully.
  const fetchScoreScenario = useCallback(async (scenario: ScenarioId) => {
    if (!iouId) return;
    setScenarioLoading(true);
    setScenarioError(null);
    try {
      const { data: raw, error: rpcErr } = await supabase.rpc('get_my_iou_score_v22_scenario', {
        p_iou_id: iouId,
        p_scenario: scenario,
      });
      if (rpcErr) {
        setScenarioError('Score estimate unavailable');
        return;
      }
      if (!isIouScoreScenario(raw)) {
        setScenarioError('Score estimate unavailable');
        return;
      }
      setScenarioData(prev => ({ ...prev, [scenario]: raw }));
      setScenarioError(null);
    } catch {
      setScenarioError('Score estimate unavailable');
    } finally {
      setScenarioLoading(false);
    }
  }, [iouId]);

  useEffect(() => {
    if (!iouId) return;

    const ch = supabase
      .channel(`loan-${iouId}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'payments',
          filter: `iou_id=eq.${iouId}`,
        },
        () => {
          void fetchPayments();
        }
      )
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'ious',
          filter: `id=eq.${iouId}`,
        },
        () => {
          void fetchIou();
        }
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(ch);
    };
  }, [iouId, fetchIou, fetchPayments]);

  // -------------------------------------------
  // DERIVED STATE
  // -------------------------------------------

  const isArchived = !!iou?.archived_at;
  const isDeleted = !!iou?.deleted_at;
  const isLender = !!me && !!iou && me === iou.lender_id;
  const isBorrower = !!me && !!iou && me === iou.borrower_id;

  // DEV: trigger v22 fetch when IOU loads and the authenticated user is the borrower
  useEffect(() => {
    if (!__DEV__ || !isBorrower) return;
    void fetchScoreV22Progress();
  // iou?.id as dep: fires when iou first loads; stable thereafter unless IOU changes
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [iou?.id, me, fetchScoreV22Progress]);

  // Score Impact tab: fetch progress + scenario when user opens the tab
  useEffect(() => {
    if (activeTab !== 'score' || !iouId || !isBorrower) return;
    if (!scoreV22Data && !scoreV22Loading) {
      void fetchScoreV22Progress();
    }
    if (!scenarioData[scoreScenario] && !scenarioLoading) {
      void fetchScoreScenario(scoreScenario);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeTab, iouId, isBorrower]);

  // DEV: refetch on every screen focus so score data stays current after payments
  useFocusEffect(
    useCallback(() => {
      if (!__DEV__ || !isBorrower) return;
      void fetchScoreV22Progress();
    }, [isBorrower, fetchScoreV22Progress])
  );

  const isIncomingView = routeDirection
    ? routeDirection === 'in'
    : isLender && !isBorrower;

  const isOutgoingView = routeDirection
    ? routeDirection === 'out'
    : isBorrower;

  const paidTotal = useMemo(
    () =>
      rows
        .filter((r) => !!r.paid_at)
        .reduce((sum, r) => sum + r.amount_cents, 0),
    [rows]
  );

  const scheduledTotal = useMemo(
    () => rows.reduce((sum, r) => sum + r.amount_cents, 0),
    [rows]
  );

  const remainingTotal = Math.max(0, scheduledTotal - paidTotal);

  const totalInstallments = useMemo(() => {
    const dbTotal =
      typeof iou?.total_installments === 'number' && iou.total_installments > 0
        ? iou.total_installments
        : 0;

    return Math.max(dbTotal, rows.length);
  }, [iou, rows.length]);

  const paidInstallments = useMemo(() => {
    return rows.filter((r) => !!r.paid_at).length;
  }, [rows]);

  const progressPercent = useMemo(() => {
    if (!totalInstallments) return 0;
    return Math.round((paidInstallments / totalInstallments) * 100);
  }, [paidInstallments, totalInstallments]);

  const paymentsRemaining = useMemo(() => {
    return Math.max(
      0,
      Math.max(totalInstallments, rows.length) - paidInstallments
    );
  }, [paidInstallments, rows.length, totalInstallments]);

  // Payment sections for the Payments tab SectionList
  const paymentSectionData = useMemo((): PaymentSectionData[] => {
    const unpaid = rows.filter(r => !r.paid_at && r.status !== 'pending_confirmation' && r.status !== 'processing');
    const pending = rows.filter(r => !r.paid_at && (r.status === 'pending_confirmation' || r.status === 'processing'));
    const paid = rows.filter(r => !!r.paid_at);
    const sections: PaymentSectionData[] = [];
    if (unpaid.length > 0) {
      const firstLabel = unpaid[0].status === 'late' ? 'Overdue' : 'Next';
      sections.push({ title: firstLabel, data: [unpaid[0]] });
      if (unpaid.length > 1) sections.push({ title: 'Upcoming', data: unpaid.slice(1) });
    }
    if (pending.length > 0) sections.push({ title: 'Pending', data: pending });
    if (paid.length > 0) sections.push({ title: 'Completed', data: paid });
    return sections;
  }, [rows]);

  const pendingCount = useMemo(
    () =>
      isOutgoingView
        ? rows.filter((r) => !r.paid_at && r.status === 'pending_confirmation').length
        : 0,
    [rows, isOutgoingView]
  );

  // Only manual payments (payment_method = 'manual' or null) require lender confirmation.
  // ACH payments never enter pending_confirmation — they use 'processing' status.
  const incomingPendingCount = useMemo(
    () =>
      isIncomingView
        ? rows.filter(
            (r) =>
              !r.paid_at &&
              r.status === 'pending_confirmation' &&
              (r.payment_method === 'manual' || !r.payment_method)
          ).length
        : 0,
    [rows, isIncomingView]
  );

  const nextDue = useMemo(
    () => rows.find((r) => !r.paid_at && r.status !== 'pending_confirmation') ?? null,
    [rows]
  );

  const firstUnpaidIndex = useMemo(
    () => rows.findIndex((r) => !r.paid_at && (r.status === 'scheduled' || r.status === 'late')),
    [rows]
  );

  const firstConfirmIndex = useMemo(
    () => rows.findIndex((r) => !r.paid_at && r.status === 'pending_confirmation'),
    [rows]
  );

  const completionRewardText = useMemo(() => {
    if (paymentsRemaining === 0) {
      return 'IOU complete. Completion is reflected in your trust history.';
    }

    if (paymentsRemaining === 1) {
      return 'One payment left. Completion will finalize this IOU\'s score contribution.';
    }

    return `${paymentsRemaining} payments remaining. Completing this IOU will finalize its score contribution.`;
  }, [paymentsRemaining]);

  const repaymentStreakValue = useMemo(() => {
    return null;
  }, []);

  const borrowerTrustLabel = useMemo(() => {
    if (typeof borrowerProfile?.iou_score !== 'number') return 'No score yet';
    if (borrowerProfile.iou_score >= 1000) return 'Strong';
    if (borrowerProfile.iou_score >= 850) return 'Rising';
    if (borrowerProfile.iou_score >= 700) return 'Starter';
    return 'Watch';
  }, [borrowerProfile]);

  const repaymentStreakText = useMemo(() => {
    if (repaymentStreakValue === null) {
      return 'Repayment streak not live yet.';
    }

    if (repaymentStreakValue === 0) {
      return 'No active on-time streak right now.';
    }

    if (repaymentStreakValue === 1) {
      return '1 on-time payment in a row.';
    }

    return `${repaymentStreakValue} on-time payments in a row.`;
  }, [repaymentStreakValue]);

  // -------------------------------------------
  // REWARD PREVIEW HELPERS
  // -------------------------------------------

  const getTimingType = useCallback((due: string) => {
    const parsed = new Date(due);
    if (Number.isNaN(parsed.getTime())) return 'unknown';

    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const dueDate = new Date(
      parsed.getFullYear(),
      parsed.getMonth(),
      parsed.getDate()
    );

    if (today.getTime() < dueDate.getTime()) return 'early';
    if (today.getTime() === dueDate.getTime()) return 'on_time';
    return 'late';
  }, []);

  const getRewardPreviewText = useCallback(
    (item: PaymentRow, index: number) => {
      if (item.paid_at) return null;
      if (!isOutgoingView) return null;
      if (!(item.status === 'scheduled' || item.status === 'late')) return null;

      const timing = getTimingType(item.due);
      const isFinal =
        index + 1 >= Math.max(totalInstallments, rows.length) &&
        Math.max(totalInstallments, rows.length) > 0;

      if (timing === 'early') {
        return 'Paying early may strengthen your IOU Score.';
      }

      if (timing === 'on_time') {
        return 'On-time payment contributes toward completion progress.';
      }

      if (timing === 'late') {
        if (isFinal) {
          return 'Late payment — completion still reflected in your trust history.';
        }
        return 'Late payment — no timing bonus.';
      }

      if (isFinal) {
        return 'Final payment — completion will reflect in your trust history.';
      }

      return null;
    },
    [getTimingType, isOutgoingView, rows.length, totalInstallments]
  );

  // -------------------------------------------
  // NAVIGATION / ACTIONS
  // -------------------------------------------

  const navigateToPersonProfile = useCallback(() => {
    if (!iou?.borrower_id) {
      Alert.alert(
        'Missing borrower',
        'This loan does not have a borrower profile linked yet.'
      );
      return;
    }

    const state = navigation?.getState?.();
    const routeNames: string[] = Array.isArray(state?.routeNames)
      ? state.routeNames
      : [];

    if (routeNames.includes('Person')) {
      navigation.navigate('Person', {
        personId: iou.borrower_id,
      });
      return;
    }

    Alert.alert(
      'Profile unavailable',
      'The borrower profile screen is not registered in this navigator yet.'
    );
  }, [iou?.borrower_id, navigation]);

  const goToAchPayScreen = (item: PaymentRow) => {
    navigation.navigate('AchPayment', {
      paymentId: item.id,
      amount: item.amount_cents,
      due: item.due,
      iouId,
      iou_id: iouId,
    });
  };

  const goToManualPayScreen = (item: PaymentRow) => {
    navigation.navigate('ConfirmPayment', {
      paymentId: item.id,
      amount: item.amount_cents,
      iouId,
      iou_id: iouId,
      loanId: iouId,
      loan_id: iouId,
    });
  };

  const openFullLoan = () => {
    if (!iouId) {
      Alert.alert('Missing loan', 'This loan is missing its contract reference.');
      return;
    }

    navigation.navigate('PreviewSign', {
      id: iouId,
    });
  };

  const confirmIncomingPayment = async (item: PaymentRow) => {
    const ready = await checkAchReady();
    if (!ready) {
      Alert.alert(
        'Bank connection required',
        'Your bank connection is not ready for payments yet. Please complete bank setup.',
        [{ text: 'OK' }]
      );
      return;
    }
    try {
      const { data, error } = await supabase.rpc('pay_and_receipt', {
        p_payment_id: item.id,
      });

      if (error) throw error;

      let hashPreview = '';
      if (Array.isArray(data) && data[0]?.hash_hex) {
        hashPreview = data[0].hash_hex;
      } else if ((data as any)?.hash_hex) {
        hashPreview = (data as any).hash_hex;
      }

      await Promise.all([fetchIou(), fetchPayments()]);
      setScenarioData({});
      setScenarioError(null);

      Alert.alert(
        'Payment confirmed',
        hashPreview
          ? `Receipt: ${hashPreview.slice(0, 12)}…`
          : 'Payment confirmed successfully.',
        [
          {
            text: 'View receipt',
            onPress: () =>
              navigation.navigate('Receipt', {
                paymentId: item.id,
                iouId,
                iou_id: iouId,
                loanId: iouId,
                loan_id: iouId,
              }),
          },
          { text: 'OK' },
        ]
      );
    } catch (e: any) {
      Alert.alert('Confirm failed', e?.message ?? 'Could not confirm payment.');
    }
  };

  const sendReminder = async (item: PaymentRow) => {
    try {
      const title = iou?.title || 'Loan';
      const amount = currency(item.amount_cents);

      await Share.share({
        message: `Reminder: ${title} payment of ${amount} is due ${item.due} in IOU.`,
      });
    } catch (e: any) {
      Alert.alert('Reminder failed', e?.message ?? 'Could not open share sheet.');
    }
  };

  const onRefresh = async () => {
    setRefreshing(true);
    setScenarioData({});
    setScenarioError(null);
    try {
      await Promise.all([fetchIou(), fetchPayments()]);
    } finally {
      setRefreshing(false);
    }
  };

  const openPaidReceipt = (item: PaymentRow) => {
    navigation.navigate('Receipt', {
      paymentId: item.id,
      iouId,
      iou_id: iouId,
      loanId: iouId,
      loan_id: iouId,
    });
  };

  const rejectManualPayment = async (item: PaymentRow) => {
    const ready = await checkAchReady();
    if (!ready) {
      Alert.alert(
        'Bank connection required',
        'Your bank connection is not ready for payments yet. Please complete bank setup.',
        [{ text: 'OK' }]
      );
      return;
    }
    try {
      const { error } = await supabase.rpc('reject_payment', { p_payment_id: item.id });
      if (error) throw error;
      await fetchPayments();
      Alert.alert('Payment rejected', 'The payment has been returned to scheduled status.');
    } catch (e: any) {
      Alert.alert('Reject failed', e?.message ?? 'Could not reject payment.');
    }
  };

  // TODO: Remove dev-only payment confirm before production release.
  const devConfirmPayment = __DEV__
    ? async (item: PaymentRow) => {
        Alert.alert(
          'Dev: Confirm Payment',
          `Sandbox only — bypasses ACH check.\n\n${currency(item.amount_cents)} due ${item.due}\n\npayment_id: ${item.id}`,
          [
            { text: 'Cancel', style: 'cancel' },
            {
              text: 'Confirm (dev)',
              onPress: async () => {
                try {
                  const { error } = await supabase.rpc('pay_and_receipt', {
                    p_payment_id: item.id,
                  });
                  if (error) throw error;
                  await Promise.all([fetchIou(), fetchPayments()]);
                  setScenarioData({});
                  setScenarioError(null);
                  Alert.alert('Dev: Confirmed', `payment_id: ${item.id}\n\nNow run Dev: Log Payment Outcome with this id — expect reason=payment_outcome_already_logged`);
                } catch (e: any) {
                  Alert.alert('Dev: Confirm failed', e?.message ?? String(e));
                }
              },
            },
          ]
        );
      }
    : undefined;

  const openIncomingPending = (item: PaymentRow) => {
    Alert.alert(
      'Manual payment received?',
      `The borrower manually submitted ${currency(item.amount_cents)} outside AutoPay.\n\nConfirm once you've received it, or reject if you did not.`,
      [
        { text: 'Close', style: 'cancel' },
        {
          text: 'Reject',
          style: 'destructive',
          onPress: () => { void rejectManualPayment(item); },
        },
        {
          text: 'Confirm received',
          onPress: () => { void confirmIncomingPayment(item); },
        },
      ]
    );
  };

  const openIncomingScheduled = (item: PaymentRow) => {
    Alert.alert(
      'Incoming payment',
      `${currency(item.amount_cents)} due ${item.due}`,
      [
        { text: 'Close', style: 'cancel' },
        {
          text: 'Remind borrower',
          onPress: () => {
            void sendReminder(item);
          },
        },
      ]
    );
  };

  const openOutgoingPending = () => {
    Alert.alert(
      'Manual payment submitted',
      'Your manual payment is waiting for lender confirmation. AutoPay handles regular scheduled payments automatically.'
    );
  };

  const approveExtension = async (item: PaymentRow) => {
    if (!me) return;
    try {
      const { error } = await supabase
        .from('payments')
        .update({
          extension_status: 'approved',
          extension_decision_at: new Date().toISOString(),
          extension_decided_by: me,
        })
        .eq('id', item.id);
      if (error) throw error;
      await fetchPayments();
    } catch (e: any) {
      Alert.alert('Approve failed', e.message ?? String(e));
    }
  };

  const denyExtension = (item: PaymentRow) => {
    Alert.alert('Deny extension?', 'The borrower will be notified that the extension was denied.', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Deny',
        style: 'destructive',
        onPress: async () => {
          if (!me) return;
          try {
            const { error } = await supabase
              .from('payments')
              .update({
                extension_status: 'denied',
                extension_decision_at: new Date().toISOString(),
                extension_decided_by: me,
              })
              .eq('id', item.id);
            if (error) throw error;
            await fetchPayments();
          } catch (e: any) {
            Alert.alert('Deny failed', e.message ?? String(e));
          }
        },
      },
    ]);
  };

  // Shared payment eligibility — single source of truth used by both the
  // next-payment card CTA and individual installment row canPay.
  const isPayEligible = (item: PaymentRow): boolean =>
    isOutgoingView &&
    !isArchived &&
    !isDeleted &&
    !item.paid_at &&
    (item.status === 'scheduled' || item.status === 'late');

  // Whether paying the next due payment would complete the IOU
  const nextPaymentCompletesIou =
    paymentsRemaining === 1 &&
    !!nextDue &&
    isOutgoingView && !isArchived && !isDeleted && !nextDue.paid_at &&
    (nextDue.status === 'scheduled' || nextDue.status === 'late');

  const scoreImpactLinkLabel = nextPaymentCompletesIou
    ? 'See estimated payoff impact →'
    : 'See estimated score impact →';

  // Switch to Score Impact tab and select the relevant scenario.
  // The score link is only shown to the borrower, so isBorrower is always true here,
  // but guard defensively so the RPC is never called for a lender.
  const handleScoreImpactLink = useCallback(() => {
    const scenario: ScenarioId = nextPaymentCompletesIou ? 'payoff_today' : 'pay_next_today';
    setScoreScenario(scenario);
    setActiveTab('score');
    if (isBorrower && !scenarioData[scenario] && !scenarioLoading) {
      void fetchScoreScenario(scenario);
    }
  }, [nextPaymentCompletesIou, isBorrower, scenarioData, scenarioLoading, fetchScoreScenario]);

  // Change the selected scenario and fetch if not cached
  const handleScenarioChange = useCallback((scenario: ScenarioId) => {
    setScoreScenario(scenario);
    if (isBorrower && !scenarioData[scenario] && !scenarioLoading) {
      void fetchScoreScenario(scenario);
    }
  }, [isBorrower, scenarioData, scenarioLoading, fetchScoreScenario]);

  // Switch tab and trigger scenario fetch when opening Score Impact tab directly
  const handleTabChange = useCallback((tab: TabId) => {
    setActiveTab(tab);
    if (tab === 'score' && isBorrower && !scenarioData[scoreScenario] && !scenarioLoading) {
      void fetchScoreScenario(scoreScenario);
    }
  }, [scoreScenario, isBorrower, scenarioData, scenarioLoading, fetchScoreScenario]);

  // -------------------------------------------
  // SMALL UI COMPONENTS
  // -------------------------------------------

  const StatusPill = ({ value }: { value: string }) => {
    const d = theme.isDark;
    const config =
      value === 'paid'
        ? { bg: d ? '#051A0A' : '#DCFCE7', border: d ? '#0D3A15' : '#BBF7D0', text: d ? '#66BB6A' : '#15803D', label: 'Paid' }
        : value === 'pending_confirmation'
          ? { bg: d ? '#050A1A' : '#EFF6FF', border: d ? '#0D1540' : '#BFDBFE', text: d ? '#60A5FA' : '#1D4ED8', label: 'Pending' }
          : value === 'processing'
            ? { bg: d ? '#050A1A' : '#EFF6FF', border: d ? '#0D1540' : '#BFDBFE', text: d ? '#60A5FA' : '#1565C0', label: 'Processing' }
            : value === 'late'
              ? { bg: d ? '#1A0505' : '#FEF2F2', border: d ? '#3A0D0D' : '#FECACA', text: d ? '#FF6B6B' : '#991B1B', label: 'Overdue' }
              : value === 'scheduled'
                ? { bg: d ? '#111111' : '#F3F4F6', border: d ? '#262626' : '#E5E7EB', text: d ? '#9CA3AF' : '#374151', label: 'Autopay' }
                : {
                    bg: d ? '#111111' : '#F3F4F6',
                    border: d ? '#262626' : '#E5E7EB',
                    text: d ? '#9CA3AF' : '#374151',
                    label: value.charAt(0).toUpperCase() + value.slice(1).replace(/_/g, ' '),
                  };

    return (
      <View style={[s.pill, { backgroundColor: config.bg, borderColor: config.border, borderWidth: 1 }]}>
        <Text style={[s.pillTxt, { color: config.text }]}>{config.label}</Text>
      </View>
    );
  };

  const PaymentRowView = ({
    item,
    index,
    isFirstUnpaid,
    isFirstConfirm,
  }: {
    item: PaymentRow;
    index: number;
    isFirstUnpaid?: boolean;
    isFirstConfirm?: boolean;
  }) => {
    const nudgeAnim = useRef(new Animated.Value(0)).current;
    const confirmNudge = useRef(new Animated.Value(0)).current;

    const canPay = isPayEligible(item);

    useEffect(() => {
      if (!isFirstUnpaid || !canPay) return;
      if (!iouId || shownSwipeNudge.has(iouId)) return;
      shownSwipeNudge.add(iouId);
      const t = setTimeout(() => {
        Animated.sequence([
          Animated.timing(nudgeAnim, { toValue: -42, duration: 280, useNativeDriver: true }),
          Animated.delay(130),
          Animated.timing(nudgeAnim, { toValue: -14, duration: 200, useNativeDriver: true }),
          Animated.timing(nudgeAnim, { toValue: -28, duration: 130, useNativeDriver: true }),
          Animated.timing(nudgeAnim, { toValue: 0, duration: 220, useNativeDriver: true }),
        ]).start();
      }, 800);
      return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    useEffect(() => {
      if (!isFirstConfirm) return;
      const confirmKey = `${iouId}_confirm`;
      if (!iouId || shownConfirmNudge.has(confirmKey)) return;
      shownConfirmNudge.add(confirmKey);
      const t = setTimeout(() => {
        Animated.sequence([
          Animated.timing(confirmNudge, { toValue: -42, duration: 280, useNativeDriver: true }),
          Animated.delay(130),
          Animated.timing(confirmNudge, { toValue: -14, duration: 200, useNativeDriver: true }),
          Animated.timing(confirmNudge, { toValue: -28, duration: 130, useNativeDriver: true }),
          Animated.timing(confirmNudge, { toValue: 0, duration: 220, useNativeDriver: true }),
        ]).start();
      }, 800);
      return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    const canRemind =
      isIncomingView &&
      !isArchived &&
      !isDeleted &&
      !item.paid_at &&
      item.status !== 'pending_confirmation';

    // Lender may confirm only manually-submitted payments.
    // ACH payments (payment_method = 'ach') are confirmed by the processor, not the lender.
    const canConfirm =
      isIncomingView &&
      !isArchived &&
      !isDeleted &&
      !item.paid_at &&
      item.status === 'pending_confirmation' &&
      (item.payment_method === 'manual' || !item.payment_method);

    const rewardPreviewText = getRewardPreviewText(item, index);

    const canRequestExtension =
      isOutgoingView &&
      !isArchived &&
      !isDeleted &&
      !item.paid_at &&
      (item.status === 'scheduled' || item.status === 'late') &&
      item.extension_status !== 'requested';

    const leftActions = () => {
      if (!canRequestExtension) return <View />;
      return (
        <RectButton
          style={s.leftActionExtension}
          onPress={() =>
            navigation.navigate('RequestExtension', {
              paymentId: item.id,
              iouId: iouId!,
              scheduledAt: item.due,
              paymentAmount: item.amount_cents,
              title: iou?.title,
            })
          }
        >
          <Text style={s.leftActionText}>Extension</Text>
        </RectButton>
      );
    };

    const rightActions = () => {
      if (canPay) {
        return (
          <RectButton
            style={s.rightActionPay}
            onPress={() => goToAchPayScreen(item)}
          >
            <Text style={s.rightActionText}>Pay now</Text>
          </RectButton>
        );
      }

      if (canRemind) {
        return (
          <RectButton
            style={s.rightActionRemind}
            onPress={() => void sendReminder(item)}
          >
            <Text style={s.rightActionText}>Remind</Text>
          </RectButton>
        );
      }

      if (canConfirm) {
        return (
          <RectButton
            style={s.rightActionConfirm}
            onPress={() => void confirmIncomingPayment(item)}
          >
            <Text style={s.rightActionText}>Confirm</Text>
          </RectButton>
        );
      }

      return <View />;
    };

    return (
      <Animated.View
        style={
          isFirstUnpaid && canPay
            ? { transform: [{ translateX: nudgeAnim }] }
            : isFirstConfirm
              ? { transform: [{ translateX: confirmNudge }] }
              : undefined
        }
      >
        <Swipeable
          renderLeftActions={leftActions}
          renderRightActions={rightActions}
          overshootLeft={false}
          overshootRight={false}
        >
        <TouchableOpacity
          activeOpacity={item.paid_at ? 0.85 : 0.9}
          onPress={() => {
            if (item.paid_at) {
              openPaidReceipt(item);
              return;
            }

            if (
              isIncomingView &&
              item.status === 'pending_confirmation' &&
              (item.payment_method === 'manual' || !item.payment_method)
            ) {
              openIncomingPending(item);
              return;
            }

            if (isIncomingView && !item.paid_at) {
              openIncomingScheduled(item);
              return;
            }

            if (isOutgoingView && item.status === 'pending_confirmation') {
              openOutgoingPending();
              return;
            }

            if (isOutgoingView && canPay) {
              goToAchPayScreen(item);
            }
          }}
        >
          <View style={[s.payRow, item.paid_at ? s.payRowDone : undefined]}>
            {/* Installment label + status pill */}
            <View style={s.rowTop}>
              <Text style={s.paymentIndexText}>
                Installment {index + 1} of {Math.max(totalInstallments, rows.length)}
              </Text>
              <StatusPill value={item.paid_at ? 'paid' : item.status || 'scheduled'} />
            </View>

            {/* Amount */}
            <Text style={[s.amountText, item.paid_at ? s.amountTextDone : undefined]}>
              {currency(item.amount_cents)}
            </Text>

            {/* Due date — human readable */}
            <Text style={s.dueText}>Due {formatDate(item.due)}</Text>

            {/* Paid date */}
            {!!item.paid_at && (
              <Text style={s.paidDateText}>
                Paid {new Date(item.paid_at).toLocaleDateString(undefined, { month: 'long', day: 'numeric', year: 'numeric' })}
              </Text>
            )}

            {/* Extension status for borrower */}
            {isOutgoingView && item.extension_status === 'requested' && (
              <View style={s.extensionStatusPill}>
                <Text style={s.extensionStatusText}>Extension pending lender approval</Text>
              </View>
            )}
            {isOutgoingView && item.extension_status === 'approved' && !!item.extension_requested_until && (
              <View style={[s.extensionStatusPill, s.extensionApprovedPill]}>
                <Text style={[s.extensionStatusText, { color: theme.isDark ? theme.brandBright : '#1B5E20' }]}>
                  Extended to {parseDateLocal(item.extension_requested_until).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}
                </Text>
              </View>
            )}
            {isOutgoingView && item.extension_status === 'denied' && (
              <View style={[s.extensionStatusPill, s.extensionDeniedPill]}>
                <Text style={[s.extensionStatusText, { color: theme.isDark ? theme.negative : '#B42318' }]}>Extension denied — original due date applies</Text>
              </View>
            )}

            {/* Lender: approve or deny an incoming extension request */}
            {isIncomingView && item.extension_status === 'requested' && !!item.extension_requested_until && (
              <View style={s.extensionRequestCard}>
                <Text style={s.extensionRequestLabel}>Extension requested</Text>
                <Text style={s.extensionRequestDate}>
                  Borrower requests until{' '}
                  {parseDateLocal(item.extension_requested_until).toLocaleDateString(undefined, { month: 'long', day: 'numeric' })}
                </Text>
                <View style={s.extensionActions}>
                  <TouchableOpacity style={s.extensionApproveBtn} onPress={() => approveExtension(item)}>
                    <Text style={s.extensionApproveTxt}>Approve</Text>
                  </TouchableOpacity>
                  <TouchableOpacity style={s.extensionDenyBtn} onPress={() => denyExtension(item)}>
                    <Text style={s.extensionDenyTxt}>Deny</Text>
                  </TouchableOpacity>
                </View>
              </View>
            )}

            {/* State notes */}
            {isOutgoingView && item.status === 'processing' && !item.paid_at && (
              <Text style={s.processingNote}>ACH payment in progress</Text>
            )}
            {isOutgoingView && item.status === 'pending_confirmation' && !item.paid_at && (
              <Text style={s.pendingConfirmNote}>Manual payment submitted · Waiting for lender</Text>
            )}

            {__DEV__ && !item.paid_at && item.status === 'pending_confirmation' && !!devConfirmPayment && (
              <TouchableOpacity style={s.devConfirmBtn} onPress={() => void devConfirmPayment(item)} activeOpacity={0.8}>
                <Text style={s.devConfirmBtnText}>Dev: Confirm Payment</Text>
              </TouchableOpacity>
            )}

            {/* Reward context */}
            {!!rewardPreviewText && (
              <Text style={s.rewardPreviewText}>{rewardPreviewText}</Text>
            )}

            {/* Primary actions — outgoing unpaid */}
            {!item.paid_at && canPay && (
              <View style={s.actionArea}>
                <TouchableOpacity style={s.btnPrimary} onPress={() => goToAchPayScreen(item)} activeOpacity={0.85}>
                  <Text style={s.btnPrimaryText}>{item.status === 'late' ? 'Pay now' : 'Pay early'}</Text>
                </TouchableOpacity>
                {canRequestExtension && (
                  <TouchableOpacity
                    style={s.btnSecondary}
                    onPress={() =>
                      navigation.navigate('RequestExtension', {
                        paymentId: item.id,
                        iouId: iouId!,
                        scheduledAt: item.due,
                        paymentAmount: item.amount_cents,
                        title: iou?.title,
                      })
                    }
                  >
                    <Text style={s.btnSecondaryText}>Request extension</Text>
                  </TouchableOpacity>
                )}
                <TouchableOpacity style={s.btnTextOnly} onPress={() => goToManualPayScreen(item)}>
                  <Text style={s.btnTextOnlyLabel}>Record manual payment</Text>
                </TouchableOpacity>
              </View>
            )}

            {/* Autopay note — informational, after actions */}
            {isOutgoingView && item.status === 'scheduled' && !item.paid_at && (
              <Text style={s.autopayNote}>Autopay withdraws on the due date</Text>
            )}

            {/* Lender swipe hints */}
            {!item.paid_at && canRemind && (
              <Text style={s.swipeGuide}>Swipe left to send a reminder</Text>
            )}
            {!item.paid_at && canConfirm && (
              <Text style={[s.swipeGuide, isFirstConfirm ? s.swipeGuideProminentBlue : { color: BLUE }]}>
                Swipe left to confirm or reject
              </Text>
            )}

            {/* Paid: receipt tap hint */}
            {!!item.paid_at && (
              <Text style={s.receiptHint}>Tap to view receipt</Text>
            )}
          </View>
        </TouchableOpacity>
        </Swipeable>
      </Animated.View>
    );
  };

  // -------------------------------------------
  // LOADING / EMPTY STATES
  // -------------------------------------------

  if (!iouId) {
    return (
      <View style={s.center}>
        <Text style={{ color: theme.textSecondary }}>Missing loan id.</Text>
      </View>
    );
  }

  if (loading) {
    return (
      <View style={s.center}>
        <ActivityIndicator color={theme.brand} />
      </View>
    );
  }

  if (!iou) {
    return (
      <View style={s.center}>
        <Text style={{ color: theme.textSecondary }}>Loan not found.</Text>
      </View>
    );
  }

  // -------------------------------------------
  // INNER LAYOUT COMPONENTS
  // -------------------------------------------

  const isComplete = iou.status === 'paid' || paymentsRemaining === 0;
  const totalPayments = Math.max(totalInstallments, rows.length);

  // Compact summary strip above the tabs
  const TopSummary = () => (
    <View style={s.topSummary}>
      <View style={s.topRow1}>
        <View style={[s.topDirChip, isIncomingView ? s.topDirChipIn : s.topDirChipOut]}>
          <Text style={s.topDirChipText}>{isIncomingView ? "You're owed" : 'You owe'}</Text>
        </View>
        {isIncomingView && !!borrowerProfile?.public_name && (
          <Text style={s.topPartyName} numberOfLines={1}>
            {borrowerProfile.public_name}
          </Text>
        )}
        {isComplete && (
          <View style={s.topCompleteChip}>
            <Text style={s.topCompleteChipText}>Completed</Text>
          </View>
        )}
      </View>

      <View style={s.topAmountRow}>
        <Text style={s.topAmount}>{currency(remainingTotal)}</Text>
        <Text style={s.topAmountOf}>of {currency(scheduledTotal)}</Text>
      </View>

      <View style={s.topProgressRow}>
        <View style={s.topProgressTrack}>
          <View style={[s.topProgressFill, { width: `${progressPercent}%` as any }]} />
        </View>
        <Text style={s.topProgressPct}>{progressPercent}%</Text>
        <Text style={s.topInstallments}>{paidInstallments}/{totalPayments}</Text>
      </View>

      {!!nextDue && !isComplete && (
        <Text style={[
          s.topNextDue,
          nextDue.status === 'late' && { color: theme.negative },
        ]}>
          {nextDue.status === 'late' ? 'Overdue · ' : 'Next due '}
          {formatDate(nextDue.due)}
        </Text>
      )}
    </View>
  );

  // Segmented tab bar
  const TabBar = () => (
    <View style={s.tabBar} accessibilityRole="tablist">
      {([
        { id: 'overview' as TabId, label: 'Overview' },
        { id: 'payments' as TabId, label: 'Payments' },
        { id: 'score' as TabId, label: 'Score Impact' },
      ]).map(({ id, label }) => (
        <TouchableOpacity
          key={id}
          style={[s.tabItem, activeTab === id && s.tabItemActive]}
          onPress={() => handleTabChange(id)}
          accessibilityRole="tab"
          accessibilityState={{ selected: activeTab === id }}
          accessibilityLabel={label}
        >
          <Text style={[s.tabLabel, activeTab === id && s.tabLabelActive]}>
            {label}
          </Text>
          {activeTab === id && <View style={s.tabIndicator} />}
        </TouchableOpacity>
      ))}
    </View>
  );

  // Tab 1 — Overview
  const OverviewTab = () => {
    const freqLabel =
      iou.frequency === 'weekly' ? 'Weekly' :
      iou.frequency === 'biweekly' ? 'Biweekly' : 'Monthly';
    const aprLabel = iou.apr_bps != null ? `${(iou.apr_bps / 100).toFixed(2)}%` : 'N/A';

    return (
      <ScrollView
        contentContainerStyle={s.tabContent}
        showsVerticalScrollIndicator={false}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
      >
        {/* Pending confirmation banner (lender) */}
        {isIncomingView && incomingPendingCount > 0 && (
          <View style={s.pendingConfirmCard}>
            <Text style={s.pendingConfirmTitle}>Manual payment received?</Text>
            <Text style={s.pendingConfirmBody}>
              {incomingPendingCount === 1
                ? 'The borrower manually submitted 1 payment outside AutoPay. Go to Payments to confirm or reject.'
                : `The borrower manually submitted ${incomingPendingCount} payments outside AutoPay. Go to Payments to confirm each.`}
            </Text>
            <TouchableOpacity
              style={s.pendingConfirmCta}
              onPress={() => handleTabChange('payments')}
            >
              <Text style={s.pendingConfirmCtaText}>Go to Payments →</Text>
            </TouchableOpacity>
          </View>
        )}

        {/* Next / overdue payment info card */}
        {!!nextDue && !isComplete && (
          <View style={[
            s.nextPayCard,
            nextDue.status === 'late' && { borderColor: theme.negativeBorder },
          ]}>
            <Text style={[
              s.nextPayLabel,
              nextDue.status === 'late' && { color: theme.negative },
            ]}>
              {nextDue.status === 'late' ? 'Overdue payment' : 'Next payment'}
            </Text>
            <Text style={[
              s.nextPayAmt,
              nextDue.status === 'late' && { color: theme.negative },
            ]}>
              {currency(nextDue.amount_cents)}
            </Text>
            <Text style={s.nextPayDate}>Due {formatDate(nextDue.due)}</Text>

            {isOutgoingView && nextDue.status === 'scheduled' && (
              <Text style={s.nextPayMethod}>Autopay withdraws on the due date</Text>
            )}
            {isOutgoingView && nextDue.status === 'late' && (
              <Text style={[s.nextPayMethod, { color: theme.negative }]}>
                Payment was not collected — pay now to resolve
              </Text>
            )}
            {isOutgoingView && nextDue.status === 'processing' && (
              <Text style={[s.nextPayMethod, { color: BLUE }]}>ACH payment in progress</Text>
            )}
            {isOutgoingView && nextDue.status === 'pending_confirmation' && (
              <Text style={[s.nextPayMethod, { color: BLUE }]}>
                Manual payment submitted · Waiting for lender
              </Text>
            )}

            {/* Score impact link — borrower only, when payment is eligible */}
            {isOutgoingView && isPayEligible(nextDue) && (
              <TouchableOpacity
                style={s.scoreImpactLink}
                onPress={handleScoreImpactLink}
                accessibilityRole="button"
                accessibilityLabel={scoreImpactLinkLabel}
              >
                <Text style={s.scoreImpactLinkText}>{scoreImpactLinkLabel}</Text>
              </TouchableOpacity>
            )}
          </View>
        )}

        {/* Completion card */}
        {isComplete && (
          <View style={[s.nextPayCard, { borderColor: theme.positiveBorder }]}>
            <Text style={[s.nextPayLabel, { color: theme.positive }]}>IOU Complete</Text>
            <Text style={s.nextPayAmt}>{currency(scheduledTotal)}</Text>
            <Text style={s.nextPayDate}>
              All {totalPayments} payment{totalPayments !== 1 ? 's' : ''} made
            </Text>
            <Text style={[s.nextPayMethod, { marginTop: 8 }]}>
              Completion is reflected in your trust history.
            </Text>
          </View>
        )}

        {/* Compact agreement grid */}
        <View style={s.agreementCard}>
          <View style={s.agreementHeader}>
            <Text style={s.agreementTitle}>Agreement</Text>
            <TouchableOpacity onPress={openFullLoan} activeOpacity={0.8}>
              <Text style={s.contractLinkText}>View contract</Text>
            </TouchableOpacity>
          </View>
          <View style={s.agreementGrid}>
            <View style={s.agreementItem}>
              <Text style={s.agreementLabel}>Frequency</Text>
              <Text style={s.agreementValue}>{freqLabel}</Text>
            </View>
            <View style={s.agreementItem}>
              <Text style={s.agreementLabel}>Term</Text>
              <Text style={s.agreementValue}>{iou.term_months} mo</Text>
            </View>
            <View style={s.agreementItem}>
              <Text style={s.agreementLabel}>APR</Text>
              <Text style={s.agreementValue}>{aprLabel}</Text>
            </View>
            <View style={s.agreementItem}>
              <Text style={s.agreementLabel}>Progress</Text>
              <Text style={s.agreementValue}>{paidInstallments}/{totalPayments}</Text>
            </View>
          </View>
        </View>

        {/* Borrower card (lender view) */}
        {isIncomingView && !!borrowerProfile && (
          <TouchableOpacity
            style={s.borrowerCard}
            onPress={navigateToPersonProfile}
            activeOpacity={0.92}
          >
            <View style={s.borrowerCardHeader}>
              <Text style={s.borrowerCardTitle}>Borrower</Text>
              <Text style={s.borrowerCardLink}>View profile →</Text>
            </View>
            <Text style={s.borrowerNameText}>{borrowerProfile.public_name || 'Borrower'}</Text>
            <Text style={s.borrowerScoreLine}>
              {typeof borrowerProfile.iou_score === 'number' ? borrowerProfile.iou_score : '—'}
              {'  '}
              <Text style={s.borrowerScoreMeta}>
                {typeof borrowerProfile.iou_score === 'number' ? `· ${borrowerTrustLabel}` : ''}
              </Text>
            </Text>
            <Text style={s.streakText}>{repaymentStreakText}</Text>
          </TouchableOpacity>
        )}
      </ScrollView>
    );
  };

  // Tab 2 — Payments (full schedule + all actions)
  const PaymentsTab = () => (
    <SectionList
      sections={paymentSectionData}
      keyExtractor={(item) => item.id}
      renderItem={({ item }) => {
        const origIndex = rows.findIndex(r => r.id === item.id);
        return (
          <PaymentRowView
            item={item}
            index={origIndex}
            isFirstUnpaid={isOutgoingView && origIndex === firstUnpaidIndex}
            isFirstConfirm={isIncomingView && origIndex === firstConfirmIndex}
          />
        );
      }}
      renderSectionHeader={({ section }) => (
        <View style={s.sectionHeaderView}>
          <Text style={s.sectionHeaderText}>{section.title}</Text>
        </View>
      )}
      contentContainerStyle={s.tabContent}
      ItemSeparatorComponent={() => <View style={{ height: 8 }} />}
      stickySectionHeadersEnabled={false}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
      ListEmptyComponent={
        <View style={s.emptyWrap}>
          <Text style={s.emptyText}>No payments found.</Text>
        </View>
      }
      ListFooterComponent={
        <View style={s.paymentsFooter}>
          <View style={s.rewardCard}>
            <Text style={s.rewardText}>{completionRewardText}</Text>
          </View>
          <TouchableOpacity style={s.contractBtn} onPress={openFullLoan} activeOpacity={0.8}>
            <Text style={s.contractBtnText}>View full contract</Text>
          </TouchableOpacity>
        </View>
      }
    />
  );

  // Tab 3 — Score Impact
  const ScoreImpactTab = () => {
    if (!isBorrower) {
      return (
        <ScrollView contentContainerStyle={s.tabContent}>
          <View style={s.scoreUnavailCard}>
            <Text style={s.scoreUnavailTitle}>Score projections are private to the borrower</Text>
            <Text style={s.scoreUnavailBody}>
              The score contribution and projection details for this IOU are only available to the borrower.
              As lender, you can view the borrower's public trust level from their profile.
            </Text>
          </View>
          {!!borrowerProfile && (
            <TouchableOpacity
              style={s.borrowerCard}
              onPress={navigateToPersonProfile}
              activeOpacity={0.92}
            >
              <View style={s.borrowerCardHeader}>
                <Text style={s.borrowerCardTitle}>Borrower</Text>
                <Text style={s.borrowerCardLink}>View profile →</Text>
              </View>
              <Text style={s.borrowerNameText}>{borrowerProfile.public_name || 'Borrower'}</Text>
              <Text style={s.borrowerScoreLine}>
                {typeof borrowerProfile.iou_score === 'number' ? borrowerProfile.iou_score : '—'}
                {'  '}
                <Text style={s.borrowerScoreMeta}>
                  {typeof borrowerProfile.iou_score === 'number' ? `· ${borrowerTrustLabel}` : ''}
                </Text>
              </Text>
            </TouchableOpacity>
          )}
        </ScrollView>
      );
    }

    // Frontend eligibility pre-filter.
    // The backend also validates — if eligible: false comes back, the projection card shows the reason.
    const eligibleScenarios: { id: ScenarioId; label: string; frontendEligible: boolean }[] = [
      {
        id: 'pay_next_today',
        label: 'Pay next\ntoday',
        frontendEligible: !!nextDue && isPayEligible(nextDue),
      },
      {
        id: 'payoff_today',
        label: 'Pay off\ntoday',
        frontendEligible: isOutgoingView && !isArchived && !isDeleted && remainingTotal > 0 && rows.some(r => isPayEligible(r)),
      },
      {
        id: 'complete_on_schedule',
        label: 'On\nschedule',
        frontendEligible: iou.status === 'open' || iou.status === 'late',
      },
    ];

    const activeScenarioData = scenarioData[scoreScenario] ?? null;

    return (
      <ScrollView contentContainerStyle={s.tabContent} showsVerticalScrollIndicator={false}>

        {/* Current state card — uses Score v2.2 progress data */}
        <ScoreV22DevCard
          data={scoreV22Data}
          loading={scoreV22Loading}
          error={scoreV22Error}
          onRefresh={() => { void fetchScoreV22Progress(); }}
          showDevBadge={__DEV__}
        />

        {/* Scenario selector + projection */}
        <View style={s.scenarioSection}>
          <View style={s.scenarioTitleRow}>
            <Text style={s.scenarioTitle}>Estimate if you…</Text>
            <Text style={s.scoreV22Label}>Score v2.2 estimate — Shadow</Text>
          </View>
          <View style={s.scenarioRow}>
            {eligibleScenarios.map(({ id, label, frontendEligible }) => (
              <TouchableOpacity
                key={id}
                style={[
                  s.scenarioBtn,
                  scoreScenario === id && s.scenarioBtnActive,
                  !frontendEligible && s.scenarioBtnDisabled,
                ]}
                onPress={() => frontendEligible && handleScenarioChange(id)}
                disabled={!frontendEligible}
                accessibilityRole="button"
                accessibilityState={{ selected: scoreScenario === id, disabled: !frontendEligible }}
                accessibilityLabel={label.replace('\n', ' ')}
              >
                <Text style={[
                  s.scenarioBtnText,
                  scoreScenario === id && s.scenarioBtnTextActive,
                  !frontendEligible && s.scenarioBtnTextDisabled,
                ]}>
                  {label}
                </Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>

        {/* Projection card */}
        <ScoreProjectionCard
          data={activeScenarioData}
          loading={scenarioLoading}
          error={scenarioError}
          onRetry={() => { void fetchScoreScenario(scoreScenario); }}
        />

        {/* Disclaimer */}
        <Text style={s.scoreDisclaimer}>
          Estimates use your current score, this IOU's payment history, active exposure, and the current Score v2.2 rules.
          Final results may differ if other activity changes first.
        </Text>

        {/* CTA back to pay (borrower, when eligible) */}
        {isOutgoingView && !!nextDue && isPayEligible(nextDue) && (
          <TouchableOpacity
            style={s.scorePayCta}
            onPress={() => handleTabChange('overview')}
            accessibilityRole="button"
          >
            <Text style={s.scorePayCtaText}>Go to Overview to pay →</Text>
          </TouchableOpacity>
        )}

      </ScrollView>
    );
  };

  // Sticky action bar — primary Pay action, visible on Overview and Payments tabs
  const StickyActionBar = () => {
    if (!nextDue || !isPayEligible(nextDue)) return null;
    const isLate = nextDue.status === 'late';
    return (
      <View style={s.stickyBar}>
        <View style={s.stickyBarInner}>
          <View style={s.stickyBarInfo}>
            <Text style={s.stickyBarLabel}>{isLate ? 'Overdue' : 'Next due'}</Text>
            <Text style={s.stickyBarDate}>{formatDate(nextDue.due)}</Text>
          </View>
          <TouchableOpacity
            style={[s.stickyPayBtn, isLate && { backgroundColor: theme.negative }]}
            onPress={() => goToAchPayScreen(nextDue)}
            activeOpacity={0.85}
            accessibilityRole="button"
            accessibilityLabel={`${isLate ? 'Pay now' : 'Pay early'} — ${currency(nextDue.amount_cents)}`}
          >
            <Text style={s.stickyPayBtnText}>{isLate ? 'Pay now' : 'Pay early'}</Text>
            <Text style={s.stickyPayBtnAmt}>{currency(nextDue.amount_cents)}</Text>
          </TouchableOpacity>
        </View>
      </View>
    );
  };

  // -------------------------------------------
  // RENDER
  // -------------------------------------------

  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
      <TopSummary />
      <TabBar />
      <View style={{ flex: 1 }}>
        {activeTab === 'overview' && <OverviewTab />}
        {activeTab === 'payments' && <PaymentsTab />}
        {activeTab === 'score' && <ScoreImpactTab />}
      </View>
      {activeTab !== 'score' && <StickyActionBar />}
    </View>
  );
}

// ---------------------------------------------
// STYLES
// ---------------------------------------------

const makeS = (t: AppTheme) => StyleSheet.create({
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },

  // ── Compact top summary ───────────────────────────────────────────────────────
  topSummary: {
    paddingHorizontal: 16,
    paddingTop: 12,
    paddingBottom: 10,
    borderBottomWidth: 1,
    borderBottomColor: t.divider,
    backgroundColor: t.background,
  },
  topRow1: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 6 },
  topDirChip: {
    borderRadius: 6, paddingHorizontal: 8, paddingVertical: 3,
    borderWidth: 1,
  },
  topDirChipIn: { backgroundColor: t.positiveSurface, borderColor: t.positiveBorder },
  topDirChipOut: { backgroundColor: t.negativeSurface, borderColor: t.negativeBorder },
  topDirChipText: { fontSize: 11, fontWeight: '700', color: t.textSecondary, letterSpacing: 0.3 },
  topPartyName: { flex: 1, fontSize: 13, fontWeight: '600', color: t.textSecondary },
  topCompleteChip: {
    borderRadius: 6, paddingHorizontal: 8, paddingVertical: 3,
    backgroundColor: t.positiveSurface, borderWidth: 1, borderColor: t.positiveBorder,
  },
  topCompleteChipText: { fontSize: 11, fontWeight: '700', color: t.positive },
  topAmountRow: { flexDirection: 'row', alignItems: 'baseline', gap: 6, marginBottom: 6 },
  topAmount: { fontSize: 26, fontWeight: '900', color: t.textPrimary, letterSpacing: -0.5 },
  topAmountOf: { fontSize: 13, fontWeight: '500', color: t.textMuted },
  topProgressRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  topProgressTrack: {
    flex: 1, height: 5, borderRadius: 999,
    backgroundColor: t.isDark ? '#1A1A1A' : '#EAEAEA', overflow: 'hidden',
  },
  topProgressFill: { height: '100%', borderRadius: 999, backgroundColor: GREEN },
  topProgressPct: { fontSize: 11, fontWeight: '700', color: GREEN, width: 30, textAlign: 'right' },
  topInstallments: { fontSize: 11, fontWeight: '600', color: t.textMuted },
  topNextDue: { marginTop: 5, fontSize: 12, fontWeight: '600', color: t.textMuted },

  // ── Segmented tab bar ─────────────────────────────────────────────────────────
  tabBar: {
    flexDirection: 'row',
    backgroundColor: t.surface,
    borderBottomWidth: 1,
    borderBottomColor: t.divider,
  },
  tabItem: {
    flex: 1, paddingVertical: 11, alignItems: 'center', position: 'relative',
  },
  tabItemActive: {},
  tabLabel: { fontSize: 13, fontWeight: '600', color: t.textMuted },
  tabLabelActive: { color: t.isDark ? t.brandBright : t.brand, fontWeight: '700' },
  tabIndicator: {
    position: 'absolute', bottom: 0, left: '15%', right: '15%',
    height: 2, borderRadius: 999,
    backgroundColor: t.isDark ? t.brandBright : t.brand,
  },

  // ── Tab content padding ───────────────────────────────────────────────────────
  tabContent: { padding: 16, paddingBottom: 24 },

  // ── Section headers (Payments tab) ────────────────────────────────────────────
  sectionHeaderView: {
    paddingTop: 12, paddingBottom: 6,
  },
  sectionHeaderText: {
    fontSize: 11, fontWeight: '700', color: t.textMuted,
    textTransform: 'uppercase', letterSpacing: 0.5,
  },

  // ── Next payment info card (Overview) ─────────────────────────────────────────
  nextPayCard: {
    backgroundColor: t.surface, borderRadius: 16, padding: 18,
    borderWidth: 1, borderColor: t.positiveBorder,
    shadowColor: '#000', shadowOpacity: t.isDark ? 0 : 0.05,
    shadowRadius: 6, shadowOffset: { width: 0, height: 2 }, elevation: t.isDark ? 0 : 1,
    marginBottom: 12,
  },
  nextPayLabel: {
    fontSize: 11, fontWeight: '700', color: t.textMuted,
    textTransform: 'uppercase', letterSpacing: 0.4, marginBottom: 6,
  },
  nextPayAmt: { fontSize: 32, fontWeight: '900', color: t.textPrimary, letterSpacing: -0.5 },
  nextPayDate: { fontSize: 14, fontWeight: '500', color: t.textMuted, marginTop: 4 },
  nextPayMethod: { fontSize: 13, fontWeight: '500', color: t.textMuted, marginTop: 6 },

  // ── Score impact link ─────────────────────────────────────────────────────────
  scoreImpactLink: { marginTop: 14, alignSelf: 'flex-start' },
  scoreImpactLinkText: {
    fontSize: 13, fontWeight: '700',
    color: t.isDark ? t.brandBright : t.brand,
    textDecorationLine: 'underline',
  },

  // ── Compact agreement card (Overview) ────────────────────────────────────────
  agreementCard: {
    backgroundColor: t.surface, borderRadius: 14, padding: 16,
    borderWidth: 1, borderColor: t.border,
    marginBottom: 12,
  },
  agreementHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 },
  agreementTitle: { fontSize: 13, fontWeight: '800', color: t.textPrimary },
  contractLinkText: { fontSize: 13, fontWeight: '700', color: BLUE },
  agreementGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 12 },
  agreementItem: { minWidth: '40%', flex: 1 },
  agreementLabel: { fontSize: 11, fontWeight: '600', color: t.textMuted, marginBottom: 2 },
  agreementValue: { fontSize: 15, fontWeight: '800', color: t.textPrimary },

  // ── Pending confirmation card (Overview) ──────────────────────────────────────
  pendingConfirmCard: {
    marginBottom: 12, backgroundColor: t.infoSurface, borderRadius: 12,
    padding: 14, borderWidth: 1, borderColor: t.isDark ? '#0D1540' : '#BFDBFE',
  },
  pendingConfirmTitle: { fontSize: 14, fontWeight: '800', color: t.isDark ? t.info : '#1D4ED8', marginBottom: 4 },
  pendingConfirmBody: { fontSize: 13, fontWeight: '500', color: t.isDark ? t.info : '#1E40AF', lineHeight: 20 },
  pendingConfirmCta: { marginTop: 10 },
  pendingConfirmCtaText: { fontSize: 13, fontWeight: '700', color: t.isDark ? t.info : '#1D4ED8' },

  // ── Payments tab footer ───────────────────────────────────────────────────────
  paymentsFooter: { paddingTop: 8, gap: 10 },

  // ── Score Impact tab ──────────────────────────────────────────────────────────
  scoreUnavailCard: {
    backgroundColor: t.surfaceMuted, borderRadius: 14, padding: 16,
    borderWidth: 1, borderColor: t.border, marginBottom: 12,
  },
  scoreUnavailTitle: { fontSize: 15, fontWeight: '800', color: t.textPrimary, marginBottom: 6 },
  scoreUnavailBody: { fontSize: 13, fontWeight: '500', color: t.textSecondary, lineHeight: 20 },
  scenarioSection: { marginTop: 14 },
  scenarioTitleRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 10 },
  scenarioTitle: { fontSize: 13, fontWeight: '700', color: t.textMuted },
  scoreV22Label: { fontSize: 11, fontWeight: '700', color: t.isDark ? '#FFD60A' : '#92400E' },
  scenarioRow: { flexDirection: 'row', gap: 8 },
  scenarioBtn: {
    flex: 1, paddingVertical: 12, paddingHorizontal: 6, borderRadius: 10, alignItems: 'center',
    backgroundColor: t.surfaceMuted, borderWidth: 1, borderColor: t.border,
  },
  scenarioBtnActive: {
    backgroundColor: t.isDark ? t.activeTabSurface : '#E8F5E9',
    borderColor: t.isDark ? t.brandBright : t.brand,
  },
  scenarioBtnDisabled: { opacity: 0.35 },
  scenarioBtnText: { fontSize: 12, fontWeight: '700', color: t.textSecondary, textAlign: 'center', lineHeight: 17 },
  scenarioBtnTextActive: { color: t.isDark ? t.brandBright : t.brand },
  scenarioBtnTextDisabled: { color: t.textMuted },
  scoreDisclaimer: {
    marginTop: 14, fontSize: 12, fontWeight: '500', color: t.textMuted, lineHeight: 18,
  },
  scorePayCta: { marginTop: 14, alignSelf: 'flex-start' },
  scorePayCtaText: { fontSize: 13, fontWeight: '700', color: t.isDark ? t.brandBright : t.brand },

  // ── Sticky action bar ─────────────────────────────────────────────────────────
  stickyBar: {
    borderTopWidth: 1, borderTopColor: t.border,
    backgroundColor: t.surface,
    paddingHorizontal: 16, paddingVertical: 10,
  },
  stickyBarInner: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  stickyBarInfo: { flex: 1 },
  stickyBarLabel: { fontSize: 11, fontWeight: '700', color: t.textMuted, textTransform: 'uppercase' },
  stickyBarDate: { fontSize: 13, fontWeight: '600', color: t.textSecondary, marginTop: 1 },
  stickyPayBtn: {
    backgroundColor: t.isDark ? '#1B5E20' : '#1B5E20',
    borderRadius: 12, paddingHorizontal: 20, paddingVertical: 12, alignItems: 'center',
  },
  stickyPayBtnText: { color: '#fff', fontWeight: '800', fontSize: 14 },
  stickyPayBtnAmt: { color: 'rgba(255,255,255,0.75)', fontWeight: '600', fontSize: 12, marginTop: 1 },

  // ── Borrowed styles from old layout ──────────────────────────────────────────
  header: { marginBottom: 12 },

  // ── Borrower card ─────────────────────────────────────────────────────────────
  borrowerCard: {
    marginTop: 12,
    backgroundColor: t.surface,
    borderRadius: 14,
    padding: 14,
    borderWidth: 1,
    borderColor: t.border,
    shadowColor: '#000',
    shadowOpacity: t.isDark ? 0 : 0.04,
    shadowRadius: 4,
    shadowOffset: { width: 0, height: 1 },
    elevation: t.isDark ? 0 : 1,
  },
  borrowerCardHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  borrowerCardTitle: { fontSize: 11, fontWeight: '700', color: t.textMuted, textTransform: 'uppercase', letterSpacing: 0.4 },
  borrowerCardLink: { color: BLUE, fontWeight: '700', fontSize: 13 },
  borrowerNameText: { marginTop: 8, color: t.textPrimary, fontSize: 16, fontWeight: '800' },
  borrowerScoreLine: { fontSize: 30, fontWeight: '900', color: GREEN, marginTop: 6 },
  borrowerScoreMeta: { fontSize: 15, fontWeight: '700', color: t.textMuted },
  streakText: { marginTop: 6, color: t.textSecondary, fontSize: 13, fontWeight: '500' },

  // ── Progress fill ─────────────────────────────────────────────────────────────
  progressFill: { height: '100%', borderRadius: 999, backgroundColor: GREEN },

  // ── Footer reward card ────────────────────────────────────────────────────────
  rewardCard: {
    marginTop: 12,
    backgroundColor: t.surfaceMuted,
    borderRadius: 14,
    padding: 14,
    borderWidth: 1,
    borderColor: t.border,
  },
  rewardText: { color: t.textSecondary, lineHeight: 20, fontSize: 13, fontWeight: '500' },

  // ── Payment row card ──────────────────────────────────────────────────────────
  payRow: {
    padding: 16,
    borderRadius: 14,
    backgroundColor: t.surface,
    borderWidth: 1,
    borderColor: t.border,
    shadowColor: '#000',
    shadowOpacity: t.isDark ? 0 : 0.04,
    shadowRadius: 4,
    shadowOffset: { width: 0, height: 1 },
    elevation: t.isDark ? 0 : 1,
  },
  payRowDone: { backgroundColor: t.surfaceMuted, shadowOpacity: 0, elevation: 0 },
  rowTop: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 },
  paymentIndexText: { fontSize: 11, fontWeight: '600', color: t.textMuted },
  amountText: { fontSize: 22, fontWeight: '800', color: t.textPrimary },
  amountTextDone: { color: t.textSecondary },
  dueText: { color: t.textMuted, marginTop: 3, fontSize: 14, fontWeight: '500' },
  paidDateText: { marginTop: 3, fontSize: 13, fontWeight: '500', color: t.isDark ? '#66BB6A' : '#16a34a' },
  rewardPreviewText: { marginTop: 8, color: t.textSecondary, fontSize: 12, fontWeight: '500', lineHeight: 17 },
  receiptHint: { marginTop: 8, fontSize: 12, fontWeight: '500', color: t.textMuted },
  swipeGuide: { color: t.textMuted, marginTop: 10, fontSize: 12, fontWeight: '600' },

  pill: { paddingHorizontal: 10, paddingVertical: 5, borderRadius: 999 },
  pillTxt: { fontSize: 12, fontWeight: '700' },

  // ── Action buttons ────────────────────────────────────────────────────────────
  actionArea: { marginTop: 14 },
  btnPrimary: { backgroundColor: GREEN, borderRadius: 10, paddingVertical: 13, alignItems: 'center' },
  btnPrimaryText: { color: '#fff', fontWeight: '800', fontSize: 15 },
  btnSecondary: {
    borderRadius: 10,
    paddingVertical: 11,
    alignItems: 'center',
    marginTop: 8,
    borderWidth: 1,
    borderColor: t.border,
    backgroundColor: t.surfaceMuted,
  },
  btnSecondaryText: { color: t.textSecondary, fontWeight: '700', fontSize: 14 },
  btnTextOnly: { paddingVertical: 8, alignItems: 'center', marginTop: 4 },
  btnTextOnlyLabel: { color: t.textMuted, fontWeight: '600', fontSize: 13 },

  // ── Swipe actions ─────────────────────────────────────────────────────────────
  leftActionExtension: {
    width: 150, marginVertical: 2, marginLeft: 4, borderRadius: 18,
    backgroundColor: ORANGE, justifyContent: 'center', alignItems: 'center',
  },
  leftActionText: { color: '#fff', fontWeight: '800', fontSize: 16 },
  rightActionPay: {
    width: 150, marginVertical: 2, marginRight: 4, borderRadius: 18,
    backgroundColor: GREEN, justifyContent: 'center', alignItems: 'center',
  },
  rightActionRemind: {
    width: 150, marginVertical: 2, marginRight: 4, borderRadius: 18,
    backgroundColor: ORANGE, justifyContent: 'center', alignItems: 'center',
  },
  rightActionConfirm: {
    width: 150, marginVertical: 2, marginRight: 4, borderRadius: 18,
    backgroundColor: BLUE, justifyContent: 'center', alignItems: 'center',
  },
  rightActionText: { color: '#fff', fontWeight: '800', fontSize: 16 },

  // ── Empty state ───────────────────────────────────────────────────────────────
  emptyWrap: { padding: 20, alignItems: 'center' },
  emptyText: { color: t.textMuted, fontSize: 14 },

  // ── Extension status ──────────────────────────────────────────────────────────
  extensionStatusPill: {
    marginTop: 8, alignSelf: 'flex-start',
    backgroundColor: t.isDark ? '#1A1000' : '#FEF3C7',
    borderRadius: 8, paddingHorizontal: 10, paddingVertical: 4,
    borderWidth: 1, borderColor: t.isDark ? '#2A1400' : '#FDE68A',
  },
  extensionApprovedPill: {
    backgroundColor: t.positiveSurface,
    borderColor: t.isDark ? '#0D3A15' : '#BBF7D0',
  },
  extensionDeniedPill: {
    backgroundColor: t.negativeSurface,
    borderColor: t.isDark ? '#3A0D0D' : '#FECACA',
  },
  extensionStatusText: { fontSize: 12, fontWeight: '600', color: t.isDark ? t.warning : '#92400E' },
  extensionRequestCard: {
    marginTop: 12, backgroundColor: t.isDark ? '#1A1000' : '#FFFBEB', borderRadius: 10,
    padding: 12, borderWidth: 1, borderColor: t.isDark ? '#2A1400' : '#FDE68A',
  },
  extensionRequestLabel: { fontSize: 11, fontWeight: '700', color: t.isDark ? t.warning : '#92400E', marginBottom: 4 },
  extensionRequestDate: { fontSize: 14, fontWeight: '700', color: t.textPrimary, marginBottom: 10 },
  extensionActions: { flexDirection: 'row', gap: 8 },
  extensionApproveBtn: { flex: 1, backgroundColor: '#1B5E20', borderRadius: 8, paddingVertical: 10, alignItems: 'center' },
  extensionApproveTxt: { color: '#fff', fontWeight: '800', fontSize: 14 },
  extensionDenyBtn: {
    flex: 1, backgroundColor: t.negativeSurface, borderRadius: 8, paddingVertical: 10,
    alignItems: 'center', borderWidth: 1, borderColor: t.isDark ? '#3A0D0D' : '#FECACA',
  },
  extensionDenyTxt: { color: t.isDark ? t.negative : '#B42318', fontWeight: '800', fontSize: 14 },

  // ── Direction badge ───────────────────────────────────────────────────────────
  dirBadge: { alignSelf: 'flex-start', borderRadius: 8, paddingHorizontal: 10, paddingVertical: 4, marginBottom: 12 },
  dirBadgeIn: { backgroundColor: t.positiveSurface, borderWidth: 1, borderColor: t.isDark ? '#0D3A15' : '#BBF7D0' },
  dirBadgeOut: { backgroundColor: t.negativeSurface, borderWidth: 1, borderColor: t.isDark ? '#3A0D0D' : '#FECACA' },
  dirBadgeText: { fontSize: 11, fontWeight: '700', color: t.textSecondary, textTransform: 'uppercase', letterSpacing: 0.4 },

  // ── Stats row ─────────────────────────────────────────────────────────────────
  statsRow: {
    flexDirection: 'row', alignItems: 'center', backgroundColor: t.surface, borderRadius: 14,
    padding: 14, borderWidth: 1, borderColor: t.border,
    shadowColor: '#000', shadowOpacity: t.isDark ? 0 : 0.04,
    shadowRadius: 4, shadowOffset: { width: 0, height: 1 }, elevation: t.isDark ? 0 : 1,
  },
  statItem: { flex: 1, alignItems: 'center' },
  statLabel: { fontSize: 11, fontWeight: '700', color: t.textMuted, textTransform: 'uppercase', letterSpacing: 0.3, marginBottom: 3 },
  statAmt: { fontSize: 17, fontWeight: '900', color: t.textPrimary },
  statSep: { width: 1, height: 30, backgroundColor: t.divider },

  // ── Progress bar ──────────────────────────────────────────────────────────────
  progressBarRow: { flexDirection: 'row', alignItems: 'center', gap: 10, marginTop: 14 },
  progressTrackCompact: { flex: 1, height: 8, borderRadius: 999, backgroundColor: t.isDark ? '#1A1A1A' : '#EAEAEA', overflow: 'hidden' },
  progressPctText: { fontSize: 13, fontWeight: '800', color: GREEN, width: 36, textAlign: 'right' },
  progressSubCompact: { marginTop: 5, color: t.textMuted, fontSize: 12, fontWeight: '600' },

  // ── Next payment card ─────────────────────────────────────────────────────────
  nextDueCard: {
    marginTop: 14, backgroundColor: t.surface, borderRadius: 14, padding: 16,
    borderWidth: 1, borderColor: t.isDark ? '#0D3A15' : '#BBF7D0',
    shadowColor: '#000', shadowOpacity: t.isDark ? 0 : 0.05,
    shadowRadius: 6, shadowOffset: { width: 0, height: 2 }, elevation: t.isDark ? 0 : 1,
  },
  nextDueLabel: { fontSize: 11, fontWeight: '700', color: t.textMuted, textTransform: 'uppercase', letterSpacing: 0.4, marginBottom: 6 },
  nextDueAmt: { fontSize: 28, fontWeight: '900', color: t.textPrimary, letterSpacing: -0.5 },
  nextDueDate: { fontSize: 14, fontWeight: '500', color: t.textMuted, marginTop: 3 },
  nextDueMethod: { fontSize: 13, fontWeight: '500', color: t.textMuted, marginTop: 8 },

  // ── Schedule header ───────────────────────────────────────────────────────────
  scheduleHeaderRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginTop: 22, marginBottom: 8 },
  scheduleLabel: { fontSize: 15, fontWeight: '800', color: t.textPrimary },
  contractBtn: {
    backgroundColor: t.infoSurface, borderRadius: 8, paddingHorizontal: 12, paddingVertical: 10,
    borderWidth: 1, borderColor: t.isDark ? '#0D1540' : '#DBEAFE', alignSelf: 'flex-start',
  },
  contractBtnText: { fontSize: 13, fontWeight: '700', color: BLUE },

  // ── Footer ───────────────────────────────────────────────────────────────────
  footer: { paddingTop: 16, paddingBottom: 24 },
  swipeGuideProminentBlue: { color: BLUE, fontWeight: '700', fontSize: 13 },

  // ── State notes ───────────────────────────────────────────────────────────────
  autopayNote: { marginTop: 8, fontSize: 12, fontWeight: '500', color: t.textMuted },
  processingNote: { marginTop: 6, fontSize: 13, fontWeight: '600', color: BLUE },
  pendingConfirmNote: { marginTop: 6, fontSize: 13, fontWeight: '600', color: BLUE },

  // ── DEV confirm button ────────────────────────────────────────────────────────
  devConfirmBtn: {
    marginTop: 10, alignSelf: 'flex-start', backgroundColor: '#1C1C1E',
    borderRadius: 8, paddingHorizontal: 12, paddingVertical: 8,
  },
  devConfirmBtnText: { color: '#FFD60A', fontWeight: '800', fontSize: 13 },
});

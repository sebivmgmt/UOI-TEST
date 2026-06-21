// src/screens/LoanDetail.tsx

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  View,
  Text,
  Alert,
  ActivityIndicator,
  Animated,
  FlatList,
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

// ── DEV-only Score v2.2 progress card ────────────────────────────────────────

const sv = StyleSheet.create({
  card: {
    marginTop: 14,
    backgroundColor: '#fff',
    borderRadius: 14,
    padding: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
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
    color: '#374151',
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
    backgroundColor: '#F3F4F6',
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },
  refreshBtnText: {
    color: '#374151',
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
    color: '#6B7280',
    fontSize: 14,
  },
  unavailableBox: {
    backgroundColor: '#FEF2F2',
    borderRadius: 8,
    padding: 12,
    borderWidth: 1,
    borderColor: '#FECACA',
  },
  unavailableText: {
    color: '#991B1B',
    fontSize: 13,
    fontWeight: '600',
    lineHeight: 19,
  },
  divider: {
    height: 1,
    backgroundColor: '#F3F4F6',
    marginVertical: 16,
  },
  sectionLabel: {
    fontSize: 10,
    fontWeight: '800',
    color: '#9CA3AF',
    textTransform: 'uppercase',
    letterSpacing: 0.6,
    marginBottom: 6,
  },
  // Hero — current score effect
  heroValue: {
    fontSize: 56,
    fontWeight: '900',
    letterSpacing: -1.5,
    lineHeight: 60,
    marginBottom: 6,
  },
  heroCaption: {
    fontSize: 13,
    fontWeight: '500',
    color: '#6B7280',
    lineHeight: 20,
  },
  // Repayment
  repayRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'baseline',
    marginBottom: 10,
  },
  repayAmount: {
    fontSize: 17,
    fontWeight: '800',
    color: '#111827',
  },
  repayPct: {
    fontSize: 13,
    fontWeight: '700',
    color: '#9CA3AF',
  },
  bar: {
    height: 8,
    borderRadius: 999,
    backgroundColor: '#EAEAEA',
    overflow: 'hidden',
  },
  barFillGreen: {
    height: '100%',
    borderRadius: 999,
    backgroundColor: GREEN,
  },
  miniBar: {
    height: 4,
    borderRadius: 999,
    backgroundColor: '#EAEAEA',
    overflow: 'hidden',
    marginTop: 6,
  },
  barFillBlue: {
    height: '100%',
    borderRadius: 999,
    backgroundColor: BLUE,
  },
  // Pending progress section
  pendingSectionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 12,
  },
  lockedChip: {
    backgroundColor: '#FFF7ED',
    borderRadius: 5,
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderWidth: 1,
    borderColor: '#FED7AA',
  },
  lockedChipText: {
    color: '#C2410C',
    fontSize: 11,
    fontWeight: '700',
  },
  unlockedChip: {
    backgroundColor: '#F0FDF4',
    borderRadius: 5,
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderWidth: 1,
    borderColor: '#BBF7D0',
  },
  unlockedChipText: {
    color: '#15803D',
    fontSize: 11,
    fontWeight: '700',
  },
  metricLine: {
    fontSize: 15,
    fontWeight: '800',
    color: '#111827',
    marginBottom: 2,
  },
  earlyBonusLine: {
    fontSize: 13,
    fontWeight: '600',
    color: '#374151',
    marginBottom: 2,
  },
  pendingNote: {
    marginTop: 10,
    fontSize: 12,
    fontWeight: '500',
    color: '#9CA3AF',
    lineHeight: 18,
  },
  // Projected at completion
  projectedValue: {
    fontSize: 32,
    fontWeight: '900',
    color: '#111827',
    letterSpacing: -0.5,
    marginBottom: 4,
  },
  projectedNote: {
    fontSize: 12,
    fontWeight: '500',
    color: '#9CA3AF',
    lineHeight: 18,
  },
  // Active penalty
  penaltyBlock: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    backgroundColor: '#FEF2F2',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  penaltyLabel: {
    fontSize: 13,
    fontWeight: '700',
    color: '#991B1B',
  },
  penaltyNote: {
    fontSize: 11,
    fontWeight: '500',
    color: '#9CA3AF',
    marginTop: 2,
  },
  penaltyValue: {
    fontSize: 20,
    fontWeight: '900',
    color: '#DC2626',
  },
  // Technical details
  techToggle: {
    marginTop: 14,
    paddingTop: 12,
    borderTopWidth: 1,
    borderTopColor: '#F3F4F6',
  },
  techToggleText: {
    fontSize: 12,
    fontWeight: '600',
    color: '#9CA3AF',
  },
  techBox: {
    marginTop: 8,
    backgroundColor: '#F9FAFB',
    borderRadius: 8,
    padding: 10,
    gap: 3,
  },
  techLine: {
    fontSize: 11,
    fontWeight: '500',
    color: '#6B7280',
    lineHeight: 17,
  },
});

function ScoreV22DevCard({
  data,
  loading,
  error,
  onRefresh,
}: {
  data: ScoreV22Progress | null;
  loading: boolean;
  error: string | null;
  onRefresh: () => void;
}) {
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
      ? '#6B7280'
      : data.current_public_score_effect < 0
        ? '#DC2626'
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
          <View style={sv.devBadge}>
            <Text style={sv.devBadgeText}>DEV</Text>
          </View>
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
          <Text style={[sv.heroValue, { color: effectColor }]}>
            {data.current_public_score_effect > 0 ? '+' : ''}
            {data.current_public_score_effect}
          </Text>
          <Text style={sv.heroCaption}>{heroCaption}</Text>

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

          {/* 3. Pending / completed score progress */}
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
            <View style={{ marginTop: 10 }}>
              <Text style={sv.earlyBonusLine}>
                {data.early_bonus_earned} of {data.early_bonus_max} early-payment bonus
              </Text>
              <View style={sv.miniBar}>
                <View style={[sv.barFillBlue, { width: `${earlyPct}%` }]} />
              </View>
            </View>
          )}

          {!data.positive_points_unlocked && (
            <Text style={sv.pendingNote}>
              {data.positive_points_unlock_condition || 'Pending points unlock when this IOU is completed.'}
            </Text>
          )}

          <View style={sv.divider} />

          {/* 4. Projected / completion result */}
          <Text style={sv.sectionLabel}>
            {data.positive_points_unlocked ? 'Completion result' : 'Projected at completion'}
          </Text>
          <Text style={[
            sv.projectedValue,
            data.positive_points_unlocked ? { color: GREEN } : undefined,
          ]}>
            {data.projected_completed_contribution > 0 ? '+' : ''}
            {data.projected_completed_contribution}
          </Text>
          <Text style={[
            sv.projectedNote,
            data.positive_points_unlocked ? { color: '#15803D' } : undefined,
          ]}>
            {data.positive_points_unlocked
              ? 'Applied to your IOU Score'
              : 'Pending until this IOU is completed'}
          </Text>

          {/* 5. Active penalty — only shown when > 0 */}
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

// Tracks which IOU ids have already shown the swipe nudge this session
const shownSwipeNudge = new Set<string>();
const shownConfirmNudge = new Set<string>();

// ---------------------------------------------
// SCREEN
// ---------------------------------------------

export default function LoanDetail({ route, navigation }: any) {
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

  // -------------------------------------------
  // AUTH
  // -------------------------------------------

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      setMe(data.user?.id ?? null);
    });
  }, []);

  useEffect(() => {
    navigation.setOptions({ title: iou?.title ?? 'IOU Details' });
  }, [iou, navigation]);

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
      return 'Loan completed. Completion is reflected in your trust history.';
    }

    if (paymentsRemaining === 1) {
      return 'One payment left. Completing this loan will strengthen your IOU Score.';
    }

    return `${paymentsRemaining} payments remaining. Completing this loan will strengthen your IOU Score.`;
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
        if (isFinal) {
          return 'Paying early may strengthen your IOU Score. Completion will be reflected in your trust history.';
        }
        return 'Paying early may strengthen your IOU Score.';
      }

      if (timing === 'on_time') {
        if (isFinal) {
          return 'On-time payment builds your IOU Score. Completion will be reflected in your trust history.';
        }
        return 'On-time payment builds your IOU Score.';
      }

      if (timing === 'late') {
        if (isFinal) {
          return 'Late payment — completion will still be reflected in your trust history.';
        }
        return 'Late payment — no timing reward.';
      }

      if (isFinal) {
        return 'Final payment — completion will be reflected in your trust history.';
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

  // -------------------------------------------
  // SMALL UI COMPONENTS
  // -------------------------------------------

  const StatusPill = ({ value }: { value: string }) => {
    const bg =
      value === 'paid'
        ? '#C8E6C9'
        : value === 'pending_confirmation'
          ? '#BBDEFB'
          : value === 'processing'
            ? '#DBEAFE'
            : value === 'late'
              ? '#FFCDD2'
              : '#E0E0E0';

    const label =
      value === 'paid' ? 'Paid' :
      value === 'pending_confirmation' ? 'Pending' :
      value === 'processing' ? 'Processing' :
      value === 'scheduled' ? 'Autopay' :
      value === 'late' ? 'Overdue' :
      value.charAt(0).toUpperCase() + value.slice(1);

    return (
      <View style={[s.pill, { backgroundColor: bg }]}>
        <Text style={s.pillTxt}>{label}</Text>
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

    const canPay =
      isOutgoingView &&
      !isArchived &&
      !isDeleted &&
      !item.paid_at &&
      (item.status === 'scheduled' || item.status === 'late');

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
          <View style={s.payRow}>
            <View style={s.rowTop}>
              <View style={{ flex: 1 }}>
                <Text style={s.paymentIndexText}>
                  Payment {index + 1} of {Math.max(totalInstallments, rows.length)}
                </Text>

                <Text style={s.amountText}>{currency(item.amount_cents)}</Text>
                <Text style={s.dueText}>Due {item.due}</Text>

                {!!rewardPreviewText && (
                  <Text style={s.rewardPreviewText}>{rewardPreviewText}</Text>
                )}

                {/* Extension status for borrower */}
                {isOutgoingView && item.extension_status === 'requested' && (
                  <View style={s.extensionStatusPill}>
                    <Text style={s.extensionStatusText}>Extension pending lender approval</Text>
                  </View>
                )}
                {isOutgoingView && item.extension_status === 'approved' && !!item.extension_requested_until && (
                  <View style={[s.extensionStatusPill, s.extensionApprovedPill]}>
                    <Text style={[s.extensionStatusText, { color: '#1B5E20' }]}>
                      Extended to {parseDateLocal(item.extension_requested_until).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}
                    </Text>
                  </View>
                )}
                {isOutgoingView && item.extension_status === 'denied' && (
                  <View style={[s.extensionStatusPill, s.extensionDeniedPill]}>
                    <Text style={[s.extensionStatusText, { color: '#B42318' }]}>Extension denied — original due date applies</Text>
                  </View>
                )}

                {/* Lender: approve or deny an incoming extension request */}
                {isIncomingView && item.extension_status === 'requested' && !!item.extension_requested_until && (
                  <View style={s.extensionRequestCard}>
                    <Text style={s.extensionRequestLabel}>EXTENSION REQUESTED</Text>
                    <Text style={s.extensionRequestDate}>
                      Borrower requests until{' '}
                      {parseDateLocal(item.extension_requested_until).toLocaleDateString(undefined, { month: 'long', day: 'numeric' })}
                    </Text>
                    <View style={s.extensionActions}>
                      <TouchableOpacity
                        style={s.extensionApproveBtn}
                        onPress={() => approveExtension(item)}
                      >
                        <Text style={s.extensionApproveTxt}>Approve</Text>
                      </TouchableOpacity>
                      <TouchableOpacity
                        style={s.extensionDenyBtn}
                        onPress={() => denyExtension(item)}
                      >
                        <Text style={s.extensionDenyTxt}>Deny</Text>
                      </TouchableOpacity>
                    </View>
                  </View>
                )}

                {isOutgoingView && item.status === 'scheduled' && !item.paid_at && (
                  <Text style={s.autopayNote}>AutoPay withdraws on the due date</Text>
                )}

                {isOutgoingView && item.status === 'processing' && !item.paid_at && (
                  <Text style={s.processingNote}>ACH payment in progress</Text>
                )}

                {isOutgoingView && item.status === 'pending_confirmation' && !item.paid_at && (
                  <Text style={s.pendingConfirmNote}>Manual payment submitted · Waiting for lender</Text>
                )}

                {__DEV__ && !item.paid_at && item.status === 'pending_confirmation' && !!devConfirmPayment && (
                  <TouchableOpacity
                    style={s.devConfirmBtn}
                    onPress={() => void devConfirmPayment(item)}
                    activeOpacity={0.8}
                  >
                    <Text style={s.devConfirmBtnText}>Dev: Confirm Payment</Text>
                  </TouchableOpacity>
                )}

                {!item.paid_at && canPay && (
                  <View>
                    <View style={s.inlineActionRow}>
                      <TouchableOpacity
                        style={[s.inlineBtn, s.inlineBtnPay]}
                        onPress={() => goToAchPayScreen(item)}
                      >
                        <Text style={s.inlineBtnPayText}>
                          {item.status === 'late' ? 'Pay now' : 'Pay early'}
                        </Text>
                      </TouchableOpacity>
                      {canRequestExtension && (
                        <TouchableOpacity
                          style={[s.inlineBtn, s.inlineBtnExt]}
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
                          <Text style={s.inlineBtnExtText}>Request extension</Text>
                        </TouchableOpacity>
                      )}
                    </View>
                    <TouchableOpacity
                      style={[s.inlineBtn, s.inlineBtnManual, { marginTop: 6, alignSelf: 'flex-start' }]}
                      onPress={() => goToManualPayScreen(item)}
                    >
                      <Text style={s.inlineBtnManualText}>Record manual payment</Text>
                    </TouchableOpacity>
                  </View>
                )}
                {!item.paid_at && canRemind && (
                  <Text style={s.swipeGuide}>Swipe left to send a reminder</Text>
                )}
                {!item.paid_at && canConfirm && (
                  <Text style={[s.swipeGuide, isFirstConfirm ? s.swipeGuideProminentBlue : { color: BLUE }]}>
                    Swipe left to confirm or reject
                  </Text>
                )}
                {!!item.paid_at && (
                  <Text style={[s.swipeGuide, { color: GREEN }]}>
                    Paid {new Date(item.paid_at).toLocaleDateString()}
                  </Text>
                )}
              </View>

              <View style={s.statusWrap}>
                <StatusPill
                  value={item.paid_at ? 'paid' : item.status || 'scheduled'}
                />
              </View>
            </View>
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
        <Text>Missing loan id.</Text>
      </View>
    );
  }

  if (loading) {
    return (
      <View style={s.center}>
        <ActivityIndicator />
      </View>
    );
  }

  if (!iou) {
    return (
      <View style={s.center}>
        <Text>Loan not found.</Text>
      </View>
    );
  }

  // -------------------------------------------
  // RENDER
  // -------------------------------------------

  return (
    <View style={{ flex: 1, backgroundColor: SOFT_BG }}>
      <FlatList
        data={rows}
        keyExtractor={(p) => p.id}
        renderItem={({ item, index }) => (
          <PaymentRowView
            item={item}
            index={index}
            isFirstUnpaid={isOutgoingView && index === firstUnpaidIndex}
            isFirstConfirm={isIncomingView && index === firstConfirmIndex}
          />
        )}
        contentContainerStyle={{ padding: 16, paddingBottom: 96 }}
        ItemSeparatorComponent={() => <View style={{ height: 10 }} />}
        ListHeaderComponent={
          <View style={s.header}>
            <View style={[s.dirBadge, isIncomingView ? s.dirBadgeIn : s.dirBadgeOut]}>
              <Text style={s.dirBadgeText}>{isIncomingView ? 'INCOMING' : 'OUTGOING'}</Text>
            </View>

            <View style={s.statsRow}>
              <View style={s.statItem}>
                <Text style={s.statLabel}>Total</Text>
                <Text style={s.statAmt}>{currency(scheduledTotal)}</Text>
              </View>
              <View style={s.statSep} />
              <View style={s.statItem}>
                <Text style={s.statLabel}>Paid</Text>
                <Text style={[s.statAmt, { color: GREEN }]}>{currency(paidTotal)}</Text>
              </View>
              <View style={s.statSep} />
              <View style={s.statItem}>
                <Text style={s.statLabel}>Remaining</Text>
                <Text style={[s.statAmt, { color: '#C62828' }]}>{currency(remainingTotal)}</Text>
              </View>
            </View>

            <View style={s.progressBarRow}>
              <View style={s.progressTrackCompact}>
                <View style={[s.progressFill, { width: `${progressPercent}%` }]} />
              </View>
              <Text style={s.progressPctText}>{progressPercent}%</Text>
            </View>
            <Text style={s.progressSubCompact}>
              {paidInstallments} of {Math.max(totalInstallments, rows.length)} payments
              {pendingCount > 0 ? ` · ${pendingCount} pending confirmation` : ''}
            </Text>

            {!!nextDue && (
              <View style={s.nextDueCard}>
                <Text style={s.nextDueLabel}>NEXT PAYMENT DUE</Text>
                <View style={s.nextDueRow}>
                  <Text style={s.nextDueDate}>
                    {parseDateLocal(nextDue.due).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })}
                  </Text>
                  <Text style={s.nextDueAmt}>{currency(nextDue.amount_cents)}</Text>
                </View>
              </View>
            )}

            {isIncomingView && incomingPendingCount > 0 && (
              <View style={s.pendingConfirmCard}>
                <Text style={s.pendingConfirmTitle}>Manual payment submitted</Text>
                <Text style={s.pendingConfirmBody}>
                  {incomingPendingCount === 1
                    ? 'The borrower manually submitted 1 payment outside AutoPay. Confirm once received, or reject if not.'
                    : `The borrower manually submitted ${incomingPendingCount} payments outside AutoPay. Swipe left on each row to confirm or reject.`}
                </Text>
              </View>
            )}

            <View style={s.scheduleHeaderRow}>
              <Text style={s.scheduleLabel}>Payment Schedule</Text>
              <TouchableOpacity onPress={openFullLoan}>
                <Text style={s.contractLinkText}>Contract →</Text>
              </TouchableOpacity>
            </View>
          </View>
        }
        ListFooterComponent={
          <View style={s.footer}>
            <View style={s.rewardCard}>
              <Text style={s.rewardText}>{completionRewardText}</Text>
            </View>
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

            {__DEV__ && isBorrower && (
              <ScoreV22DevCard
                data={scoreV22Data}
                loading={scoreV22Loading}
                error={scoreV22Error}
                onRefresh={() => { void fetchScoreV22Progress(); }}
              />
            )}
          </View>
        }
        ListEmptyComponent={
          <View style={s.emptyWrap}>
            <Text style={s.emptyText}>No payments found.</Text>
          </View>
        }
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={onRefresh} />
        }
      />
    </View>
  );
}

// ---------------------------------------------
// STYLES
// ---------------------------------------------

const s = StyleSheet.create({
  center: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },

  header: {
    marginBottom: 12,
  },

  borrowerCard: {
    marginTop: 12,
    backgroundColor: '#fff',
    borderRadius: 14,
    padding: 14,
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },

  borrowerCardHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },

  borrowerCardTitle: {
    fontSize: 12,
    fontWeight: '800',
    color: '#777',
    textTransform: 'uppercase',
  },

  borrowerCardLink: {
    color: BLUE,
    fontWeight: '800',
    fontSize: 13,
  },

  borrowerNameText: {
    marginTop: 8,
    color: '#111827',
    fontSize: 16,
    fontWeight: '800',
  },

  borrowerScoreLine: {
    fontSize: 30,
    fontWeight: '900',
    color: GREEN,
    marginTop: 6,
  },

  borrowerScoreMeta: {
    fontSize: 15,
    fontWeight: '800',
    color: '#667085',
  },

  streakText: {
    marginTop: 6,
    color: '#4D4D4D',
    fontSize: 14,
    fontWeight: '700',
  },

  progressFill: {
    height: '100%',
    borderRadius: 999,
    backgroundColor: GREEN,
  },

  rewardCard: {
    marginTop: 14,
    backgroundColor: '#F1FFF1',
    borderRadius: 14,
    padding: 14,
    borderWidth: 1,
    borderColor: '#D8EFD8',
  },

  rewardText: {
    color: '#2E7D32',
    lineHeight: 20,
    fontSize: 14,
    fontWeight: '600',
  },

  payRow: {
    padding: 16,
    borderRadius: 14,
    backgroundColor: '#fff',
    borderWidth: 1,
    borderColor: '#E9E9E9',
  },

  rowTop: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    gap: 12,
  },

  paymentIndexText: {
    fontSize: 11,
    fontWeight: '600',
    color: '#9CA3AF',
    marginBottom: 2,
  },

  amountText: {
    fontSize: 22,
    fontWeight: '800',
    color: '#111',
  },

  dueText: {
    color: '#6B7280',
    marginTop: 4,
    fontSize: 14,
  },

  rewardPreviewText: {
    marginTop: 8,
    color: '#2E7D32',
    fontSize: 13,
    fontWeight: '700',
    lineHeight: 18,
  },

  swipeGuide: {
    color: '#7A7A7A',
    marginTop: 10,
    fontSize: 13,
    fontWeight: '700',
  },

  statusWrap: {
    alignItems: 'flex-end',
  },

  pill: {
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 999,
  },

  pillTxt: {
    fontSize: 12,
    fontWeight: '800',
    color: '#111',
  },

  leftActionExtension: {
    width: 150,
    marginVertical: 2,
    marginLeft: 4,
    borderRadius: 18,
    backgroundColor: ORANGE,
    justifyContent: 'center',
    alignItems: 'center',
  },

  leftActionText: {
    color: '#fff',
    fontWeight: '800',
    fontSize: 16,
  },

  rightActionPay: {
    width: 150,
    marginVertical: 2,
    marginRight: 4,
    borderRadius: 18,
    backgroundColor: GREEN,
    justifyContent: 'center',
    alignItems: 'center',
  },

  rightActionRemind: {
    width: 150,
    marginVertical: 2,
    marginRight: 4,
    borderRadius: 18,
    backgroundColor: ORANGE,
    justifyContent: 'center',
    alignItems: 'center',
  },

  rightActionConfirm: {
    width: 150,
    marginVertical: 2,
    marginRight: 4,
    borderRadius: 18,
    backgroundColor: BLUE,
    justifyContent: 'center',
    alignItems: 'center',
  },

  rightActionText: {
    color: '#fff',
    fontWeight: '800',
    fontSize: 16,
  },

  emptyWrap: {
    padding: 20,
    alignItems: 'center',
  },

  emptyText: {
    color: '#777',
  },

  extensionStatusPill: {
    marginTop: 8,
    alignSelf: 'flex-start',
    backgroundColor: '#FEF3C7',
    borderRadius: 8,
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderWidth: 1,
    borderColor: '#FDE68A',
  },

  extensionApprovedPill: {
    backgroundColor: '#F0FDF4',
    borderColor: '#BBF7D0',
  },

  extensionDeniedPill: {
    backgroundColor: '#FEF2F2',
    borderColor: '#FECACA',
  },

  extensionStatusText: {
    fontSize: 12,
    fontWeight: '700',
    color: '#92400E',
  },

  extensionRequestCard: {
    marginTop: 12,
    backgroundColor: '#FFFBEB',
    borderRadius: 10,
    padding: 12,
    borderWidth: 1,
    borderColor: '#FDE68A',
  },

  extensionRequestLabel: {
    fontSize: 10,
    fontWeight: '800',
    color: '#92400E',
    textTransform: 'uppercase',
    letterSpacing: 0.4,
    marginBottom: 4,
  },

  extensionRequestDate: {
    fontSize: 14,
    fontWeight: '700',
    color: '#111827',
    marginBottom: 10,
  },

  extensionActions: {
    flexDirection: 'row',
    gap: 8,
  },

  extensionApproveBtn: {
    flex: 1,
    backgroundColor: '#1B5E20',
    borderRadius: 8,
    paddingVertical: 10,
    alignItems: 'center',
  },

  extensionApproveTxt: {
    color: '#fff',
    fontWeight: '800',
    fontSize: 14,
  },

  extensionDenyBtn: {
    flex: 1,
    backgroundColor: '#FEF2F2',
    borderRadius: 8,
    paddingVertical: 10,
    alignItems: 'center',
    borderWidth: 1,
    borderColor: '#FECACA',
  },

  extensionDenyTxt: {
    color: '#B42318',
    fontWeight: '800',
    fontSize: 14,
  },

  dirBadge: {
    alignSelf: 'flex-start',
    borderRadius: 8,
    paddingHorizontal: 10,
    paddingVertical: 4,
    marginBottom: 10,
  },
  dirBadgeIn: { backgroundColor: '#DDEEDD' },
  dirBadgeOut: { backgroundColor: '#F7DDDD' },
  dirBadgeText: { fontSize: 11, fontWeight: '800', color: '#374151', textTransform: 'uppercase', letterSpacing: 0.4 },

  statsRow: { flexDirection: 'row', alignItems: 'center', backgroundColor: '#fff', borderRadius: 14, padding: 14, borderWidth: 1, borderColor: '#E5E7EB' },
  statItem: { flex: 1, alignItems: 'center' },
  statLabel: { fontSize: 10, fontWeight: '800', color: '#9CA3AF', textTransform: 'uppercase', letterSpacing: 0.3, marginBottom: 3 },
  statAmt: { fontSize: 18, fontWeight: '900', color: '#111827' },
  statSep: { width: 1, height: 30, backgroundColor: '#E5E7EB' },

  progressBarRow: { flexDirection: 'row', alignItems: 'center', gap: 10, marginTop: 12 },
  progressTrackCompact: { flex: 1, height: 8, borderRadius: 999, backgroundColor: '#EAEAEA', overflow: 'hidden' },
  progressPctText: { fontSize: 13, fontWeight: '800', color: GREEN, width: 36, textAlign: 'right' },
  progressSubCompact: { marginTop: 4, color: '#6B7280', fontSize: 12, fontWeight: '600' },

  nextDueCard: { marginTop: 12, backgroundColor: '#F0FDF4', borderRadius: 12, padding: 12, borderWidth: 1, borderColor: '#BBF7D0' },
  nextDueLabel: { fontSize: 10, fontWeight: '800', color: '#15803D', textTransform: 'uppercase', letterSpacing: 0.4, marginBottom: 4 },
  nextDueRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  nextDueDate: { fontSize: 15, fontWeight: '800', color: '#111827' },
  nextDueAmt: { fontSize: 15, fontWeight: '900', color: GREEN },

  scheduleHeaderRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginTop: 18, marginBottom: 4 },
  scheduleLabel: { fontSize: 14, fontWeight: '900', color: '#111827', textTransform: 'uppercase', letterSpacing: 0.3 },
  contractLinkText: { fontSize: 13, fontWeight: '700', color: BLUE },

  footer: { paddingTop: 16, paddingBottom: 40 },
  swipeGuideProminentBlue: { color: BLUE, fontWeight: '800', fontSize: 14 },

  pendingConfirmCard: {
    marginTop: 12,
    backgroundColor: '#EFF6FF',
    borderRadius: 12,
    padding: 14,
    borderWidth: 1,
    borderColor: '#BFDBFE',
  },
  pendingConfirmTitle: {
    fontSize: 14,
    fontWeight: '800',
    color: '#1D4ED8',
    marginBottom: 4,
  },
  pendingConfirmBody: {
    fontSize: 13,
    fontWeight: '600',
    color: '#1E40AF',
    lineHeight: 20,
  },
  autopayNote: {
    marginTop: 6,
    fontSize: 13,
    fontWeight: '700',
    color: '#16a34a',
  },
  processingNote: {
    marginTop: 6,
    fontSize: 13,
    fontWeight: '700',
    color: BLUE,
  },
  pendingConfirmNote: {
    marginTop: 6,
    fontSize: 13,
    fontWeight: '700',
    color: '#3B82F6',
  },
  devConfirmBtn: {
    marginTop: 10,
    alignSelf: 'flex-start',
    backgroundColor: '#1C1C1E',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  devConfirmBtnText: {
    color: '#FFD60A',
    fontWeight: '800',
    fontSize: 13,
  },

  inlineActionRow: {
    flexDirection: 'row',
    gap: 8,
    marginTop: 12,
  },
  inlineBtn: {
    borderRadius: 8,
    paddingVertical: 8,
    paddingHorizontal: 14,
    alignItems: 'center',
    justifyContent: 'center',
  },
  inlineBtnPay: {
    backgroundColor: GREEN,
  },
  inlineBtnPayText: {
    color: '#fff',
    fontWeight: '800',
    fontSize: 13,
  },
  inlineBtnExt: {
    backgroundColor: '#FEF3C7',
    borderWidth: 1,
    borderColor: '#FDE68A',
  },
  inlineBtnExtText: {
    color: '#92400E',
    fontWeight: '700',
    fontSize: 13,
  },
  inlineBtnManual: {
    backgroundColor: '#F3F4F6',
    borderWidth: 1,
    borderColor: '#E5E7EB',
  },
  inlineBtnManualText: {
    color: '#374151',
    fontWeight: '700',
    fontSize: 13,
  },
});
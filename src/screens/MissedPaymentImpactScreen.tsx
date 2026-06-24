// src/screens/MissedPaymentImpactScreen.tsx
//
// Communicates what happens if the next payment becomes late, how to request
// an extension before the due date, and how to recover if already overdue.
//
// PRIVACY: Score projections are BORROWER-ONLY. Lenders see payment status and
// extension information only — the projection section must never render for a
// lender, even briefly.
//
// All score, Visible Trust, penalty, and opportunity-loss values come from the
// backend RPC. No arithmetic on these values is performed in React Native.

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
  Alert,
} from 'react-native';
import Svg, { Path, Text as SvgText } from 'react-native-svg';
import { useAppTheme, AppTheme } from '../theme';
import { supabase } from '../supabase';

// ─── Gauge geometry (identical to LoanDetail.tsx) ─────────────────────────────
// In react-native-svg, sweep=1 goes counter-clockwise visually and over the
// top, which is the direction we want for a top-semicircle arc.

const G_R = 90;
const G_SW = 20;
const G_PAD = G_SW / 2 + 2;           // 12 — headroom above arc stroke cap
const G_W = 2 * (G_R + G_SW / 2);     // 200
const G_H = G_R + G_SW / 2 + G_PAD;   // 112
const G_CX = G_W / 2;                 // 100
const G_CY = G_H;                     // 112

const G_TRACK_PATH =
  `M ${G_CX - G_R} ${G_CY} ` +
  `A ${G_R} ${G_R} 0 0 1 ${G_CX} ${G_CY - G_R} ` +
  `A ${G_R} ${G_R} 0 0 1 ${G_CX + G_R} ${G_CY}`;

function halfDonutFillPath(fillRatio: number): string {
  const clamped = Math.min(1, Math.max(0, fillRatio));
  if (clamped <= 0) return '';
  if (clamped >= 1) {
    return (
      `M ${G_CX - G_R} ${G_CY} ` +
      `A ${G_R} ${G_R} 0 0 1 ${G_CX} ${G_CY - G_R} ` +
      `A ${G_R} ${G_R} 0 0 1 ${G_CX + G_R} ${G_CY}`
    );
  }
  const endAngleRad = ((1 - clamped) * 180 * Math.PI) / 180;
  const ex = (G_CX + G_R * Math.cos(endAngleRad)).toFixed(3);
  const ey = (G_CY - G_R * Math.sin(endAngleRad)).toFixed(3);
  if (clamped > 0.5) {
    return (
      `M ${G_CX - G_R} ${G_CY} ` +
      `A ${G_R} ${G_R} 0 0 1 ${G_CX} ${G_CY - G_R} ` +
      `A ${G_R} ${G_R} 0 0 1 ${ex} ${ey}`
    );
  }
  return `M ${G_CX - G_R} ${G_CY} A ${G_R} ${G_R} 0 0 1 ${ex} ${ey}`;
}

// ─── Types ────────────────────────────────────────────────────────────────────

type PaymentStatus = 'scheduled' | 'pending_confirmation' | 'paid' | 'late' | string;

type PaymentRow = {
  id: string;
  iou_id: string;
  amount_cents: number;
  status: PaymentStatus;
  paid_at: string | null;
  due: string;                          // YYYY-MM-DD
  payment_method?: string | null;
  extension_status?: string | null;
  extension_requested_until?: string | null;
};

type IouRow = {
  id: string;
  title: string | null;
  lender_id: string;
  borrower_id: string | null;
  archived_at: string | null;
  deleted_at: string | null;
};

// Contract for get_my_iou_score_v22_late_scenario(p_iou_id, p_payment_id, p_days_late).
// All numeric values come from the backend. No client-side score arithmetic.
type IouLateScenario = {
  dueDate: string;
  daysLate: number;
  eligible: boolean;
  completesIou: boolean;
  paymentAmountCents: number;

  // Gauge primary metric: points foregone vs. paying now
  opportunityLossVsPayNow: number;
  // Gauge denominator: payNowProjectedScore - currentScore
  payNowProjectedScore: number;
  payNowProjectedVisibleTrust: number;

  currentScore: number;
  projectedScore: number;
  scoreDelta: number;

  currentVisibleTrust: number;
  projectedVisibleTrust: number;
  visibleTrustDelta: number;

  currentIouEffect: number;
  projectedIouEffect: number;

  additionalLatePenalty: number;
  totalRetainedPenalty: number;

  currentExposure: number;
  projectedExposure: number;

  completionCreditStillLocked: number;
  earlyBonusStillLocked: number;

  explanation: string[];
};

function isIouLateScenario(v: unknown): v is IouLateScenario {
  if (typeof v !== 'object' || v === null) return false;
  const r = v as Record<string, unknown>;
  return (
    typeof r.eligible === 'boolean' &&
    typeof r.opportunityLossVsPayNow === 'number' &&
    typeof r.payNowProjectedScore === 'number' &&
    typeof r.currentScore === 'number' &&
    typeof r.projectedScore === 'number' &&
    typeof r.scoreDelta === 'number' &&
    typeof r.currentVisibleTrust === 'number' &&
    typeof r.projectedVisibleTrust === 'number' &&
    typeof r.visibleTrustDelta === 'number' &&
    typeof r.additionalLatePenalty === 'number' &&
    typeof r.totalRetainedPenalty === 'number' &&
    typeof r.currentExposure === 'number' &&
    typeof r.completionCreditStillLocked === 'number' &&
    Array.isArray(r.explanation)
  );
}

type DaysLate = 1 | 7 | 14 | 30;
const CHECKPOINTS: DaysLate[] = [1, 7, 14, 30];
const CHECKPOINT_LABELS: Record<DaysLate, string> = {
  1: '1 day',
  7: '7 days',
  14: '14 days',
  30: '30 days',
};

// 'error' sentinel means the fetch for that checkpoint failed; data can be retried.
type ProjectionEntry = IouLateScenario | 'error';

// ─── Helpers ──────────────────────────────────────────────────────────────────

const currency = (c: number) => `$${(c / 100).toFixed(2)}`;

const parseDateLocal = (s: string): Date => {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, m - 1, d);
};

const formatDateLong = (s: string): string =>
  parseDateLocal(s).toLocaleDateString(undefined, {
    month: 'long',
    day: 'numeric',
    year: 'numeric',
  });

function daysFromToday(dueDateStr: string): number {
  const due = parseDateLocal(dueDateStr);
  const today = new Date();
  const todayMidnight = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  return Math.round((due.getTime() - todayMidnight.getTime()) / (24 * 60 * 60 * 1000));
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function MissedPaymentImpactScreen({ route, navigation }: any) {
  const theme = useAppTheme();
  const s = useMemo(() => makeS(theme), [theme]);

  const iouId: string = route?.params?.iouId ?? '';
  const paymentId: string = route?.params?.paymentId ?? '';

  // ── Auth & data ──────────────────────────────────────────────────────────────

  const [me, setMe] = useState<string | null>(null);
  const [iou, setIou] = useState<IouRow | null>(null);
  const [payment, setPayment] = useState<PaymentRow | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => setMe(data.user?.id ?? null));
  }, []);

  const fetchData = useCallback(async () => {
    if (!iouId || !paymentId) return;
    setLoading(true);
    try {
      const [iouRes, payRes] = await Promise.all([
        supabase
          .from('ious')
          .select('id,title,lender_id,borrower_id,archived_at,deleted_at')
          .eq('id', iouId)
          .single(),
        supabase
          .from('payments')
          .select('id,iou_id,amount_cents,status,paid_at,due_date,payment_method,extension_status,extension_requested_until')
          .eq('id', paymentId)
          .single(),
      ]);

      if (!iouRes.error && iouRes.data) setIou(iouRes.data as IouRow);

      if (!payRes.error && payRes.data) {
        const p = payRes.data as any;
        setPayment({
          id: p.id,
          iou_id: p.iou_id,
          amount_cents: p.amount_cents,
          status: p.status,
          paid_at: p.paid_at ?? null,
          due: p.due_date ?? '',
          payment_method: p.payment_method ?? null,
          extension_status: p.extension_status ?? null,
          extension_requested_until: p.extension_requested_until ?? null,
        });
      } else {
        // Fallback for due_at column variant
        const fb = await supabase
          .from('payments')
          .select('id,iou_id,amount_cents,status,paid_at,due_at,payment_method,extension_status,extension_requested_until')
          .eq('id', paymentId)
          .single();
        if (!fb.error && fb.data) {
          const p = fb.data as any;
          setPayment({
            id: p.id,
            iou_id: p.iou_id,
            amount_cents: p.amount_cents,
            status: p.status,
            paid_at: p.paid_at ?? null,
            due: typeof p.due_at === 'string' ? p.due_at.slice(0, 10) : '',
            payment_method: p.payment_method ?? null,
            extension_status: p.extension_status ?? null,
            extension_requested_until: p.extension_requested_until ?? null,
          });
        }
      }
    } catch {
      Alert.alert('Load failed', 'Could not load payment details.');
    } finally {
      setLoading(false);
    }
  }, [iouId, paymentId]);

  useEffect(() => { void fetchData(); }, [fetchData]);

  // ── Projection state (borrower-only) ─────────────────────────────────────────

  const [selectedDaysLate, setSelectedDaysLate] = useState<DaysLate>(1);
  const [projections, setProjections] = useState<Partial<Record<DaysLate, ProjectionEntry>>>({});
  const [projectionLoading, setProjectionLoading] = useState(false);

  // ── Disclosure ───────────────────────────────────────────────────────────────

  const [disclosureOpen, setDisclosureOpen] = useState(false);

  // ── Derived state ────────────────────────────────────────────────────────────

  const isBorrower = !!me && !!iou && me === iou.borrower_id;
  const isLender = !!me && !!iou && me === iou.lender_id;
  const isArchived = !!iou?.archived_at;
  const isDeleted = !!iou?.deleted_at;

  const daysDiff = payment?.due ? daysFromToday(payment.due) : null;
  const isOverdue = payment?.status === 'late' || (daysDiff !== null && daysDiff < 0);
  const daysOverdue = isOverdue && daysDiff !== null ? Math.abs(daysDiff) : null;
  const daysRemaining = !isOverdue && daysDiff !== null ? daysDiff : null;

  const canRequestExtension =
    isBorrower &&
    !isArchived &&
    !isDeleted &&
    !!payment &&
    !payment.paid_at &&
    (payment.status === 'scheduled' || payment.status === 'late') &&
    payment.extension_status !== 'requested';

  const canPay =
    isBorrower &&
    !isArchived &&
    !isDeleted &&
    !!payment &&
    !payment.paid_at &&
    (payment.status === 'scheduled' || payment.status === 'late');

  // ── RPC fetch (borrower-only) ────────────────────────────────────────────────

  const fetchLateProjection = useCallback(async (daysLate: DaysLate) => {
    if (!isBorrower || !iouId || !paymentId) return;
    if (projections[daysLate] !== undefined) return;   // already cached (data or error)
    setProjectionLoading(true);
    try {
      const { data, error } = await supabase.rpc('get_my_iou_score_v22_late_scenario', {
        p_iou_id: iouId,
        p_payment_id: paymentId,
        p_days_late: daysLate,
      });
      if (error) {
        setProjections(prev => ({ ...prev, [daysLate]: 'error' }));
        return;
      }
      if (!isIouLateScenario(data)) {
        setProjections(prev => ({ ...prev, [daysLate]: 'error' }));
        return;
      }
      setProjections(prev => ({ ...prev, [daysLate]: data }));
    } catch {
      setProjections(prev => ({ ...prev, [daysLate]: 'error' }));
    } finally {
      setProjectionLoading(false);
    }
  }, [isBorrower, iouId, paymentId, projections]);

  // Retry clears the cached error then re-fetches
  const retryProjection = useCallback((daysLate: DaysLate) => {
    setProjections(prev => {
      const next = { ...prev };
      delete next[daysLate];
      return next;
    });
  }, []);

  useEffect(() => {
    if (isBorrower) void fetchLateProjection(selectedDaysLate);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isBorrower, selectedDaysLate, projections]);

  // ── Actions ──────────────────────────────────────────────────────────────────

  const handlePayNow = () => {
    if (!payment) return;
    navigation.navigate('AchPayment', {
      paymentId: payment.id,
      amount: payment.amount_cents,
      due: payment.due,
      iouId,
      iou_id: iouId,
    });
  };

  const handleRequestExtension = () => {
    if (!payment) return;
    navigation.navigate('RequestExtension', {
      paymentId: payment.id,
      iouId,
      scheduledAt: payment.due,
      paymentAmount: payment.amount_cents,
      title: iou?.title,
    });
  };

  // ── Loading / error gates ────────────────────────────────────────────────────

  if (loading) {
    return (
      <View style={s.center}>
        <ActivityIndicator color={theme.brand} />
      </View>
    );
  }

  if (!payment || !iou) {
    return (
      <View style={s.center}>
        <Text style={s.errorText}>Payment details unavailable.</Text>
      </View>
    );
  }

  // ── Lender view — payment status + extension info only; no projections ────────

  if (isLender && !isBorrower) {
    return (
      <ScrollView contentContainerStyle={s.content} showsVerticalScrollIndicator={false}>
        <LenderView
          payment={payment}
          isOverdue={isOverdue}
          daysOverdue={daysOverdue}
          daysRemaining={daysRemaining}
          s={s}
          theme={theme}
        />
      </ScrollView>
    );
  }

  // ── Borrower view ────────────────────────────────────────────────────────────

  const projEntry = projections[selectedDaysLate];
  const headline = isOverdue ? 'Your payment is overdue' : 'If this payment is missed';
  const projData: IouLateScenario | null =
    projEntry !== undefined && projEntry !== 'error' ? projEntry : null;
  const projIsError = projEntry === 'error';
  const projIsLoading = projectionLoading && projEntry === undefined;

  return (
    <ScrollView contentContainerStyle={s.content} showsVerticalScrollIndicator={false}>

      {/* ── Header card ── */}
      <View style={[s.headerCard, isOverdue && s.headerCardOverdue]}>
        <Text style={[s.headline, isOverdue && { color: theme.negative }]}>{headline}</Text>
        <Text style={s.headerAmt}>{currency(payment.amount_cents)}</Text>
        <Text style={s.headerDate}>Due {formatDateLong(payment.due)}</Text>

        {isOverdue && daysOverdue !== null && (
          <View style={s.badgeRow}>
            <View style={[s.badge, s.badgeOverdue]}>
              <Text style={[s.badgeText, { color: theme.negative }]}>
                {daysOverdue === 0 ? 'Due today' : `${daysOverdue} day${daysOverdue !== 1 ? 's' : ''} overdue`}
              </Text>
            </View>
          </View>
        )}
        {!isOverdue && daysRemaining !== null && (
          <View style={s.badgeRow}>
            <View style={[s.badge, s.badgeDue]}>
              <Text style={s.badgeText}>
                {daysRemaining === 0
                  ? 'Due today'
                  : `${daysRemaining} day${daysRemaining !== 1 ? 's' : ''} remaining`}
              </Text>
            </View>
          </View>
        )}

        {payment.extension_status === 'requested' && (
          <View style={[s.badge, s.badgePending, { alignSelf: 'flex-start', marginTop: 8 }]}>
            <Text style={[s.badgeText, { color: theme.warning }]}>Extension pending approval</Text>
          </View>
        )}
        {payment.extension_status === 'approved' && !!payment.extension_requested_until && (
          <View style={[s.badge, s.badgeExtApproved, { alignSelf: 'flex-start', marginTop: 8 }]}>
            <Text style={[s.badgeText, { color: theme.positive }]}>
              {'Extended to '}
              {parseDateLocal(payment.extension_requested_until).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}
            </Text>
          </View>
        )}
        {payment.extension_status === 'denied' && (
          <View style={[s.badge, s.badgeOverdue, { alignSelf: 'flex-start', marginTop: 8 }]}>
            <Text style={[s.badgeText, { color: theme.negative }]}>Extension denied — original date applies</Text>
          </View>
        )}
      </View>

      {/* ── Guidance card ── */}
      <View style={s.guidanceCard}>
        {isOverdue ? (
          <>
            <Text style={s.guidanceTitle}>This payment is overdue</Text>
            <Text style={s.guidanceBody}>
              Paying sooner limits further score impact. The recorded outcome depends on when
              payment confirmation is processed — not when you initiate the payment.
            </Text>
          </>
        ) : (
          <>
            <Text style={s.guidanceTitle}>Before this becomes late</Text>
            <Text style={s.guidanceBody}>
              If you cannot make this payment, request an extension before it becomes late.
              Your lender must approve the new date. Missing the payment without an approved
              extension may affect your IOU Score.
            </Text>
          </>
        )}
      </View>

      {/* ── Actions ── */}
      {/* Before due date: extension is the primary path; pay early is secondary. */}
      {/* After due date: paying is the primary path; extension is secondary if still allowed. */}
      <View style={s.actionsCard}>
        {!isOverdue ? (
          <>
            {canRequestExtension && (
              <TouchableOpacity
                style={s.btnPrimary}
                onPress={handleRequestExtension}
                activeOpacity={0.85}
                accessibilityRole="button"
                accessibilityLabel="Request an extension"
              >
                <Text style={s.btnPrimaryText}>Request an extension</Text>
              </TouchableOpacity>
            )}
            {canPay && (
              <TouchableOpacity
                style={s.btnSecondary}
                onPress={handlePayNow}
                activeOpacity={0.85}
                accessibilityRole="button"
                accessibilityLabel={`Pay early — ${currency(payment.amount_cents)}`}
              >
                <Text style={s.btnSecondaryText}>Pay early</Text>
                <Text style={s.btnSecondaryAmt}>{currency(payment.amount_cents)}</Text>
              </TouchableOpacity>
            )}
          </>
        ) : (
          <>
            {canPay && (
              <TouchableOpacity
                style={[s.btnPrimary, s.btnPrimaryOverdue]}
                onPress={handlePayNow}
                activeOpacity={0.85}
                accessibilityRole="button"
                accessibilityLabel={`Pay overdue balance — ${currency(payment.amount_cents)}`}
              >
                <Text style={s.btnPrimaryText}>Pay overdue balance</Text>
                <Text style={s.btnPrimaryAmt}>{currency(payment.amount_cents)}</Text>
              </TouchableOpacity>
            )}
            {canRequestExtension && (
              <TouchableOpacity
                style={s.btnSecondary}
                onPress={handleRequestExtension}
                activeOpacity={0.85}
                accessibilityRole="button"
                accessibilityLabel="Request an extension"
              >
                <Text style={s.btnSecondaryText}>Request an extension</Text>
              </TouchableOpacity>
            )}
          </>
        )}

        {canRequestExtension && (
          <Text style={s.extensionCaveat}>
            Your due date changes only if the lender approves the request.
          </Text>
        )}

        {!canRequestExtension && payment.extension_status === 'requested' && (
          <View style={s.extensionPendingBox}>
            <Text style={s.extensionPendingText}>
              You have a pending extension request. The due date will not change until your lender approves it.
            </Text>
          </View>
        )}
      </View>

      {/* ── Late score projection (borrower-only) ── */}
      <View style={s.projectionSection}>
        <Text style={s.projectionSectionTitle}>Score impact if this payment is late</Text>
        <Text style={s.projectionSectionSub}>
          Select a lateness checkpoint. Values are estimates — the authoritative
          outcome is recorded when payment confirmation is processed.
        </Text>

        {/* Checkpoint pills */}
        <View style={s.checkpointRow}>
          {CHECKPOINTS.map(d => (
            <TouchableOpacity
              key={d}
              style={[s.checkpointBtn, selectedDaysLate === d && s.checkpointBtnActive]}
              onPress={() => setSelectedDaysLate(d)}
              accessibilityRole="button"
              accessibilityState={{ selected: selectedDaysLate === d }}
              accessibilityLabel={`${CHECKPOINT_LABELS[d]} late`}
            >
              <Text style={[s.checkpointBtnText, selectedDaysLate === d && s.checkpointBtnTextActive]}>
                {CHECKPOINT_LABELS[d]}
              </Text>
            </TouchableOpacity>
          ))}
        </View>

        {/* Projection card */}
        <View style={s.projCard}>
          {projIsLoading ? (
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, paddingVertical: 4 }}>
              <ActivityIndicator size="small" color={theme.negative} />
              <Text style={s.projUnavailText}>Loading estimate…</Text>
            </View>
          ) : projIsError ? (
            <View>
              <Text style={s.projUnavailTitle}>Estimate unavailable</Text>
              <Text style={s.projUnavailText}>Could not load the late-payment projection.</Text>
              <TouchableOpacity
                style={s.retryBtn}
                onPress={() => retryProjection(selectedDaysLate)}
                accessibilityRole="button"
              >
                <Text style={s.retryBtnText}>Retry</Text>
              </TouchableOpacity>
            </View>
          ) : !projData ? (
            <View style={{ paddingVertical: 4 }}>
              <ActivityIndicator size="small" color={theme.negative} />
            </View>
          ) : !projData.eligible ? (
            <Text style={s.projUnavailText}>
              {projData.explanation[0] ?? 'Projection not available for this payment.'}
            </Text>
          ) : (
            <LateProjectionCard
              data={projData}
              daysLate={selectedDaysLate}
              s={s}
              theme={theme}
            />
          )}
        </View>
      </View>

      {/* ── Collapsed disclosure ── */}
      <View style={s.disclosureSection}>
        <TouchableOpacity
          style={s.disclosureToggle}
          onPress={() => setDisclosureOpen(v => !v)}
          accessibilityRole="button"
          accessibilityState={{ expanded: disclosureOpen }}
        >
          <Text style={s.disclosureToggleText}>
            {`How late payments affect your score  ${disclosureOpen ? '↑' : '↓'}`}
          </Text>
        </TouchableOpacity>

        {disclosureOpen && (
          <View style={s.disclosureContent}>
            {[
              'Late penalties escalate based on how many days past due the payment is at the time it is confirmed, under Score v2.2 rules.',
              'Completion credit remains locked until the IOU is fully completed. A late payment does not unlock completion credit.',
              'Active exposure remains on your score while this IOU is open, regardless of lateness.',
              'Penalties that have already been recorded remain part of your history even after the IOU completes.',
              'An approved extension can establish a new due date. Lateness is then measured from the new date.',
            ].map((line, i) => (
              <Text key={i} style={s.disclosureLine}>{`· ${line}`}</Text>
            ))}
          </View>
        )}
      </View>

    </ScrollView>
  );
}

// ─── Late projection card (borrower-only) ─────────────────────────────────────

function LateProjectionCard({
  data,
  daysLate,
  s,
  theme,
}: {
  data: IouLateScenario;
  daysLate: DaysLate;
  s: ReturnType<typeof makeS>;
  theme: ReturnType<typeof useAppTheme>;
}) {
  const ceiling = data.payNowProjectedScore - data.currentScore;
  const fillRatio = ceiling > 0 ? data.opportunityLossVsPayNow / ceiling : 0;
  const fillPath = halfDonutFillPath(fillRatio);
  const daysLabel = daysLate === 1 ? '1 day' : `${daysLate} days`;

  return (
    <View>
      {/* Red gauge — same geometry as green estimate gauge */}
      <View style={s.gaugeWrap}>
        <Svg width={G_W} height={G_H} viewBox={`0 0 ${G_W} ${G_H}`}>
          {/* Track */}
          <Path
            d={G_TRACK_PATH}
            stroke={theme.isDark ? '#2A2A2A' : '#E5E7EB'}
            strokeWidth={G_SW}
            fill="none"
            strokeLinecap="butt"
          />
          {/* Fill — red, representing risk / opportunity lost */}
          {!!fillPath && (
            <Path
              d={fillPath}
              stroke={theme.negative}
              strokeWidth={G_SW}
              fill="none"
              strokeLinecap="round"
            />
          )}
          {/* Primary metric — points lost vs. paying now */}
          <SvgText
            x={G_CX}
            y={68}
            textAnchor="middle"
            fontSize={26}
            fontWeight="900"
            fill={theme.negative}
          >
            {`−${data.opportunityLossVsPayNow}`}
          </SvgText>
          <SvgText
            x={G_CX}
            y={85}
            textAnchor="middle"
            fontSize={11}
            fontWeight="600"
            fill={theme.isDark ? '#6B7280' : '#9CA3AF'}
          >
            potential points
          </SvgText>
        </Svg>
      </View>

      {/* Subtitle */}
      <Text style={s.projSubtitle}>
        {`Estimated if this payment is successfully confirmed ${daysLabel} late`}
      </Text>

      {/* Supporting rows */}
      <View style={s.projRows}>
        <View style={s.projRow}>
          <Text style={s.projLabel}>Estimated Score</Text>
          <View style={s.projRight}>
            <Text style={s.projFrom}>{data.currentScore}</Text>
            <Text style={s.projArrow}> → </Text>
            <Text style={[s.projTo, { color: theme.negative }]}>{data.projectedScore}</Text>
            <Text style={[s.projDelta, { color: theme.negative }]}>
              {data.scoreDelta <= 0 ? `  ${data.scoreDelta}` : `  +${data.scoreDelta}`}
            </Text>
          </View>
        </View>

        <View style={s.projRow}>
          <Text style={s.projLabel}>Estimated Visible Trust</Text>
          <View style={s.projRight}>
            <Text style={s.projFrom}>{data.currentVisibleTrust}</Text>
            <Text style={s.projArrow}> → </Text>
            <Text style={[s.projTo, { color: theme.negative }]}>{data.projectedVisibleTrust}</Text>
            <Text style={[s.projDelta, { color: theme.negative }]}>
              {data.visibleTrustDelta <= 0 ? `  ${data.visibleTrustDelta}` : `  +${data.visibleTrustDelta}`}
            </Text>
          </View>
        </View>

        {data.additionalLatePenalty > 0 && (
          <View style={s.projRow}>
            <Text style={s.projLabel}>Additional late penalty</Text>
            <Text style={[s.projDetailValue, { color: theme.negative }]}>−{data.additionalLatePenalty} pts</Text>
          </View>
        )}

        {data.completionCreditStillLocked > 0 && (
          <View style={s.projRow}>
            <Text style={s.projLabel}>Completion credit locked</Text>
            <Text style={s.projDetailValue}>
              {data.completionCreditStillLocked} pts while unpaid
            </Text>
          </View>
        )}

        {data.currentExposure > 0 && (
          <View style={[s.projRow, { borderBottomWidth: 0 }]}>
            <Text style={s.projLabel}>Active exposure</Text>
            <Text style={s.projDetailValue}>
              −{data.currentExposure} pts while unpaid
            </Text>
          </View>
        )}
      </View>

      {/* Explanation lines */}
      {data.explanation.length > 0 && (
        <View style={s.projExplainBlock}>
          {data.explanation.map((line, i) => (
            <Text key={i} style={s.projExplainLine}>{`· ${line}`}</Text>
          ))}
        </View>
      )}
    </View>
  );
}

// ─── Lender view ──────────────────────────────────────────────────────────────

function LenderView({
  payment,
  isOverdue,
  daysOverdue,
  daysRemaining,
  s,
  theme,
}: {
  payment: PaymentRow;
  isOverdue: boolean;
  daysOverdue: number | null;
  daysRemaining: number | null;
  s: ReturnType<typeof makeS>;
  theme: ReturnType<typeof useAppTheme>;
}) {
  return (
    <>
      <View style={[s.headerCard, isOverdue && s.headerCardOverdue]}>
        <Text style={[s.headline, isOverdue && { color: theme.negative }]}>
          {isOverdue ? 'Payment is overdue' : 'Upcoming payment'}
        </Text>
        <Text style={s.headerAmt}>{currency(payment.amount_cents)}</Text>
        <Text style={s.headerDate}>Due {formatDateLong(payment.due)}</Text>
        {isOverdue && daysOverdue !== null && (
          <View style={s.badgeRow}>
            <View style={[s.badge, s.badgeOverdue]}>
              <Text style={[s.badgeText, { color: theme.negative }]}>
                {daysOverdue === 0 ? 'Due today' : `${daysOverdue} day${daysOverdue !== 1 ? 's' : ''} overdue`}
              </Text>
            </View>
          </View>
        )}
        {!isOverdue && daysRemaining !== null && (
          <View style={s.badgeRow}>
            <View style={[s.badge, s.badgeDue]}>
              <Text style={s.badgeText}>
                {daysRemaining === 0 ? 'Due today' : `${daysRemaining} day${daysRemaining !== 1 ? 's' : ''} remaining`}
              </Text>
            </View>
          </View>
        )}
      </View>

      <View style={s.guidanceCard}>
        <Text style={s.guidanceTitle}>Score projections are private to the borrower</Text>
        <Text style={s.guidanceBody}>
          Impact estimates and score projections for this payment are only visible to the
          borrower. You can view the borrower's public trust level from their profile.
        </Text>
      </View>

      {payment.extension_status === 'requested' && !!payment.extension_requested_until && (
        <View style={s.lenderExtCard}>
          <Text style={s.lenderExtTitle}>Extension requested</Text>
          <Text style={s.lenderExtBody}>
            The borrower has requested an extension until{' '}
            {formatDateLong(payment.extension_requested_until)}.
            Go to the Payments tab to approve or deny.
          </Text>
        </View>
      )}
    </>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const makeS = (t: AppTheme) => StyleSheet.create({
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  errorText: { fontSize: 14, color: t.textMuted, fontWeight: '500' },

  content: { padding: 16, paddingBottom: 48 },

  // ── Header card ──────────────────────────────────────────────────────────────
  headerCard: {
    backgroundColor: t.surface,
    borderRadius: 16,
    padding: 18,
    borderWidth: 1,
    borderColor: t.border,
    marginBottom: 12,
  },
  headerCardOverdue: {
    borderColor: t.negativeBorder,
    backgroundColor: t.isDark ? '#0A0202' : '#FFF5F5',
  },
  headline: {
    fontSize: 11,
    fontWeight: '700',
    color: t.textMuted,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginBottom: 10,
  },
  headerAmt: {
    fontSize: 32,
    fontWeight: '900',
    color: t.textPrimary,
    letterSpacing: -0.5,
    marginBottom: 4,
  },
  headerDate: {
    fontSize: 14,
    fontWeight: '500',
    color: t.textMuted,
    marginBottom: 8,
  },
  badgeRow: { flexDirection: 'row', gap: 8, marginTop: 2 },
  badge: {
    alignSelf: 'flex-start',
    borderRadius: 8,
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderWidth: 1,
  },
  badgeDue: {
    backgroundColor: t.isDark ? '#111111' : '#F3F4F6',
    borderColor: t.isDark ? '#262626' : '#E5E7EB',
  },
  badgeText: { fontSize: 12, fontWeight: '700', color: t.textSecondary },
  badgeOverdue: {
    backgroundColor: t.negativeSurface,
    borderColor: t.isDark ? '#3A0D0D' : '#FECACA',
  },
  badgePending: {
    backgroundColor: t.isDark ? '#1A1000' : '#FEF3C7',
    borderColor: t.isDark ? '#2A1400' : '#FDE68A',
  },
  badgeExtApproved: {
    backgroundColor: t.positiveSurface,
    borderColor: t.isDark ? '#0D3A15' : '#BBF7D0',
  },

  // ── Guidance card ─────────────────────────────────────────────────────────────
  guidanceCard: {
    backgroundColor: t.surfaceMuted,
    borderRadius: 14,
    padding: 16,
    borderWidth: 1,
    borderColor: t.border,
    marginBottom: 12,
  },
  guidanceTitle: {
    fontSize: 13,
    fontWeight: '800',
    color: t.textPrimary,
    marginBottom: 6,
  },
  guidanceBody: {
    fontSize: 13,
    fontWeight: '500',
    color: t.textSecondary,
    lineHeight: 20,
  },

  // ── Actions ───────────────────────────────────────────────────────────────────
  actionsCard: { marginBottom: 12, gap: 10 },
  btnPrimary: {
    backgroundColor: '#1B5E20',
    borderRadius: 14,
    paddingVertical: 14,
    paddingHorizontal: 18,
    alignItems: 'center',
  },
  btnPrimaryOverdue: {
    backgroundColor: t.isDark ? '#7F1D1D' : '#DC2626',
  },
  btnPrimaryText: { color: '#fff', fontWeight: '800', fontSize: 15 },
  btnPrimaryAmt: {
    color: 'rgba(255,255,255,0.7)',
    fontWeight: '600',
    fontSize: 13,
    marginTop: 2,
  },
  btnSecondary: {
    backgroundColor: t.surfaceMuted,
    borderRadius: 14,
    paddingVertical: 13,
    paddingHorizontal: 18,
    alignItems: 'center',
    borderWidth: 1,
    borderColor: t.border,
  },
  btnSecondaryText: { color: t.textSecondary, fontWeight: '700', fontSize: 15 },
  btnSecondaryAmt: {
    color: t.textMuted,
    fontWeight: '500',
    fontSize: 13,
    marginTop: 2,
  },
  extensionCaveat: {
    fontSize: 12,
    fontWeight: '500',
    color: t.textMuted,
    lineHeight: 18,
    textAlign: 'center',
    paddingHorizontal: 4,
  },
  extensionPendingBox: {
    backgroundColor: t.isDark ? '#1A1000' : '#FEF3C7',
    borderRadius: 10,
    padding: 12,
    borderWidth: 1,
    borderColor: t.isDark ? '#2A1400' : '#FDE68A',
  },
  extensionPendingText: {
    fontSize: 13,
    fontWeight: '500',
    color: t.isDark ? t.warning : '#92400E',
    lineHeight: 19,
  },

  // ── Projection section ────────────────────────────────────────────────────────
  projectionSection: { marginBottom: 12 },
  projectionSectionTitle: {
    fontSize: 13,
    fontWeight: '800',
    color: t.textPrimary,
    marginBottom: 4,
  },
  projectionSectionSub: {
    fontSize: 12,
    fontWeight: '500',
    color: t.textMuted,
    lineHeight: 18,
    marginBottom: 12,
  },

  // Checkpoint pills
  checkpointRow: { flexDirection: 'row', gap: 6, marginBottom: 10 },
  checkpointBtn: {
    flex: 1,
    paddingVertical: 9,
    alignItems: 'center',
    borderRadius: 10,
    backgroundColor: t.surfaceMuted,
    borderWidth: 1,
    borderColor: t.border,
  },
  checkpointBtnActive: {
    backgroundColor: t.isDark ? '#1A0505' : '#FEF2F2',
    borderColor: t.isDark ? '#3A0D0D' : '#FECACA',
  },
  checkpointBtnText: { fontSize: 11, fontWeight: '700', color: t.textMuted },
  checkpointBtnTextActive: { color: t.isDark ? '#FF6B6B' : '#991B1B' },

  // Projection card container
  projCard: {
    backgroundColor: t.surface,
    borderRadius: 14,
    padding: 14,
    borderWidth: 1,
    borderColor: t.isDark ? '#2A1818' : '#FEE2E2',
  },
  projUnavailTitle: {
    fontSize: 14,
    fontWeight: '800',
    color: t.textSecondary,
    marginBottom: 6,
  },
  projUnavailText: {
    fontSize: 13,
    fontWeight: '500',
    color: t.textMuted,
    lineHeight: 19,
  },
  retryBtn: { marginTop: 10, alignSelf: 'flex-start' },
  retryBtnText: {
    fontSize: 13,
    fontWeight: '700',
    color: t.isDark ? t.brandBright : t.brand,
  },

  // Gauge
  gaugeWrap: { alignItems: 'center', marginVertical: 8 },

  // Projection subtitle
  projSubtitle: {
    fontSize: 11,
    fontWeight: '500',
    color: t.textMuted,
    textAlign: 'center',
    marginBottom: 14,
    lineHeight: 16,
  },

  // Supporting rows
  projRows: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: t.divider,
  },
  projRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 8,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: t.divider,
  },
  projLabel: { fontSize: 12, fontWeight: '600', color: t.textSecondary, flex: 1 },
  projRight: { flexDirection: 'row', alignItems: 'baseline' },
  projFrom: { fontSize: 12, fontWeight: '600', color: t.textMuted },
  projArrow: { fontSize: 11, fontWeight: '500', color: t.textMuted, marginHorizontal: 2 },
  projTo: { fontSize: 12, fontWeight: '800' },
  projDelta: { fontSize: 11, fontWeight: '700', marginLeft: 2 },
  projDetailValue: { fontSize: 12, fontWeight: '700', color: t.textSecondary },

  // Explanation lines
  projExplainBlock: { marginTop: 10, gap: 4 },
  projExplainLine: {
    fontSize: 11,
    fontWeight: '500',
    color: t.textMuted,
    lineHeight: 17,
  },

  // ── Disclosure ────────────────────────────────────────────────────────────────
  disclosureSection: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: t.divider,
    paddingTop: 14,
  },
  disclosureToggle: { paddingBottom: 2 },
  disclosureToggleText: {
    fontSize: 13,
    fontWeight: '700',
    color: t.isDark ? t.brandBright : t.brand,
  },
  disclosureContent: { marginTop: 10, gap: 8 },
  disclosureLine: {
    fontSize: 12,
    fontWeight: '500',
    color: t.textSecondary,
    lineHeight: 19,
  },

  // ── Lender-only ───────────────────────────────────────────────────────────────
  lenderExtCard: {
    backgroundColor: t.isDark ? '#1A1000' : '#FFFBEB',
    borderRadius: 12,
    padding: 14,
    borderWidth: 1,
    borderColor: t.isDark ? '#2A1400' : '#FDE68A',
    marginTop: 4,
  },
  lenderExtTitle: {
    fontSize: 13,
    fontWeight: '800',
    color: t.isDark ? t.warning : '#92400E',
    marginBottom: 6,
  },
  lenderExtBody: {
    fontSize: 13,
    fontWeight: '500',
    color: t.isDark ? t.warning : '#78350F',
    lineHeight: 19,
  },
});

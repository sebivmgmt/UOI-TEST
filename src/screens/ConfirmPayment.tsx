// src/screens/ConfirmPayment.tsx

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  View,
  Text,
  Alert,
  StyleSheet,
  TouchableOpacity,
  ActivityIndicator,
  ScrollView,
} from 'react-native';
import { supabase } from '../supabase';

const GREEN = '#77B777';
const GREEN_DARK = '#5F9F5F';
const BLUE = '#3b82f6';
const ORANGE = '#f59e0b';
const BG = '#F5F7F9';

const currency = (cents: number) => `$${(cents / 100).toFixed(2)}`;

type PaymentContext = {
  payment_number?: number | null;
  due_date?: string | null;
  due_at?: string | null;
  scheduled_at?: string | null;
  iou_title?: string | null;
  total_installments?: number | null;
  status?: string | null;
  paid_at?: string | null;
};

type BankConnectionMeta = {
  linked: boolean;
  providerLabel: string | null;
  accountMask: string | null;
  achStatus: string | null; // null = column absent or unset; "ready" = ACH active
};

export default function ConfirmPayment({ route, navigation }: any) {
  const paymentId: string | undefined = route?.params?.paymentId;
  const amount: number = Number(route?.params?.amount ?? 0);
  const iouId: string | undefined =
    route?.params?.iouId ??
    route?.params?.iou_id ??
    route?.params?.loanId ??
    route?.params?.loan_id;

  const [submitting, setSubmitting] = useState(false);
  const [loadingMeta, setLoadingMeta] = useState(true);
  const [loadingBankMeta, setLoadingBankMeta] = useState(true);

  const [paymentMeta, setPaymentMeta] = useState<PaymentContext | null>(null);
  const [bankMeta, setBankMeta] = useState<BankConnectionMeta | null>(null);

  const amountLabel = useMemo(() => currency(amount || 0), [amount]);

  const dueRaw = useMemo(
    () => paymentMeta?.due_date ?? paymentMeta?.due_at ?? paymentMeta?.scheduled_at ?? null,
    [paymentMeta]
  );

  const dueDateObj = useMemo(() => {
    if (!dueRaw) return null;
    const d = new Date(dueRaw);
    return Number.isNaN(d.getTime()) ? null : d;
  }, [dueRaw]);

  const dueLabel = useMemo(() => {
    if (!dueRaw) return '—';
    if (!dueDateObj) return String(dueRaw).slice(0, 10);
    return dueDateObj.toLocaleDateString();
  }, [dueRaw, dueDateObj]);

  const paymentTiming = useMemo(() => {
    if (!dueDateObj) return 'unknown';
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const due = new Date(dueDateObj.getFullYear(), dueDateObj.getMonth(), dueDateObj.getDate());
    if (today.getTime() < due.getTime()) return 'early';
    if (today.getTime() === due.getTime()) return 'on_time';
    return 'late';
  }, [dueDateObj]);

  const timingBadge = useMemo(() => {
    if (paymentTiming === 'early') return { label: 'EARLY', bg: '#EAF8EA', color: GREEN_DARK };
    if (paymentTiming === 'on_time') return { label: 'DUE TODAY', bg: '#EEF4FF', color: BLUE };
    if (paymentTiming === 'late') return { label: 'LATE', bg: '#FFF3E0', color: ORANGE };
    return null;
  }, [paymentTiming]);

  const effectiveStatus = useMemo(() => {
    if (paymentMeta?.paid_at) return 'paid';
    return paymentMeta?.status ?? null;
  }, [paymentMeta]);

  const statusBadge = useMemo(() => {
    if (effectiveStatus === 'paid') return { label: 'PAID', bg: '#EAF8EA', color: GREEN_DARK };
    if (effectiveStatus === 'pending_confirmation') return { label: 'PENDING CONFIRMATION', bg: '#EEF4FF', color: BLUE };
    if (effectiveStatus === 'late') return { label: 'LATE', bg: '#FFF3E0', color: ORANGE };
    return null;
  }, [effectiveStatus]);

  const bankLinked = !!bankMeta?.linked;

  // Null or missing ach_status is treated as not ready — fail closed.
  const achReady = useMemo(
    () => bankMeta?.achStatus === 'ready',
    [bankMeta]
  );

  const bankStatusText = useMemo(() => {
    if (loadingBankMeta) return 'Checking bank connection…';
    if (!bankMeta?.linked) return 'No bank account connected yet.';
    if (!achReady) return 'Bank connected but not ready for payments yet.';
    const provider = bankMeta.providerLabel || 'Bank';
    const mask = bankMeta.accountMask ? ` ···· ${bankMeta.accountMask}` : '';
    return `${provider}${mask}`;
  }, [bankMeta, loadingBankMeta, achReady]);

  const primaryButtonLabel = useMemo(() => {
    if (effectiveStatus === 'paid') return 'Already paid';
    if (effectiveStatus === 'pending_confirmation') return 'Already pending';
    if (!bankLinked) return 'Connect bank account';
    if (!achReady) return 'Bank connection not ready';
    return 'Submit manual early payment';
  }, [effectiveStatus, bankLinked, achReady]);

  // ── Data loading ──────────────────────────────────────────────

  const loadPaymentMeta = useCallback(async () => {
    if (!paymentId) { setLoadingMeta(false); return; }
    setLoadingMeta(true);

    const selects = [
      'payment_number, due_date, status, paid_at, ious!payments_iou_id_fkey(title, total_installments)',
      'payment_number, due_at, status, paid_at, ious!payments_iou_id_fkey(title, total_installments)',
      'payment_number, scheduled_at, status, paid_at, ious!payments_iou_id_fkey(title, total_installments)',
      'payment_number, due_date, status, paid_at',
      'payment_number, due_at, status, paid_at',
      'payment_number, scheduled_at, status, paid_at',
    ];

    for (const sel of selects) {
      const { data, error } = await supabase.from('payments').select(sel).eq('id', paymentId).single();
      if (!error && data) {
        setPaymentMeta({
          payment_number: (data as any).payment_number ?? null,
          due_date: (data as any).due_date ?? null,
          due_at: (data as any).due_at ?? null,
          scheduled_at: (data as any).scheduled_at ?? null,
          status: (data as any).status ?? null,
          paid_at: (data as any).paid_at ?? null,
          iou_title: (data as any).ious?.title ?? null,
          total_installments: (data as any).ious?.total_installments ?? null,
        });
        setLoadingMeta(false);
        return;
      }
    }
    setPaymentMeta(null);
    setLoadingMeta(false);
  }, [paymentId]);

  const loadBankMeta = useCallback(async () => {
    setLoadingBankMeta(true);
    try {
      const { data: auth } = await supabase.auth.getUser();
      const me = auth.user?.id;
      if (!me) { setBankMeta(null); setLoadingBankMeta(false); return; }

      const selectAttempts = [
        'bank_linked, bank_provider, bank_account_mask, ach_status',
        'plaid_linked, bank_provider, bank_account_mask, ach_status',
        'plaid_linked, plaid_institution_name, bank_account_mask',
        'plaid_linked, plaid_institution_name, account_mask',
      ];

      for (const sel of selectAttempts) {
        const { data, error } = await supabase.from('profiles').select(sel).eq('id', me).single();
        if (!error && data) {
          const raw = data as any;
          setBankMeta({
            linked: !!(raw.bank_linked ?? raw.plaid_linked),
            providerLabel: raw.bank_provider ?? raw.plaid_institution_name ?? 'Bank',
            accountMask: raw.bank_account_mask ?? raw.account_mask ?? null,
            achStatus: typeof raw.ach_status === 'string' ? raw.ach_status : null,
          });
          setLoadingBankMeta(false);
          return;
        }
      }
      setBankMeta({ linked: false, providerLabel: null, accountMask: null, achStatus: null });
    } catch {
      setBankMeta({ linked: false, providerLabel: null, accountMask: null, achStatus: null });
    } finally {
      setLoadingBankMeta(false);
    }
  }, []);

  useEffect(() => {
    void loadPaymentMeta();
    void loadBankMeta();
  }, [loadPaymentMeta, loadBankMeta]);

  // ── Actions ───────────────────────────────────────────────────

  const openBankLink = () => {
    const state = navigation?.getState?.();
    const routeNames: string[] = Array.isArray(state?.routeNames) ? state.routeNames : [];
    if (routeNames.includes('LinkBank')) {
      navigation.navigate('LinkBank', { returnTo: 'ConfirmPayment', paymentId, iouId });
      return;
    }
    if (routeNames.includes('BankLink')) {
      navigation.navigate('BankLink', { returnTo: 'ConfirmPayment', paymentId, iouId });
      return;
    }
    Alert.alert('Bank link unavailable', 'The bank connection screen is not set up yet.');
  };

  const handleStartManualPayment = async () => {
    if (!paymentId) {
      Alert.alert('Missing payment', 'No payment was provided for this screen.');
      return;
    }

    if (effectiveStatus === 'paid') {
      Alert.alert('Already paid', 'This payment is already marked as paid.', [{ text: 'OK' }]);
      return;
    }

    if (effectiveStatus === 'pending_confirmation') {
      Alert.alert(
        'Already pending',
        'This payment has already been submitted and is waiting for lender confirmation.',
        [{ text: 'OK' }]
      );
      return;
    }

    try {
      setSubmitting(true);

      const { data: auth } = await supabase.auth.getUser();
      const me = auth.user?.id;
      if (!me) throw new Error('Not signed in.');

      const { error } = await supabase.rpc('claim_payment', { p_payment_id: paymentId, p_actor: me });
      if (error) throw error;

      await loadPaymentMeta();

      Alert.alert(
        'Manual payment submitted',
        'The lender will be notified to confirm receipt of your early payment.',
        [{
          text: 'OK',
          onPress: () => {
            if (iouId) {
              navigation.reset({
                index: 1,
                routes: [{ name: 'Home' }, { name: 'LoanDetail', params: { iouId } }],
              });
            } else {
              navigation.reset({ index: 0, routes: [{ name: 'Home' }] });
            }
          },
        }]
      );
    } catch (e: any) {
      Alert.alert('Payment failed', e?.message ?? 'Could not submit payment.');
    } finally {
      setSubmitting(false);
    }
  };

  const onPrimaryPress = () => {
    if (!bankLinked) { openBankLink(); return; }
    if (!achReady) {
      Alert.alert(
        'Bank Not Ready',
        'Your bank account is connected but not yet ready for payments. Complete the bank setup to continue.',
        [
          { text: 'Cancel', style: 'cancel' },
          { text: 'Set up bank', onPress: openBankLink },
        ]
      );
      return;
    }
    void handleStartManualPayment();
  };

  // ── Render ────────────────────────────────────────────────────

  return (
    <ScrollView style={s.screen} contentContainerStyle={s.content} showsVerticalScrollIndicator={false}>
      <View style={s.card}>
        <Text style={s.title}>Manual Early Payment</Text>

        {loadingMeta ? (
          <View style={s.metaLoadingWrap}>
            <ActivityIndicator />
            <Text style={s.metaLoadingText}>Loading payment details…</Text>
          </View>
        ) : (
          <>
            {(timingBadge || statusBadge) && (
              <View style={s.topBadgeRow}>
                {timingBadge && (
                  <View style={[s.badge, { backgroundColor: timingBadge.bg }]}>
                    <Text style={[s.badgeText, { color: timingBadge.color }]}>{timingBadge.label}</Text>
                  </View>
                )}
                {statusBadge && (
                  <View style={[s.badge, { backgroundColor: statusBadge.bg }]}>
                    <Text style={[s.badgeText, { color: statusBadge.color }]}>{statusBadge.label}</Text>
                  </View>
                )}
              </View>
            )}

            {!!paymentMeta?.iou_title && (
              <View style={s.section}>
                <Text style={s.label}>Loan</Text>
                <Text style={s.value}>{paymentMeta.iou_title}</Text>
              </View>
            )}

            {typeof paymentMeta?.payment_number === 'number' && (
              <View style={s.section}>
                <Text style={s.label}>Payment</Text>
                <Text style={s.value}>
                  #{paymentMeta.payment_number}
                  {typeof paymentMeta?.total_installments === 'number' && paymentMeta.total_installments > 0
                    ? ` of ${paymentMeta.total_installments}`
                    : ''}
                </Text>
              </View>
            )}

            <View style={s.section}>
              <Text style={s.label}>Due date</Text>
              <Text style={s.value}>{dueLabel}</Text>
            </View>
          </>
        )}

        <View style={s.section}>
          <Text style={s.label}>Amount</Text>
          <Text style={s.amount}>{amountLabel}</Text>
        </View>

        <View style={s.noteCard}>
          <Text style={s.noteCardTitle}>Outside AutoPay</Text>
          <Text style={s.noteCardText}>
            AutoPay is already scheduled to handle this payment on the due date. This is a manual early payment — it is processed outside AutoPay and requires lender confirmation before it counts as paid.
          </Text>
        </View>

        <View style={s.bankCard}>
          <Text style={s.bankCardTitle}>Bank connection</Text>
          {loadingBankMeta ? (
            <ActivityIndicator size="small" style={{ marginTop: 6 }} />
          ) : (
            <>
              <Text style={[
                s.bankCardText,
                bankLinked && achReady && { color: GREEN_DARK },
                bankLinked && !achReady && { color: ORANGE },
              ]}>
                {bankStatusText}
              </Text>
              {!bankLinked && (
                <TouchableOpacity style={s.connectBtn} onPress={openBankLink} activeOpacity={0.9}>
                  <Text style={s.connectBtnText}>Connect bank account</Text>
                </TouchableOpacity>
              )}
              {bankLinked && !achReady && (
                <TouchableOpacity style={[s.connectBtn, { backgroundColor: ORANGE }]} onPress={openBankLink} activeOpacity={0.9}>
                  <Text style={s.connectBtnText}>Complete bank setup</Text>
                </TouchableOpacity>
              )}
            </>
          )}
        </View>

        <TouchableOpacity
          style={[
            s.primaryBtn,
            (submitting || effectiveStatus === 'paid' || effectiveStatus === 'pending_confirmation') && s.btnDisabled,
          ]}
          onPress={onPrimaryPress}
          disabled={submitting || effectiveStatus === 'paid' || effectiveStatus === 'pending_confirmation'}
          activeOpacity={0.9}
        >
          {submitting ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={s.primaryBtnText}>{primaryButtonLabel}</Text>
          )}
        </TouchableOpacity>

        <TouchableOpacity
          style={s.secondaryBtn}
          onPress={() => navigation.goBack()}
          disabled={submitting}
        >
          <Text style={s.secondaryBtnText}>Cancel</Text>
        </TouchableOpacity>
      </View>
    </ScrollView>
  );
}

const s = StyleSheet.create({
  screen: { flex: 1, backgroundColor: BG },
  content: { padding: 16, justifyContent: 'center', flexGrow: 1 },

  card: {
    backgroundColor: '#fff',
    borderRadius: 18,
    padding: 18,
    borderWidth: 1,
    borderColor: '#EAEAEA',
  },

  title: {
    fontSize: 24,
    fontWeight: '800',
    color: '#111',
    marginBottom: 4,
  },

  metaLoadingWrap: {
    marginTop: 18,
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: 14,
  },

  metaLoadingText: {
    marginTop: 10,
    color: '#666',
  },

  topBadgeRow: {
    flexDirection: 'row',
    gap: 8,
    marginTop: 16,
    flexWrap: 'wrap',
  },

  badge: {
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 5,
    alignSelf: 'flex-start',
  },

  badgeText: {
    fontWeight: '800',
    fontSize: 12,
  },

  section: {
    marginTop: 16,
  },

  label: {
    fontSize: 12,
    fontWeight: '800',
    textTransform: 'uppercase',
    color: '#666',
    marginBottom: 4,
  },

  amount: {
    fontSize: 36,
    fontWeight: '900',
    color: GREEN,
  },

  value: {
    fontSize: 16,
    color: '#111',
    fontWeight: '600',
  },

  noteCard: {
    marginTop: 18,
    backgroundColor: '#F0FDF4',
    borderRadius: 12,
    padding: 14,
    borderWidth: 1,
    borderColor: '#BBF7D0',
  },

  noteCardTitle: {
    color: '#15803D',
    fontSize: 13,
    fontWeight: '800',
    textTransform: 'uppercase',
    letterSpacing: 0.4,
    marginBottom: 6,
  },
  noteCardText: {
    color: '#15803D',
    fontSize: 14,
    fontWeight: '600',
    lineHeight: 20,
  },

  bankCard: {
    marginTop: 18,
    backgroundColor: '#F8FBFF',
    borderRadius: 12,
    padding: 14,
    borderWidth: 1,
    borderColor: '#D9E7FF',
  },

  bankCardTitle: {
    fontSize: 12,
    fontWeight: '800',
    textTransform: 'uppercase',
    color: '#1D4ED8',
    marginBottom: 6,
  },

  bankCardText: {
    fontSize: 15,
    fontWeight: '700',
    color: '#475467',
  },

  connectBtn: {
    marginTop: 12,
    alignSelf: 'flex-start',
    backgroundColor: BLUE,
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 10,
  },

  connectBtnText: {
    color: '#fff',
    fontWeight: '800',
    fontSize: 14,
  },

  primaryBtn: {
    marginTop: 20,
    height: 54,
    borderRadius: 14,
    backgroundColor: GREEN,
    alignItems: 'center',
    justifyContent: 'center',
  },

  btnDisabled: {
    opacity: 0.6,
  },

  primaryBtnText: {
    color: '#fff',
    fontSize: 17,
    fontWeight: '800',
  },

  secondaryBtn: {
    marginTop: 10,
    height: 50,
    borderRadius: 14,
    backgroundColor: '#EEF2F5',
    alignItems: 'center',
    justifyContent: 'center',
  },

  secondaryBtnText: {
    color: '#222',
    fontSize: 16,
    fontWeight: '700',
  },
});

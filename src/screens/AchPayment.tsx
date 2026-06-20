// src/screens/AchPayment.tsx

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

const parseDateLocal = (s: string): Date => {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, m - 1, d);
};

type BankMeta = {
  ach_status: string | null;
  bank_provider: string | null;
  bank_name: string | null;
  account_mask: string | null;
};

type AchStage = 'idle' | 'initiating' | 'settling' | 'done' | 'error';

export default function AchPayment({ route, navigation }: any) {
  const paymentId: string | undefined = route?.params?.paymentId;
  const amount: number = Number(route?.params?.amount ?? 0);
  const due: string = route?.params?.due ?? '';
  const iouId: string | undefined =
    route?.params?.iouId ?? route?.params?.iou_id;

  const [bankMeta, setBankMeta] = useState<BankMeta | null>(null);
  const [loadingBank, setLoadingBank] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [achStage, setAchStage] = useState<AchStage>('idle');

  const dueDateObj = useMemo(() => {
    if (!due) return null;
    return parseDateLocal(due);
  }, [due]);

  const isEarly = useMemo(() => {
    if (!dueDateObj) return false;
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    return today.getTime() < dueDateObj.getTime();
  }, [dueDateObj]);

  const dueLabel = useMemo(() => {
    if (!dueDateObj) return due || '—';
    return dueDateObj.toLocaleDateString(undefined, {
      month: 'long',
      day: 'numeric',
      year: 'numeric',
    });
  }, [due, dueDateObj]);

  const isDevFixture = bankMeta?.bank_provider === 'dev_fixture';
  const achReady = bankMeta?.ach_status === 'ready';

  const bankReadable = useMemo(() => {
    if (!bankMeta) return '—';
    const name = bankMeta.bank_name ?? bankMeta.bank_provider ?? 'Bank';
    const mask = bankMeta.account_mask ? ` ···· ${bankMeta.account_mask}` : '';
    return `${name}${mask}`;
  }, [bankMeta]);

  // ── Load bank meta ────────────────────────────────────────────────────────

  const loadBankMeta = useCallback(async () => {
    setLoadingBank(true);
    try {
      const {
        data: { user },
      } = await supabase.auth.getUser();
      if (!user) {
        setBankMeta(null);
        return;
      }

      const attempts = [
        'ach_status, bank_provider, bank_name, bank_account_mask',
        'ach_status, bank_provider, bank_account_mask',
        'ach_status, bank_provider',
      ];

      for (const sel of attempts) {
        const { data, error } = await supabase
          .from('profiles')
          .select(sel)
          .eq('id', user.id)
          .single();
        if (!error && data) {
          const r = data as any;
          setBankMeta({
            ach_status: typeof r.ach_status === 'string' ? r.ach_status : null,
            bank_provider: r.bank_provider ?? null,
            bank_name: r.bank_name ?? null,
            account_mask: r.bank_account_mask ?? null,
          });
          return;
        }
      }
      setBankMeta(null);
    } finally {
      setLoadingBank(false);
    }
  }, []);

  useEffect(() => {
    void loadBankMeta();
  }, [loadBankMeta]);

  // ── Navigate back to IOU detail after completion ──────────────────────────

  const navigateAfterPay = () => {
    if (iouId) {
      navigation.reset({
        index: 1,
        routes: [
          { name: 'Home' },
          { name: 'LoanDetail', params: { iouId, direction: 'out' } },
        ],
      });
    } else {
      navigation.reset({ index: 0, routes: [{ name: 'Home' }] });
    }
  };

  // ── Confirm handler ───────────────────────────────────────────────────────

  const handleConfirm = async () => {
    if (!paymentId) {
      Alert.alert('Error', 'Missing payment reference.');
      return;
    }
    if (!achReady) {
      Alert.alert('Not Ready', 'Your bank account is not ready for ACH payments.');
      return;
    }

    setSubmitting(true);

    try {
      // ── Step A: initiate_ach_payment ───────────────────────────────────────
      setAchStage('initiating');

      const { data: initiateData, error: initiateError } = await supabase.rpc(
        'initiate_ach_payment',
        { p_payment_id: paymentId }
      );

      if (initiateError) {
        if (__DEV__) {
          console.log('[AchPayment] initiate_ach_payment error', {
            payment_id_suffix: paymentId.slice(-6),
            message: initiateError.message,
            code: (initiateError as any).code ?? null,
          });
        }
        throw new Error(initiateError.message);
      }

      const initiateRow = Array.isArray(initiateData)
        ? (initiateData[0] ?? null)
        : initiateData;

      if (__DEV__) {
        console.log('[AchPayment] initiate_ach_payment result', {
          payment_id_suffix: paymentId.slice(-6),
          status: initiateRow?.status ?? null,
          payment_method: initiateRow?.payment_method ?? null,
        });
      }

      if (
        !initiateRow ||
        initiateRow.status !== 'processing' ||
        initiateRow.payment_method !== 'ach'
      ) {
        throw new Error(
          `Unexpected state after initiation: status=${initiateRow?.status ?? 'null'}, method=${initiateRow?.payment_method ?? 'null'}`
        );
      }

      // ── Step B: DEV fixture settlement ────────────────────────────────────
      if (__DEV__ && isDevFixture) {
        setAchStage('settling');

        const { data: settleData, error: settleError } = await supabase.functions.invoke(
          'dev-complete-ach-payment',
          { body: { payment_id: paymentId } }
        );

        if (settleError) {
          let stage: string | null = null;
          let errMsg: string = settleError.message;
          try {
            const ctx = (settleError as any)?.context as Response | undefined;
            if (typeof ctx?.json === 'function') {
              const body = await ctx.json();
              stage = body?.stage ?? null;
              errMsg = typeof body?.error === 'string' ? body.error : errMsg;
            } else if (typeof ctx?.text === 'function') {
              const raw = await ctx.text();
              try {
                const parsed = JSON.parse(raw);
                stage = parsed?.stage ?? null;
                errMsg = typeof parsed?.error === 'string' ? parsed.error : errMsg;
              } catch {}
            }
          } catch {}

          if (__DEV__) {
            console.log('[AchPayment] dev-complete-ach-payment error', {
              payment_id_suffix: paymentId.slice(-6),
              stage,
              error: errMsg,
            });
          }

          setAchStage('error');
          Alert.alert(
            'DEV settlement failed',
            `Payment is in processing state but settlement failed${stage ? ` at stage: ${stage}` : ''}.\n\n${errMsg}\n\nDo not use the manual payment flow — the payment remains processing.`,
            [{ text: 'OK', onPress: () => navigation.goBack() }]
          );
          return;
        }

        const d = settleData as any;

        if (__DEV__) {
          console.log('[AchPayment] dev-complete-ach-payment result', {
            payment_id_suffix: paymentId.slice(-6),
            ok: d?.ok ?? null,
            stage: d?.stage ?? null,
            status: d?.status ?? null,
            payment_method: d?.payment_method ?? null,
            has_paid_at: !!d?.paid_at,
          });
        }

        if (
          !d?.ok ||
          d?.status !== 'paid' ||
          d?.payment_method !== 'ach' ||
          !d?.paid_at
        ) {
          setAchStage('error');
          Alert.alert(
            'DEV settlement incomplete',
            `Payment was initiated but settlement not confirmed (status=${d?.status ?? 'null'}).\n\nPayment remains in processing. Do not use the manual flow.`,
            [{ text: 'OK', onPress: () => navigation.goBack() }]
          );
          return;
        }

        setAchStage('done');
        Alert.alert(
          'DEV ACH payment completed',
          `${currency(amount)} paid via ACH (DEV fixture).\n\nReceipt and Score v2 outcome recorded.`,
          [
            {
              text: 'View payment',
              onPress: navigateAfterPay,
            },
            { text: 'OK', onPress: navigateAfterPay },
          ]
        );
        return;
      }

      // ── Non-fixture: initiated, no live Dwolla transfer function yet ──────
      // Do NOT falsely mark paid. Fail closed with honest copy.
      setAchStage('done');
      Alert.alert(
        'ACH payment initiated',
        'Your payment has been submitted and is processing. Live ACH transfer execution is not yet wired — the payment will remain in processing until the processor confirms.',
        [{ text: 'OK', onPress: navigateAfterPay }]
      );
    } catch (e: any) {
      setAchStage('error');
      Alert.alert('Payment failed', e?.message ?? 'Could not initiate ACH payment.');
    } finally {
      setSubmitting(false);
    }
  };

  const stageLabel = useMemo(() => {
    if (achStage === 'initiating') return 'Initiating ACH payment…';
    if (achStage === 'settling') return 'Completing DEV settlement…';
    return null;
  }, [achStage]);

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <ScrollView
      style={s.screen}
      contentContainerStyle={s.content}
      showsVerticalScrollIndicator={false}
    >
      <View style={s.card}>
        <Text style={s.title}>ACH Payment</Text>
        <Text style={s.subtitle}>
          {isEarly ? 'Early payment — before due date' : 'Payment due today or overdue'}
        </Text>

        <View style={s.section}>
          <Text style={s.label}>Amount</Text>
          <Text style={s.amount}>{currency(amount)}</Text>
        </View>

        <View style={s.section}>
          <Text style={s.label}>Due date</Text>
          <Text style={s.value}>{dueLabel}</Text>
        </View>

        {isEarly && (
          <View style={[s.timingBadge, { backgroundColor: '#EAF8EA' }]}>
            <Text style={[s.timingBadgeText, { color: GREEN_DARK }]}>EARLY PAYMENT</Text>
          </View>
        )}

        <View style={s.approvalCard}>
          <Text style={s.approvalTitle}>Lender approval not required</Text>
          <Text style={s.approvalBody}>
            ACH payments are processed directly. The lender will see the payment status and receipt once completed — no confirmation action required from them.
          </Text>
        </View>

        <View style={s.bankCard}>
          <Text style={s.bankLabel}>Bank account</Text>
          {loadingBank ? (
            <ActivityIndicator size="small" style={{ marginTop: 6 }} />
          ) : (
            <>
              <Text
                style={[
                  s.bankValue,
                  achReady ? { color: GREEN_DARK } : { color: ORANGE },
                ]}
              >
                {achReady ? bankReadable : 'Bank not ready for ACH'}
              </Text>
              {!achReady && (
                <Text style={s.bankNote}>
                  Complete bank setup before initiating an ACH payment.
                </Text>
              )}
            </>
          )}
        </View>

        {__DEV__ && isDevFixture && (
          <View style={s.devCard}>
            <Text style={s.devCardTitle}>DEV FIXTURE</Text>
            <Text style={s.devCardBody}>
              bank_provider = dev_fixture. Settlement will be simulated via the dev-complete-ach-payment Edge Function. No real money moves.
            </Text>
          </View>
        )}

        {!!stageLabel && (
          <View style={s.stageRow}>
            <ActivityIndicator size="small" color={BLUE} />
            <Text style={s.stageText}>{stageLabel}</Text>
          </View>
        )}

        <TouchableOpacity
          style={[
            s.primaryBtn,
            (!achReady || submitting || loadingBank) && s.btnDisabled,
          ]}
          onPress={() => void handleConfirm()}
          disabled={!achReady || submitting || loadingBank}
          activeOpacity={0.9}
        >
          {submitting ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={s.primaryBtnText}>
              {loadingBank
                ? 'Loading…'
                : !achReady
                  ? 'Bank not ready'
                  : isEarly
                    ? 'Confirm early ACH payment'
                    : 'Confirm ACH payment'}
            </Text>
          )}
        </TouchableOpacity>

        <TouchableOpacity
          style={s.cancelBtn}
          onPress={() => navigation.goBack()}
          disabled={submitting}
        >
          <Text style={s.cancelBtnText}>Cancel</Text>
        </TouchableOpacity>
      </View>
    </ScrollView>
  );
}

// ── Styles ────────────────────────────────────────────────────────────────────

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
    marginBottom: 2,
  },

  subtitle: {
    fontSize: 14,
    fontWeight: '600',
    color: '#6B7280',
  },

  section: { marginTop: 16 },

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

  timingBadge: {
    marginTop: 14,
    alignSelf: 'flex-start',
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 5,
  },

  timingBadgeText: {
    fontWeight: '800',
    fontSize: 12,
  },

  approvalCard: {
    marginTop: 18,
    backgroundColor: '#F0FDF4',
    borderRadius: 12,
    padding: 14,
    borderWidth: 1,
    borderColor: '#BBF7D0',
  },

  approvalTitle: {
    fontSize: 13,
    fontWeight: '800',
    color: '#15803D',
    textTransform: 'uppercase',
    letterSpacing: 0.4,
    marginBottom: 6,
  },

  approvalBody: {
    fontSize: 14,
    fontWeight: '600',
    color: '#15803D',
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

  bankLabel: {
    fontSize: 12,
    fontWeight: '800',
    textTransform: 'uppercase',
    color: '#1D4ED8',
    marginBottom: 6,
  },

  bankValue: {
    fontSize: 15,
    fontWeight: '700',
    color: '#475467',
  },

  bankNote: {
    marginTop: 6,
    fontSize: 13,
    fontWeight: '600',
    color: ORANGE,
  },

  devCard: {
    marginTop: 14,
    backgroundColor: '#1C1C1E',
    borderRadius: 10,
    padding: 12,
  },

  devCardTitle: {
    fontSize: 10,
    fontWeight: '800',
    color: '#FFD60A',
    letterSpacing: 0.6,
    textTransform: 'uppercase',
    marginBottom: 4,
  },

  devCardBody: {
    fontSize: 13,
    fontWeight: '600',
    color: '#E5E7EB',
    lineHeight: 18,
  },

  stageRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    marginTop: 14,
    paddingVertical: 8,
    paddingHorizontal: 12,
    backgroundColor: '#EEF4FF',
    borderRadius: 8,
  },

  stageText: {
    fontSize: 13,
    fontWeight: '700',
    color: BLUE,
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

  cancelBtn: {
    marginTop: 10,
    height: 50,
    borderRadius: 14,
    backgroundColor: '#EEF2F5',
    alignItems: 'center',
    justifyContent: 'center',
  },

  cancelBtnText: {
    color: '#222',
    fontSize: 16,
    fontWeight: '700',
  },
});

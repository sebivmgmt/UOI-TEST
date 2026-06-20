import React, { useEffect, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  InteractionManager,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { useReceiptSplit } from '../context/receiptSplitContext';
import { calculateSplit, formatCents } from '../services/splitCalculator';
import { generateSplitIous } from '../services/paymentService';
import {
  fetchSplitTotals,
  generateIousFromSplit,
  SplitTotalRow,
} from '../services/receiptPersistenceService';
import { supabase } from '../supabase';
import SplitSummaryCard from '../components/receipt/SplitSummaryCard';

const BRAND = '#1B5E20';
const BG = '#F5F7F9';

type Props = { navigation: any };

export default function ReceiptSummaryScreen({ navigation }: Props) {
  const { draft, participants, payerId, assignments, reset } = useReceiptSplit();
  const [sending, setSending] = useState(false);
  const [serverTotals, setServerTotals] = useState<SplitTotalRow[]>([]);

  // ─── Subscribe to receipt_split_totals (when persisted) ─────────────────────
  useEffect(() => {
    if (!draft?.splitId) return;
    const splitId = draft.splitId;

    fetchSplitTotals(splitId).then(setServerTotals).catch(() => {});

    const channel = supabase
      .channel(`summary-totals-${splitId}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'receipt_split_totals',
          filter: `receipt_split_id=eq.${splitId}`,
        },
        () => {
          fetchSplitTotals(splitId).then(setServerTotals).catch(() => {});
        }
      )
      .subscribe();

    return () => { supabase.removeChannel(channel); };
  }, [draft?.splitId]);

  if (!draft) {
    return (
      <View style={styles.centered}>
        <Text style={styles.emptyText}>No receipt data. Go back to start.</Text>
      </View>
    );
  }

  const localSplitResult = useMemo(
    () => calculateSplit(draft.items, participants, assignments, draft.taxCents, draft.tipCents),
    [draft.items, participants, assignments, draft.taxCents, draft.tipCents]
  );

  // Prefer server totals when available; fall back to local calc.
  function getTotalCents(participantId: string): number {
    if (serverTotals.length > 0) {
      const row = serverTotals.find(r => r.local_participant_id === participantId);
      if (row) return row.total_cents;
    }
    return localSplitResult.totals.find(t => t.participantId === participantId)?.totalCents ?? 0;
  }

  const payer = participants.find(p => p.id === payerId);
  const nonPayers = participants.filter(p => p.id !== payerId);

  const subtotalDollars = (localSplitResult.subtotalCents / 100).toFixed(2);
  const taxDollars = (localSplitResult.taxCents / 100).toFixed(2);
  const tipDollars = (localSplitResult.tipCents / 100).toFixed(2);
  const grandDollars = (localSplitResult.grandTotalCents / 100).toFixed(2);

  function navigateHome() {
    setSending(false);
    const parent = navigation.getParent();
    if (parent) parent.navigate('HomeTab', { screen: 'Home' });
    else navigation.popToTop();
    InteractionManager.runAfterInteractions(reset);
  }

  async function handleSendIous() {
    if (!draft || !payerId) return;
    setSending(true);
    try {
      if (draft.splitId) {
        // Real path: server generates IOU drafts via RPC.
        const dueDate = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)
          .toISOString()
          .split('T')[0];
        const result = await generateIousFromSplit(draft.splitId, dueDate);
        const count = result.iou_count;
        Alert.alert(
          count > 0 ? 'IOUs Created' : 'Nothing to Send',
          count > 0
            ? `${count} IOU request${count !== 1 ? 's' : ''} sent. Friends will receive them in their inbox.`
            : 'No IOUs were created. Add friends who use the app to split with them.',
          [{ text: 'Done', onPress: navigateHome }]
        );
      } else {
        // Demo / offline fallback — no Supabase writes.
        const ious = await generateSplitIous(draft, participants, payerId, localSplitResult);
        Alert.alert(
          'IOUs Sent (demo)',
          `${ious.length} IOU request${ious.length !== 1 ? 's' : ''} created in demo mode.`,
          [{ text: 'Done', onPress: navigateHome }]
        );
      }
    } catch (e: any) {
      setSending(false);
      const raw: string = e?.message ?? String(e);
      const msg = raw.includes('already exists') || raw.includes('generated_iou_id')
        ? 'IOUs have already been created for this receipt.'
        : raw.includes('not authorized') || raw.includes('owner')
        ? 'Only the person who paid can send IOUs.'
        : raw;
      Alert.alert('Could Not Send IOUs', msg);
    }
  }

  return (
    <View style={{ flex: 1, backgroundColor: BG }}>
      <ScrollView contentContainerStyle={styles.scroll} showsVerticalScrollIndicator={false}>
        <View style={styles.restaurantCard}>
          <Text style={styles.restaurantName}>{draft.restaurantName || 'Receipt'}</Text>
          <Text style={styles.restaurantDate}>{draft.date}</Text>
        </View>

        <View style={styles.totalsCard}>
          <Text style={styles.sectionLabel}>Receipt Totals</Text>
          <View style={styles.totalLine}>
            <Text style={styles.totalLineLabel}>Subtotal</Text>
            <Text style={styles.totalLineValue}>${subtotalDollars}</Text>
          </View>
          <View style={styles.totalLine}>
            <Text style={styles.totalLineLabel}>Tax</Text>
            <Text style={styles.totalLineValue}>${taxDollars}</Text>
          </View>
          <View style={styles.totalLine}>
            <Text style={styles.totalLineLabel}>Tip</Text>
            <Text style={styles.totalLineValue}>${tipDollars}</Text>
          </View>
          <View style={[styles.totalLine, styles.grandLine]}>
            <Text style={styles.grandLineLabel}>Total</Text>
            <Text style={styles.grandLineValue}>${grandDollars}</Text>
          </View>
        </View>

        <Text style={styles.owesHeader}>Who Owes What</Text>

        {nonPayers.length === 0 && (
          <View style={styles.noOwesWrap}>
            <Text style={styles.noOwesText}>
              Only one participant — no IOUs to create.
            </Text>
          </View>
        )}

        {nonPayers.length > 0 && nonPayers.every(p => getTotalCents(p.id) === 0) && (
          <View style={styles.noOwesWrap}>
            <Text style={styles.noOwesText}>
              All items are assigned to you — no IOUs to create.
            </Text>
          </View>
        )}

        {nonPayers.map(person => {
          const amountCents = getTotalCents(person.id);
          if (amountCents === 0) return null;
          return (
            <SplitSummaryCard
              key={person.id}
              fromName={person.name}
              toName={payer?.name ?? 'Payer'}
              amountCents={amountCents}
              fromAvatarUrl={person.avatar_url}
              toAvatarUrl={payer?.avatar_url}
            />
          );
        })}

        {payer && (
          <View style={styles.payerSummaryCard}>
            <Text style={styles.payerSummaryLabel}>Your share</Text>
            <View style={styles.payerRow}>
              <Text style={styles.payerName}>{payer.name}</Text>
              <Text style={styles.payerAmount}>
                {formatCents(getTotalCents(payer.id))}
              </Text>
            </View>
            <Text style={styles.payerNote}>
              You paid upfront — friends will send you their share.
            </Text>
          </View>
        )}

        <View style={{ height: 120 }} />
      </ScrollView>

      <View style={styles.bottomBar}>
        <TouchableOpacity
          style={[styles.sendBtn, sending && styles.sendBtnDisabled]}
          onPress={handleSendIous}
          disabled={sending}
          activeOpacity={0.85}
        >
          {sending ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.sendBtnText}>Send IOUs</Text>
          )}
        </TouchableOpacity>
        {!draft.splitId && (
          <Text style={styles.demoNote}>Demo mode — no backend calls</Text>
        )}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  scroll: {
    paddingTop: 20,
    paddingBottom: 24,
  },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 32,
  },
  emptyText: {
    textAlign: 'center',
    fontSize: 15,
    fontWeight: '600',
    color: '#9CA3AF',
  },
  restaurantCard: {
    backgroundColor: '#fff',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    marginHorizontal: 16,
    marginBottom: 14,
    padding: 20,
    alignItems: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 8,
    elevation: 3,
  },
  restaurantName: {
    fontSize: 24,
    fontWeight: '900',
    color: '#111827',
    textAlign: 'center',
  },
  restaurantDate: {
    marginTop: 4,
    fontSize: 14,
    fontWeight: '600',
    color: '#9CA3AF',
  },
  totalsCard: {
    backgroundColor: '#fff',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    marginHorizontal: 16,
    marginBottom: 20,
    padding: 16,
    gap: 8,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 8,
    elevation: 3,
  },
  sectionLabel: {
    fontSize: 12,
    fontWeight: '800',
    color: '#6B7280',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginBottom: 4,
  },
  totalLine: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  totalLineLabel: {
    fontSize: 14,
    fontWeight: '600',
    color: '#6B7280',
  },
  totalLineValue: {
    fontSize: 14,
    fontWeight: '700',
    color: '#374151',
  },
  grandLine: {
    marginTop: 6,
    paddingTop: 10,
    borderTopWidth: 1.5,
    borderTopColor: '#E5E7EB',
  },
  grandLineLabel: {
    fontSize: 17,
    fontWeight: '900',
    color: '#111827',
  },
  grandLineValue: {
    fontSize: 20,
    fontWeight: '900',
    color: BRAND,
  },
  owesHeader: {
    fontSize: 18,
    fontWeight: '900',
    color: '#111827',
    marginHorizontal: 16,
    marginBottom: 12,
  },
  noOwesWrap: {
    marginHorizontal: 16,
    padding: 16,
    backgroundColor: '#fff',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    alignItems: 'center',
  },
  noOwesText: {
    fontSize: 14,
    fontWeight: '600',
    color: '#9CA3AF',
    textAlign: 'center',
  },
  payerSummaryCard: {
    backgroundColor: '#F0FBF0',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#C8E6C9',
    marginHorizontal: 16,
    marginTop: 4,
    padding: 16,
    gap: 6,
  },
  payerSummaryLabel: {
    fontSize: 12,
    fontWeight: '800',
    color: BRAND,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
  },
  payerRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  payerName: {
    fontSize: 16,
    fontWeight: '800',
    color: '#111827',
  },
  payerAmount: {
    fontSize: 18,
    fontWeight: '900',
    color: BRAND,
  },
  payerNote: {
    fontSize: 12,
    fontWeight: '600',
    color: '#6B7280',
    lineHeight: 17,
  },
  bottomBar: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    backgroundColor: '#fff',
    borderTopWidth: 1,
    borderTopColor: '#E5E7EB',
    padding: 20,
    paddingBottom: 36,
    gap: 8,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: -3 },
    shadowOpacity: 0.07,
    shadowRadius: 8,
    elevation: 8,
  },
  sendBtn: {
    backgroundColor: BRAND,
    borderRadius: 16,
    paddingVertical: 18,
    alignItems: 'center',
    shadowColor: BRAND,
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.3,
    shadowRadius: 8,
    elevation: 4,
  },
  sendBtnDisabled: {
    opacity: 0.6,
  },
  sendBtnText: {
    color: '#fff',
    fontSize: 18,
    fontWeight: '900',
    letterSpacing: 0.3,
  },
  demoNote: {
    textAlign: 'center',
    fontSize: 12,
    fontWeight: '600',
    color: '#9CA3AF',
  },
});

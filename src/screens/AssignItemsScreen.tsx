import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Alert, FlatList, StyleSheet, Text, View } from 'react-native';
import { useReceiptSplit, ItemAssignment, ReceiptItem } from '../context/receiptSplitContext';
import { calculateSplit } from '../services/splitCalculator';
import {
  fetchSplitTotals,
  refreshSplitTotals,
  SplitTotalRow,
  upsertAssignments,
} from '../services/receiptPersistenceService';
import { supabase } from '../supabase';
import ReceiptItemCard from '../components/receipt/ReceiptItemCard';
import ReceiptTotalsBar from '../components/receipt/ReceiptTotalsBar';
import SharedItemSelector from '../components/receipt/SharedItemSelector';

const BG = '#F5F7F9';

type Props = { navigation: any };

function assignmentErrorMessage(raw: string): string {
  if (raw.includes('exceeds 100')) {
    return 'One item\'s split adds up to more than 100%. Adjust the amounts and try again.';
  }
  if (raw.includes('does not belong to this receipt split')) {
    return 'A participant isn\'t part of this receipt. Go back and re-add friends.';
  }
  if (raw.includes('receipt_split_id does not match')) {
    return 'There was a data mismatch. Go back and try again.';
  }
  return raw;
}

export default function AssignItemsScreen({ navigation }: Props) {
  const {
    draft,
    participants,
    assignments: contextAssignments,
    setAssignments,
    itemDbIdMap,
    participantDbIdMap,
  } = useReceiptSplit();

  const [localAssignments, setLocalAssignments] = useState<ItemAssignment[]>([]);
  const [selectorItem, setSelectorItem] = useState<ReceiptItem | null>(null);
  const [selectorVisible, setSelectorVisible] = useState(false);
  const [serverTotals, setServerTotals] = useState<SplitTotalRow[]>([]);

  const debounceTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Tracks the last assignment state successfully committed to Supabase.
  // Used to roll back local UI if the server rejects a constraint violation.
  const lastCommittedAssignments = useRef<ItemAssignment[]>([]);

  useEffect(() => {
    const initial = contextAssignments.length > 0 ? contextAssignments : [];
    setLocalAssignments(initial);
    lastCommittedAssignments.current = initial;
  }, []);

  // ─── Realtime subscription on receipt_split_totals ──────────────────────────
  useEffect(() => {
    if (!draft?.splitId) return;
    const splitId = draft.splitId;

    fetchSplitTotals(splitId).then(setServerTotals).catch(() => {});

    const channel = supabase
      .channel(`assign-totals-${splitId}`)
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

  // ─── Debounced upsert → calculate_receipt_split_totals ──────────────────────
  useEffect(() => {
    if (!draft?.splitId) return;
    const splitId = draft.splitId;
    const snapshot = localAssignments;

    if (debounceTimer.current) clearTimeout(debounceTimer.current);
    debounceTimer.current = setTimeout(async () => {
      try {
        await upsertAssignments(splitId, snapshot, participantDbIdMap, itemDbIdMap);
        lastCommittedAssignments.current = snapshot;
      } catch (e: any) {
        setLocalAssignments(lastCommittedAssignments.current);
        const msg = assignmentErrorMessage(e?.message ?? String(e));
        Alert.alert('Assignment Error', msg);
        return;
      }
      try {
        await refreshSplitTotals(splitId);
      } catch {
        // Totals will stay stale; realtime subscription will catch up when possible.
      }
    }, 400);

    return () => { if (debounceTimer.current) clearTimeout(debounceTimer.current); };
  }, [localAssignments, draft?.splitId, participantDbIdMap, itemDbIdMap]);

  const items = draft?.items ?? [];
  const taxCents = draft?.taxCents ?? 0;
  const tipCents = draft?.tipCents ?? 0;

  // Local calc — instant, always reflects current UI state.
  const splitResult = useMemo(
    () => calculateSplit(items, participants, localAssignments, taxCents, tipCents),
    [items, participants, localAssignments, taxCents, tipCents]
  );

  // Merge server totals into display totals when available.
  // Server totals are preferred for final accuracy; local calc is the immediate fallback.
  const displayTotals = useMemo(() => {
    if (serverTotals.length === 0) return splitResult.totals;
    return splitResult.totals.map(local => {
      const server = serverTotals.find(s => s.local_participant_id === local.participantId);
      if (!server) return local;
      return {
        ...local,
        itemCents: server.item_cents,
        taxCents: server.tax_cents,
        tipCents: server.tip_cents,
        totalCents: server.total_cents,
      };
    });
  }, [splitResult.totals, serverTotals]);

  function getAssignment(itemId: string): ItemAssignment | undefined {
    return localAssignments.find(a => a.itemId === itemId);
  }

  function getAssignedParticipants(itemId: string) {
    const assignment = getAssignment(itemId);
    if (!assignment) return [];
    return participants.filter(p => assignment.participantIds.includes(p.id));
  }

  function toggleParticipantOnItem(itemId: string, participantId: string) {
    setLocalAssignments(prev => {
      const existing = prev.find(a => a.itemId === itemId);
      if (!existing) {
        return [...prev, { itemId, participantIds: [participantId], splitMode: 'equal' }];
      }
      const alreadyIn = existing.participantIds.includes(participantId);
      const newIds = alreadyIn
        ? existing.participantIds.filter(id => id !== participantId)
        : [...existing.participantIds, participantId];
      return prev.map(a => a.itemId === itemId ? { ...a, participantIds: newIds } : a);
    });
  }

  function openSelector(item: ReceiptItem) {
    setSelectorItem(item);
    setSelectorVisible(true);
  }

  function handleSelectorSave(assignment: ItemAssignment) {
    setLocalAssignments(prev => {
      const existing = prev.findIndex(a => a.itemId === assignment.itemId);
      if (existing >= 0) {
        const next = [...prev];
        next[existing] = assignment;
        return next;
      }
      return [...prev, assignment];
    });
    setSelectorVisible(false);
    setSelectorItem(null);
  }

  function handleContinue() {
    setAssignments(localAssignments);
    navigation.navigate('ReceiptSummary');
  }

  const renderItem = useCallback(({ item }: { item: ReceiptItem }) => (
    <ReceiptItemCard
      item={item}
      assignedParticipants={getAssignedParticipants(item.id)}
      allParticipants={participants}
      onToggle={(participantId) => toggleParticipantOnItem(item.id, participantId)}
      onLongPress={() => openSelector(item)}
    />
  ), [localAssignments, participants]);

  if (!draft) {
    return (
      <View style={styles.centered}>
        <Text style={styles.emptyText}>No receipt draft found. Go back and scan a receipt.</Text>
      </View>
    );
  }

  return (
    <View style={{ flex: 1, backgroundColor: BG }}>
      <FlatList
        data={items}
        keyExtractor={it => it.id}
        renderItem={renderItem}
        ListHeaderComponent={
          <View style={styles.header}>
            <Text style={styles.restaurantName}>{draft.restaurantName || 'Receipt'}</Text>
            <Text style={styles.headerSub}>
              Tap a person's bubble to assign. Long press an item for custom split.
            </Text>
          </View>
        }
        ListEmptyComponent={
          <View style={styles.centered}>
            <Text style={styles.emptyText}>No items on this receipt.</Text>
          </View>
        }
        contentContainerStyle={styles.listContent}
        showsVerticalScrollIndicator={false}
      />

      <ReceiptTotalsBar
        participants={participants}
        totals={displayTotals}
        onContinue={handleContinue}
        continueLabel="Review Split"
      />

      <SharedItemSelector
        visible={selectorVisible}
        item={selectorItem}
        participants={participants}
        currentAssignment={selectorItem ? (getAssignment(selectorItem.id) ?? null) : null}
        onSave={handleSelectorSave}
        onClose={() => {
          setSelectorVisible(false);
          setSelectorItem(null);
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  listContent: {
    paddingTop: 16,
    paddingBottom: 120,
  },
  header: {
    paddingHorizontal: 16,
    marginBottom: 12,
    gap: 4,
  },
  restaurantName: {
    fontSize: 22,
    fontWeight: '900',
    color: '#111827',
  },
  headerSub: {
    fontSize: 13,
    fontWeight: '600',
    color: '#9CA3AF',
    lineHeight: 18,
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
});

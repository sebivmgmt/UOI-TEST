import React, { useEffect, useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Modal,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { ItemAssignment, Participant, ReceiptItem, SplitMode } from '../../context/receiptSplitContext';
import SebivAvatar from '../SebivAvatar';

const BRAND = '#1B5E20';

type Props = {
  visible: boolean;
  item: ReceiptItem | null;
  participants: Participant[];
  currentAssignment: ItemAssignment | null;
  onSave: (assignment: ItemAssignment) => void;
  onClose: () => void;
};

export default function SharedItemSelector({
  visible,
  item,
  participants,
  currentAssignment,
  onSave,
  onClose,
}: Props) {
  const [tab, setTab] = useState<SplitMode>('equal');
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [manualAmounts, setManualAmounts] = useState<Record<string, string>>({});

  useEffect(() => {
    if (!visible || !item) return;
    if (currentAssignment) {
      setTab(currentAssignment.splitMode);
      setSelectedIds([...currentAssignment.participantIds]);
      const ma: Record<string, string> = {};
      if (currentAssignment.manualAmounts) {
        Object.entries(currentAssignment.manualAmounts).forEach(([id, v]) => {
          ma[id] = v.toFixed(2);
        });
      }
      setManualAmounts(ma);
    } else {
      setTab('equal');
      setSelectedIds(participants.map(p => p.id));
      setManualAmounts({});
    }
  }, [visible, item, currentAssignment, participants]);

  if (!item) return null;

  const itemTotal = item.price * item.quantity;

  function toggleParticipant(id: string) {
    setSelectedIds(prev =>
      prev.includes(id) ? prev.filter(x => x !== id) : [...prev, id]
    );
  }

  function handleSave() {
    if (!item) return;
    if (selectedIds.length === 0) {
      Alert.alert('No participants', 'Select at least one person for this item.');
      return;
    }

    if (tab === 'manual') {
      const sum = selectedIds.reduce((acc, id) => {
        return acc + parseFloat(manualAmounts[id] || '0');
      }, 0);
      const diff = Math.abs(sum - itemTotal);
      if (diff > 0.02) {
        Alert.alert(
          'Amounts do not match',
          `Custom amounts total $${sum.toFixed(2)} but item is $${itemTotal.toFixed(2)}. Adjust amounts to match.`
        );
        return;
      }

      const amounts: Record<string, number> = {};
      selectedIds.forEach(id => {
        amounts[id] = parseFloat(manualAmounts[id] || '0');
      });

      onSave({
        itemId: item.id,
        participantIds: selectedIds,
        splitMode: 'manual',
        manualAmounts: amounts,
      });
    } else {
      onSave({
        itemId: item.id,
        participantIds: selectedIds,
        splitMode: 'equal',
      });
    }
  }

  const equalShare = selectedIds.length > 0 ? itemTotal / selectedIds.length : 0;

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <TouchableOpacity style={styles.backdrop} activeOpacity={1} onPress={onClose} />
      <KeyboardAvoidingView
        behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
        style={styles.sheetWrap}
      >
        <View style={styles.sheet}>
          <View style={styles.handle} />

          <View style={styles.titleRow}>
            <View style={styles.titleLeft}>
              <Text style={styles.itemTitle} numberOfLines={1}>{item.name}</Text>
              <Text style={styles.itemPrice}>
                ${itemTotal.toFixed(2)}
                {item.quantity > 1 ? ` (x${item.quantity})` : ''}
              </Text>
            </View>
            <TouchableOpacity onPress={onClose} style={styles.closeBtn}>
              <Text style={styles.closeBtnText}>Done</Text>
            </TouchableOpacity>
          </View>

          <View style={styles.tabs}>
            {(['equal', 'manual'] as SplitMode[]).map(t => (
              <TouchableOpacity
                key={t}
                style={[styles.tab, tab === t && styles.tabActive]}
                onPress={() => setTab(t)}
              >
                <Text style={[styles.tabText, tab === t && styles.tabTextActive]}>
                  {t === 'equal' ? 'Equal Split' : 'Custom Split'}
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          <ScrollView style={styles.list} showsVerticalScrollIndicator={false}>
            {participants.map(p => {
              const isSelected = selectedIds.includes(p.id);

              if (tab === 'equal') {
                return (
                  <TouchableOpacity
                    key={p.id}
                    style={[styles.personRow, isSelected && styles.personRowSelected]}
                    onPress={() => toggleParticipant(p.id)}
                    activeOpacity={0.75}
                  >
                    <SebivAvatar uri={p.avatar_url} size={38} />
                    <Text style={styles.personRowName}>{p.name}</Text>
                    <View style={styles.personRowRight}>
                      {isSelected && (
                        <Text style={styles.shareAmount}>${equalShare.toFixed(2)}</Text>
                      )}
                      <View style={[styles.checkbox, isSelected && styles.checkboxActive]}>
                        {isSelected && <View style={styles.checkDot} />}
                      </View>
                    </View>
                  </TouchableOpacity>
                );
              }

              return (
                <View key={p.id} style={styles.personRow}>
                  <TouchableOpacity onPress={() => toggleParticipant(p.id)} activeOpacity={0.7}>
                    <View style={{ opacity: isSelected ? 1 : 0.45 }}>
                      <SebivAvatar uri={p.avatar_url} size={38} />
                    </View>
                  </TouchableOpacity>
                  <Text style={[styles.personRowName, !isSelected && { opacity: 0.4 }]}>
                    {p.name}
                  </Text>
                  <View style={styles.amountInputWrap}>
                    <Text style={styles.dollarSign}>$</Text>
                    <TextInput
                      style={[styles.amountInput, !isSelected && { opacity: 0.3 }]}
                      keyboardType="decimal-pad"
                      value={manualAmounts[p.id] ?? ''}
                      onChangeText={text => {
                        setManualAmounts(prev => ({ ...prev, [p.id]: text }));
                        if (!isSelected && text.length > 0) toggleParticipant(p.id);
                      }}
                      placeholder="0.00"
                      editable={isSelected}
                      selectTextOnFocus
                    />
                  </View>
                </View>
              );
            })}

            {tab === 'manual' && selectedIds.length > 0 && (
              <View style={styles.totalCheckRow}>
                <Text style={styles.totalCheckLabel}>Total assigned:</Text>
                <Text style={styles.totalCheckValue}>
                  ${selectedIds.reduce((s, id) => s + parseFloat(manualAmounts[id] || '0'), 0).toFixed(2)}
                  {' / '}
                  <Text style={styles.totalCheckTarget}>${itemTotal.toFixed(2)}</Text>
                </Text>
              </View>
            )}

            <View style={{ height: 20 }} />
          </ScrollView>

          <TouchableOpacity style={styles.saveBtn} onPress={handleSave} activeOpacity={0.85}>
            <Text style={styles.saveBtnText}>Save Assignment</Text>
          </TouchableOpacity>
        </View>
      </KeyboardAvoidingView>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.4)',
  },
  sheetWrap: {
    justifyContent: 'flex-end',
  },
  sheet: {
    backgroundColor: '#fff',
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    paddingHorizontal: 20,
    paddingBottom: 32,
    maxHeight: '80%',
  },
  handle: {
    width: 40,
    height: 4,
    borderRadius: 2,
    backgroundColor: '#E5E7EB',
    alignSelf: 'center',
    marginTop: 12,
    marginBottom: 16,
  },
  titleRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'flex-start',
    marginBottom: 16,
  },
  titleLeft: {
    flex: 1,
  },
  itemTitle: {
    fontSize: 18,
    fontWeight: '800',
    color: '#111827',
  },
  itemPrice: {
    fontSize: 14,
    fontWeight: '700',
    color: BRAND,
    marginTop: 2,
  },
  closeBtn: {
    paddingLeft: 12,
    paddingVertical: 2,
  },
  closeBtnText: {
    fontSize: 15,
    fontWeight: '700',
    color: BRAND,
  },
  tabs: {
    flexDirection: 'row',
    backgroundColor: '#F3F4F6',
    borderRadius: 10,
    padding: 3,
    marginBottom: 16,
  },
  tab: {
    flex: 1,
    paddingVertical: 8,
    borderRadius: 8,
    alignItems: 'center',
  },
  tabActive: {
    backgroundColor: '#fff',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.08,
    shadowRadius: 4,
    elevation: 2,
  },
  tabText: {
    fontSize: 13,
    fontWeight: '700',
    color: '#6B7280',
  },
  tabTextActive: {
    color: '#111827',
  },
  list: {
    flexGrow: 0,
  },
  personRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 10,
    gap: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#F3F4F6',
  },
  personRowSelected: {
    backgroundColor: '#F0FBF0',
    borderRadius: 10,
    paddingHorizontal: 8,
  },
  personRowName: {
    flex: 1,
    fontSize: 15,
    fontWeight: '700',
    color: '#111827',
  },
  personRowRight: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  shareAmount: {
    fontSize: 14,
    fontWeight: '800',
    color: BRAND,
  },
  checkbox: {
    width: 22,
    height: 22,
    borderRadius: 11,
    borderWidth: 2,
    borderColor: '#D1D5DB',
    alignItems: 'center',
    justifyContent: 'center',
  },
  checkboxActive: {
    borderColor: BRAND,
    backgroundColor: BRAND,
  },
  checkDot: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: '#fff',
  },
  amountInputWrap: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#F9FAFB',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 8,
    paddingHorizontal: 8,
    minWidth: 80,
  },
  dollarSign: {
    fontSize: 15,
    fontWeight: '700',
    color: '#374151',
  },
  amountInput: {
    fontSize: 15,
    fontWeight: '700',
    color: '#111827',
    paddingVertical: 8,
    paddingLeft: 2,
    minWidth: 60,
  },
  totalCheckRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginTop: 12,
    paddingTop: 12,
    borderTopWidth: 1,
    borderTopColor: '#E5E7EB',
  },
  totalCheckLabel: {
    fontSize: 13,
    fontWeight: '700',
    color: '#6B7280',
  },
  totalCheckValue: {
    fontSize: 14,
    fontWeight: '800',
    color: '#111827',
  },
  totalCheckTarget: {
    color: BRAND,
  },
  saveBtn: {
    backgroundColor: BRAND,
    borderRadius: 14,
    paddingVertical: 16,
    alignItems: 'center',
    marginTop: 12,
  },
  saveBtnText: {
    color: '#fff',
    fontWeight: '800',
    fontSize: 16,
  },
});

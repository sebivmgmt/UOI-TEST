import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { useReceiptSplit, ReceiptDraft, ReceiptItem } from '../context/receiptSplitContext';
import { persistReceiptSplit } from '../services/receiptPersistenceService';

const BRAND = '#1B5E20';
const BG = '#F5F7F9';

type Props = { navigation: any };

let itemCounter = 1000;
function newItemId() { return `item-new-${++itemCounter}`; }

function centsToDisplay(cents: number): string {
  return (cents / 100).toFixed(2);
}

function displayToCents(text: string): number {
  const v = parseFloat(text.replace(/[^0-9.]/g, ''));
  return isNaN(v) ? 0 : Math.round(v * 100);
}

export default function ReceiptReviewScreen({ navigation }: Props) {
  const { draft, setDraft, setItemDbIdMap } = useReceiptSplit();

  const [restaurantName, setRestaurantName] = useState('');
  const [items, setItems] = useState<ReceiptItem[]>([]);
  const [taxText, setTaxText] = useState('0.00');
  const [tipText, setTipText] = useState('0.00');
  const [persisting, setPersisting] = useState(false);

  useEffect(() => {
    if (draft) {
      setRestaurantName(draft.restaurantName);
      setItems(draft.items);
      setTaxText(centsToDisplay(draft.taxCents));
      setTipText(centsToDisplay(draft.tipCents));
    }
  }, [draft?.id]);

  const subtotal = items.reduce((s, it) => s + it.price * it.quantity, 0);
  const taxCents = displayToCents(taxText);
  const tipCents = displayToCents(tipText);
  const total = subtotal + taxCents / 100 + tipCents / 100;

  function updateItem(id: string, field: keyof ReceiptItem, value: string | number) {
    setItems(prev =>
      prev.map(it => {
        if (it.id !== id) return it;
        if (field === 'price') {
          const num = parseFloat(String(value).replace(/[^0-9.]/g, ''));
          return { ...it, price: isNaN(num) ? 0 : num };
        }
        if (field === 'quantity') {
          const num = parseInt(String(value), 10);
          return { ...it, quantity: isNaN(num) || num < 1 ? 1 : num };
        }
        return { ...it, [field]: value };
      })
    );
  }

  function deleteItem(id: string) {
    setItems(prev => prev.filter(it => it.id !== id));
  }

  function addItem() {
    const newItem: ReceiptItem = {
      id: newItemId(),
      name: '',
      price: 0,
      quantity: 1,
    };
    setItems(prev => [...prev, newItem]);
  }

  function applyTipPercent(pct: number) {
    const tip = subtotal * pct;
    setTipText(tip.toFixed(2));
  }

  async function handleContinue() {
    if (items.length === 0) {
      Alert.alert('No items', 'Add at least one item before continuing.');
      return;
    }
    const updatedDraft: ReceiptDraft = {
      id: draft?.id ?? `draft-${Date.now()}`,
      restaurantName,
      date: draft?.date ?? new Date().toISOString().split('T')[0],
      imageUri: draft?.imageUri,
      items,
      taxCents,
      tipCents,
    };

    // Persistence checkpoint: create receipt_splits + receipt_split_items in Supabase.
    setPersisting(true);
    try {
      const { splitId, itemDbIdMap } = await persistReceiptSplit(updatedDraft);
      setItemDbIdMap(itemDbIdMap);
      setDraft({ ...updatedDraft, splitId });
    } catch (e: any) {
      console.error('[ReceiptReview] persistReceiptSplit failed:', e);
      setPersisting(false);
      Alert.alert('Could Not Save', 'Something went wrong. Please try again.');
      return;
    }
    setPersisting(false);
    navigation.navigate('ReceiptParticipants');
  }

  return (
    <KeyboardAvoidingView
      style={{ flex: 1, backgroundColor: BG }}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      keyboardVerticalOffset={88}
    >
      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
        keyboardShouldPersistTaps="handled"
      >
        <View style={styles.card}>
          <Text style={styles.sectionLabel}>Restaurant</Text>
          <TextInput
            style={styles.restaurantInput}
            value={restaurantName}
            onChangeText={setRestaurantName}
            placeholder="Restaurant name"
            placeholderTextColor="#9CA3AF"
          />
        </View>

        <View style={styles.card}>
          <View style={styles.sectionHeader}>
            <Text style={styles.sectionLabel}>Items</Text>
            <TouchableOpacity onPress={addItem} style={styles.addBtn}>
              <Text style={styles.addBtnText}>+ Add Item</Text>
            </TouchableOpacity>
          </View>

          {items.length === 0 && (
            <Text style={styles.emptyItems}>No items yet. Tap "Add Item" above.</Text>
          )}

          {items.map((item, idx) => (
            <View key={item.id} style={[styles.itemRow, idx > 0 && styles.itemRowBorder]}>
              <View style={styles.itemLeft}>
                <TextInput
                  style={styles.itemNameInput}
                  value={item.name}
                  onChangeText={v => updateItem(item.id, 'name', v)}
                  placeholder="Item name"
                  placeholderTextColor="#9CA3AF"
                />
                <View style={styles.itemMeta}>
                  <Text style={styles.metaLabel}>Qty:</Text>
                  <TextInput
                    style={styles.qtyInput}
                    value={String(item.quantity)}
                    onChangeText={v => updateItem(item.id, 'quantity', v)}
                    keyboardType="number-pad"
                    selectTextOnFocus
                  />
                </View>
              </View>

              <View style={styles.itemRight}>
                <View style={styles.priceInputWrap}>
                  <Text style={styles.dollarSign}>$</Text>
                  <TextInput
                    style={styles.priceInput}
                    value={item.price === 0 ? '' : String(item.price)}
                    onChangeText={v => updateItem(item.id, 'price', v)}
                    keyboardType="decimal-pad"
                    placeholder="0.00"
                    placeholderTextColor="#9CA3AF"
                    selectTextOnFocus
                  />
                </View>
                <TouchableOpacity onPress={() => deleteItem(item.id)} style={styles.deleteBtn}>
                  <View style={styles.deleteX}>
                    <View style={[styles.deleteBar, { transform: [{ rotate: '45deg' }] }]} />
                    <View style={[styles.deleteBar, { transform: [{ rotate: '-45deg' }] }]} />
                  </View>
                </TouchableOpacity>
              </View>
            </View>
          ))}
        </View>

        <View style={styles.card}>
          <Text style={styles.sectionLabel}>Tax & Tip</Text>

          <View style={styles.taxRow}>
            <Text style={styles.taxLabel}>Tax</Text>
            <View style={styles.priceInputWrap}>
              <Text style={styles.dollarSign}>$</Text>
              <TextInput
                style={styles.priceInput}
                value={taxText}
                onChangeText={setTaxText}
                keyboardType="decimal-pad"
                selectTextOnFocus
              />
            </View>
          </View>

          <View style={styles.taxRow}>
            <Text style={styles.taxLabel}>Tip</Text>
            <View style={styles.priceInputWrap}>
              <Text style={styles.dollarSign}>$</Text>
              <TextInput
                style={styles.priceInput}
                value={tipText}
                onChangeText={setTipText}
                keyboardType="decimal-pad"
                selectTextOnFocus
              />
            </View>
          </View>

          <View style={styles.tipPctRow}>
            {[0.15, 0.18, 0.20].map(pct => (
              <TouchableOpacity
                key={pct}
                style={styles.tipPctBtn}
                onPress={() => applyTipPercent(pct)}
              >
                <Text style={styles.tipPctText}>{(pct * 100).toFixed(0)}%</Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>

        <View style={styles.totalsCard}>
          <View style={styles.totalRow}>
            <Text style={styles.totalLabel}>Subtotal</Text>
            <Text style={styles.totalValue}>${subtotal.toFixed(2)}</Text>
          </View>
          <View style={styles.totalRow}>
            <Text style={styles.totalLabel}>Tax</Text>
            <Text style={styles.totalValue}>${(taxCents / 100).toFixed(2)}</Text>
          </View>
          <View style={styles.totalRow}>
            <Text style={styles.totalLabel}>Tip</Text>
            <Text style={styles.totalValue}>${(tipCents / 100).toFixed(2)}</Text>
          </View>
          <View style={[styles.totalRow, styles.grandTotalRow]}>
            <Text style={styles.grandLabel}>Total</Text>
            <Text style={styles.grandValue}>${total.toFixed(2)}</Text>
          </View>
        </View>

        <TouchableOpacity
          style={[styles.continueBtn, persisting && { opacity: 0.7 }]}
          onPress={handleContinue}
          disabled={persisting}
          activeOpacity={0.85}
        >
          {persisting ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.continueBtnText}>Add Friends →</Text>
          )}
        </TouchableOpacity>

        <View style={{ height: 32 }} />
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  scroll: {
    padding: 16,
    gap: 14,
  },
  card: {
    backgroundColor: '#fff',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    padding: 16,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 8,
    elevation: 3,
  },
  sectionHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 12,
  },
  sectionLabel: {
    fontSize: 12,
    fontWeight: '800',
    color: '#6B7280',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginBottom: 10,
  },
  restaurantInput: {
    fontSize: 20,
    fontWeight: '800',
    color: '#111827',
    paddingVertical: 4,
    borderBottomWidth: 2,
    borderBottomColor: '#E5E7EB',
  },
  addBtn: {
    backgroundColor: '#E8F5E9',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  addBtnText: {
    fontSize: 13,
    fontWeight: '800',
    color: BRAND,
  },
  emptyItems: {
    textAlign: 'center',
    color: '#9CA3AF',
    fontWeight: '600',
    fontSize: 14,
    paddingVertical: 12,
  },
  itemRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 10,
    gap: 10,
  },
  itemRowBorder: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: '#F3F4F6',
  },
  itemLeft: {
    flex: 1,
    gap: 4,
  },
  itemNameInput: {
    fontSize: 15,
    fontWeight: '700',
    color: '#111827',
    paddingVertical: 2,
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
  },
  itemMeta: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
  },
  metaLabel: {
    fontSize: 12,
    fontWeight: '600',
    color: '#9CA3AF',
  },
  qtyInput: {
    fontSize: 13,
    fontWeight: '700',
    color: '#374151',
    width: 32,
    textAlign: 'center',
    borderBottomWidth: 1,
    borderBottomColor: '#E5E7EB',
    paddingVertical: 1,
  },
  itemRight: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  priceInputWrap: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#F9FAFB',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 8,
    paddingHorizontal: 8,
    paddingVertical: 4,
  },
  dollarSign: {
    fontSize: 14,
    fontWeight: '700',
    color: '#374151',
  },
  priceInput: {
    fontSize: 15,
    fontWeight: '700',
    color: '#111827',
    minWidth: 56,
    paddingVertical: 4,
    paddingLeft: 2,
  },
  deleteBtn: {
    padding: 4,
  },
  deleteX: {
    width: 20,
    height: 20,
    alignItems: 'center',
    justifyContent: 'center',
  },
  deleteBar: {
    position: 'absolute',
    width: 14,
    height: 2,
    backgroundColor: '#EF4444',
    borderRadius: 1,
  },
  taxRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 10,
  },
  taxLabel: {
    fontSize: 15,
    fontWeight: '700',
    color: '#374151',
  },
  tipPctRow: {
    flexDirection: 'row',
    gap: 8,
    marginTop: 4,
  },
  tipPctBtn: {
    flex: 1,
    backgroundColor: '#F3F4F6',
    borderRadius: 8,
    paddingVertical: 8,
    alignItems: 'center',
  },
  tipPctText: {
    fontSize: 13,
    fontWeight: '800',
    color: BRAND,
  },
  totalsCard: {
    backgroundColor: '#fff',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    padding: 16,
    gap: 8,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 8,
    elevation: 3,
  },
  totalRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  totalLabel: {
    fontSize: 14,
    fontWeight: '600',
    color: '#6B7280',
  },
  totalValue: {
    fontSize: 14,
    fontWeight: '700',
    color: '#374151',
  },
  grandTotalRow: {
    marginTop: 6,
    paddingTop: 10,
    borderTopWidth: 1.5,
    borderTopColor: '#E5E7EB',
  },
  grandLabel: {
    fontSize: 17,
    fontWeight: '900',
    color: '#111827',
  },
  grandValue: {
    fontSize: 20,
    fontWeight: '900',
    color: BRAND,
  },
  continueBtn: {
    backgroundColor: BRAND,
    borderRadius: 14,
    paddingVertical: 16,
    alignItems: 'center',
    shadowColor: BRAND,
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.25,
    shadowRadius: 8,
    elevation: 4,
  },
  continueBtnText: {
    color: '#fff',
    fontSize: 17,
    fontWeight: '800',
  },
});

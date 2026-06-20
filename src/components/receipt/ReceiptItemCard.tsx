import React from 'react';
import { StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { Participant, ReceiptItem } from '../../context/receiptSplitContext';
import SebivAvatar from '../SebivAvatar';

const BRAND = '#1B5E20';

type Props = {
  item: ReceiptItem;
  assignedParticipants: Participant[];
  allParticipants: Participant[];
  onToggle: (participantId: string) => void;
  onLongPress?: () => void;
};

function formatPrice(price: number, quantity: number): string {
  const total = price * quantity;
  return `$${total.toFixed(2)}`;
}

export default function ReceiptItemCard({
  item,
  assignedParticipants,
  allParticipants,
  onToggle,
  onLongPress,
}: Props) {
  const assignedIds = new Set(assignedParticipants.map(p => p.id));

  return (
    <TouchableOpacity
      activeOpacity={0.92}
      onLongPress={onLongPress}
      style={styles.card}
    >
      <View style={styles.header}>
        <View style={styles.nameWrap}>
          <Text style={styles.itemName} numberOfLines={1}>{item.name}</Text>
          {item.quantity > 1 && (
            <Text style={styles.qtyBadge}>x{item.quantity}</Text>
          )}
        </View>
        <Text style={styles.price}>{formatPrice(item.price, item.quantity)}</Text>
      </View>

      <View style={styles.bubblesRow}>
        {allParticipants.map(p => {
          const isAssigned = assignedIds.has(p.id);
          return (
            <TouchableOpacity
              key={p.id}
              onPress={() => onToggle(p.id)}
              activeOpacity={0.7}
              style={[styles.bubbleWrap, isAssigned && styles.bubbleWrapActive]}
            >
              <View
                style={[
                  styles.avatarRing,
                  { borderColor: isAssigned ? BRAND : '#D1D5DB' },
                ]}
              >
                <SebivAvatar uri={p.avatar_url} size={30} />
              </View>
              <Text
                style={[styles.bubbleName, isAssigned && styles.bubbleNameActive]}
                numberOfLines={1}
              >
                {p.name.split(' ')[0]}
              </Text>
            </TouchableOpacity>
          );
        })}
        {allParticipants.length === 0 && (
          <Text style={styles.noParticipants}>No participants added yet</Text>
        )}
      </View>

      {onLongPress && (
        <Text style={styles.longPressHint}>Long press for custom split</Text>
      )}
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: '#fff',
    borderRadius: 12,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    padding: 14,
    marginHorizontal: 16,
    marginBottom: 10,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 8,
    elevation: 3,
  },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 10,
  },
  nameWrap: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  itemName: {
    fontSize: 15,
    fontWeight: '700',
    color: '#111827',
    flex: 1,
  },
  qtyBadge: {
    fontSize: 12,
    fontWeight: '800',
    color: '#6B7280',
    backgroundColor: '#F3F4F6',
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 6,
  },
  price: {
    fontSize: 16,
    fontWeight: '800',
    color: BRAND,
  },
  bubblesRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
  },
  bubbleWrap: {
    alignItems: 'center',
    gap: 3,
    opacity: 0.45,
  },
  bubbleWrapActive: {
    opacity: 1,
  },
  avatarRing: {
    borderWidth: 2,
    borderRadius: 18,
    padding: 1,
  },
  bubbleName: {
    fontSize: 10,
    fontWeight: '700',
    color: '#9CA3AF',
    maxWidth: 38,
    textAlign: 'center',
  },
  bubbleNameActive: {
    color: BRAND,
  },
  noParticipants: {
    fontSize: 12,
    fontWeight: '600',
    color: '#9CA3AF',
    fontStyle: 'italic',
  },
  longPressHint: {
    marginTop: 8,
    fontSize: 10,
    fontWeight: '600',
    color: '#9CA3AF',
    textAlign: 'right',
  },
});

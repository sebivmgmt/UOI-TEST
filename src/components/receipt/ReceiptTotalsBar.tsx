import React, { useEffect, useRef } from 'react';
import { Animated, ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { Participant } from '../../context/receiptSplitContext';
import { ParticipantTotal, formatCents } from '../../services/splitCalculator';

const BRAND = '#1B5E20';

type Props = {
  participants: Participant[];
  totals: ParticipantTotal[];
  onContinue: () => void;
  continueLabel?: string;
};

function AnimatedChip({ name, cents }: { name: string; cents: number }) {
  const scale = useRef(new Animated.Value(1)).current;
  const prevCents = useRef(cents);

  useEffect(() => {
    if (prevCents.current !== cents) {
      prevCents.current = cents;
      Animated.sequence([
        Animated.spring(scale, { toValue: 1.1, useNativeDriver: true, speed: 50, bounciness: 6 }),
        Animated.spring(scale, { toValue: 1, useNativeDriver: true, speed: 30, bounciness: 4 }),
      ]).start();
    }
  }, [cents]);

  return (
    <Animated.View style={[styles.personChip, { transform: [{ scale }] }]}>
      <Text style={styles.chipName} numberOfLines={1}>{name.split(' ')[0]}</Text>
      <Text style={[styles.chipAmount, cents === 0 && styles.chipAmountZero]}>
        {formatCents(cents)}
      </Text>
    </Animated.View>
  );
}

export default function ReceiptTotalsBar({
  participants,
  totals,
  onContinue,
  continueLabel = 'Continue',
}: Props) {
  const totalMap = Object.fromEntries(totals.map(t => [t.participantId, t]));

  return (
    <View style={styles.container}>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={styles.scrollContent}
      >
        {participants.map(p => {
          const t = totalMap[p.id];
          const cents = t?.totalCents ?? 0;
          return <AnimatedChip key={p.id} name={p.name} cents={cents} />;
        })}
      </ScrollView>

      <TouchableOpacity style={styles.continueBtn} onPress={onContinue} activeOpacity={0.85}>
        <Text style={styles.continueText}>{continueLabel} →</Text>
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    backgroundColor: '#fff',
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 12,
    paddingHorizontal: 16,
    borderTopWidth: 1,
    borderTopColor: '#E5E7EB',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: -3 },
    shadowOpacity: 0.07,
    shadowRadius: 8,
    elevation: 8,
    gap: 12,
  },
  scrollContent: {
    flexDirection: 'row',
    gap: 10,
    paddingRight: 4,
  },
  personChip: {
    alignItems: 'center',
    backgroundColor: '#F3F4F6',
    borderRadius: 10,
    paddingHorizontal: 10,
    paddingVertical: 6,
    minWidth: 60,
  },
  chipName: {
    fontSize: 11,
    fontWeight: '700',
    color: '#6B7280',
    marginBottom: 2,
  },
  chipAmount: {
    fontSize: 13,
    fontWeight: '900',
    color: BRAND,
  },
  chipAmountZero: {
    color: '#9CA3AF',
  },
  continueBtn: {
    backgroundColor: BRAND,
    borderRadius: 12,
    paddingHorizontal: 18,
    paddingVertical: 12,
    minWidth: 120,
    alignItems: 'center',
  },
  continueText: {
    color: '#fff',
    fontWeight: '800',
    fontSize: 15,
  },
});

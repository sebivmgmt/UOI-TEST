import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import SebivAvatar from '../SebivAvatar';
import { formatCents } from '../../services/splitCalculator';

const BRAND = '#1B5E20';

type Props = {
  fromName: string;
  toName: string;
  amountCents: number;
  fromAvatarUrl?: string | null;
  toAvatarUrl?: string | null;
};

export default function SplitSummaryCard({
  fromName,
  toName,
  amountCents,
  fromAvatarUrl,
  toAvatarUrl,
}: Props) {
  return (
    <View style={styles.card}>
      <View style={styles.avatarRow}>
        <View style={styles.personWrap}>
          <SebivAvatar uri={fromAvatarUrl} size={52} />
          <Text style={styles.personName} numberOfLines={1}>{fromName}</Text>
        </View>

        <View style={styles.arrowWrap}>
          <View style={styles.arrowLine} />
          <View style={styles.arrowHead} />
          <Text style={styles.amountLabel}>{formatCents(amountCents)}</Text>
        </View>

        <View style={styles.personWrap}>
          <SebivAvatar uri={toAvatarUrl} size={52} />
          <Text style={styles.personName} numberOfLines={1}>{toName}</Text>
        </View>
      </View>

      <Text style={styles.owesLine}>
        <Text style={styles.owesName}>{fromName}</Text>
        <Text style={styles.owesText}> owes </Text>
        <Text style={styles.owesName}>{toName}</Text>
      </Text>

      <View style={styles.amountRow}>
        <Text style={styles.bigAmount}>{formatCents(amountCents)}</Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: '#fff',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    padding: 20,
    marginHorizontal: 16,
    marginBottom: 12,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 8,
    elevation: 3,
  },
  avatarRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 12,
    marginBottom: 14,
  },
  personWrap: {
    alignItems: 'center',
    gap: 6,
    width: 70,
  },
  personName: {
    fontSize: 12,
    fontWeight: '700',
    color: '#374151',
    textAlign: 'center',
  },
  arrowWrap: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 4,
  },
  arrowLine: {
    height: 2,
    backgroundColor: BRAND,
    width: '80%',
    borderRadius: 2,
  },
  arrowHead: {
    width: 0,
    height: 0,
    borderTopWidth: 6,
    borderBottomWidth: 6,
    borderLeftWidth: 10,
    borderTopColor: 'transparent',
    borderBottomColor: 'transparent',
    borderLeftColor: BRAND,
    marginTop: -2,
    alignSelf: 'flex-end',
    marginRight: 4,
  },
  amountLabel: {
    fontSize: 12,
    fontWeight: '800',
    color: BRAND,
  },
  owesLine: {
    textAlign: 'center',
    marginBottom: 6,
  },
  owesName: {
    fontSize: 14,
    fontWeight: '800',
    color: '#111827',
  },
  owesText: {
    fontSize: 14,
    fontWeight: '600',
    color: '#6B7280',
  },
  amountRow: {
    alignItems: 'center',
  },
  bigAmount: {
    fontSize: 32,
    fontWeight: '900',
    color: BRAND,
    letterSpacing: -0.5,
  },
});

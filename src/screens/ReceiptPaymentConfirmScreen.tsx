import React from 'react';
import {
  Alert,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import SebivAvatar from '../components/SebivAvatar';
import { formatCents } from '../services/splitCalculator';

const BRAND = '#1B5E20';
const BG = '#F5F7F9';

type Props = {
  navigation: any;
  route: {
    params: {
      recipientName: string;
      payerName: string;
      amountCents: number;
    };
  };
};

export default function ReceiptPaymentConfirmScreen({ navigation, route }: Props) {
  const { recipientName, payerName, amountCents } = route.params;

  function handleApprove() {
    Alert.alert('Sent!', `Your payment request was sent to ${payerName}.`, [
      { text: 'OK', onPress: () => navigation.goBack() },
    ]);
  }

  function handleDecline() {
    navigation.goBack();
  }

  return (
    <View style={styles.container}>
      <View style={styles.card}>
        <Text style={styles.eyebrow}>Payment Request</Text>

        <View style={styles.amountBlock}>
          <Text style={styles.amount}>{formatCents(amountCents)}</Text>
          <Text style={styles.amountSub}>due to {payerName}</Text>
        </View>

        <View style={styles.avatarSection}>
          <SebivAvatar uri={null} size={72} />
          <Text style={styles.payerName}>{payerName}</Text>
          <Text style={styles.payerRole}>Paid the bill tonight</Text>
        </View>

        <View style={styles.detailsBox}>
          <View style={styles.detailRow}>
            <Text style={styles.detailLabel}>From</Text>
            <Text style={styles.detailValue}>{recipientName}</Text>
          </View>
          <View style={styles.detailRow}>
            <Text style={styles.detailLabel}>To</Text>
            <Text style={styles.detailValue}>{payerName}</Text>
          </View>
          <View style={styles.detailRow}>
            <Text style={styles.detailLabel}>Amount</Text>
            <Text style={[styles.detailValue, styles.detailAmountValue]}>
              {formatCents(amountCents)}
            </Text>
          </View>
          <View style={styles.detailRow}>
            <Text style={styles.detailLabel}>Status</Text>
            <View style={styles.pendingBadge}>
              <Text style={styles.pendingBadgeText}>Pending</Text>
            </View>
          </View>
        </View>
      </View>

      <View style={styles.actionsWrap}>
        <TouchableOpacity style={styles.approveBtn} onPress={handleApprove} activeOpacity={0.85}>
          <Text style={styles.approveBtnText}>Approve</Text>
        </TouchableOpacity>

        <TouchableOpacity style={styles.declineBtn} onPress={handleDecline} activeOpacity={0.75}>
          <Text style={styles.declineBtnText}>Decline</Text>
        </TouchableOpacity>

        <Text style={styles.disclaimer}>
          Powered by IOU · Linked bank coming soon
        </Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: BG,
    padding: 20,
    justifyContent: 'space-between',
  },
  card: {
    backgroundColor: '#fff',
    borderRadius: 24,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    padding: 28,
    alignItems: 'center',
    gap: 20,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 8,
    elevation: 3,
  },
  eyebrow: {
    fontSize: 12,
    fontWeight: '800',
    color: '#9CA3AF',
    textTransform: 'uppercase',
    letterSpacing: 1,
  },
  amountBlock: {
    alignItems: 'center',
    gap: 4,
  },
  amount: {
    fontSize: 52,
    fontWeight: '900',
    color: '#111827',
    letterSpacing: -1,
  },
  amountSub: {
    fontSize: 16,
    fontWeight: '600',
    color: '#6B7280',
  },
  avatarSection: {
    alignItems: 'center',
    gap: 8,
  },
  payerName: {
    fontSize: 18,
    fontWeight: '800',
    color: '#111827',
  },
  payerRole: {
    fontSize: 13,
    fontWeight: '600',
    color: '#9CA3AF',
  },
  detailsBox: {
    width: '100%',
    backgroundColor: '#F9FAFB',
    borderRadius: 14,
    padding: 16,
    gap: 10,
  },
  detailRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  detailLabel: {
    fontSize: 13,
    fontWeight: '700',
    color: '#6B7280',
  },
  detailValue: {
    fontSize: 14,
    fontWeight: '700',
    color: '#111827',
  },
  detailAmountValue: {
    color: BRAND,
    fontWeight: '900',
    fontSize: 15,
  },
  pendingBadge: {
    backgroundColor: '#FEF3C7',
    borderRadius: 6,
    paddingHorizontal: 8,
    paddingVertical: 3,
  },
  pendingBadgeText: {
    fontSize: 12,
    fontWeight: '800',
    color: '#92400E',
  },
  actionsWrap: {
    gap: 12,
    paddingBottom: 16,
  },
  approveBtn: {
    backgroundColor: BRAND,
    borderRadius: 16,
    paddingVertical: 18,
    alignItems: 'center',
    shadowColor: BRAND,
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.25,
    shadowRadius: 8,
    elevation: 4,
  },
  approveBtnText: {
    color: '#fff',
    fontSize: 18,
    fontWeight: '900',
  },
  declineBtn: {
    borderWidth: 1.5,
    borderColor: '#E5E7EB',
    borderRadius: 16,
    paddingVertical: 16,
    alignItems: 'center',
  },
  declineBtnText: {
    fontSize: 16,
    fontWeight: '700',
    color: '#6B7280',
  },
  disclaimer: {
    textAlign: 'center',
    fontSize: 12,
    fontWeight: '600',
    color: '#9CA3AF',
    marginTop: 4,
  },
});

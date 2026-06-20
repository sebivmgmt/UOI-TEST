import React, { useEffect } from 'react';
import { StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { useReceiptSplit } from '../context/receiptSplitContext';
import { createEmptyDraft } from '../services/receiptParser';

const BRAND = '#1B5E20';
const BG = '#F5F7F9';

type Props = { navigation: any };

export default function SplitReceiptScreen({ navigation }: Props) {
  const { reset, setDraft } = useReceiptSplit();

  useEffect(() => {
    reset();
  }, []);

  return (
    <View style={styles.container}>
      <View style={styles.heroCard}>
        <View style={styles.iconWrap}>
          <View style={styles.iconOuter}>
            <View style={styles.iconInner}>
              <View style={styles.receiptLine} />
              <View style={[styles.receiptLine, { width: '70%' }]} />
              <View style={[styles.receiptLine, { width: '85%' }]} />
              <View style={[styles.receiptLine, { width: '60%' }]} />
              <View style={styles.receiptDivider} />
              <View style={[styles.receiptLine, { width: '90%' }]} />
            </View>
          </View>
        </View>

        <Text style={styles.heading}>Split a Receipt</Text>
        <Text style={styles.subtitle}>
          Scan your receipt and split with friends instantly
        </Text>

        <TouchableOpacity
          style={styles.primaryBtn}
          onPress={() => navigation.navigate('ReceiptCamera')}
          activeOpacity={0.85}
        >
          <Text style={styles.primaryBtnText}>Scan Receipt</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={styles.secondaryBtn}
          onPress={() => {
            setDraft(createEmptyDraft());
            navigation.navigate('ReceiptReview');
          }}
          activeOpacity={0.75}
        >
          <Text style={styles.secondaryBtnText}>Enter Manually</Text>
        </TouchableOpacity>
      </View>

      <View style={styles.featureRow}>
        {[
          { label: 'Instant Split', desc: 'Equal or custom per item' },
          { label: 'Send IOUs', desc: 'Track who owes what' },
          { label: 'No Math', desc: 'We handle the rounding' },
        ].map(f => (
          <View key={f.label} style={styles.featureCard}>
            <Text style={styles.featureLabel}>{f.label}</Text>
            <Text style={styles.featureDesc}>{f.desc}</Text>
          </View>
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: BG,
    paddingHorizontal: 20,
    paddingTop: 24,
    gap: 20,
  },
  heroCard: {
    backgroundColor: '#fff',
    borderRadius: 24,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    padding: 28,
    alignItems: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 8,
    elevation: 3,
  },
  iconWrap: {
    marginBottom: 20,
  },
  iconOuter: {
    width: 80,
    height: 80,
    borderRadius: 20,
    backgroundColor: '#E8F5E9',
    alignItems: 'center',
    justifyContent: 'center',
  },
  iconInner: {
    width: 44,
    height: 52,
    backgroundColor: '#fff',
    borderRadius: 6,
    borderWidth: 1.5,
    borderColor: BRAND,
    padding: 6,
    gap: 5,
    justifyContent: 'center',
  },
  receiptLine: {
    height: 3,
    width: '100%',
    backgroundColor: '#C8E6C9',
    borderRadius: 2,
  },
  receiptDivider: {
    height: 1,
    width: '100%',
    backgroundColor: BRAND,
    marginVertical: 2,
  },
  heading: {
    fontSize: 28,
    fontWeight: '900',
    color: '#111827',
    textAlign: 'center',
    marginBottom: 8,
  },
  subtitle: {
    fontSize: 15,
    fontWeight: '600',
    color: '#6B7280',
    textAlign: 'center',
    lineHeight: 22,
    marginBottom: 28,
    paddingHorizontal: 8,
  },
  primaryBtn: {
    backgroundColor: BRAND,
    borderRadius: 14,
    paddingVertical: 16,
    paddingHorizontal: 32,
    width: '100%',
    alignItems: 'center',
    marginBottom: 12,
    shadowColor: BRAND,
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.25,
    shadowRadius: 8,
    elevation: 4,
  },
  primaryBtnText: {
    color: '#fff',
    fontSize: 17,
    fontWeight: '800',
  },
  secondaryBtn: {
    borderWidth: 1.5,
    borderColor: '#E5E7EB',
    borderRadius: 14,
    paddingVertical: 14,
    paddingHorizontal: 32,
    width: '100%',
    alignItems: 'center',
  },
  secondaryBtnText: {
    color: '#374151',
    fontSize: 15,
    fontWeight: '700',
  },
  featureRow: {
    flexDirection: 'row',
    gap: 10,
  },
  featureCard: {
    flex: 1,
    backgroundColor: '#fff',
    borderRadius: 14,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    padding: 14,
    alignItems: 'center',
    gap: 4,
  },
  featureLabel: {
    fontSize: 12,
    fontWeight: '800',
    color: BRAND,
    textAlign: 'center',
  },
  featureDesc: {
    fontSize: 11,
    fontWeight: '600',
    color: '#9CA3AF',
    textAlign: 'center',
    lineHeight: 15,
  },
});

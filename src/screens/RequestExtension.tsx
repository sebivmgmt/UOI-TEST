// src/screens/RequestExtension.tsx
import React, { useEffect, useState } from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
  Alert,
  ScrollView,
  Platform,
} from 'react-native';
import DateTimePicker from '@react-native-community/datetimepicker';
import { supabase } from '../supabase';

const GREEN = '#1B5E20';
const GREEN_LIGHT = '#EEF7EE';

const currency = (c: number) => `$${(c / 100).toFixed(2)}`;

const fmt = (d: Date) =>
  d.toLocaleDateString(undefined, { month: 'long', day: 'numeric', year: 'numeric' });

export default function RequestExtension({ route, navigation }: any) {
  const {
    paymentId,
    iouId: _iouId,
    scheduledAt,
    paymentAmount,
    title,
  }: {
    paymentId: string;
    iouId: string;
    scheduledAt: string;
    paymentAmount?: number;
    title?: string | null;
  } = route.params;

  const originalDue = new Date(scheduledAt);
  const maxDate = new Date(originalDue);
  maxDate.setDate(maxDate.getDate() + 14);

  const minDate = new Date(originalDue);
  minDate.setDate(minDate.getDate() + 1);

  const [me, setMe] = useState<string | null>(null);
  const [extendUntil, setExtendUntil] = useState<Date>(minDate);
  const [showPicker, setShowPicker] = useState(Platform.OS === 'ios');
  const [reason, setReason] = useState('');
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      setMe(data.user?.id ?? null);
    });
  }, []);

  const handleSubmit = async () => {
    if (!me) {
      Alert.alert('Not signed in', 'Please sign in again.');
      return;
    }
    if (extendUntil <= originalDue) {
      Alert.alert('Invalid date', 'The extension date must be after the original due date.');
      return;
    }
    if (extendUntil > maxDate) {
      Alert.alert('Too far out', 'Extensions are limited to 14 days past the original due date.');
      return;
    }

    setSubmitting(true);
    try {
      const { error } = await supabase
        .from('payments')
        .update({
          extension_requested_at: new Date().toISOString(),
          extension_requested_by: me,
          extension_requested_until: extendUntil.toISOString().slice(0, 10),
          extension_status: 'requested',
          extension_reason: reason.trim() || null,
        })
        .eq('id', paymentId);

      if (error) throw error;

      Alert.alert(
        'Extension requested',
        'Your lender will be notified and can approve or deny this request.',
        [{ text: 'OK', onPress: () => navigation.goBack() }]
      );
    } catch (e: any) {
      Alert.alert('Request failed', e.message ?? String(e));
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <ScrollView
      contentContainerStyle={s.scroll}
      keyboardShouldPersistTaps="handled"
      showsVerticalScrollIndicator={false}
    >
      <View style={s.infoCard}>
        {!!title && (
          <>
            <Text style={s.label}>LOAN</Text>
            <Text style={s.value}>{title}</Text>
          </>
        )}
        {!!paymentAmount && (
          <>
            <Text style={[s.label, { marginTop: 12 }]}>PAYMENT AMOUNT</Text>
            <Text style={s.value}>{currency(paymentAmount)}</Text>
          </>
        )}
        <Text style={[s.label, { marginTop: 12 }]}>ORIGINAL DUE DATE</Text>
        <Text style={s.value}>{fmt(originalDue)}</Text>
        <Text style={[s.label, { marginTop: 12 }]}>MAX EXTENSION DATE</Text>
        <Text style={[s.value, { color: GREEN }]}>{fmt(maxDate)}</Text>
      </View>

      <View style={s.section}>
        <Text style={s.sectionTitle}>Requested new due date</Text>
        <Text style={s.sectionSub}>
          Choose any date up to 14 days after the original due date. Future payments are not affected.
        </Text>

        {Platform.OS === 'android' && (
          <TouchableOpacity style={s.dateBtn} onPress={() => setShowPicker(true)}>
            <Text style={s.dateBtnText}>{fmt(extendUntil)}</Text>
            <Text style={s.dateBtnChange}>Change ›</Text>
          </TouchableOpacity>
        )}

        {showPicker && (
          <DateTimePicker
            value={extendUntil}
            mode="date"
            display={Platform.OS === 'ios' ? 'spinner' : 'default'}
            minimumDate={minDate}
            maximumDate={maxDate}
            onChange={(_, selected) => {
              if (Platform.OS === 'android') setShowPicker(false);
              if (selected) setExtendUntil(selected);
            }}
          />
        )}

        {Platform.OS === 'ios' && (
          <Text style={s.selectedDateText}>Requesting extension until {fmt(extendUntil)}</Text>
        )}
      </View>

      <View style={s.section}>
        <Text style={s.sectionTitle}>Reason (optional)</Text>
        <TextInput
          style={s.input}
          placeholder="Briefly explain why you need more time…"
          placeholderTextColor="#aaa"
          multiline
          numberOfLines={3}
          value={reason}
          onChangeText={setReason}
          maxLength={240}
          textAlignVertical="top"
        />
      </View>

      <View style={s.notice}>
        <Text style={s.noticeText}>
          An extension applies only to this specific payment and does not change, pause, delay, or reschedule any future payments under the IOU. If approved by the lender, this payment's due date may be extended by up to 14 calendar days. An approved extension does not negatively affect your IOU Score during the approved extension window.{'\n\n'}A payment extension is different from a loan reschedule. A reschedule changes the repayment structure of the IOU and may affect your IOU Score.
        </Text>
      </View>

      {submitting ? (
        <ActivityIndicator color={GREEN} style={{ marginTop: 8 }} />
      ) : (
        <TouchableOpacity style={s.submitBtn} onPress={handleSubmit} activeOpacity={0.85}>
          <Text style={s.submitBtnText}>Request Extension</Text>
        </TouchableOpacity>
      )}
    </ScrollView>
  );
}

const s = StyleSheet.create({
  scroll: {
    padding: 16,
    paddingBottom: 60,
  },
  infoCard: {
    backgroundColor: '#fff',
    borderRadius: 14,
    padding: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    marginBottom: 20,
  },
  label: {
    fontSize: 11,
    fontWeight: '800',
    color: '#777',
    textTransform: 'uppercase',
    letterSpacing: 0.4,
  },
  value: {
    fontSize: 16,
    fontWeight: '700',
    color: '#111827',
    marginTop: 3,
  },
  section: {
    marginBottom: 20,
  },
  sectionTitle: {
    fontSize: 15,
    fontWeight: '800',
    color: '#111827',
    marginBottom: 4,
  },
  sectionSub: {
    fontSize: 13,
    color: '#667085',
    fontWeight: '600',
    marginBottom: 12,
    lineHeight: 18,
  },
  dateBtn: {
    backgroundColor: '#fff',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 12,
    padding: 14,
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  dateBtnText: {
    fontSize: 16,
    fontWeight: '700',
    color: '#111827',
  },
  dateBtnChange: {
    fontSize: 14,
    fontWeight: '700',
    color: GREEN,
  },
  selectedDateText: {
    marginTop: 10,
    fontSize: 14,
    fontWeight: '700',
    color: GREEN,
    textAlign: 'center',
  },
  input: {
    backgroundColor: '#fff',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 12,
    padding: 14,
    fontSize: 15,
    color: '#111',
    minHeight: 90,
  },
  notice: {
    backgroundColor: GREEN_LIGHT,
    borderRadius: 12,
    padding: 14,
    marginBottom: 24,
    borderWidth: 1,
    borderColor: '#D0E8D0',
  },
  noticeText: {
    fontSize: 13,
    color: '#374151',
    lineHeight: 20,
    fontWeight: '600',
  },
  submitBtn: {
    backgroundColor: GREEN,
    borderRadius: 14,
    paddingVertical: 16,
    alignItems: 'center',
  },
  submitBtnText: {
    color: '#fff',
    fontWeight: '900',
    fontSize: 16,
  },
});

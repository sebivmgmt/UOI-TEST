// src/screens/RequestExtension.tsx
import React, { useEffect, useMemo, useState } from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
  Alert,
  Platform,
  KeyboardAvoidingView,
  ScrollView,
} from 'react-native';
import DateTimePicker from '@react-native-community/datetimepicker';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { requestPaymentExtension, ExtensionError } from '../services/paymentExtensionService';
import IouStepProgress from '../components/iou/IouStepProgress';
import { supabase } from '../supabase';
import { parseDateInput, formatDateInput, addDays, startOfLocalDay } from '../utils/dateUtils';

const GREEN = '#1B5E20';
const GREEN_LIGHT = '#EEF7EE';
const TOTAL_STEPS = 3;

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

  const insets = useSafeAreaInsets();

  // scheduledAt is a plain YYYY-MM-DD date string. It must be parsed as a local
  // calendar date, not via `new Date(string)` (which parses as UTC midnight and
  // can shift the displayed/compared date back a day in negative-UTC-offset zones).
  const originalDue = useMemo(() => parseDateInput(scheduledAt), [scheduledAt]);
  const minDate = useMemo(() => (originalDue ? addDays(originalDue, 1) : null), [originalDue]);
  const maxDate = useMemo(() => (originalDue ? addDays(originalDue, 14) : null), [originalDue]);

  const [me, setMe] = useState<string | null>(null);
  const [step, setStep] = useState(0);
  const [extendUntil, setExtendUntil] = useState<Date | null>(minDate);
  const [showAndroidPicker, setShowAndroidPicker] = useState(false);
  const [reason, setReason] = useState('');
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      setMe(data.user?.id ?? null);
    });
  }, []);

  // Keep the selected date in sync if minDate becomes available/changes (defensive;
  // route params are stable in practice, but this avoids a stuck null state).
  useEffect(() => {
    if (minDate) setExtendUntil((curr) => curr ?? minDate);
  }, [minDate]);

  const handleStepPress = (s: number) => {
    if (s < step) setStep(s);
  };

  const handleNext = () => {
    if (step === 0) {
      if (!extendUntil || !originalDue || !maxDate) return;
      if (extendUntil <= originalDue) {
        Alert.alert('Invalid date', 'The extension date must be after the original due date.');
        return;
      }
      if (extendUntil > maxDate) {
        Alert.alert('Too far out', 'Extensions are limited to 14 days past the original due date.');
        return;
      }
    }
    setStep((s) => s + 1);
  };

  const handleSubmit = async () => {
    if (!me) {
      Alert.alert('Not signed in', 'Please sign in again.');
      return;
    }
    if (!extendUntil) {
      Alert.alert('Invalid date', 'Please select a valid extension date.');
      return;
    }
    setSubmitting(true);
    try {
      await requestPaymentExtension(
        paymentId,
        formatDateInput(extendUntil),
        reason.trim() || null,
      );
      Alert.alert(
        'Extension requested',
        'Your lender will be notified and can approve or deny this request.',
        [{ text: 'OK', onPress: () => navigation.goBack() }],
      );
    } catch (e: unknown) {
      const msg =
        e instanceof ExtensionError
          ? e.userMessage
          : 'Could not submit the request. Please try again.';
      Alert.alert('Request failed', msg);
    } finally {
      setSubmitting(false);
    }
  };

  const footerPaddingBottom =
    insets.bottom > 0 ? insets.bottom : Platform.OS === 'ios' ? 28 : 14;

  const STEP_LABELS = ['Date', 'Note', 'Review'];

  if (!originalDue || !minDate || !maxDate || !extendUntil) {
    return (
      <View style={s.errorScreen}>
        <Text style={s.errorTitle}>Couldn't load payment details</Text>
        <Text style={s.errorText}>
          The payment due date is invalid. Please go back and try again.
        </Text>
        <TouchableOpacity
          style={[s.btn, s.btnPrimary, { marginTop: 16, alignSelf: 'stretch' }]}
          onPress={() => navigation.goBack()}
          activeOpacity={0.85}
        >
          <Text style={s.btnPrimaryText}>Go back</Text>
        </TouchableOpacity>
      </View>
    );
  }

  return (
    <KeyboardAvoidingView
      style={s.outer}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      keyboardVerticalOffset={90}
    >
      {/* Progress */}
      <View style={s.progressRow}>
        <IouStepProgress
          total={TOTAL_STEPS}
          current={step + 1}
          onStepPress={handleStepPress}
        />
        <Text style={s.stepLabel}>{STEP_LABELS[step]}</Text>
      </View>

      {/* Content */}
      <ScrollView
        style={s.scroll}
        contentContainerStyle={s.scrollContent}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      >
        {/* Step 0 — Date */}
        {step === 0 && (
          <View style={s.card}>
            {/* Payment summary */}
            {!!title && <Text style={s.summaryTitle}>{title}</Text>}
            <View style={s.summaryMeta}>
              {!!paymentAmount && (
                <View style={s.metaItem}>
                  <Text style={s.metaLabel}>PAYMENT</Text>
                  <Text style={s.metaValue}>{currency(paymentAmount)}</Text>
                </View>
              )}
              <View style={s.metaItem}>
                <Text style={s.metaLabel}>ORIGINAL DUE</Text>
                <Text style={s.metaValue}>{fmt(originalDue)}</Text>
              </View>
              <View style={s.metaItem}>
                <Text style={s.metaLabel}>MAX EXTENSION</Text>
                <Text style={[s.metaValue, { color: GREEN }]}>{fmt(maxDate)}</Text>
              </View>
            </View>

            <View style={s.divider} />

            <Text style={s.fieldLabel}>New requested due date</Text>

            {Platform.OS === 'ios' ? (
              <DateTimePicker
                value={extendUntil}
                mode="date"
                display="compact"
                minimumDate={minDate}
                maximumDate={maxDate}
                onChange={(_, selected) => {
                  if (selected) setExtendUntil(startOfLocalDay(selected));
                }}
                style={s.compactPicker}
              />
            ) : (
              <>
                <TouchableOpacity
                  style={s.androidDateBtn}
                  onPress={() => setShowAndroidPicker(true)}
                >
                  <Text style={s.androidDateText}>{fmt(extendUntil)}</Text>
                  <Text style={s.androidDateChange}>Change ›</Text>
                </TouchableOpacity>
                {showAndroidPicker && (
                  <DateTimePicker
                    value={extendUntil}
                    mode="date"
                    display="default"
                    minimumDate={minDate}
                    maximumDate={maxDate}
                    onChange={(_, selected) => {
                      setShowAndroidPicker(false);
                      if (selected) setExtendUntil(startOfLocalDay(selected));
                    }}
                  />
                )}
              </>
            )}

            <Text style={s.limitNote}>Up to 14 days past the original due date.</Text>
          </View>
        )}

        {/* Step 1 — Note */}
        {step === 1 && (
          <View style={s.card}>
            <Text style={s.fieldLabel}>Reason (optional)</Text>
            <Text style={s.fieldSub}>
              Briefly explain why you need more time. Your lender will see this.
            </Text>
            <TextInput
              style={s.noteInput}
              placeholder="e.g. Waiting on a paycheck…"
              placeholderTextColor="#aaa"
              multiline
              value={reason}
              onChangeText={setReason}
              maxLength={240}
              textAlignVertical="top"
              autoFocus
            />
          </View>
        )}

        {/* Step 2 — Review */}
        {step === 2 && (
          <View style={s.card}>
            <Text style={s.reviewHeading}>Review your request</Text>

            {!!title && (
              <View style={s.reviewRow}>
                <Text style={s.reviewLabel}>IOU</Text>
                <Text style={s.reviewValue}>{title}</Text>
              </View>
            )}
            {!!paymentAmount && (
              <View style={s.reviewRow}>
                <Text style={s.reviewLabel}>Payment amount</Text>
                <Text style={s.reviewValue}>{currency(paymentAmount)}</Text>
              </View>
            )}
            <View style={s.reviewRow}>
              <Text style={s.reviewLabel}>Original due</Text>
              <Text style={s.reviewValue}>{fmt(originalDue)}</Text>
            </View>
            <View style={s.reviewRow}>
              <Text style={s.reviewLabel}>Requesting until</Text>
              <Text style={[s.reviewValue, { color: GREEN, fontWeight: '900' }]}>
                {fmt(extendUntil)}
              </Text>
            </View>
            {!!reason.trim() && (
              <View style={s.reviewRow}>
                <Text style={s.reviewLabel}>Note</Text>
                <Text style={s.reviewValue}>{reason.trim()}</Text>
              </View>
            )}

            <View style={s.noticePill}>
              <Text style={s.noticeText}>
                Your due date will not change unless your lender approves this request.
                Extensions apply only to this payment and do not affect future payments
                or your IOU Score during the approved window.
              </Text>
            </View>
          </View>
        )}
      </ScrollView>

      {/* Footer */}
      <View style={[s.footer, { paddingBottom: footerPaddingBottom }]}>
        {step === 0 ? (
          <TouchableOpacity
            style={[s.btn, s.btnPrimary]}
            onPress={handleNext}
            activeOpacity={0.85}
          >
            <Text style={s.btnPrimaryText}>Continue</Text>
          </TouchableOpacity>
        ) : (
          <View style={s.footerRow}>
            <TouchableOpacity
              style={[s.btn, s.btnSecondary, { flex: 1 }]}
              onPress={() => setStep((st) => st - 1)}
              disabled={submitting}
              activeOpacity={0.85}
            >
              <Text style={s.btnSecondaryText}>Back</Text>
            </TouchableOpacity>

            {step === 1 ? (
              <TouchableOpacity
                style={[s.btn, s.btnPrimary, { flex: 2 }]}
                onPress={handleNext}
                activeOpacity={0.85}
              >
                <Text style={s.btnPrimaryText}>Continue</Text>
              </TouchableOpacity>
            ) : (
              <TouchableOpacity
                style={[s.btn, s.btnPrimary, { flex: 2 }, submitting ? s.btnDisabled : undefined]}
                onPress={handleSubmit}
                disabled={submitting}
                activeOpacity={0.85}
              >
                {submitting ? (
                  <ActivityIndicator color="#fff" />
                ) : (
                  <Text style={s.btnPrimaryText}>Send extension request</Text>
                )}
              </TouchableOpacity>
            )}
          </View>
        )}
      </View>
    </KeyboardAvoidingView>
  );
}

const s = StyleSheet.create({
  outer: { flex: 1, backgroundColor: '#F5F7F9' },

  errorScreen: {
    flex: 1,
    backgroundColor: '#F5F7F9',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
  },
  errorTitle: { fontSize: 17, fontWeight: '800', color: '#111827', textAlign: 'center' },
  errorText: {
    fontSize: 14,
    fontWeight: '500',
    color: '#6B7280',
    textAlign: 'center',
    marginTop: 8,
  },

  progressRow: {
    paddingHorizontal: 16,
    paddingTop: 12,
    paddingBottom: 4,
    alignItems: 'center',
  },
  stepLabel: {
    marginTop: 4,
    fontSize: 12,
    fontWeight: '700',
    color: '#6B7280',
    letterSpacing: 0.3,
    textTransform: 'uppercase',
  },

  scroll: { flex: 1 },
  scrollContent: { padding: 16, paddingBottom: 8 },

  card: {
    backgroundColor: '#fff',
    borderRadius: 16,
    borderWidth: 1,
    borderColor: '#E5E7EB',
    padding: 16,
  },

  summaryTitle: {
    fontSize: 16,
    fontWeight: '800',
    color: '#111827',
    marginBottom: 10,
  },
  summaryMeta: { flexDirection: 'row', flexWrap: 'wrap', gap: 16 },
  metaItem: {},
  metaLabel: {
    fontSize: 10,
    fontWeight: '800',
    color: '#9CA3AF',
    textTransform: 'uppercase',
    letterSpacing: 0.4,
  },
  metaValue: { fontSize: 14, fontWeight: '700', color: '#111827', marginTop: 2 },

  divider: { height: 1, backgroundColor: '#F3F4F6', marginVertical: 14 },

  fieldLabel: { fontSize: 14, fontWeight: '800', color: '#111827', marginBottom: 6 },
  fieldSub: { fontSize: 13, fontWeight: '500', color: '#6B7280', marginBottom: 12 },

  compactPicker: { alignSelf: 'flex-start' },
  limitNote: { marginTop: 10, fontSize: 12, fontWeight: '600', color: '#9CA3AF' },

  androidDateBtn: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 10,
    padding: 14,
  },
  androidDateText: { fontSize: 15, fontWeight: '700', color: '#111827' },
  androidDateChange: { fontSize: 13, fontWeight: '700', color: GREEN },

  noteInput: {
    borderWidth: 1,
    borderColor: '#E5E7EB',
    borderRadius: 10,
    padding: 14,
    fontSize: 15,
    color: '#111',
    minHeight: 100,
  },

  reviewHeading: {
    fontSize: 15,
    fontWeight: '800',
    color: '#111827',
    marginBottom: 14,
  },
  reviewRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 10,
    gap: 12,
  },
  reviewLabel: { fontSize: 13, fontWeight: '600', color: '#6B7280' },
  reviewValue: {
    fontSize: 13,
    fontWeight: '700',
    color: '#111827',
    textAlign: 'right',
    flex: 1,
  },

  noticePill: {
    backgroundColor: GREEN_LIGHT,
    borderRadius: 10,
    padding: 12,
    marginTop: 14,
    borderWidth: 1,
    borderColor: '#D0E8D0',
  },
  noticeText: { fontSize: 12, fontWeight: '500', color: '#374151', lineHeight: 18 },

  footer: {
    backgroundColor: '#fff',
    borderTopWidth: 1,
    borderTopColor: '#E5E7EB',
    padding: 16,
  },
  footerRow: { flexDirection: 'row', gap: 10 },

  btn: {
    borderRadius: 12,
    paddingVertical: 15,
    alignItems: 'center',
    justifyContent: 'center',
  },
  btnPrimary: { backgroundColor: GREEN },
  btnPrimaryText: { color: '#fff', fontWeight: '900', fontSize: 15 },
  btnSecondary: { backgroundColor: '#F3F4F6' },
  btnSecondaryText: { color: '#374151', fontWeight: '700', fontSize: 15 },
  btnDisabled: { opacity: 0.45 },
});

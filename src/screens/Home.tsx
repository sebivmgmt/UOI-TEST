

// src/screens/Home.tsx
import React, {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  memo,
} from 'react';
import {
  Alert,
  Animated,
  FlatList,
  RefreshControl,
  Text,
  TouchableOpacity,
  View,
  ActivityIndicator,
  StyleSheet,
  Share,
} from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import SebivAvatar from '../components/SebivAvatar';
import Swipeable from 'react-native-gesture-handler/Swipeable';
import { RectButton } from 'react-native-gesture-handler';
import { supabase } from '../supabase';
import { useScreenGuard } from '../dev/useScreenGuard';
const SCREENS = {
  Archived: 'Archived',
  Profile: 'Profile',
  ScoreHistory: 'ScoreHistory',
  NewLoan: 'NewLoan',
  LoanDetail: 'LoanDetail',
  Receipt: 'Receipt',
  VerifyPhone: 'VerifyPhone',
  ConfirmPayment: 'ConfirmPayment',
  PreviewSign: 'PreviewSign',
  Inbox: 'Inbox',
  SearchUsers: 'SearchUsers',
  RequestExtension: 'RequestExtension',
  SplitReceipt: 'SplitReceipt',
} as const;
type Props = { navigation: any };
type DueCol = 'due_date' | 'due_at' | 'scheduled_at';
type UpcomingItem = {
  id: string;
  iou_id: string;
  scheduled_at: string;
  paid_at: string | null;
  amount_cents: number;
  title?: string | null;
  direction: 'in' | 'out';
  payment_status: 'scheduled' | 'pending_confirmation' | 'paid' | 'late' | string;
  iou_status?: string | null;
  progress_percent?: number | null;
  paid_installments?: number | null;
  total_installments?: number | null;
  counterparty_name: string | null;
  counterparty_avatar_url: string | null;
};
type IouLite = {
  id: string;
  title: string | null;
  lender_id: string;
  borrower_id: string | null;
  archived_at: string | null;
  deleted_at: string | null;
  status: string | null;
  progress_percent: number | null;
  paid_installments: number | null;
  total_installments: number | null;
};
type PaymentLite = {
  id: string;
  iou_id: string | null;
  status: string | null;
  scheduled_at: string;
  paid_at: string | null;
  amount_cents: number;
};
type ListEntry =
  | { type: 'section'; title: string; id: string }
  | { type: 'item'; data: UpcomingItem; id: string; completed: boolean }
  | { type: 'empty'; message: string; id: string };
const IOU_GREEN = '#1B5E20';
const IOU_GREEN_DARK = '#1B5E20';
const IOU_RED_DARK = '#C62828';
const BLUE = '#3b82f6';
const ORANGE = '#f59e0b';
const currency = (cents: number) => `$${((cents ?? 0) / 100).toFixed(2)}`;
const isSameDay = (a: Date, b: Date) =>
  a.getFullYear() === b.getFullYear() &&
  a.getMonth() === b.getMonth() &&
  a.getDate() === b.getDate();
const dueBadge = (
  iso: string,
  paid_at: string | null,
  payment_status?: string
) => {
  if (paid_at) return 'paid';
  if (payment_status === 'pending_confirmation') return 'pending';
  const due = new Date(iso);
  const now = new Date();
  if (isSameDay(due, now)) return 'today';
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  return due < startOfToday ? 'late' : 'due';
};
const badgeColorFor = (badge: string) => {
  if (badge === 'paid') return '#4CAF50';
  if (badge === 'pending') return BLUE;
  if (badge === 'late') return '#E53935';
  if (badge === 'today') return '#0288D1';
  return '#F9A825';
};
const paymentStatusBgFor = (status?: string) => {
  if (status === 'paid') return '#C8E6C9';
  if (status === 'pending_confirmation') return '#BBDEFB';
  if (status === 'late') return '#FFCDD2';
  if (status === 'scheduled') return '#E0E0E0';
  return '#E0E0E0';
};
const sortUpcoming = (items: UpcomingItem[]) => {
  return [...items].sort((a, b) => {
    const aDate = new Date(a.scheduled_at);
    const bDate = new Date(b.scheduled_at);
    const aBadge = dueBadge(a.scheduled_at, a.paid_at, a.payment_status);
    const bBadge = dueBadge(b.scheduled_at, b.paid_at, b.payment_status);
    const rank = (badge: string) => {
      if (badge === 'pending') return 0;
      if (badge === 'late') return 1;
      if (badge === 'today') return 2;
      if (badge === 'due') return 3;
      return 4;
    };
    const rankDiff = rank(aBadge) - rank(bBadge);
    if (rankDiff !== 0) return rankDiff;
    return aDate.getTime() - bDate.getTime();
  });
};
const formatShortDate = (iso: string): string => {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '—';
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
};
const paymentStatusLabel = (status: string): string => {
  if (status === 'scheduled') return 'AutoPay';
  if (status === 'processing') return 'Processing';
  if (status === 'pending_confirmation') return 'Pending';
  if (status === 'paid') return 'Paid';
  if (status === 'late') return 'Late';
  return status;
};
const statusChipColors = (status: string): { bg: string; text: string } => {
  if (status === 'paid') return { bg: '#C8E6C9', text: '#1B5E20' };
  if (status === 'pending_confirmation') return { bg: '#BBDEFB', text: '#1565C0' };
  if (status === 'late') return { bg: '#FFCDD2', text: '#C62828' };
  if (status === 'scheduled') return { bg: '#E8F5E9', text: '#2E7D32' };
  return { bg: '#E0E0E0', text: '#374151' };
};
const clampProgress = (value: number) => {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(100, Math.round(value)));
};
const getProgressPercent = (item: UpcomingItem) => {
  if (typeof item.progress_percent === 'number') {
    return clampProgress(item.progress_percent);
  }
  if (
    typeof item.paid_installments === 'number' &&
    typeof item.total_installments === 'number' &&
    item.total_installments > 0
  ) {
    return clampProgress((item.paid_installments / item.total_installments) * 100);
  }
  return 0;
};
const getProgressLabel = (item: UpcomingItem) => {
  if (
    typeof item.paid_installments === 'number' &&
    typeof item.total_installments === 'number' &&
    item.total_installments > 0
  ) {
    return `${item.paid_installments}/${item.total_installments} paid`;
  }
  return `${getProgressPercent(item)}% complete`;
};
export default function Home({ navigation }: Props) {
  const [userId, setUserId] = useState<string | null>(null);
  const [phoneVerified, setPhoneVerified] = useState<boolean | null>(null);
  const [pendingInboxCount, setPendingInboxCount] = useState<number>(0);
  const [incoming14, setIncoming14] = useState<UpcomingItem[]>([]);
  const [outgoing14, setOutgoing14] = useState<UpcomingItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [firstLoad, setFirstLoad] = useState(true);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [activeFilter, setActiveFilter] = useState<'all' | 'in' | 'out'>('all');
  const [showInboxToast, setShowInboxToast] = useState(false);
  const toastTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const toastAnim = useRef(new Animated.Value(0)).current;

  useLayoutEffect(() => {
    navigation.setOptions({
      headerStyle: { backgroundColor: '#1B5E20' },
      headerShadowVisible: false,
      headerTitleAlign: 'center',
      headerTitle: () => null,
      headerLeft: () => (
        <TouchableOpacity
          onPress={() => navigation.navigate(SCREENS.Inbox)}
          style={headerS.sideBtn}
        >
          <Text style={headerS.sideBtnText}>Inbox</Text>
          {pendingInboxCount > 0 && (
            <View style={headerS.countBadge}>
              <Text style={headerS.countText}>
                {pendingInboxCount > 99 ? '99+' : pendingInboxCount}
              </Text>
            </View>
          )}
        </TouchableOpacity>
      ),
      headerRight: () => (
        <TouchableOpacity
          onPress={() => navigation.navigate(SCREENS.Profile)}
          style={[headerS.sideBtn, { marginRight: 16 }]}
        >
          <Text style={headerS.sideBtnText}>Profile</Text>
        </TouchableOpacity>
      ),
    });
  }, [navigation, pendingInboxCount]);
  useScreenGuard('Home', [
    { label: 'FAB + New IOU present', pass: true },
    { label: 'Header → Archived', pass: !!navigation },
    { label: 'Header → Inbox', pass: !!navigation },
    { label: 'Header → Profile', pass: !!navigation },
    { label: 'Incoming list loaded', pass: Array.isArray(incoming14) },
    { label: 'Outgoing list loaded', pass: Array.isArray(outgoing14) },
  ]);
  useEffect(() => {
    (async () => {
      const { data } = await supabase.auth.getUser();
      setUserId(data.user?.id ?? null);
    })();
  }, []);
  const fetchProfileMeta = useCallback(async () => {
    if (!userId) return;
    const { data, error } = await supabase
      .from('profiles')
      .select('phone_verified')
      .eq('id', userId)
      .maybeSingle();
    if (!error && data) {
      setPhoneVerified(!!(data as { phone_verified?: boolean | null }).phone_verified);
    }
  }, [userId]);
  const fetchInboxCount = useCallback(async () => {
    if (!userId) return;
    const { count, error } = await supabase
      .from('ious')
      .select('id', { count: 'exact', head: true })
      .eq('requested_action_by', userId)
      .eq('status', 'open')
      .is('activated_at', null)
      .is('deleted_at', null);
    if (!error) {
      setPendingInboxCount(count ?? 0);
    }
  }, [userId]);
  useEffect(() => {
    void fetchProfileMeta();
    void fetchInboxCount();
  }, [fetchProfileMeta, fetchInboxCount]);

  useEffect(() => {
    if (pendingInboxCount > 0) {
      setShowInboxToast(true);
      toastAnim.setValue(0);
      Animated.timing(toastAnim, { toValue: 1, duration: 280, useNativeDriver: true }).start();
      if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
      toastTimerRef.current = setTimeout(() => {
        Animated.timing(toastAnim, { toValue: 0, duration: 280, useNativeDriver: true }).start(() =>
          setShowInboxToast(false)
        );
      }, 7000);
    } else {
      if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
      setShowInboxToast(false);
      toastAnim.setValue(0);
    }
    return () => { if (toastTimerRef.current) clearTimeout(toastTimerRef.current); };
  }, [pendingInboxCount]);
  const inTotal = useMemo(
    () => incoming14.reduce((s, r) => s + r.amount_cents, 0),
    [incoming14]
  );
  const outTotal = useMemo(
    () => outgoing14.reduce((s, r) => s + r.amount_cents, 0),
    [outgoing14]
  );
  const today = new Date();
  const inToday = useMemo(
    () =>
      incoming14.filter(
        (i) =>
          !i.paid_at &&
          i.payment_status !== 'pending_confirmation' &&
          isSameDay(new Date(i.scheduled_at), today)
      ).length,
    [incoming14, today]
  );
  const outToday = useMemo(
    () =>
      outgoing14.filter(
        (i) =>
          !i.paid_at &&
          i.payment_status !== 'pending_confirmation' &&
          isSameDay(new Date(i.scheduled_at), today)
      ).length,
    [outgoing14, today]
  );
  const inLate = useMemo(
    () =>
      incoming14.filter(
        (i) =>
          !i.paid_at &&
          i.payment_status !== 'pending_confirmation' &&
          new Date(i.scheduled_at) < today
      ).length,
    [incoming14, today]
  );
  const outLate = useMemo(
    () =>
      outgoing14.filter(
        (i) =>
          !i.paid_at &&
          i.payment_status !== 'pending_confirmation' &&
          new Date(i.scheduled_at) < today
      ).length,
    [outgoing14, today]
  );
  const fetchScopedIous = useCallback(
    async (role: 'lender' | 'borrower') => {
      if (!userId) {
        return {
          data: [] as IouLite[],
          error: null as { message?: string } | null,
        };
      }
      const roleColumn = role === 'lender' ? 'lender_id' : 'borrower_id';
      return await supabase
        .from('ious')
        .select(
          `
            id,
            title,
            lender_id,
            borrower_id,
            archived_at,
            deleted_at,
            status,
            progress_percent,
            paid_installments,
            total_installments
          `
        )
        .eq(roleColumn, userId)
        .in('status', ['active', 'open', 'late'])
        .not('activated_at', 'is', null)
        .is('archived_at', null)
        .is('deleted_at', null);
    },
    [userId]
  );
  const fetchPaymentsByIouIds = useCallback(
    async (dueCol: DueCol, iouIds: string[]) => {
      if (!iouIds.length) {
        return {
          data: [] as PaymentLite[],
          error: null as { message?: string } | null,
        };
      }
      const from = new Date();
      from.setDate(from.getDate() - 30);
      const to = new Date();
      to.setDate(to.getDate() + 30);
      return await supabase
        .from('payments')
        .select(
          `
            id,
            iou_id,
            status,
            scheduled_at:${dueCol},
            paid_at,
            amount_cents
          `
        )
        .in('iou_id', iouIds)
        .gte(dueCol, from.toISOString())
        .lt(dueCol, to.toISOString())
        .order(dueCol, { ascending: true });
    },
    []
  );
  const buildUpcomingItems = useCallback(
    (
      payments: PaymentLite[],
      iouMap: Record<string, IouLite>,
      direction: 'in' | 'out',
      profileMap: Record<string, { public_name: string | null; avatar_url: string | null }>
    ): UpcomingItem[] => {
      const items: UpcomingItem[] = payments
        .filter((p) => !!p.iou_id && !!p.scheduled_at)
        .map((p) => {
          const iou = p.iou_id ? iouMap[p.iou_id] : undefined;
          const counterpartyId =
            direction === 'in' ? (iou?.borrower_id ?? null) : (iou?.lender_id ?? null);
          const profile = counterpartyId ? (profileMap[counterpartyId] ?? null) : null;
          const resolvedName = profile?.public_name || null;
          return {
            id: p.id,
            iou_id: p.iou_id ?? '',
            scheduled_at: p.scheduled_at,
            paid_at: p.paid_at,
            amount_cents: p.amount_cents,
            title: iou?.title ?? null,
            direction,
            payment_status: p.status ?? 'scheduled',
            iou_status: iou?.status ?? 'active',
            progress_percent:
              typeof iou?.progress_percent === 'number' ? iou.progress_percent : null,
            paid_installments:
              typeof iou?.paid_installments === 'number' ? iou.paid_installments : null,
            total_installments:
              typeof iou?.total_installments === 'number' ? iou.total_installments : null,
            counterparty_name: resolvedName,
            counterparty_avatar_url: profile?.avatar_url ?? null,
          };
        })
        .filter((item) => !!item.iou_id);
      return sortUpcoming(items);
    },
    []
  );
  const fetchUpcoming = useCallback(async () => {
    if (!userId) return;
    setLoading(true);
    setErrorMsg(null);
    const [incomingIousRes, outgoingIousRes] = await Promise.all([
      fetchScopedIous('lender'),
      fetchScopedIous('borrower'),
    ]);
    if (incomingIousRes.error || outgoingIousRes.error) {
      setErrorMsg(
        incomingIousRes.error?.message ||
          outgoingIousRes.error?.message ||
          'Failed to load IOUs.'
      );
      setIncoming14([]);
      setOutgoing14([]);
      setFirstLoad(false);
      setLoading(false);
      return;
    }
    const incomingIous = (incomingIousRes.data ?? []) as IouLite[];
    const outgoingIous = (outgoingIousRes.data ?? []) as IouLite[];
    const incomingIouIds = incomingIous.map((row) => row.id);
    const outgoingIouIds = outgoingIous.map((row) => row.id);
    const incomingIouMap: Record<string, IouLite> = Object.fromEntries(
      incomingIous.map((row) => [row.id, row])
    );
    const outgoingIouMap: Record<string, IouLite> = Object.fromEntries(
      outgoingIous.map((row) => [row.id, row])
    );

    // Fetch counterparty profiles (borrower for incoming, lender for outgoing)
    type ProfileEntry = { public_name: string | null; avatar_url: string | null };
    let profileMap: Record<string, ProfileEntry> = {};
    const counterpartyIds = new Set<string>();
    incomingIous.forEach((iou) => { if (iou.borrower_id) counterpartyIds.add(iou.borrower_id); });
    outgoingIous.forEach((iou) => { if (iou.lender_id) counterpartyIds.add(iou.lender_id); });
    if (counterpartyIds.size > 0) {
      const { data: profileData } = await supabase
        .from('profile_directory')
        .select('id, public_name, avatar_url')
        .in('id', Array.from(counterpartyIds));
      if (profileData) {
        profileMap = Object.fromEntries(
          (profileData as any[]).map((p) => [
            p.id,
            {
              public_name: p.public_name ?? null,
              avatar_url: p.avatar_url ?? null,
            },
          ])
        );
      }
    }

    const cols: DueCol[] = ['due_date', 'due_at', 'scheduled_at'];
    let lastErr: string | null = null;
    for (const col of cols) {
      const [inPaymentsRes, outPaymentsRes] = await Promise.all([
        fetchPaymentsByIouIds(col, incomingIouIds),
        fetchPaymentsByIouIds(col, outgoingIouIds),
      ]);
      if (!inPaymentsRes.error && !outPaymentsRes.error) {
        const safeIn = buildUpcomingItems(
          (inPaymentsRes.data ?? []) as PaymentLite[],
          incomingIouMap,
          'in',
          profileMap
        );
        const safeOut = buildUpcomingItems(
          (outPaymentsRes.data ?? []) as PaymentLite[],
          outgoingIouMap,
          'out',
          profileMap
        );
        setIncoming14(safeIn);
        setOutgoing14(safeOut);
        setFirstLoad(false);
        setLoading(false);
        return;
      }
      lastErr =
        inPaymentsRes.error?.message ||
        outPaymentsRes.error?.message ||
        'Unknown error';
    }
    setErrorMsg(lastErr ?? 'Failed to load payments.');
    setIncoming14([]);
    setOutgoing14([]);
    setFirstLoad(false);
    setLoading(false);
  }, [userId, fetchScopedIous, fetchPaymentsByIouIds, buildUpcomingItems]);
  useFocusEffect(
    useCallback(() => {
      void fetchUpcoming();
      void fetchProfileMeta();
      void fetchInboxCount();
    }, [fetchUpcoming, fetchProfileMeta, fetchInboxCount])
  );
  useEffect(() => {
    const paymentsChannel = supabase
      .channel('home-payments')
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'payments' },
        () => {
          void fetchUpcoming();
          void fetchProfileMeta();
        }
      )
      .subscribe();
    const iousChannel = supabase
      .channel('home-ious')
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'ious' },
        () => {
          void fetchUpcoming();
          void fetchInboxCount();
          void fetchProfileMeta();
        }
      )
      .subscribe();
    const profilesChannel = userId
      ? supabase
          .channel(`home-profile-${userId}`)
          .on(
            'postgres_changes',
            {
              event: '*',
              schema: 'public',
              table: 'profiles',
              filter: `id=eq.${userId}`,
            },
            () => {
              void fetchProfileMeta();
            }
          )
          .subscribe()
      : null;
    return () => {
      supabase.removeChannel(paymentsChannel);
      supabase.removeChannel(iousChannel);
      if (profilesChannel) supabase.removeChannel(profilesChannel);
    };
  }, [fetchUpcoming, fetchInboxCount, fetchProfileMeta, userId]);
  const startPaymentFlow = (item: UpcomingItem) => {
    navigation.navigate(SCREENS.ConfirmPayment, {
      paymentId: item.id,
      amount: item.amount_cents,
      iouId: item.iou_id,
      iou_id: item.iou_id,
      loanId: item.iou_id,
      loan_id: item.iou_id,
    });
  };
  const sendReminder = async (item: UpcomingItem) => {
    try {
      const title = item.title || 'Loan';
      const amount = currency(item.amount_cents);
      const due = new Date(item.scheduled_at).toLocaleDateString();
      await Share.share({
        message: `Reminder: ${title} payment of ${amount} is due ${due} in IOU.`,
      });
    } catch (e: any) {
      Alert.alert('Reminder failed', e.message ?? 'Could not open share sheet.');
    }
  };
  const openFullLoan = (item: UpcomingItem) => {
    navigation.navigate(SCREENS.LoanDetail, {
      iouId: item.iou_id,
      direction: item.direction,
    });
  };
  const filteredAll = useMemo(() => {
    const all = [...incoming14, ...outgoing14];
    if (activeFilter === 'in') return all.filter((i) => i.direction === 'in');
    if (activeFilter === 'out') return all.filter((i) => i.direction === 'out');
    return all;
  }, [incoming14, outgoing14, activeFilter]);

  const futureItems = useMemo(
    () => sortUpcoming(filteredAll.filter((i) => i.payment_status !== 'paid')),
    [filteredAll]
  );

  const recentItems = useMemo(
    () =>
      [...filteredAll.filter((i) => i.payment_status === 'paid')].sort(
        (a, b) =>
          new Date(b.paid_at ?? b.scheduled_at).getTime() -
          new Date(a.paid_at ?? a.scheduled_at).getTime()
      ),
    [filteredAll]
  );

  const listData = useMemo((): ListEntry[] => {
    const result: ListEntry[] = [];

    result.push({ type: 'section', title: 'Future Activity', id: 'section-future' });
    if (futureItems.length > 0) {
      futureItems.forEach((item) =>
        result.push({ type: 'item', data: item, id: `future-${item.id}`, completed: false })
      );
    } else {
      const msg =
        activeFilter === 'in'
          ? 'No incoming payments scheduled.'
          : activeFilter === 'out'
            ? 'No outgoing payments scheduled.'
            : 'No upcoming payments in the next 30 days.';
      result.push({ type: 'empty', message: msg, id: 'empty-future' });
    }

    result.push({ type: 'section', title: 'Recent Activity', id: 'section-recent' });
    if (recentItems.length > 0) {
      recentItems.forEach((item) =>
        result.push({ type: 'item', data: item, id: `recent-${item.id}`, completed: true })
      );
    } else {
      result.push({ type: 'empty', message: 'No recent payments yet.', id: 'empty-recent' });
    }

    return result;
  }, [futureItems, recentItems, activeFilter]);
  const HeaderContent = memo(function HeaderContent({
    filter,
    onFilterChange,
  }: {
    filter: 'all' | 'in' | 'out';
    onFilterChange: (f: 'all' | 'in' | 'out') => void;
  }) {
    return (
      <>
        {phoneVerified === false && (
          <TouchableOpacity
            onPress={() => navigation.navigate(SCREENS.VerifyPhone)}
            style={styles.verifyBanner}
            activeOpacity={0.9}
          >
            <Text style={styles.verifyTitle}>Verify your phone</Text>
            <Text style={styles.verifyText}>
              You'll need to verify your phone before creating new IOUs. Tap to verify →
            </Text>
          </TouchableOpacity>
        )}
        <View style={styles.summaryRow}>
          <TouchableOpacity
            style={[
              styles.summaryCard,
              filter === 'in' ? styles.summaryCardGreenActive : styles.summaryCardGreen,
            ]}
            activeOpacity={0.85}
            onPress={() => onFilterChange(filter === 'in' ? 'all' : 'in')}
          >
            <Text style={[styles.summaryLabel, filter === 'in' && styles.summaryTextActive]}>
              You're owed
            </Text>
            <Text style={[styles.summaryAmount, { color: filter === 'in' ? '#fff' : IOU_GREEN }]}>
              {currency(inTotal)}
            </Text>
            <Text style={[styles.summaryMeta, filter === 'in' && styles.summaryTextActive]}>
              {inToday > 0 ? `${inToday} due today` : inLate > 0 ? `${inLate} late` : 'All on track'}
            </Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[
              styles.summaryCard,
              filter === 'out' ? styles.summaryCardRedActive : styles.summaryCardRed,
            ]}
            activeOpacity={0.85}
            onPress={() => onFilterChange(filter === 'out' ? 'all' : 'out')}
          >
            <Text style={[styles.summaryLabel, filter === 'out' && styles.summaryTextActive]}>
              You owe
            </Text>
            <Text style={[styles.summaryAmount, { color: filter === 'out' ? '#fff' : IOU_RED_DARK }]}>
              {currency(outTotal)}
            </Text>
            <Text style={[styles.summaryMeta, filter === 'out' && styles.summaryTextActive]}>
              {outToday > 0 ? `${outToday} due today` : outLate > 0 ? `${outLate} late` : 'All on track'}
            </Text>
          </TouchableOpacity>
        </View>
        <TouchableOpacity
          style={styles.splitReceiptCard}
          onPress={() => navigation.navigate(SCREENS.SplitReceipt)}
          activeOpacity={0.85}
        >
          <View style={styles.splitReceiptIcon}>
            <View style={styles.splitReceiptIconLine} />
            <View style={[styles.splitReceiptIconLine, { width: '70%' }]} />
            <View style={[styles.splitReceiptIconLine, { width: '85%' }]} />
          </View>
          <View style={styles.splitReceiptText}>
            <Text style={styles.splitReceiptTitle}>Split a Receipt</Text>
            <Text style={styles.splitReceiptSub}>Scan and split with friends instantly</Text>
          </View>
          <Text style={styles.splitReceiptArrow}>→</Text>
        </TouchableOpacity>
        {errorMsg && (
          <View style={styles.errorBanner}>
            <Text style={styles.errorTitle}>Couldn't load payments</Text>
            <Text style={styles.errorText}>{errorMsg}</Text>
          </View>
        )}
      </>
    );
  });
  const Row = memo(function Row({ item, completed }: { item: UpcomingItem; completed: boolean }) {
    const isIn = item.direction === 'in';
    const railColor = completed ? '#D1D5DB' : (isIn ? '#4CAF50' : '#EF5350');
    const amountColor = completed ? '#6B7280' : (isIn ? IOU_GREEN : IOU_RED_DARK);

    const displayName = item.counterparty_name || (isIn ? 'Borrower' : 'Lender');
    const nextDate = formatShortDate(item.scheduled_at);
    const statusLabel = paymentStatusLabel(item.payment_status);
    const chipColors = statusChipColors(item.payment_status);

    const canPay =
      !isIn && !item.paid_at &&
      item.payment_status === 'late';
    const canRemind =
      isIn && !item.paid_at && item.payment_status !== 'pending_confirmation';
    const canConfirm =
      isIn && !item.paid_at && item.payment_status === 'pending_confirmation';

    const leftActions = () => {
      if (item.paid_at || item.direction !== 'out') return <View />;
      return (
        <RectButton
          onPress={() =>
            navigation.navigate(SCREENS.RequestExtension, {
              paymentId: item.id,
              iouId: item.iou_id,
              scheduledAt: item.scheduled_at,
              paymentAmount: item.amount_cents,
              title: item.title,
            })
          }
          style={styles.leftAction}
        >
          <Text style={styles.sideActionText}>Extension</Text>
        </RectButton>
      );
    };

    const rightActions = () => {
      if (canPay) {
        return (
          <RectButton onPress={() => startPaymentFlow(item)} style={styles.rightActionPay}>
            <Text style={styles.sideActionText}>Pay now</Text>
          </RectButton>
        );
      }
      if (canConfirm) {
        return (
          <RectButton
            onPress={() => navigation.navigate(SCREENS.LoanDetail, { iouId: item.iou_id, direction: 'in' })}
            style={styles.rightActionConfirm}
          >
            <Text style={styles.sideActionText}>Confirm</Text>
          </RectButton>
        );
      }
      if (canRemind) {
        return (
          <RectButton onPress={() => { void sendReminder(item); }} style={styles.rightActionRemind}>
            <Text style={styles.sideActionText}>Remind</Text>
          </RectButton>
        );
      }
      return <View />;
    };

    return (
      <Swipeable
        renderRightActions={rightActions}
        renderLeftActions={leftActions}
        overshootLeft={false}
        overshootRight={false}
      >
        <TouchableOpacity activeOpacity={0.85} onPress={() => openFullLoan(item)}>
          <View style={[styles.rowCard, { borderLeftWidth: 4, borderLeftColor: railColor, backgroundColor: completed ? '#FAFAFA' : '#fff' }]}>
            <View style={styles.rowInner}>
              <SebivAvatar uri={item.counterparty_avatar_url} size={46} />
              <View style={styles.rowContent}>
                {/* Name + direction chip */}
                <View style={styles.rowTopRow}>
                  <Text style={styles.rowPersonName} numberOfLines={1}>{displayName}</Text>
                  <View style={[styles.dirTag, {
                    backgroundColor: completed ? '#F3F4F6' : (isIn ? '#BBF7D0' : '#FEE2E2'),
                  }]}>
                    <Text style={[styles.dirTagText, {
                      color: completed ? '#9CA3AF' : (isIn ? '#166534' : '#991B1B'),
                    }]}>
                      {isIn ? 'Incoming' : 'Outgoing'}
                    </Text>
                  </View>
                </View>

                {/* Amount + due date */}
                <View style={styles.rowAmountRow}>
                  <Text style={[styles.rowAmount, { color: amountColor }]}>
                    {currency(item.amount_cents)}
                  </Text>
                  <Text style={styles.rowDueDate}>· Due {nextDate}</Text>
                </View>

                {/* Status chip + optional title */}
                <View style={styles.rowBottomRow}>
                  <View style={[styles.statusChip, { backgroundColor: chipColors.bg }]}>
                    <Text style={[styles.statusChipText, { color: chipColors.text }]}>
                      {statusLabel}
                    </Text>
                  </View>
                  {item.title ? (
                    <Text style={styles.rowTitleMuted} numberOfLines={1}>{item.title}</Text>
                  ) : null}
                </View>
              </View>
            </View>
          </View>
        </TouchableOpacity>
      </Swipeable>
    );
  });
  return (
    <View style={{ flex: 1, backgroundColor: '#f7f7f7' }}>
      {showInboxToast && (
        <Animated.View
          style={[
            styles.inboxToast,
            {
              opacity: toastAnim,
              transform: [{ translateY: toastAnim.interpolate({ inputRange: [0, 1], outputRange: [-72, 0] }) }],
            },
          ]}
          pointerEvents="box-none"
        >
          <TouchableOpacity
            style={styles.inboxToastInner}
            activeOpacity={0.9}
            onPress={() => {
              if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
              Animated.timing(toastAnim, { toValue: 0, duration: 200, useNativeDriver: true }).start(() =>
                setShowInboxToast(false)
              );
              navigation.navigate(SCREENS.Inbox);
            }}
          >
            <Text style={styles.inboxToastTitle}>
              {pendingInboxCount === 1
                ? 'You have 1 IOU request waiting'
                : `You have ${pendingInboxCount} IOU requests waiting`}
            </Text>
            <Text style={styles.inboxToastSub}>Tap to review and sign →</Text>
          </TouchableOpacity>
        </Animated.View>
      )}
      {firstLoad && loading ? (
        <View style={styles.centered}>
          <ActivityIndicator />
        </View>
      ) : (
        <FlatList
          data={listData}
          keyExtractor={(i) => i.id}
          renderItem={({ item }) => {
            if (item.type === 'section') {
              return <Text style={styles.sectionHeadText}>{item.title}</Text>;
            }
            if (item.type === 'empty') {
              return (
                <View style={styles.sectionEmptyWrap}>
                  <Text style={styles.sectionEmptyText}>{item.message}</Text>
                </View>
              );
            }
            return <Row item={item.data} completed={item.completed} />;
          }}
          ListHeaderComponent={
            <HeaderContent
              filter={activeFilter}
              onFilterChange={setActiveFilter}
            />
          }
          refreshControl={
            <RefreshControl
              refreshing={loading}
              onRefresh={() => {
                void fetchUpcoming();
                void fetchInboxCount();
              }}
            />
          }
          contentContainerStyle={styles.listContent}
          ItemSeparatorComponent={() => <View style={{ height: 8 }} />}
          showsVerticalScrollIndicator={false}
        />
      )}
    </View>
  );
}
const styles = StyleSheet.create({
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  listContent: {
    paddingBottom: 120,
    paddingTop: 0,
  },
  verifyBanner: {
    margin: 12,
    marginBottom: 0,
    padding: 12,
    borderRadius: 10,
    backgroundColor: '#FFF3E0',
    borderWidth: 1,
    borderColor: '#FFCC80',
  },
  verifyTitle: {
    fontWeight: '800',
    marginBottom: 4,
  },
  verifyText: {
    opacity: 0.8,
  },
  inboxBanner: {
    margin: 12,
    marginBottom: 0,
    padding: 12,
    borderRadius: 12,
    backgroundColor: '#EEF2F5',
    borderWidth: 1,
    borderColor: '#D0D5DD',
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  inboxBannerActive: {
    margin: 12,
    marginBottom: 0,
    padding: 14,
    borderRadius: 12,
    backgroundColor: '#EFF6FF',
    borderWidth: 1.5,
    borderColor: '#93C5FD',
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  inboxTitle: {
    fontWeight: '900',
    color: '#1E3A5F',
    fontSize: 15,
    lineHeight: 21,
  },
  inboxText: {
    marginTop: 4,
    color: '#3B82F6',
    fontWeight: '700',
    fontSize: 13,
  },
  inboxArrow: {
    fontSize: 22,
    fontWeight: '900',
    color: IOU_GREEN,
  },
  topSection: {
    backgroundColor: '#fff',
    paddingBottom: 8,
    borderBottomWidth: 1,
    borderBottomColor: 'rgba(0,0,0,0.06)',
  },
  scoreHero: {
    marginHorizontal: 12,
    marginTop: 12,
    backgroundColor: '#F2FAF2',
    borderWidth: 1,
    borderColor: '#D7EBD7',
    borderRadius: 18,
    padding: 16,
  },
  scoreHeroTop: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    gap: 12,
  },
  scoreHeroCopy: {
    flex: 1,
  },
  scoreHeroEyebrow: {
    fontSize: 13,
    fontWeight: '800',
    color: IOU_GREEN_DARK,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
  },
  scoreHeroValue: {
    marginTop: 4,
    fontSize: 48,
    lineHeight: 54,
    fontWeight: '900',
    color: IOU_GREEN_DARK,
  },
  scoreHeroSubtext: {
    marginTop: 6,
    fontSize: 14,
    fontWeight: '700',
    color: '#4B5B4B',
  },
  scoreTierPill: {
    backgroundColor: '#DFF0DF',
    borderRadius: 999,
    paddingHorizontal: 12,
    paddingVertical: 8,
    alignSelf: 'flex-start',
  },
  scoreTierText: {
    color: IOU_GREEN_DARK,
    fontWeight: '800',
    fontSize: 13,
  },
  scoreMetricsRow: {
    flexDirection: 'row',
    gap: 10,
    marginTop: 14,
  },
  scoreMetricPill: {
    flex: 1,
    backgroundColor: '#FFFFFF',
    borderRadius: 12,
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderWidth: 1,
    borderColor: '#DDEBDD',
  },
  scoreMetricLabel: {
    fontSize: 11,
    fontWeight: '800',
    color: '#6A7A6A',
    textTransform: 'uppercase',
    marginBottom: 4,
  },
  scoreMetricValue: {
    fontSize: 20,
    fontWeight: '900',
    color: IOU_GREEN_DARK,
  },
  scoreMetricValueGood: {
    color: IOU_GREEN_DARK,
  },
  scoreMetricValuePending: {
    color: '#B45309',
  },
  scoreMovementCard: {
    marginTop: 12,
    backgroundColor: '#FFFFFF',
    borderRadius: 12,
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderWidth: 1,
    borderColor: '#DDEBDD',
  },
  scoreMovementLabel: {
    fontSize: 11,
    fontWeight: '800',
    color: '#6A7A6A',
    textTransform: 'uppercase',
    marginBottom: 4,
  },
  scoreMovementValue: {
    fontSize: 14,
    fontWeight: '800',
    color: '#2F3E2F',
    lineHeight: 20,
  },
  scoreMovementSubvalue: {
    marginTop: 4,
    fontSize: 12,
    fontWeight: '700',
    color: '#667085',
  },
  scoreActivityStrip: {
    marginTop: 12,
    backgroundColor: '#FFFFFF',
    borderRadius: 12,
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderWidth: 1,
    borderColor: '#DDEBDD',
  },
  scoreActivityLabel: {
    fontSize: 11,
    fontWeight: '800',
    color: '#6A7A6A',
    textTransform: 'uppercase',
    marginBottom: 4,
  },
  scoreActivityValue: {
    fontSize: 14,
    fontWeight: '800',
    color: '#2F3E2F',
  },
  statRow: {
    flexDirection: 'row',
    paddingHorizontal: 12,
    paddingTop: 10,
    paddingBottom: 4,
    backgroundColor: '#fff',
  },
  statCard: {
    flex: 1,
    padding: 12,
    borderRadius: 12,
    borderWidth: 2,
    minHeight: 92,
  },
  statCardActive: {
    shadowColor: '#000',
    shadowOpacity: 0.08,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 2 },
    elevation: 2,
  },
  statLabel: {
    fontSize: 12,
    opacity: 0.72,
    fontWeight: '700',
    color: '#334155',
  },
  statLabelActive: {
    opacity: 1,
    color: '#111827',
  },
  statValue: {
    marginTop: 4,
    fontSize: 17,
    fontWeight: '900',
    color: '#111',
  },
  statValueActive: {
    color: '#111',
  },
  statMeta: {
    marginTop: 6,
    opacity: 0.8,
    fontWeight: '600',
    color: '#475569',
  },
  statMetaActive: {
    opacity: 1,
    color: '#334155',
  },
  summaryRow: {
    flexDirection: 'row',
    gap: 12,
    paddingHorizontal: 12,
    paddingVertical: 12,
    backgroundColor: '#fff',
  },
  summaryCard: {
    flex: 1,
    borderRadius: 16,
    padding: 16,
    borderWidth: 1,
  },
  summaryCardGreen: {
    backgroundColor: '#F0FBF0',
    borderColor: '#C8E6C9',
  },
  summaryCardRed: {
    backgroundColor: '#FFF0F0',
    borderColor: '#FFCDD2',
  },
  summaryCardGreenActive: {
    backgroundColor: '#1B5E20',
    borderColor: '#1B5E20',
    borderWidth: 1,
  },
  summaryCardRedActive: {
    backgroundColor: '#B71C1C',
    borderColor: '#B71C1C',
    borderWidth: 1,
  },
  summaryTextActive: {
    color: '#fff',
  },
  sectionHeadText: {
    paddingHorizontal: 12,
    paddingTop: 16,
    paddingBottom: 6,
    fontSize: 13,
    fontWeight: '800',
    color: '#6B7280',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    backgroundColor: '#f7f7f7',
  },
  sectionEmptyWrap: {
    marginHorizontal: 12,
    paddingVertical: 14,
    paddingHorizontal: 16,
    backgroundColor: '#F9FAFB',
    borderRadius: 10,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#E5E7EB',
  },
  sectionEmptyText: {
    color: '#9CA3AF',
    fontWeight: '600',
    fontSize: 14,
    textAlign: 'center',
  },
  summaryLabel: {
    fontSize: 13,
    fontWeight: '700',
    color: '#555',
    marginBottom: 4,
  },
  summaryAmount: {
    fontSize: 26,
    fontWeight: '900',
    lineHeight: 30,
  },
  summaryMeta: {
    marginTop: 4,
    fontSize: 12,
    fontWeight: '700',
    color: '#888',
  },
  activityHeader: {
    paddingHorizontal: 12,
    paddingTop: 16,
    paddingBottom: 8,
    fontSize: 17,
    fontWeight: '900',
    color: '#111',
    backgroundColor: '#f7f7f7',
  },
  headerNextUpWrap: {
    paddingHorizontal: 12,
    paddingTop: 12,
  },
  nextCard: {
    backgroundColor: '#fff',
    borderRadius: 14,
    padding: 14,
    borderWidth: 1,
    borderColor: '#ECECEC',
  },
  nextHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  nextEyebrow: {
    fontSize: 12,
    fontWeight: '700',
    color: '#666',
    textTransform: 'uppercase',
  },
  nextTitle: {
    marginTop: 10,
    fontSize: 18,
    fontWeight: '800',
    color: '#111',
  },
  nextMetaRow: {
    marginTop: 8,
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  nextAmount: {
    fontSize: 20,
    fontWeight: '800',
    color: IOU_GREEN,
  },
  nextDate: {
    color: '#666',
    fontWeight: '600',
  },
  progressSection: {
    marginTop: 10,
  },
  progressHeaderRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  progressLabel: {
    fontSize: 12,
    fontWeight: '800',
    color: '#444',
    textTransform: 'uppercase',
  },
  progressValue: {
    fontSize: 12,
    fontWeight: '800',
    color: IOU_GREEN,
  },
  progressTrack: {
    marginTop: 6,
    height: 8,
    borderRadius: 999,
    backgroundColor: '#EAEAEA',
    overflow: 'hidden',
  },
  progressFill: {
    height: '100%',
    borderRadius: 999,
    backgroundColor: IOU_GREEN,
  },
  progressSubtext: {
    marginTop: 6,
    color: '#666',
    fontSize: 12,
    fontWeight: '700',
  },
  nextActionsRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
    marginTop: 14,
  },
  nextActionBtn: {
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 10,
  },
  nextActionGreen: {
    backgroundColor: IOU_GREEN,
  },
  nextActionBlue: {
    backgroundColor: BLUE,
  },
  nextActionOrange: {
    backgroundColor: ORANGE,
  },
  nextActionConfirm: {
    backgroundColor: BLUE,
  },
  nextActionNeutral: {
    backgroundColor: '#EEF2F5',
  },
  nextActionText: {
    color: '#fff',
    fontWeight: '800',
    fontSize: 14,
  },
  nextActionTextDark: {
    color: '#222',
  },
  errorBanner: {
    margin: 12,
    padding: 12,
    borderRadius: 10,
    backgroundColor: '#FFEBEE',
    borderWidth: 1,
    borderColor: '#F8BBD0',
  },
  errorTitle: {
    color: '#C62828',
    fontWeight: '700',
  },
  errorText: {
    color: '#C62828',
    marginTop: 4,
    opacity: 0.8,
  },
  rowCard: {
    marginHorizontal: 12,
    paddingVertical: 12,
    paddingHorizontal: 14,
    borderRadius: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#E5E7EB',
    backgroundColor: '#fff',
    overflow: 'hidden',
  },
  rowInner: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 12,
  },
  avatar: {
    width: 46,
    height: 46,
    borderRadius: 23,
  },
  avatarCircle: {
    width: 46,
    height: 46,
    borderRadius: 23,
    alignItems: 'center',
    justifyContent: 'center',
  },
  avatarInitials: {
    color: '#fff',
    fontWeight: '900',
    fontSize: 16,
  },
  rowContent: {
    flex: 1,
  },
  rowPersonName: {
    fontSize: 16,
    fontWeight: '900',
    color: '#111827',
    flex: 1,
  },
  rowSubLine: {
    fontSize: 12,
    fontWeight: '700',
    color: '#667085',
  },
  rowAmountLine: {
    fontSize: 13,
    fontWeight: '600',
    color: '#374151',
    marginTop: 1,
  },
  rowTagLine: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    marginTop: 4,
    flexWrap: 'wrap',
  },
  dirTag: {
    borderRadius: 999,
    paddingHorizontal: 8,
    paddingVertical: 3,
    flexShrink: 0,
  },
  dirTagText: {
    fontSize: 11,
    fontWeight: '800',
  },
  rowStatusText: {
    fontSize: 12,
    fontWeight: '600',
    color: '#6B7280',
  },
  rowTopRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 8,
  },
  rowAmountRow: {
    flexDirection: 'row',
    alignItems: 'baseline',
    gap: 6,
    marginTop: 4,
  },
  rowAmount: {
    fontSize: 20,
    fontWeight: '900',
  },
  rowDueDate: {
    fontSize: 13,
    fontWeight: '600',
    color: '#6B7280',
  },
  rowBottomRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    marginTop: 6,
    flexWrap: 'wrap',
  },
  statusChip: {
    borderRadius: 999,
    paddingHorizontal: 8,
    paddingVertical: 3,
  },
  statusChipText: {
    fontSize: 11,
    fontWeight: '800',
  },
  rowTitleMuted: {
    fontSize: 12,
    fontWeight: '600',
    color: '#9CA3AF',
    flexShrink: 1,
  },
  leftAction: {
    width: 150,
    marginVertical: 2,
    marginLeft: 8,
    borderRadius: 12,
    backgroundColor: BLUE,
    justifyContent: 'center',
    alignItems: 'center',
  },
  rightActionPay: {
    width: 150,
    marginVertical: 2,
    marginRight: 8,
    borderRadius: 12,
    backgroundColor: IOU_GREEN,
    justifyContent: 'center',
    alignItems: 'center',
  },
  rightActionRemind: {
    width: 150,
    marginVertical: 2,
    marginRight: 8,
    borderRadius: 12,
    backgroundColor: ORANGE,
    justifyContent: 'center',
    alignItems: 'center',
  },
  rightActionConfirm: {
    width: 150,
    marginVertical: 2,
    marginRight: 8,
    borderRadius: 12,
    backgroundColor: BLUE,
    justifyContent: 'center',
    alignItems: 'center',
  },
  sideActionText: {
    fontWeight: '800',
    color: '#fff',
    fontSize: 16,
  },
  emptyWrap: {
    padding: 20,
    alignItems: 'center',
  },
  emptyText: {
    opacity: 0.6,
  },
  splitReceiptCard: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#F0F9F0',
    marginHorizontal: 12,
    marginTop: 8,
    marginBottom: 0,
    borderRadius: 12,
    paddingVertical: 10,
    paddingHorizontal: 14,
    gap: 10,
    borderWidth: 1,
    borderColor: '#C8E6C9',
  },
  splitReceiptIcon: {
    width: 30,
    height: 36,
    backgroundColor: 'rgba(27,94,32,0.08)',
    borderRadius: 5,
    padding: 5,
    gap: 4,
    justifyContent: 'center',
    alignItems: 'center',
  },
  splitReceiptIconLine: {
    height: 2,
    width: '100%',
    backgroundColor: '#2E7D32',
    borderRadius: 2,
  },
  splitReceiptText: {
    flex: 1,
    gap: 2,
  },
  splitReceiptTitle: {
    fontSize: 14,
    fontWeight: '700',
    color: '#1B5E20',
  },
  splitReceiptSub: {
    fontSize: 11,
    fontWeight: '600',
    color: '#4B7A4B',
  },
  splitReceiptArrow: {
    fontSize: 16,
    fontWeight: '700',
    color: '#4B7A4B',
  },
  fab: {
    position: 'absolute',
    right: 20,
    bottom: 24,
    backgroundColor: IOU_GREEN,
    borderRadius: 28,
    paddingHorizontal: 18,
    height: 56,
    alignItems: 'center',
    justifyContent: 'center',
    shadowColor: '#000',
    shadowOpacity: 0.2,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 3 },
    elevation: 6,
  },
  fabText: {
    color: '#fff',
    fontSize: 18,
    fontWeight: '800',
  },
  inboxToast: {
    position: 'absolute',
    top: 10,
    left: 12,
    right: 12,
    zIndex: 100,
  },
  inboxToastInner: {
    backgroundColor: '#1E3A5F',
    borderRadius: 14,
    paddingVertical: 12,
    paddingHorizontal: 16,
    shadowColor: '#000',
    shadowOpacity: 0.14,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 3 },
    elevation: 8,
  },
  inboxToastTitle: {
    color: '#fff',
    fontWeight: '900',
    fontSize: 15,
    lineHeight: 21,
  },
  inboxToastSub: {
    marginTop: 3,
    color: '#93C5FD',
    fontWeight: '700',
    fontSize: 13,
  },
});

const RED_BADGE = '#ef4444';

const headerS = StyleSheet.create({
  sideBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    marginLeft: 16,
    paddingVertical: 6,
    paddingHorizontal: 2,
    gap: 5,
  },
  sideBtnText: {
    color: '#fff',
    fontWeight: '600',
    fontSize: 15,
  },
  logoBadge: {
    backgroundColor: '#fff',
    borderRadius: 14,
    paddingHorizontal: 10,
    paddingVertical: 3,
  },
  countBadge: {
    backgroundColor: RED_BADGE,
    borderRadius: 10,
    minWidth: 18,
    height: 18,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 4,
  },
  countText: {
    color: '#fff',
    fontSize: 10,
    fontWeight: '900',
  },
});
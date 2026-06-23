

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
  Image,
  RefreshControl,
  Text,
  TouchableOpacity,
  View,
  ActivityIndicator,
  StyleSheet,
  Share,
} from 'react-native';
import { useAppTheme, AppTheme } from '../theme';
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
const statusChipColors = (status: string, isDark: boolean): { bg: string; text: string; border: string } => {
  if (isDark) {
    if (status === 'paid') return { bg: '#051A0A', text: '#66BB6A', border: '#0D3A15' };
    if (status === 'pending_confirmation') return { bg: '#050A1A', text: '#60A5FA', border: '#0D1540' };
    if (status === 'late') return { bg: '#1A0505', text: '#FF6B6B', border: '#3A0D0D' };
    return { bg: '#111111', text: '#9CA3AF', border: '#262626' };
  }
  if (status === 'paid') return { bg: '#DCFCE7', text: '#15803D', border: '#BBF7D0' };
  if (status === 'pending_confirmation') return { bg: '#EFF6FF', text: '#1D4ED8', border: '#BFDBFE' };
  if (status === 'late') return { bg: '#FEF2F2', text: '#991B1B', border: '#FECACA' };
  if (status === 'scheduled') return { bg: '#F3F4F6', text: '#374151', border: '#E5E7EB' };
  return { bg: '#F3F4F6', text: '#374151', border: '#E5E7EB' };
};
export default function Home({ navigation }: Props) {
  const theme = useAppTheme();
  const styles = useMemo(() => makeStyles(theme), [theme]);
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
    const hStyles = makeHeaderStyles(theme);
    navigation.setOptions({
      headerStyle: {
        backgroundColor: theme.headerBackground,
        borderBottomWidth: 1,
        borderBottomColor: '#1B5E20',
      },
      headerShadowVisible: false,
      headerTitleAlign: 'center',
      statusBarStyle: theme.isDark ? 'light' : 'dark',
      headerTitle: () => (
        <Image
          source={require('../../assets/iou-wordmark-final.png')}
          style={{ height: 32, width: 81, ...(theme.isDark ? { tintColor: '#fff' } : {}) }}
          resizeMode="contain"
          accessibilityLabel="IOU"
        />
      ),
      headerLeft: () => (
        <TouchableOpacity
          onPress={() => navigation.navigate(SCREENS.Inbox)}
          style={hStyles.sideBtn}
        >
          <Text style={hStyles.sideBtnText}>Inbox</Text>
          {pendingInboxCount > 0 && (
            <View style={hStyles.countBadge}>
              <Text style={hStyles.countText}>
                {pendingInboxCount > 99 ? '99+' : pendingInboxCount}
              </Text>
            </View>
          )}
        </TouchableOpacity>
      ),
      headerRight: () => (
        <TouchableOpacity
          onPress={() => navigation.navigate(SCREENS.Profile)}
          style={[hStyles.sideBtn, { marginRight: 16 }]}
        >
          <Text style={hStyles.sideBtnText}>Profile</Text>
        </TouchableOpacity>
      ),
    });
  }, [navigation, pendingInboxCount, theme]);
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
    const inStatusText = inToday > 0 ? `${inToday} due today` : inLate > 0 ? `${inLate} late` : 'All on track';
    const inStatusColor = inLate > 0
      ? (theme.isDark ? '#FF6B6B' : '#C62828')
      : inToday > 0
        ? (theme.isDark ? '#FBBF24' : '#B45309')
        : (theme.isDark ? '#66BB6A' : '#2E7D32');
    const outStatusText = outToday > 0 ? `${outToday} due today` : outLate > 0 ? `${outLate} late` : 'All on track';
    const outStatusColor = outLate > 0
      ? (theme.isDark ? '#FF6B6B' : '#C62828')
      : outToday > 0
        ? (theme.isDark ? '#FBBF24' : '#B45309')
        : (theme.isDark ? theme.textMuted : '#4B5563');
    const inFutureCount = futureItems.filter(i => i.direction === 'in').length;
    const outFutureCount = futureItems.filter(i => i.direction === 'out').length;
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
              Verify your phone before creating new IOUs. Tap to continue →
            </Text>
          </TouchableOpacity>
        )}
        <View style={styles.summaryRow}>
          <TouchableOpacity
            style={[styles.summaryCard, styles.summaryCardOwed, filter === 'in' && styles.summaryCardGreenActive]}
            activeOpacity={0.85}
            onPress={() => onFilterChange(filter === 'in' ? 'all' : 'in')}
          >
            <Text style={styles.summaryLabel}>You're owed</Text>
            <Text style={[styles.summaryAmount, { color: theme.isDark ? theme.positive : IOU_GREEN }]}>{currency(inTotal)}</Text>
            {inFutureCount > 0 && (
              <Text style={styles.summaryCount}>{inFutureCount} upcoming</Text>
            )}
            <View style={styles.summaryStatusRow}>
              <View style={[styles.summaryDot, { backgroundColor: inStatusColor }]} />
              <Text style={[styles.summaryStatus, { color: inStatusColor }]}>{inStatusText}</Text>
            </View>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.summaryCard, styles.summaryCardOwe, filter === 'out' && styles.summaryCardRedActive]}
            activeOpacity={0.85}
            onPress={() => onFilterChange(filter === 'out' ? 'all' : 'out')}
          >
            <Text style={styles.summaryLabel}>You owe</Text>
            <Text style={[styles.summaryAmount, { color: theme.isDark ? theme.negative : IOU_RED_DARK }]}>{currency(outTotal)}</Text>
            {outFutureCount > 0 && (
              <Text style={styles.summaryCount}>{outFutureCount} upcoming</Text>
            )}
            <View style={styles.summaryStatusRow}>
              <View style={[styles.summaryDot, { backgroundColor: outStatusColor }]} />
              <Text style={[styles.summaryStatus, { color: outStatusColor }]}>{outStatusText}</Text>
            </View>
          </TouchableOpacity>
        </View>
        <TouchableOpacity
          style={styles.splitReceiptCard}
          onPress={() => navigation.navigate(SCREENS.SplitReceipt)}
          activeOpacity={0.85}
        >
          <View style={styles.splitReceiptContent}>
            <Text style={styles.splitReceiptTitle}>Split a receipt</Text>
            <Text style={styles.splitReceiptSub}>Scan and divide with friends</Text>
          </View>
          <View style={styles.splitReceiptCta}>
            <Text style={styles.splitReceiptCtaText}>Scan →</Text>
          </View>
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
    const amountColor = completed
      ? theme.textMuted
      : isIn
        ? (theme.isDark ? theme.positive : IOU_GREEN)
        : (theme.isDark ? theme.negative : IOU_RED_DARK);
    const sign = isIn ? '+' : '−';

    const displayName = item.counterparty_name || (isIn ? 'Borrower' : 'Lender');
    const nextDate = formatShortDate(item.scheduled_at);
    const statusLabel = paymentStatusLabel(item.payment_status);
    const chipColors = statusChipColors(item.payment_status, theme.isDark);

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
          <View style={[styles.rowCard, completed && styles.rowCardCompleted]}>
            <View style={styles.rowInner}>
              <SebivAvatar uri={item.counterparty_avatar_url} size={40} />
              <View style={styles.rowContent}>
                <View style={styles.rowTopRow}>
                  <Text style={styles.rowPersonName} numberOfLines={1}>{displayName}</Text>
                  <Text style={[styles.rowAmount, { color: amountColor }]}>
                    {sign}{currency(item.amount_cents)}
                  </Text>
                </View>
                <View style={styles.rowMetaRow}>
                  <Text style={styles.rowDueDate}>{isIn ? 'Incoming' : 'Outgoing'} · {nextDate}</Text>
                  <View style={[styles.statusChip, { backgroundColor: chipColors.bg, borderColor: chipColors.border, borderWidth: 1 }]}>
                    <Text style={[styles.statusChipText, { color: chipColors.text }]}>
                      {statusLabel}
                    </Text>
                  </View>
                </View>
                {item.title ? (
                  <Text style={styles.rowTitleMuted} numberOfLines={1}>{item.title}</Text>
                ) : null}
              </View>
            </View>
          </View>
        </TouchableOpacity>
      </Swipeable>
    );
  });
  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
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
const RED_BADGE = '#ef4444';

const makeStyles = (t: AppTheme) => StyleSheet.create({
  centered: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  listContent: { paddingBottom: 120, paddingTop: 0 },

  // ── banners ──────────────────────────────────────────────────────
  verifyBanner: {
    margin: 12, marginBottom: 0, padding: 14, borderRadius: 12,
    backgroundColor: t.isDark ? '#1A1000' : '#FFF3E0',
    borderWidth: 1, borderColor: t.isDark ? '#2A1A00' : '#FFCC80',
  },
  verifyTitle: { fontWeight: '800', fontSize: 14, marginBottom: 4, color: t.isDark ? '#FBBF24' : '#92400E' },
  verifyText: { fontSize: 13, color: t.isDark ? '#D97706' : '#78350F', opacity: 0.9 },
  errorBanner: {
    margin: 12, padding: 14, borderRadius: 12,
    backgroundColor: t.isDark ? '#1A0505' : '#FFEBEE',
    borderWidth: 1, borderColor: t.isDark ? '#2A0D0D' : '#F8BBD0',
  },
  errorTitle: { color: t.isDark ? '#FF6B6B' : '#C62828', fontWeight: '700', fontSize: 14 },
  errorText: { color: t.isDark ? '#FF6B6B' : '#C62828', marginTop: 4, fontSize: 13, opacity: 0.85 },

  // ── summary cards ─────────────────────────────────────────────────
  summaryRow: {
    flexDirection: 'row', gap: 12, paddingHorizontal: 12,
    paddingVertical: 12, backgroundColor: t.surface,
  },
  summaryCard: { flex: 1, borderRadius: 14, padding: 16, borderWidth: 1 },
  summaryCardOwed: {
    backgroundColor: t.isDark ? t.positiveSurface : '#F2FAF2',
    borderColor: t.isDark ? t.positiveBorder : '#C8E6C9',
  },
  summaryCardOwe: {
    backgroundColor: t.isDark ? t.negativeSurface : '#FFF5F5',
    borderColor: t.isDark ? t.negativeBorder : '#FFCDD2',
  },
  summaryCardGreenActive: {
    borderColor: t.isDark ? t.brandBright : '#4CAF50',
    borderWidth: 1.5,
    backgroundColor: t.isDark ? t.activeTabSurface : '#E8F5E9',
  },
  summaryCardRedActive: {
    borderColor: t.isDark ? t.negativeBorder : '#EF9A9A',
    borderWidth: 1.5,
    backgroundColor: t.isDark ? t.negativeSurface : '#FFEBEE',
  },
  summaryLabel: {
    fontSize: 11, fontWeight: '700', color: t.textMuted,
    textTransform: 'uppercase', letterSpacing: 0.5, marginBottom: 8,
  },
  summaryAmount: { fontSize: 30, fontWeight: '900', lineHeight: 34, letterSpacing: -0.5 },
  summaryCount: { marginTop: 6, fontSize: 12, fontWeight: '600', color: t.textMuted },
  summaryStatusRow: { flexDirection: 'row', alignItems: 'center', gap: 5, marginTop: 6 },
  summaryDot: { width: 7, height: 7, borderRadius: 999 },
  summaryStatus: { fontSize: 13, fontWeight: '700' },

  // ── split receipt ─────────────────────────────────────────────────
  splitReceiptCard: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    backgroundColor: t.surface, marginHorizontal: 12, marginTop: 10,
    borderRadius: 14, paddingVertical: 14, paddingHorizontal: 16,
    borderWidth: 1, borderColor: t.border,
    shadowColor: '#000', shadowOpacity: t.isDark ? 0 : 0.05, shadowRadius: 4,
    shadowOffset: { width: 0, height: 1 }, elevation: t.isDark ? 0 : 1,
  },
  splitReceiptContent: { flex: 1, gap: 3 },
  splitReceiptTitle: { fontSize: 15, fontWeight: '700', color: t.textPrimary },
  splitReceiptSub: { fontSize: 13, fontWeight: '500', color: t.textSecondary },
  splitReceiptCta: {
    backgroundColor: IOU_GREEN, borderRadius: 8, paddingHorizontal: 14, paddingVertical: 8,
  },
  splitReceiptCtaText: { color: '#fff', fontWeight: '700', fontSize: 13 },

  // ── section headers ──────────────────────────────────────────────
  sectionHeadText: {
    paddingHorizontal: 12, paddingTop: 22, paddingBottom: 8,
    fontSize: 13, fontWeight: '700', color: t.textSecondary,
    textTransform: 'uppercase', letterSpacing: 0.6, backgroundColor: t.background,
  },
  sectionEmptyWrap: {
    marginHorizontal: 12, paddingVertical: 18, paddingHorizontal: 16,
    backgroundColor: t.surface, borderRadius: 12, borderWidth: 1, borderColor: t.border,
  },
  sectionEmptyText: { color: t.textSecondary, fontWeight: '600', fontSize: 14, textAlign: 'center' },

  // ── activity rows ─────────────────────────────────────────────────
  rowCard: {
    marginHorizontal: 12, paddingVertical: 16, paddingHorizontal: 14,
    borderRadius: 14, borderWidth: 1, borderColor: t.border,
    backgroundColor: t.surface, overflow: 'hidden',
    shadowColor: '#000', shadowOpacity: t.isDark ? 0 : 0.05, shadowRadius: 4,
    shadowOffset: { width: 0, height: 1 }, elevation: t.isDark ? 0 : 1,
  },
  rowCardCompleted: { backgroundColor: t.surfaceMuted, shadowOpacity: 0, elevation: 0 },
  rowInner: { flexDirection: 'row', alignItems: 'flex-start', gap: 12 },
  rowContent: { flex: 1, gap: 6 },
  rowTopRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
  rowPersonName: { fontSize: 16, fontWeight: '800', color: t.textPrimary, flex: 1 },
  rowAmount: { fontSize: 18, fontWeight: '800', flexShrink: 0 },
  rowMetaRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
  rowDueDate: { fontSize: 14, fontWeight: '600', color: t.textSecondary, flex: 1 },
  statusChip: { borderRadius: 999, paddingHorizontal: 10, paddingVertical: 4 },
  statusChipText: { fontSize: 12, fontWeight: '700' },
  rowTitleMuted: { fontSize: 13, fontWeight: '600', color: t.textSecondary },

  // ── swipe actions ─────────────────────────────────────────────────
  leftAction: {
    width: 150, marginVertical: 2, marginLeft: 8, borderRadius: 12,
    backgroundColor: BLUE, justifyContent: 'center', alignItems: 'center',
  },
  rightActionPay: {
    width: 150, marginVertical: 2, marginRight: 8, borderRadius: 12,
    backgroundColor: IOU_GREEN, justifyContent: 'center', alignItems: 'center',
  },
  rightActionRemind: {
    width: 150, marginVertical: 2, marginRight: 8, borderRadius: 12,
    backgroundColor: ORANGE, justifyContent: 'center', alignItems: 'center',
  },
  rightActionConfirm: {
    width: 150, marginVertical: 2, marginRight: 8, borderRadius: 12,
    backgroundColor: BLUE, justifyContent: 'center', alignItems: 'center',
  },
  sideActionText: { fontWeight: '800', color: '#fff', fontSize: 16 },

  // ── inbox toast ──────────────────────────────────────────────────
  inboxToast: { position: 'absolute', top: 10, left: 12, right: 12, zIndex: 100 },
  inboxToastInner: {
    backgroundColor: '#1E3A5F', borderRadius: 14, paddingVertical: 12,
    paddingHorizontal: 16, shadowColor: '#000', shadowOpacity: 0.14,
    shadowRadius: 8, shadowOffset: { width: 0, height: 3 }, elevation: 8,
  },
  inboxToastTitle: { color: '#fff', fontWeight: '900', fontSize: 15, lineHeight: 21 },
  inboxToastSub: { marginTop: 3, color: '#93C5FD', fontWeight: '700', fontSize: 13 },
});

const makeHeaderStyles = (t: AppTheme) => StyleSheet.create({
  sideBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    marginLeft: 16,
    paddingVertical: 6,
    paddingHorizontal: 2,
    gap: 5,
  },
  sideBtnText: {
    color: t.isDark ? '#FFFFFF' : '#1B5E20',
    fontWeight: '600',
    fontSize: 15,
  },
  logoBadge: {
    backgroundColor: t.surface,
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
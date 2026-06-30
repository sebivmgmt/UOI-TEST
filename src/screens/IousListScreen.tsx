// src/screens/IousListScreen.tsx
import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  ActivityIndicator,
  StyleSheet,
  RefreshControl,
  LayoutAnimation,
  Platform,
  UIManager,
} from "react-native";

if (Platform.OS === "android" && UIManager.setLayoutAnimationEnabledExperimental) {
  UIManager.setLayoutAnimationEnabledExperimental(true);
}
import { useFocusEffect } from "@react-navigation/native";
import { supabase } from "../supabase";
import SebivAvatar from "../components/SebivAvatar";

const BRAND = "#1B5E20";
const RED = "#C62828";
const BG = "#F5F7F9";
const currency = (cents: number) =>
  `$${((cents ?? 0) / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

// ─── types ────────────────────────────────────────────────────────────────────

type IouRow = {
  id: string;
  title: string | null;
  principal_cents: number;
  status: string | null;
  activated_at: string | null;
  created_at: string | null;
  lender_id: string;
  borrower_id: string | null;
  progress_percent: number | null;
  paid_installments: number | null;
  total_installments: number | null;
  archived_at: string | null;
};

type NextPayment = {
  iou_id: string;
  scheduled_at: string;
  amount_cents: number;
};

type Profile = {
  id: string;
  public_name: string | null;
  avatar_url: string | null;
};

type IouWithDir = IouRow & { direction: "in" | "out"; next: NextPayment | null };

type PersonGroup = {
  counterpartyId: string | null;
  profile: Profile | null;
  ious: IouWithDir[];
  inCents: number;
  outCents: number;
  net: number;
  hasPending: boolean;
  soonestAt: string | null;
  soonestAmount: number;
  priority: number;
};

// ─── helpers ──────────────────────────────────────────────────────────────────

const getInitials = (name: string | null | undefined): string => {
  if (!name) return "?";
  const parts = name.trim().split(/[\s._]+/).filter(Boolean);
  if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
  return (parts[0]?.slice(0, 2) ?? "?").toUpperCase();
};

const shortDate = (iso: string | null): string => {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "";
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
};

const remainingCents = (row: IouRow): number => {
  if (typeof row.progress_percent === "number" && row.progress_percent > 0) {
    return Math.round(row.principal_cents * (1 - row.progress_percent / 100));
  }
  if (
    typeof row.paid_installments === "number" &&
    typeof row.total_installments === "number" &&
    row.total_installments > 0
  ) {
    const fraction = row.paid_installments / row.total_installments;
    return Math.round(row.principal_cents * (1 - fraction));
  }
  return row.principal_cents;
};

const iouStatusLabel = (row: IouRow): string => {
  if (!row.activated_at && row.status === "open") return "Pending";
  if (row.status === "active") return "Active";
  if (row.status === "open") return "Active";
  if (row.status === "late") return "Late";
  if (row.status === "completed" || row.status === "paid") return "Completed";
  if (row.status === "canceled") return "Canceled";
  if (row.status === "denied") return "Denied";
  return row.status ?? "Unknown";
};

const isLiveIou = (row: IouRow): boolean => {
  if (row.archived_at) return false;
  return row.status === "active" || row.status === "open" || row.status === "late";
};

const groupPriority = (g: PersonGroup): number => {
  if (g.hasPending) return 0;
  if (g.soonestAt) {
    const daysUntil = (new Date(g.soonestAt).getTime() - Date.now()) / 86_400_000;
    if (daysUntil <= 7) return 1;
  }
  if (g.inCents > 0 || g.outCents > 0) return 2;
  return 3;
};

// ─── component ────────────────────────────────────────────────────────────────

export default function IousListScreen({ navigation }: any) {
  const [userId, setUserId] = useState<string | null>(null);
  const [rows, setRows] = useState<IouRow[]>([]);
  const [profiles, setProfiles] = useState<Record<string, Profile>>({});
  const [nextPayments, setNextPayments] = useState<NextPayment[]>([]);
  const [extensionIouIds, setExtensionIouIds] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [expandedIds, setExpandedIds] = useState<Set<string | null>>(new Set());

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      setUserId(data.user?.id ?? null);
    });
  }, []);

  const load = useCallback(async () => {
    if (!userId) return;
    setLoading(true);

    // Fetch all live IOUs for this user
    const { data: iouData } = await supabase
      .from("ious")
      .select(
        "id,title,principal_cents,status,activated_at,created_at,lender_id,borrower_id,progress_percent,paid_installments,total_installments,archived_at"
      )
      .or(`lender_id.eq.${userId},borrower_id.eq.${userId}`)
      .is("deleted_at", null)
      .order("created_at", { ascending: false });

    const allRows = (iouData ?? []) as IouRow[];
    const live = allRows.filter(isLiveIou);
    setRows(live);

    // Collect counterparty IDs
    const cpIds = new Set<string>();
    live.forEach((r) => {
      const cp = r.lender_id === userId ? r.borrower_id : r.lender_id;
      if (cp) cpIds.add(cp);
    });

    // Fetch profiles
    if (cpIds.size > 0) {
      const { data: profileData } = await supabase
        .from("profile_directory")
        .select("id,public_name,avatar_url")
        .in("id", Array.from(cpIds));
      const map: Record<string, Profile> = {};
      (profileData ?? []).forEach((p: any) => {
        map[p.id] = {
          id: p.id,
          public_name: p.public_name ?? null,
          avatar_url: p.avatar_url ?? null,
        };
      });
      setProfiles(map);
    }

    // Fetch next unpaid payment per IOU
    const iouIds = live.map((r) => r.id);
    if (iouIds.length > 0) {
      const today = new Date().toISOString();
      const { data: pmtData } = await supabase
        .from("payments")
        .select("iou_id,scheduled_at,amount_cents")
        .in("iou_id", iouIds)
        .in("status", ["scheduled", "pending_confirmation", "late"])
        .gte("scheduled_at", today)
        .order("scheduled_at", { ascending: true });
      // Keep only the earliest per IOU
      const seen = new Set<string>();
      const earliest: NextPayment[] = [];
      ((pmtData ?? []) as any[]).forEach((p) => {
        if (!seen.has(p.iou_id)) {
          seen.add(p.iou_id);
          earliest.push({
            iou_id: p.iou_id,
            scheduled_at: p.scheduled_at,
            amount_cents: p.amount_cents,
          });
        }
      });
      setNextPayments(earliest);
    }

    // Fetch extension-pending IOU IDs (lender side only)
    const lenderIouIds = live.filter((r) => r.lender_id === userId).map((r) => r.id);
    if (lenderIouIds.length > 0) {
      const { data: extData } = await supabase
        .from("payments")
        .select("iou_id")
        .in("iou_id", lenderIouIds)
        .eq("extension_status", "requested")
        .is("paid_at", null);
      setExtensionIouIds(new Set(((extData ?? []) as any[]).map((p) => p.iou_id as string)));
    } else {
      setExtensionIouIds(new Set());
    }

    setLoading(false);
  }, [userId]);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load])
  );

  const onRefresh = async () => {
    setRefreshing(true);
    await load();
    setRefreshing(false);
  };

  const toggleExpand = (id: string | null) => {
    LayoutAnimation.configureNext(LayoutAnimation.Presets.easeInEaseOut);
    setExpandedIds((prev) => {
      const next = new Set(prev);
      const key = id ?? "__unknown__";
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  // ─── group by counterparty ──────────────────────────────────────────────────
  const groups = useMemo((): PersonGroup[] => {
    if (!userId) return [];
    const nextMap: Record<string, NextPayment> = {};
    nextPayments.forEach((n) => (nextMap[n.iou_id] = n));

    const grouped: Map<string | null, IouWithDir[]> = new Map();
    rows.forEach((r) => {
      const direction: "in" | "out" = r.lender_id === userId ? "in" : "out";
      const cpId = direction === "in" ? r.borrower_id : r.lender_id;
      const key = cpId ?? null;
      if (!grouped.has(key)) grouped.set(key, []);
      grouped.get(key)!.push({ ...r, direction, next: nextMap[r.id] ?? null });
    });

    const result: PersonGroup[] = [];
    grouped.forEach((ious, cpId) => {
      let inCents = 0;
      let outCents = 0;
      let hasPending = false;
      let soonestAt: string | null = null;
      let soonestAmount = 0;

      ious.forEach((iou) => {
        const rem = remainingCents(iou);
        if (iou.direction === "in") inCents += rem;
        else outCents += rem;
        if (!iou.activated_at) hasPending = true;
        if (iou.next) {
          if (!soonestAt || iou.next.scheduled_at < soonestAt) {
            soonestAt = iou.next.scheduled_at;
            soonestAmount = iou.next.amount_cents;
          }
        }
      });

      const g: PersonGroup = {
        counterpartyId: cpId,
        profile: cpId ? (profiles[cpId] ?? null) : null,
        ious,
        inCents,
        outCents,
        net: inCents - outCents,
        hasPending,
        soonestAt,
        soonestAmount,
        priority: 0,
      };
      g.priority = groupPriority(g);
      result.push(g);
    });

    result.sort((a, b) => {
      if (a.priority !== b.priority) return a.priority - b.priority;
      return Math.abs(b.net) - Math.abs(a.net);
    });
    return result;
  }, [rows, profiles, nextPayments, userId]);

  // ─── summary totals ─────────────────────────────────────────────────────────
  const totalIn = useMemo(() => groups.reduce((s, g) => s + g.inCents, 0), [groups]);
  const totalOut = useMemo(() => groups.reduce((s, g) => s + g.outCents, 0), [groups]);
  const net = totalIn - totalOut;

  // ─── render ─────────────────────────────────────────────────────────────────
  if (loading && rows.length === 0) {
    return (
      <View style={s.center}>
        <ActivityIndicator color={BRAND} />
      </View>
    );
  }

  const renderGroup = ({ item: g }: { item: PersonGroup }) => {
    const expandKey = g.counterpartyId ?? "__unknown__";
    const expanded = expandedIds.has(expandKey);
    const profile = g.profile;
    const displayName =
      profile?.public_name ||
      (g.counterpartyId ? `User …${g.counterpartyId.slice(-6)}` : "Pending");
    const initials = getInitials(displayName);
    const hasIn = g.inCents > 0;
    const hasOut = g.outCents > 0;
    const settled = !hasIn && !hasOut;

    // Card accent color
    const accentColor = settled ? "#9CA3AF" : hasIn && !hasOut ? BRAND : RED;

    return (
      <View style={s.personCard}>
        {/* Left accent rail */}
        <View style={[s.accentRail, { backgroundColor: accentColor }]} />

        <View style={s.cardBody}>
          {/* Header row */}
          <TouchableOpacity
            activeOpacity={0.82}
            onPress={() => toggleExpand(g.counterpartyId)}
          >
            <View style={s.cardHeader}>
              {/* Avatar */}
              <SebivAvatar uri={profile?.avatar_url} size={46} />

              {/* Name + relationship */}
              <View style={{ flex: 1, marginLeft: 12 }}>
                <Text style={s.personName} numberOfLines={1}>
                  {displayName}
                </Text>

                {settled ? (
                  <Text style={s.settledText}>Settled up</Text>
                ) : (
                  <View style={s.balanceCol}>
                    {hasIn && (
                      <Text
                        style={s.inAmount}
                        numberOfLines={1}
                        adjustsFontSizeToFit
                        minimumFontScale={0.6}
                      >
                        {hasOut ? "Owed " : ""}{currency(g.inCents)}
                      </Text>
                    )}
                    {hasOut && (
                      <Text
                        style={s.outAmount}
                        numberOfLines={1}
                        adjustsFontSizeToFit
                        minimumFontScale={0.6}
                      >
                        {hasIn ? "You owe " : "You owe "}{currency(g.outCents)}
                      </Text>
                    )}
                  </View>
                )}
              </View>

              {/* IOU count + expand toggle */}
              <View style={s.cardRight}>
                <View style={[s.countPill, { backgroundColor: accentColor + "22" }]}>
                  <Text style={[s.countPillText, { color: accentColor }]}>
                    {g.ious.length} IOU{g.ious.length !== 1 ? "s" : ""}
                  </Text>
                </View>
                <Text style={[s.chevron, expanded && s.chevronOpen]}>›</Text>
              </View>
            </View>

            {/* Next payment / pending badge row */}
            <View style={s.metaRow}>
              {g.hasPending && (
                <View style={s.pendingPill}>
                  <Text style={s.pendingText}>Pending review</Text>
                </View>
              )}
              {g.soonestAt && !g.hasPending && (
                <Text style={s.nextText}>
                  Next {shortDate(g.soonestAt)} · {currency(g.soonestAmount)}
                </Text>
              )}
            </View>

            {/* Net bar */}
            {!settled && (hasIn || hasOut) && (
              <View style={s.netBar}>
                <View
                  style={[
                    s.netBarFill,
                    {
                      flex: Math.max(g.inCents, 1),
                      backgroundColor: "#C8E6C9",
                    },
                  ]}
                />
                <View
                  style={[
                    s.netBarFill,
                    {
                      flex: Math.max(g.outCents, 1),
                      backgroundColor: "#FFCDD2",
                    },
                  ]}
                />
              </View>
            )}
          </TouchableOpacity>

          {/* Expanded IOU list */}
          {expanded && (
            <View style={s.iouList}>
              <View style={s.iouDivider} />
              {g.ious.map((iou) => {
                const isIn = iou.direction === "in";
                const rem = remainingCents(iou);
                const label = iouStatusLabel(iou);
                const isPending = !iou.activated_at;
                const pillBg = isPending
                  ? "#FFF8E1"
                  : isIn
                  ? "#E8F5E9"
                  : "#FFEBEE";
                const pillColor = isPending
                  ? "#F57F17"
                  : isIn
                  ? BRAND
                  : RED;
                const prog =
                  typeof iou.progress_percent === "number"
                    ? Math.max(0, Math.min(100, Math.round(iou.progress_percent)))
                    : typeof iou.paid_installments === "number" &&
                      typeof iou.total_installments === "number" &&
                      iou.total_installments > 0
                    ? Math.round((iou.paid_installments / iou.total_installments) * 100)
                    : 0;

                return (
                  <TouchableOpacity
                    key={iou.id}
                    style={s.iouRow}
                    activeOpacity={0.8}
                    onPress={() =>
                      navigation.navigate("LoanDetail", {
                        iouId: iou.id,
                        direction: iou.direction,
                      })
                    }
                  >
                    <View style={s.iouRowTop}>
                      <View style={{ flex: 1 }}>
                        <Text style={s.iouTitle} numberOfLines={1}>
                          {iou.title || "IOU"}
                        </Text>
                        <Text style={[s.iouDir, { color: isIn ? BRAND : RED }]}>
                          {isIn ? "They owe you" : "You owe"}
                        </Text>
                      </View>
                      <View style={{ alignItems: "flex-end", gap: 4 }}>
                        <Text
                          style={[s.iouAmount, { color: isIn ? BRAND : RED }]}
                          numberOfLines={1}
                          adjustsFontSizeToFit
                          minimumFontScale={0.6}
                        >
                          {currency(rem)}
                        </Text>
                        <View style={[s.statusPill, { backgroundColor: pillBg }]}>
                          <Text style={[s.statusText, { color: pillColor }]}>
                            {label}
                          </Text>
                        </View>
                      </View>
                    </View>
                    {prog > 0 && (
                      <View style={s.progTrack}>
                        <View
                          style={[
                            s.progFill,
                            {
                              width: `${prog}%` as any,
                              backgroundColor: isIn ? BRAND : RED,
                            },
                          ]}
                        />
                      </View>
                    )}
                    {iou.next && (
                      <Text style={s.iouNext}>
                        Next {shortDate(iou.next.scheduled_at)} · {currency(iou.next.amount_cents)}
                      </Text>
                    )}
                    {isIn && extensionIouIds.has(iou.id) && (
                      <View style={s.extPendingPill}>
                        <Text style={s.extPendingText}>Extension request pending</Text>
                      </View>
                    )}
                  </TouchableOpacity>
                );
              })}
            </View>
          )}
        </View>
      </View>
    );
  };

  return (
    <View style={s.screen}>
      <FlatList
        data={groups}
        keyExtractor={(g) => g.counterpartyId ?? "__unknown__"}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
        contentContainerStyle={s.list}
        ItemSeparatorComponent={() => <View style={{ height: 10 }} />}
        showsVerticalScrollIndicator={false}
        ListHeaderComponent={
          <View>
            {/* Summary banner */}
            <View style={s.summaryBanner}>
              <View style={s.summaryItem}>
                <Text style={s.summaryLabel}>Owed to me</Text>
                <Text
                  style={[s.summaryValue, { color: BRAND }]}
                  numberOfLines={1}
                  adjustsFontSizeToFit
                  minimumFontScale={0.5}
                >
                  {currency(totalIn)}
                </Text>
              </View>
              <View style={s.summaryDivider} />
              <View style={s.summaryItem}>
                <Text style={s.summaryLabel}>I owe</Text>
                <Text
                  style={[s.summaryValue, { color: RED }]}
                  numberOfLines={1}
                  adjustsFontSizeToFit
                  minimumFontScale={0.5}
                >
                  {currency(totalOut)}
                </Text>
              </View>
              <View style={s.summaryDivider} />
              <View style={s.summaryItem}>
                <Text style={s.summaryLabel}>Net</Text>
                <Text
                  style={[s.summaryValue, { color: net >= 0 ? BRAND : RED }]}
                  numberOfLines={1}
                  adjustsFontSizeToFit
                  minimumFontScale={0.5}
                >
                  {net >= 0 ? "+" : ""}{currency(net)}
                </Text>
              </View>
            </View>

            <Text style={s.sectionLabel}>People</Text>
          </View>
        }
        ListEmptyComponent={
          <View style={s.empty}>
            <Text style={s.emptyTitle}>No active IOUs</Text>
            <Text style={s.emptyText}>
              Tap the IOU button to create your first loan.
            </Text>
          </View>
        }
        renderItem={renderGroup}
      />
    </View>
  );
}

// ─── styles ───────────────────────────────────────────────────────────────────
const s = StyleSheet.create({
  screen: { flex: 1, backgroundColor: BG },
  center: { flex: 1, alignItems: "center", justifyContent: "center" },
  list: { padding: 14, paddingBottom: 48 },

  summaryBanner: {
    flexDirection: "row",
    backgroundColor: "#fff",
    borderRadius: 16,
    padding: 16,
    marginBottom: 16,
    borderWidth: 1,
    borderColor: "#E5E7EB",
    alignItems: "center",
  },
  summaryItem: { flex: 1, alignItems: "center", overflow: "hidden", paddingHorizontal: 4 },
  summaryLabel: {
    fontSize: 10,
    fontWeight: "700",
    color: "#6B7280",
    textTransform: "uppercase",
    letterSpacing: 0.4,
    marginBottom: 4,
  },
  summaryValue: { fontSize: 19, fontWeight: "900", width: "100%", textAlign: "center" },
  summaryDivider: { width: 1, height: 36, backgroundColor: "#E5E7EB", flexShrink: 0 },

  sectionLabel: {
    fontSize: 12,
    fontWeight: "800",
    color: "#6B7280",
    textTransform: "uppercase",
    letterSpacing: 0.5,
    marginBottom: 10,
    paddingHorizontal: 2,
  },

  personCard: {
    flexDirection: "row",
    backgroundColor: "#fff",
    borderRadius: 16,
    borderWidth: 1,
    borderColor: "#E5E7EB",
    overflow: "hidden",
  },
  accentRail: { width: 4 },
  cardBody: { flex: 1, padding: 14 },

  cardHeader: { flexDirection: "row", alignItems: "center" },
  avatar: { width: 46, height: 46, borderRadius: 23 },
  avatarCircle: {
    width: 46,
    height: 46,
    borderRadius: 23,
    alignItems: "center",
    justifyContent: "center",
  },
  avatarText: { color: "#fff", fontWeight: "900", fontSize: 16 },

  personName: {
    fontSize: 16,
    fontWeight: "900",
    color: "#111827",
    marginBottom: 3,
  },
  settledText: { fontSize: 13, fontWeight: "700", color: "#9CA3AF" },

  balanceCol: { flexDirection: "column", gap: 1 },
  inAmount: { fontSize: 13, fontWeight: "800", color: BRAND },
  outAmount: { fontSize: 13, fontWeight: "800", color: RED },

  cardRight: { alignItems: "center", gap: 6, marginLeft: 10 },
  countPill: {
    borderRadius: 999,
    paddingHorizontal: 8,
    paddingVertical: 3,
  },
  countPillText: { fontSize: 11, fontWeight: "800" },
  chevron: {
    fontSize: 22,
    fontWeight: "300",
    color: "#9CA3AF",
    transform: [{ rotate: "0deg" }],
    lineHeight: 26,
  },
  chevronOpen: { transform: [{ rotate: "90deg" }] },

  metaRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    marginTop: 8,
    flexWrap: "wrap",
  },
  pendingPill: {
    backgroundColor: "#FFF8E1",
    borderRadius: 999,
    paddingHorizontal: 8,
    paddingVertical: 3,
  },
  pendingText: { fontSize: 11, fontWeight: "800", color: "#F57F17" },
  nextText: { fontSize: 12, fontWeight: "700", color: "#6B7280" },

  netBar: {
    flexDirection: "row",
    height: 5,
    borderRadius: 999,
    overflow: "hidden",
    marginTop: 10,
    gap: 2,
  },
  netBarFill: { borderRadius: 999, height: "100%" },

  // Expanded IOU list
  iouList: { marginTop: 2 },
  iouDivider: {
    height: 1,
    backgroundColor: "#F3F4F6",
    marginBottom: 10,
    marginTop: 6,
  },
  iouRow: {
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: "#F3F4F6",
  },
  iouRowTop: {
    flexDirection: "row",
    alignItems: "flex-start",
    justifyContent: "space-between",
    gap: 12,
  },
  iouTitle: { fontSize: 14, fontWeight: "800", color: "#111827" },
  iouDir: { fontSize: 12, fontWeight: "700", marginTop: 2 },
  iouAmount: { fontSize: 15, fontWeight: "900" },
  statusPill: {
    borderRadius: 999,
    paddingHorizontal: 7,
    paddingVertical: 2,
    alignSelf: "flex-end",
  },
  statusText: { fontSize: 10, fontWeight: "800" },
  progTrack: {
    marginTop: 8,
    height: 5,
    borderRadius: 999,
    backgroundColor: "#EAEAEA",
    overflow: "hidden",
  },
  progFill: { height: "100%", borderRadius: 999 },
  iouNext: {
    marginTop: 5,
    fontSize: 12,
    fontWeight: "700",
    color: "#6B7280",
  },
  extPendingPill: {
    marginTop: 6,
    alignSelf: "flex-start",
    backgroundColor: "#FEF3C7",
    borderRadius: 6,
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderWidth: 1,
    borderColor: "#FDE68A",
  },
  extPendingText: {
    fontSize: 11,
    fontWeight: "700",
    color: "#92400E",
    letterSpacing: 0.2,
  },

  empty: { alignItems: "center", paddingTop: 60, paddingHorizontal: 24 },
  emptyTitle: {
    fontSize: 18,
    fontWeight: "900",
    color: "#111",
    marginBottom: 8,
  },
  emptyText: {
    color: "#667085",
    fontWeight: "600",
    textAlign: "center",
    lineHeight: 22,
  },
});

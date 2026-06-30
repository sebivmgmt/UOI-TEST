// src/screens/Inbox.tsx
import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  View,
  Text,
  SectionList,
  TouchableOpacity,
  Alert,
  ActivityIndicator,
  StyleSheet,
  RefreshControl,
} from "react-native";
import { supabase } from "../supabase";
import { parseDateInput } from "../utils/dateUtils";

const GREEN = "#77B777";
const RED = "#ef4444";
const BLUE = "#3B82F6";
const AMBER = "#F59E0B";
const BG = "#F5F7F9";

const currency = (cents: number) => `$${(cents / 100).toFixed(2)}`;

// due_date / extension date columns are plain YYYY-MM-DD strings — must parse
// as local calendar dates, not via `new Date(string)` (UTC midnight parsing
// can shift the displayed date back a day in negative-UTC-offset zones).
const formatDateOnly = (iso: string): string => {
  const d = parseDateInput(iso) ?? new Date(iso);
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
};

type IouRow = {
  id: string;
  title: string | null;
  principal_cents: number;
  apr_bps: number | null;
  term_months: number | null;
  frequency: string | null;
  status: string | null;
  created_at: string | null;
  activated_at: string | null;
  lender_id: string | null;
  borrower_id: string | null;
  created_by: string | null;
  requested_action_by: string | null;
};

type ExtensionItem = {
  id: string; // paymentId — used as SectionList key
  _type: 'extension';
  iouId: string;
  iouTitle: string | null;
  dueDateIso: string;
  amountCents: number;
  requestedUntilIso: string | null;
  borrowerName: string | null;
};

// Borrower-side: a lender's approve/deny decision on an extension request,
// read from the existing payment_extension_events ledger. This is a durable
// status/history item, not an unread notification — there is no read-state
// model behind it (no dismissal, no unread count, no push delivery).
type DecisionItem = {
  id: string; // `decision_${request_id}` — used as SectionList key
  _type: 'decision';
  iouId: string;
  iouTitle: string | null;
  paymentId: string;
  eventType: 'approved' | 'denied';
  originalDueDateIso: string | null;
  requestedUntilIso: string | null;
  decidedAtIso: string;
};

type AnyItem = IouRow | ExtensionItem | DecisionItem;

type SectionKey = "incoming" | "sent" | "ext_requests" | "ext_decisions";
type Section = {
  key: SectionKey;
  title: string;
  subtitle: string;
  data: AnyItem[];
};

export default function Inbox({ navigation }: any) {
  const [rows, setRows] = useState<IouRow[]>([]);
  const [extensionItems, setExtensionItems] = useState<ExtensionItem[]>([]);
  const [decisionItems, setDecisionItems] = useState<DecisionItem[]>([]);
  const [me, setMe] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      setMe(data.user?.id ?? null);
    });
  }, []);

  const load = useCallback(async () => {
    if (!me) return;
    setLoading(true);

    // Auxiliary queries (extension requests / decisions) must never silently
    // collapse into an empty section on failure — track failures and surface
    // a single combined warning instead of one alert per failed query.
    let auxQueryFailed = false;
    const logAuxError = (label: string, error: unknown) => {
      auxQueryFailed = true;
      if (__DEV__) {
        console.error(`[Inbox] ${label} failed`, error);
      }
    };

    // Load IOU requests, lender's open/late IOUs, and borrower's open/late IOUs in parallel.
    // "active" is not a valid ious.status value — the canonical contract for a
    // live (extendable) agreement is status IN ('open','late'), matching what
    // the payment-extension backend itself permits.
    const [iouResult, lenderIouResult, borrowerIouResult] = await Promise.all([
      supabase
        .from("ious")
        .select(
          "id,title,principal_cents,apr_bps,term_months,frequency,status,created_at,activated_at,lender_id,borrower_id,created_by,requested_action_by"
        )
        .in("status", ["open", "pending_acceptance", "draft"])
        .is("activated_at", null)
        .or(`lender_id.eq.${me},borrower_id.eq.${me}`)
        .is("deleted_at", null)
        .order("created_at", { ascending: false }),
      supabase
        .from("ious")
        .select("id,title,borrower_id")
        .eq("lender_id", me)
        .in("status", ["open", "late"])
        .is("deleted_at", null),
      supabase
        .from("ious")
        .select("id,title")
        .eq("borrower_id", me)
        .in("status", ["open", "late"])
        .is("deleted_at", null),
    ]);

    if (iouResult.error) {
      Alert.alert("Load failed", iouResult.error.message);
      setRows([]);
    } else {
      setRows((iouResult.data ?? []) as IouRow[]);
    }

    if (lenderIouResult.error) logAuxError("lenderIouResult", lenderIouResult.error);
    if (borrowerIouResult.error) logAuxError("borrowerIouResult", borrowerIouResult.error);

    // Build extension items from open/late lender IOUs
    const lenderIous = lenderIouResult.error ? [] : ((lenderIouResult.data ?? []) as any[]);
    const lenderIouIds = lenderIous.map((r: any) => r.id as string);
    const lenderIouMap: Record<string, any> = Object.fromEntries(lenderIous.map((r: any) => [r.id, r]));

    // Build decision items from open/late borrower IOUs (approved/denied extension events)
    const borrowerIous = borrowerIouResult.error ? [] : ((borrowerIouResult.data ?? []) as any[]);
    const borrowerIouIds = borrowerIous.map((r: any) => r.id as string);
    const borrowerIouTitleMap: Record<string, string | null> = Object.fromEntries(
      borrowerIous.map((r: any) => [r.id, r.title ?? null])
    );

    const [extResult, profileResult, eventsResult] = await Promise.all([
      lenderIouIds.length > 0
        ? supabase
            .from("payments")
            .select("id,iou_id,due_date,amount_cents,extension_requested_until")
            .in("iou_id", lenderIouIds)
            .eq("extension_status", "requested")
            .is("paid_at", null)
        : Promise.resolve({ data: [] as any[], error: null as any }),
      lenderIouIds.length > 0
        ? supabase
            .from("profile_directory")
            .select("id,public_name")
            .in(
              "id",
              [...new Set(lenderIous.map((r: any) => r.borrower_id).filter(Boolean))]
            )
        : Promise.resolve({ data: [] as any[], error: null as any }),
      borrowerIouIds.length > 0
        ? supabase
            .from("payment_extension_events")
            .select("request_id,payment_id,iou_id,event_type,original_due_date,requested_until,created_at")
            .in("iou_id", borrowerIouIds)
            .in("event_type", ["approved", "denied"])
            .order("created_at", { ascending: false })
        : Promise.resolve({ data: [] as any[], error: null as any }),
    ]);

    if (extResult.error) logAuxError("extResult", extResult.error);
    if (profileResult.error) logAuxError("profileResult", profileResult.error);
    if (eventsResult.error) logAuxError("eventsResult", eventsResult.error);

    const profileMap: Record<string, string | null> = profileResult.error
      ? {}
      : Object.fromEntries(
          ((profileResult.data ?? []) as any[]).map((p: any) => [p.id, p.public_name ?? null])
        );

    const extItems: ExtensionItem[] = extResult.error
      ? []
      : ((extResult.data ?? []) as any[]).map((p: any) => {
          const iou = lenderIouMap[p.iou_id];
          return {
            id: p.id,
            _type: 'extension' as const,
            iouId: p.iou_id,
            iouTitle: iou?.title ?? null,
            dueDateIso: p.due_date,
            amountCents: p.amount_cents,
            requestedUntilIso: p.extension_requested_until ?? null,
            borrowerName: iou?.borrower_id ? (profileMap[iou.borrower_id] ?? null) : null,
          };
        });
    setExtensionItems(extItems);

    // De-dupe: keep only the most recent event per request_id (events are
    // ordered by created_at desc, so the first occurrence wins).
    const seenRequestIds = new Set<string>();
    const decisions: DecisionItem[] = [];
    (eventsResult.error ? [] : ((eventsResult.data ?? []) as any[])).forEach((e: any) => {
      if (seenRequestIds.has(e.request_id)) return;
      seenRequestIds.add(e.request_id);
      decisions.push({
        id: `decision_${e.request_id}`,
        _type: 'decision' as const,
        iouId: e.iou_id,
        iouTitle: borrowerIouTitleMap[e.iou_id] ?? null,
        paymentId: e.payment_id,
        eventType: e.event_type,
        originalDueDateIso: e.original_due_date ?? null,
        requestedUntilIso: e.requested_until ?? null,
        decidedAtIso: e.created_at,
      });
    });
    setDecisionItems(decisions);

    if (auxQueryFailed) {
      Alert.alert(
        "Some updates couldn't load",
        "Extension request and decision info may be incomplete. Pull to refresh to try again."
      );
    }

    setLoading(false);
  }, [me]);

  useEffect(() => {
    void load();
  }, [load]);

  const onRefresh = async () => {
    setRefreshing(true);
    try {
      await load();
    } finally {
      setRefreshing(false);
    }
  };

  // A) Incoming: other party created it, waiting on ME to act
  // B) Sent: I created it, waiting on the OTHER person
  // C) Extension requests: lender reviewing borrower extension requests
  // D) Extension decisions: borrower seeing a lender's approve/deny decision (history, not unread)
  const sections: Section[] = useMemo(() => {
    const incoming: IouRow[] = [];
    const sent: IouRow[] = [];

    rows.forEach((row) => {
      if (row.requested_action_by === me) {
        incoming.push(row);
      } else {
        sent.push(row);
      }
    });

    const result: Section[] = [];

    if (extensionItems.length > 0) {
      result.push({
        key: "ext_requests",
        title: "Extension Requests",
        subtitle: "Borrowers requesting more time to pay",
        data: extensionItems,
      });
    }
    if (incoming.length > 0) {
      result.push({
        key: "incoming",
        title: "Incoming Requests",
        subtitle: "Waiting on you to review",
        data: incoming,
      });
    }
    if (sent.length > 0) {
      result.push({
        key: "sent",
        title: "Sent Requests",
        subtitle: "Waiting on the other person",
        data: sent,
      });
    }
    if (decisionItems.length > 0) {
      result.push({
        key: "ext_decisions",
        title: "Extension Updates",
        subtitle: "Recent lender decisions on your requests",
        data: decisionItems,
      });
    }
    return result;
  }, [rows, extensionItems, decisionItems, me]);

  const deny = (id: string) => {
    Alert.alert("Deny this request?", "The sender will be notified.", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Deny",
        style: "destructive",
        onPress: async () => {
          setBusyId(id);
          try {
            const { error } = await supabase.rpc("deny_iou_request", {
              p_iou_id: id,
              p_reason: null,
            });
            if (error) throw error;
            setRows((curr) => curr.filter((r) => r.id !== id));
          } catch (e: any) {
            Alert.alert("Deny failed", (e as any).message ?? String(e));
          } finally {
            setBusyId(null);
          }
        },
      },
    ]);
  };

  const cancel = (id: string) => {
    Alert.alert(
      "Cancel Request?",
      "This will withdraw your IOU request. This cannot be undone.",
      [
        { text: "Keep", style: "cancel" },
        {
          text: "Cancel Request",
          style: "destructive",
          onPress: async () => {
            setBusyId(id);
            try {
              const { error } = await supabase
                .from("ious")
                .update({ status: "canceled" })
                .eq("id", id)
                .or(`lender_id.eq.${me},created_by.eq.${me}`);
              if (error) throw error;
              setRows((curr) => curr.filter((r) => r.id !== id));
            } catch (e: any) {
              Alert.alert("Cancel failed", (e as any).message ?? String(e));
            } finally {
              setBusyId(null);
            }
          },
        },
      ]
    );
  };

  if (loading) {
    return (
      <View style={s.center}>
        <ActivityIndicator color={GREEN} />
      </View>
    );
  }

  if (sections.length === 0) {
    return (
      <View style={s.screen}>
        <View style={s.empty}>
          <Text style={s.emptyTitle}>All clear</Text>
          <Text style={s.emptyText}>
            New IOU requests and payment extension requests will appear here.
          </Text>
        </View>
      </View>
    );
  }

  return (
    <View style={s.screen}>
      <SectionList
        sections={sections}
        keyExtractor={(item) => item.id}
        stickySectionHeadersEnabled={false}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={onRefresh} />
        }
        contentContainerStyle={s.list}
        renderSectionHeader={({ section }) => (
          <View style={s.sectionHead}>
            <Text style={s.sectionTitle}>{section.title}</Text>
            <Text style={s.sectionSub}>{section.subtitle}</Text>
          </View>
        )}
        SectionSeparatorComponent={() => <View style={{ height: 8 }} />}
        ItemSeparatorComponent={() => <View style={{ height: 10 }} />}
        renderItem={({ item, section }) => {
          // Extension request card (lender reviewing borrower request)
          if ('_type' in item && (item as ExtensionItem)._type === 'extension') {
            const ext = item as ExtensionItem;
            return (
              <TouchableOpacity
                style={s.card}
                onPress={() =>
                  navigation.navigate("LoanDetail", {
                    iouId: ext.iouId,
                    initialTab: 'payments',
                    focusPaymentId: ext.id,
                  })
                }
                activeOpacity={0.8}
              >
                <View style={s.cardHeader}>
                  <Text style={s.cardTitle} numberOfLines={1}>
                    {ext.iouTitle || "IOU"}
                  </Text>
                  <View style={s.reviewBadge}>
                    <Text style={s.reviewBadgeText}>REVIEW</Text>
                  </View>
                </View>
                <Text style={s.amount}>{currency(ext.amountCents)}</Text>
                <Text style={s.meta}>
                  {"Due "}
                  {formatDateOnly(ext.dueDateIso)}
                  {ext.requestedUntilIso
                    ? ` · Requesting until ${formatDateOnly(ext.requestedUntilIso)}`
                    : ""}
                </Text>
                {!!ext.borrowerName && (
                  <Text style={s.meta}>From {ext.borrowerName}</Text>
                )}
                <View style={s.actionPrompt}>
                  <Text style={s.actionPromptText}>
                    Tap to review and approve or deny this request.
                  </Text>
                </View>
              </TouchableOpacity>
            );
          }

          // Extension decision card (borrower viewing a lender's approve/deny decision)
          if ('_type' in item && (item as DecisionItem)._type === 'decision') {
            const dec = item as DecisionItem;
            const approved = dec.eventType === 'approved';
            return (
              <TouchableOpacity
                style={s.card}
                onPress={() =>
                  navigation.navigate("LoanDetail", {
                    iouId: dec.iouId,
                    initialTab: 'payments',
                    focusPaymentId: dec.paymentId,
                  })
                }
                activeOpacity={0.8}
              >
                <View style={s.cardHeader}>
                  <Text style={s.cardTitle} numberOfLines={1}>
                    {dec.iouTitle || "IOU"}
                  </Text>
                  <View style={[s.pendingBadge, approved ? s.decisionApprovedBadge : s.decisionDeniedBadge]}>
                    <Text style={[s.pendingText, approved ? s.decisionApprovedText : s.decisionDeniedText]}>
                      {approved ? "APPROVED" : "DENIED"}
                    </Text>
                  </View>
                </View>
                <Text style={[s.amount, { fontSize: 17 }, approved ? s.decisionApprovedText : s.decisionDeniedText]}>
                  {approved ? "Extension approved" : "Extension denied"}
                </Text>
                <Text style={s.meta}>
                  {approved && dec.requestedUntilIso
                    ? `New due date ${formatDateOnly(dec.requestedUntilIso)}`
                    : dec.originalDueDateIso
                      ? `Original due date ${formatDateOnly(dec.originalDueDateIso)} applies`
                      : "Your original due date applies"}
                </Text>
                <Text style={s.meta}>
                  Decided {formatDateOnly(dec.decidedAtIso)}
                </Text>
              </TouchableOpacity>
            );
          }

          const iouItem = item as IouRow;
          const isIncoming = section.key === "incoming";
          const busy = busyId === iouItem.id;
          const apr =
            typeof iouItem.apr_bps === "number" ? iouItem.apr_bps / 100 : 0;

          return (
            <View style={s.card}>
              <View style={s.cardHeader}>
                <Text style={s.cardTitle} numberOfLines={1}>
                  {iouItem.title || "IOU Request"}
                </Text>
                {!isIncoming && (
                  <View style={[
                    s.pendingBadge,
                    iouItem.status === "draft" && { backgroundColor: "#FEF3C7" },
                  ]}>
                    <Text style={[
                      s.pendingText,
                      iouItem.status === "draft" && { color: AMBER },
                    ]}>
                      {iouItem.status === "draft" ? "AWAITING APPROVAL" : "PENDING"}
                    </Text>
                  </View>
                )}
              </View>

              <Text style={s.amount}>{currency(iouItem.principal_cents)}</Text>

              <Text style={s.meta}>
                {apr > 0 ? `${apr}% APR · ` : ""}
                {iouItem.term_months ? `${iouItem.term_months} mo` : "—"}
                {iouItem.frequency ? ` · ${iouItem.frequency}` : ""}
              </Text>
              <Text style={s.meta}>
                {iouItem.created_at
                  ? new Date(iouItem.created_at).toLocaleDateString(undefined, {
                      month: "short",
                      day: "numeric",
                      year: "numeric",
                    })
                  : "—"}
              </Text>

              {isIncoming ? (
                iouItem.status === "draft" ? (
                  // Lender incoming: borrower proposed schedule dates, needs approval
                  <View>
                    <View style={s.actionPrompt}>
                      <View style={[s.sigBadge, s.scheduleChangeBadge]}>
                        <Text style={[s.sigBadgeText, s.scheduleChangeBadgeText]}>
                          SCHEDULE CHANGE PROPOSED
                        </Text>
                      </View>
                      <Text style={s.actionPromptText}>
                        Borrower has proposed payment dates. Review and approve or reject.
                      </Text>
                    </View>
                    <View style={s.actions}>
                      <TouchableOpacity
                        style={[s.btn, s.reviewBtn, { flex: 2 }]}
                        onPress={() =>
                          navigation.navigate("PreviewSign", { id: iouItem.id })
                        }
                        disabled={busy}
                      >
                        <Text style={s.btnText}>Review Changes</Text>
                      </TouchableOpacity>
                      <TouchableOpacity
                        style={[s.btn, s.denyBtn, { flex: 1 }]}
                        onPress={() => deny(iouItem.id)}
                        disabled={busy}
                      >
                        {busy ? (
                          <ActivityIndicator color="#fff" size="small" />
                        ) : (
                          <Text style={s.btnText}>Deny</Text>
                        )}
                      </TouchableOpacity>
                    </View>
                  </View>
                ) : (
                  // Borrower incoming: new IOU — needs to review, set schedule, and sign
                  <View>
                    <View style={s.actionPrompt}>
                      <View style={s.sigBadge}>
                        <Text style={s.sigBadgeText}>SCHEDULE + SIGNATURE REQUIRED</Text>
                      </View>
                      <Text style={s.actionPromptText}>
                        Set your payment schedule and sign to activate.
                      </Text>
                    </View>
                    <View style={s.actions}>
                      <TouchableOpacity
                        style={[s.btn, s.reviewBtn, { flex: 2 }]}
                        onPress={() =>
                          navigation.navigate("PreviewSign", { id: iouItem.id })
                        }
                        disabled={busy}
                      >
                        <Text style={s.btnText}>Review & Set Schedule</Text>
                      </TouchableOpacity>
                      <TouchableOpacity
                        style={[s.btn, s.denyBtn, { flex: 1 }]}
                        onPress={() => deny(iouItem.id)}
                        disabled={busy}
                      >
                        {busy ? (
                          <ActivityIndicator color="#fff" size="small" />
                        ) : (
                          <Text style={s.btnText}>Deny</Text>
                        )}
                      </TouchableOpacity>
                    </View>
                  </View>
                )
              ) : (
                // Sent: can only view or cancel
                <View>
                  {iouItem.status === "draft" && (
                    <View style={s.actionPrompt}>
                      <View style={[s.sigBadge, s.scheduleChangeBadge]}>
                        <Text style={[s.sigBadgeText, s.scheduleChangeBadgeText]}>
                          AWAITING LENDER APPROVAL
                        </Text>
                      </View>
                      <Text style={s.actionPromptText}>
                        Your proposed schedule is waiting for lender review.
                      </Text>
                    </View>
                  )}
                  <View style={s.actions}>
                    <TouchableOpacity
                      style={[s.btn, s.reviewBtn, { flex: 2 }]}
                      onPress={() =>
                        navigation.navigate("PreviewSign", { id: iouItem.id })
                      }
                      disabled={busy}
                    >
                      <Text style={s.btnText}>View Details</Text>
                    </TouchableOpacity>
                    <TouchableOpacity
                      style={[s.btn, s.cancelBtn, { flex: 1 }]}
                      onPress={() => cancel(iouItem.id)}
                      disabled={busy}
                    >
                      {busy ? (
                        <ActivityIndicator color={RED} size="small" />
                      ) : (
                        <Text style={[s.btnText, { color: RED }]}>Cancel</Text>
                      )}
                    </TouchableOpacity>
                  </View>
                </View>
              )}
            </View>
          );
        }}
      />
    </View>
  );
}

const s = StyleSheet.create({
  screen: { flex: 1, backgroundColor: BG },
  center: { flex: 1, alignItems: "center", justifyContent: "center" },
  list: { padding: 16, paddingBottom: 100 },
  sectionHead: { marginBottom: 10, marginTop: 4 },
  sectionTitle: {
    fontSize: 17,
    fontWeight: "900",
    color: "#111827",
  },
  sectionSub: {
    fontSize: 12,
    color: "#667085",
    fontWeight: "600",
    marginTop: 2,
  },
  card: {
    backgroundColor: "#fff",
    borderRadius: 14,
    padding: 14,
    borderWidth: 1,
    borderColor: "#e5e7eb",
  },
  cardHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 8,
  },
  cardTitle: {
    flex: 1,
    fontSize: 16,
    fontWeight: "900",
    color: "#111827",
  },
  pendingBadge: {
    backgroundColor: "#FEF3C7",
    borderRadius: 6,
    paddingHorizontal: 8,
    paddingVertical: 3,
  },
  pendingText: {
    fontSize: 10,
    fontWeight: "800",
    color: AMBER,
    letterSpacing: 0.5,
  },
  reviewBadge: {
    backgroundColor: "#ECFDF5",
    borderRadius: 6,
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderWidth: 1,
    borderColor: "#A7F3D0",
  },
  reviewBadgeText: {
    fontSize: 10,
    fontWeight: "800",
    color: "#065F46",
    letterSpacing: 0.5,
  },
  decisionApprovedBadge: { backgroundColor: "#ECFDF5", borderWidth: 1, borderColor: "#A7F3D0" },
  decisionDeniedBadge: { backgroundColor: "#FEF2F2", borderWidth: 1, borderColor: "#FCA5A5" },
  decisionApprovedText: { color: "#065F46" },
  decisionDeniedText: { color: RED },
  amount: {
    marginTop: 8,
    fontSize: 26,
    fontWeight: "900",
    color: GREEN,
  },
  meta: {
    marginTop: 4,
    color: "#667085",
    fontWeight: "600",
    fontSize: 13,
  },
  actions: {
    flexDirection: "row",
    gap: 8,
    marginTop: 14,
  },
  btn: {
    borderRadius: 10,
    paddingVertical: 11,
    alignItems: "center",
    justifyContent: "center",
  },
  reviewBtn: { backgroundColor: BLUE },
  denyBtn: { backgroundColor: RED },
  actionPrompt: {
    marginTop: 10,
    marginBottom: 2,
  },
  sigBadge: {
    alignSelf: "flex-start",
    backgroundColor: "#EFF6FF",
    borderRadius: 6,
    paddingHorizontal: 8,
    paddingVertical: 3,
    marginBottom: 4,
  },
  sigBadgeText: {
    fontSize: 10,
    fontWeight: "800",
    color: BLUE,
    letterSpacing: 0.5,
  },
  actionPromptText: {
    fontSize: 13,
    fontWeight: "600",
    color: "#667085",
  },
  cancelBtn: {
    backgroundColor: "#FEF2F2",
    borderWidth: 1,
    borderColor: "#FCA5A5",
  },
  scheduleChangeBadge: {
    backgroundColor: "#FEF3C7",
  },
  scheduleChangeBadgeText: {
    color: AMBER,
  },
  btnText: {
    color: "#fff",
    fontWeight: "900",
    fontSize: 14,
  },
  empty: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    padding: 40,
    marginTop: 80,
  },
  emptyTitle: {
    fontSize: 20,
    fontWeight: "900",
    color: "#111827",
  },
  emptyText: {
    marginTop: 8,
    textAlign: "center",
    color: "#667085",
    fontWeight: "600",
    lineHeight: 22,
  },
});

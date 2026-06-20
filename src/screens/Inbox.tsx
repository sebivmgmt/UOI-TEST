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

const GREEN = "#77B777";
const RED = "#ef4444";
const BLUE = "#3B82F6";
const AMBER = "#F59E0B";
const BG = "#F5F7F9";

const currency = (cents: number) => `$${(cents / 100).toFixed(2)}`;

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

type SectionKey = "incoming" | "sent";
type Section = {
  key: SectionKey;
  title: string;
  subtitle: string;
  data: IouRow[];
};

export default function Inbox({ navigation }: any) {
  const [rows, setRows] = useState<IouRow[]>([]);
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
    const { data, error } = await supabase
      .from("ious")
      .select(
        "id,title,principal_cents,apr_bps,term_months,frequency,status,created_at,activated_at,lender_id,borrower_id,created_by,requested_action_by"
      )
      .in("status", ["open", "pending_acceptance", "draft"])
      .is("activated_at", null)
      .or(`lender_id.eq.${me},borrower_id.eq.${me}`)
      .is("deleted_at", null)
      .order("created_at", { ascending: false });

    if (error) {
      Alert.alert("Load failed", error.message);
      setRows([]);
    } else {
      setRows((data ?? []) as IouRow[]);
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
    return result;
  }, [rows, me]);

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
            New requests will appear here when someone creates an IOU with you.
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
          const isIncoming = section.key === "incoming";
          const busy = busyId === item.id;
          const apr =
            typeof item.apr_bps === "number" ? item.apr_bps / 100 : 0;

          return (
            <View style={s.card}>
              <View style={s.cardHeader}>
                <Text style={s.cardTitle} numberOfLines={1}>
                  {item.title || "IOU Request"}
                </Text>
                {!isIncoming && (
                  <View style={[
                    s.pendingBadge,
                    item.status === "draft" && { backgroundColor: "#FEF3C7" },
                  ]}>
                    <Text style={[
                      s.pendingText,
                      item.status === "draft" && { color: AMBER },
                    ]}>
                      {item.status === "draft" ? "AWAITING APPROVAL" : "PENDING"}
                    </Text>
                  </View>
                )}
              </View>

              <Text style={s.amount}>{currency(item.principal_cents)}</Text>

              <Text style={s.meta}>
                {apr > 0 ? `${apr}% APR · ` : ""}
                {item.term_months ? `${item.term_months} mo` : "—"}
                {item.frequency ? ` · ${item.frequency}` : ""}
              </Text>
              <Text style={s.meta}>
                {item.created_at
                  ? new Date(item.created_at).toLocaleDateString(undefined, {
                      month: "short",
                      day: "numeric",
                      year: "numeric",
                    })
                  : "—"}
              </Text>

              {isIncoming ? (
                item.status === "draft" ? (
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
                          navigation.navigate("PreviewSign", { id: item.id })
                        }
                        disabled={busy}
                      >
                        <Text style={s.btnText}>Review Changes</Text>
                      </TouchableOpacity>
                      <TouchableOpacity
                        style={[s.btn, s.denyBtn, { flex: 1 }]}
                        onPress={() => deny(item.id)}
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
                          navigation.navigate("PreviewSign", { id: item.id })
                        }
                        disabled={busy}
                      >
                        <Text style={s.btnText}>Review & Set Schedule</Text>
                      </TouchableOpacity>
                      <TouchableOpacity
                        style={[s.btn, s.denyBtn, { flex: 1 }]}
                        onPress={() => deny(item.id)}
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
                  {item.status === "draft" && (
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
                        navigation.navigate("PreviewSign", { id: item.id })
                      }
                      disabled={busy}
                    >
                      <Text style={s.btnText}>View Details</Text>
                    </TouchableOpacity>
                    <TouchableOpacity
                      style={[s.btn, s.cancelBtn, { flex: 1 }]}
                      onPress={() => cancel(item.id)}
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

import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  ActivityIndicator,
  ScrollView,
  TouchableOpacity,
  RefreshControl,
  Alert,
} from "react-native";
import { supabase } from "../supabase";
import {
  getPublicIouScoreV22,
  tierColor,
  formatTierLabel,
  type OfficialScoreV22,
} from "../services/iouScoreV22";

const GREEN = "#77B777";
const GREEN_DARK = "#5F9F5F";
const RED = "#D9534F";
const BLUE = "#3B82F6";
const BG = "#F5F7F9";

type ProfileRow = {
  id: string;
  iou_hash: string | null;
  public_name: string | null;
  avatar_url: string | null;
  strike_count?: number | null;
};

type LoanLite = {
  id: string;
  title: string | null;
  principal_cents: number;
  status: string;
  archived_at: string | null;
  deleted_at: string | null;
  lender_id: string | null;
  borrower_id: string | null;
  created_at?: string | null;
};

const currency = (cents: number) => `$${(cents / 100).toFixed(2)}`;

export default function PersonScreen({ route, navigation }: any) {
  const personId: string | undefined =
    route?.params?.personId ?? route?.params?.id;

  const [meId, setMeId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [person, setPerson] = useState<ProfileRow | null>(null);
  const [officialScore, setOfficialScore] = useState<OfficialScoreV22 | null>(null);
  const [loans, setLoans] = useState<LoanLite[]>([]);

  const load = useCallback(async () => {
    if (!personId) {
      setLoading(false);
      return;
    }

    setLoading(true);

    try {
      const me = (await supabase.auth.getUser()).data.user;
      setMeId(me?.id ?? null);

      const { data: profileData, error: profileError } = await supabase
        .from("profile_directory")
        .select("id, iou_hash, public_name, avatar_url, strike_count")
        .eq("id", personId)
        .single();

      if (profileError) throw profileError;

      setPerson((profileData as ProfileRow) ?? null);
      setOfficialScore(await getPublicIouScoreV22(personId));

      if (me?.id) {
        const { data: loanData, error: loanError } = await supabase
          .from("ious")
          .select(
            "id, title, principal_cents, status, archived_at, deleted_at, lender_id, borrower_id, created_at"
          )
          .or(
            `and(lender_id.eq.${me.id},borrower_id.eq.${personId}),and(lender_id.eq.${personId},borrower_id.eq.${me.id})`
          )
          .order("created_at", { ascending: false });

        if (loanError) throw loanError;

        setLoans((loanData ?? []) as LoanLite[]);
      } else {
        setLoans([]);
      }
    } catch (e: any) {
      Alert.alert("Load failed", e?.message ?? String(e));
    } finally {
      setLoading(false);
    }
  }, [personId]);

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

  const displayName = useMemo(() => {
    return person?.public_name || "Unnamed person";
  }, [person]);

  const scoreValue = officialScore?.public_score ?? null;
  const visibleTrust = officialScore?.visible_trust ?? null;
  const scoreLabel = formatTierLabel(officialScore?.trust_tier);
  const scoreColor = tierColor(officialScore?.trust_tier, {
    strong: GREEN_DARK,
    rising: GREEN,
    starter: BLUE,
    watch: "#B7791F",
    muted: "#111",
    critical: RED,
  });

  const strikeCount = useMemo(() => {
    if (typeof person?.strike_count === "number") {
      return Math.max(0, person.strike_count);
    }
    return 0;
  }, [person]);

  const openLoan = (loanId: string) => {
    navigation.navigate("LoanDetail", { iouId: loanId });
  };

  const startNewLoan = () => {
    navigation.navigate("NewIouScreen", {
      initialRole: "lend",
      presetCounterpartyId: person?.id,
      presetCounterpartyName: displayName ?? null,
    });
  };

  if (loading) {
    return (
      <View style={s.center}>
        <ActivityIndicator />
      </View>
    );
  }

  if (!personId) {
    return (
      <View style={s.center}>
        <Text>Missing person id.</Text>
      </View>
    );
  }

  if (!person) {
    return (
      <View style={s.center}>
        <Text>Person not found.</Text>
      </View>
    );
  }

  return (
    <ScrollView
      style={s.screen}
      contentContainerStyle={s.content}
      refreshControl={
        <RefreshControl refreshing={refreshing} onRefresh={onRefresh} />
      }
      showsVerticalScrollIndicator={false}
    >
      <View style={s.heroCard}>
        <Text style={s.eyebrow}>Counterparty</Text>
        <Text style={s.h1}>{displayName}</Text>
        <Text style={s.heroSub}>{person.iou_hash || person.id}</Text>

        <View style={s.heroStatusRow}>
          <View style={[s.statusPill, { backgroundColor: "#EEF7EE" }]}>
            <Text style={[s.statusPillText, { color: scoreColor }]}>
              {scoreLabel}
            </Text>
          </View>

          <View style={[s.statusPill, { backgroundColor: "#EEF4FF" }]}>
            <Text style={[s.statusPillText, { color: BLUE }]}>
              Public Profile
            </Text>
          </View>
        </View>
      </View>

      <View style={s.scoreCard}>
        <Text style={s.sectionTitle}>Trust Snapshot</Text>

        <View style={s.metricsRow}>
          <View style={s.metricBox}>
            <Text style={s.metricLabel}>IOU score</Text>
            <Text style={[s.metricValue, { color: scoreColor }]}>
              {scoreValue === null ? "—" : scoreValue}
            </Text>
          </View>

          <View style={s.metricBox}>
            <Text style={s.metricLabel}>Visible trust</Text>
            <Text style={s.metricValue}>
              {visibleTrust === null ? "—" : visibleTrust}
            </Text>
          </View>
        </View>

        <View style={s.metricsRow}>
          <View style={s.metricBox}>
            <Text style={s.metricLabel}>Strikes</Text>
            <Text
              style={[
                s.metricValue,
                strikeCount > 0 ? { color: RED } : { color: GREEN_DARK },
              ]}
            >
              {strikeCount}
            </Text>
          </View>
        </View>
      </View>

      <TouchableOpacity style={s.primaryBtn} onPress={startNewLoan}>
        <Text style={s.primaryBtnText}>New IOU with this person</Text>
      </TouchableOpacity>

      <View style={s.card}>
        <Text style={s.sectionTitle}>Loans with this person</Text>

        {loans.length === 0 && (
          <Text style={s.emptyText}>No loans with this person yet.</Text>
        )}

        {loans.map((loan) => {
          const iAmLender = !!meId && loan.lender_id === meId;
          const directionLabel = iAmLender ? "You lent" : "You borrowed";
          const isArchived = !!loan.archived_at || loan.status === "paid";

          return (
            <TouchableOpacity
              key={loan.id}
              style={s.loanRow}
              onPress={() => openLoan(loan.id)}
              activeOpacity={0.9}
            >
              <View style={{ flex: 1 }}>
                <Text style={s.loanTitle}>{loan.title || "Loan"}</Text>
                <Text style={s.loanMeta}>
                  {directionLabel} • {currency(loan.principal_cents)}
                </Text>
                <Text style={s.loanMeta}>
                  {isArchived ? "Archived / closed" : "Active"} • {loan.status}
                </Text>
              </View>

              <View
                style={[
                  s.loanPill,
                  {
                    backgroundColor: isArchived ? "#EEF2F5" : "#EEF7EE",
                  },
                ]}
              >
                <Text
                  style={[
                    s.loanPillText,
                    { color: isArchived ? "#475467" : GREEN_DARK },
                  ]}
                >
                  {isArchived ? "Closed" : "Open"}
                </Text>
              </View>
            </TouchableOpacity>
          );
        })}
      </View>
    </ScrollView>
  );
}

const s = StyleSheet.create({
  screen: { flex: 1, backgroundColor: BG },
  content: { padding: 16, paddingBottom: 28 },
  center: { flex: 1, alignItems: "center", justifyContent: "center" },

  heroCard: {
    backgroundColor: "#fff",
    borderRadius: 16,
    padding: 16,
    marginBottom: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#e5e7eb",
  },

  scoreCard: {
    backgroundColor: "#fff",
    borderRadius: 16,
    padding: 16,
    marginBottom: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#e5e7eb",
  },

  card: {
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 14,
    marginBottom: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#e5e7eb",
  },

  eyebrow: {
    fontSize: 12,
    fontWeight: "800",
    textTransform: "uppercase",
    color: GREEN,
    marginBottom: 6,
    letterSpacing: 0.4,
  },

  h1: {
    fontSize: 24,
    fontWeight: "800",
    color: "#111",
  },

  heroSub: {
    marginTop: 6,
    color: "#666",
    fontSize: 15,
  },

  heroStatusRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
    marginTop: 14,
  },

  statusPill: {
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 6,
  },

  statusPillText: {
    fontWeight: "800",
    fontSize: 12,
  },

  sectionTitle: {
    fontSize: 18,
    fontWeight: "800",
    color: "#111",
    marginBottom: 8,
  },

  metricsRow: {
    flexDirection: "row",
    gap: 10,
    marginTop: 10,
  },

  metricBox: {
    flex: 1,
    backgroundColor: "#F6F8FA",
    borderRadius: 12,
    padding: 12,
    borderWidth: 1,
    borderColor: "#E8EBEF",
  },

  metricLabel: {
    fontSize: 12,
    fontWeight: "800",
    color: "#667085",
    textTransform: "uppercase",
    marginBottom: 6,
  },

  metricValue: {
    fontSize: 24,
    fontWeight: "900",
    color: "#111",
  },

  summaryRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingVertical: 8,
  },

  summaryLabel: {
    color: "#555",
    fontSize: 15,
  },

  summaryValue: {
    color: "#111",
    fontSize: 15,
    fontWeight: "800",
  },

  primaryBtn: {
    marginTop: 14,
    backgroundColor: GREEN,
    borderRadius: 12,
    paddingVertical: 12,
    alignItems: "center",
  },

  primaryBtnText: {
    color: "#fff",
    fontWeight: "800",
    fontSize: 15,
  },

  emptyText: {
    color: "#666",
    marginTop: 4,
  },

  loanRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingVertical: 12,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#E5E7EB",
  },

  loanTitle: {
    fontSize: 15,
    fontWeight: "800",
    color: "#111",
  },

  loanMeta: {
    marginTop: 3,
    fontSize: 13,
    color: "#666",
  },

  loanPill: {
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 6,
  },

  loanPillText: {
    fontWeight: "800",
    fontSize: 12,
  },
});
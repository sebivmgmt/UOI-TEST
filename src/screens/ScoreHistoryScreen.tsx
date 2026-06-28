// src/screens/ScoreHistoryScreen.tsx
import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  ActivityIndicator,
  ScrollView,
  RefreshControl,
} from "react-native";
import { useFocusEffect } from "@react-navigation/native";
import { supabase } from "../supabase";
import {
  getMyOfficialIouScoreV22,
  tierColor,
  formatTierLabel,
  type MyScoreV22,
} from "../services/iouScoreV22";

const GREEN = "#77B777";
const GREEN_DARK = "#5F9F5F";
const RED = "#D9534F";
const BLUE = "#3B82F6";
const BG = "#F5F7F9";

type ProfileRow = {
  id: string;
  strike_count?: number | null;
  score_last_updated_at?: string | null;
};

type ScoreEventRow = {
  id: string;
  event_type?: string | null;
  delta?: number | null;
  description?: string | null;
  reason?: string | null;
  created_at?: string | null;
};

export default function ScoreHistoryScreen() {
  const [userId, setUserId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [profile, setProfile] = useState<ProfileRow | null>(null);
  const [myScore, setMyScore] = useState<MyScoreV22 | null>(null);
  const [events, setEvents] = useState<ScoreEventRow[]>([]);

  const load = useCallback(async () => {
    const me = (await supabase.auth.getUser()).data.user;
    setUserId(me?.id ?? null);

    if (!me?.id) {
      setProfile(null);
      setEvents([]);
      setLoading(false);
      return;
    }

    const [scoreResult, profileResult] = await Promise.all([
      getMyOfficialIouScoreV22(),
      supabase
        .from("profiles")
        .select("id, strike_count, score_last_updated_at")
        .eq("id", me.id)
        .single(),
    ]);

    setMyScore(scoreResult);

    if (profileResult.data) {
      setProfile({
        id: profileResult.data.id,
        strike_count:
          typeof (profileResult.data as any).strike_count === "number"
            ? (profileResult.data as any).strike_count
            : 0,
        score_last_updated_at: (profileResult.data as any).score_last_updated_at ?? null,
      });
    } else {
      setProfile(null);
    }

    let eventRows: ScoreEventRow[] = [];

    const eventQueries = [
      supabase
        .from("score_events")
        .select("id, event_type, delta, description, created_at")
        .eq("user_id", me.id)
        .order("created_at", { ascending: false })
        .limit(25),
      supabase
        .from("score_history")
        .select("id, event_type, delta, description, created_at")
        .eq("user_id", me.id)
        .order("created_at", { ascending: false })
        .limit(25),
      supabase
        .from("score_history")
        .select("id, reason, delta, created_at")
        .eq("user_id", me.id)
        .order("created_at", { ascending: false })
        .limit(25),
    ];

    for (const query of eventQueries) {
      const { data, error } = await query;
      if (!error && Array.isArray(data)) {
        eventRows = data as ScoreEventRow[];
        break;
      }
    }

    setEvents(eventRows);
    setLoading(false);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load])
  );

  useEffect(() => {
    if (!userId) return;

    const profilesChannel = supabase
      .channel(`score-history-profile-${userId}`)
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "profiles",
          filter: `id=eq.${userId}`,
        },
        () => {
          void load();
        }
      )
      .subscribe();

    const scoreEventsChannel = supabase
      .channel(`score-history-events-${userId}`)
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "score_events",
          filter: `user_id=eq.${userId}`,
        },
        () => {
          void load();
        }
      )
      .subscribe();

    const scoreHistoryChannel = supabase
      .channel(`score-history-fallback-${userId}`)
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "score_history",
          filter: `user_id=eq.${userId}`,
        },
        () => {
          void load();
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(profilesChannel);
      supabase.removeChannel(scoreEventsChannel);
      supabase.removeChannel(scoreHistoryChannel);
    };
  }, [userId, load]);

  const onRefresh = async () => {
    setRefreshing(true);
    try {
      await load();
    } finally {
      setRefreshing(false);
    }
  };

  const scoreValue = myScore?.shadow_score ?? null;
  const exposureValue = myScore?.active_exposure_points ?? 0;
  const visibleTrust = myScore?.visible_trust ?? null;
  const scoreLabel = formatTierLabel(myScore?.trust_tier);
  const scoreColor = tierColor(myScore?.trust_tier, {
    strong: GREEN_DARK,
    rising: GREEN,
    starter: BLUE,
    watch: "#B7791F",
    muted: "#111",
    critical: RED,
  });

  const strikeCount = useMemo(() => {
    if (typeof profile?.strike_count === "number") {
      return Math.max(0, profile.strike_count);
    }
    return 0;
  }, [profile]);

  const scoreUpdatedLabel = useMemo(() => {
    if (!profile?.score_last_updated_at) return null;
    const date = new Date(profile.score_last_updated_at);
    if (Number.isNaN(date.getTime())) return null;
    return date.toLocaleString();
  }, [profile]);

  const normalizedEvents = useMemo(() => {
    return events.map((event) => {
      const delta =
        typeof event.delta === "number" ? event.delta : Number(event.delta ?? 0);

      const rawType = event.event_type ?? event.reason ?? "score_update";
      const prettyType = String(rawType).replace(/_/g, " ");

      const titleMap: Record<string, string> = {
        payment_on_time: "On-time payment",
        payment_early: "Early payment",
        payment_late: "Late payment",
        loan_completion: "Loan completed",
        exposure_removed: "Exposure removed",
        strike_1: "Strike 1",
        strike_2: "Strike 2",
        strike_3: "Strike 3",
        score_update: "Score update",
      };

      const title = titleMap[String(rawType)] ?? prettyType;
      const subtitle =
        event.description ??
        event.reason?.replace(/_/g, " ") ??
        "Score updated";

      const createdAt = event.created_at ? new Date(event.created_at) : null;

      return {
        id: event.id,
        delta,
        title,
        subtitle,
        createdAtLabel:
          createdAt && !Number.isNaN(createdAt.getTime())
            ? createdAt.toLocaleString()
            : null,
      };
    });
  }, [events]);

  if (loading) {
    return (
      <View style={s.center}>
        <ActivityIndicator />
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
        <Text style={s.eyebrow}>Score history</Text>
        <Text style={s.h1}>Your IOU Score</Text>
        <Text style={s.heroSub}>
          Full breakdown of trust, exposure, and recent movement.
        </Text>
      </View>

      <View style={s.scoreHeroCard}>
        <View style={s.rowBetweenTop}>
          <Text style={s.scoreHeroTitle}>Current Score</Text>
          <View style={[s.scoreBadge, { backgroundColor: "#EEF7EE" }]}>
            <Text style={[s.scoreBadgeText, { color: scoreColor }]}>
              {scoreLabel}
            </Text>
          </View>
        </View>

        <Text style={[s.scoreHeroValue, { color: scoreColor }]}>
          {scoreValue === null ? "—" : scoreValue}
        </Text>

        <Text style={s.scoreHeroHint}>
          {scoreValue === null
            ? "No score yet."
            : "Your base IOU trust score before temporary exposure is subtracted."}
        </Text>

        <View style={s.metricsRow}>
          <View style={s.metricBox}>
            <Text style={s.metricLabel}>Visible trust</Text>
            <Text style={s.metricValue}>
              {visibleTrust === null ? "—" : visibleTrust}
            </Text>
          </View>

          <View style={s.metricBox}>
            <Text style={s.metricLabel}>Active exposure</Text>
            <Text
              style={[
                s.metricValue,
                exposureValue > 0 ? { color: "#B45309" } : { color: GREEN_DARK },
              ]}
            >
              {exposureValue > 0 ? `-${exposureValue}` : "0"}
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

          <View style={s.metricBox}>
            <Text style={s.metricLabel}>Completion reward</Text>
            <Text style={s.metricValueSmall}>Large on final payoff</Text>
          </View>
        </View>

        {scoreUpdatedLabel && (
          <Text style={s.scoreUpdatedText}>Updated {scoreUpdatedLabel}</Text>
        )}
      </View>

      <View style={s.card}>
        <Text style={s.sectionTitle}>How scoring works</Text>
        <Text style={s.infoText}>
          Base score starts at 700. On-time full payments give a small reward.
          Early full payments give a medium reward. Finishing a loan gives a
          large reward. Active exposure temporarily lowers visible trust while
          loans are open.
        </Text>
        <Text style={[s.infoText, { marginTop: 10 }]}>
          Extensions approved by the lender are neutral. Defaults create strikes.
          Strike 1 and 2 are heavy penalties. Strike 3 crushes the score and
          creates a lifetime cap.
        </Text>
      </View>

      <View style={s.card}>
        <Text style={s.sectionTitle}>Recent score activity</Text>

        {normalizedEvents.length === 0 && (
          <Text style={s.emptyText}>No recent score activity yet.</Text>
        )}

        {normalizedEvents.map((event) => (
          <View key={event.id} style={s.activityRow}>
            <View style={s.activityLeft}>
              <Text
                style={[
                  s.activityDelta,
                  event.delta >= 0 ? { color: GREEN } : { color: RED },
                ]}
              >
                {event.delta > 0 ? `+${event.delta}` : event.delta}
              </Text>
            </View>

            <View style={s.activityRight}>
              <Text style={s.activityTitle}>{event.title}</Text>
              <Text style={s.activitySubtitle}>{event.subtitle}</Text>
              {event.createdAtLabel && (
                <Text style={s.activityDate}>{event.createdAtLabel}</Text>
              )}
            </View>
          </View>
        ))}
      </View>
    </ScrollView>
  );
}

const s = StyleSheet.create({
  screen: {
    flex: 1,
    backgroundColor: BG,
  },

  content: {
    padding: 16,
    paddingBottom: 28,
  },

  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
  },

  heroCard: {
    backgroundColor: "#fff",
    borderRadius: 16,
    padding: 16,
    marginBottom: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#e5e7eb",
  },

  scoreHeroCard: {
    backgroundColor: "#fff",
    borderRadius: 16,
    padding: 16,
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

  card: {
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 14,
    marginBottom: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#e5e7eb",
  },

  sectionTitle: {
    fontSize: 18,
    fontWeight: "800",
    color: "#111",
    marginBottom: 8,
  },

  scoreHeroTitle: {
    fontSize: 18,
    fontWeight: "800",
    color: "#111",
  },

  scoreHeroValue: {
    fontSize: 52,
    lineHeight: 58,
    fontWeight: "900",
    marginTop: 8,
  },

  scoreHeroHint: {
    color: "#666",
    marginTop: 2,
    fontSize: 15,
    lineHeight: 22,
  },

  rowBetweenTop: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "flex-start",
  },

  metricsRow: {
    flexDirection: "row",
    gap: 10,
    marginTop: 14,
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

  metricValueSmall: {
    fontSize: 16,
    fontWeight: "800",
    color: "#111",
    lineHeight: 22,
  },

  scoreUpdatedText: {
    color: "#666",
    marginTop: 10,
    fontSize: 13,
    fontWeight: "600",
  },

  scoreBadge: {
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 6,
  },

  scoreBadgeText: {
    fontWeight: "800",
    fontSize: 12,
  },

  infoText: {
    color: "#4D4D4D",
    lineHeight: 21,
    fontSize: 14,
  },

  emptyText: {
    color: "#666",
    marginTop: 4,
  },

  activityRow: {
    flexDirection: "row",
    gap: 12,
    paddingVertical: 12,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#E5E7EB",
  },

  activityLeft: {
    width: 60,
    alignItems: "flex-start",
  },

  activityRight: {
    flex: 1,
  },

  activityDelta: {
    fontSize: 18,
    fontWeight: "900",
  },

  activityTitle: {
    fontSize: 15,
    fontWeight: "800",
    color: "#111",
  },

  activitySubtitle: {
    marginTop: 2,
    fontSize: 14,
    color: "#555",
    lineHeight: 20,
  },

  activityDate: {
    marginTop: 4,
    fontSize: 12,
    color: "#777",
    fontWeight: "600",
  },
});
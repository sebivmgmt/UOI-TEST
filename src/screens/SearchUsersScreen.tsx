import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  View,
  Text,
  TextInput,
  StyleSheet,
  TouchableOpacity,
  ActivityIndicator,
  FlatList,
  Alert,
  Keyboard,
} from "react-native";
import { useFocusEffect } from "@react-navigation/native";
import { supabase } from "../supabase";
import SebivAvatar from "../components/SebivAvatar";
import { useAppTheme, AppTheme } from "../theme";
import { getPublicIouScoresV22 } from "../services/iouScoreV22";

type UserResult = {
  id: string;
  iou_hash?: string | null;
  public_name: string | null;
  public_score?: number | null;
  avatar_url?: string | null;
};

type RecentContact = {
  id: string;
  public_name: string | null;
  public_score?: number | null;
  avatar_url?: string | null;
  lastIouDate: string;
};


export default function SearchUsersScreen({ navigation }: any) {
  const theme = useAppTheme();
  const s = useMemo(() => makeS(theme), [theme]);

  const [userId, setUserId] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [searching, setSearching] = useState(false);
  const [results, setResults] = useState<UserResult[]>([]);
  const [recentContacts, setRecentContacts] = useState<RecentContact[]>([]);
  const [loadingRecent, setLoadingRecent] = useState(false);
  const [hasSearched, setHasSearched] = useState(false);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      setUserId(data.user?.id ?? null);
    });
  }, []);

  const loadRecentContacts = useCallback(async () => {
    if (!userId) return;
    setLoadingRecent(true);
    try {
      const { data: iouData } = await supabase
        .from("ious")
        .select("lender_id, borrower_id, created_at")
        .or(`lender_id.eq.${userId},borrower_id.eq.${userId}`)
        .is("deleted_at", null)
        .order("created_at", { ascending: false })
        .limit(30);

      if (!iouData || iouData.length === 0) {
        setRecentContacts([]);
        return;
      }

      const counterpartyMap = new Map<string, string>();
      for (const row of iouData as any[]) {
        const otherId = row.lender_id === userId ? row.borrower_id : row.lender_id;
        if (otherId && !counterpartyMap.has(otherId)) {
          counterpartyMap.set(otherId, row.created_at);
        }
      }

      const ids = Array.from(counterpartyMap.keys());
      if (ids.length === 0) {
        setRecentContacts([]);
        return;
      }

      const { data: profileData } = await supabase
        .from("profile_directory")
        .select("id, iou_hash, public_name, avatar_url")
        .in("id", ids);

      const scoreMap = await getPublicIouScoresV22(ids);

      const contacts: RecentContact[] = (profileData ?? []).map((p: any) => ({
        id: p.id,
        public_name: p.public_name ?? null,
        public_score: scoreMap.get(p.id)?.public_score ?? null,
        avatar_url: p.avatar_url ?? null,
        lastIouDate: counterpartyMap.get(p.id) ?? "",
      }));

      contacts.sort((a, b) => b.lastIouDate.localeCompare(a.lastIouDate));
      setRecentContacts(contacts);
    } catch {
      // silent
    } finally {
      setLoadingRecent(false);
    }
  }, [userId]);

  useFocusEffect(
    useCallback(() => {
      void loadRecentContacts();
    }, [loadRecentContacts])
  );

  const runSearch = useCallback(async () => {
    const q = query.trim();
    if (!q) return;
    Keyboard.dismiss();
    setSearching(true);
    setHasSearched(true);
    try {
      const { data, error } = await supabase.functions.invoke("search-counterparty", {
        body: { query: q },
      });
      if (error) throw error;
      const mapped: UserResult[] = ((data?.results ?? []) as any[]).map((r) => ({
        id: r.id,
        iou_hash: r.iou_hash ?? null,
        public_name: (r.display_name || r.full_name || null) as string | null,
        public_score: typeof r.public_score === "number" ? r.public_score : null,
        avatar_url: r.avatar_url ?? null,
      }));
      setResults(mapped);
    } catch (e: any) {
      Alert.alert("Search failed", e?.message ?? String(e));
    } finally {
      setSearching(false);
    }
  }, [query]);

  const openPerson = (id: string) => {
    navigation.navigate("Person", { personId: id });
  };

  const renderContactCard = (
    id: string,
    name: string | null,
    score: number | null | undefined,
    actionLabel: string,
    avatarUrl?: string | null
  ) => {
    const displayName = name || "Unknown";
    return (
      <TouchableOpacity
        key={id}
        style={s.contactCard}
        activeOpacity={0.88}
        onPress={() => openPerson(id)}
      >
        <SebivAvatar uri={avatarUrl} size={44} />
        <View style={{ flex: 1 }}>
          <Text style={s.contactName}>{displayName}</Text>
          {typeof score === "number" && (
            <Text style={s.scoreText}>IOU Score {Math.round(score)}</Text>
          )}
        </View>
        <TouchableOpacity
          style={s.actionBtn}
          onPress={() =>
            navigation.navigate("NewIouScreen", {
              initialRole: "lend",
              presetCounterpartyId: id,
              presetCounterpartyName: displayName,
            })
          }
          hitSlop={8}
        >
          <Text style={s.actionBtnText}>{actionLabel}</Text>
        </TouchableOpacity>
      </TouchableOpacity>
    );
  };

  const showSearchResults = hasSearched || results.length > 0;

  type ListSection =
    | { kind: "search-header" }
    | { kind: "search-result"; item: UserResult }
    | { kind: "search-empty" }
    | { kind: "recent-header" }
    | { kind: "recent-item"; item: RecentContact }
    | { kind: "recent-empty" };

  const listData: ListSection[] = [];

  if (showSearchResults) {
    listData.push({ kind: "search-header" });
    if (results.length > 0) {
      results.forEach((r) => listData.push({ kind: "search-result", item: r }));
    } else {
      listData.push({ kind: "search-empty" });
    }
  }

  if (!showSearchResults || recentContacts.length > 0) {
    listData.push({ kind: "recent-header" });
    if (recentContacts.length > 0) {
      recentContacts.forEach((r) => listData.push({ kind: "recent-item", item: r }));
    } else if (!loadingRecent) {
      listData.push({ kind: "recent-empty" });
    }
  }

  return (
    <View style={s.screen}>
      {/* Search bar */}
      <View style={s.searchWrap}>
        <TextInput
          style={s.input}
          value={query}
          onChangeText={(t) => {
            setQuery(t);
            if (!t.trim()) { setResults([]); setHasSearched(false); }
          }}
          placeholder="Search by name, email, or phone"
          placeholderTextColor={theme.textMuted}
          autoCapitalize="none"
          autoCorrect={false}
          returnKeyType="search"
          onSubmitEditing={runSearch}
        />
        <TouchableOpacity
          style={[s.searchBtn, searching && { opacity: 0.7 }]}
          onPress={runSearch}
          disabled={searching}
          activeOpacity={0.9}
        >
          {searching ? (
            <ActivityIndicator color="#fff" size="small" />
          ) : (
            <Text style={s.searchBtnText}>Search</Text>
          )}
        </TouchableOpacity>
      </View>

      <FlatList
        data={listData}
        keyExtractor={(item, i) => {
          if (item.kind === "search-result") return `sr-${item.item.id}`;
          if (item.kind === "recent-item") return `rc-${item.item.id}`;
          return `${item.kind}-${i}`;
        }}
        contentContainerStyle={s.listContent}
        showsVerticalScrollIndicator={false}
        renderItem={({ item }) => {
          if (item.kind === "search-header") {
            return <Text style={s.sectionHeader}>Results</Text>;
          }
          if (item.kind === "search-result") {
            const r = item.item;
            return renderContactCard(r.id, r.public_name, r.public_score, "New IOU", r.avatar_url);
          }
          if (item.kind === "search-empty") {
            return (
              <View style={s.emptyBox}>
                <Text style={s.emptyTitle}>No users found</Text>
                <Text style={s.emptyText}>Try their email, phone, or display name.</Text>
              </View>
            );
          }
          if (item.kind === "recent-header") {
            return <Text style={s.sectionHeader}>Recent</Text>;
          }
          if (item.kind === "recent-item") {
            const r = item.item;
            return renderContactCard(r.id, r.public_name, r.public_score, "New IOU", r.avatar_url);
          }
          if (item.kind === "recent-empty") {
            return (
              <View style={s.emptyBox}>
                <Text style={s.emptyTitle}>No contacts yet</Text>
                <Text style={s.emptyText}>
                  Your friends will appear here after you create or receive IOUs.
                </Text>
                <TouchableOpacity
                  style={s.findBtn}
                  onPress={runSearch}
                  activeOpacity={0.85}
                >
                  <Text style={s.findBtnText}>Find someone</Text>
                </TouchableOpacity>
              </View>
            );
          }
          return null;
        }}
        ListHeaderComponent={<View style={{ height: 4 }} />}
      />
    </View>
  );
}

function makeS(t: AppTheme) {
  return StyleSheet.create({
    screen: { flex: 1, backgroundColor: t.background },
    searchWrap: {
      flexDirection: "row",
      gap: 8,
      marginHorizontal: 16,
      marginTop: 14,
      marginBottom: 4,
      alignItems: "center",
    },
    input: {
      flex: 1,
      borderWidth: 1,
      borderColor: t.border,
      borderRadius: 12,
      paddingHorizontal: 14,
      paddingVertical: 11,
      fontSize: 15,
      backgroundColor: t.surface,
      color: t.textPrimary,
    },
    searchBtn: {
      backgroundColor: t.brand,
      borderRadius: 12,
      paddingHorizontal: 16,
      paddingVertical: 11,
      alignItems: "center",
      justifyContent: "center",
      minWidth: 72,
    },
    searchBtnText: { color: "#fff", fontWeight: "900", fontSize: 14 },
    listContent: { paddingHorizontal: 16, paddingBottom: 60 },
    sectionHeader: {
      fontSize: 12,
      fontWeight: "800",
      color: t.textMuted,
      textTransform: "uppercase",
      letterSpacing: 0.5,
      paddingTop: 18,
      paddingBottom: 8,
      paddingHorizontal: 2,
    },
    contactCard: {
      flexDirection: "row",
      alignItems: "center",
      gap: 12,
      backgroundColor: t.surface,
      borderRadius: 14,
      padding: 14,
      marginBottom: 8,
      borderWidth: 1,
      borderColor: t.border,
    },
    contactName: { fontSize: 15, fontWeight: "800", color: t.textPrimary },
    scoreText: { marginTop: 4, color: t.positive, fontSize: 12, fontWeight: "800" },
    actionBtn: {
      backgroundColor: t.positiveSurface,
      borderRadius: 8,
      paddingHorizontal: 12,
      paddingVertical: 7,
      borderWidth: 1,
      borderColor: t.positiveBorder,
    },
    actionBtnText: { color: t.isDark ? t.brandBright : t.brand, fontWeight: "800", fontSize: 13 },
    emptyBox: {
      alignItems: "center",
      paddingVertical: 24,
      paddingHorizontal: 16,
    },
    emptyTitle: { fontSize: 16, fontWeight: "900", color: t.textSecondary, marginBottom: 6 },
    emptyText: {
      textAlign: "center",
      color: t.textMuted,
      lineHeight: 20,
      fontWeight: "600",
      fontSize: 14,
    },
    findBtn: {
      marginTop: 14,
      backgroundColor: t.brand,
      borderRadius: 12,
      paddingHorizontal: 20,
      paddingVertical: 11,
    },
    findBtnText: { color: "#fff", fontWeight: "900", fontSize: 14 },
  });
}

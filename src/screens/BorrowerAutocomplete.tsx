// src/components/BorrowerAutocomplete.tsx
import React, { useEffect, useMemo, useRef, useState } from "react";
import { View, TextInput, FlatList, TouchableOpacity, Text, ActivityIndicator, StyleSheet } from "react-native";
import { supabase } from "../supabase";

export type ProfileLite = {
  id: string;
  iou_hash?: string | null;
  public_name: string | null;
  avatar_url?: string | null;
  iou_score?: number | null;
};

type Props = {
  placeholder?: string;
  value: ProfileLite | null;
  onChange: (p: ProfileLite | null) => void;
  onInvite?: () => void;
  initialQuery?: string;
};

export default function BorrowerAutocomplete({
  placeholder = "Search by name, IOU handle, or email",
  value,
  onChange,
  onInvite,
  initialQuery = "",
}: Props) {
  const [q, setQ] = useState(initialQuery);
  const [loading, setLoading] = useState(false);
  const [results, setResults] = useState<ProfileLite[]>([]);
  const [open, setOpen] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const runSearch = async (term: string) => {
    const t = term.trim();
    if (!t) { setResults([]); return; }
    setLoading(true);

    try {
      const { data, error } = await supabase.functions.invoke("search-counterparty", {
        body: { query: t },
      });
      if (!error && data?.results) {
        const mapped: ProfileLite[] = (data.results as any[]).map((r) => ({
          id: r.id,
          iou_hash: r.iou_hash ?? null,
          public_name: (r.display_name || r.full_name || null) as string | null,
          avatar_url: r.avatar_url ?? null,
          iou_score: typeof r.iou_score === "number" ? r.iou_score : null,
        }));
        setResults(mapped);
      }
    } finally {
      setLoading(false);
    }
  };

  // debounce typing (250ms)
  useEffect(() => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => runSearch(q), 250);
    return () => { if (timer.current) clearTimeout(timer.current); };
  }, [q]);

  const showInvite = useMemo(() => !loading && results.length === 0 && q.trim().length > 2, [loading, results, q]);

  if (value) {
    return (
      <View style={styles.selectedCard}>
        <View style={{ flex: 1 }}>
          <Text style={{ fontWeight: "800" }}>{value.public_name || "Unnamed"}</Text>
          <Text style={{ color: "#666" }}>{value.iou_hash || value.id}</Text>
        </View>
        <TouchableOpacity onPress={() => onChange(null)}>
          <Text style={{ color: "#d00", fontWeight: "800" }}>Clear</Text>
        </TouchableOpacity>
      </View>
    );
  }

  return (
    <View>
      <TextInput
        placeholder={placeholder}
        value={q}
        onChangeText={(t) => { setQ(t); setOpen(true); }}
        autoCapitalize="none"
        style={styles.input}
      />

      {open && (
        <View style={styles.dropdown}>
          {loading ? (
            <View style={styles.loadingRow}><ActivityIndicator /></View>
          ) : results.length > 0 ? (
            <FlatList
              keyboardShouldPersistTaps="handled"
              data={results}
              keyExtractor={(r) => r.id}
              ItemSeparatorComponent={() => <View style={{ height: StyleSheet.hairlineWidth, backgroundColor: "#eee" }} />}
              renderItem={({ item }) => (
                <TouchableOpacity style={styles.row} onPress={() => { onChange(item); setOpen(false); }}>
                  <View style={{ flex: 1 }}>
                    <Text style={{ fontWeight: "700" }}>{item.public_name || "Unnamed"}</Text>
                    <Text style={{ color: "#666" }}>{item.iou_hash || item.id}</Text>
                  </View>
                </TouchableOpacity>
              )}
            />
          ) : showInvite ? (
            <TouchableOpacity style={styles.inviteRow} onPress={onInvite}>
              <Text style={{ color: "#1555d6", fontWeight: "800" }}>Invite “{q.trim()}”</Text>
            </TouchableOpacity>
          ) : null}
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  input: {
    borderWidth: 1, borderColor: "#ddd", borderRadius: 10, paddingHorizontal: 14, paddingVertical: 12, fontSize: 16, backgroundColor: "#fff",
  },
  dropdown: {
    marginTop: 6, borderWidth: 1, borderColor: "#e5e7eb", backgroundColor: "#fff", borderRadius: 10, maxHeight: 220, overflow: "hidden",
  },
  row: { paddingHorizontal: 12, paddingVertical: 10, flexDirection: "row", alignItems: "center" },
  loadingRow: { padding: 12, alignItems: "center", justifyContent: "center" },
  inviteRow: { padding: 12, alignItems: "center", justifyContent: "center" },
  selectedCard: {
    marginTop: 8, borderWidth: 1, borderColor: "#cbd5e1", backgroundColor: "#f8fafc",
    borderRadius: 10, padding: 12, flexDirection: "row", alignItems: "center", gap: 12,
  },
});
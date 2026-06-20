// src/screens/Archived.tsx
import React, { useEffect, useState, useCallback } from "react";
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  ActivityIndicator,
  Alert,
  StyleSheet,
} from "react-native";
import { supabase } from "../supabase";
import {
  unarchiveLoan,
  deleteLoanSoft,
  restoreLoan,
} from "../utils/iouActions";

type IouRow = {
  id: string;
  title: string | null;
  principal_cents: number;
  status: string | null;
  archived_at: string | null;
  deleted_at: string | null;
  is_archived: boolean | null;
};

const GREEN = "#77B777";
const RED = "#D9534F";
const BLUE = "#3B82F6";
const currency = (c: number) => `$${(c / 100).toFixed(2)}`;

export default function Archived({ navigation }: any) {
  const [rows, setRows] = useState<IouRow[]>([]);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const { data, error } = await supabase
        .from("ious")
        .select(
          "id, title, principal_cents, status, archived_at, deleted_at, is_archived"
        )
        // anything archived OR soft-deleted
        .or("archived_at.not.is.null,deleted_at.not.is.null,is_archived.eq.true")
        .order("archived_at", { ascending: false, nullsFirst: false })
        .limit(200);

      if (error) throw error;
      setRows((data ?? []) as IouRow[]);
    } catch (e: any) {
      console.warn("Archived load failed:", e.message ?? e);
      Alert.alert("Error", "Could not load archived loans.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  // Realtime: refresh whenever an IOU changes (archive / delete / restore)
  useEffect(() => {
    const channel = supabase
      .channel("archived-list")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "ious" },
        () => {
          // light refresh; ignore loading spinner here
          load();
        }
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, [load]);

  const handleUnarchive = async (id: string) => {
    try {
      await unarchiveLoan(id);
      load();
    } catch (e: any) {
      Alert.alert("Unarchive failed", e.message ?? String(e));
    }
  };

  const handleRestore = async (id: string) => {
    try {
      await restoreLoan(id);
      load();
    } catch (e: any) {
      Alert.alert("Restore failed", e.message ?? String(e));
    }
  };

  const handleDelete = async (id: string) => {
    try {
      // deleteLoanSoft already has its own confirm dialog
      const res = await deleteLoanSoft(id);
      if (res) load();
    } catch (e: any) {
      Alert.alert("Delete failed", e.message ?? String(e));
    }
  };

  const renderItem = ({ item }: { item: IouRow }) => {
    const isDeleted = !!item.deleted_at;
    const isArchived = !!item.archived_at || !!item.is_archived;

    let stateLabel = "ARCHIVED";
    if (isDeleted) stateLabel = "DELETED";

    return (
      <TouchableOpacity
        activeOpacity={0.85}
        onPress={() => navigation.navigate("LoanDetail", { iou_id: item.id })}
        style={s.card}
      >
        <View style={{ flex: 1 }}>
          <Text style={s.title}>{item.title || "Loan"}</Text>
          <Text style={s.subtitle}>
            {currency(item.principal_cents)} ·{" "}
            {(item.status || "paid").toUpperCase()}
          </Text>
          <Text
            style={[
              s.state,
              isDeleted ? { color: RED } : { color: "#92400e" },
            ]}
          >
            {stateLabel}
          </Text>
        </View>

        <View style={s.actions}>
          {isDeleted ? (
            <>
              <TouchableOpacity
                style={[s.btn, s.btnBlue]}
                onPress={() => handleRestore(item.id)}
              >
                <Text style={s.btnTxt}>Restore</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[s.btn, s.btnRed]}
                onPress={() => handleDelete(item.id)}
              >
                <Text style={s.btnTxt}>Delete</Text>
              </TouchableOpacity>
            </>
          ) : (
            <>
              <TouchableOpacity
                style={[s.btn, s.btnBlue]}
                onPress={() => handleUnarchive(item.id)}
              >
                <Text style={s.btnTxt}>Unarchive</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[s.btn, s.btnRed]}
                onPress={() => handleDelete(item.id)}
              >
                <Text style={s.btnTxt}>Delete</Text>
              </TouchableOpacity>
            </>
          )}
        </View>
      </TouchableOpacity>
    );
  };

  if (loading) {
    return (
      <View style={s.center}>
        <ActivityIndicator size="large" color={GREEN} />
      </View>
    );
  }

  return (
    <FlatList
      data={rows}
      keyExtractor={(r) => r.id}
      renderItem={renderItem}
      contentContainerStyle={{ padding: 12, paddingBottom: 32 }}
      ListEmptyComponent={
        <View style={{ padding: 24, alignItems: "center" }}>
          <Text style={{ color: "#777" }}>No archived loans found.</Text>
        </View>
      }
    />
  );
}

const s = StyleSheet.create({
  center: { flex: 1, alignItems: "center", justifyContent: "center" },
  card: {
    flexDirection: "row",
    alignItems: "center",
    padding: 14,
    marginBottom: 12,
    backgroundColor: "#fff",
    borderWidth: 1,
    borderColor: "#eee",
    borderRadius: 10,
  },
  title: { fontSize: 18, fontWeight: "700", color: "#111" },
  subtitle: { marginTop: 4, color: "#555" },
  state: { marginTop: 4, fontWeight: "800", fontSize: 12 },
  actions: {
    marginLeft: 12,
    justifyContent: "center",
    alignItems: "flex-end",
    gap: 6,
  },
  btn: {
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 8,
  },
  btnTxt: { color: "#fff", fontWeight: "800", fontSize: 12 },
  btnBlue: { backgroundColor: BLUE },
  btnRed: { backgroundColor: RED },
});
// src/screens/Profile.tsx
import React, { useEffect, useState, useCallback, useMemo } from "react";
import {
  View,
  Text,
  TextInput,
  StyleSheet,
  TouchableOpacity,
  ActivityIndicator,
  Alert,
  ScrollView,
} from "react-native";
import { supabase } from "../supabase";
import { useColorSchemeCtx, useAppTheme, AppTheme, Preference } from "../theme";

const RED = "#D9534F";
const BLUE = "#3B82F6";

type ProfileRow = {
  id: string;
  iou_hash: string | null;
  display_name: string | null;
  name: string | null;
  photo_url: string | null;
  full_name: string | null;
  email: string | null;
  phone: string | null;
  phone_verified: boolean | null;
  identity_status?: string | null;
  identity_verified_at?: string | null;
  dwolla_customer_id?: string | null;
  dwolla_customer_status?: string | null;
  ach_status?: string | null;
  bank_provider?: string | null;
};

export default function Profile({ navigation }: any) {
  const theme = useAppTheme();
  const s = useMemo(() => makeS(theme), [theme]);
  const { preference, setPreference } = useColorSchemeCtx();
  const [meId, setMeId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [row, setRow] = useState<ProfileRow | null>(null);
  const [fullName, setFullName] = useState<string>("");
  const [devPaymentId, setDevPaymentId] = useState<string>("");
  const [devScoreTestRunning, setDevScoreTestRunning] = useState(false);
  const [devScoreTestResult, setDevScoreTestResult] = useState<string | null>(null);
  const [devFixtureLoading, setDevFixtureLoading] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);

    const me = (await supabase.auth.getUser()).data.user;
    setMeId(me?.id ?? null);

    if (!me?.id) {
      setLoading(false);
      return;
    }

    const profileRes = await supabase
      .from("profiles")
      .select(
        "id, iou_hash, display_name, name, photo_url, full_name, email, phone, phone_verified, identity_status, identity_verified_at, dwolla_customer_id, dwolla_customer_status, ach_status, bank_provider"
      )
      .eq("id", me.id)
      .single();

    if (profileRes.error) {
      Alert.alert("Profile load failed", profileRes.error.message);
      setLoading(false);
      return;
    }

    const data: any = profileRes.data;

    const merged: ProfileRow = {
      id: data.id,
      iou_hash: data.iou_hash ?? null,
      display_name: data.display_name ?? null,
      name: data.name ?? null,
      photo_url: data.photo_url ?? null,
      full_name: data.full_name ?? data.display_name ?? data.name ?? null,
      email: data.email ?? me.email ?? null,
      phone: data.phone ?? null,
      phone_verified: data.phone_verified ?? false,
      identity_status: data.identity_status ?? null,
      identity_verified_at: data.identity_verified_at ?? null,
      dwolla_customer_id: data.dwolla_customer_id ?? null,
      dwolla_customer_status: data.dwolla_customer_status ?? null,
      ach_status: data.ach_status ?? null,
      bank_provider: data.bank_provider ?? null,
    };

    setRow(merged);
    setFullName(merged.full_name ?? "");
    setLoading(false);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function save() {
    if (!meId) return;

    setSaving(true);

    const trimmedName = fullName.trim() || null;

    const { error } = await supabase
      .from("profiles")
      .update({
        full_name: trimmedName,
        display_name: trimmedName,
        name: trimmedName,
      })
      .eq("id", meId);

    setSaving(false);

    if (error) {
      return Alert.alert("Save failed", error.message);
    }

    Alert.alert("Saved", "Profile updated.");
    void load();
  }

  async function sendPasswordReset() {
    const me = (await supabase.auth.getUser()).data.user;
    if (!me?.email) return Alert.alert("No email on file");

    const { error } = await supabase.auth.resetPasswordForEmail(me.email);
    if (error) return Alert.alert("Reset failed", error.message);

    Alert.alert("Email sent", "Check your inbox for password reset.");
  }

  async function signOut() {
    await supabase.auth.signOut();
  }

  // TODO: Remove this dev-only Score v2 outcome test tool before production release.
  async function runDevScoreOutcomeTest() {
    const trimmed = devPaymentId.trim();
    if (!trimmed) {
      Alert.alert("Missing payment ID", "Paste a payment UUID to test.");
      return;
    }
    // TODO remove before production
    setDevScoreTestRunning(true);
    setDevScoreTestResult(null);
    try {
      const { data, error } = await supabase.rpc(
        "log_payment_score_outcome_shadow",
        { p_payment_id: trimmed, p_actor_id: null }
      );

      // Always log the raw RPC envelope for debugging
      console.log("[DEV] log_payment_score_outcome_shadow rpc response:", { data, error });

      if (error) {
        // Log full error and show to dev
        console.error("[DEV] log_payment_score_outcome_shadow error:", error);
        const errMsg = error?.message ? String(error.message) : JSON.stringify(error);
        setDevScoreTestResult("ERROR: " + errMsg);
        Alert.alert("Dev: RPC error", errMsg || "(no message)");
        return;
      }

      // supabase.rpc may return the payload directly or an array - normalize it
      let result: any = data ?? null;
      if (Array.isArray(result) && result.length === 1) result = result[0];

      // Ensure developer can always see a clear, human-friendly message
      const resultStr = result ? JSON.stringify(result, null, 2) : "(null response)";
      console.log("[DEV] log_payment_score_outcome_shadow result:", result);
      setDevScoreTestResult(resultStr);

      const recorded = result?.recorded === true;
      const reason = typeof result?.reason === "string" ? result.reason : null;

      if (recorded) {
        Alert.alert("Dev: Outcome recorded ✓", resultStr);
      } else if (reason === "payment_outcome_already_logged") {
        // Explicit, clear message for the common idempotency case
        const message = `Not recorded — payment_outcome_already_logged\n\n${resultStr}`;
        Alert.alert("Dev: Outcome not recorded", message);
      } else {
        // Generic not-recorded case (still visible to developer)
        const title = "Dev: Outcome not recorded";
        const message = reason ? `reason: ${reason}\n\n${resultStr}` : resultStr;
        Alert.alert(title, message);
      }
    } catch (e: any) {
      // Catch unexpected exceptions, log full error object
      console.error("[DEV] log_payment_score_outcome_shadow exception:", e);
      const errMsg = "ERROR: " + (e?.message ?? String(e));
      setDevScoreTestResult(errMsg);
      Alert.alert("Dev: RPC exception", errMsg);
    } finally {
      setDevScoreTestRunning(false);
    }
  }

  async function runDevFixture() {
    setDevFixtureLoading(true);
    try {
      const { data, error } = await supabase.functions.invoke("dev-set-financial-ready", {});
      if (error) {
        let fnStatus: number | null = null;
        let fnStage: string | null = null;
        let fnError: string | null = null;
        let fnAchStatus: string | null = null;
        let fnBankProvider: string | null = null;
        try {
          const ctx = (error as any)?.context as Response | undefined;
          fnStatus = ctx?.status ?? null;
          if (typeof ctx?.json === "function") {
            const body = await ctx.json();
            fnStage = body?.stage ?? null;
            fnError = typeof body?.error === "string" ? body.error : null;
            fnAchStatus = body?.ach_status ?? null;
            fnBankProvider = body?.bank_provider ?? null;
          } else if (typeof ctx?.text === "function") {
            const raw = await ctx.text();
            try {
              const parsed = JSON.parse(raw);
              fnStage = parsed?.stage ?? null;
              fnError = typeof parsed?.error === "string" ? parsed.error : null;
              fnAchStatus = parsed?.ach_status ?? null;
              fnBankProvider = parsed?.bank_provider ?? null;
            } catch {}
          }
        } catch {}
        if (__DEV__) {
          console.log("[Profile] runDevFixture error", {
            user_id_suffix: meId?.slice(-6) ?? null,
            status: fnStatus,
            ok: false,
            stage: fnStage,
            error: fnError ?? error.message,
            ach_status: fnAchStatus,
            bank_provider: fnBankProvider,
          });
        }
        Alert.alert("Fixture failed", fnError ?? error.message);
        return;
      }
      const d = data as any;
      if (__DEV__) {
        console.log("[Profile] runDevFixture response", {
          user_id_suffix: meId?.slice(-6) ?? null,
          status: 200,
          ok: d?.ok ?? null,
          stage: d?.stage ?? null,
          error: d?.error ?? null,
          ach_status: d?.ach_status ?? null,
          bank_provider: d?.bank_provider ?? null,
        });
      }
      if (!d?.ok || d?.ach_status !== "ready" || d?.bank_provider !== "dev_fixture") {
        Alert.alert("Fixture failed", d?.error ?? "Server did not confirm fixture. Check logs.");
        return;
      }
      Alert.alert("Fixture applied", "Profile marked financially ready (DEV fixture).");
      void load();
    } finally {
      setDevFixtureLoading(false);
    }
  }

  const normalizedIdentityStatus = useMemo(() => {
    const raw = (row?.identity_status || row?.dwolla_customer_status || "")
      .toString()
      .trim()
      .toLowerCase();

    if (
      raw === "verified" ||
      raw === "approved" ||
      raw === "active" ||
      raw === "identity_verified"
    ) {
      return "verified";
    }

    if (
      raw === "retry" ||
      raw === "document" ||
      raw === "documents_needed" ||
      raw === "document_needed" ||
      raw === "suspended" ||
      raw === "flagged"
    ) {
      return "action_needed";
    }

    if (
      raw === "pending" ||
      raw === "review" ||
      raw === "in_review" ||
      raw === "received"
    ) {
      return "pending";
    }

    return "unverified";
  }, [row]);

  const identityStatusUi = useMemo(() => {
    if (normalizedIdentityStatus === "verified") {
      return {
        label: "Identity Verified",
        shortLabel: "Verified",
        bg: theme.positiveSurface,
        color: theme.positive,
        description:
          "Your identity is verified and ready for compliant money movement.",
      };
    }

    if (normalizedIdentityStatus === "pending") {
      return {
        label: "Identity Pending",
        shortLabel: "Pending",
        bg: theme.warningSurface,
        color: theme.warning,
        description:
          "Your identity has been submitted and is waiting on review.",
      };
    }

    if (normalizedIdentityStatus === "action_needed") {
      return {
        label: "Identity Needs Action",
        shortLabel: "Needs action",
        bg: theme.negativeSurface,
        color: theme.negative,
        description:
          "More information may be needed before money movement can go live.",
      };
    }

    return {
      label: "Identity Unverified",
      shortLabel: "Unverified",
      bg: theme.negativeSurface,
      color: theme.negative,
      description:
        "Verify your identity before enabling live ACH and compliance flows.",
    };
  }, [normalizedIdentityStatus, theme]);

  const completionChecks = useMemo(() => {
    const items = [
      { label: "Full name added", done: !!(fullName.trim() || row?.full_name) },
      { label: "Email on file", done: !!row?.email },
      { label: "Phone added", done: !!row?.phone },
      { label: "Phone verified", done: !!row?.phone_verified },
      {
        label: "Identity verified",
        done: normalizedIdentityStatus === "verified",
      },
    ];

    const completed = items.filter((i) => i.done).length;
    const percent = Math.round((completed / items.length) * 100);

    return { items, completed, total: items.length, percent };
  }, [fullName, row, normalizedIdentityStatus]);

  const identityUpdatedLabel = useMemo(() => {
    if (!row?.identity_verified_at) return null;
    const date = new Date(row.identity_verified_at);
    if (Number.isNaN(date.getTime())) return null;
    return date.toLocaleString();
  }, [row]);

  if (loading) {
    return (
      <View style={s.center}>
        <ActivityIndicator color={theme.textMuted} />
      </View>
    );
  }

  if (!row) {
    return (
      <View style={s.center}>
        <Text style={{ color: theme.textSecondary }}>Not signed in.</Text>
      </View>
    );
  }

  return (
    <ScrollView
      style={s.screen}
      contentContainerStyle={s.content}
      showsVerticalScrollIndicator={false}
    >
      {/* Account hero */}
      <View style={s.heroCard}>
        <Text style={s.eyebrow}>Your account</Text>
        <Text style={s.h1}>{row.full_name || "Profile"}</Text>
        <Text style={s.heroSub}>{row.email ?? "No email on file"}</Text>

        {!!row.iou_hash && <Text style={s.iouHashText}>{row.iou_hash}</Text>}

        <View style={s.heroStatusRow}>
          <View
            style={[
              s.statusPill,
              { backgroundColor: row.phone_verified ? theme.positiveSurface : theme.negativeSurface },
            ]}
          >
            <Text
              style={[
                s.statusPillText,
                { color: row.phone_verified ? theme.positive : theme.negative },
              ]}
            >
              {row.phone_verified ? "Phone Verified" : "Phone Unverified"}
            </Text>
          </View>

          <View style={[s.statusPill, { backgroundColor: identityStatusUi.bg }]}>
            <Text style={[s.statusPillText, { color: identityStatusUi.color }]}>
              {identityStatusUi.label}
            </Text>
          </View>

          <View style={[s.statusPill, { backgroundColor: theme.infoSurface }]}>
            <Text style={[s.statusPillText, { color: theme.info }]}>
              {completionChecks.percent}% complete
            </Text>
          </View>
        </View>
      </View>

      {/* Profile details */}
      <View style={s.card}>
        <Text style={s.sectionTitle}>Profile details</Text>

        <Text style={s.label}>Full name</Text>
        <TextInput
          style={s.input}
          value={fullName}
          onChangeText={setFullName}
          placeholder="Your name"
          placeholderTextColor={theme.textMuted}
        />

        <Text style={s.label}>Email</Text>
        <Text style={s.value}>{row.email ?? "—"}</Text>

        <Text style={s.label}>Phone</Text>
        <View style={s.rowBetween}>
          <Text style={s.value}>{row.phone ?? "Not set"}</Text>
          <Text style={{ fontWeight: "800", color: row.phone_verified ? theme.positive : theme.negative }}>
            {row.phone_verified ? "Verified" : "Unverified"}
          </Text>
        </View>

        <TouchableOpacity
          style={[s.btn, { backgroundColor: BLUE }]}
          onPress={() => navigation.navigate("VerifyPhone")}
        >
          <Text style={s.btnTxt}>
            {row.phone_verified ? "Change phone" : "Verify phone"}
          </Text>
        </TouchableOpacity>

        <Text style={s.label}>Identity verification</Text>
        <View style={s.rowBetween}>
          <Text style={s.value}>{identityStatusUi.shortLabel}</Text>
          <Text style={{ fontWeight: "800", color: identityStatusUi.color }}>
            {identityStatusUi.shortLabel}
          </Text>
        </View>

        <Text style={s.helperText}>{identityStatusUi.description}</Text>

        {!!row.dwolla_customer_id && (
          <Text style={s.metaText}>Dwolla customer connected</Text>
        )}

        {!!identityUpdatedLabel && (
          <Text style={s.metaText}>Verified {identityUpdatedLabel}</Text>
        )}

        <TouchableOpacity
          style={[
            s.btn,
            {
              backgroundColor:
                normalizedIdentityStatus === "verified" ? theme.brand : theme.brandBright,
            },
          ]}
          onPress={() => navigation.navigate("VerifyIdentity")}
        >
          <Text style={s.btnTxt}>
            {normalizedIdentityStatus === "verified"
              ? "View identity details"
              : normalizedIdentityStatus === "pending"
              ? "Continue identity review"
              : normalizedIdentityStatus === "action_needed"
              ? "Fix identity info"
              : "Verify identity"}
          </Text>
        </TouchableOpacity>

        <Text style={s.label}>Bank account</Text>
        <View style={s.rowBetween}>
          <Text style={s.value}>
            {row.ach_status === "ready" ? "Linked" : "Not linked"}
          </Text>
          <View
            style={[
              s.statusPill,
              { backgroundColor: row.ach_status === "ready" ? theme.positiveSurface : theme.negativeSurface },
            ]}
          >
            <Text
              style={[
                s.statusPillText,
                { color: row.ach_status === "ready" ? theme.positive : theme.negative },
              ]}
            >
              {row.ach_status === "ready" ? "Ready" : "Not linked"}
            </Text>
          </View>
        </View>
        {row.bank_provider === "dev_fixture" && (
          <View style={s.fixtureWarning}>
            <Text style={s.fixtureWarningText}>DEV fixture — no real ACH connection</Text>
          </View>
        )}
        <TouchableOpacity
          style={[s.btn, { backgroundColor: BLUE }]}
          onPress={() => navigation.navigate("LinkBank")}
        >
          <Text style={s.btnTxt}>
            {row.ach_status === "ready" ? "Manage bank account" : "Link bank account"}
          </Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={[s.btn, { backgroundColor: theme.brand }]}
          onPress={save}
          disabled={saving}
        >
          <Text style={s.btnTxt}>{saving ? "Saving…" : "Save profile"}</Text>
        </TouchableOpacity>
      </View>

      {/* Profile completeness */}
      <View style={s.card}>
        <View style={s.rowBetween}>
          <Text style={s.sectionTitle}>Profile completeness</Text>
          <Text style={s.percentText}>{completionChecks.percent}%</Text>
        </View>

        <View style={s.progressTrack}>
          <View
            style={[s.progressFill, { width: `${completionChecks.percent}%` }]}
          />
        </View>

        <View style={s.checklist}>
          {completionChecks.items.map((item) => (
            <View key={item.label} style={s.checkRow}>
              <Text style={s.checkIcon}>{item.done ? "✓" : "○"}</Text>
              <Text
                style={[
                  s.checkText,
                  item.done && { color: theme.textPrimary, fontWeight: "700" },
                ]}
              >
                {item.label}
              </Text>
            </View>
          ))}
        </View>
      </View>

      {/* History */}
      <View style={s.card}>
        <Text style={s.sectionTitle}>History</Text>
        <TouchableOpacity
          style={[s.btn, { backgroundColor: "#667085" }]}
          onPress={() => navigation.navigate("Archived")}
        >
          <Text style={s.btnTxt}>View archived IOUs</Text>
        </TouchableOpacity>
      </View>

      {/* Security */}
      <View style={s.card}>
        <Text style={s.sectionTitle}>Security</Text>

        <TouchableOpacity
          style={[s.btn, { backgroundColor: theme.isDark ? "#374151" : "#444" }]}
          onPress={sendPasswordReset}
        >
          <Text style={s.btnTxt}>Email me a password reset link</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={[s.btn, { backgroundColor: RED }]}
          onPress={signOut}
        >
          <Text style={s.btnTxt}>Sign out</Text>
        </TouchableOpacity>
      </View>

      {/* Dev-only section — never shown in production (__DEV__ === false in release builds) */}
      {__DEV__ && (
        <View style={s.devCard}>
          <Text style={s.devCardTitle}>Developer</Text>
          <TouchableOpacity
            style={s.devBtn}
            onPress={() => navigation.navigate("NewIouScreen")}
            activeOpacity={0.8}
          >
            <Text style={s.devBtnText}>Dev: New IOU Guided Flow</Text>
          </TouchableOpacity>

          <View style={s.devDivider} />

          {/* TODO: Remove this dev-only Score v2 outcome test tool before production release. */}
          <Text style={s.devSectionLabel}>Score v2 · Outcome Test</Text>
          <TextInput
            style={s.devInput}
            placeholder="Paste payment UUID…"
            placeholderTextColor="#6B7280"
            value={devPaymentId}
            onChangeText={setDevPaymentId}
            autoCapitalize="none"
            autoCorrect={false}
            spellCheck={false}
          />
          <TouchableOpacity
            style={[s.devBtn, { marginTop: 8, opacity: devScoreTestRunning ? 0.6 : 1 }]}
            onPress={() => { void runDevScoreOutcomeTest(); }}
            disabled={devScoreTestRunning}
            activeOpacity={0.8}
          >
            {devScoreTestRunning
              ? <ActivityIndicator color="#D1D5DB" />
              : <Text style={s.devBtnText}>Dev: Log Payment Outcome</Text>}
          </TouchableOpacity>

          {devScoreTestResult !== null && (
            <View style={s.devResultCard}>
              <Text style={s.devResultText}>{devScoreTestResult}</Text>
            </View>
          )}

          <View style={s.devDivider} />

          <Text style={s.devSectionLabel}>Financial Fixtures</Text>
          <TouchableOpacity
            style={[s.devBtn, { opacity: devFixtureLoading ? 0.6 : 1 }]}
            onPress={() => { void runDevFixture(); }}
            disabled={devFixtureLoading}
            activeOpacity={0.8}
          >
            {devFixtureLoading
              ? <ActivityIndicator color="#D1D5DB" />
              : <Text style={s.devBtnText}>Dev: Mark Financial Ready</Text>}
          </TouchableOpacity>

          {row.bank_provider === "dev_fixture" && (
            <View style={s.devFixtureActive}>
              <Text style={s.devFixtureActiveText}>⚠ DEV fixture active — no real ACH connection</Text>
            </View>
          )}

          <View style={s.devDivider} />

          <Text style={s.devSectionLabel}>Theme Preference</Text>
          <View style={{ flexDirection: 'row', gap: 8, marginTop: 6 }}>
            {(['system', 'light', 'dark'] as Preference[]).map((p) => (
              <TouchableOpacity
                key={p}
                onPress={() => setPreference(p)}
                style={[
                  s.devBtn,
                  { flex: 1 },
                  preference === p && { backgroundColor: '#1B5E20', borderColor: '#2E7D32' },
                ]}
              >
                <Text style={[s.devBtnText, preference === p && { color: '#fff' }]}>
                  {p.toUpperCase()}
                </Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>
      )}
    </ScrollView>
  );
}

function makeS(t: AppTheme) {
  return StyleSheet.create({
    screen: { flex: 1, backgroundColor: t.background },
    content: { padding: 20, paddingBottom: 28 },
    center: { flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: t.background },

    heroCard: {
      backgroundColor: t.surface,
      borderRadius: 16,
      padding: 16,
      marginBottom: 14,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: t.border,
    },

    eyebrow: {
      fontSize: 12,
      fontWeight: "800",
      textTransform: "uppercase",
      color: t.positive,
      marginBottom: 6,
      letterSpacing: 0.4,
    },

    h1: { fontSize: 24, fontWeight: "800", color: t.textPrimary },
    heroSub: { marginTop: 6, color: t.textSecondary, fontSize: 15 },

    iouHashText: {
      marginTop: 8,
      color: t.textMuted,
      fontSize: 13,
      fontWeight: "800",
      letterSpacing: 0.4,
    },

    heroStatusRow: {
      flexDirection: "row",
      flexWrap: "wrap",
      gap: 8,
      marginTop: 14,
    },

    statusPill: { borderRadius: 999, paddingHorizontal: 10, paddingVertical: 6 },
    statusPillText: { fontWeight: "800", fontSize: 12 },

    card: {
      backgroundColor: t.surface,
      borderRadius: 12,
      padding: 14,
      marginBottom: 14,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: t.border,
    },

    sectionTitle: {
      fontSize: 18,
      fontWeight: "800",
      color: t.textPrimary,
      marginBottom: 4,
    },

    label: { fontWeight: "800", color: t.textSecondary, marginTop: 10 },

    input: {
      borderWidth: 1,
      borderColor: t.border,
      borderRadius: 10,
      paddingHorizontal: 12,
      paddingVertical: 10,
      marginTop: 6,
      backgroundColor: t.surfaceMuted,
      color: t.textPrimary,
    },

    value: { marginTop: 6, color: t.textSecondary },

    helperText: { marginTop: 6, color: t.textSecondary, lineHeight: 20 },

    metaText: {
      marginTop: 6,
      color: t.textMuted,
      fontSize: 13,
      fontWeight: "600",
    },

    rowBetween: {
      flexDirection: "row",
      justifyContent: "space-between",
      alignItems: "center",
    },

    btn: {
      marginTop: 12,
      borderRadius: 10,
      paddingVertical: 12,
      alignItems: "center",
    },

    btnTxt: { color: "#fff", fontWeight: "800" },

    percentText: { fontSize: 16, fontWeight: "800", color: t.positive },

    progressTrack: {
      marginTop: 10,
      height: 10,
      borderRadius: 999,
      backgroundColor: t.isDark ? "#1A1A1A" : "#EAEAEA",
      overflow: "hidden",
    },

    progressFill: {
      height: "100%",
      borderRadius: 999,
      backgroundColor: t.positive,
    },

    checklist: { marginTop: 14, gap: 10 },
    checkRow: { flexDirection: "row", alignItems: "center" },
    checkIcon: { width: 22, fontSize: 16, fontWeight: "800", color: t.positive },
    checkText: { color: t.textMuted, fontSize: 14 },

    fixtureWarning: {
      marginTop: 8,
      backgroundColor: t.warningSurface,
      borderRadius: 8,
      padding: 8,
      borderWidth: 1,
      borderColor: t.isDark ? "#3D2800" : "#FDE68A",
    },
    fixtureWarningText: {
      color: t.warning,
      fontSize: 12,
      fontWeight: "800",
    },

    devCard: {
      backgroundColor: "#1F2937",
      borderRadius: 12,
      padding: 14,
      marginBottom: 14,
    },
    devCardTitle: {
      fontSize: 11,
      fontWeight: "800",
      textTransform: "uppercase",
      letterSpacing: 0.5,
      color: "#6B7280",
      marginBottom: 10,
    },
    devBtn: {
      borderRadius: 10,
      paddingVertical: 12,
      alignItems: "center",
      backgroundColor: "#374151",
      borderWidth: 1,
      borderColor: "#4B5563",
    },
    devBtnText: { color: "#D1D5DB", fontWeight: "800", fontSize: 14 },

    devDivider: {
      height: 1,
      backgroundColor: "#374151",
      marginVertical: 12,
    },
    devSectionLabel: {
      fontSize: 10,
      fontWeight: "800",
      textTransform: "uppercase",
      letterSpacing: 0.5,
      color: "#9CA3AF",
      marginBottom: 8,
    },
    devInput: {
      backgroundColor: "#111827",
      borderRadius: 8,
      paddingHorizontal: 12,
      paddingVertical: 10,
      color: "#F9FAFB",
      fontSize: 13,
      fontFamily: "monospace",
      borderWidth: 1,
      borderColor: "#374151",
    },
    devResultCard: {
      marginTop: 10,
      backgroundColor: "#111827",
      borderRadius: 8,
      padding: 10,
      borderWidth: 1,
      borderColor: "#374151",
    },
    devResultText: {
      color: "#6EE7B7",
      fontSize: 11,
      fontFamily: "monospace",
      lineHeight: 17,
    },

    devFixtureActive: {
      marginTop: 10,
      backgroundColor: "#78350F",
      borderRadius: 8,
      padding: 10,
      borderWidth: 1,
      borderColor: "#92400E",
    },
    devFixtureActiveText: {
      color: "#FDE68A",
      fontSize: 12,
      fontWeight: "800",
      textAlign: "center",
    },
  });
}

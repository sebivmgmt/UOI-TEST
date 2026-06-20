import React, { useMemo, useState } from "react";
import {
  View,
  Text,
  Alert,
  StyleSheet,
  TouchableOpacity,
  ActivityIndicator,
  ScrollView,
} from "react-native";
import { supabase } from "../supabase";

const GREEN = "#77B777";
const BLUE = "#3B82F6";
const BG = "#F5F7F9";
const RED = "#D9534F";

type AccountOption = {
  plaid_account_id: string;
  account_name: string | null;
  official_name: string | null;
  mask: string | null;
  type: string | null;
  subtype: string | null;
  verification_status: string | null;
  is_active: boolean;
};

export default function SelectBankAccount({ route, navigation }: any) {
  const {
    accounts = [],
    institutionName = null,
    returnTo = null,
    paymentId = null,
    iouId = null,
    iou_id = null,
    loanId = null,
    loan_id = null,
  } = route?.params ?? {};

  const resolvedIouId = iouId ?? iou_id ?? loanId ?? loan_id ?? null;

  const [saving, setSaving] = useState<string | null>(null);

  const eligibleAccounts: AccountOption[] = useMemo(() => {
    return Array.isArray(accounts)
      ? accounts.filter(
          (acct) =>
            acct?.is_active !== false &&
            acct?.type === "depository" &&
            (acct?.subtype === "checking" ||
              acct?.subtype === "savings" ||
              acct?.subtype == null)
        )
      : [];
  }, [accounts]);

  // Detects which stack this screen is currently mounted in, then navigates out cleanly:
  // - HomeStack → reset stack to Home (screen exists there)
  // - ProfileStack → reset stack back to Profile, then switch to HomeTab
  // - Identity gate → reset stack to its root, then attempt HomeTab (gate transition handles the rest)
  const navigateToHome = () => {
    const state = navigation.getState();
    const routeNames: string[] = (state as any)?.routeNames ?? [];

    if (routeNames.includes("Home")) {
      navigation.reset({ index: 0, routes: [{ name: "Home" }] });
    } else {
      // Reset this stack to its root first so the user doesn't return to SelectBankAccount
      // when they tap the Profile tab again.
      const rootRoute = routeNames[0] ?? "Profile";
      navigation.reset({ index: 0, routes: [{ name: rootRoute }] });
      navigation.getParent()?.navigate("HomeTab", { screen: "Home" });
    }
  };

  const finishFlow = async () => {
    if (returnTo === "ConfirmPayment" && paymentId) {
      // Always reached from HomeStack — navigation.reset() resets that stack.
      navigation.reset({
        index: 1,
        routes: [
          { name: "Home" },
          {
            name: "ConfirmPayment",
            params: {
              paymentId,
              iouId: resolvedIouId,
              iou_id: resolvedIouId,
              loanId: resolvedIouId,
              loan_id: resolvedIouId,
            },
          },
        ],
      });
      return;
    }

    if (resolvedIouId) {
      // Always reached from HomeStack — navigation.reset() resets that stack.
      navigation.reset({
        index: 1,
        routes: [
          { name: "Home" },
          {
            name: "LoanDetail",
            params: {
              iouId: resolvedIouId,
              iou_id: resolvedIouId,
              loanId: resolvedIouId,
              loan_id: resolvedIouId,
            },
          },
        ],
      });
      return;
    }

    try {
      await supabase.auth.refreshSession();
    } catch {
      // ignore — triggers onAuthStateChange which re-evaluates the gate
    }
    navigateToHome();
  };

  const handleSelect = async (account: AccountOption) => {
    try {
      setSaving(account.plaid_account_id);

      const { data: auth } = await supabase.auth.getUser();
      const me = auth.user?.id;
      if (!me) throw new Error("No signed-in user.");

      const { error: clearError } = await supabase
        .from("bank_accounts")
        .update({
          is_default_payment: false,
          updated_at: new Date().toISOString(),
        })
        .eq("user_id", me);

      if (clearError) {
        throw new Error(clearError.message);
      }

      const { error: setError } = await supabase
        .from("bank_accounts")
        .update({
          is_default_payment: true,
          updated_at: new Date().toISOString(),
        })
        .eq("user_id", me)
        .eq("plaid_account_id", account.plaid_account_id);

      if (setError) {
        throw new Error(setError.message);
      }

      let setupWarning: string | null = null;
      try {
        const { data: setupData, error: setupError } = await Promise.race([
          supabase.functions.invoke("dwolla-attach-funding-source", {
            body: { plaid_account_id: account.plaid_account_id },
          }),
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error("timeout")), 15000)
          ),
        ]);
        const d = setupData as any;
        if (setupError || !d?.ok || d?.ach_status !== "ready") {
          let fnStage: string | null = d?.stage ?? null;
          let fnError: string | null = d?.error ?? null;
          let fnStatus: number | null = null;
          let fnRetryable: boolean | null = d?.retryable ?? null;
          let fnAchStatus: string | null = d?.ach_status ?? null;

          if (setupError) {
            try {
              const ctx = (setupError as any)?.context as Response | undefined;
              fnStatus = ctx?.status ?? null;
              if (typeof ctx?.json === "function") {
                const body = await ctx.json();
                fnStage = fnStage ?? body?.stage ?? null;
                fnError = fnError ?? body?.error ?? null;
                fnRetryable = fnRetryable ?? body?.retryable ?? null;
                fnAchStatus = fnAchStatus ?? body?.ach_status ?? null;
              } else if (typeof ctx?.text === "function") {
                const raw = await ctx.text();
                try {
                  const parsed = JSON.parse(raw);
                  fnStage = fnStage ?? parsed?.stage ?? null;
                  fnError = fnError ?? parsed?.error ?? null;
                  fnRetryable = fnRetryable ?? parsed?.retryable ?? null;
                  fnAchStatus = fnAchStatus ?? parsed?.ach_status ?? null;
                } catch {}
              }
            } catch {}
          }

          console.error("[SelectBankAccount] payment setup error", {
            status: fnStatus,
            ok: d?.ok ?? false,
            stage: fnStage,
            error: fnError,
            retryable: fnRetryable,
            ach_status: fnAchStatus,
          });
          setupWarning = "setup_incomplete";
        }
      } catch (e: any) {
        console.error("[SelectBankAccount] payment setup exception", { message: e?.message });
        setupWarning = "setup_incomplete";
      }

      // Bank display metadata (bank_provider, bank_account_mask, etc.) is written
      // server-side by dwolla-attach-funding-source. The client must not write
      // these fields to profiles.

      Alert.alert(
        setupWarning ? "Bank selected" : "Bank ready for payments.",
        setupWarning
          ? "Bank selected, but payment setup is not ready yet. Please complete bank setup."
          : "Your bank account has been saved and is ready for payments.",
        [{ text: "OK", onPress: () => { void finishFlow(); } }]
      );
    } catch (e: any) {
      console.error("[SelectBankAccount] handleSelect error", e?.message);
      Alert.alert(
        "Selection failed",
        "We couldn't save your bank selection. Please try again."
      );
    } finally {
      setSaving(null);
    }
  };

  return (
    <ScrollView
      style={s.screen}
      contentContainerStyle={s.content}
      showsVerticalScrollIndicator={false}
    >
      <View style={s.card}>
        <Text style={s.eyebrow}>Choose account</Text>
        <Text style={s.title}>Select default payment account</Text>
        <Text style={s.subtitle}>
          Pick the bank account IOU should use by default for payments.
        </Text>

        {eligibleAccounts.length === 0 ? (
          <View style={s.emptyCard}>
            <Text style={s.emptyTitle}>No eligible accounts found</Text>
            <Text style={s.emptyText}>
              We found your institution, but no eligible bank accounts were available to select.
            </Text>
            <TouchableOpacity
              style={s.secondaryBtn}
              onPress={navigateToHome}
              activeOpacity={0.9}
            >
              <Text style={s.secondaryBtnText}>Back to Home</Text>
            </TouchableOpacity>
          </View>
        ) : (
          <>
            {eligibleAccounts.map((account) => {
              const isBusy = saving === account.plaid_account_id;
              const displayName =
                account.official_name || account.account_name || "Bank Account";
              const meta = [
                account.subtype || account.type || "account",
                account.mask ? `•••• ${account.mask}` : null,
              ]
                .filter(Boolean)
                .join(" • ");

              return (
                <TouchableOpacity
                  key={account.plaid_account_id}
                  style={[s.accountCard, isBusy && s.accountCardDisabled]}
                  onPress={() => handleSelect(account)}
                  disabled={!!saving}
                  activeOpacity={0.9}
                >
                  <View style={s.accountTopRow}>
                    <View style={{ flex: 1 }}>
                      <Text style={s.accountTitle}>{displayName}</Text>
                      <Text style={s.accountMeta}>{meta}</Text>
                    </View>

                    {isBusy ? (
                      <ActivityIndicator />
                    ) : (
                      <View style={s.selectPill}>
                        <Text style={s.selectPillText}>Select</Text>
                      </View>
                    )}
                  </View>
                </TouchableOpacity>
              );
            })}

            <TouchableOpacity
              style={[s.cancelBtn, !!saving && s.accountCardDisabled]}
              onPress={navigateToHome}
              disabled={!!saving}
              activeOpacity={0.9}
            >
              <Text style={s.cancelBtnText}>Cancel</Text>
            </TouchableOpacity>
          </>
        )}
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
    flexGrow: 1,
    justifyContent: "center",
  },

  card: {
    backgroundColor: "#fff",
    borderRadius: 18,
    padding: 18,
    borderWidth: 1,
    borderColor: "#EAEAEA",
  },

  eyebrow: {
    fontSize: 12,
    fontWeight: "800",
    textTransform: "uppercase",
    color: GREEN,
    letterSpacing: 0.5,
    marginBottom: 8,
  },

  title: {
    fontSize: 28,
    fontWeight: "800",
    color: "#111",
  },

  subtitle: {
    marginTop: 8,
    color: "#666",
    lineHeight: 21,
    marginBottom: 18,
  },

  emptyCard: {
    backgroundColor: "#FFF7ED",
    borderWidth: 1,
    borderColor: "#FED7AA",
    borderRadius: 14,
    padding: 14,
  },

  emptyTitle: {
    fontSize: 16,
    fontWeight: "800",
    color: "#7C2D12",
  },

  emptyText: {
    marginTop: 8,
    color: "#7C2D12",
    lineHeight: 20,
  },

  accountCard: {
    borderWidth: 1,
    borderColor: "#E5E7EB",
    borderRadius: 14,
    padding: 14,
    marginBottom: 12,
    backgroundColor: "#fff",
  },

  accountCardDisabled: {
    opacity: 0.7,
  },

  accountTopRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
  },

  accountTitle: {
    fontSize: 16,
    fontWeight: "800",
    color: "#111",
  },

  accountMeta: {
    marginTop: 4,
    color: "#666",
    fontSize: 13,
  },

  selectPill: {
    backgroundColor: BLUE,
    borderRadius: 999,
    paddingHorizontal: 12,
    paddingVertical: 8,
  },

  selectPillText: {
    color: "#fff",
    fontWeight: "800",
    fontSize: 12,
  },

  secondaryBtn: {
    marginTop: 16,
    height: 50,
    borderRadius: 14,
    backgroundColor: "#EEF2F5",
    alignItems: "center",
    justifyContent: "center",
  },

  secondaryBtnText: {
    color: "#222",
    fontSize: 16,
    fontWeight: "700",
  },

  cancelBtn: {
    marginTop: 8,
    height: 50,
    borderRadius: 14,
    backgroundColor: RED,
    alignItems: "center",
    justifyContent: "center",
  },

  cancelBtnText: {
    color: "#fff",
    fontSize: 16,
    fontWeight: "800",
  },
});

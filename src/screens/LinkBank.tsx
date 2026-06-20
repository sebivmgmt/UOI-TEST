import React, { useCallback, useEffect, useMemo, useState } from "react";
import {
  View,
  Text,
  Alert,
  StyleSheet,
  TouchableOpacity,
  ActivityIndicator,
  ScrollView,
} from "react-native";
import {
  create,
  open,
  LinkSuccess,
  LinkExit,
} from "react-native-plaid-link-sdk";
import { supabase } from "../supabase";

const GREEN = "#77B777";
const BLUE = "#3B82F6";
const ORANGE = "#F59E0B";
const RED = "#D9534F";
const BG = "#F5F7F9";

type BankLinkState = {
  linked: boolean;
  providerLabel: string | null;
  accountMask: string | null;
  achStatus: string | null;
};

type ProfileReadResult = {
  linked: boolean;
  providerLabel: string | null;
  accountMask: string | null;
  achStatus: string | null;
};

type ExchangeAccount = {
  plaid_account_id: string;
  account_name: string | null;
  official_name: string | null;
  mask: string | null;
  type: string | null;
  subtype: string | null;
  verification_status: string | null;
  is_active: boolean;
};

export default function LinkBank({ route, navigation }: any) {
  const returnTo = route?.params?.returnTo ?? null;
  const paymentId = route?.params?.paymentId ?? null;
  const iouId =
    route?.params?.iouId ??
    route?.params?.iou_id ??
    route?.params?.loanId ??
    route?.params?.loan_id ??
    null;

  const [loading, setLoading] = useState(true);
  const [linking, setLinking] = useState(false);
  const [state, setState] = useState<BankLinkState>({
    linked: false,
    providerLabel: null,
    accountMask: null,
    achStatus: null,
  });

  const getCurrentUserId = useCallback(async () => {
    const { data: auth } = await supabase.auth.getUser();
    const me = auth.user?.id;
    if (!me) throw new Error("No signed-in user.");
    return me;
  }, []);

  const getAccessToken = useCallback(async () => {
    const { data, error } = await supabase.auth.getSession();
    if (error) throw new Error(error.message);
    const accessToken = data.session?.access_token;
    if (!accessToken) throw new Error("No active session token.");
    return accessToken;
  }, []);

  const readProfileBankState = useCallback(async (userId: string) => {
    const selectAttempts = [
      "bank_linked, plaid_linked, bank_provider, bank_account_mask, plaid_institution_name, account_mask, ach_status",
      "bank_linked, plaid_linked, bank_provider, bank_account_mask, plaid_institution_name, account_mask",
      "plaid_linked, plaid_institution_name, account_mask",
      "bank_linked, bank_provider, bank_account_mask",
    ];

    for (const sel of selectAttempts) {
      const { data, error } = await supabase
        .from("profiles")
        .select(sel)
        .eq("id", userId)
        .single();

      if (!error && data) {
        const raw = data as any;

        const linked = !!(raw.bank_linked ?? raw.plaid_linked);
        const providerLabel =
          raw.bank_provider ?? raw.plaid_institution_name ?? null;
        const accountMask = raw.bank_account_mask ?? raw.account_mask ?? null;
        const achStatus =
          typeof raw.ach_status === "string"
            ? raw.ach_status
            : null;

        const result: ProfileReadResult = {
          linked,
          providerLabel,
          accountMask,
          achStatus,
        };

        return result;
      }
    }

    return {
      linked: false,
      providerLabel: null,
      accountMask: null,
      achStatus: null,
    } as ProfileReadResult;
  }, []);

  const loadBankState = useCallback(async () => {
    setLoading(true);

    try {
      const me = await getCurrentUserId();
      const nextState = await readProfileBankState(me);
      setState(nextState);
    } catch (e: any) {
      console.error("[LinkBank] loadBankState error", e?.message);
      Alert.alert("Error", "Could not load bank status. Please try again.");
    } finally {
      setLoading(false);
    }
  }, [getCurrentUserId, readProfileBankState]);

  useEffect(() => {
    void loadBankState();
  }, [loadBankState]);

  const connectionLabel = useMemo(() => {
    if (!state.linked) return "No bank connected";
    const provider = state.providerLabel || "Connected Bank";
    const mask = state.accountMask ? ` •••• ${state.accountMask}` : "";
    return `${provider}${mask}`;
  }, [state]);

  const statusTone = useMemo(() => {
    if (state.linked) {
      return {
        bg: "#EAF8EA",
        border: "#D8EFD8",
        title: GREEN,
        text: "#2F4F2F",
      };
    }

    return {
      bg: "#FFF7ED",
      border: "#FED7AA",
      title: ORANGE,
      text: "#7C2D12",
    };
  }, [state.linked]);

  const paymentStatus = useMemo(() => {
    if (!state.linked) return "Connect a bank to prepare IOU payments.";
    if (state.achStatus === "ready") return "Bank ready for payments.";
    return "Bank connected. Payment setup still needs to finish.";
  }, [state.linked, state.achStatus]);

  // Bank display metadata (bank_provider, bank_account_mask, plaid_institution_name,
  // plaid_account_id, account_mask, bank_name) must be written server-side by the
  // trusted Plaid/Dwolla flow. The client must not write these fields to profiles.

  // bank_accounts rows are created server-side by exchange-token.
  // Only the default-payment flag is managed here.

  const setDefaultPaymentAccount = useCallback(
    async (account: ExchangeAccount, institutionName: string | null) => {
      const me = await getCurrentUserId();

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
    },
    [getCurrentUserId]
  );

  const attachPaymentSetup = useCallback(
    async (plaidAccountId: string): Promise<{ warning: string | null }> => {
      try {
        const { data, error } = await supabase.functions.invoke(
          "dwolla-attach-funding-source",
          { body: { plaid_account_id: plaidAccountId } }
        );
        const d = data as any;
        if (error || !d?.ok) {
          let fnStage: string | null = d?.stage ?? null;
          let fnError: string | null = d?.error ?? null;
          let fnStatus: number | null = null;
          let fnRetryable: boolean | null = d?.retryable ?? null;
          let fnAchStatus: string | null = d?.ach_status ?? null;

          if (error) {
            try {
              const ctx = (error as any)?.context as Response | undefined;
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

          console.error("[LinkBank] payment setup error", {
            status: fnStatus,
            ok: d?.ok ?? false,
            stage: fnStage,
            error: fnError,
            retryable: fnRetryable,
            ach_status: fnAchStatus,
          });
          return { warning: "setup_incomplete" };
        }
        return { warning: null };
      } catch (e: any) {
        console.error("[LinkBank] payment setup exception", { message: e?.message });
        return { warning: "setup_incomplete" };
      }
    },
    []
  );

  // Bank removal requires a server-side unlink flow that:
  //   1. Looks up the user's Dwolla funding source (dwolla_funding_source_id or
  //      dwolla_funding_source_url from bank_accounts) and calls the Dwolla
  //      DELETE /funding-sources/{id} API to remove it.
  //   2. Verifies the funding source is fully removed via Dwolla before clearing
  //      any local state.
  //   3. Only after Dwolla confirms: sets bank_linked=false, plaid_linked=false,
  //      ach_status=null, clears display metadata, and deletes the bank_accounts rows.
  // Until that Edge Function exists, removal is blocked client-side.

  const goNext = useCallback(async () => {
    if (returnTo === "ConfirmPayment") {
      navigation.navigate("ConfirmPayment", {
        paymentId,
        iouId,
        iou_id: iouId,
        loanId: iouId,
        loan_id: iouId,
      });
      return;
    }

    if (iouId) {
      navigation.navigate("LoanDetail", {
        iouId,
        iou_id: iouId,
      });
      return;
    }

    if (navigation.canGoBack()) {
      navigation.goBack();
      return;
    }

    // Refresh the session so onAuthStateChange re-evaluates the gate.
    // This is the correct exit when finishing the identity/bank-link gate flow,
    // where "Home" is not in the current navigator.
    await supabase.auth.refreshSession();
  }, [navigation, returnTo, paymentId, iouId]);

  const handlePlaidSuccess = useCallback(
    async (success: LinkSuccess) => {
      try {
        const institutionName =
          success?.metadata?.institution?.name ?? "Plaid Connected Bank";

        const accessToken = await getAccessToken();
        const me = await getCurrentUserId();

        const { data: exchangeDataRaw, error: exchangeError } =
          await supabase.functions.invoke("exchange-token", {
            body: {
              public_token: success.publicToken,
              institution_name: institutionName,
              user_id: me,
              metadata_accounts: success?.metadata?.accounts ?? [],
            },
            headers: {
              Authorization: `Bearer ${accessToken}`,
            },
          });

        let exchangeData: any = exchangeDataRaw;

        if (typeof exchangeDataRaw === "string") {
          try {
            exchangeData = JSON.parse(exchangeDataRaw);
          } catch {
            exchangeData = exchangeDataRaw;
          }
        }

        if (exchangeError) {
          const errorAny = exchangeError as any;
          const response = errorAny?.context;

          let body: any = null;

          try {
            if (response && typeof response.text === "function") {
              const text = await response.text();
              try {
                body = JSON.parse(text);
              } catch {
                body = text;
              }
            }
          } catch (e: any) {
            body = { failed_to_read: true, message: e?.message ?? "unknown" };
          }

          console.error("[LinkBank] exchange-token error", {
            stage: body?.stage ?? null,
            error: body?.error ?? null,
            status: response?.status ?? null,
          });

          throw new Error(
            body?.details?.message ||
              body?.details ||
              body?.error ||
              errorAny?.message ||
              "Exchange failed"
          );
        }

        const plaidItemId =
          exchangeData?.item_id ??
          exchangeData?.data?.item_id ??
          exchangeData?.itemId ??
          exchangeData?.data?.itemId ??
          null;

        if (!plaidItemId) {
          throw new Error("Failed to retrieve item_id from backend.");
        }

        const accounts: ExchangeAccount[] = Array.isArray(exchangeData?.accounts)
          ? exchangeData.accounts
          : Array.isArray(exchangeData?.data?.accounts)
            ? exchangeData.data.accounts
            : [];

        const eligibleAccounts = accounts.filter(
          (acct) =>
            acct.is_active !== false &&
            acct.type === "depository" &&
            (acct.subtype === "checking" ||
              acct.subtype === "savings" ||
              acct.subtype == null)
        );

        const checkingAccounts = eligibleAccounts.filter(
          (acct) => acct.subtype === "checking"
        );

        if (checkingAccounts.length === 1 && eligibleAccounts.length === 1) {
          const account = checkingAccounts[0];

          await setDefaultPaymentAccount(account, institutionName);
          const { warning: setupWarning } = await attachPaymentSetup(account.plaid_account_id);
          await loadBankState();

          Alert.alert(
            setupWarning ? "Bank connected" : "Bank ready for payments.",
            setupWarning
              ? "Bank connected. Payment setup still needs to finish. You can keep using IOU, but payments will stay disabled until setup is ready."
              : "Your bank is connected and ready for payments.",
            [{ text: "OK", onPress: () => { void goNext(); } }]
          );
          return;
        }

        if (eligibleAccounts.length > 1) {
          navigation.navigate("SelectBankAccount", {
            accounts: eligibleAccounts,
            institutionName,
            plaidItemId,
            returnTo,
            paymentId,
            iouId,
            iou_id: iouId,
            loanId: iouId,
            loan_id: iouId,
          });
          return;
        }

        if (accounts.length === 1) {
          const account = accounts[0];

          await setDefaultPaymentAccount(account, institutionName);
          const { warning: setupWarning } = await attachPaymentSetup(account.plaid_account_id);
          await loadBankState();

          Alert.alert(
            setupWarning ? "Bank connected" : "Bank ready for payments.",
            setupWarning
              ? "Bank connected. Payment setup still needs to finish. You can keep using IOU, but payments will stay disabled until setup is ready."
              : "Your bank is connected and ready for payments.",
            [{ text: "OK", onPress: () => { void goNext(); } }]
          );
          return;
        }

        await loadBankState();

        Alert.alert(
          "Bank linked",
          accounts.length > 0
            ? "Your bank was linked. Please select a payment account."
            : "Your bank was linked, but no eligible accounts were found.",
          [
            {
              text: "OK",
              onPress: () => goNext(),
            },
          ]
        );
      } catch (e: any) {
        console.error("[LinkBank] handlePlaidSuccess error", e?.message);
        Alert.alert(
          "Bank setup failed",
          "We couldn't finish bank setup. Please try again."
        );
      } finally {
        setLinking(false);
      }
    },
    [
      attachPaymentSetup,
      getAccessToken,
      getCurrentUserId,
      goNext,
      iouId,
      loadBankState,
      navigation,
      paymentId,
      returnTo,
      setDefaultPaymentAccount,
    ]
  );

  const handlePlaidExit = useCallback((exit: LinkExit) => {
    const exitMessage =
      exit?.error?.displayMessage || exit?.error?.errorMessage || null;

    if (exitMessage) {
      Alert.alert("Connection closed", exitMessage);
    }

    setLinking(false);
  }, []);

  const handleOpenPlaid = useCallback(async () => {
    try {
      setLinking(true);

      const me = await getCurrentUserId();

      const { data, error } = await supabase.functions.invoke("create-link-token", {
        body: {
          client_user_id: me,
        },
      });

      if (error) {
        // Read the actual response body so DEV toasts show stage + Plaid error
        // rather than the generic FunctionsHttpError message.
        let fnStage: string | null = null;
        let fnError: string | null = null;
        let fnStatus: number | null = null;
        try {
          const ctx = (error as any)?.context as Response | undefined;
          fnStatus = ctx?.status ?? null;
          if (typeof ctx?.json === "function") {
            const body = await ctx.json();
            fnStage = body?.stage ?? null;
            fnError = body?.error ?? null;
          } else if (typeof ctx?.text === "function") {
            const raw = await ctx.text();
            const parsed = JSON.parse(raw);
            fnStage = parsed?.stage ?? null;
            fnError = parsed?.error ?? null;
          }
        } catch {}

        console.error("[LinkBank] handleOpenPlaid error", {
          status: fnStatus,
          stage: fnStage,
          error: fnError,
        });

        throw new Error(fnError || error.message || "Could not create link token.");
      }

      if (!data?.link_token) {
        throw new Error("No link token returned.");
      }

      create({ token: data.link_token });

      open({
        onSuccess: handlePlaidSuccess,
        onExit: handlePlaidExit,
      });
    } catch (e: any) {
      setLinking(false);
      console.error("[LinkBank] handleOpenPlaid error", e?.message);
      Alert.alert("Connection failed", "We couldn't open the bank connection. Please try again.");
    }
  }, [getCurrentUserId, handlePlaidExit, handlePlaidSuccess]);

  const handleRemoveBank = () => {
    // Bank removal is not yet available client-side. A server-side unlink
    // function must first revoke the Dwolla funding source before any local
    // state can be cleared. See comment above for what that requires.
    Alert.alert(
      "Bank removal unavailable",
      "Bank removal is temporarily unavailable. Your payment connection was not changed.",
      [{ text: "OK" }]
    );
  };

  const handleContinue = () => {
    void goNext();
  };

  return (
    <ScrollView
      style={s.screen}
      contentContainerStyle={s.content}
      showsVerticalScrollIndicator={false}
    >
      <View style={s.card}>
        <Text style={s.title}>Link Bank</Text>
        <Text style={s.subtitle}>
          Connect your bank account to enable IOU payments.
        </Text>

        {loading ? (
          <View style={s.loadingWrap}>
            <ActivityIndicator />
            <Text style={s.loadingText}>Loading bank connection…</Text>
          </View>
        ) : (
          <>
            <View
              style={[
                s.statusCard,
                {
                  backgroundColor: statusTone.bg,
                  borderColor: statusTone.border,
                },
              ]}
            >
              <Text style={[s.statusCardTitle, { color: statusTone.title }]}>
                Bank account
              </Text>
              <Text style={s.statusPrimary}>{connectionLabel}</Text>
              <Text style={[s.statusSecondary, { color: statusTone.text }]}>
                {paymentStatus}
              </Text>
            </View>

            {!state.linked ? (
              <TouchableOpacity
                style={[s.primaryBtn, linking && s.btnDisabled]}
                onPress={handleOpenPlaid}
                disabled={linking}
                activeOpacity={0.9}
              >
                {linking ? (
                  <ActivityIndicator color="#fff" />
                ) : (
                  <Text style={s.primaryBtnText}>Connect bank</Text>
                )}
              </TouchableOpacity>
            ) : (
              <>
                <TouchableOpacity
                  style={[s.primaryBtn, linking && s.btnDisabled]}
                  onPress={handleOpenPlaid}
                  disabled={linking}
                  activeOpacity={0.9}
                >
                  {linking ? (
                    <ActivityIndicator color="#fff" />
                  ) : (
                    <Text style={s.primaryBtnText}>Replace bank</Text>
                  )}
                </TouchableOpacity>

                <TouchableOpacity
                  style={s.removeBtn}
                  onPress={handleRemoveBank}
                  disabled={linking}
                  activeOpacity={0.9}
                >
                  <Text style={s.removeBtnText}>Remove bank</Text>
                </TouchableOpacity>
              </>
            )}

            <TouchableOpacity
              style={[
                s.secondaryBtn,
                !state.linked && s.secondaryBtnDisabled,
              ]}
              onPress={handleContinue}
              activeOpacity={0.9}
            >
              <Text
                style={[
                  s.secondaryBtnText,
                  !state.linked && s.secondaryBtnTextDisabled,
                ]}
              >
                {state.linked ? "Continue" : "Back"}
              </Text>
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

  title: {
    fontSize: 28,
    fontWeight: "800",
    color: "#111",
  },

  subtitle: {
    marginTop: 8,
    color: "#666",
    lineHeight: 21,
  },

  loadingWrap: {
    marginTop: 18,
    alignItems: "center",
    justifyContent: "center",
    paddingVertical: 20,
  },

  loadingText: {
    marginTop: 10,
    color: "#666",
  },

  statusCard: {
    marginTop: 18,
    borderWidth: 1,
    borderRadius: 14,
    padding: 14,
  },

  statusCardTitle: {
    fontSize: 12,
    fontWeight: "800",
    textTransform: "uppercase",
    marginBottom: 8,
  },

  statusPrimary: {
    fontSize: 18,
    fontWeight: "800",
    color: "#111",
  },

  statusSecondary: {
    marginTop: 6,
    lineHeight: 20,
    fontSize: 14,
  },

  primaryBtn: {
    marginTop: 20,
    height: 54,
    borderRadius: 14,
    backgroundColor: BLUE,
    alignItems: "center",
    justifyContent: "center",
  },

  removeBtn: {
    marginTop: 10,
    height: 54,
    borderRadius: 14,
    backgroundColor: RED,
    alignItems: "center",
    justifyContent: "center",
  },

  btnDisabled: {
    opacity: 0.7,
  },

  primaryBtnText: {
    color: "#fff",
    fontSize: 17,
    fontWeight: "800",
  },

  removeBtnText: {
    color: "#fff",
    fontSize: 17,
    fontWeight: "800",
  },

  secondaryBtn: {
    marginTop: 10,
    height: 50,
    borderRadius: 14,
    backgroundColor: "#EEF2F5",
    alignItems: "center",
    justifyContent: "center",
  },

  secondaryBtnDisabled: {
    backgroundColor: "#F3F4F6",
  },

  secondaryBtnText: {
    color: "#222",
    fontSize: 16,
    fontWeight: "700",
  },

  secondaryBtnTextDisabled: {
    color: "#667085",
  },
});

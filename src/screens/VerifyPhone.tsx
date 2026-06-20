// src/screens/VerifyPhone.tsx
import React, { useEffect, useState } from "react";
import {
  ActivityIndicator,
  Alert,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { supabase } from "../supabase";

const BRAND = "#1B5E20";
const BG = "#F5F7F9";

export default function VerifyPhone() {
  const [phone, setPhone] = useState("");
  const [code, setCode] = useState("");
  const [sending, setSending] = useState(false);
  const [verifying, setVerifying] = useState(false);
  const [codeSent, setCodeSent] = useState(false);

  // userId is used only to guard against calling before auth is resolved.
  // User identity for all server operations is derived from the session JWT.
  const [userId, setUserId] = useState<string | null>(null);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => setUserId(data.user?.id ?? null));
  }, []);

  // ── Step 1: Request verification code ─────────────────────────────────────
  // Calls request-phone-verification which:
  //   • Normalizes and validates the phone number server-side
  //   • Saves the normalized phone to profiles.phone via service role
  //   • Inserts into phone_verifications via service role
  //   • In dev (ALLOW_DEV_PHONE_OTP=true): returns dev_code in the response
  //   • In production: dispatches the code via SMS, never returns it
  //   • Fails closed (503) if neither env var is set
  const handleSendCode = async () => {
    if (!userId) return Alert.alert("Not signed in");

    const digitCount = phone.replace(/\D/g, "").length;
    if (digitCount < 10) {
      return Alert.alert("Invalid number", "Enter a valid phone number including area code.");
    }

    setSending(true);

    try {
      const { data, error } = await supabase.functions.invoke(
        "request-phone-verification",
        { body: { phone: phone.trim() } }
      );

      if (error) {
        let fnStatus: number | null = null;
        let fnStage: string | null = null;
        let fnError: string | null = null;
        try {
          const ctx = (error as any)?.context as Response | undefined;
          fnStatus = ctx?.status ?? null;
          if (typeof ctx?.json === "function") {
            const body = await ctx.json();
            fnStage = body?.stage ?? null;
            fnError = typeof body?.error === "string" ? body.error : null;
          } else if (typeof ctx?.text === "function") {
            const raw = await ctx.text();
            try {
              const parsed = JSON.parse(raw);
              fnStage = parsed?.stage ?? null;
              fnError = typeof parsed?.error === "string" ? parsed.error : null;
            } catch {}
          }
        } catch {}
        if (__DEV__) {
          console.log("[VerifyPhone] send error", {
            userId_suffix: userId?.slice(-6) ?? null,
            status: fnStatus,
            stage: fnStage,
            error: fnError ?? error.message,
          });
        }
        return Alert.alert("Could not send code", fnError ?? error.message);
      }

      if (__DEV__) {
        console.log("[VerifyPhone] send ok", {
          userId_suffix: userId?.slice(-6) ?? null,
          dev_code_returned: !!(data as any)?.dev_code,
        });
      }

      setCodeSent(true);

      const devCode = (data as any)?.dev_code;
      if (devCode) {
        Alert.alert("Dev mode", `Code: ${devCode}`);
      }
    } finally {
      setSending(false);
    }
  };

  // ── Step 2: Verify the submitted code ─────────────────────────────────────
  // Calls public.verify_phone_code(in_code, in_phone) which:
  //   • Looks up the unconsumed, non-expired verification row for (user, phone)
  //   • Validates the code with a FOR UPDATE lock to prevent concurrent reuse
  //   • On success: marks phone_verified=true and phone_verified_at=now() on
  //     the profile (enforced by DB trigger — clients cannot write these fields)
  //   • Returns true on success, false on incorrect/expired code
  //
  // Gate re-evaluates via onAuthStateChange after refreshSession — no explicit
  // navigation needed; the gate transition unmounts this screen.
  const handleVerifyCode = async () => {
    if (!userId) return Alert.alert("Not signed in");

    setVerifying(true);

    try {
      // in_phone is intentionally omitted: the client holds the raw typed phone
      // but the server stored the E.164-normalized form. Passing the raw string
      // would cause pv.phone = v_target_phone to fail. Omitting in_phone (NULL)
      // skips that filter; auth.uid() already scopes the lookup to this user.
      const { data, error } = await supabase.rpc("verify_phone_code", {
        in_code: code.trim(),
      });

      if (__DEV__) {
        console.log("[VerifyPhone] verify rpc", {
          userId_suffix: userId?.slice(-6) ?? null,
          rpc_data: data,
          rpc_error: error ? { message: error.message, code: (error as any).code } : null,
        });
      }

      if (error) {
        return Alert.alert("Verification failed", error.message);
      }

      if (data !== true) {
        return Alert.alert(
          "Incorrect code",
          "The code is incorrect or has expired. Please request a new code."
        );
      }

      const { data: profileData, error: profileError } = await supabase
        .from("profiles")
        .select("phone_verified")
        .eq("id", userId)
        .single();

      if (__DEV__) {
        console.log("[VerifyPhone] profile readback", {
          userId_suffix: userId?.slice(-6) ?? null,
          phone_verified: (profileData as any)?.phone_verified ?? null,
          profile_error: profileError ? { message: profileError.message, code: (profileError as any).code } : null,
        });
      }

      if (profileError || !(profileData as any)?.phone_verified) {
        return Alert.alert(
          "Verification failed",
          "Verification did not complete. Please try again."
        );
      }

      await supabase.auth.refreshSession();
    } catch (e: any) {
      Alert.alert("Verification failed", e?.message ?? "An unexpected error occurred.");
    } finally {
      setVerifying(false);
    }
  };

  const canSend = phone.replace(/\D/g, "").length >= 10 && !sending;
  const canVerify = code.trim().length > 0 && !verifying;

  return (
    <KeyboardAvoidingView
      style={{ flex: 1, backgroundColor: BG }}
      behavior={Platform.OS === "ios" ? "padding" : undefined}
      keyboardVerticalOffset={88}
    >
      <ScrollView
        contentContainerStyle={s.scroll}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      >
        <View style={s.header}>
          <Text style={s.title}>Verify your phone</Text>
          <Text style={s.subtitle}>
            We'll send a code to confirm your number.
          </Text>
        </View>

        {/* Step 1 — Phone number */}
        <View style={s.card}>
          <Text style={s.cardLabel}>Phone number</Text>
          <View style={s.inputRow}>
            <TextInput
              style={[s.input, { flex: 1 }]}
              keyboardType="phone-pad"
              placeholder="+1 (555) 000-0000"
              placeholderTextColor="#9CA3AF"
              value={phone}
              onChangeText={setPhone}
              autoComplete="tel"
              editable={!sending && !verifying}
            />
          </View>
          <TouchableOpacity
            style={[s.btn, !canSend && s.btnDisabled]}
            onPress={handleSendCode}
            disabled={!canSend}
            activeOpacity={0.85}
          >
            {sending ? (
              <ActivityIndicator color="#fff" />
            ) : (
              <Text style={s.btnText}>
                {codeSent ? "Resend code" : "Send code"}
              </Text>
            )}
          </TouchableOpacity>
        </View>

        {/* Step 2 — Verification code */}
        {codeSent && (
          <View style={s.card}>
            <Text style={s.cardLabel}>Verification code</Text>
            <TextInput
              style={s.input}
              keyboardType="number-pad"
              placeholder="Enter code"
              placeholderTextColor="#9CA3AF"
              value={code}
              onChangeText={setCode}
              editable={!verifying}
            />
            <TouchableOpacity
              style={[s.btn, s.btnPrimary, !canVerify && s.btnDisabled]}
              onPress={handleVerifyCode}
              disabled={!canVerify}
              activeOpacity={0.85}
            >
              {verifying ? (
                <ActivityIndicator color="#fff" />
              ) : (
                <Text style={s.btnText}>Verify</Text>
              )}
            </TouchableOpacity>
          </View>
        )}
      </ScrollView>
    </KeyboardAvoidingView>
  );
}


const s = StyleSheet.create({
  scroll: {
    padding: 16,
    gap: 16,
    flexGrow: 1,
  },
  header: {
    gap: 6,
    marginBottom: 4,
  },
  title: {
    fontSize: 28,
    fontWeight: "900",
    color: "#111827",
  },
  subtitle: {
    fontSize: 15,
    fontWeight: "600",
    color: "#6B7280",
    lineHeight: 22,
  },
  card: {
    backgroundColor: "#fff",
    borderRadius: 16,
    borderWidth: 1,
    borderColor: "#E5E7EB",
    padding: 16,
    gap: 12,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 8,
    elevation: 3,
  },
  cardLabel: {
    fontSize: 12,
    fontWeight: "800",
    color: "#6B7280",
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
  inputRow: {
    flexDirection: "row",
    gap: 10,
    alignItems: "center",
  },
  input: {
    backgroundColor: "#F9FAFB",
    borderWidth: 1,
    borderColor: "#E5E7EB",
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 16,
    fontWeight: "600",
    color: "#111827",
  },
  btn: {
    backgroundColor: "#6B7280",
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: "center",
  },
  btnPrimary: {
    backgroundColor: BRAND,
  },
  btnDisabled: {
    opacity: 0.45,
  },
  btnText: {
    color: "#fff",
    fontSize: 16,
    fontWeight: "800",
  },
});

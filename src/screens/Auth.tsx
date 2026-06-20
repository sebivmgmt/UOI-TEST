// src/screens/Auth.tsx
import React, { useEffect, useRef, useState } from "react";
import {
  View,
  Text,
  TextInput,
  Alert,
  ActivityIndicator,
  StyleSheet,
  TouchableOpacity,
  Modal,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  Animated as RNAnimated,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { supabase } from "../supabase";

const BRAND = "#1B5E20";

export default function Auth() {
  const [mode, setMode] = useState<"landing" | "login">("landing");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [signUpVisible, setSignUpVisible] = useState(false);
  const [signUpEmail, setSignUpEmail] = useState("");
  const [signUpPassword, setSignUpPassword] = useState("");
  const [signUpBusy, setSignUpBusy] = useState(false);

  const contentOpacity = useRef(new RNAnimated.Value(0)).current;
  const loginFormHeight = useRef(new RNAnimated.Value(0)).current;
  useEffect(() => {
    RNAnimated.timing(contentOpacity, {
      toValue: 1,
      duration: 700,
      delay: 200,
      useNativeDriver: true,
    }).start();
  }, []);

  useEffect(() => {
    RNAnimated.timing(loginFormHeight, {
      toValue: mode === "login" ? 1 : 0,
      duration: 300,
      useNativeDriver: false,
    }).start();
  }, [mode]);

  const signIn = async () => {
    if (!email.trim() || !password) {
      return Alert.alert("Missing fields", "Enter your email and password.");
    }
    setBusy(true);
    try {
      const { error } = await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      });
      if (error) throw error;
    } catch (e: any) {
      // TODO remove before production — full error detail for network failure diagnosis
      if (__DEV__) {
        console.error("[DEV] signIn error (full):", {
          message: e?.message,
          name: e?.name,
          cause: e?.cause,
          stack: e?.stack,
        });
      }
      Alert.alert("Sign in failed", e.message ?? String(e));
    } finally {
      setBusy(false);
    }
  };

  const signUp = async () => {
    if (!signUpEmail.trim() || !signUpPassword) {
      return Alert.alert("Missing fields", "Enter your email and password.");
    }
    setSignUpBusy(true);
    try {
      const { error } = await supabase.auth.signUp({
        email: signUpEmail.trim(),
        password: signUpPassword,
      });
      if (error) throw error;
      setSignUpVisible(false);
      setSignUpEmail("");
      setSignUpPassword("");
      Alert.alert(
        "Check your inbox",
        "We sent a confirmation link to your email. Tap it to activate your account."
      );
    } catch (e: any) {
      Alert.alert("Sign up failed", e.message ?? String(e));
    } finally {
      setSignUpBusy(false);
    }
  };

  const reset = async () => {
    if (!email.trim()) {
      return Alert.alert(
        "Enter your email first",
        "Type your email above, then tap Forgot password."
      );
    }
    setBusy(true);
    try {
      const { error } = await supabase.auth.resetPasswordForEmail(email.trim());
      if (error) throw error;
      Alert.alert("Sent", "Password reset link emailed.");
    } catch (e: any) {
      Alert.alert("Reset failed", e.message ?? String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <SafeAreaView style={s.safe}>
      <KeyboardAvoidingView
        style={{ flex: 1 }}
        behavior={Platform.OS === "ios" ? "padding" : undefined}
      >
        <ScrollView
          contentContainerStyle={s.scroll}
          keyboardShouldPersistTaps="handled"
          showsVerticalScrollIndicator={false}
        >
          {/* Logo wordmark + spinning O */}
          <RNAnimated.View style={[s.logoWrap, { opacity: contentOpacity }]}>
            <RNAnimated.Image
              source={require("../../assets/iou-wordmark-final.png")}
              style={s.logo}
              resizeMode="contain"
            />
          </RNAnimated.View>

          {/* Tagline */}
          <RNAnimated.View style={{ opacity: contentOpacity }}>
            <Text style={s.tagline}>Be a Bank.</Text>
            <Text style={s.sub}>Get Paid.</Text>
          </RNAnimated.View>

          {/* Login form (slides in) */}
          {mode === "login" && (
            <RNAnimated.View style={{ opacity: contentOpacity }}>
              <TextInput
                style={s.input}
                placeholder="Email"
                placeholderTextColor="#aaa"
                autoCapitalize="none"
                keyboardType="email-address"
                value={email}
                onChangeText={setEmail}
                autoFocus
              />
              <TextInput
                style={s.input}
                placeholder="Password"
                placeholderTextColor="#aaa"
                secureTextEntry
                value={password}
                onChangeText={setPassword}
              />
              {busy ? (
                <ActivityIndicator style={{ marginTop: 4 }} color={BRAND} />
              ) : (
                <TouchableOpacity
                  style={s.primaryBtn}
                  onPress={signIn}
                  activeOpacity={0.85}
                >
                  <Text style={s.primaryBtnText}>Sign In</Text>
                </TouchableOpacity>
              )}
              <TouchableOpacity style={s.linkBtn} onPress={reset}>
                <Text style={s.linkBtnText}>Forgot password</Text>
              </TouchableOpacity>
            </RNAnimated.View>
          )}

          {/* CTA buttons */}
          <RNAnimated.View style={[s.ctaSection, { opacity: contentOpacity }]}>
            <TouchableOpacity
              style={s.primaryBtn}
              onPress={() => setSignUpVisible(true)}
              activeOpacity={0.85}
            >
              <Text style={s.primaryBtnText}>Get Started</Text>
            </TouchableOpacity>

            {mode === "landing" ? (
              <TouchableOpacity
                style={s.outlineBtn}
                onPress={() => setMode("login")}
                activeOpacity={0.85}
              >
                <Text style={s.outlineBtnText}>Log In</Text>
              </TouchableOpacity>
            ) : (
              <TouchableOpacity
                style={s.outlineBtn}
                onPress={() => setMode("landing")}
                activeOpacity={0.85}
              >
                <Text style={s.outlineBtnText}>Back</Text>
              </TouchableOpacity>
            )}
          </RNAnimated.View>
        </ScrollView>
      </KeyboardAvoidingView>

      {/* Sign up modal */}
      <Modal
        visible={signUpVisible}
        animationType="slide"
        presentationStyle="pageSheet"
        onRequestClose={() => setSignUpVisible(false)}
      >
        <SafeAreaView style={s.modalSafe}>
          <KeyboardAvoidingView
            style={{ flex: 1 }}
            behavior={Platform.OS === "ios" ? "padding" : undefined}
          >
            <ScrollView
              contentContainerStyle={s.modalScroll}
              keyboardShouldPersistTaps="handled"
              showsVerticalScrollIndicator={false}
            >
              <View style={s.modalHeader}>
                <Text style={s.modalTitle}>Create account</Text>
                <TouchableOpacity
                  onPress={() => setSignUpVisible(false)}
                  hitSlop={12}
                >
                  <Text style={s.modalClose}>✕</Text>
                </TouchableOpacity>
              </View>

              <Text style={s.modalSubtitle}>
                We'll send a confirmation link to verify your email.
              </Text>

              <TextInput
                style={s.input}
                placeholder="Email"
                placeholderTextColor="#aaa"
                autoCapitalize="none"
                keyboardType="email-address"
                value={signUpEmail}
                onChangeText={setSignUpEmail}
                autoFocus
              />
              <TextInput
                style={s.input}
                placeholder="Password"
                placeholderTextColor="#aaa"
                secureTextEntry
                value={signUpPassword}
                onChangeText={setSignUpPassword}
              />

              {signUpBusy ? (
                <ActivityIndicator
                  style={{ marginTop: 16 }}
                  color={BRAND}
                />
              ) : (
                <TouchableOpacity
                  style={s.primaryBtn}
                  onPress={signUp}
                  activeOpacity={0.85}
                >
                  <Text style={s.primaryBtnText}>Create account</Text>
                </TouchableOpacity>
              )}

              <TouchableOpacity
                style={s.linkBtn}
                onPress={() => setSignUpVisible(false)}
              >
                <Text style={s.linkBtnText}>
                  Already have an account? Log In
                </Text>
              </TouchableOpacity>
            </ScrollView>
          </KeyboardAvoidingView>
        </SafeAreaView>
      </Modal>
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  safe: {
    flex: 1,
    backgroundColor: "#fff",
  },
  scroll: {
    flexGrow: 1,
    paddingHorizontal: 28,
    paddingTop: 40,
    paddingBottom: 32,
    justifyContent: "center",
  },
  logoWrap: {
    alignItems: "center",
    marginBottom: 24,
  },
  logo: {
    width: 260,
    height: 86,
  },
  spinO: {
    width: 48,
    height: 48,
    marginTop: 12,
    opacity: 0.55,
  },
  tagline: {
    fontSize: 22,
    fontWeight: "800",
    color: "#111",
    textAlign: "center",
  },
  sub: {
    fontSize: 16,
    color: "#667085",
    fontWeight: "600",
    textAlign: "center",
    marginTop: 6,
    marginBottom: 32,
  },
  input: {
    borderWidth: 1,
    borderColor: "#e0e0e0",
    borderRadius: 12,
    padding: 14,
    marginBottom: 12,
    backgroundColor: "#fafafa",
    fontSize: 16,
    color: "#111",
  },
  ctaSection: {
    gap: 12,
  },
  primaryBtn: {
    backgroundColor: BRAND,
    borderRadius: 14,
    paddingVertical: 16,
    alignItems: "center",
  },
  primaryBtnText: {
    color: "#fff",
    fontWeight: "900",
    fontSize: 17,
  },
  outlineBtn: {
    borderWidth: 2,
    borderColor: BRAND,
    borderRadius: 14,
    paddingVertical: 15,
    alignItems: "center",
  },
  outlineBtnText: {
    color: BRAND,
    fontWeight: "900",
    fontSize: 17,
  },
  linkBtn: {
    paddingVertical: 12,
    alignItems: "center",
  },
  linkBtnText: {
    color: "#667085",
    fontWeight: "700",
    fontSize: 15,
  },
  modalSafe: {
    flex: 1,
    backgroundColor: "#fff",
  },
  modalScroll: {
    flexGrow: 1,
    padding: 24,
  },
  modalHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 8,
  },
  modalTitle: {
    fontSize: 26,
    fontWeight: "900",
    color: "#111",
  },
  modalClose: {
    fontSize: 20,
    color: "#667085",
    fontWeight: "700",
  },
  modalSubtitle: {
    color: "#667085",
    fontWeight: "600",
    marginBottom: 20,
    lineHeight: 20,
  },
});

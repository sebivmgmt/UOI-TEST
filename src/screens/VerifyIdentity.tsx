// src/screens/VerifyIdentity.tsx
import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator,
  Alert,
  FlatList,
  Modal,
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
const RED = "#D9534F";
const BLUE = "#3B82F6";
const AMBER = "#B7791F";
const BG = "#F5F7F9";
const BORDER = "#E5E7EB";
const TEXT = "#111827";
const MUTED = "#6B7280";

const US_STATES = [
  { code: "AL", name: "Alabama" },
  { code: "AK", name: "Alaska" },
  { code: "AZ", name: "Arizona" },
  { code: "AR", name: "Arkansas" },
  { code: "CA", name: "California" },
  { code: "CO", name: "Colorado" },
  { code: "CT", name: "Connecticut" },
  { code: "DE", name: "Delaware" },
  { code: "DC", name: "District of Columbia" },
  { code: "FL", name: "Florida" },
  { code: "GA", name: "Georgia" },
  { code: "HI", name: "Hawaii" },
  { code: "ID", name: "Idaho" },
  { code: "IL", name: "Illinois" },
  { code: "IN", name: "Indiana" },
  { code: "IA", name: "Iowa" },
  { code: "KS", name: "Kansas" },
  { code: "KY", name: "Kentucky" },
  { code: "LA", name: "Louisiana" },
  { code: "ME", name: "Maine" },
  { code: "MD", name: "Maryland" },
  { code: "MA", name: "Massachusetts" },
  { code: "MI", name: "Michigan" },
  { code: "MN", name: "Minnesota" },
  { code: "MS", name: "Mississippi" },
  { code: "MO", name: "Missouri" },
  { code: "MT", name: "Montana" },
  { code: "NE", name: "Nebraska" },
  { code: "NV", name: "Nevada" },
  { code: "NH", name: "New Hampshire" },
  { code: "NJ", name: "New Jersey" },
  { code: "NM", name: "New Mexico" },
  { code: "NY", name: "New York" },
  { code: "NC", name: "North Carolina" },
  { code: "ND", name: "North Dakota" },
  { code: "OH", name: "Ohio" },
  { code: "OK", name: "Oklahoma" },
  { code: "OR", name: "Oregon" },
  { code: "PA", name: "Pennsylvania" },
  { code: "RI", name: "Rhode Island" },
  { code: "SC", name: "South Carolina" },
  { code: "SD", name: "South Dakota" },
  { code: "TN", name: "Tennessee" },
  { code: "TX", name: "Texas" },
  { code: "UT", name: "Utah" },
  { code: "VT", name: "Vermont" },
  { code: "VA", name: "Virginia" },
  { code: "WA", name: "Washington" },
  { code: "WV", name: "West Virginia" },
  { code: "WI", name: "Wisconsin" },
  { code: "WY", name: "Wyoming" },
] as const;

const STEPS = ["Name", "Date of Birth", "Address", "SSN", "Review"] as const;
const STATUS_ONLY = new Set(["verified", "pending", "suspended", "deactivated"]);

function normalizeStatus(raw?: string | null): string {
  const s = (raw ?? "").trim().toLowerCase();

  if (s === "verified") return "verified";
  if (s === "retry") return "retry";
  if (s === "document") return "document";
  if (s === "kba") return "kba";
  if (s === "suspended") return "suspended";
  if (s === "deactivated") return "deactivated";
  if (["pending", "review", "in_review", "received", "submitted"].includes(s)) {
    return "pending";
  }

  return "unverified";
}

function formatDobInput(value: string): string {
  const digits = value.replace(/\D/g, "").slice(0, 8);

  if (digits.length <= 2) return digits;
  if (digits.length <= 4) return `${digits.slice(0, 2)}/${digits.slice(2)}`;
  return `${digits.slice(0, 2)}/${digits.slice(2, 4)}/${digits.slice(4)}`;
}

function isoToDob(value?: string | null): string {
  if (!value) return "";

  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  return match ? `${match[2]}/${match[3]}/${match[1]}` : value;
}

function dobToIso(value: string): string | null {
  const trimmed = value.trim();

  if (/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) return trimmed;
  if (!/^\d{2}\/\d{2}\/\d{4}$/.test(trimmed)) return null;

  const [mm, dd, yyyy] = trimmed.split("/");
  return `${yyyy}-${mm}-${dd}`;
}

function isValidDob(value: string): boolean {
  const trimmed = value.trim();

  if (!/^\d{2}\/\d{2}\/\d{4}$/.test(trimmed)) return false;

  const [mm, dd, yyyy] = trimmed.split("/").map(Number);
  const date = new Date(yyyy, mm - 1, dd);

  if (
    date.getFullYear() !== yyyy ||
    date.getMonth() !== mm - 1 ||
    date.getDate() !== dd
  ) {
    return false;
  }

  const now = new Date();
  const eighteenthBirthday = new Date(now.getFullYear() - 18, now.getMonth(), now.getDate());
  return date <= eighteenthBirthday;
}

export default function VerifyIdentity({ navigation }: any) {
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [step, setStep] = useState(0);

  const [userId, setUserId] = useState<string | null>(null);
  const [identityStatus, setIdentityStatus] = useState<string | null>(null);
  const [dwollaStatus, setDwollaStatus] = useState<string | null>(null);
  const [email, setEmail] = useState<string | null>(null);
  const [phone, setPhone] = useState<string | null>(null);

  const [firstLegalName, setFirstLegalName] = useState("");
  const [lastLegalName, setLastLegalName] = useState("");
  const [dob, setDob] = useState("");
  const [streetAddress, setStreetAddress] = useState("");
  const [address2, setAddress2] = useState("");
  const [city, setCity] = useState("");
  const [stateCode, setStateCode] = useState("");
  const [postalCode, setPostalCode] = useState("");
  const [ssnLast4, setSsnLast4] = useState("");

  const [stateModal, setStateModal] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  const scrollRef = useRef<ScrollView>(null);

  async function refreshStatus() {
    if (!userId) return;
    setRefreshing(true);
    try {
      const { data } = await supabase
        .from("profiles")
        .select("identity_status, dwolla_customer_status")
        .eq("id", userId)
        .single();

      if (data) {
        const profile = data as any;
        setIdentityStatus(profile.identity_status ?? null);
        setDwollaStatus(profile.dwolla_customer_status ?? null);

        const next = normalizeStatus(profile.dwolla_customer_status || profile.identity_status);
        if (next === "verified") {
          const { data: sessionData } = await supabase.auth.getSession();
          if (sessionData.session) {
            await supabase.auth.setSession({
              access_token: sessionData.session.access_token,
              refresh_token: sessionData.session.refresh_token,
            });
          }
        }
      }
    } catch {}
    finally {
      setRefreshing(false);
    }
  }

  function scrollToEnd(delay = 250) {
    setTimeout(() => {
      scrollRef.current?.scrollToEnd({ animated: true });
    }, delay);
  }

  function goToStep(nextStep: number) {
    setStep(nextStep);

    if (nextStep === 2 || nextStep === 3) {
      scrollToEnd(350);
    } else {
      setTimeout(() => {
        scrollRef.current?.scrollTo({ y: 0, animated: true });
      }, 100);
    }
  }

  useEffect(() => {
    let alive = true;

    async function loadProfile() {
      setLoading(true);

      const { data: authData } = await supabase.auth.getUser();
      const user = authData.user;

      if (!alive) return;

      setUserId(user?.id ?? null);

      if (!user?.id) {
        setLoading(false);
        return;
      }

      const { data, error } = await supabase
        .from("profiles")
        .select(
          "id,full_name,email,phone,dob,address_1,address_2,city,state,postal_code,ssn_last_4,identity_status,dwolla_customer_status"
        )
        .eq("id", user.id)
        .single();

      if (!alive) return;

      if (!error && data) {
        const profile = data as any;
        const nameParts = String(profile.full_name ?? "").trim().split(/\s+/).filter(Boolean);

        setEmail(profile.email ?? user.email ?? null);
        setPhone(profile.phone ?? null);
        setIdentityStatus(profile.identity_status ?? null);
        setDwollaStatus(profile.dwolla_customer_status ?? null);

        setFirstLegalName(nameParts[0] ?? "");
        setLastLegalName(nameParts.slice(1).join(" "));
        setDob(isoToDob(profile.dob));
        setStreetAddress(profile.address_1 ?? "");
        setAddress2(profile.address_2 ?? "");
        setCity(profile.city ?? "");
        setStateCode(String(profile.state ?? "").toUpperCase());
        setPostalCode(profile.postal_code ?? "");
        setSsnLast4(profile.ssn_last_4 ?? "");
      } else {
        setEmail(user.email ?? null);
      }

      setLoading(false);
    }

    void loadProfile();

    return () => {
      alive = false;
    };
  }, []);

  const status = useMemo(
    () => normalizeStatus(dwollaStatus || identityStatus),
    [dwollaStatus, identityStatus]
  );

  const statusBadge = useMemo(() => {
    switch (status) {
      case "verified":
        return {
          label: "Identity Verified",
          bg: "#EAF8EA",
          color: BRAND,
          desc: "Your identity is verified and ready for bank setup.",
        };
      case "retry":
        return {
          label: "Retry Needed",
          bg: "#FFF7E6",
          color: AMBER,
          desc: "Some information needs correction. Please update and resubmit.",
        };
      case "document":
        return {
          label: "Document Required",
          bg: "#FFF7E6",
          color: AMBER,
          desc: "Additional documents are needed. Our team will follow up.",
        };
      case "kba":
        return {
          label: "Additional Verification Required",
          bg: "#FFF7E6",
          color: AMBER,
          desc: "Additional identity verification is required.",
        };
      case "suspended":
        return {
          label: "Account Under Review",
          bg: "#FDECEC",
          color: RED,
          desc: "Your account is under review. Contact support@iou.llc.",
        };
      case "deactivated":
        return {
          label: "Account Deactivated",
          bg: "#FDECEC",
          color: RED,
          desc: "Your account is deactivated. Contact support@iou.llc.",
        };
      case "pending":
        return {
          label: "Under Review",
          bg: "#EEF4FF",
          color: BLUE,
          desc: "Your information is being reviewed. This usually takes 1–2 business days.",
        };
      default:
        return {
          label: "Not Submitted",
          bg: "#FDECEC",
          color: RED,
          desc: "Complete the steps below to verify your identity.",
        };
    }
  }, [status]);

  const valid = useMemo(
    () => ({
      firstName: firstLegalName.trim().length >= 2,
      lastName: lastLegalName.trim().length >= 2,
      dob: isValidDob(dob),
      street: streetAddress.trim().length >= 4,
      city: city.trim().length >= 2,
      state: US_STATES.some((item) => item.code === stateCode),
      zip: /^\d{5}(-\d{4})?$/.test(postalCode.trim()),
      ssn: /^\d{4}$/.test(ssnLast4.trim()),
    }),
    [firstLegalName, lastLegalName, dob, streetAddress, city, stateCode, postalCode, ssnLast4]
  );

  const allValid = Object.values(valid).every(Boolean);

  const stepOk = useMemo(() => {
    if (step === 0) return valid.firstName && valid.lastName;
    if (step === 1) return valid.dob;
    if (step === 2) return valid.street && valid.city && valid.state && valid.zip;
    if (step === 3) return valid.ssn;
    return allValid;
  }, [allValid, step, valid]);

  function goBack() {
    if (step > 0) {
      goToStep(step - 1);
      return;
    }

    navigation.goBack();
  }

  function goNext() {
    if (step < STEPS.length - 1) {
      goToStep(step + 1);
      return;
    }

    void submit();
  }

  async function submit() {
    if (!userId || !allValid) return;

    const isoDob = dobToIso(dob);

    if (!isoDob) {
      Alert.alert("Invalid date", "Use MM/DD/YYYY format.");
      return;
    }

    setBusy(true);

    try {
      // identity_status, identity_verified_at, and dwolla_customer_status are
      // set server-side by create-dwolla-customer after Dwolla confirms the submission.
      const profilePayload = {
        full_name: `${firstLegalName.trim()} ${lastLegalName.trim()}`,
        dob: isoDob,
        address_1: streetAddress.trim(),
        address_2: address2.trim() || null,
        city: city.trim(),
        state: stateCode,
        postal_code: postalCode.trim(),
        ssn_last_4: ssnLast4.trim(),
      };

      console.log("[submit] saving profile", { userId, payloadKeys: Object.keys(profilePayload) });

      const { error: saveError } = await supabase
        .from("profiles")
        .update(profilePayload)
        .eq("id", userId);

      if (saveError) {
        console.error("[submit] profile save failed", { userId, error: saveError });
        throw new Error(`Profile save failed: ${saveError.message}`);
      }

      const fnName = "create-dwolla-customer";
      console.log("[submit] invoking", fnName, { userId, payloadKeys: [] });

      const { data, error: fnError } = await supabase.functions.invoke(fnName, {
        body: {},
      });

      if (fnError) {
        let fnBody: Record<string, unknown> | null = null;
        try {
          const ctx = (fnError as unknown as { context?: Response }).context;
          if (typeof ctx?.json === "function") {
            fnBody = await ctx.json();
          } else if (typeof ctx?.text === "function") {
            fnBody = { raw: await ctx.text() };
          }
        } catch {}

        console.error("[submit] edge function failed", {
          fn: fnName,
          userId,
          errorMessage: fnError.message,
          errorName: (fnError as unknown as { name?: string }).name,
          responseStatus: (fnError as unknown as { context?: Response }).context?.status,
          responseBody: fnBody,
          returnedData: data,
        });

        const displayMessage = (fnBody?.error as string | undefined) ?? fnError.message ?? "Verification service error";
        const stageSuffix = fnBody?.stage ? ` (stage: ${fnBody.stage})` : "";
        throw new Error(`${displayMessage}${stageSuffix}`);
      }

      console.log("[submit] edge function response", { fn: fnName, data });

      const nextStatus = normalizeStatus(
        (data as any)?.identityStatus || (data as any)?.dwollaCustomerStatus || "submitted"
      );

      setIdentityStatus((data as any)?.identityStatus ?? "submitted");
      setDwollaStatus((data as any)?.dwollaCustomerStatus ?? null);

      if (nextStatus === "verified") {
        Alert.alert("Verified", "Your identity is verified.", [
          { text: "OK", onPress: () => navigation.replace("LinkBank") },
        ]);
        return;
      }

      if (nextStatus === "document") {
        Alert.alert("Document required", "Additional documents are needed. Our team will follow up.");
        return;
      }

      if (nextStatus === "retry") {
        Alert.alert("Retry needed", "Some information needs correction. Please review and resubmit.");
        return;
      }

      if (nextStatus === "suspended" || nextStatus === "deactivated") {
        Alert.alert("Needs review", "Your status requires manual review before continuing.");
        return;
      }

      Alert.alert("Submitted", "Your identity was submitted and may need additional review.", [
        { text: "OK", onPress: () => navigation.replace("LinkBank") },
      ]);
    } catch (error: any) {
      Alert.alert("Error", error?.message || "An error occurred. Please try again.");
    } finally {
      setBusy(false);
    }
  }

  function renderName() {
    return (
      <View style={s.card}>
        <Text style={s.cardTitle}>What is your legal name?</Text>
        <Text style={s.cardSub}>
          Enter your name exactly as it appears on your government-issued ID.
        </Text>

        <Text style={s.label}>First legal name</Text>
        <TextInput
          style={s.input}
          placeholder="First name"
          placeholderTextColor="#9CA3AF"
          value={firstLegalName}
          onChangeText={(text) => setFirstLegalName(text)}
          editable
          autoCorrect={false}
          autoCapitalize="words"
        />

        <Text style={s.label}>Last legal name</Text>
        <TextInput
          style={s.input}
          placeholder="Last name"
          placeholderTextColor="#9CA3AF"
          value={lastLegalName}
          onChangeText={(text) => setLastLegalName(text)}
          editable
          autoCorrect={false}
          autoCapitalize="words"
        />
      </View>
    );
  }

  function renderDob() {
    return (
      <View style={s.card}>
        <Text style={s.cardTitle}>Date of birth</Text>
        <Text style={s.cardSub}>You must be 18 or older. Use MM/DD/YYYY.</Text>

        <Text style={s.label}>Date of birth</Text>
        <TextInput
          style={s.input}
          placeholder="MM/DD/YYYY"
          placeholderTextColor="#9CA3AF"
          value={dob}
          onChangeText={(text) => setDob(formatDobInput(text))}
          editable
          autoCorrect={false}
          keyboardType="number-pad"
          maxLength={10}
        />
      </View>
    );
  }

  function renderAddress() {
    return (
      <View style={s.card}>
        <Text style={s.cardTitle}>Home address</Text>
        <Text style={s.cardSub}>Use your current U.S. residential address.</Text>

        <Text style={s.label}>Street address</Text>
        <TextInput
          style={s.input}
          placeholder="123 Main St"
          placeholderTextColor="#9CA3AF"
          value={streetAddress}
          onChangeText={(text) => setStreetAddress(text)}
          editable
          autoCorrect={false}
          autoCapitalize="words"
        />

        <Text style={s.label}>Address line 2 (optional)</Text>
        <TextInput
          style={s.input}
          placeholder="Apt, suite, unit"
          placeholderTextColor="#9CA3AF"
          value={address2}
          onChangeText={(text) => setAddress2(text)}
          editable
          autoCorrect={false}
          autoCapitalize="words"
        />

        <Text style={s.label}>City</Text>
        <TextInput
          style={s.input}
          placeholder="City"
          placeholderTextColor="#9CA3AF"
          value={city}
          onChangeText={(text) => setCity(text)}
          editable
          autoCorrect={false}
          autoCapitalize="words"
        />

        <View style={s.row}>
          <View style={{ flex: 1.3 }}>
            <Text style={s.label}>State</Text>
            <TouchableOpacity
              style={[s.input, s.stateButton]}
              onPress={() => {
                scrollToEnd(180);
                setStateModal(true);
              }}
              activeOpacity={0.8}
            >
              {stateCode ? (
                <Text style={s.stateText}>
                  {stateCode}{"  "}
                  <Text style={s.stateName}>
                    {US_STATES.find((item) => item.code === stateCode)?.name ?? ""}
                  </Text>
                </Text>
              ) : (
                <Text style={s.placeholderText}>Select state</Text>
              )}
            </TouchableOpacity>
          </View>

          <View style={{ flex: 0.7 }}>
            <Text style={s.label}>ZIP code</Text>
            <TextInput
              style={s.input}
              placeholder="02150"
              placeholderTextColor="#9CA3AF"
              value={postalCode}
              onChangeText={(text) => setPostalCode(text)}
              onFocus={() => scrollToEnd(180)}
              editable
              autoCorrect={false}
              keyboardType="number-pad"
              maxLength={10}
            />
          </View>
        </View>
      </View>
    );
  }

  function renderSsn() {
    return (
      <View style={s.card} onTouchStart={() => scrollToEnd(180)}>
        <Text style={s.cardTitle}>Last 4 of your SSN</Text>
        <Text style={s.cardSub}>
          Required for identity verification. This is never shown to other users.
        </Text>

        <Text style={s.label}>Last 4 digits</Text>
        <TextInput
          style={s.input}
          placeholder="••••"
          placeholderTextColor="#9CA3AF"
          value={ssnLast4}
          onChangeText={(text) => setSsnLast4(text.replace(/\D/g, "").slice(0, 4))}
          onFocus={() => scrollToEnd(180)}
          editable
          autoCorrect={false}
          keyboardType="number-pad"
          secureTextEntry
          maxLength={4}
        />
      </View>
    );
  }

  function ReviewRow({ label, value }: { label: string; value: string }) {
    return (
      <View style={s.reviewRow}>
        <Text style={s.reviewLabel}>{label}</Text>
        <Text style={s.reviewValue}>{value}</Text>
      </View>
    );
  }

  function renderReview() {
    const fullName = `${firstLegalName.trim()} ${lastLegalName.trim()}`.trim() || "—";
    const addressLine = [streetAddress.trim(), address2.trim()].filter(Boolean).join(", ");
    const cityLine = [city.trim(), stateCode, postalCode.trim()].filter(Boolean).join(" ");

    return (
      <View style={s.card}>
        <Text style={s.cardTitle}>Review your information</Text>
        <Text style={s.cardSub}>Make sure everything is accurate before submitting.</Text>

        <View style={s.reviewTable}>
          <ReviewRow label="Legal name" value={fullName} />
          <ReviewRow label="Date of birth" value={dob.trim() || "—"} />
          <ReviewRow
            label="Address"
            value={[addressLine, cityLine].filter(Boolean).join("\n") || "—"}
          />
          <ReviewRow label="SSN" value={`••••${ssnLast4.trim() || "—"}`} />
          <ReviewRow label="Contact" value={[email, phone].filter(Boolean).join("\n") || "—"} />
        </View>

        <Text style={s.disclosure}>
          By submitting, you confirm this information is accurate and authorize IOU to verify your identity.
        </Text>
      </View>
    );
  }

  function renderCards() {
    return (
      <>
        <View style={step === 0 ? undefined : s.hiddenStep}>{renderName()}</View>
        <View style={step === 1 ? undefined : s.hiddenStep}>{renderDob()}</View>
        <View style={step === 2 ? undefined : s.hiddenStep}>{renderAddress()}</View>
        <View style={step === 3 ? undefined : s.hiddenStep}>{renderSsn()}</View>
        <View style={step === 4 ? undefined : s.hiddenStep}>{renderReview()}</View>
      </>
    );
  }

  if (loading) {
    return (
      <View style={s.center}>
        <ActivityIndicator color={BRAND} />
      </View>
    );
  }

  if (!userId) {
    return (
      <View style={s.center}>
        <Text style={s.emptyTitle}>Not signed in</Text>
        <Text style={s.emptySub}>Sign in to verify your identity.</Text>
      </View>
    );
  }

  if (STATUS_ONLY.has(status)) {
    return (
      <View style={s.screen}>
        <ScrollView contentContainerStyle={s.statusScroll} showsVerticalScrollIndicator={false}>
          <View style={s.reviewCard}>
            <View style={[s.pill, { backgroundColor: statusBadge.bg }]}>
              <Text style={[s.pillText, { color: statusBadge.color }]}>{statusBadge.label}</Text>
            </View>

            <Text style={s.reviewTitle}>Identity review in progress</Text>

            <View style={s.reviewStatusRow}>
              <Text style={s.reviewStatusLabel}>Status</Text>
              <Text style={[s.reviewStatusValue, { color: statusBadge.color }]}>
                {statusBadge.label}
              </Text>
            </View>

            <Text style={s.reviewBody}>
              Your identity information has been securely submitted and is currently being
              reviewed. This process is typically completed within 1–2 business days.
            </Text>

            <View style={s.reviewDivider} />

            <Text style={s.reviewNextTitle}>What happens next</Text>
            <View style={s.reviewNextList}>
              <Text style={s.reviewNextItem}>
                {"·  "}We verify your name, date of birth, and address with trusted identity providers.
              </Text>
              <Text style={s.reviewNextItem}>
                {"·  "}Once approved, you can link a bank account and start sending and receiving money.
              </Text>
              <Text style={s.reviewNextItem}>
                {"·  "}You can safely close the app — your status will update automatically when review is complete.
              </Text>
            </View>

            <TouchableOpacity
              style={s.statusPrimary}
              onPress={() =>
                navigation.canGoBack()
                  ? navigation.goBack()
                  : navigation.navigate("Profile")
              }
              activeOpacity={0.8}
            >
              <Text style={s.statusPrimaryText}>Back to Profile</Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={[s.statusSecondary, refreshing && s.statusSecondaryDisabled]}
              onPress={() => void refreshStatus()}
              disabled={refreshing}
              activeOpacity={0.8}
            >
              {refreshing ? (
                <ActivityIndicator color={BRAND} size="small" />
              ) : (
                <Text style={s.statusSecondaryText}>Refresh Status</Text>
              )}
            </TouchableOpacity>
          </View>
        </ScrollView>
      </View>
    );
  }

  return (
    <View style={s.screen}>
      <View style={s.progressWrap}>
        <View style={s.progressTrack}>
          {STEPS.map((_, index) => (
            <View
              key={STEPS[index]}
              style={[
                s.progressDot,
                index < step && s.progressDone,
                index === step && s.progressActive,
              ]}
            />
          ))}
        </View>
        <Text style={s.progressLabel}>
          {STEPS[step]} · {step + 1} of {STEPS.length}
        </Text>
      </View>

      {status !== "unverified" && (
        <View style={[s.banner, { backgroundColor: statusBadge.bg, borderColor: `${statusBadge.color}55` }]}>
          <Text style={[s.bannerTitle, { color: statusBadge.color }]}>{statusBadge.label}</Text>
          <Text style={[s.bannerDesc, { color: statusBadge.color }]}>{statusBadge.desc}</Text>
        </View>
      )}

      <ScrollView
        ref={scrollRef}
        contentContainerStyle={s.scroll}
        keyboardShouldPersistTaps="always"
        keyboardDismissMode="none"
        showsVerticalScrollIndicator={false}
        removeClippedSubviews={false}
      >
        {renderCards()}

        <View style={s.controls}>
          <TouchableOpacity style={s.backButton} onPress={goBack} activeOpacity={0.8}>
            <Text style={s.backText}>{step === 0 ? "Cancel" : "Back"}</Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={[s.nextButton, (!stepOk || busy) && s.nextButtonDisabled]}
            onPress={goNext}
            disabled={!stepOk || busy}
            activeOpacity={0.8}
          >
            {busy && step === STEPS.length - 1 ? (
              <ActivityIndicator color="#fff" size="small" />
            ) : (
              <Text style={s.nextText}>{step === STEPS.length - 1 ? "Submit" : "Continue"}</Text>
            )}
          </TouchableOpacity>
        </View>
      </ScrollView>

      <Modal
        visible={stateModal}
        animationType="slide"
        transparent
        onRequestClose={() => setStateModal(false)}
      >
        <View style={s.modalBackdrop}>
          <TouchableOpacity style={{ flex: 1 }} activeOpacity={1} onPress={() => setStateModal(false)} />
          <View style={s.sheet}>
            <View style={s.sheetHeader}>
              <Text style={s.sheetTitle}>Select state</Text>
              <TouchableOpacity onPress={() => setStateModal(false)}>
                <Text style={s.sheetDone}>Done</Text>
              </TouchableOpacity>
            </View>

            <FlatList
              data={US_STATES}
              keyExtractor={(item) => item.code}
              showsVerticalScrollIndicator={false}
              renderItem={({ item }) => (
                <TouchableOpacity
                  style={[s.stateRow, item.code === stateCode && s.stateRowActive]}
                  onPress={() => {
                    setStateCode(item.code);
                    setStateModal(false);
                  }}
                  activeOpacity={0.7}
                >
                  <Text style={[s.stateCode, item.code === stateCode && { color: BRAND }]}>
                    {item.code}
                  </Text>
                  <Text style={[s.stateName2, item.code === stateCode && { color: BRAND }]}>
                    {item.name}
                  </Text>
                </TouchableOpacity>
              )}
              ItemSeparatorComponent={() => <View style={s.separator} />}
            />
          </View>
        </View>
      </Modal>
    </View>
  );
}

const s = StyleSheet.create({
  screen: {
    flex: 1,
    backgroundColor: BG,
  },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    padding: 24,
    backgroundColor: BG,
  },
  emptyTitle: {
    fontSize: 20,
    fontWeight: "800",
    color: TEXT,
  },
  emptySub: {
    marginTop: 8,
    fontSize: 15,
    color: MUTED,
    textAlign: "center",
  },
  progressWrap: {
    paddingHorizontal: 16,
    paddingTop: 14,
    paddingBottom: 8,
    gap: 6,
  },
  progressTrack: {
    flexDirection: "row",
    gap: 5,
  },
  progressDot: {
    flex: 1,
    height: 4,
    borderRadius: 2,
    backgroundColor: BORDER,
  },
  progressDone: {
    backgroundColor: BRAND,
    opacity: 0.4,
  },
  progressActive: {
    backgroundColor: BRAND,
  },
  progressLabel: {
    fontSize: 11,
    fontWeight: "700",
    color: MUTED,
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
  banner: {
    marginHorizontal: 16,
    borderRadius: 10,
    padding: 12,
    borderWidth: 1,
    gap: 3,
  },
  bannerTitle: {
    fontSize: 12,
    fontWeight: "800",
    textTransform: "uppercase",
    letterSpacing: 0.4,
  },
  bannerDesc: {
    fontSize: 13,
    fontWeight: "500",
    lineHeight: 18,
    opacity: 0.9,
  },
  statusScroll: {
    padding: 20,
    gap: 12,
  },
  scroll: {
    padding: 16,
    paddingBottom: Platform.OS === "ios" ? 240 : 200,
  },
  hiddenStep: {
    display: "none",
  },
  card: {
    backgroundColor: "#fff",
    borderRadius: 14,
    borderWidth: 1,
    borderColor: BORDER,
    padding: 18,
    gap: 8,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.05,
    shadowRadius: 6,
    elevation: 2,
  },
  cardTitle: {
    fontSize: 20,
    fontWeight: "900",
    color: TEXT,
  },
  cardSub: {
    fontSize: 13,
    fontWeight: "500",
    color: MUTED,
    lineHeight: 18,
  },
  label: {
    fontSize: 13,
    fontWeight: "700",
    color: "#374151",
    marginTop: 4,
  },
  input: {
    borderWidth: 1,
    borderColor: BORDER,
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 13,
    backgroundColor: "#F9FAFB",
    color: TEXT,
    fontSize: 16,
    fontWeight: "500",
  },
  row: {
    flexDirection: "row",
    gap: 10,
  },
  stateButton: {
    justifyContent: "center",
  },
  stateText: {
    fontSize: 15,
    fontWeight: "600",
    color: TEXT,
  },
  stateName: {
    fontSize: 14,
    fontWeight: "400",
    color: MUTED,
  },
  placeholderText: {
    fontSize: 15,
    color: "#9CA3AF",
  },
  reviewTable: {
    borderRadius: 10,
    borderWidth: 1,
    borderColor: BORDER,
    overflow: "hidden",
    marginTop: 4,
  },
  reviewRow: {
    flexDirection: "row",
    paddingVertical: 11,
    paddingHorizontal: 14,
    gap: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: BORDER,
  },
  reviewLabel: {
    width: 88,
    fontSize: 13,
    fontWeight: "700",
    color: MUTED,
    paddingTop: 1,
  },
  reviewValue: {
    flex: 1,
    fontSize: 14,
    fontWeight: "600",
    color: TEXT,
    lineHeight: 20,
  },
  disclosure: {
    fontSize: 12,
    color: MUTED,
    lineHeight: 17,
    textAlign: "center",
    paddingHorizontal: 4,
    marginTop: 4,
  },
  controls: {
    flexDirection: "row",
    gap: 10,
    marginTop: 16,
  },
  backButton: {
    flex: 1,
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: "center",
    backgroundColor: "#F3F4F6",
  },
  backText: {
    fontSize: 15,
    fontWeight: "700",
    color: MUTED,
  },
  nextButton: {
    flex: 2,
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: "center",
    backgroundColor: BRAND,
  },
  nextButtonDisabled: {
    opacity: 0.4,
  },
  nextText: {
    fontSize: 16,
    fontWeight: "800",
    color: "#fff",
  },
  pill: {
    alignSelf: "flex-start",
    borderRadius: 999,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  pillText: {
    fontSize: 12,
    fontWeight: "800",
  },
  modalBackdrop: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.4)",
    justifyContent: "flex-end",
  },
  sheet: {
    backgroundColor: "#fff",
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    maxHeight: "70%",
    paddingBottom: Platform.OS === "ios" ? 34 : 16,
  },
  sheetHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 20,
    paddingVertical: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: BORDER,
  },
  sheetTitle: {
    fontSize: 17,
    fontWeight: "700",
    color: TEXT,
  },
  sheetDone: {
    fontSize: 16,
    fontWeight: "700",
    color: BRAND,
  },
  stateRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingVertical: 13,
    paddingHorizontal: 20,
    gap: 14,
  },
  stateRowActive: {
    backgroundColor: "#F0F9F0",
  },
  stateCode: {
    width: 32,
    fontSize: 14,
    fontWeight: "800",
    color: MUTED,
  },
  stateName2: {
    flex: 1,
    fontSize: 16,
    fontWeight: "500",
    color: TEXT,
  },
  separator: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: BORDER,
    marginLeft: 20,
  },
  supportText: {
    fontSize: 13,
    color: MUTED,
    lineHeight: 18,
    textAlign: "center",
    paddingHorizontal: 4,
    marginTop: 4,
  },
  statusPrimary: {
    backgroundColor: BRAND,
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: "center",
    marginTop: 8,
  },
  statusPrimaryText: {
    fontSize: 15,
    fontWeight: "700",
    color: "#fff",
  },
  statusSecondary: {
    backgroundColor: "#F3F4F6",
    borderRadius: 12,
    paddingVertical: 13,
    alignItems: "center",
    marginTop: 8,
  },
  statusSecondaryDisabled: {
    opacity: 0.5,
  },
  statusSecondaryText: {
    fontSize: 15,
    fontWeight: "700",
    color: MUTED,
  },
  reviewCard: {
    backgroundColor: "#fff",
    borderRadius: 16,
    borderWidth: 1,
    borderColor: BORDER,
    padding: 24,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.06,
    shadowRadius: 10,
    elevation: 3,
  },
  reviewTitle: {
    fontSize: 22,
    fontWeight: "800",
    color: TEXT,
    marginTop: 12,
    lineHeight: 28,
  },
  reviewStatusRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    backgroundColor: "#F9FAFB",
    borderRadius: 10,
    paddingVertical: 10,
    paddingHorizontal: 14,
    marginTop: 14,
  },
  reviewStatusLabel: {
    fontSize: 13,
    fontWeight: "700",
    color: MUTED,
  },
  reviewStatusValue: {
    fontSize: 13,
    fontWeight: "700",
  },
  reviewBody: {
    fontSize: 14,
    color: MUTED,
    lineHeight: 21,
    marginTop: 16,
  },
  reviewDivider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: BORDER,
    marginTop: 22,
    marginBottom: 4,
  },
  reviewNextTitle: {
    fontSize: 11,
    fontWeight: "800",
    color: MUTED,
    textTransform: "uppercase",
    letterSpacing: 0.6,
    marginTop: 14,
  },
  reviewNextList: {
    marginTop: 10,
    gap: 10,
  },
  reviewNextItem: {
    fontSize: 13,
    color: MUTED,
    lineHeight: 19,
  },
});
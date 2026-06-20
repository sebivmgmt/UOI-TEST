// src/screens/PreviewSign.tsx

import React, { useCallback, useMemo, useRef, useState } from "react";
import {
  View,
  Text,
  ScrollView,
  ActivityIndicator,
  Alert,
  TouchableOpacity,
  StyleSheet,
  Share,
  TextInput,
  KeyboardAvoidingView,
  Platform,
  Modal,
} from "react-native";
import { useFocusEffect } from "@react-navigation/native";
import { supabase } from "../supabase";

type Frequency = "weekly" | "biweekly" | "monthly";

type IouRow = {
  id: string;
  lender_id: string;
  borrower_id: string;
  principal_cents: number;
  apr_bps: number;
  start_date: string | null;
  term_months: number;
  frequency: Frequency;
  status: string;
  title: string | null;
  contract_text: string | null;
  activated_at: string | null;
  requested_action_by: string | null;
};

type ProfileLite = {
  id: string;
  public_name: string | null;
};

type BorrowerTrust = {
  iou_score?: number | null;
  active_exposure_points?: number | null;
  strike_count?: number | null;
};

type PaymentPreviewRow = {
  id: string;
  amount_cents: number;
  due: string;
  status: string;
};

const TERMS_VERSION = "2026-05-17";
const PRIVACY_VERSION = "2026-05-17";

const TERMS_TEXT = `IOU Terms of Service
Effective: ${TERMS_VERSION}

1. Agreement to Terms
By using the IOU app, you agree to these Terms of Service. If you do not agree, do not use the app.

2. Description of Service
IOU is a personal lending agreement tool that helps individuals create, track, and manage loan agreements between people they know and trust. IOU is not a bank, lender, debt collector, financial institution, or payment processor.

3. Not a Financial Institution
IOU LLC is not a lender, creditor, or financial institution. IOU does not provide credit, guarantee repayment, or enforce loan agreements. All loans created through IOU are personal agreements between the lender and borrower. IOU does not participate as a party to any loan agreement.

4. Platform Fee
IOU charges a platform fee of 0.7% of the principal loan amount to create and manage the agreement. This fee is charged to the borrower and is separate from any interest agreed upon between the parties.

5. Electronic Records and Signatures
You consent to receive all agreements, disclosures, and notices electronically. Your typed signature constitutes a legally binding electronic signature to the extent permitted by applicable law.

6. User Responsibilities
You are solely responsible for the accuracy of information you enter. You agree to use IOU only for lawful purposes. You agree not to use IOU to facilitate fraudulent, abusive, or predatory lending.

7. Dispute Resolution
Any disputes between lenders and borrowers are between those individuals. IOU LLC has no obligation to mediate, arbitrate, or resolve disputes between users.

8. Limitation of Liability
IOU LLC is not liable for any loss, unpaid amounts, damages, or harm arising from the use of the platform or any loan agreement created through it. Use IOU at your own risk.

9. Privacy
Your use of IOU is also governed by the IOU Privacy Policy, which is incorporated into these Terms by reference.

10. Changes to Terms
IOU may update these Terms from time to time. Continued use of the app after changes constitutes acceptance of the updated Terms.

11. Governing Law
These Terms are governed by the laws of the state in which IOU LLC is incorporated, without regard to conflict of law principles.

By tapping "I agree to the Terms of Service" you confirm that you have reviewed, understood, and agree to these Terms of Service.`;

const PRIVACY_TEXT = `IOU Privacy Policy
Effective: ${PRIVACY_VERSION}

1. Information We Collect
IOU collects information you provide directly, including: your name, email address, phone number, and any loan agreement details you enter. We may also collect device information and usage data to improve the app.

2. How We Use Your Information
We use your information to: operate and maintain the IOU service, facilitate loan agreements between users, process platform fees, send notifications related to your agreements, and improve the app.

3. Information Sharing
We do not sell your personal information. We share your information only: with the counterparty in a loan agreement (lender or borrower), with service providers who help us operate the platform, and as required by law.

4. Loan Agreement Data
When you create or participate in a loan agreement, certain details (your name, payment amounts, dates) are shared with the other party to the agreement. This is necessary to operate the service.

5. Electronic Signatures
Typed signatures you provide are stored as part of the loan agreement record. This record may be referenced in the event of a dispute.

6. Data Security
We take reasonable steps to protect your information. However, no internet transmission is 100% secure, and we cannot guarantee absolute security.

7. Data Retention
We retain your data as long as your account is active or as needed to comply with legal obligations. You may request deletion of your account data by contacting us.

8. Your Rights
Depending on your jurisdiction, you may have rights to access, correct, or delete your personal data. Contact us to exercise these rights.

9. Children
IOU is not intended for users under 18. We do not knowingly collect data from minors.

10. Contact
For privacy questions or requests, contact us at the email address listed in the app.

11. Changes to This Policy
We may update this Privacy Policy. We will notify you of significant changes. Continued use of the app constitutes acceptance of the updated policy.

By tapping "I agree to the Privacy Policy" you confirm that you have reviewed and understood how IOU collects, uses, and shares your information.`;

const GREEN = "#77B777";
const GREEN_DARK = "#5F9F5F";
const BLUE = "#3B82F6";
const RED = "#D9534F";
const AMBER = "#F59E0B";
const BG = "#F5F7F9";

const currency = (c: number) => `$${(c / 100).toFixed(2)}`;
const normName = (s: string) => s.toLowerCase().replace(/\s+/g, " ").trim();

export default function PreviewSign({ route, navigation }: any) {
  const iouId: string | undefined = route?.params?.id;

  const [meId, setMeId] = useState<string | null>(null);
  const [iou, setIou] = useState<IouRow | null>(null);
  const [lender, setLender] = useState<ProfileLite | null>(null);
  const [borrower, setBorrower] = useState<ProfileLite | null>(null);
  const [borrowerTrust, setBorrowerTrust] = useState<BorrowerTrust | null>(null);
  const [payments, setPayments] = useState<PaymentPreviewRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [activating, setActivating] = useState(false);
  const [approvingSchedule, setApprovingSchedule] = useState(false);
  const [sharing, setSharing] = useState(false);
  // ACH readiness — loaded for both parties, never set from client
  const [meAchStatus, setMeAchStatus] = useState<string | null>(null);
  const [counterpartyAchStatus, setCounterpartyAchStatus] = useState<string | null>(null);
  const [contractExpanded, setContractExpanded] = useState(false);
  const [signatureName, setSignatureName] = useState("");
  const [agreedToContract, setAgreedToContract] = useState(false);
  const [termsReviewed, setTermsReviewed] = useState(false);
  const [privacyReviewed, setPrivacyReviewed] = useState(false);
  const [showDocModal, setShowDocModal] = useState<null | "terms" | "privacy">(null);
  const [docScrolledToBottom, setDocScrolledToBottom] = useState(false);
  const docViewHeightRef = useRef(0);
  const [ackElectronic, setAckElectronic] = useState(false);
  const [ackFee, setAckFee] = useState(false);
  const [ackNotLender, setAckNotLender] = useState(false);

  const loadPayments = useCallback(async (nextIouId: string) => {
    const selectOptions = [
      "id, amount_cents, status, due_date",
      "id, amount_cents, status, due_at",
      "id, amount_cents, status, scheduled_at",
    ];

    for (const sel of selectOptions) {
      const orderCol = sel.includes("due_date")
        ? "due_date"
        : sel.includes("due_at")
          ? "due_at"
          : "scheduled_at";

      const { data, error } = await supabase
        .from("payments")
        .select(sel)
        .eq("iou_id", nextIouId)
        .order(orderCol as any, { ascending: true });

      if (!error) {
        setPayments(
          (data ?? []).map((row: any) => ({
            id: row.id,
            amount_cents: row.amount_cents ?? 0,
            status: row.status ?? "scheduled",
            due:
              row.due_date ??
              (typeof row.due_at === "string" ? row.due_at.slice(0, 10) : null) ??
              (typeof row.scheduled_at === "string"
                ? row.scheduled_at.slice(0, 10)
                : null) ??
              "",
          })) as PaymentPreviewRow[]
        );
        return;
      }
    }
    setPayments([]);
  }, []);

  const load = useCallback(async () => {
    if (!iouId) return;
    setLoading(true);
    try {
      const { data: authData } = await supabase.auth.getUser();
      const currentUserId = authData.user?.id ?? null;
      setMeId(currentUserId);

      const { data, error } = await supabase
        .from("ious")
        .select("*")
        .eq("id", iouId)
        .single();

      if (error || !data) throw error ?? new Error("IOU not found");

      const row = data as IouRow;
      setIou(row);

      const ids = [row.lender_id, row.borrower_id].filter(Boolean);
      if (ids.length) {
        const { data: profs, error: profError } = await supabase
          .from("profile_directory")
          .select("id, public_name")
          .in("id", ids);
        if (profError) throw profError;
        const map = new Map((profs ?? []).map((p: any) => [p.id, p]));
        setLender(map.get(row.lender_id) || null);
        setBorrower(map.get(row.borrower_id) || null);
      } else {
        setLender(null);
        setBorrower(null);
      }

      setSignatureName("");
      setAgreedToContract(false);
      setTermsReviewed(false);
      setPrivacyReviewed(false);
      setShowDocModal(null);
      setDocScrolledToBottom(false);
      setAckElectronic(false);
      setAckFee(false);
      setAckNotLender(false);
      setMeAchStatus(null);
      setCounterpartyAchStatus(null);

      if (row.borrower_id) {
        const { data: trustData, error: trustError } = await supabase
          .from("profile_directory")
          .select("iou_score, active_exposure_points, strike_count")
          .eq("id", row.borrower_id)
          .single();
        setBorrowerTrust(trustError ? null : (trustData ?? null));
      } else {
        setBorrowerTrust(null);
      }

      // Load ACH readiness for both parties via the safe RPC.
      // ach_status is never read cross-user from profiles directly.
      // get_iou_ach_readiness returns TABLE — supabase.rpc() wraps it as an array.
      if (currentUserId && row.borrower_id && row.lender_id) {
        const { data: achData, error: achError } = await supabase.rpc("get_iou_ach_readiness", {
          p_iou_id: iouId,
        });
        if (__DEV__) {
          console.log("[PreviewSign] get_iou_ach_readiness", {
            iouId,
            user_id_suffix: currentUserId?.slice(-6) ?? null,
            lender_suffix: row.lender_id?.slice(-6) ?? null,
            borrower_suffix: row.borrower_id?.slice(-6) ?? null,
            raw_response: achData,
            rpc_error: achError ? { message: achError.message, code: (achError as any).code } : null,
          });
        }
        // achData is an array because the function uses RETURNS TABLE + return query.
        const achRow = Array.isArray(achData) ? (achData[0] ?? null) : achData;
        if (achRow) {
          setMeAchStatus(achRow.self_ready ? "ready" : "not_ready");
          setCounterpartyAchStatus(achRow.counterparty_ready ? "ready" : "not_ready");
        }
      }

      await loadPayments(row.id);
    } catch (e: any) {
      Alert.alert("Load failed", e?.message ?? String(e));
    } finally {
      setLoading(false);
    }
  }, [iouId, loadPayments]);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load])
  );

  const lenderName = lender?.public_name || "Lender";
  const borrowerName = borrower?.public_name || "Borrower";

  const isLenderView = !!meId && !!iou && meId === iou.lender_id;
  const isBorrowerView = !!meId && !!iou && meId === iou.borrower_id;

  const humanFrequency = (f: Frequency) =>
    f === "weekly" ? "weekly" : f === "biweekly" ? "every two weeks" : "monthly";

  const contractPreview = useMemo(() => {
    if (!iou) return "";
    const startDate = iou.start_date
      ? new Date(iou.start_date).toLocaleDateString()
      : "the agreed start date";
    const aprPct = (iou.apr_bps / 100).toFixed(2);
    return (
      iou.contract_text ||
      [
        `This IOU is between ${lenderName} ("Lender") and ${borrowerName} ("Borrower").`,
        ``,
        `Principal: ${currency(iou.principal_cents)}`,
        `APR: ${aprPct}%`,
        `Start date: ${startDate}`,
        `Term: ${iou.term_months} month(s)`,
        `Repayment frequency: ${humanFrequency(iou.frequency)}.`,
        ``,
        `Borrower agrees to repay the loan according to the attached payment schedule`,
        `generated inside the IOU app. Payments marked as "paid" in IOU represent`,
        `Borrower's acknowledgment that such payment was made to Lender.`,
        ``,
        `This agreement is for personal lending between people who know and trust`,
        `each other. IOU LLC is not a party to this agreement and is not responsible`,
        `for enforcing or collecting this debt.`,
      ].join("\n")
    );
  }, [iou, lenderName, borrowerName]);

  const isActivated = !!iou?.activated_at;
  const isPaid = iou?.status === "paid";
  const isLocked = isActivated || isPaid;

  // ACH readiness — derived from server-read values; never set client-side.
  // selfAchReady: current user has ach_status = 'ready'.
  // counterpartyAchReady: the other party has ach_status = 'ready'.
  // plaid_linked = true is NOT sufficient; only ach_status = 'ready' qualifies.
  // If either status is null (still loading), treat as not-ready to fail safe.
  const selfAchReady = meAchStatus === "ready";
  const counterpartyAchReady = counterpartyAchStatus === "ready";
  // Which role is the counterparty from the current user's perspective?
  const counterpartyRole: "lender" | "borrower" = isBorrowerView ? "lender" : "borrower";
  // achBlocker: 'self' = current user must finish setup; 'counterparty' = other party must.
  const achBlocker: "self" | "counterparty" | null =
    !selfAchReady ? "self" : !counterpartyAchReady ? "counterparty" : null;

  const counterpartyPublicName: string | null = isBorrowerView
    ? (lender?.public_name ?? null)
    : (borrower?.public_name ?? null);

  const achBlockerText: string | null =
    !achBlocker
      ? null
      : achBlocker === "self" && !counterpartyAchReady
        ? "Both participants need to finish bank setup before this IOU can be activated."
        : achBlocker === "self"
          ? "Finish your bank setup before activating this IOU."
          : counterpartyPublicName
            ? `Waiting for ${counterpartyPublicName} to finish bank setup before this IOU can be activated.`
            : "Waiting for the other participant to finish bank setup before this IOU can be activated.";

  const borrowerScore =
    typeof borrowerTrust?.iou_score === "number" ? borrowerTrust.iou_score : null;

  const borrowerTrustLabel =
    borrowerScore === null
      ? "No score yet"
      : borrowerScore >= 1000 ? "Strong"
      : borrowerScore >= 850 ? "Rising"
      : borrowerScore >= 700 ? "Starter"
      : "Watch";

  const borrowerTrustColor =
    borrowerScore === null ? "#111"
      : borrowerScore >= 1000 ? GREEN
      : borrowerScore >= 850 ? BLUE
      : borrowerScore >= 700 ? "#B7791F"
      : RED;

  const totalScheduled = useMemo(
    () => payments.reduce((sum, row) => sum + row.amount_cents, 0),
    [payments]
  );

  const firstDue = payments.length > 0 ? payments[0].due : null;
  const lastDue = payments.length > 0 ? payments[payments.length - 1].due : null;
  const perPayment = payments.length > 0 ? payments[0].amount_cents : 0;
  const feeCents = iou ? Math.round(iou.principal_cents * 0.007) : 0;

  // Profile name for signature matching (borrower only)
  const profileName = isBorrowerView ? (borrower?.public_name ?? null) : null;

  const normalizedSignatureName = useMemo(
    () => signatureName.replace(/\s+/g, " ").trim(),
    [signatureName]
  );

  const signatureLooksLikeEmail = normalizedSignatureName.includes("@");

  const signatureParts = normalizedSignatureName
    .split(" ")
    .map((p) => p.trim())
    .filter(Boolean);

  // Signature must match profile name when known
  const signatureMatchesProfile = useMemo(() => {
    if (!profileName) return true;
    return normName(normalizedSignatureName) === normName(profileName);
  }, [profileName, normalizedSignatureName]);

  const signatureReady = useMemo(() => {
    return (
      agreedToContract &&
      signatureParts.length >= 2 &&
      !signatureLooksLikeEmail &&
      signatureMatchesProfile
    );
  }, [agreedToContract, signatureLooksLikeEmail, signatureParts.length, signatureMatchesProfile]);

  const signatureErrorText = useMemo(() => {
    if (!normalizedSignatureName) return null;
    if (signatureLooksLikeEmail) return "Use your full name, not your email.";
    if (signatureParts.length < 2) return "Enter your full first and last name.";
    if (!signatureMatchesProfile && profileName)
      return `Sign as "${profileName}" to match your profile name.`;
    return null;
  }, [normalizedSignatureName, signatureLooksLikeEmail, signatureParts.length, signatureMatchesProfile, profileName]);

  // Step completion (borrower flow)
  const scheduleReady = payments.length > 0;
  // Borrower proposed a schedule change — waiting for lender to approve
  const schedulePendingApproval = isBorrowerView && iou?.status === "draft" && scheduleReady;
  // Schedule has been lender-approved and is now locked for borrower editing
  const scheduleLockedForBorrower = isBorrowerView && scheduleReady && iou?.status === "open" && !isActivated;
  // Lender sees a schedule the borrower proposed that needs approval
  const borrowerProposedSchedule = isLenderView && iou?.status === "draft" && payments.length > 0;

  const allAcknowledged = termsReviewed && privacyReviewed && ackElectronic && ackFee && ackNotLender;

  const canAccept = scheduleReady && allAcknowledged && signatureReady && !isLocked && !schedulePendingApproval;

  const acceptBlockReason: string | null = schedulePendingApproval
    ? "Waiting for lender to approve your proposed schedule."
    : !scheduleReady
      ? "Set your payment schedule before accepting."
      : !allAcknowledged
        ? "Check all required acknowledgments to continue."
        : !agreedToContract
          ? "Agree to the contract terms to accept."
          : signatureParts.length < 2
            ? "Add your full name signature to accept."
            : !signatureMatchesProfile && !!profileName
              ? `Sign as "${profileName}" to match your profile.`
              : null;

  const formatActivateError = (err: any) => {
    const raw = err?.message ?? String(err) ?? "Could not activate this IOU.";
    const lower = raw.toLowerCase();
    if (lower.includes("maximum number of active loans") || lower.includes("maximum of 10 active loans"))
      return "This borrower already has 10 active loans and cannot activate another one right now.";
    if (lower.includes("maximum allowed exposure") || lower.includes("would exceed max exposure") || lower.includes("would exceed the maximum allowed exposure"))
      return "Activating this IOU would push the borrower over the current exposure limit.";
    if (lower.includes("borrower is required before activation"))
      return "Add a borrower before activating this IOU.";
    return raw;
  };

  const openDocument = (type: "terms" | "privacy") => {
    setDocScrolledToBottom(false);
    setShowDocModal(type);
  };

  const handleDocScroll = (event: any) => {
    const { contentOffset, layoutMeasurement, contentSize } = event.nativeEvent;
    if (contentOffset.y + layoutMeasurement.height >= contentSize.height - 40) {
      setDocScrolledToBottom(true);
    }
  };

  const onDocRead = () => {
    if (showDocModal === "terms") setTermsReviewed(true);
    else if (showDocModal === "privacy") setPrivacyReviewed(true);
    setShowDocModal(null);
  };

  // suppress unused ref warning — used by modal scroll
  void docViewHeightRef;

  const openBorrowerProfile = () => {
    if (!iou?.borrower_id) {
      Alert.alert("Missing borrower", "This IOU does not have a borrower profile linked yet.");
      return;
    }
    navigation.navigate("Person", { personId: iou.borrower_id });
  };

  const openLoanDetail = () => {
    if (!iouId) return;
    navigation.navigate("LoanDetail", { iouId });
  };

  const onEditSchedule = () => {
    if (!iouId) return;
    navigation.navigate("NewLoan", { id: iouId, borrowerScheduleEdit: isBorrowerView });
  };

  // Lender: activates the IOU directly
  const onActivate = async () => {
    if (!iou || !iouId) return;
    if (isActivated) { Alert.alert("Already active", "This IOU has already been activated."); return; }
    if (!isLenderView) { Alert.alert("Activate blocked", "Only the lender can activate this IOU."); return; }
    if (payments.length === 0) { Alert.alert("Missing schedule", "This IOU needs at least one scheduled payment before it can be activated."); return; }
    if (!signatureReady) { Alert.alert("Signature required", "Enter your full first and last name, then confirm you agree to the contract before activating."); return; }

    // ACH readiness gate — must check both parties.
    // achBlocker = 'self' means the current user (lender here) must finish bank setup.
    // achBlocker = 'counterparty' means the borrower must finish — lender should NOT be
    // routed to their own LinkBank in this case.
    if (achBlocker === "self") {
      Alert.alert(
        "Bank setup required",
        achBlockerText ?? "Finish your bank setup before activating this IOU.",
        [
          { text: "Not now", style: "cancel" },
          { text: "Set up bank", onPress: () => navigation.navigate("LinkBank", { iouId }) },
        ]
      );
      return;
    }
    if (achBlocker === "counterparty") {
      Alert.alert(
        "Bank setup required",
        achBlockerText ?? "Waiting for the other participant to finish bank setup before this IOU can be activated."
      );
      return;
    }

    Alert.alert(
      "Activate IOU?",
      "This will lock in the schedule and formally activate this IOU.",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Activate",
          style: "destructive",
          onPress: async () => {
            try {
              setActivating(true);
              const { error } = await supabase.rpc("activate_iou", {
                p_iou_id: iouId,
                p_contract_text: contractPreview,
              });
              if (error) throw error;
              await load();
              Alert.alert("IOU activated", "Your IOU is now active.", [
                {
                  text: "View loan",
                  onPress: () =>
                    navigation.reset({
                      index: 1,
                      routes: [{ name: "Home" }, { name: "LoanDetail", params: { iouId } }],
                    }),
                },
              ]);
            } catch (e: any) {
              Alert.alert("Activate blocked", formatActivateError(e));
            } finally {
              setActivating(false);
            }
          },
        },
      ]
    );
  };

  // Borrower: accepts and activates after signing
  const onAcceptAsReceiver = async () => {
    if (!iou || !iouId) return;
    if (isActivated) { Alert.alert("Already active", "This IOU has already been activated."); return; }
    if (!canAccept) return; // button is disabled; should not be reachable

    // ACH readiness gate — must check both parties.
    // achBlocker = 'self' means the current user (borrower here) must finish bank setup.
    // achBlocker = 'counterparty' means the lender must finish — borrower should NOT be
    // routed to their own LinkBank in this case.
    if (achBlocker === "self") {
      Alert.alert(
        "Bank setup required",
        achBlockerText ?? "Finish your bank setup before activating this IOU.",
        [
          { text: "Not now", style: "cancel" },
          { text: "Set up bank", onPress: () => navigation.navigate("LinkBank", { iouId }) },
        ]
      );
      return;
    }
    if (achBlocker === "counterparty") {
      Alert.alert(
        "Bank setup required",
        achBlockerText ?? "Waiting for the other participant to finish bank setup before this IOU can be activated."
      );
      return;
    }

    Alert.alert(
      "Accept & Activate IOU?",
      "This will activate the IOU and lock in the payment schedule. You agree to the terms as signed.",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Accept & Activate",
          onPress: async () => {
            try {
              setActivating(true);
              try {
                await supabase.from("iou_acceptance_audit").insert({
                  iou_id: iouId,
                  user_id: meId,
                  typed_signature: normalizedSignatureName,
                  terms_version: TERMS_VERSION,
                  privacy_version: PRIVACY_VERSION,
                  platform_fee_bps: 70,
                  accepted_at: new Date().toISOString(),
                  repayment_total_cents: totalScheduled,
                  platform_fee_cents: feeCents,
                  total_borrower_cost_cents: totalScheduled + feeCents,
                  metadata: null,
                });
              } catch {
                // audit save failed — proceed with activation
              }
              const { error } = await supabase.rpc("accept_iou_request", {
                p_iou_id: iouId,
              });
              if (error) throw error;
              Alert.alert("IOU activated", "Your payment schedule is now active.", [
                {
                  text: "OK",
                  onPress: () =>
                    navigation.reset({
                      index: 1,
                      routes: [{ name: "Home" }, { name: "LoanDetail", params: { iouId } }],
                    }),
                },
              ]);
            } catch (e: any) {
              Alert.alert("Accept failed", formatActivateError(e));
            } finally {
              setActivating(false);
            }
          },
        },
      ]
    );
  };

  // Lender approves borrower's proposed schedule
  const onApproveSchedule = async () => {
    if (!iou || !iouId) return;
    Alert.alert(
      "Approve schedule?",
      "This confirms the borrower's proposed payment schedule and sends the IOU back for their signature.",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Approve",
          onPress: async () => {
            setApprovingSchedule(true);
            try {
              const paymentsJson = payments.map((p) => ({ due_date: p.due, amount_cents: p.amount_cents }));
              const { error } = await supabase.rpc("finalize_iou_schedule", {
                p_iou_id: iouId,
                p_payments: paymentsJson,
                p_title: iou.title,
                p_lender_id: iou.lender_id,
                p_borrower_id: iou.borrower_id,
                p_principal_cents: iou.principal_cents,
                p_apr_bps: iou.apr_bps,
                p_start_date: iou.start_date,
                p_term_months: iou.term_months,
                p_frequency: iou.frequency,
              });
              if (error) throw error;
              await load();
              Alert.alert("Schedule approved", "The borrower can now review and sign.", [
                {
                  text: "OK",
                  onPress: () => navigation.reset({ index: 0, routes: [{ name: "Home" }] }),
                },
              ]);
            } catch (e: any) {
              Alert.alert("Approve failed", e?.message ?? String(e));
            } finally {
              setApprovingSchedule(false);
            }
          },
        },
      ]
    );
  };

  // Lender rejects borrower's proposed schedule — removes payments, asks borrower to re-propose
  const onRejectSchedule = async () => {
    if (!iou || !iouId) return;
    Alert.alert(
      "Reject schedule?",
      "This removes the proposed dates and asks the borrower to propose new payment dates.",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Reject",
          style: "destructive",
          onPress: async () => {
            setApprovingSchedule(true);
            try {
              const { error } = await supabase.rpc("reject_schedule_change", { p_iou_id: iouId });
              if (error) throw error;
              await load();
              Alert.alert("Schedule rejected", "The borrower can propose a new schedule.", [
                {
                  text: "OK",
                  onPress: () => navigation.reset({ index: 0, routes: [{ name: "Home" }] }),
                },
              ]);
            } catch (e: any) {
              Alert.alert("Reject failed", e?.message ?? String(e));
            } finally {
              setApprovingSchedule(false);
            }
          },
        },
      ]
    );
  };

  const onShare = async () => {
    if (!iou) return;
    setSharing(true);
    try {
      const aprPct = (iou.apr_bps / 100).toFixed(2);
      const startDate = iou.start_date ? new Date(iou.start_date).toLocaleDateString() : "TBD";
      const summaryLines = [
        `IOU Summary: ${iou.title || "Loan"}`,
        ``,
        `Lender: ${lenderName}`,
        `Borrower: ${borrowerName}`,
        ``,
        `Principal: ${currency(iou.principal_cents)}`,
        `APR: ${aprPct}%`,
        `Term: ${iou.term_months} month(s)`,
        `Frequency: ${humanFrequency(iou.frequency)}`,
        `Start date: ${startDate}`,
        `Scheduled payments: ${payments.length}`,
        payments.length > 0 ? `First due: ${firstDue}` : null,
        payments.length > 0 ? `Last due: ${lastDue}` : null,
        ``,
        `We'll track payments in the IOU app and mark them paid as we go.`,
      ].filter(Boolean);
      await Share.share({ message: summaryLines.join("\n") });
    } catch (e: any) {
      Alert.alert("Share failed", e?.message ?? String(e));
    } finally {
      setSharing(false);
    }
  };

  if (!iouId) {
    return <View style={s.center}><Text>Missing IOU id.</Text></View>;
  }

  if (loading || !iou) {
    return <View style={s.center}><ActivityIndicator size="large" color={GREEN} /></View>;
  }

  const aprPct = (iou.apr_bps / 100).toFixed(2);

  // ─────────────────────────────────────────────────────────────
  // RENDER
  // ─────────────────────────────────────────────────────────────
  return (
    <KeyboardAvoidingView
      style={s.screen}
      behavior={Platform.OS === "ios" ? "padding" : undefined}
    >
      <ScrollView
        style={s.screen}
        contentContainerStyle={s.content}
        showsVerticalScrollIndicator={false}
        keyboardShouldPersistTaps="handled"
        contentInsetAdjustmentBehavior="automatic"
      >
        <Text style={s.h1}>
          {isBorrowerView ? "Review & Sign IOU" : "Preview & Sign"}
        </Text>

        {/* ── BORROWER: 4-step checklist ── */}
        {isBorrowerView && !isActivated && (
          <View style={s.checklistCard}>
            <Text style={s.checklistHeading}>Steps to accept this IOU</Text>
            {([
              { label: "Review IOU terms", done: true },
              { label: "Confirm payment schedule", done: scheduleReady && !schedulePendingApproval },
              { label: "Sign your name", done: signatureReady },
              { label: "Accept IOU", done: isActivated },
            ] as const).map(({ label, done }, i) => (
              <View key={i} style={s.checklistRow}>
                <View style={[s.stepBubble, done && s.stepBubbleDone]}>
                  <Text style={[s.stepBubbleText, done && s.stepBubbleTextDone]}>
                    {done ? "✓" : i + 1}
                  </Text>
                </View>
                <Text style={[s.stepLabel, done && s.stepLabelDone]}>{label}</Text>
              </View>
            ))}
          </View>
        )}

        {/* ── LENDER: subtitle ── */}
        {!isBorrowerView && !isActivated && (
          <Text style={s.subtitle}>
            Review the key terms before activating this IOU. You can still edit
            the schedule if needed.
          </Text>
        )}

        {/* ── IOU terms summary ── */}
        <View style={s.card}>
          <Text style={s.sectionTitle}>{iou.title || "IOU"}</Text>
          <Text style={s.summaryAmount}>{currency(iou.principal_cents)}</Text>
          <View style={s.divider} />
          <View style={s.summaryRow}>
            <Text style={s.summaryLabel}>APR</Text>
            <Text style={s.summaryValue}>
              {aprPct === "0.00" ? "0% (interest-free)" : `${aprPct}%`}
            </Text>
          </View>
          <View style={s.summaryRow}>
            <Text style={s.summaryLabel}>Term</Text>
            <Text style={s.summaryValue}>
              {iou.term_months} month{iou.term_months !== 1 ? "s" : ""}
            </Text>
          </View>
          <View style={s.summaryRow}>
            <Text style={s.summaryLabel}>Frequency</Text>
            <Text style={s.summaryValue}>{humanFrequency(iou.frequency)}</Text>
          </View>
          <View style={s.summaryRow}>
            <Text style={s.summaryLabel}>Lender</Text>
            <Text style={s.summaryValue}>{lenderName}</Text>
          </View>
          <View style={[s.summaryRow, { borderBottomWidth: 0 }]}>
            <Text style={s.summaryLabel}>Borrower</Text>
            <Text style={s.summaryValue}>{borrowerName}</Text>
          </View>
        </View>

        {/* ── BORROWER: payment schedule section ── */}
        {isBorrowerView && !isActivated && (
          schedulePendingApproval ? (
            // Borrower proposed dates — waiting for lender to approve
            <View style={[s.card, s.schedulePendingCard]}>
              <Text style={s.schedulePendingTitle}>⏳ Schedule pending lender approval</Text>
              <Text style={s.schedulePendingBody}>
                Your proposed payment schedule was sent to the lender. You can sign after the lender approves.
              </Text>
              <View style={s.summaryRow}>
                <Text style={s.summaryLabel}>First payment</Text>
                <Text style={s.summaryValue}>{firstDue || "—"}</Text>
              </View>
              <View style={[s.summaryRow, { borderBottomWidth: 0 }]}>
                <Text style={s.summaryLabel}>Payments</Text>
                <Text style={s.summaryValue}>
                  {payments.length} × {perPayment > 0 ? currency(perPayment) : "—"}
                </Text>
              </View>
            </View>
          ) : scheduleReady ? (
            // Schedule approved/confirmed — show green card; Adjust hidden if lender-approved
            <View style={[s.card, s.scheduleReadyCard]}>
              <View style={s.scheduleReadyHeader}>
                <Text style={s.scheduleReadyTitle}>✓ Payment schedule ready</Text>
                {scheduleLockedForBorrower ? (
                  <Text style={s.scheduleLockBadge}>Lender approved</Text>
                ) : (
                  <TouchableOpacity onPress={onEditSchedule} activeOpacity={0.8}>
                    <Text style={s.adjustLink}>Adjust</Text>
                  </TouchableOpacity>
                )}
              </View>
              <View style={s.summaryRow}>
                <Text style={s.summaryLabel}>First payment</Text>
                <Text style={s.summaryValue}>{firstDue || "—"}</Text>
              </View>
              <View style={s.summaryRow}>
                <Text style={s.summaryLabel}>Last payment</Text>
                <Text style={s.summaryValue}>{lastDue || "—"}</Text>
              </View>
              <View style={s.summaryRow}>
                <Text style={s.summaryLabel}>Total payments</Text>
                <Text style={s.summaryValue}>{payments.length}</Text>
              </View>
              <View style={s.summaryRow}>
                <Text style={s.summaryLabel}>Per payment</Text>
                <Text style={s.summaryValue}>{perPayment > 0 ? currency(perPayment) : "—"}</Text>
              </View>
              <View style={[s.summaryRow, { borderBottomWidth: 0 }]}>
                <Text style={s.summaryLabel}>Total repayment</Text>
                <Text style={[s.summaryValue, { color: GREEN_DARK }]}>
                  {totalScheduled > 0 ? currency(totalScheduled) : "—"}
                </Text>
              </View>
            </View>
          ) : (
            // No schedule yet — prompt borrower to set one
            <View style={[s.card, s.scheduleRequiredCard]}>
              <View style={s.scheduleRequiredHeader}>
                <Text style={s.scheduleRequiredIcon}>📅</Text>
                <View style={{ flex: 1 }}>
                  <Text style={s.scheduleRequiredTitle}>Payment schedule required</Text>
                  <Text style={s.scheduleRequiredSub}>
                    Choose payment dates that work with your payday before signing.
                  </Text>
                </View>
              </View>
              <Text style={s.scheduleRequiredBody}>
                Pick dates that match your payday — most people get paid
                Wednesday, Thursday, or Friday. You can adjust the schedule
                before accepting.
              </Text>
              <TouchableOpacity
                style={s.setScheduleBtn}
                onPress={onEditSchedule}
                activeOpacity={0.85}
              >
                <Text style={s.setScheduleBtnText}>Set Payment Schedule</Text>
              </TouchableOpacity>
            </View>
          )
        )}

        {/* ── LENDER: borrower proposed schedule approval ── */}
        {borrowerProposedSchedule && !isActivated && (
          <View style={[s.card, s.scheduleApprovalCard]}>
            <Text style={s.scheduleApprovalTitle}>Borrower proposed a payment schedule</Text>
            <Text style={s.scheduleApprovalBody}>
              Review the dates below. Approve to let the borrower proceed to signing,
              or reject to ask them to propose new dates.
            </Text>
            <View style={s.summaryRow}>
              <Text style={s.summaryLabel}>First payment</Text>
              <Text style={s.summaryValue}>{firstDue || "—"}</Text>
            </View>
            <View style={s.summaryRow}>
              <Text style={s.summaryLabel}>Last payment</Text>
              <Text style={s.summaryValue}>{lastDue || "—"}</Text>
            </View>
            <View style={s.summaryRow}>
              <Text style={s.summaryLabel}>Total payments</Text>
              <Text style={s.summaryValue}>{payments.length}</Text>
            </View>
            <View style={s.summaryRow}>
              <Text style={s.summaryLabel}>Per payment</Text>
              <Text style={s.summaryValue}>{perPayment > 0 ? currency(perPayment) : "—"}</Text>
            </View>
            <View style={[s.summaryRow, { borderBottomWidth: 0 }]}>
              <Text style={s.summaryLabel}>Total repayment</Text>
              <Text style={[s.summaryValue, { color: GREEN_DARK }]}>
                {totalScheduled > 0 ? currency(totalScheduled) : "—"}
              </Text>
            </View>
            <View style={s.approvalActions}>
              <TouchableOpacity
                style={s.rejectScheduleBtn}
                onPress={onRejectSchedule}
                disabled={approvingSchedule}
              >
                <Text style={s.rejectScheduleBtnTxt}>Reject</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[s.btn, s.btnGrow, s.approveScheduleBtn]}
                onPress={onApproveSchedule}
                disabled={approvingSchedule}
              >
                {approvingSchedule ? (
                  <ActivityIndicator color="#fff" size="small" />
                ) : (
                  <Text style={s.btnTxt}>Approve Schedule</Text>
                )}
              </TouchableOpacity>
            </View>
          </View>
        )}

        {/* ── LENDER: borrower trust card ── */}
        {isLenderView && (
          <TouchableOpacity activeOpacity={0.92} style={s.card} onPress={openBorrowerProfile}>
            <View style={s.cardHeaderRow}>
              <Text style={s.sectionTitle}>Borrower</Text>
              <Text style={s.inlineLinkText}>View profile →</Text>
            </View>
            <Text style={s.borrowerName}>{borrowerName}</Text>
            <View style={s.borrowerScoreRow}>
              <Text style={s.borrowerScoreLabel}>Trust snapshot</Text>
              <Text style={[s.borrowerScoreValue, { color: borrowerTrustColor }]}>
                {borrowerScore ?? "—"}{" "}
                <Text style={s.borrowerTrustInline}>
                  {borrowerScore === null ? "" : `· ${borrowerTrustLabel}`}
                </Text>
              </Text>
            </View>
            <Text style={s.borrowerProfileHint}>
              Open profile for full trust details and relationship history.
            </Text>
          </TouchableOpacity>
        )}

        {/* ── Cost Breakdown (borrower only) ── */}
        {isBorrowerView && !isActivated && !!iou && (
          <>
            <View style={s.card}>
              <Text style={s.sectionTitle}>Cost Breakdown</Text>
              <View style={s.summaryRow}>
                <Text style={s.summaryLabel}>Loan amount</Text>
                <Text style={s.summaryValue}>{currency(iou.principal_cents)}</Text>
              </View>
              {totalScheduled > iou.principal_cents && (
                <View style={s.summaryRow}>
                  <Text style={s.summaryLabel}>Estimated interest</Text>
                  <Text style={s.summaryValue}>{currency(totalScheduled - iou.principal_cents)}</Text>
                </View>
              )}
              <View style={s.summaryRow}>
                <Text style={s.summaryLabel}>Repayment to lender</Text>
                <Text style={s.summaryValue}>{currency(totalScheduled)}</Text>
              </View>
              <View style={s.summaryRow}>
                <Text style={s.summaryLabel}>IOU platform fee (0.7%)</Text>
                <Text style={s.summaryValue}>{currency(feeCents)}</Text>
              </View>
              <View style={[s.summaryRow, { borderBottomWidth: 0 }]}>
                <Text style={[s.summaryLabel, s.totalBorrowerLabel]}>Total borrower cost</Text>
                <Text style={[s.summaryValue, s.totalBorrowerValue]}>{currency(totalScheduled + feeCents)}</Text>
              </View>
            </View>
            <View style={s.feeDisclosureCard}>
              <Text style={s.feeDisclosureText}>
                IOU charges a 0.7% platform fee for creating and managing this agreement.
              </Text>
            </View>
          </>
        )}

        {/* ── Required acknowledgments (borrower only) ── */}
        {isBorrowerView && !isActivated && (
          <View style={s.card}>
            <Text style={s.sectionTitle}>Required acknowledgments</Text>

            <View style={s.docReviewRow}>
              <View style={s.docReviewLeft}>
                <View style={[s.checkbox, termsReviewed && s.checkboxChecked]}>
                  {termsReviewed && <Text style={s.checkboxCheck}>✓</Text>}
                </View>
                <Text style={s.ackText}>{"I agree to IOU's Terms of Service."}</Text>
              </View>
              {!termsReviewed && (
                <TouchableOpacity style={s.reviewDocBtn} onPress={() => openDocument("terms")} activeOpacity={0.8}>
                  <Text style={s.reviewDocBtnText}>Review</Text>
                </TouchableOpacity>
              )}
            </View>

            <View style={s.docReviewRow}>
              <View style={s.docReviewLeft}>
                <View style={[s.checkbox, privacyReviewed && s.checkboxChecked]}>
                  {privacyReviewed && <Text style={s.checkboxCheck}>✓</Text>}
                </View>
                <Text style={s.ackText}>{"I acknowledge IOU's Privacy Policy."}</Text>
              </View>
              {!privacyReviewed && (
                <TouchableOpacity style={s.reviewDocBtn} onPress={() => openDocument("privacy")} activeOpacity={0.8}>
                  <Text style={s.reviewDocBtnText}>Review</Text>
                </TouchableOpacity>
              )}
            </View>

            <TouchableOpacity style={s.ackRow} onPress={() => setAckElectronic((v) => !v)} activeOpacity={0.8}>
              <View style={[s.checkbox, ackElectronic && s.checkboxChecked]}>
                {ackElectronic && <Text style={s.checkboxCheck}>✓</Text>}
              </View>
              <Text style={s.ackText}>I consent to use electronic records and electronic signatures.</Text>
            </TouchableOpacity>

            <TouchableOpacity style={s.ackRow} onPress={() => setAckFee((v) => !v)} activeOpacity={0.8}>
              <View style={[s.checkbox, ackFee && s.checkboxChecked]}>
                {ackFee && <Text style={s.checkboxCheck}>✓</Text>}
              </View>
              <Text style={s.ackText}>{"I understand IOU's platform fee is 0.7% of the loan amount."}</Text>
            </TouchableOpacity>

            <TouchableOpacity style={s.ackRow} onPress={() => setAckNotLender((v) => !v)} activeOpacity={0.8}>
              <View style={[s.checkbox, ackNotLender && s.checkboxChecked]}>
                {ackNotLender && <Text style={s.checkboxCheck}>✓</Text>}
              </View>
              <Text style={s.ackText}>I understand IOU is not a lender, debt collector, or repayment guarantor.</Text>
            </TouchableOpacity>
          </View>
        )}

        {/* ── Signature ── */}
        {!isActivated && (
          <View style={[s.card, isBorrowerView && (!scheduleReady || schedulePendingApproval) && s.cardMuted]}>
            <Text style={s.sectionTitle}>
              {isBorrowerView ? "Your signature" : "Signature"}
            </Text>

            {isBorrowerView && !scheduleReady && (
              <View style={s.scheduleFirstNote}>
                <Text style={s.scheduleFirstNoteText}>
                  Complete the payment schedule step above before signing.
                </Text>
              </View>
            )}

            {isBorrowerView && schedulePendingApproval && (
              <View style={s.scheduleFirstNote}>
                <Text style={s.scheduleFirstNoteText}>
                  Wait for lender to approve your schedule before signing.
                </Text>
              </View>
            )}

            <Text style={s.signatureHelpText}>
              {isBorrowerView
                ? "Type your full legal name exactly as it appears in your profile, then agree to the contract terms."
                : isLenderView
                  ? "As lender, type your full legal name and confirm the contract before signing."
                  : "Type your full legal name and confirm the contract before continuing."}
            </Text>

            {isBorrowerView && !!profileName && (
              <Text style={s.profileNameHint}>
                Your registered name: <Text style={{ fontWeight: "900" }}>{profileName}</Text>
              </Text>
            )}

            <Text style={s.label}>Typed signature</Text>
            <TextInput
              style={[s.signatureInput, isBorrowerView && (!scheduleReady || schedulePendingApproval) && s.inputMuted]}
              value={signatureName}
              onChangeText={setSignatureName}
              placeholder={
                profileName ? `Type: ${profileName}` : "Full legal name (First & Last)"
              }
              placeholderTextColor="#9CA3AF"
              autoCapitalize="words"
              autoCorrect={false}
              textContentType="name"
              returnKeyType="done"
              editable={!isBorrowerView || (scheduleReady && !schedulePendingApproval)}
            />

            {!!signatureErrorText && (
              <Text style={s.signatureErrorText}>{signatureErrorText}</Text>
            )}

            <TouchableOpacity
              activeOpacity={0.9}
              style={s.agreeRow}
              onPress={() => {
                if (isBorrowerView && (!scheduleReady || schedulePendingApproval)) return;
                setAgreedToContract((prev) => !prev);
              }}
            >
              <View style={[s.checkbox, agreedToContract && s.checkboxChecked]}>
                {agreedToContract && <Text style={s.checkboxCheck}>✓</Text>}
              </View>
              <Text style={s.agreeText}>
                I have reviewed this IOU and agree to the contract terms.
              </Text>
            </TouchableOpacity>
          </View>
        )}

        {/* ── Collapsible contract ── */}
        <View style={s.card}>
          <TouchableOpacity
            style={s.contractToggleRow}
            onPress={() => setContractExpanded((v) => !v)}
            activeOpacity={0.8}
          >
            <Text style={s.sectionTitle}>Contract terms</Text>
            <Text style={s.contractToggleText}>
              {contractExpanded ? "Hide ▲" : "View ▼"}
            </Text>
          </TouchableOpacity>
          {contractExpanded && (
            <Text style={s.contract}>{contractPreview}</Text>
          )}
        </View>

        {/* ── LENDER: loan details ── */}
        {isLenderView && (
          <View style={s.card}>
            <Text style={s.sectionTitle}>Details</Text>
            <Text style={s.label}>Lender</Text>
            <Text style={s.value}>{lenderName}</Text>
            <Text style={s.label}>Borrower</Text>
            <TouchableOpacity activeOpacity={0.8} onPress={openBorrowerProfile}>
              <Text style={[s.value, s.linkValue]}>{borrowerName}</Text>
            </TouchableOpacity>
            <Text style={s.label}>Activation</Text>
            <Text style={[s.value, isActivated ? s.goodText : s.pendingText]}>
              {isActivated
                ? `Activated on ${new Date(iou.activated_at as string).toLocaleDateString()}`
                : "Not activated yet"}
            </Text>
          </View>
        )}

        {/* ── LENDER: payment preview ── */}
        {isLenderView && payments.length > 0 && (
          <View style={s.card}>
            <View style={s.cardHeaderRow}>
              <Text style={s.sectionTitle}>Payment preview</Text>
              {payments.length > 3 && (
                <Text style={s.previewMetaText}>Showing first 3</Text>
              )}
            </View>
            {payments.slice(0, 3).map((payment, index) => (
              <View
                key={payment.id}
                style={[s.paymentPreviewRow, index > 0 && s.paymentPreviewRowBorder]}
              >
                <View style={{ flex: 1 }}>
                  <Text style={s.paymentPreviewTitle}>Payment {index + 1}</Text>
                  <Text style={s.paymentPreviewMeta}>Due {payment.due || "—"}</Text>
                </View>
                <View style={{ alignItems: "flex-end" }}>
                  <Text style={s.paymentPreviewAmount}>{currency(payment.amount_cents)}</Text>
                  <Text style={s.paymentPreviewStatus}>
                    {(payment.status || "scheduled").toUpperCase()}
                  </Text>
                </View>
              </View>
            ))}
          </View>
        )}

        {/* ── Actions ── */}
        {isActivated ? (
          <TouchableOpacity style={s.openLoanBtnPrimary} onPress={openLoanDetail} activeOpacity={0.85}>
            <Text style={s.openLoanBtnPrimaryText}>Open Loan Detail →</Text>
          </TouchableOpacity>
        ) : isBorrowerView ? (
          // Borrower CTA
          <>
            <Text style={s.acceptFeeNote}>
              By accepting, you agree to the repayment schedule and IOU's 0.7% platform fee.
            </Text>
            <TouchableOpacity
              style={[s.acceptBtn, !canAccept && s.acceptBtnDisabled]}
              onPress={onAcceptAsReceiver}
              disabled={activating || !canAccept}
              activeOpacity={0.85}
            >
              {activating ? (
                <ActivityIndicator color="#fff" size="small" />
              ) : (
                <Text style={s.acceptBtnText}>
                  {isPaid ? "Already paid" : "Accept & Activate IOU"}
                </Text>
              )}
            </TouchableOpacity>
            {!!acceptBlockReason && (
              <Text style={s.acceptBlockReason}>{acceptBlockReason}</Text>
            )}
            {!isLocked && !!achBlocker && (
              <View style={s.achBlockerCard}>
                <Text style={s.achBlockerText}>
                  {achBlockerText}
                </Text>
                {achBlocker === "self" && (
                  <TouchableOpacity
                    onPress={() => navigation.navigate("LinkBank", { iouId })}
                    style={s.achBlockerBtn}
                  >
                    <Text style={s.achBlockerBtnText}>Set up bank →</Text>
                  </TouchableOpacity>
                )}
              </View>
            )}
          </>
        ) : (
          // Lender CTA
          <>
            {!isLocked && !!achBlocker && (
              <View style={s.achBlockerCard}>
                <Text style={s.achBlockerText}>
                  {achBlockerText}
                </Text>
                {achBlocker === "self" && (
                  <TouchableOpacity
                    onPress={() => navigation.navigate("LinkBank", { iouId })}
                    style={s.achBlockerBtn}
                  >
                    <Text style={s.achBlockerBtnText}>Set up bank →</Text>
                  </TouchableOpacity>
                )}
              </View>
            )}
            <View style={s.actionsRow}>
              <TouchableOpacity style={[s.btn, s.btnOutline]} onPress={onEditSchedule}>
                <Text style={s.btnOutlineTxt}>Edit schedule</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[s.btn, s.btnGrow, isLocked ? s.btnDisabled : s.btnPrimary]}
                onPress={onActivate}
                disabled={activating || isLocked}
              >
                <Text style={s.btnTxt}>
                  {activating ? "Activating…" : isPaid ? "Already paid" : "Activate IOU"}
                </Text>
              </TouchableOpacity>
            </View>
          </>
        )}

        <TouchableOpacity
          style={[s.btnShareFull]}
          onPress={onShare}
          disabled={sharing}
        >
          <Text style={s.btnShareTxt}>{sharing ? "Sharing…" : "Share summary"}</Text>
        </TouchableOpacity>

        {isActivated && !isPaid && (
          <Text style={[s.hint, { color: GREEN }]}>
            This IOU is active. Payments can be managed from the Loan Detail screen.
          </Text>
        )}
        {isPaid && (
          <Text style={[s.hint, { color: GREEN }]}>
            This IOU is fully paid. The loan can be archived from the Loan Detail screen.
          </Text>
        )}

        {__DEV__ && (
          <View style={s.devCard}>
            <Text style={s.devCardTitle}>DEV — ACH status</Text>
            <Text style={s.devCardRow}>meAchStatus: {meAchStatus ?? "(null)"}</Text>
            <Text style={s.devCardRow}>counterpartyAchStatus: {counterpartyAchStatus ?? "(null)"}</Text>
            <Text style={s.devCardRow}>
              achBlocker: {achBlocker ?? "none"} · selfReady: {selfAchReady ? "yes" : "no"} · cpReady: {counterpartyAchReady ? "yes" : "no"}
            </Text>
          </View>
        )}
      </ScrollView>

      {/* ── Document viewer modal ── */}
      <Modal
        visible={showDocModal !== null}
        animationType="slide"
        presentationStyle="pageSheet"
        onRequestClose={() => setShowDocModal(null)}
      >
        <View style={s.modalContainer}>
          <View style={s.modalHeader}>
            <Text style={s.modalTitle}>
              {showDocModal === "terms" ? "Terms of Service" : "Privacy Policy"}
            </Text>
            <TouchableOpacity onPress={() => setShowDocModal(null)} style={s.modalClose}>
              <Text style={s.modalCloseTxt}>Close</Text>
            </TouchableOpacity>
          </View>
          <Text style={s.modalScrollHint}>
            {docScrolledToBottom
              ? "Please review the full document before continuing."
              : "Please review the full document before continuing."}
          </Text>
          <ScrollView
            style={s.modalScroll}
            onScroll={handleDocScroll}
            scrollEventThrottle={16}
          >
            <Text style={s.modalDocText}>
              {showDocModal === "terms" ? TERMS_TEXT : PRIVACY_TEXT}
            </Text>
          </ScrollView>
          <View style={s.modalFooter}>
            <TouchableOpacity
              style={[s.modalReadBtn, !docScrolledToBottom && s.modalReadBtnDisabled]}
              onPress={onDocRead}
              disabled={!docScrolledToBottom}
              activeOpacity={0.85}
            >
              <Text style={s.modalReadBtnTxt}>
                {docScrolledToBottom
                  ? showDocModal === "terms"
                    ? "I agree to the Terms of Service"
                    : "I agree to the Privacy Policy"
                  : "Review full document"}
              </Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>
    </KeyboardAvoidingView>
  );
}

const s = StyleSheet.create({
  screen: { flex: 1, backgroundColor: BG },
  content: { flexGrow: 1, padding: 16, paddingBottom: 40 },
  center: { flex: 1, alignItems: "center", justifyContent: "center" },

  h1: { fontSize: 24, fontWeight: "800", marginBottom: 10 },
  subtitle: { color: "#555", marginBottom: 12, lineHeight: 20 },

  // ── Checklist ──
  checklistCard: {
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 14,
    marginBottom: 14,
    borderWidth: 1,
    borderColor: "#e5e7eb",
  },
  checklistHeading: {
    fontSize: 13,
    fontWeight: "800",
    color: "#667085",
    textTransform: "uppercase",
    letterSpacing: 0.6,
    marginBottom: 12,
  },
  checklistRow: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 10,
  },
  stepBubble: {
    width: 26,
    height: 26,
    borderRadius: 13,
    backgroundColor: "#F3F4F6",
    borderWidth: 1.5,
    borderColor: "#D1D5DB",
    alignItems: "center",
    justifyContent: "center",
    marginRight: 10,
  },
  stepBubbleDone: {
    backgroundColor: GREEN,
    borderColor: GREEN,
  },
  stepBubbleText: {
    fontSize: 12,
    fontWeight: "800",
    color: "#6B7280",
  },
  stepBubbleTextDone: {
    color: "#fff",
  },
  stepLabel: {
    fontSize: 14,
    fontWeight: "700",
    color: "#6B7280",
  },
  stepLabelDone: {
    color: "#111827",
  },

  // ── Cards ──
  card: {
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 14,
    marginBottom: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#e5e7eb",
  },
  cardMuted: {
    opacity: 0.6,
  },
  cardHeaderRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 10,
  },
  sectionTitle: {
    fontSize: 17,
    fontWeight: "800",
    color: "#111",
    marginBottom: 8,
  },
  inlineLinkText: { color: BLUE, fontWeight: "800", fontSize: 13 },

  // ── Summary rows ──
  summaryAmount: {
    fontSize: 34,
    fontWeight: "900",
    color: GREEN,
    marginBottom: 12,
  },
  divider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: "#E5E7EB",
    marginBottom: 4,
  },
  summaryRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingVertical: 8,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#F3F4F6",
  },
  summaryLabel: { color: "#667085", fontSize: 14, fontWeight: "600" },
  summaryValue: { color: "#111", fontSize: 14, fontWeight: "800" },

  // ── Schedule sections ──
  scheduleReadyCard: {
    borderColor: "#BBF7D0",
    backgroundColor: "#F0FDF4",
  },
  scheduleReadyHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 4,
  },
  scheduleReadyTitle: {
    fontSize: 15,
    fontWeight: "800",
    color: GREEN_DARK,
    marginBottom: 8,
  },
  adjustLink: {
    color: BLUE,
    fontWeight: "800",
    fontSize: 13,
    paddingBottom: 8,
  },
  scheduleRequiredCard: {
    borderColor: "#FCD34D",
    backgroundColor: "#FFFBEB",
    borderWidth: 1.5,
  },
  scheduleRequiredHeader: {
    flexDirection: "row",
    alignItems: "flex-start",
    gap: 10,
    marginBottom: 8,
  },
  scheduleRequiredIcon: { fontSize: 22, marginTop: 2 },
  scheduleRequiredTitle: {
    fontSize: 15,
    fontWeight: "900",
    color: "#92400E",
  },
  scheduleRequiredSub: {
    fontSize: 13,
    color: "#78350F",
    fontWeight: "600",
    marginTop: 2,
  },
  scheduleRequiredBody: {
    fontSize: 13,
    color: "#78350F",
    lineHeight: 19,
    fontWeight: "600",
    marginBottom: 12,
  },
  setScheduleBtn: {
    backgroundColor: AMBER,
    borderRadius: 10,
    paddingVertical: 13,
    alignItems: "center",
  },
  setScheduleBtnText: {
    color: "#fff",
    fontWeight: "900",
    fontSize: 15,
  },

  // ── Borrower card ──
  borrowerName: { fontSize: 18, fontWeight: "800", color: "#111", marginTop: 2 },
  borrowerScoreRow: { marginTop: 10 },
  borrowerScoreLabel: {
    fontSize: 12, fontWeight: "800", color: "#667085",
    textTransform: "uppercase", marginBottom: 4,
  },
  borrowerScoreValue: { fontSize: 28, fontWeight: "900" },
  borrowerTrustInline: { fontSize: 16, fontWeight: "800", color: "#667085" },
  borrowerProfileHint: { marginTop: 8, color: "#667085", fontSize: 13, fontWeight: "700" },

  // ── Signature ──
  scheduleFirstNote: {
    backgroundColor: "#FEF9C3",
    borderRadius: 8,
    padding: 10,
    marginBottom: 10,
    borderWidth: 1,
    borderColor: "#FDE68A",
  },
  scheduleFirstNoteText: {
    fontSize: 13,
    fontWeight: "700",
    color: "#713F12",
  },
  signatureHelpText: {
    color: "#555", fontSize: 13, lineHeight: 19, marginBottom: 8, fontWeight: "600",
  },
  profileNameHint: {
    fontSize: 13,
    color: "#374151",
    fontWeight: "600",
    marginBottom: 8,
    backgroundColor: "#F3F4F6",
    borderRadius: 6,
    padding: 8,
  },
  label: { fontWeight: "800", color: "#333", marginTop: 6 },
  value: { marginTop: 2, color: "#111" },
  linkValue: { color: BLUE, fontWeight: "800" },
  signatureInput: {
    borderWidth: 1,
    borderColor: "#D0D5DD",
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 12,
    fontSize: 15,
    color: "#111",
    backgroundColor: "#fff",
    marginTop: 6,
  },
  inputMuted: {
    backgroundColor: "#F9FAFB",
    color: "#9CA3AF",
  },
  signatureErrorText: {
    marginTop: 8, color: RED, fontSize: 13, fontWeight: "700",
  },
  agreeRow: {
    flexDirection: "row", alignItems: "flex-start", marginTop: 14,
  },
  checkbox: {
    width: 22, height: 22, borderRadius: 6, borderWidth: 1.5,
    borderColor: "#CBD5E1", backgroundColor: "#fff",
    alignItems: "center", justifyContent: "center",
    marginRight: 10, marginTop: 1,
  },
  checkboxChecked: { backgroundColor: GREEN, borderColor: GREEN },
  checkboxCheck: { color: "#fff", fontWeight: "900", fontSize: 13 },
  agreeText: {
    flex: 1, color: "#334155", fontSize: 14, lineHeight: 20, fontWeight: "600",
  },

  // ── Contract ──
  contractToggleRow: {
    flexDirection: "row", justifyContent: "space-between", alignItems: "center",
  },
  contractToggleText: { color: BLUE, fontSize: 13, fontWeight: "800", paddingBottom: 8 },
  contract: { marginTop: 8, color: "#111", lineHeight: 20 },

  // ── Payment preview ──
  previewMetaText: { color: "#667085", fontWeight: "700", fontSize: 12 },
  paymentPreviewRow: { flexDirection: "row", alignItems: "center", paddingVertical: 12 },
  paymentPreviewRowBorder: {
    borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: "#E5E7EB",
  },
  paymentPreviewTitle: { fontSize: 15, fontWeight: "800", color: "#111" },
  paymentPreviewMeta: { marginTop: 3, fontSize: 13, color: "#666" },
  paymentPreviewAmount: { fontSize: 15, fontWeight: "900", color: "#111" },
  paymentPreviewStatus: { marginTop: 4, fontSize: 11, fontWeight: "800", color: "#667085" },

  // ── Accept button (borrower) ──
  acceptBtn: {
    backgroundColor: GREEN,
    borderRadius: 12,
    paddingVertical: 16,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 8,
  },
  acceptBtnDisabled: { backgroundColor: "#D1D5DB" },
  acceptBtnText: { color: "#fff", fontWeight: "900", fontSize: 16 },
  acceptBlockReason: {
    color: "#B45309",
    fontSize: 13,
    fontWeight: "700",
    textAlign: "center",
    marginBottom: 8,
  },

  // ── Lender actions row ──
  actionsRow: {
    flexDirection: "row", gap: 10, marginBottom: 8, alignItems: "stretch",
  },
  btn: {
    paddingVertical: 14, borderRadius: 10, alignItems: "center", justifyContent: "center",
  },
  btnGrow: { flex: 1 },
  btnPrimary: { backgroundColor: GREEN },
  btnDisabled: { backgroundColor: "#D1D5DB" },
  btnOutline: {
    borderWidth: 1, borderColor: BLUE, backgroundColor: "#fff", paddingHorizontal: 16,
  },
  btnTxt: { color: "#fff", fontWeight: "800" },
  btnOutlineTxt: { color: BLUE, fontWeight: "800" },

  // ── Activated state ──
  openLoanBtnPrimary: {
    marginBottom: 12, backgroundColor: GREEN, borderRadius: 12,
    paddingVertical: 16, alignItems: "center", justifyContent: "center",
  },
  openLoanBtnPrimaryText: { color: "#fff", fontWeight: "900", fontSize: 16 },

  // ── Share ──
  btnShareFull: {
    marginTop: 4, marginBottom: 4, backgroundColor: "#64748B",
    borderRadius: 10, paddingVertical: 13, alignItems: "center",
  },
  btnShareTxt: { color: "#fff", fontWeight: "800" },

  hint: { color: "#6b7280", marginTop: 8, textAlign: "center" },
  goodText: { color: "#16a34a" },
  pendingText: { color: "#b45309" },

  // ── Borrower pending approval ──
  schedulePendingCard: {
    borderColor: "#FCD34D",
    backgroundColor: "#FFFBEB",
    borderWidth: 1.5,
  },
  schedulePendingTitle: {
    fontSize: 15,
    fontWeight: "800",
    color: "#92400E",
    marginBottom: 8,
  },
  schedulePendingBody: {
    fontSize: 13,
    color: "#78350F",
    fontWeight: "600",
    lineHeight: 19,
    marginBottom: 10,
  },

  // ── Lender schedule approval ──
  scheduleApprovalCard: {
    borderColor: "#93C5FD",
    backgroundColor: "#EFF6FF",
    borderWidth: 1.5,
  },
  scheduleApprovalTitle: {
    fontSize: 15,
    fontWeight: "800",
    color: "#1D4ED8",
    marginBottom: 8,
  },
  scheduleApprovalBody: {
    fontSize: 13,
    color: "#1E40AF",
    fontWeight: "600",
    lineHeight: 19,
    marginBottom: 10,
  },
  approvalActions: {
    flexDirection: "row",
    gap: 10,
    marginTop: 14,
  },
  approveScheduleBtn: {
    backgroundColor: GREEN,
  },
  rejectScheduleBtn: {
    borderWidth: 1,
    borderColor: "#FCA5A5",
    backgroundColor: "#FEF2F2",
    borderRadius: 10,
    paddingVertical: 14,
    paddingHorizontal: 16,
    alignItems: "center",
    justifyContent: "center",
  },
  rejectScheduleBtnTxt: {
    color: "#B91C1C",
    fontWeight: "800",
    fontSize: 14,
  },

  // ── Cost Breakdown ──
  totalBorrowerLabel: { fontWeight: "800", color: "#111" },
  totalBorrowerValue: { fontWeight: "900", fontSize: 16, color: "#111" },
  feeDisclosureCard: {
    backgroundColor: "#FFF7ED",
    borderRadius: 12,
    padding: 14,
    marginBottom: 14,
    borderWidth: 1,
    borderColor: "#FED7AA",
  },
  feeDisclosureText: {
    fontSize: 13,
    fontWeight: "600",
    color: "#92400E",
    lineHeight: 19,
  },
  acceptFeeNote: {
    fontSize: 12,
    fontWeight: "600",
    color: "#667085",
    textAlign: "center",
    marginBottom: 10,
  },

  // ── Document review rows ──
  docReviewRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginTop: 12,
    gap: 10,
  },
  docReviewLeft: {
    flexDirection: "row",
    alignItems: "flex-start",
    flex: 1,
    gap: 10,
  },
  reviewDocBtn: {
    backgroundColor: "#EFF6FF",
    borderRadius: 8,
    borderWidth: 1,
    borderColor: "#BFDBFE",
    paddingVertical: 6,
    paddingHorizontal: 12,
  },
  reviewDocBtnText: {
    color: BLUE,
    fontWeight: "800",
    fontSize: 13,
  },

  // ── Document modal ──
  modalContainer: {
    flex: 1,
    backgroundColor: "#fff",
  },
  modalHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    padding: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#E5E7EB",
  },
  modalTitle: {
    fontSize: 17,
    fontWeight: "800",
    color: "#111",
  },
  modalClose: {
    padding: 4,
  },
  modalCloseTxt: {
    color: BLUE,
    fontWeight: "700",
    fontSize: 15,
  },
  modalScrollHint: {
    fontSize: 12,
    fontWeight: "600",
    color: "#667085",
    textAlign: "center",
    paddingVertical: 8,
    paddingHorizontal: 16,
    backgroundColor: "#F9FAFB",
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#E5E7EB",
  },
  modalScroll: {
    flex: 1,
  },
  modalDocText: {
    fontSize: 14,
    lineHeight: 22,
    color: "#334155",
    fontWeight: "500",
    padding: 16,
    paddingBottom: 40,
  },
  modalFooter: {
    padding: 16,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#E5E7EB",
  },
  modalReadBtn: {
    backgroundColor: GREEN,
    borderRadius: 12,
    paddingVertical: 16,
    alignItems: "center",
  },
  modalReadBtnDisabled: {
    backgroundColor: "#D1D5DB",
  },
  modalReadBtnTxt: {
    color: "#fff",
    fontWeight: "900",
    fontSize: 16,
  },

  // ── Required acknowledgments ──
  ackRow: {
    flexDirection: "row",
    alignItems: "flex-start",
    marginTop: 12,
  },
  ackText: {
    flex: 1,
    color: "#334155",
    fontSize: 14,
    lineHeight: 20,
    fontWeight: "600",
  },
  ackLink: {
    color: BLUE,
    fontWeight: "700",
    textDecorationLine: "underline",
  },
  scheduleLockBadge: {
    fontSize: 11,
    fontWeight: "800",
    color: GREEN_DARK,
    letterSpacing: 0.3,
  },

  // ── ACH blocker card ──
  achBlockerCard: {
    backgroundColor: "#FEF9C3",
    borderWidth: 1,
    borderColor: "#FDE68A",
    borderRadius: 10,
    padding: 12,
    marginBottom: 10,
  },
  achBlockerText: {
    color: "#92400E",
    fontSize: 13,
    fontWeight: "600",
    lineHeight: 18,
  },
  achBlockerBtn: {
    marginTop: 8,
    alignSelf: "flex-start",
  },
  achBlockerBtnText: {
    color: "#B45309",
    fontSize: 13,
    fontWeight: "800",
    textDecorationLine: "underline",
  },

  // ── DEV diagnostic card (never shown in production) ──
  devCard: {
    backgroundColor: "#F1F5F9",
    borderWidth: 1,
    borderColor: "#CBD5E1",
    borderRadius: 8,
    padding: 10,
    marginTop: 16,
    marginBottom: 4,
  },
  devCardTitle: {
    fontSize: 10,
    fontWeight: "800",
    color: "#64748B",
    textTransform: "uppercase",
    letterSpacing: 0.5,
    marginBottom: 4,
  },
  devCardRow: {
    fontSize: 11,
    color: "#475569",
    fontFamily: "monospace",
    marginBottom: 2,
  },
});

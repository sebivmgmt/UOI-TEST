import React, { useEffect, useState, useCallback, useMemo } from "react";
import {
  View,
  Text,
  TextInput,
  Button,
  ScrollView,
  TouchableOpacity,
  Keyboard,
  Alert,
  StyleSheet,
  ActivityIndicator,
  Share,
  KeyboardAvoidingView,
  Platform,
} from "react-native";
import * as Calendar from "expo-calendar";
import DateTimePicker, {
  DateTimePickerEvent,
} from "@react-native-community/datetimepicker";
import { supabase } from "../supabase";
import { generateSchedule } from "../utils/schedule";
import { useScreenGuard } from "../dev/useScreenGuard";
import { useRecentCounterparties, type ProfileLite } from "../hooks/useRecentCounterparties";
import {
  type QuickDateKey,
  formatDateInput,
  formatFancyDate,
  parseDateInput,
  startOfLocalDay,
  nextWeekdayDate,
  inferWeekdayFromDate,
  quickDateValue,
} from "../utils/dateUtils";
import { digitsOnly } from "../utils/counterpartyUtils";
import { type Frequency, WEEKDAY_OPTIONS, QUICK_DATE_OPTIONS, frequencyLabel } from "../constants/iouOptions";
import { buildScheduleRows } from "../utils/iouSchedule";
import { createIou } from "../services/iouCreationService";

const GREEN = "#77B777";
const BLUE = "#3B82F6";

type LoanSide = "lend" | "borrow";

type IouRow = {
  id: string;
  title: string | null;
  lender_id: string | null;
  borrower_id: string | null;
  principal_cents: number;
  apr_bps: number;
  start_date: string;
  term_months: number;
  frequency: Frequency;
  status: string;
};

type PaymentRowLite = {
  due_date?: string | null;
  due_at?: string | null;
  scheduled_at?: string | null;
};

function currencyFromInput(value: string) {
  const n = parseFloat(value || "0") || 0;
  return n > 0 ? `$${n.toFixed(2)}` : "—";
}

export default function NewLoan({ route, navigation }: any) {
  const existingId = route?.params?.id as string | undefined;
  const borrowerScheduleEdit = !!(route?.params?.borrowerScheduleEdit as boolean | undefined);

  const presetBorrowerId = route?.params?.presetBorrowerId as
    | string
    | undefined;
  const presetBorrowerName = route?.params?.presetBorrowerName as
    | string
    | null
    | undefined;
  const presetBorrowerEmail = route?.params?.presetBorrowerEmail as
    | string
    | null
    | undefined;
  const presetBorrowerPhone = route?.params?.presetBorrowerPhone as
    | string
    | null
    | undefined;
  const presetBorrowerPhoneVerified =
    route?.params?.presetBorrowerPhoneVerified as boolean | null | undefined;

  const [loanSide, setLoanSide] = useState<LoanSide>("lend");

  const [title, setTitle] = useState<string>("");
  const [amount, setAmount] = useState<string>("");
  const [aprPct, setAprPct] = useState<string>("");
  const [termMonths, setTermMonths] = useState<string>("");
  const [frequency, setFrequency] = useState<Frequency>("biweekly");

  const [firstDueDate, setFirstDueDate] = useState<string>(
    formatDateInput(nextWeekdayDate(4))
  );
  const [selectedWeekday, setSelectedWeekday] = useState<number>(4);
  const [showDatePicker, setShowDatePicker] = useState(false);

  const [counterpartyQuery, setCounterpartyQuery] = useState("");
  const [results, setResults] = useState<ProfileLite[]>([]);
  const [searching, setSearching] = useState(false);
  const [counterparty, setCounterparty] = useState<ProfileLite | null>(null);
  const { recent } = useRecentCounterparties();

  const [loading, setLoading] = useState<boolean>(false);
  const [prefilling, setPrefilling] = useState<boolean>(!!existingId);
  const [userId, setUserId] = useState<string | null>(null);
  const [meProfile, setMeProfile] = useState<ProfileLite | null>(null);

  const counterpartyLabel = loanSide === "lend" ? "Borrower" : "Lender";
  const counterpartySearchPlaceholder =
    loanSide === "lend"
      ? "Search borrower by email / phone / IOU hash / name"
      : "Search lender by email / phone / IOU hash / name";

  const introTitle = existingId
    ? borrowerScheduleEdit ? "Adjust Payment Dates" : "Preview Schedule"
    : "New IOU";

  useEffect(() => {
    const boot = async () => {
      const { data } = await supabase.auth.getUser();
      const me = data.user?.id ?? null;
      setUserId(me);

      if (!me) {
        setMeProfile(null);
        return;
      }

      const { data: prof } = await supabase
        .from("profiles")
        .select("id, full_name, email, phone, phone_verified")
        .eq("id", me)
        .maybeSingle();

      setMeProfile((prof as ProfileLite | null) ?? null);
    };

    void boot();
  }, []);

  useEffect(() => {
    if (presetBorrowerId && !existingId) {
      setLoanSide("lend");
      setCounterparty({
        id: presetBorrowerId,
        iou_hash: null,
        public_name: presetBorrowerName ?? null,
      });
      setCounterpartyQuery("");
      setResults([]);
    }
  }, [
    presetBorrowerId,
    presetBorrowerName,
    presetBorrowerEmail,
    presetBorrowerPhone,
    presetBorrowerPhoneVerified,
    existingId,
  ]);

  const prefillFromExisting = useCallback(async () => {
    if (!existingId) return;
    setPrefilling(true);

    const { data, error } = await supabase
      .from("ious")
      .select("*")
      .eq("id", existingId)
      .single();

    if (error || !data) {
      setPrefilling(false);
      Alert.alert("Load IOU failed", error?.message ?? "Unknown error");
      return;
    }

    const iou = data as IouRow;
    setTitle(iou.title ?? "");
    setAmount((iou.principal_cents / 100).toString());
    setAprPct((iou.apr_bps / 100).toString());
    setTermMonths(String(iou.term_months));
    setFrequency(iou.frequency);

    if (userId) {
      if (iou.lender_id === userId) {
        setLoanSide("lend");
      } else if (iou.borrower_id === userId) {
        setLoanSide("borrow");
      }
    }

    const otherPersonId =
      userId && iou.lender_id === userId
        ? iou.borrower_id
        : userId && iou.borrower_id === userId
        ? iou.lender_id
        : iou.borrower_id;

    if (otherPersonId) {
      const { data: prof } = await supabase
        .from("profile_directory")
        .select("id, iou_hash, public_name, avatar_url, iou_score")
        .eq("id", otherPersonId)
        .maybeSingle();

      if (prof) {
        const p: any = prof;
        setCounterparty({
          id: p.id,
          iou_hash: p.iou_hash ?? null,
          public_name: p.public_name ?? null,
          avatar_url: p.avatar_url ?? null,
          iou_score: p.iou_score ?? null,
        });
      }
    }

    const { data: payments } = await supabase
      .from("payments")
      .select("due_date, due_at, scheduled_at")
      .eq("iou_id", existingId)
      .order("due_date", { ascending: true })
      .limit(1);

    const firstPayment = (payments?.[0] ?? null) as PaymentRowLite | null;
    const existingDue =
      firstPayment?.due_date ||
      firstPayment?.due_at ||
      firstPayment?.scheduled_at ||
      iou.start_date;

    if (existingDue) {
      const dateOnly = existingDue.slice(0, 10);
      setFirstDueDate(dateOnly);

      const inferred = inferWeekdayFromDate(dateOnly);
      if (typeof inferred === "number") {
        setSelectedWeekday(inferred);
      }
    }

    setPrefilling(false);
  }, [existingId, userId]);

  useEffect(() => {
    void prefillFromExisting();
  }, [prefillFromExisting]);

  useEffect(() => {
    if (existingId) return;
    if (frequency === "weekly" || frequency === "biweekly") {
      setFirstDueDate(formatDateInput(nextWeekdayDate(selectedWeekday)));
    }
  }, [frequency, selectedWeekday, existingId]);

  useScreenGuard("NewLoan", [
    { label: "Side selected", pass: !!loanSide },
    {
      label: `${counterpartyLabel} picked`,
      pass: !!counterparty,
      note: counterparty?.iou_hash || counterparty?.public_name || undefined,
    },
    { label: "Title filled", pass: !!title.trim() },
    { label: "Amount filled", pass: !!amount.trim() },
    { label: "APR filled", pass: !!aprPct?.trim?.() },
    { label: "Term filled", pass: !!termMonths?.trim?.() },
    { label: "First due date filled", pass: !!firstDueDate.trim() },
  ]);

  const runSearch = useCallback(async () => {
    const q = counterpartyQuery.trim();
    if (!q) return setResults([]);

    setSearching(true);

    try {
      const { data, error } = await supabase.functions.invoke(
        "search-counterparty",
        {
          body: { query: q },
        }
      );

      if (error) throw error;

      const safeResults = ((data?.results ?? []) as any[])
        .map((r) => ({
          id: r.id as string,
          iou_hash: r.iou_hash ?? null,
          public_name: (r.display_name || r.full_name || null) as string | null,
          avatar_url: r.avatar_url ?? null,
          iou_score: typeof r.iou_score === "number" ? r.iou_score : null,
        } as ProfileLite))
        .filter((p) => p.id !== userId);

      setResults(safeResults);
    } catch (e: any) {
      Alert.alert("Search failed", e.message ?? String(e));
    } finally {
      setSearching(false);
    }
  }, [counterpartyQuery, userId]);

  const inviteFromQuery = useCallback(async () => {
    const me = (await supabase.auth.getUser()).data.user?.id;
    if (!me) return Alert.alert("Not signed in");

    const q = counterpartyQuery.trim();
    if (!q) {
      return Alert.alert(
        "Missing info",
        `Enter the ${counterpartyLabel.toLowerCase()}'s email, phone, or name first.`
      );
    }

    const digits = digitsOnly(q);
    const email = q.includes("@") ? q : null;

    try {
      const { data, error } = await supabase
        .from("invites")
        .insert([
          {
            inviter_id: me,
            target_email: email,
            target_phone: digits || null,
          },
        ])
        .select("code")
        .single();

      if (error) throw error;

      const link = `https://iou.app/invite/${data.code}`;

      await Share.share({
        message:
          loanSide === "lend"
            ? `Hey! Join me on IOU so I can set up a loan for you: ${link}`
            : `Hey! Join me on IOU so I can request a loan from you: ${link}`,
      });
    } catch (e: any) {
      Alert.alert("Invite failed", e.message ?? String(e));
    }
  }, [counterpartyQuery, counterpartyLabel, loanSide]);

  const openCounterpartyProfile = () => {
    if (!counterparty?.id) return;
    navigation.navigate("Person", {
      personId: counterparty.id,
    });
  };

  const parsedFirstDueDate = useMemo(
    () => parseDateInput(firstDueDate),
    [firstDueDate]
  );

  const selectedQuickDate = useMemo(() => {
    if (!parsedFirstDueDate) return null;
    const current = formatDateInput(parsedFirstDueDate);

    for (const option of QUICK_DATE_OPTIONS) {
      if (formatDateInput(quickDateValue(option.key)) === current) {
        return option.key;
      }
    }

    return null;
  }, [parsedFirstDueDate]);

  const isSelfCounterparty = useMemo(() => {
    if (!counterparty || !userId) return false;
    return counterparty.id === userId;
  }, [counterparty, userId]);

  const principalCentsPreview = Math.round(
    (parseFloat(amount || "0") || 0) * 100
  );
  const aprPreview = parseFloat(aprPct || "0") || 0;
  const termPreview = Math.max(
    1,
    Math.floor(parseInt(termMonths || "0", 10) || 0)
  );

  const previewRows = useMemo(() => {
    if (!principalCentsPreview || !parsedFirstDueDate || !termPreview) {
      return [];
    }

    try {
      return generateSchedule({
        principalCents: principalCentsPreview,
        aprBps: Math.round(aprPreview * 100),
        termMonths: termPreview,
        frequency,
        firstDueDate: parsedFirstDueDate,
      });
    } catch {
      return [];
    }
  }, [
    principalCentsPreview,
    parsedFirstDueDate,
    termPreview,
    aprPreview,
    frequency,
  ]);

  const previewPaymentCount = previewRows.length;
  const previewTotalCents = previewRows.reduce(
    (sum, row) => sum + row.amount_cents,
    0
  );
  const previewFirst = previewRows[0]?.due_date ?? null;
  const previewLast = previewRows[previewRows.length - 1]?.due_date ?? null;

  const scheduleSummaryText = useMemo(() => {
    if (!parsedFirstDueDate || !previewPaymentCount) {
      return "Choose a start date to generate a live payment timeline.";
    }

    const paymentWord = previewPaymentCount === 1 ? "payment" : "payments";
    return `${previewPaymentCount} ${paymentWord} starting ${formatFancyDate(
      parsedFirstDueDate
    )}.`;
  }, [parsedFirstDueDate, previewPaymentCount]);

  const paymentDaySummaryText = useMemo(() => {
    if (!parsedFirstDueDate) return null;

    const weekday = parsedFirstDueDate.toLocaleDateString(undefined, {
      weekday: "long",
    });

    if (frequency === "weekly") {
      return `Weekly payments will land on ${weekday}.`;
    }

    if (frequency === "biweekly") {
      return `Biweekly payments will land on ${weekday}.`;
    }

    return `Payments begin on ${weekday}.`;
  }, [parsedFirstDueDate, frequency]);

  const loanSummaryText = useMemo(() => {
    if (!amount.trim() && !aprPct.trim() && !termMonths.trim()) {
      return "Set the amount, APR, and term to see your loan summary.";
    }

    const amountLabel = currencyFromInput(amount);
    const aprLabel = aprPct.trim() ? `${aprPct.trim()}% APR` : "No APR set";
    const monthWord = termPreview === 1 ? "month" : "months";

    return `${amountLabel} over ${termPreview} ${monthWord} at ${aprLabel}.`;
  }, [amount, aprPct, termPreview, termMonths]);

  const handleDateChange = (
    event: DateTimePickerEvent,
    selectedDate?: Date
  ) => {
    if (Platform.OS !== "ios") {
      setShowDatePicker(false);
    }

    if (event.type === "dismissed" || !selectedDate) return;

    const local = startOfLocalDay(selectedDate);
    setFirstDueDate(formatDateInput(local));

    if (frequency === "weekly" || frequency === "biweekly") {
      setSelectedWeekday(local.getDay());
    }
  };

  const applyQuickDate = (key: QuickDateKey) => {
    const nextDate = quickDateValue(key);
    setFirstDueDate(formatDateInput(nextDate));

    if (frequency === "weekly" || frequency === "biweekly") {
      setSelectedWeekday(nextDate.getDay());
    }

    setShowDatePicker(false);
  };

  const handleCreatePress = async () => {
    Keyboard.dismiss();

    const principalCents = Math.round((parseFloat(amount || "0") || 0) * 100);
    const aprBps = Math.round((parseFloat(aprPct || "0") || 0) * 100);
    const months = Math.max(1, Math.floor(parseInt(termMonths || "0", 10) || 0));
    const firstPaymentDate = parseDateInput(firstDueDate);

    if (!title.trim()) return Alert.alert("Error", "Enter a loan title");
    if (!principalCents) return Alert.alert("Error", "Enter a valid amount");
    if (!firstPaymentDate) {
      return Alert.alert("Error", "Choose a valid first due date.");
    }

    if (startOfLocalDay(firstPaymentDate) < startOfLocalDay(new Date())) {
      return Alert.alert("Error", "First due date cannot be in the past.");
    }

    setLoading(true);

    try {
      const me = (await supabase.auth.getUser()).data.user?.id;
      if (!me) throw new Error("No signed-in user");

      const { data: myProf, error: profErr } = await supabase
        .from("profiles")
        .select("id, email, phone, phone_verified")
        .eq("id", me)
        .single();

      if (profErr) throw profErr;

      if (!myProf?.phone_verified) {
        setLoading(false);
        return Alert.alert(
          "Verify phone",
          "Please verify your phone to continue.",
          [
            { text: "Later" },
            {
              text: "Verify now",
              onPress: () => navigation.navigate("VerifyPhone"),
            },
          ]
        );
      }

      if (!existingId) {
        if (!counterparty?.id) {
          setLoading(false);
          return Alert.alert(
            `Pick ${counterpartyLabel}`,
            `Search and select the ${counterpartyLabel.toLowerCase()}, or invite them.`,
            [{ text: "Invite", onPress: inviteFromQuery }, { text: "OK" }]
          );
        }

        if (isSelfCounterparty) {
          setLoading(false);
          return Alert.alert(
            "Invalid IOU",
            "You cannot create an IOU with yourself. Choose a different person."
          );
        }
      }

      const lenderId = loanSide === "lend" ? me : counterparty?.id ?? null;
      const borrowerId = loanSide === "lend" ? counterparty?.id ?? null : me;

      if (!lenderId || !borrowerId) {
        setLoading(false);
        throw new Error("Missing lender or borrower.");
      }

      if (lenderId === borrowerId) {
        setLoading(false);
        return Alert.alert(
          "Invalid IOU",
          "You cannot create or save an IOU where lender and borrower are the same account."
        );
      }


      if (existingId) {
        const rows = buildScheduleRows(
          existingId,
          principalCents,
          aprBps,
          months,
          frequency,
          firstPaymentDate
        );

        const paymentsJson = rows.map((r) => ({
          due_date: r.due_date,
          amount_cents: r.amount_cents,
        }));

        if (borrowerScheduleEdit) {
          // Borrower proposing payment dates — goes back to lender for approval
          const { error: rpcErr } = await supabase.rpc("propose_schedule_change", {
            p_iou_id: existingId,
            p_payments: paymentsJson,
          });
          if (rpcErr) throw rpcErr;
          Alert.alert("Schedule proposed", "Waiting for lender approval.", [
            {
              text: "OK",
              onPress: () => {
                const parent = navigation.getParent();
                if (parent) parent.navigate("HomeTab", { screen: "Home" });
                else navigation.reset({ index: 0, routes: [{ name: "Home" }] });
              },
            },
          ]);
          return;
        } else {
          // Lender finalizing schedule — bypasses triggers and forces status='open'
          const { data: rpcResult, error: rpcErr } = await supabase.rpc(
            "finalize_iou_schedule",
            {
              p_iou_id: existingId,
              p_payments: paymentsJson,
              p_title: title.trim(),
              p_lender_id: lenderId,
              p_borrower_id: borrowerId,
              p_principal_cents: principalCents,
              p_apr_bps: aprBps,
              p_start_date: formatDateInput(firstPaymentDate),
              p_term_months: months,
              p_frequency: frequency,
            }
          );
          if (rpcErr) throw rpcErr;
          const finalRow = (rpcResult ?? [])[0];
          if (!finalRow || finalRow.status !== "open") {
            throw new Error("Schedule could not be saved. Please try again.");
          }
        }

        navigation.navigate("PreviewSign", { id: existingId });
      } else {
        if (!userId) throw new Error("No signed-in user");
        if (!counterparty?.id) throw new Error("Missing counterparty.");

        await createIou({
          title: title.trim(),
          lenderId,
          borrowerId,
          principalCents,
          aprBps,
          termMonths: months,
          frequency,
          firstPaymentDate,
          createdBy: me,
          counterpartyId: counterparty.id,
        });

        Alert.alert(
          "IOU request sent",
          "The other person can now accept or deny this IOU from their inbox.",
          [
            {
              text: "Go home",
              onPress: () => {
                const parent = navigation.getParent();
                if (parent) parent.navigate("HomeTab", { screen: "Home" });
                else navigation.navigate("Home");
              },
            },
          ]
        );
      }
    } catch (e: any) {
      Alert.alert("Create failed", String(e?.message ?? e));
    } finally {
      setLoading(false);
    }
  };

  const addToCalendar = useCallback(async () => {
    if (previewRows.length === 0) return;

    try {
      const { status } = await Calendar.requestCalendarPermissionsAsync();
      if (status !== "granted") {
        Alert.alert("Permission denied", "Calendar access is required to add events.");
        return;
      }

      const calendars = await Calendar.getCalendarsAsync(Calendar.EntityTypes.EVENT);
      const defaultCal =
        calendars.find((c) => c.isPrimary) ??
        calendars.find((c) => c.allowsModifications) ??
        calendars[0];

      if (!defaultCal) {
        Alert.alert("No calendar found", "Could not find a writable calendar on this device.");
        return;
      }

      let added = 0;
      for (const row of previewRows) {
        const [year, month, day] = row.due_date.split("-").map(Number);
        const startDate = new Date(year, month - 1, day, 9, 0, 0);
        const endDate = new Date(year, month - 1, day, 9, 30, 0);

        await Calendar.createEventAsync(defaultCal.id, {
          title: `IOU Payment Due - $${(row.amount_cents / 100).toFixed(2)}`,
          startDate,
          endDate,
          notes: title.trim() ? `IOU: ${title.trim()}` : undefined,
          alarms: [{ relativeOffset: -60 * 24 }],
        });
        added++;
      }

      Alert.alert("Added to Calendar", `${added} payment event${added === 1 ? "" : "s"} added to your calendar.`);
    } catch (e: any) {
      Alert.alert("Calendar error", e?.message ?? "Could not add events.");
    }
  }, [previewRows, title]);

  const modeLabel = existingId
    ? borrowerScheduleEdit ? "Propose Schedule" : "Save Schedule"
    : "Send IOU Request";

  return (
    <KeyboardAvoidingView
      style={s.screen}
      behavior={Platform.OS === "ios" ? "padding" : undefined}
      keyboardVerticalOffset={96}
    >
      <ScrollView
        style={s.scroll}
        contentContainerStyle={s.scrollContent}
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode={Platform.OS === "ios" ? "interactive" : "on-drag"}
        showsVerticalScrollIndicator={false}
      >
        <Text style={s.h1}>{introTitle}</Text>

        {prefilling && (
          <View style={{ marginBottom: 12 }}>
            <ActivityIndicator />
          </View>
        )}

        {existingId && borrowerScheduleEdit && (
          <View style={s.borrowerEditBanner}>
            <Text style={s.borrowerEditBannerTitle}>Adjusting payment dates only</Text>
            <Text style={s.borrowerEditBannerSub}>
              The loan amount, APR, term, and frequency are set by the lender.
              You can pick payment dates that align with your payday.
            </Text>
          </View>
        )}

        {!existingId && (
          <>
            <Text style={s.label}>Type</Text>
            <View style={s.sideRow}>
              <TouchableOpacity
                onPress={() => {
                  setLoanSide("lend");
                  setCounterparty(null);
                  setCounterpartyQuery("");
                  setResults([]);
                }}
                style={[s.sideCard, loanSide === "lend" && s.sideCardActive]}
                activeOpacity={0.9}
              >
                <Text
                  style={[
                    s.sideTitle,
                    loanSide === "lend" && s.sideTitleActive,
                  ]}
                >
                  Lend
                </Text>
                <Text
                  style={[
                    s.sideSub,
                    loanSide === "lend" && s.sideSubActive,
                  ]}
                >
                  You are lending money
                </Text>
              </TouchableOpacity>

              <TouchableOpacity
                onPress={() => {
                  setLoanSide("borrow");
                  setCounterparty(null);
                  setCounterpartyQuery("");
                  setResults([]);
                }}
                style={[
                  s.sideCard,
                  loanSide === "borrow" && s.sideCardActiveBlue,
                ]}
                activeOpacity={0.9}
              >
                <Text
                  style={[
                    s.sideTitle,
                    loanSide === "borrow" && s.sideTitleBlue,
                  ]}
                >
                  Borrow
                </Text>
                <Text
                  style={[
                    s.sideSub,
                    loanSide === "borrow" && s.sideSubBlue,
                  ]}
                >
                  You are borrowing money
                </Text>
              </TouchableOpacity>
            </View>
          </>
        )}

        <Text style={[s.label, { marginTop: 16 }]}>{counterpartyLabel}</Text>

        {recent.length > 0 && !counterparty && (
          <View style={{ marginTop: 8, marginBottom: 6 }}>
            <Text style={{ color: "#666", marginBottom: 6 }}>Recent people</Text>
            <View style={s.chipsWrap}>
              {recent.map((p) => (
                <TouchableOpacity
                  key={p.id}
                  style={s.chip}
                  onPress={() => setCounterparty(p)}
                >
                  <Text style={s.chipTxt}>
                    {p.public_name || p.iou_hash || p.id.slice(0, 8)}
                  </Text>
                </TouchableOpacity>
              ))}
            </View>
          </View>
        )}

        {counterparty ? (
          <View
            style={[
              s.selectedCard,
              isSelfCounterparty && s.selectedCardError,
            ]}
          >
            <TouchableOpacity
              style={{ flex: 1 }}
              activeOpacity={0.85}
              onPress={openCounterpartyProfile}
            >
              <Text style={{ fontWeight: "800" }}>
                {counterparty.public_name || "Unnamed"}
              </Text>
              <Text style={{ color: "#666", marginTop: 2 }}>
                {counterparty.iou_hash || counterparty.id}
              </Text>
              <Text style={s.selectedHint}>Tap to open person profile</Text>
              {isSelfCounterparty && (
                <Text style={s.errorText}>
                  This matches your own account. IOUs with yourself are blocked.
                </Text>
              )}
            </TouchableOpacity>

            <View style={s.selectedActions}>
              <TouchableOpacity onPress={openCounterpartyProfile}>
                <Text style={{ color: GREEN, fontWeight: "800" }}>View</Text>
              </TouchableOpacity>

              {!borrowerScheduleEdit && (
                <TouchableOpacity onPress={() => setCounterparty(null)}>
                  <Text style={{ color: "#d00", fontWeight: "800" }}>Clear</Text>
                </TouchableOpacity>
              )}
            </View>
          </View>
        ) : (
          <>
            <TextInput
              style={s.input}
              placeholder={counterpartySearchPlaceholder}
              value={counterpartyQuery}
              onChangeText={setCounterpartyQuery}
              autoCapitalize="none"
            />
            <View style={s.searchActionsRow}>
              <View style={{ flex: 1 }}>
                <Button
                  title={searching ? "Searching…" : "Search"}
                  onPress={runSearch}
                  disabled={searching}
                />
              </View>
              <View style={{ flex: 1 }}>
                <Button title="Invite" onPress={inviteFromQuery} />
              </View>
            </View>

            {results.length > 0 && (
              <View style={s.resultsCard}>
                <Text style={s.resultsCardHeader}>Search results</Text>
                {results.map((item) => {
                  const resultMatchesMe = !!userId && item.id === userId;

                  return (
                    <TouchableOpacity
                      key={item.id}
                      style={[
                        s.resultRow,
                        { marginBottom: 8 },
                        resultMatchesMe && s.resultRowDisabled,
                      ]}
                      onPress={() => {
                        if (resultMatchesMe) {
                          Alert.alert(
                            "Invalid IOU",
                            "You cannot choose yourself as the other person on an IOU."
                          );
                          return;
                        }

                        setCounterparty(item);
                        setResults([]);
                      }}
                    >
                      <View style={{ flex: 1 }}>
                        <Text style={{ fontWeight: "700" }}>
                          {item.public_name || "Unnamed"}
                        </Text>
                        <Text style={{ color: "#666" }}>
                          {item.iou_hash || item.id}
                        </Text>
                        {typeof item.iou_score === "number" && (
                          <Text style={s.scoreMiniText}>
                            IOU Score {Math.round(item.iou_score)}
                          </Text>
                        )}
                        {resultMatchesMe && (
                          <Text style={s.errorText}>This is your account</Text>
                        )}
                      </View>
                    </TouchableOpacity>
                  );
                })}
              </View>
            )}
          </>
        )}

        <View style={[s.detailsCard, borrowerScheduleEdit && { opacity: 0.6 }]}>
          <Text style={s.detailsTitle}>
            {borrowerScheduleEdit ? "Lender-set terms (locked)" : "Loan details"}
          </Text>
          <Text style={s.detailsSub}>
            {borrowerScheduleEdit
              ? "These terms are set by the lender and cannot be changed."
              : "These terms drive the schedule preview below."}
          </Text>

          <Text style={s.fieldLabel}>Title</Text>
          <TextInput
            style={s.input}
            placeholder="Title (e.g., Car Repair)"
            value={title}
            onChangeText={setTitle}
            editable={!borrowerScheduleEdit}
          />

          <View style={s.inputGrid}>
            <View style={s.inputGridItem}>
              <Text style={s.fieldLabel}>Amount</Text>
              <TextInput
                style={s.input}
                placeholder="1000"
                keyboardType="decimal-pad"
                value={amount}
                onChangeText={setAmount}
                returnKeyType="next"
                editable={!borrowerScheduleEdit}
              />
              <Text style={s.fieldHelper}>
                Principal: {currencyFromInput(amount)}
              </Text>
            </View>

            <View style={s.inputGridItem}>
              <Text style={s.fieldLabel}>APR</Text>
              <TextInput
                style={s.input}
                placeholder="7"
                keyboardType="decimal-pad"
                value={aprPct}
                onChangeText={setAprPct}
                returnKeyType="next"
                editable={!borrowerScheduleEdit}
              />
              <Text style={s.fieldHelper}>
                {aprPct.trim()
                  ? `${aprPct.trim()}% annual rate`
                  : "No APR entered"}
              </Text>
            </View>
          </View>

          <Text style={s.fieldLabel}>Term length</Text>
          <TextInput
            style={s.input}
            placeholder="12"
            keyboardType="number-pad"
            value={termMonths}
            onChangeText={setTermMonths}
            returnKeyType="done"
            editable={!borrowerScheduleEdit}
          />
          <Text style={s.fieldHelper}>
            {termMonths.trim()
              ? `${termPreview} ${termPreview === 1 ? "month" : "months"}`
              : "Length of the loan in months"}
          </Text>

          <View style={s.loanSummaryCard}>
            <Text style={s.loanSummaryTitle}>Live loan summary</Text>
            <Text style={s.loanSummaryText}>{loanSummaryText}</Text>
          </View>
        </View>

        <View style={s.liveCard}>
          <Text style={s.liveCardTitle}>Live schedule estimate</Text>

          <View style={[s.frequencyRow, borrowerScheduleEdit && { opacity: 0.6 }]}>
            {(["weekly", "biweekly", "monthly"] as Frequency[]).map((f) => (
              <TouchableOpacity
                key={f}
                onPress={() => { if (!borrowerScheduleEdit) setFrequency(f); }}
                style={[
                  s.pill,
                  frequency === f && {
                    borderColor: GREEN,
                    backgroundColor: "#e9f6ec",
                  },
                ]}
              >
                <Text style={[s.pillText, frequency === f && { color: GREEN }]}>
                  {frequencyLabel(f)}
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          {(frequency === "weekly" || frequency === "biweekly") && (
            <>
              <Text style={s.label}>Payment day</Text>
              <View style={s.weekdayRow}>
                {WEEKDAY_OPTIONS.map((day) => (
                  <TouchableOpacity
                    key={day.value}
                    onPress={() => setSelectedWeekday(day.value)}
                    style={[
                      s.weekdayPill,
                      selectedWeekday === day.value && s.weekdayPillActive,
                    ]}
                  >
                    <Text
                      style={[
                        s.weekdayPillText,
                        selectedWeekday === day.value &&
                          s.weekdayPillTextActive,
                      ]}
                    >
                      {day.label}
                    </Text>
                  </TouchableOpacity>
                ))}
              </View>
            </>
          )}

          <Text style={[s.label, { marginTop: 16 }]}>First due date</Text>

          <View style={s.quickDateRow}>
            {QUICK_DATE_OPTIONS.map((option) => (
              <TouchableOpacity
                key={option.key}
                onPress={() => applyQuickDate(option.key)}
                style={[
                  s.quickDateChip,
                  selectedQuickDate === option.key && s.quickDateChipActive,
                ]}
                activeOpacity={0.9}
              >
                <Text
                  style={[
                    s.quickDateChipText,
                    selectedQuickDate === option.key &&
                      s.quickDateChipTextActive,
                  ]}
                >
                  {option.label}
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          <TouchableOpacity
            activeOpacity={0.9}
            style={s.dateButton}
            onPress={() => {
              Keyboard.dismiss();
              setShowDatePicker(true);
            }}
          >
            <View style={s.dateButtonInner}>
              <View style={{ flex: 1 }}>
                <Text style={s.dateButtonLabel}>📅 First payment date</Text>
                <Text
                  style={
                    parsedFirstDueDate
                      ? s.dateButtonText
                      : s.dateButtonPlaceholder
                  }
                >
                  {parsedFirstDueDate
                    ? formatFancyDate(parsedFirstDueDate)
                    : "Choose first due date"}
                </Text>
                <Text style={s.dateButtonHint}>Tap to change</Text>
              </View>
            </View>
          </TouchableOpacity>

          <Text style={s.helperText}>Payments begin on this date.</Text>

          {!!paymentDaySummaryText && (
            <Text style={s.scheduleSummarySub}>{paymentDaySummaryText}</Text>
          )}

          {showDatePicker && (
            <View style={s.datePickerWrap}>
              <DateTimePicker
                value={parsedFirstDueDate ?? nextWeekdayDate(selectedWeekday)}
                mode="date"
                display={Platform.OS === "ios" ? "spinner" : "default"}
                minimumDate={startOfLocalDay(new Date())}
                onChange={handleDateChange}
              />
              {Platform.OS === "ios" && (
                <TouchableOpacity
                  style={s.doneDateBtn}
                  onPress={() => setShowDatePicker(false)}
                >
                  <Text style={s.doneDateBtnText}>Done</Text>
                </TouchableOpacity>
              )}
            </View>
          )}

          <View style={s.scheduleSummaryBanner}>
            <Text style={s.scheduleSummaryBannerText}>{scheduleSummaryText}</Text>
            {!!existingId && (
              <Text style={s.scheduleSummaryEditText}>
                Changing the date will update the full payment schedule.
              </Text>
            )}
          </View>

          <View style={s.estimateGrid}>
            <View style={s.estimateItem}>
              <Text style={s.estimateLabel}>Payments</Text>
              <Text style={s.estimateValue}>{previewPaymentCount || "—"}</Text>
            </View>
            <View style={s.estimateItem}>
              <Text style={s.estimateLabel}>Estimated total</Text>
              <Text style={s.estimateValue}>
                {previewPaymentCount
                  ? `$${(previewTotalCents / 100).toFixed(2)}`
                  : "—"}
              </Text>
            </View>
            <View style={s.estimateItem}>
              <Text style={s.estimateLabel}>First due</Text>
              <Text style={s.estimateValue}>{previewFirst ?? "—"}</Text>
            </View>
            <View style={s.estimateItem}>
              <Text style={s.estimateLabel}>Last due</Text>
              <Text style={s.estimateValue}>{previewLast ?? "—"}</Text>
            </View>
          </View>

          {previewRows.length > 0 && (
            <View style={s.previewInlineCard}>
              <Text style={s.previewTitle}>Upcoming payment preview</Text>
              {previewRows.slice(0, 5).map((row, idx) => (
                <View key={`${row.due_date}-${idx}`} style={s.previewRow}>
                  <Text style={s.previewRowLeft}>#{idx + 1}</Text>
                  <Text style={s.previewRowMiddle}>{row.due_date}</Text>
                  <Text style={s.previewRowRight}>
                    ${(row.amount_cents / 100).toFixed(2)}
                  </Text>
                </View>
              ))}
              {previewRows.length > 5 && (
                <Text style={s.previewMore}>
                  + {previewRows.length - 5} more payments
                </Text>
              )}
              <TouchableOpacity
                style={s.calendarBtn}
                onPress={addToCalendar}
                activeOpacity={0.9}
              >
                <Text style={s.calendarBtnText}>Add to Calendar</Text>
              </TouchableOpacity>
            </View>
          )}
        </View>

        <Button
          title={loading ? `${modeLabel}…` : modeLabel}
          onPress={handleCreatePress}
          disabled={loading || isSelfCounterparty}
        />
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const s = StyleSheet.create({
  screen: {
    flex: 1,
  },

  scroll: {
    flex: 1,
  },

  scrollContent: {
    padding: 20,
    paddingBottom: 60,
    flexGrow: 1,
  },

  h1: { fontSize: 28, fontWeight: "800", marginBottom: 12 },
  label: { fontWeight: "800", color: "#333" },

  fieldLabel: {
    fontWeight: "800",
    color: "#344054",
    marginTop: 10,
    marginBottom: 2,
    fontSize: 13,
    textTransform: "uppercase",
  },

  fieldHelper: {
    marginTop: 6,
    color: "#667085",
    fontSize: 12,
    fontWeight: "700",
  },

  input: {
    borderWidth: 1,
    borderColor: "#ddd",
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 12,
    marginTop: 10,
    fontSize: 16,
    backgroundColor: "#fff",
  },

  helperText: {
    marginTop: 8,
    color: "#667085",
    fontSize: 12,
    fontWeight: "600",
    lineHeight: 18,
  },

  sideRow: {
    flexDirection: "row",
    gap: 10,
    marginTop: 10,
  },
  sideCard: {
    flex: 1,
    borderWidth: 1,
    borderColor: "#d1d5db",
    borderRadius: 14,
    padding: 14,
    backgroundColor: "#fff",
  },
  sideCardActive: {
    borderColor: GREEN,
    backgroundColor: "#eef9f0",
  },
  sideCardActiveBlue: {
    borderColor: BLUE,
    backgroundColor: "#eef4ff",
  },
  sideTitle: {
    fontSize: 18,
    fontWeight: "800",
    color: "#111",
  },
  sideTitleActive: {
    color: GREEN,
  },
  sideTitleBlue: {
    color: BLUE,
  },
  sideSub: {
    marginTop: 6,
    fontSize: 13,
    color: "#667085",
    fontWeight: "600",
  },
  sideSubActive: {
    color: "#3f6f48",
  },
  sideSubBlue: {
    color: "#3559a8",
  },

  detailsCard: {
    marginTop: 18,
    padding: 14,
    borderRadius: 16,
    backgroundColor: "#ffffff",
    borderWidth: 1,
    borderColor: "#e5e7eb",
  },
  detailsTitle: {
    fontSize: 18,
    fontWeight: "800",
    color: "#111827",
  },
  detailsSub: {
    marginTop: 4,
    color: "#667085",
    fontSize: 13,
    fontWeight: "600",
  },
  inputGrid: {
    flexDirection: "row",
    gap: 10,
    marginTop: 2,
  },
  inputGridItem: {
    flex: 1,
  },
  loanSummaryCard: {
    marginTop: 14,
    padding: 12,
    borderRadius: 12,
    backgroundColor: "#f8fafc",
    borderWidth: 1,
    borderColor: "#e2e8f0",
  },
  loanSummaryTitle: {
    fontSize: 12,
    fontWeight: "800",
    color: "#667085",
    textTransform: "uppercase",
    marginBottom: 6,
  },
  loanSummaryText: {
    color: "#0f172a",
    fontSize: 14,
    fontWeight: "700",
    lineHeight: 20,
  },

  liveCard: {
    marginTop: 18,
    marginBottom: 18,
    padding: 14,
    borderRadius: 16,
    backgroundColor: "#f8fafc",
    borderWidth: 1,
    borderColor: "#e2e8f0",
  },
  liveCardTitle: {
    fontSize: 18,
    fontWeight: "800",
    color: "#111827",
    marginBottom: 8,
  },

  pill: {
    borderWidth: 1,
    borderColor: "#ddd",
    borderRadius: 22,
    paddingHorizontal: 14,
    paddingVertical: 8,
  },
  pillText: { fontWeight: "600", color: "#333" },

  weekdayRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
    marginTop: 10,
  },
  weekdayPill: {
    borderWidth: 1,
    borderColor: "#d0d5dd",
    borderRadius: 999,
    paddingHorizontal: 12,
    paddingVertical: 8,
    backgroundColor: "#fff",
  },
  weekdayPillActive: {
    borderColor: GREEN,
    backgroundColor: "#e9f6ec",
  },
  weekdayPillText: {
    fontWeight: "700",
    color: "#344054",
  },
  weekdayPillTextActive: {
    color: GREEN,
  },

  quickDateRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
    marginTop: 10,
  },
  quickDateChip: {
    borderWidth: 1,
    borderColor: "#d0d5dd",
    borderRadius: 999,
    paddingHorizontal: 12,
    paddingVertical: 8,
    backgroundColor: "#fff",
  },
  quickDateChipActive: {
    borderColor: BLUE,
    backgroundColor: "#eef4ff",
  },
  quickDateChipText: {
    color: "#344054",
    fontWeight: "700",
    fontSize: 13,
  },
  quickDateChipTextActive: {
    color: BLUE,
  },

  dateButton: {
    marginTop: 10,
    borderWidth: 1,
    borderColor: "#ddd",
    borderRadius: 14,
    paddingHorizontal: 14,
    paddingVertical: 14,
    backgroundColor: "#fff",
  },
  dateButtonInner: {
    flexDirection: "row",
    alignItems: "center",
  },
  dateButtonLabel: {
    fontSize: 12,
    color: "#667085",
    fontWeight: "800",
    textTransform: "uppercase",
    marginBottom: 6,
  },
  dateButtonText: {
    fontSize: 16,
    color: "#111827",
    fontWeight: "800",
  },
  dateButtonPlaceholder: {
    fontSize: 16,
    color: "#98A2B3",
    fontWeight: "600",
  },
  dateButtonHint: {
    marginTop: 6,
    fontSize: 12,
    color: BLUE,
    fontWeight: "700",
  },

  datePickerWrap: {
    marginTop: 12,
    padding: 10,
    borderRadius: 12,
    backgroundColor: "#fff",
    borderWidth: 1,
    borderColor: "#e5e7eb",
  },
  doneDateBtn: {
    marginTop: 8,
    alignSelf: "flex-end",
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 999,
    backgroundColor: GREEN,
  },
  doneDateBtnText: {
    color: "#fff",
    fontWeight: "800",
  },

  scheduleSummaryBanner: {
    marginTop: 12,
    padding: 12,
    borderRadius: 12,
    backgroundColor: "#eef9f0",
    borderWidth: 1,
    borderColor: "#d6eddc",
  },
  scheduleSummaryBannerText: {
    color: "#245c2e",
    fontSize: 13,
    fontWeight: "800",
    lineHeight: 18,
  },
  scheduleSummarySub: {
    marginTop: 6,
    color: "#3f6f48",
    fontSize: 12,
    fontWeight: "700",
  },
  scheduleSummaryEditText: {
    marginTop: 6,
    color: "#5b6472",
    fontSize: 12,
    fontWeight: "700",
    lineHeight: 17,
  },

  estimateGrid: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 10,
    marginTop: 16,
  },
  estimateItem: {
    width: "47%",
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 12,
    borderWidth: 1,
    borderColor: "#e5e7eb",
  },
  estimateLabel: {
    fontSize: 12,
    fontWeight: "800",
    color: "#667085",
    textTransform: "uppercase",
    marginBottom: 4,
  },
  estimateValue: {
    fontSize: 18,
    fontWeight: "900",
    color: "#111827",
  },

  previewInlineCard: {
    marginTop: 14,
    padding: 14,
    borderRadius: 14,
    backgroundColor: "#fff",
    borderWidth: 1,
    borderColor: "#e5e7eb",
  },

  resultRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 12,
    paddingVertical: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#f3f4f6",
    backgroundColor: "#fff",
  },
  resultRowDisabled: {
    borderWidth: 1,
    borderColor: "#fecaca",
    backgroundColor: "#fef2f2",
  },
  selectedCard: {
    marginTop: 8,
    borderWidth: 1,
    borderColor: "#cbd5e1",
    backgroundColor: "#f8fafc",
    borderRadius: 10,
    padding: 12,
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
  },
  selectedCardError: {
    borderColor: "#fca5a5",
    backgroundColor: "#fef2f2",
  },
  selectedActions: {
    gap: 10,
    alignItems: "flex-end",
  },
  selectedHint: {
    marginTop: 6,
    color: GREEN,
    fontWeight: "700",
    fontSize: 12,
  },
  errorText: {
    marginTop: 6,
    color: "#b91c1c",
    fontWeight: "700",
    fontSize: 12,
  },
  scoreMiniText: {
    marginTop: 4,
    color: GREEN,
    fontWeight: "800",
    fontSize: 12,
  },
  chip: {
    backgroundColor: "#eef2ff",
    borderColor: "#c7d2fe",
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 999,
    paddingVertical: 6,
    paddingHorizontal: 10,
  },
  chipTxt: { color: "#3749a3", fontWeight: "700" },

  chipsWrap: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
  },

  searchActionsRow: {
    flexDirection: "row",
    gap: 8,
    marginTop: 8,
  },

  resultsCard: {
    marginTop: 8,
    maxHeight: 260,
    backgroundColor: "#fff",
    borderWidth: 1,
    borderColor: "#d1d5db",
    borderRadius: 14,
    overflow: "hidden",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.08,
    shadowRadius: 6,
    elevation: 3,
  },
  resultsCardHeader: {
    paddingHorizontal: 12,
    paddingTop: 10,
    paddingBottom: 6,
    fontSize: 11,
    fontWeight: "800",
    textTransform: "uppercase",
    color: "#667085",
    letterSpacing: 0.4,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#e5e7eb",
  },

  frequencyRow: {
    flexDirection: "row",
    gap: 10,
    marginTop: 6,
    marginBottom: 8,
  },

  previewTitle: {
    fontSize: 16,
    fontWeight: "800",
    color: "#111827",
    marginBottom: 10,
  },
  previewRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingVertical: 6,
  },
  previewRowLeft: {
    width: 34,
    fontWeight: "800",
    color: "#667085",
  },
  previewRowMiddle: {
    flex: 1,
    color: "#111827",
    fontWeight: "700",
  },
  previewRowRight: {
    color: GREEN,
    fontWeight: "800",
  },
  previewMore: {
    marginTop: 8,
    color: "#667085",
    fontWeight: "700",
  },

  calendarBtn: {
    marginTop: 14,
    paddingVertical: 12,
    borderRadius: 12,
    backgroundColor: BLUE,
    alignItems: "center",
  },
  calendarBtnText: {
    color: "#fff",
    fontWeight: "800",
    fontSize: 14,
  },

  borrowerEditBanner: {
    backgroundColor: "#EFF6FF",
    borderRadius: 12,
    padding: 14,
    marginBottom: 14,
    borderWidth: 1,
    borderColor: "#93C5FD",
  },
  borrowerEditBannerTitle: {
    fontSize: 14,
    fontWeight: "800",
    color: "#1D4ED8",
    marginBottom: 4,
  },
  borrowerEditBannerSub: {
    fontSize: 13,
    fontWeight: "600",
    color: "#1E40AF",
    lineHeight: 18,
  },
});
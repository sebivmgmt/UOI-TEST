import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  ScrollView,
  StyleSheet,
  KeyboardAvoidingView,
  Platform,
  Alert,
  ActivityIndicator,
  Modal,
} from "react-native";
import IouStepProgress from "../components/iou/IouStepProgress";
import {
  type Frequency,
  QUICK_DATE_OPTIONS,
  frequencyLabel,
} from "../constants/iouOptions";
import { usePersonalIouPolicy } from "../hooks/usePersonalIouPolicy";
import {
  mapPersonalIouPolicyError,
  policyStatusMessage,
  MSG_POLICY_LOAD_FAILED,
} from "../utils/personalIouPolicyErrors";
import {
  formatDateInput,
  formatFancyDate,
  nextWeekdayDate,
  parseDateInput,
  quickDateValue,
  startOfLocalDay,
} from "../utils/dateUtils";
import { generateSchedule } from "../utils/schedule";
import { buildScheduleRows } from "../utils/iouSchedule";
import { supabase } from "../supabase";
import {
  useRecentCounterparties,
  type ProfileLite,
} from "../hooks/useRecentCounterparties";
import { createIou } from "../services/iouCreationService";
import { TERMS_VERSION, PRIVACY_VERSION } from "../constants/legalVersions";
import { TERMS_TEXT, PRIVACY_TEXT } from "../constants/legalDocuments";

const BRAND = "#77B777";
const BG = "#F5F7F9";
const BLUE = "#3B82F6";
const RED = "#D9534F";
const GRAY = "#9CA3AF";

const TOTAL_STEPS = 7;
const STEP_LABELS = ["Role", "Who", "Amount", "Terms", "Schedule", "Legal", "Review"];

type LoanSide = "lend" | "borrow";

type TypeOption = {
  key: string;
  label: string;
  desc: string;
  accent: string;
  disabled?: boolean;
};

const TYPE_OPTIONS: TypeOption[] = [
  { key: "lend",        label: "Lender",         desc: "You give money to someone else.",         accent: BRAND },
  { key: "borrow",      label: "Borrower",        desc: "You receive money from someone else.",    accent: BLUE },
  { key: "buying",      label: "Buying / Split",  desc: "Split a purchase or shared expense.",     accent: GRAY, disabled: true },
  { key: "tenant",      label: "Tenant",          desc: "Track rent or housing payments.",         accent: GRAY, disabled: true },
  { key: "contracting", label: "Contracting",     desc: "Service agreements and invoices.",        accent: GRAY, disabled: true },
];

const FREQUENCIES: Frequency[] = ["weekly", "biweekly", "monthly"];

const fmt = (cents: number) => `$${(cents / 100).toFixed(2)}`;

function parsePrincipalCents(amount: string) {
  return Math.round((parseFloat(amount || "0") || 0) * 100);
}

function parseAprBps(aprPct: string): number | null {
  const normalized = aprPct.trim();

  if (!normalized) return 0;

  // Accept ordinary positive decimal percentages only. Reject partial values
  // such as "5abc", scientific notation, negative values, NaN, and Infinity.
  if (!/^(?:\d+(?:\.\d*)?|\.\d+)$/.test(normalized)) return null;

  const pct = Number(normalized);

  if (!Number.isFinite(pct) || pct < 0) return null;

  const bps = Math.round(pct * 100);

  if (!Number.isFinite(bps) || !Number.isInteger(bps) || bps < 0) {
    return null;
  }

  return bps;
}

function parseTermMonths(termMonths: string) {
  return Math.max(1, Math.floor(parseInt(termMonths || "0", 10) || 0));
}


export default function NewIouScreen({ navigation }: any) {
  const [step, setStep] = useState(0);
  const [loanSide, setLoanSide] = useState<LoanSide | null>(null);
  const [counterpartyQuery, setCounterpartyQuery] = useState("");
  const [title, setTitle] = useState("");
  const [amount, setAmount] = useState("");
  const [aprPct, setAprPct] = useState("");
  const [termMonths, setTermMonths] = useState("");
  const [frequency, setFrequency] = useState<Frequency>("biweekly");
  const [firstDueDate, setFirstDueDate] = useState(
    formatDateInput(nextWeekdayDate(4))
  );
  const [dateError, setDateError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [legalSubmitting, setLegalSubmitting] = useState(false);
  const [showTermsSchedule, setShowTermsSchedule] = useState(false);

  // Step 5 legal/consent state — reset when major terms change
  const [hasOpenedTerms, setHasOpenedTerms] = useState(false);
  const [hasOpenedPrivacy, setHasOpenedPrivacy] = useState(false);
  const [ackTermsPrivacy, setAckTermsPrivacy] = useState(false);
  const [legalInlineError, setLegalInlineError] = useState<string | null>(null);
  const [showDocModal, setShowDocModal] = useState<null | "terms" | "privacy">(null);
  const [docScrolledToBottom, setDocScrolledToBottom] = useState(false);

  const scrollViewRef = useRef<ScrollView>(null);

  // Counterparty / Who step state
  const [counterparty, setCounterparty] = useState<ProfileLite | null>(null);
  const [results, setResults] = useState<ProfileLite[]>([]);
  const [searching, setSearching] = useState(false);
  const [userId, setUserId] = useState<string | null>(null);
  const [meProfile, setMeProfile] = useState<ProfileLite | null>(null);
  const { recent, recentLoading } = useRecentCounterparties();

  // Borrower ID for jurisdiction policy: current user when borrowing, counterparty when lending.
  const borrowerIdForPolicy = useMemo(() => {
    if (!loanSide || !userId) return null;
    if (loanSide === "lend") return counterparty?.id ?? null;
    return userId;
  }, [loanSide, userId, counterparty]);

  const {
    policyStatus,
    supported: policySupported,
    maxAprBps,
    loading: policyLoading,
    error: policyError,
    refresh: refreshPolicy,
  } = usePersonalIouPolicy(borrowerIdForPolicy);

  const parsedAprBps = useMemo(() => parseAprBps(aprPct), [aprPct]);

  // Live payment summary for Terms step — available while user fills in APR/term.
  // Guards against the phantom-1-month case: parseTermMonths clamps empty/"0" to 1,
  // so we check the raw integer before computing to avoid showing misleading previews.
  const termsPreview = useMemo(() => {
    const cents = parsePrincipalCents(amount);
    const rawMonths = parseInt(termMonths.trim(), 10);
    if (!cents || !termMonths.trim() || isNaN(rawMonths) || rawMonths < 1) return null;
    const months = parseTermMonths(termMonths);

    const bps = parsedAprBps;
    if (bps === null) return null;

    const firstDate = parseDateInput(firstDueDate) ?? startOfLocalDay(new Date());

    try {
      const rows = generateSchedule({
        principalCents: cents,
        aprBps: bps,
        termMonths: months,
        frequency,
        firstDueDate: firstDate,
      });
      const total = rows.reduce((sum, r) => sum + r.amount_cents, 0);
      return { count: rows.length, total };
    } catch {
      return null;
    }
  }, [amount, parsedAprBps, termMonths, frequency, firstDueDate]);

  // Full schedule rows for Review step (placeholder iouId — not inserted yet).
  // Same raw-months guard as termsPreview to stay consistent.
  const reviewSchedule = useMemo(() => {
    const cents = parsePrincipalCents(amount);
    const rawMonths = parseInt(termMonths.trim(), 10);
    const firstDate = parseDateInput(firstDueDate);

    if (!cents || !termMonths.trim() || isNaN(rawMonths) || rawMonths < 1 || !firstDate) return null;
    const months = parseTermMonths(termMonths);

    const bps = parsedAprBps;
    if (bps === null) return null;

    try {
      return buildScheduleRows("preview", cents, bps, months, frequency, firstDate);
    } catch {
      return null;
    }
  }, [amount, parsedAprBps, termMonths, frequency, firstDueDate]);

  // Load current user for self-counterparty guard
  useEffect(() => {
    const load = async () => {
      const { data: auth } = await supabase.auth.getUser();
      const me = auth.user?.id ?? null;
      setUserId(me);
      if (!me) return;
      const { data: prof } = await supabase
        .from("profiles")
        .select("id, full_name, email, phone, phone_verified")
        .eq("id", me)
        .maybeSingle();
      setMeProfile((prof as ProfileLite | null) ?? null);
    };
    void load();
  }, []);

  // Auto-search on query change — same contract as NewLoan's runSearch
  const runSearch = useCallback(async () => {
    const q = counterpartyQuery.trim();
    if (!q) {
      setResults([]);
      return;
    }
    setSearching(true);
    try {
      const { data, error } = await supabase.functions.invoke(
        "search-counterparty",
        { body: { query: q } }
      );
      if (error) throw error;
      const safeResults = ((data?.results ?? []) as any[])
        .map((r) => ({
          id: r.id as string,
          iou_hash: r.iou_hash ?? null,
          public_name: (r.display_name || r.full_name || null) as string | null,
          avatar_url: r.avatar_url ?? null,
          public_score: typeof r.public_score === "number" ? r.public_score : null,
        } as ProfileLite))
        .filter((p) => p.id !== userId);
      setResults(safeResults);
    } catch (e: any) {
      Alert.alert("Search failed", e?.message ?? String(e));
    } finally {
      setSearching(false);
    }
  }, [counterpartyQuery, userId]);

  useEffect(() => {
    void runSearch();
  }, [runSearch]);

  // Reset legal consent whenever major terms change
  useEffect(() => {
    setHasOpenedTerms(false);
    setHasOpenedPrivacy(false);
    setAckTermsPrivacy(false);
    setLegalInlineError(null);
  }, [amount, aprPct, termMonths, frequency, firstDueDate, counterparty]);

  // Clear inline legal error when navigating away from step 5
  useEffect(() => {
    if (step !== 5) setLegalInlineError(null);
  }, [step]);

  const isSelfCounterparty = useMemo(() => {
    if (!counterparty || !userId) return false;
    return counterparty.id === userId;
  }, [counterparty, userId]);

  const goBack = () => {
    if (step === 0) {
      navigation?.goBack?.();
    } else {
      setStep((s) => s - 1);
    }
  };

  const jumpTo = (s: number) => {
    if (s < step) setStep(s);
  };

  const recordLegalAcceptances = async () => {
    setLegalSubmitting(true);
    try {
      const { error: termsErr } = await supabase.rpc("record_legal_acceptance", {
        p_document_type: "terms_of_service",
        p_document_version: TERMS_VERSION,
        p_context: "new_iou_flow",
        p_platform: Platform.OS,
      });
      if (termsErr) throw termsErr;

      const { error: privacyErr } = await supabase.rpc("record_legal_acceptance", {
        p_document_type: "privacy_policy",
        p_document_version: PRIVACY_VERSION,
        p_context: "new_iou_flow",
        p_platform: Platform.OS,
      });
      if (privacyErr) throw privacyErr;

      setStep((s) => Math.min(s + 1, TOTAL_STEPS - 1));
    } catch {
      setLegalInlineError("Could not record your acceptance. Please try again.");
    } finally {
      setLegalSubmitting(false);
    }
  };

  const openDocModal = (type: "terms" | "privacy") => {
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
    if (showDocModal === "terms") setHasOpenedTerms(true);
    else if (showDocModal === "privacy") setHasOpenedPrivacy(true);
    setShowDocModal(null);
    setDocScrolledToBottom(false);
  };

  const handleContinue = () => {
    if (step === 1) {
      if (!counterparty) {
        Alert.alert("Required", "Search and select the other person to continue.");
        return;
      }
      if (isSelfCounterparty) {
        Alert.alert("Invalid", "You cannot create an IOU with yourself.");
        return;
      }
    }
    if (step === 2) {
      if (!title.trim()) {
        Alert.alert("Required", "Enter a title for this IOU.");
        return;
      }
      if (!parsePrincipalCents(amount)) {
        Alert.alert("Required", "Enter a valid amount.");
        return;
      }
    }
    if (step === 3) {
      const rawMonths = parseInt(termMonths.trim(), 10);
      if (!termMonths.trim() || isNaN(rawMonths) || rawMonths < 1) {
        Alert.alert("Required", "Enter a term length of at least 1 month.");
        return;
      }
      // Defense in depth if the disabled Continue state is bypassed.
      if (!borrowerIdForPolicy) return;
      if (policyLoading) return;
      if (policyError) return;
      if (!policySupported) return;
      if (maxAprBps === null) return;
      if (parsedAprBps === null) return;
      if (parsedAprBps > maxAprBps) return;
    }
    if (step === 4) {
      const parsed = parseDateInput(firstDueDate);
      if (!parsed) {
        setDateError("Enter a valid date in YYYY-MM-DD format.");
        return;
      }
      if (startOfLocalDay(parsed) < startOfLocalDay(new Date())) {
        setDateError("First due date cannot be in the past.");
        return;
      }
      setDateError(null);
    }
    if (step === 5) {
      if (!hasOpenedTerms || !hasOpenedPrivacy) {
        setLegalInlineError("Open both documents above before checking the box.");
        return;
      }
      if (!ackTermsPrivacy) {
        setLegalInlineError("Check the agreement box to continue.");
        return;
      }
      setLegalInlineError(null);
      void recordLegalAcceptances();
      return;
    }
    setStep((s) => Math.min(s + 1, TOTAL_STEPS - 1));
  };

  // ─── Step 0: I AM… ───────────────────────────────────────────────────────────

  const renderStepType = () => (
    <View>
      <Text style={s.stepTitle}>I AM…</Text>
      <Text style={s.stepSub}>What's your role in this agreement?</Text>

      {TYPE_OPTIONS.filter((o) => !o.disabled).map((opt) => {
        const sel = loanSide === opt.key;
        return (
          <TouchableOpacity
            key={opt.key}
            style={[
              s.typeCard,
              sel && { backgroundColor: opt.accent, borderColor: opt.accent },
            ]}
            onPress={() => {
              setLoanSide(opt.key as LoanSide);
              setStep(1);
            }}
            activeOpacity={0.85}
          >
            <View
              style={[
                s.typeBar,
                { backgroundColor: sel ? "rgba(255,255,255,0.35)" : opt.accent },
              ]}
            />
            <View style={{ flex: 1 }}>
              <Text style={[s.typeCardTitle, sel && s.typeCardTitleSel]}>
                {opt.label}
              </Text>
              <Text style={[s.typeCardDesc, sel && s.typeCardDescSel]}>
                {opt.desc}
              </Text>
            </View>
          </TouchableOpacity>
        );
      })}

      <Text style={s.comingSoonLabel}>Coming soon</Text>
      <View style={s.comingSoonRow}>
        {TYPE_OPTIONS.filter((o) => o.disabled).map((opt) => (
          <View key={opt.key} style={s.comingSoonCard}>
            <Text style={s.comingSoonCardTitle}>{opt.label}</Text>
            <View style={s.comingSoonBadge}>
              <Text style={s.comingSoonBadgeText}>Soon</Text>
            </View>
          </View>
        ))}
      </View>
    </View>
  );

  // ─── Step 1: Who ─────────────────────────────────────────────────────────────

  const renderStepWho = () => {
    const isLend = loanSide !== "borrow";
    const placeholder = isLend ? "Search borrower…" : "Search lender…";

    return (
      <View>
        <Text style={s.stepTitle}>Who is this with?</Text>
        <Text style={s.stepSub}>
          Search by name, email, phone, or IOU handle.
        </Text>

        {counterparty ? (
          <View style={[s.selectedCard, isSelfCounterparty && s.selectedCardError]}>
            <View style={{ flex: 1 }}>
              <Text style={s.selectedName}>
                {counterparty.public_name || "Unnamed"}
              </Text>
              <Text style={s.selectedSub}>
                {counterparty.iou_hash || counterparty.id}
              </Text>
              {typeof counterparty.public_score === "number" && (
                <Text style={s.selectedScore}>
                  IOU Score {Math.round(counterparty.public_score)}
                </Text>
              )}
              {isSelfCounterparty && (
                <Text style={s.selectedSelfError}>
                  This matches your own account. IOUs with yourself are not allowed.
                </Text>
              )}
            </View>
            <TouchableOpacity
              style={s.clearBtn}
              onPress={() => {
                setCounterparty(null);
                setCounterpartyQuery("");
                setResults([]);
              }}
              activeOpacity={0.7}
            >
              <Text style={s.clearBtnText}>Clear</Text>
            </TouchableOpacity>
          </View>
        ) : (
          <>
            <View style={s.inputWrap}>
              <TextInput
                style={s.input}
                placeholder={placeholder}
                value={counterpartyQuery}
                onChangeText={setCounterpartyQuery}
                autoCapitalize="none"
                autoCorrect={false}
                autoFocus
                placeholderTextColor="#9CA3AF"
              />
            </View>

            {searching && (
              <View style={s.searchingRow}>
                <ActivityIndicator size="small" color={BRAND} />
                <Text style={s.searchingText}>Searching…</Text>
              </View>
            )}

            {results.length > 0 && (
              <View style={s.resultsCard}>
                {results.map((item, i) => (
                  <TouchableOpacity
                    key={item.id}
                    style={[s.resultRow, i > 0 && s.resultRowBorder]}
                    onPress={() => {
                      setCounterparty(item);
                      setCounterpartyQuery("");
                      setResults([]);
                    }}
                    activeOpacity={0.85}
                  >
                    <View style={{ flex: 1 }}>
                      <Text style={s.resultName}>
                        {item.public_name || "Unnamed"}
                      </Text>
                      <Text style={s.resultSub}>
                        {item.iou_hash || item.id}
                      </Text>
                      {typeof item.public_score === "number" && (
                        <Text style={s.resultScore}>
                          IOU Score {Math.round(item.public_score)}
                        </Text>
                      )}
                    </View>
                    <Text style={s.resultSelectText}>Select</Text>
                  </TouchableOpacity>
                ))}
              </View>
            )}

            {!searching && results.length === 0 && recent.length > 0 && (
              <View style={s.recentSection}>
                <Text style={s.recentLabel}>
                  {recentLoading ? "Loading recent…" : "Recent"}
                </Text>
                <View style={s.recentChips}>
                  {recent.map((p) => (
                    <TouchableOpacity
                      key={p.id}
                      style={s.recentChip}
                      onPress={() => {
                        setCounterparty(p);
                        setCounterpartyQuery("");
                        setResults([]);
                      }}
                      activeOpacity={0.8}
                    >
                      <Text style={s.recentChipText} numberOfLines={1}>
                        {p.public_name || p.iou_hash || p.id.slice(0, 8)}
                      </Text>
                    </TouchableOpacity>
                  ))}
                </View>
              </View>
            )}
          </>
        )}
      </View>
    );
  };

  // ─── Step 2: Amount ──────────────────────────────────────────────────────────

  const renderStepAmount = () => (
    <View>
      <Text style={s.stepTitle}>Amount</Text>
      <Text style={s.stepSub}>Name this IOU and set the amount.</Text>

      <Text style={s.fieldLabel}>IOU title</Text>
      <View style={s.inputWrap}>
        <TextInput
          style={s.input}
          placeholder='e.g. "Rent advance" or "Lunch loan"'
          value={title}
          onChangeText={setTitle}
          returnKeyType="done"
          placeholderTextColor="#9CA3AF"
        />
      </View>

      <Text style={s.fieldLabel}>Amount (USD)</Text>
      <View style={s.inputWrap}>
        <TextInput
          style={s.input}
          placeholder="0.00"
          value={amount}
          onChangeText={setAmount}
          keyboardType="decimal-pad"
          autoFocus
          placeholderTextColor="#9CA3AF"
        />
      </View>
    </View>
  );

  // ─── Step 3: Terms ───────────────────────────────────────────────────────────

  const renderStepTerms = () => (
    <View>
      <Text style={s.stepTitle}>Terms</Text>
      <Text style={s.stepSub}>Repayment structure.</Text>

      <Text style={s.fieldLabel}>APR %</Text>
      <View style={s.inputWrap}>
        <TextInput
          style={s.input}
          placeholder="0"
          value={aprPct}
          onChangeText={setAprPct}
          keyboardType="decimal-pad"
          autoFocus
          placeholderTextColor="#9CA3AF"
          editable={
            !policyLoading &&
            !policyError &&
            !!borrowerIdForPolicy &&
            policySupported &&
            maxAprBps !== null
          }
        />
      </View>
      {policyLoading && (
        <Text style={s.policyNotice} accessibilityLiveRegion="polite">
          Checking Personal IOU availability…
        </Text>
      )}
      {!policyLoading && policySupported && maxAprBps !== null && (
        <Text style={s.policyNoticeOk}>
          Maximum APR: {(maxAprBps / 100).toFixed(2)}% for this borrower
        </Text>
      )}
      {!policyLoading && policySupported && maxAprBps !== null && parsedAprBps === null && (
        <Text style={s.policyNoticeError} accessibilityRole="alert">
          Enter a valid non-negative APR percentage.
        </Text>
      )}
      {!policyLoading &&
        policySupported &&
        maxAprBps !== null &&
        parsedAprBps !== null &&
        parsedAprBps > maxAprBps && (
          <Text style={s.policyNoticeError} accessibilityRole="alert">
            APR exceeds the {(maxAprBps / 100).toFixed(2)}% limit for this borrower.
          </Text>
        )}
      {!policyLoading && !policySupported && policyStatus !== null && (
        <Text style={s.policyNoticeError} accessibilityRole="alert">
          {policyStatusMessage(policyStatus)}
        </Text>
      )}
      {!policyLoading && policyError && policyStatus === null && (
        <View style={s.policyErrorRow}>
          <Text style={s.policyNoticeError} accessibilityRole="alert">
            {MSG_POLICY_LOAD_FAILED}
          </Text>
          <TouchableOpacity onPress={() => { void refreshPolicy(); }} style={s.retryBtn}>
            <Text style={s.retryBtnText}>Retry</Text>
          </TouchableOpacity>
        </View>
      )}
      {!policyLoading && !policyError && policyStatus === null && borrowerIdForPolicy !== null && (
        <Text style={s.policyNotice} accessibilityLiveRegion="polite">
          Checking Personal IOU availability…
        </Text>
      )}
      <Text style={s.fieldHint}>0 = interest-free</Text>

      <Text style={s.fieldLabel}>Term (months)</Text>
      <View style={s.inputWrap}>
        <TextInput
          style={s.input}
          placeholder="12"
          value={termMonths}
          onChangeText={setTermMonths}
          keyboardType="number-pad"
          placeholderTextColor="#9CA3AF"
        />
      </View>

      <Text style={s.fieldLabel}>Payment frequency</Text>
      <View style={s.freqRow}>
        {FREQUENCIES.map((f) => {
          const sel = frequency === f;
          return (
            <TouchableOpacity
              key={f}
              style={[s.freqPill, sel && s.freqPillActive]}
              onPress={() => setFrequency(f)}
              activeOpacity={0.8}
            >
              <Text style={[s.freqPillText, sel && s.freqPillTextActive]}>
                {frequencyLabel(f)}
              </Text>
            </TouchableOpacity>
          );
        })}
      </View>

      {termsPreview && (
        <View style={s.termsSummary}>
          <Text style={s.termsSummaryText}>
            {termsPreview.count} payment{termsPreview.count !== 1 ? "s" : ""}
            {"  •  "}
            avg {fmt(Math.round(termsPreview.total / termsPreview.count))} each
            {"  •  "}
            total {fmt(termsPreview.total)}
          </Text>
        </View>
      )}

      {termsPreview && reviewSchedule && (
        <>
          <TouchableOpacity
            style={s.schedulePreviewLink}
            onPress={() => {
              if (!showTermsSchedule) {
                setTimeout(() => scrollViewRef.current?.scrollToEnd({ animated: true }), 100);
              }
              setShowTermsSchedule((v) => !v);
            }}
            activeOpacity={0.75}
          >
            <Text style={s.schedulePreviewLinkText}>
              {showTermsSchedule ? "Hide schedule ▲" : "Preview schedule ▼"}
            </Text>
          </TouchableOpacity>

          {showTermsSchedule && (
            <View style={s.scheduleCard}>
              {reviewSchedule.slice(0, 3).map((row, i) => {
                const d = parseDateInput(row.due_date);
                return (
                  <View key={i} style={[s.scheduleRow, i > 0 && s.scheduleRowBorder]}>
                    <Text style={s.scheduleRowNum}>{i + 1}</Text>
                    <Text style={s.scheduleRowDate}>
                      {d ? formatFancyDate(d) : row.due_date}
                    </Text>
                    <Text style={s.scheduleRowAmt}>{fmt(row.amount_cents)}</Text>
                  </View>
                );
              })}
              {reviewSchedule.length > 3 && (
                <View style={[s.scheduleRow, s.scheduleRowBorder]}>
                  <Text style={[s.scheduleRowDate, { color: "#9CA3AF", flex: 1 }]}>
                    +{reviewSchedule.length - 3} more payment
                    {reviewSchedule.length - 3 !== 1 ? "s" : ""}
                  </Text>
                </View>
              )}
              <View style={[s.scheduleRow, s.scheduleRowBorder, s.scheduleTotalRow]}>
                <Text style={s.scheduleTotalLabel}>Total</Text>
                <Text style={s.scheduleTotalValue}>{fmt(termsPreview.total)}</Text>
              </View>
            </View>
          )}
        </>
      )}
    </View>
  );

  // ─── Step 4: Schedule ────────────────────────────────────────────────────────

  const renderStepSchedule = () => {
    const parsedDate = parseDateInput(firstDueDate);
    return (
      <View>
        <Text style={s.stepTitle}>First payment date</Text>
        <Text style={s.stepSub}>When should the first payment be due?</Text>

        <View style={s.quickRow}>
          {QUICK_DATE_OPTIONS.map((opt) => {
            const val = formatDateInput(quickDateValue(opt.key));
            const sel = firstDueDate === val;
            return (
              <TouchableOpacity
                key={opt.key}
                style={[s.quickPill, sel && s.quickPillActive]}
                onPress={() => {
                  setFirstDueDate(val);
                  setDateError(null);
                }}
                activeOpacity={0.8}
              >
                <Text style={[s.quickPillText, sel && s.quickPillTextActive]}>
                  {opt.label}
                </Text>
              </TouchableOpacity>
            );
          })}
        </View>

        <Text style={s.fieldLabel}>Or enter a date</Text>
        <View style={[s.inputWrap, !!dateError && s.inputWrapError]}>
          <TextInput
            style={s.input}
            placeholder="YYYY-MM-DD"
            value={firstDueDate}
            onChangeText={(v) => {
              setFirstDueDate(v);
              setDateError(null);
            }}
            keyboardType="numbers-and-punctuation"
            placeholderTextColor="#9CA3AF"
          />
        </View>

        {dateError ? (
          <Text style={s.fieldError}>{dateError}</Text>
        ) : parsedDate ? (
          <Text style={s.fieldHint}>{formatFancyDate(parsedDate)}</Text>
        ) : null}
      </View>
    );
  };

  // ─── Step 5: Terms & Privacy ─────────────────────────────────────────────────

  const renderStepLegal = () => {
    const bothOpened = hasOpenedTerms && hasOpenedPrivacy;
    return (
      <View>
        <Text style={s.stepTitle}>Terms & Privacy</Text>
        <Text style={s.stepSub}>Review before you agree.</Text>

        <View style={s.ackList}>
          {[
            "This sends an IOU request. No money moves automatically.",
            "The other person must review and accept before this IOU becomes active.",
            "IOU tracks the agreement. IOU is not a lender, bank, or debt collector.",
            "Only create IOUs with people you know and trust.",
          ].map((text, i) => (
            <View key={i} style={s.ackItem}>
              <View style={s.ackDot} />
              <Text style={s.ackText}>{text}</Text>
            </View>
          ))}
        </View>

        <View style={s.legalDocsCard}>
          <TouchableOpacity
            style={s.legalDocRow}
            onPress={() => {
              openDocModal("terms");
              setLegalInlineError(null);
            }}
            activeOpacity={0.75}
          >
            <Text style={s.legalDocLabel}>Terms of Service</Text>
            <View style={s.legalDocRight}>
              {hasOpenedTerms && <Text style={s.legalDocCheck}>✓</Text>}
              <Text style={s.legalDocArrow}>›</Text>
            </View>
          </TouchableOpacity>
          <View style={s.legalDocDivider} />
          <TouchableOpacity
            style={s.legalDocRow}
            onPress={() => {
              openDocModal("privacy");
              setLegalInlineError(null);
            }}
            activeOpacity={0.75}
          >
            <Text style={s.legalDocLabel}>Privacy Policy</Text>
            <View style={s.legalDocRight}>
              {hasOpenedPrivacy && <Text style={s.legalDocCheck}>✓</Text>}
              <Text style={s.legalDocArrow}>›</Text>
            </View>
          </TouchableOpacity>
        </View>

        <TouchableOpacity
          style={[s.agreeRow, !bothOpened && s.agreeRowDisabled]}
          onPress={() => {
            if (!bothOpened) {
              setLegalInlineError("Open both documents above before checking the box.");
              return;
            }
            setAckTermsPrivacy((v) => !v);
            setLegalInlineError(null);
          }}
          activeOpacity={bothOpened ? 0.75 : 1}
        >
          <View style={[s.checkbox, ackTermsPrivacy && s.checkboxChecked]}>
            {ackTermsPrivacy && <Text style={s.checkmark}>✓</Text>}
          </View>
          <Text style={[s.agreeText, !bothOpened && s.agreeTextDisabled]}>
            I agree to the Terms of Service and Privacy Policy.
          </Text>
        </TouchableOpacity>

        {legalInlineError ? (
          <Text style={s.legalError}>{legalInlineError}</Text>
        ) : null}
      </View>
    );
  };

  // ─── Step 6: Review & Send ───────────────────────────────────────────────────

  const renderStepReview = () => {
    const parsedFirst = parseDateInput(firstDueDate);
    const lastRow = reviewSchedule?.[reviewSchedule.length - 1];
    const parsedLast = lastRow ? parseDateInput(lastRow.due_date) : null;
    const months = parseTermMonths(termMonths);
    const principalCents = parsePrincipalCents(amount);
    const counterpartyName =
      counterparty?.public_name || counterparty?.iou_hash || "—";
    const totalCents = reviewSchedule
      ? reviewSchedule.reduce((sum, r) => sum + r.amount_cents, 0)
      : termsPreview?.total ?? 0;
    const avgPaymentCents = termsPreview
      ? Math.round(termsPreview.total / termsPreview.count)
      : 0;

    const reviewRows: { label: string; value: string }[] = [
      {
        label: "Role",
        value: loanSide === "lend" ? "Lender" : "Borrower",
      },
      {
        label: loanSide === "lend" ? "Borrower" : "Lender",
        value: counterpartyName,
      },
      { label: "Title", value: title.trim() || "—" },
      {
        label: "Amount",
        value: principalCents ? fmt(principalCents) : "—",
      },
      { label: "APR", value: aprPct ? `${aprPct}%` : "0%" },
      {
        label: "Term",
        value: termMonths
          ? `${months} month${months === 1 ? "" : "s"}`
          : "—",
      },
      { label: "Frequency", value: frequencyLabel(frequency) },
      {
        label: "First due",
        value: parsedFirst ? formatFancyDate(parsedFirst) : firstDueDate || "—",
      },
      {
        label: "Last due",
        value: parsedLast
          ? formatFancyDate(parsedLast)
          : lastRow?.due_date ?? "—",
      },
      {
        label: "Est. payment",
        value: avgPaymentCents ? fmt(avgPaymentCents) : "—",
      },
      {
        label: "Total repayment",
        value: totalCents ? fmt(totalCents) : "—",
      },
    ];

    return (
      <View>
        {/* Transaction hero */}
        <View style={s.reviewHero}>
          <Text style={s.reviewHeroRole}>
            {loanSide === "lend" ? "You are lending" : "You are borrowing"}
          </Text>
          <Text style={s.reviewHeroAmount}>
            {principalCents ? fmt(principalCents) : "—"}
          </Text>
          <Text style={s.reviewHeroWith}>
            {loanSide === "lend" ? "to " : "from "}
            <Text style={s.reviewHeroName}>{counterpartyName}</Text>
          </Text>
        </View>

        <View style={s.reviewCard}>
          {reviewRows.map(({ label, value }, i) => (
            <View
              key={label}
              style={[s.reviewRow, i > 0 && s.reviewRowBorder]}
            >
              <Text style={s.reviewLabel}>{label}</Text>
              <Text style={s.reviewValue}>{value}</Text>
            </View>
          ))}
        </View>

        <Text style={s.scheduleHeading}>Payment schedule</Text>

        {reviewSchedule ? (
          <View style={s.scheduleCard}>
            {reviewSchedule.slice(0, 3).map((row, i) => {
              const d = parseDateInput(row.due_date);
              return (
                <View
                  key={i}
                  style={[s.scheduleRow, i > 0 && s.scheduleRowBorder]}
                >
                  <Text style={s.scheduleRowNum}>{i + 1}</Text>
                  <Text style={s.scheduleRowDate}>
                    {d ? formatFancyDate(d) : row.due_date}
                  </Text>
                  <Text style={s.scheduleRowAmt}>{fmt(row.amount_cents)}</Text>
                </View>
              );
            })}

            {reviewSchedule.length > 3 && (
              <View style={[s.scheduleRow, s.scheduleRowBorder]}>
                <Text style={[s.scheduleRowDate, { color: "#9CA3AF", flex: 1 }]}>
                  +{reviewSchedule.length - 3} more payment
                  {reviewSchedule.length - 3 !== 1 ? "s" : ""}
                </Text>
              </View>
            )}

            <View style={[s.scheduleRow, s.scheduleRowBorder, s.scheduleTotalRow]}>
              <Text style={s.scheduleTotalLabel}>Total</Text>
              <Text style={s.scheduleTotalValue}>{fmt(totalCents)}</Text>
            </View>
          </View>
        ) : (
          <View style={s.scheduleIncompleteCard}>
            <Text style={s.scheduleIncompleteText}>
              Complete terms and schedule steps to see payment details.
            </Text>
          </View>
        )}
      </View>
    );
  };

  // ─── Render ──────────────────────────────────────────────────────────────────

  const renderStep = () => {
    switch (step) {
      case 0: return renderStepType();
      case 1: return renderStepWho();
      case 2: return renderStepAmount();
      case 3: return renderStepTerms();
      case 4: return renderStepSchedule();
      case 5: return renderStepLegal();
      case 6: return renderStepReview();
      default: return null;
    }
  };

  const isSendDisabled = useMemo(() => {
    if (submitting) return true;
    if (!loanSide || !counterparty || isSelfCounterparty) return true;
    if (!title.trim()) return true;
    if (!parsePrincipalCents(amount)) return true;
    if (!borrowerIdForPolicy) return true;
    if (policyLoading) return true;
    if (policyError) return true;
    if (!policySupported) return true;
    if (maxAprBps === null) return true;
    if (parsedAprBps === null) return true;
    if (parsedAprBps > maxAprBps) return true;

    const rawMonths = parseInt(termMonths.trim(), 10);
    if (!termMonths.trim() || isNaN(rawMonths) || rawMonths < 1) return true;

    const parsed = parseDateInput(firstDueDate);
    if (!parsed) return true;
    if (startOfLocalDay(parsed) < startOfLocalDay(new Date())) return true;
    if (!ackTermsPrivacy) return true;

    return false;
  }, [
    submitting,
    loanSide,
    counterparty,
    isSelfCounterparty,
    title,
    amount,
    borrowerIdForPolicy,
    policyLoading,
    policyError,
    policySupported,
    maxAprBps,
    parsedAprBps,
    termMonths,
    firstDueDate,
    ackTermsPrivacy,
  ]);

  const handleSubmit = async () => {
    if (isSendDisabled) return;

    const principalCents = parsePrincipalCents(amount);
    const aprBps = parsedAprBps;
    const months = parseTermMonths(termMonths);

    if (aprBps === null) return;
    const firstPaymentDate = parseDateInput(firstDueDate);

    if (!firstPaymentDate || !counterparty || !loanSide) return;

    setSubmitting(true);
    try {
      const { data: auth } = await supabase.auth.getUser();
      const me = auth.user?.id;
      if (!me) throw new Error("No signed-in user.");

      const { data: myProf } = await supabase
        .from("profiles")
        .select("phone_verified")
        .eq("id", me)
        .single();

      if (!myProf?.phone_verified) {
        Alert.alert(
          "Verify phone",
          "Please verify your phone before sending an IOU.",
          [
            { text: "Later" },
            {
              text: "Verify now",
              onPress: () => navigation?.navigate?.("VerifyPhone"),
            },
          ]
        );
        return;
      }

      const lenderId = loanSide === "lend" ? me : counterparty.id;
      const borrowerId = loanSide === "lend" ? counterparty.id : me;

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
            text: "OK",
            onPress: () => {
              const parent = navigation?.getParent?.();
              if (parent) parent.navigate("HomeTab", { screen: "Home" });
              else navigation?.navigate?.("Home");
            },
          },
        ]
      );
    } catch (e: any) {
      console.error("[NewIouScreen] createIou failed:", e);
      Alert.alert("Could not send IOU", mapPersonalIouPolicyError(e));
    } finally {
      setSubmitting(false);
    }
  };

  const isReview = step === TOTAL_STEPS - 1;
  const isContinueDisabled =
    (step === 1 && (!counterparty || isSelfCounterparty)) ||
    (step === 3 && (
      !borrowerIdForPolicy ||
      policyLoading ||
      !!policyError ||
      !policySupported ||
      maxAprBps === null ||
      parsedAprBps === null ||
      parsedAprBps > maxAprBps
    )) ||
    legalSubmitting;

  return (
    <KeyboardAvoidingView
      style={s.flex}
      behavior={Platform.OS === "ios" ? "padding" : undefined}
      keyboardVerticalOffset={90}
    >
      {/* Header */}
      <View style={s.header}>
        <TouchableOpacity style={s.headerBack} onPress={goBack} activeOpacity={0.7}>
          <Text style={s.headerBackText}>‹ Back</Text>
        </TouchableOpacity>
        <Text style={s.headerTitle}>New IOU</Text>
        <Text style={s.headerCount}>
          {step + 1} / {TOTAL_STEPS}
        </Text>
      </View>

      {/* Progress */}
      <View style={s.progressWrap}>
        <IouStepProgress total={TOTAL_STEPS} current={step} onStepPress={jumpTo} />
        <Text style={s.stepNameLabel}>{STEP_LABELS[step]}</Text>
      </View>

      {/* Content */}
      <ScrollView
        ref={scrollViewRef}
        style={s.scroll}
        contentContainerStyle={s.scrollContent}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      >
        <View style={s.card}>{renderStep()}</View>
      </ScrollView>

      {/* Bottom controls */}
      {step > 0 && (
        <View style={s.controls}>
          <TouchableOpacity
            style={[s.backBtn, submitting && s.btnDisabledOpacity]}
            onPress={goBack}
            disabled={submitting}
            activeOpacity={0.8}
          >
            <Text style={s.backBtnText}>Back</Text>
          </TouchableOpacity>

          {!isReview ? (
            <TouchableOpacity
              style={[s.continueBtn, isContinueDisabled && s.continueBtnDisabled]}
              onPress={handleContinue}
              activeOpacity={0.85}
              disabled={isContinueDisabled}
            >
              {legalSubmitting ? (
                <ActivityIndicator color="#fff" />
              ) : (
                <Text style={s.continueBtnText}>Continue</Text>
              )}
            </TouchableOpacity>
          ) : (
            <TouchableOpacity
              style={[s.continueBtn, isSendDisabled && s.continueBtnDisabled]}
              onPress={() => { void handleSubmit(); }}
              disabled={isSendDisabled}
              activeOpacity={0.85}
            >
              {submitting ? (
                <ActivityIndicator color="#fff" />
              ) : (
                <Text style={s.continueBtnText}>Send IOU Request</Text>
              )}
            </TouchableOpacity>
          )}
        </View>
      )}
      {/* Document viewer modal — scroll to bottom required before Done is enabled */}
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
            {showDocModal === "terms"
              ? "Please review the full Terms of Service before continuing."
              : "Please review the full Privacy Policy before continuing."}
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
                {docScrolledToBottom ? "I agree" : "Review full document"}
              </Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>
    </KeyboardAvoidingView>
  );
}

const s = StyleSheet.create({
  flex: { flex: 1, backgroundColor: BG },

  // Header
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    backgroundColor: "#fff",
    paddingHorizontal: 16,
    paddingTop: 12,
    paddingBottom: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#E5E7EB",
  },
  headerBack: { minWidth: 60 },
  headerBackText: { color: BRAND, fontWeight: "700", fontSize: 16 },
  headerTitle: { fontSize: 17, fontWeight: "800", color: "#111" },
  headerCount: {
    minWidth: 60,
    textAlign: "right",
    color: "#9CA3AF",
    fontSize: 13,
    fontWeight: "600",
  },

  // Progress
  progressWrap: {
    backgroundColor: "#fff",
    paddingTop: 8,
    paddingBottom: 6,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#E5E7EB",
  },
  stepNameLabel: {
    textAlign: "center",
    fontSize: 11,
    fontWeight: "800",
    color: BRAND,
    textTransform: "uppercase",
    letterSpacing: 0.5,
    marginTop: 4,
    marginBottom: 2,
  },

  // Scroll
  scroll: { flex: 1 },
  scrollContent: { padding: 16, paddingBottom: 60 },

  // Card
  card: {
    backgroundColor: "#fff",
    borderRadius: 18,
    padding: 20,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#E5E7EB",
  },

  // Step headers
  stepTitle: {
    fontSize: 24,
    fontWeight: "800",
    color: "#111",
    marginBottom: 6,
  },
  stepSub: {
    fontSize: 15,
    color: "#6B7280",
    lineHeight: 21,
    marginBottom: 14,
  },

  // Type cards (active)
  typeCard: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: "#fff",
    borderRadius: 14,
    borderWidth: 1.5,
    borderColor: "#E5E7EB",
    padding: 16,
    marginBottom: 10,
  },
  typeBar: {
    width: 4,
    height: 40,
    borderRadius: 2,
    marginRight: 14,
  },
  typeCardTitle: { fontSize: 18, fontWeight: "800", color: "#111", marginBottom: 2 },
  typeCardTitleSel: { color: "#fff" },
  typeCardDesc: { fontSize: 13, color: "#6B7280", lineHeight: 18 },
  typeCardDescSel: { color: "rgba(255,255,255,0.85)" },

  // Coming soon row (disabled type options)
  comingSoonLabel: {
    fontSize: 11,
    fontWeight: "800",
    textTransform: "uppercase",
    color: "#9CA3AF",
    letterSpacing: 0.5,
    marginTop: 14,
    marginBottom: 8,
  },
  comingSoonRow: { flexDirection: "row", gap: 8 },
  comingSoonCard: {
    flex: 1,
    backgroundColor: "#F9FAFB",
    borderRadius: 12,
    borderWidth: 1,
    borderColor: "#E5E7EB",
    padding: 10,
    alignItems: "center",
    gap: 6,
  },
  comingSoonCardTitle: { fontSize: 12, fontWeight: "700", color: "#9CA3AF" },
  comingSoonBadge: {
    backgroundColor: "#E5E7EB",
    borderRadius: 999,
    paddingHorizontal: 6,
    paddingVertical: 2,
  },
  comingSoonBadgeText: { fontSize: 9, fontWeight: "800", color: "#9CA3AF", textTransform: "uppercase" },

  // Input
  fieldLabel: {
    fontSize: 12,
    fontWeight: "800",
    textTransform: "uppercase",
    color: "#6B7280",
    letterSpacing: 0.4,
    marginBottom: 6,
    marginTop: 10,
  },
  inputWrap: {
    borderWidth: 1,
    borderColor: "#E5E7EB",
    borderRadius: 10,
    backgroundColor: "#F9FAFB",
    overflow: "hidden",
  },
  inputWrapError: {
    borderColor: RED,
  },
  input: {
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 16,
    fontWeight: "600",
    color: "#111",
  },
  fieldError: {
    marginTop: 6,
    fontSize: 13,
    color: RED,
    fontWeight: "600",
  },
  fieldHint: {
    marginTop: 6,
    fontSize: 13,
    color: BRAND,
    fontWeight: "600",
  },
  policyNotice: {
    marginTop: 6,
    fontSize: 13,
    color: "#6B7280",
    fontWeight: "600",
  },
  policyNoticeOk: {
    marginTop: 6,
    fontSize: 13,
    color: BRAND,
    fontWeight: "600",
  },
  policyNoticeError: {
    marginTop: 6,
    fontSize: 13,
    color: RED,
    fontWeight: "600",
  },
  policyErrorRow: {
    marginTop: 6,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    flexWrap: "wrap",
  },
  retryBtn: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: RED,
  },
  retryBtnText: {
    fontSize: 12,
    fontWeight: "800",
    color: RED,
  },

  // Frequency
  freqRow: { flexDirection: "row", gap: 8, marginTop: 8 },
  freqPill: {
    flex: 1,
    paddingVertical: 10,
    borderRadius: 10,
    borderWidth: 1.5,
    borderColor: "#E5E7EB",
    alignItems: "center",
    backgroundColor: "#F9FAFB",
  },
  freqPillActive: { backgroundColor: BRAND, borderColor: BRAND },
  freqPillText: { fontSize: 13, fontWeight: "700", color: "#374151" },
  freqPillTextActive: { color: "#fff" },

  // Terms live summary
  termsSummary: {
    marginTop: 10,
    backgroundColor: "#EEF7EE",
    borderRadius: 10,
    padding: 9,
    borderWidth: 1,
    borderColor: "#C3E6C3",
  },
  termsSummaryText: {
    fontSize: 13,
    fontWeight: "700",
    color: "#3A7A3A",
    textAlign: "center",
  },
  schedulePreviewLink: {
    marginTop: 8,
    alignItems: "center",
    paddingVertical: 6,
  },
  schedulePreviewLinkText: {
    fontSize: 12,
    fontWeight: "700",
    color: BRAND,
  },

  // Quick date
  quickRow: { flexDirection: "row", gap: 8, marginBottom: 16 },
  quickPill: {
    flex: 1,
    paddingVertical: 10,
    borderRadius: 10,
    borderWidth: 1.5,
    borderColor: "#E5E7EB",
    alignItems: "center",
    backgroundColor: "#F9FAFB",
  },
  quickPillActive: { backgroundColor: BRAND, borderColor: BRAND },
  quickPillText: { fontSize: 12, fontWeight: "700", color: "#374151" },
  quickPillTextActive: { color: "#fff" },

  // Legal step — acknowledgment list
  ackList: { marginBottom: 16, gap: 8 },
  ackItem: { flexDirection: "row", alignItems: "flex-start", gap: 10 },
  ackDot: {
    width: 6,
    height: 6,
    borderRadius: 3,
    backgroundColor: BRAND,
    marginTop: 7,
    flexShrink: 0,
  },
  ackText: { flex: 1, fontSize: 13, fontWeight: "600", color: "#374151", lineHeight: 19 },

  // Legal step — document buttons
  legalDocsCard: {
    borderWidth: 1,
    borderColor: "#E5E7EB",
    borderRadius: 12,
    overflow: "hidden",
    backgroundColor: "#fff",
    marginBottom: 12,
  },
  legalDocRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 14,
    paddingVertical: 14,
  },
  legalDocLabel: { fontSize: 14, fontWeight: "700", color: "#111" },
  legalDocRight: { flexDirection: "row", alignItems: "center", gap: 6 },
  legalDocCheck: { fontSize: 14, fontWeight: "900", color: BRAND },
  legalDocArrow: { fontSize: 20, color: "#9CA3AF", lineHeight: 22 },
  legalDocDivider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: "#E5E7EB",
    marginHorizontal: 14,
  },

  // Legal step — agreement checkbox row
  agreeRow: {
    flexDirection: "row",
    alignItems: "flex-start",
    gap: 12,
    paddingVertical: 4,
  },
  agreeRowDisabled: { opacity: 0.45 },
  agreeText: { flex: 1, fontSize: 14, fontWeight: "600", color: "#111", lineHeight: 20 },
  agreeTextDisabled: { color: "#9CA3AF" },
  legalError: {
    marginTop: 10,
    fontSize: 13,
    fontWeight: "600",
    color: RED,
  },

  // Shared checkbox (used by legal step)
  checkbox: {
    width: 22,
    height: 22,
    borderRadius: 6,
    borderWidth: 1.5,
    borderColor: "#D1D5DB",
    backgroundColor: "#F9FAFB",
    alignItems: "center",
    justifyContent: "center",
    marginTop: 1,
    flexShrink: 0,
  },
  checkboxChecked: {
    backgroundColor: BRAND,
    borderColor: BRAND,
  },
  checkmark: {
    fontSize: 13,
    fontWeight: "900",
    color: "#fff",
    lineHeight: 16,
  },

  // Review hero
  reviewHero: {
    alignItems: "center",
    paddingVertical: 16,
    marginBottom: 16,
    backgroundColor: "#F9FAFB",
    borderRadius: 14,
    borderWidth: 1,
    borderColor: "#E5E7EB",
  },
  reviewHeroRole: { fontSize: 12, fontWeight: "700", color: "#9CA3AF", textTransform: "uppercase", letterSpacing: 0.5, marginBottom: 6 },
  reviewHeroAmount: { fontSize: 36, fontWeight: "900", color: "#111", marginBottom: 4 },
  reviewHeroWith: { fontSize: 14, fontWeight: "600", color: "#6B7280" },
  reviewHeroName: { fontWeight: "800", color: "#111" },

  // Review summary table
  reviewCard: {
    borderWidth: 1,
    borderColor: "#E5E7EB",
    borderRadius: 12,
    overflow: "hidden",
    marginTop: 4,
  },
  reviewRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 14,
    paddingVertical: 10,
    backgroundColor: "#fff",
  },
  reviewRowBorder: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#E5E7EB",
  },
  reviewLabel: { fontSize: 13, color: "#6B7280", fontWeight: "600" },
  reviewValue: {
    fontSize: 14,
    fontWeight: "800",
    color: "#111",
    textAlign: "right",
    flex: 1,
    marginLeft: 12,
  },

  // Schedule preview
  scheduleHeading: {
    fontSize: 12,
    fontWeight: "800",
    textTransform: "uppercase",
    color: "#6B7280",
    letterSpacing: 0.4,
    marginTop: 20,
    marginBottom: 8,
  },
  scheduleCard: {
    borderWidth: 1,
    borderColor: "#E5E7EB",
    borderRadius: 12,
    overflow: "hidden",
    backgroundColor: "#fff",
  },
  scheduleRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 14,
    paddingVertical: 10,
    gap: 10,
    backgroundColor: "#fff",
  },
  scheduleRowBorder: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#E5E7EB",
  },
  scheduleRowNum: {
    width: 22,
    fontSize: 12,
    fontWeight: "800",
    color: "#9CA3AF",
    textAlign: "center",
  },
  scheduleRowDate: {
    flex: 1,
    fontSize: 13,
    fontWeight: "600",
    color: "#374151",
  },
  scheduleRowAmt: {
    fontSize: 14,
    fontWeight: "800",
    color: "#111",
  },
  scheduleTotalRow: {
    backgroundColor: "#F9FAFB",
  },
  scheduleTotalLabel: {
    flex: 1,
    fontSize: 13,
    fontWeight: "800",
    color: "#374151",
  },
  scheduleTotalValue: {
    fontSize: 15,
    fontWeight: "900",
    color: "#111",
  },
  scheduleIncompleteCard: {
    borderWidth: 1,
    borderColor: "#E5E7EB",
    borderRadius: 12,
    padding: 16,
    backgroundColor: "#F9FAFB",
    alignItems: "center",
  },
  scheduleIncompleteText: {
    fontSize: 14,
    color: "#9CA3AF",
    textAlign: "center",
    lineHeight: 20,
  },

  // Bottom controls
  controls: {
    flexDirection: "row",
    gap: 10,
    padding: 14,
    paddingBottom: Platform.OS === "ios" ? 28 : 14,
    backgroundColor: "#fff",
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#E5E7EB",
  },
  backBtn: {
    flex: 1,
    height: 50,
    borderRadius: 14,
    borderWidth: 1.5,
    borderColor: "#E5E7EB",
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: "#F9FAFB",
  },
  backBtnText: { fontSize: 15, fontWeight: "800", color: "#374151" },
  continueBtn: {
    flex: 2,
    height: 50,
    borderRadius: 14,
    backgroundColor: BRAND,
    alignItems: "center",
    justifyContent: "center",
  },
  continueBtnDisabled: { opacity: 0.45 },
  btnDisabledOpacity: { opacity: 0.45 },
  continueBtnText: { fontSize: 15, fontWeight: "800", color: "#fff" },

  // Selected counterparty card
  selectedCard: {
    borderWidth: 1.5,
    borderColor: BRAND,
    borderRadius: 14,
    padding: 14,
    backgroundColor: "#EEF7EE",
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
  },
  selectedCardError: {
    borderColor: RED,
    backgroundColor: "#FEF2F2",
  },
  selectedName: { fontSize: 16, fontWeight: "800", color: "#111" },
  selectedSub: { fontSize: 13, color: "#6B7280", marginTop: 2 },
  selectedScore: {
    fontSize: 12,
    color: BRAND,
    fontWeight: "700",
    marginTop: 4,
  },
  selectedSelfError: {
    fontSize: 13,
    color: RED,
    fontWeight: "600",
    marginTop: 6,
  },
  clearBtn: {
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 8,
    backgroundColor: "#fff",
    borderWidth: 1,
    borderColor: "#E5E7EB",
  },
  clearBtnText: { fontSize: 13, fontWeight: "800", color: RED },

  // Search feedback
  searchingRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    marginTop: 10,
  },
  searchingText: { fontSize: 13, color: "#9CA3AF" },

  // Search results
  resultsCard: {
    marginTop: 10,
    borderWidth: 1,
    borderColor: "#E5E7EB",
    borderRadius: 12,
    overflow: "hidden",
    backgroundColor: "#fff",
  },
  resultRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 14,
    paddingVertical: 12,
    gap: 10,
  },
  resultRowBorder: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#E5E7EB",
  },
  resultName: { fontSize: 15, fontWeight: "800", color: "#111" },
  resultSub: { fontSize: 13, color: "#6B7280", marginTop: 2 },
  resultScore: { fontSize: 12, color: BRAND, fontWeight: "700", marginTop: 3 },
  resultSelectText: {
    fontSize: 13,
    fontWeight: "800",
    color: BRAND,
  },

  // Recent
  recentSection: { marginTop: 20 },
  recentLabel: {
    fontSize: 11,
    fontWeight: "800",
    textTransform: "uppercase",
    color: "#9CA3AF",
    letterSpacing: 0.5,
    marginBottom: 10,
  },
  recentChips: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  recentChip: {
    backgroundColor: "#F3F4F6",
    borderRadius: 999,
    paddingHorizontal: 12,
    paddingVertical: 7,
    borderWidth: 1,
    borderColor: "#E5E7EB",
  },
  recentChipText: {
    fontSize: 13,
    fontWeight: "700",
    color: "#374151",
    maxWidth: 140,
  },

  // Document viewer modal
  modalContainer: { flex: 1, backgroundColor: "#fff" },
  modalHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    padding: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#E5E7EB",
  },
  modalTitle: { fontSize: 17, fontWeight: "800", color: "#111" },
  modalClose: { padding: 4 },
  modalCloseTxt: { color: BLUE, fontWeight: "700", fontSize: 15 },
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
  modalScroll: { flex: 1 },
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
    backgroundColor: BRAND,
    borderRadius: 12,
    paddingVertical: 16,
    alignItems: "center",
  },
  modalReadBtnDisabled: { backgroundColor: "#D1D5DB" },
  modalReadBtnTxt: { color: "#fff", fontWeight: "900", fontSize: 16 },
});

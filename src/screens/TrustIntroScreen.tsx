// src/screens/TrustIntroScreen.tsx
import React, { useState } from "react";
import {
  ActivityIndicator,
  Platform,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from "react-native";
import { supabase } from "../supabase";

const GREEN = "#77B777";
const GREEN_DARK = "#5F9F5F";
const RED = "#D9534F";
const BLUE = "#3B82F6";
const AMBER = "#B7791F";
const BG = "#F5F7F9";
const TOTAL_STEPS = 8;

const EDUCATION_KEY = "iou_trust_intro";
const EDUCATION_VERSION = "2026-05-30";
const EDUCATION_CONTEXT = "trust_intro_screen";

const PILLARS = [
  { n: "1", title: "Payment Reliability", body: "Whether payments are completed early, on time, late, missed, reversed, or recovered." },
  { n: "2", title: "Obligation Strength", body: "How serious the obligation was, including amount, term length, repayment speed, and difficulty." },
  { n: "3", title: "Proof Depth", body: "How strongly IOU can verify what happened, from manual confirmation to verified payment rails." },
  { n: "4", title: "Housing & Recurring Stability", body: "Consistency with rent, phone bills, utilities, and other recurring responsibilities." },
  { n: "5", title: "Relationship Trust", body: "Whether trust is broad, healthy, and real, including counterparty diversity and no-score family/private lanes." },
  { n: "6", title: "Fairness & Conduct", body: "How borrowers and lenders behave, including fair terms, extensions, disputes, and confirmation behavior." },
  { n: "7", title: "Trust Intelligence", body: "How IOU learns from outcomes, explains trust, tracks model versions, and keeps reports auditable." },
];

const CONFIRMATIONS = [
  "I understand IOU Trust is based on my real activity and verified obligations.",
  "I understand some actions can improve or reduce trust signals.",
  "I understand family/private/no-score agreements do not affect IOU Trust by default.",
  "I understand my Trust Report is private unless I choose to share it.",
];

const STEP_TITLES = [
  "Welcome to IOU Trust",
  "What IOU Trust Is",
  "The 7 Pillars of IOU Trust",
  "What Can Help",
  "What Can Hurt",
  "What Does Not Count By Default",
  "Privacy and Trust Reports",
  "I Understand",
];

function BulletItem({ label, body, color = GREEN_DARK }: { label: string; body?: string; color?: string }) {
  return (
    <View style={s.bulletRow}>
      <View style={[s.bulletDot, { backgroundColor: color }]} />
      <View style={{ flex: 1 }}>
        <Text style={s.bulletLabel}>{label}</Text>
        {body ? <Text style={s.bulletBody}>{body}</Text> : null}
      </View>
    </View>
  );
}

function PillarCard({ n, title, body }: { n: string; title: string; body: string }) {
  return (
    <View style={s.pillarCard}>
      <View style={s.pillarNumCircle}>
        <Text style={s.pillarNumText}>{n}</Text>
      </View>
      <View style={{ flex: 1 }}>
        <Text style={s.pillarTitle}>{title}</Text>
        <Text style={s.pillarBody}>{body}</Text>
      </View>
    </View>
  );
}

function CheckRow({
  label,
  checked,
  onToggle,
}: {
  label: string;
  checked: boolean;
  onToggle: () => void;
}) {
  return (
    <TouchableOpacity style={s.checkRow} onPress={onToggle} activeOpacity={0.75}>
      <View style={[s.checkbox, checked && s.checkboxChecked]}>
        {checked && <Text style={s.checkmark}>✓</Text>}
      </View>
      <Text style={[s.checkLabel, checked && s.checkLabelChecked]}>{label}</Text>
    </TouchableOpacity>
  );
}

export default function TrustIntroScreen({ navigation }: any) {
  const [step, setStep] = useState(0);
  const [checked, setChecked] = useState([false, false, false, false]);
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  const isLast = step === TOTAL_STEPS - 1;
  const allChecked = checked.every(Boolean);

  async function handleComplete() {
    setSubmitError(null);
    setSubmitting(true);
    try {
      const me = (await supabase.auth.getUser()).data.user;
      if (!me?.id) {
        setSubmitError("Session error. Please sign out and back in.");
        return;
      }

      const { error } = await supabase.rpc("record_trust_education_acceptance", {
        p_user_id: me.id,
        p_education_key: EDUCATION_KEY,
        p_education_version: EDUCATION_VERSION,
        p_context: EDUCATION_CONTEXT,
        p_platform: Platform.OS,
        p_accepted_statements: CONFIRMATIONS,
        p_metadata: {},
      });

      if (error) {
        console.error("[TrustIntro] record_trust_education_acceptance error:", error);
        setSubmitError("We couldn't save your Trust Intro completion. Please try again.");
        return;
      }

      navigation.goBack();
    } finally {
      setSubmitting(false);
    }
  }

  function goNext() {
    if (step < TOTAL_STEPS - 1) {
      setStep((s) => s + 1);
    } else {
      void handleComplete();
    }
  }

  function goPrev() {
    if (step > 0) {
      setSubmitError(null);
      setStep((s) => s - 1);
    }
  }

  function toggleCheck(i: number) {
    setChecked((prev) => prev.map((v, idx) => (idx === i ? !v : v)));
    setSubmitError(null);
  }

  function renderContent() {
    switch (step) {
      case 0:
        return (
          <>
            <Text style={s.stepIntro}>
              IOU Trust is a progress and transparency system built around real agreements. It reflects how you handle real financial obligations. Not estimates or assumptions.
            </Text>
            <View style={s.quoteCard}>
              <Text style={s.quoteText}>
                "IOU Trust is built from real obligations, proof, relationships, and outcomes. Not guesses."
              </Text>
            </View>
            <Text style={s.stepIntro}>
              The next few screens walk you through how IOU Trust works, what affects it, and how your privacy is protected.
            </Text>
          </>
        );

      case 1:
        return (
          <>
            <Text style={s.stepIntro}>IOU Trust gives you a verified picture of your financial reputation:</Text>
            <BulletItem label="Verified agreement history" body="Who you've transacted with and how it went." />
            <BulletItem label="Proof depth" body="How strongly IOU can verify what happened." />
            <BulletItem label="Visible trust" body="The portion of your score not offset by active exposure." />
            <BulletItem label="Recurring reliability" body="Rent, phone, utilities, and other regular responsibilities." />
          </>
        );

      case 2:
        return (
          <>
            <Text style={s.stepIntro}>
              IOU Trust is calculated across 7 dimensions. Each one captures a different aspect of how you handle obligations.
            </Text>
            {PILLARS.map((p) => (
              <PillarCard key={p.n} n={p.n} title={p.title} body={p.body} />
            ))}
          </>
        );

      case 3:
        return (
          <>
            <Text style={s.stepIntro}>These actions build a stronger trust profile:</Text>
            <BulletItem label="On-time or early payments" color={GREEN_DARK} />
            <BulletItem label="Meaningful obligations with real amounts and terms" color={GREEN_DARK} />
            <BulletItem label="Verified rent, phone, and utility streams" color={GREEN_DARK} />
            <BulletItem label="More verified counterparties" color={GREEN_DARK} />
            <BulletItem label="Low dispute rate" color={GREEN_DARK} />
            <BulletItem label="Fair lending behavior" color={GREEN_DARK} />
            <BulletItem label="Recovery after problems" color={GREEN_DARK} />
          </>
        );

      case 4:
        return (
          <>
            <Text style={s.stepIntro}>These actions reduce trust signals:</Text>
            <BulletItem label="Defaults and missed payments" color={RED} />
            <BulletItem label="Reversals and failed payments" color={RED} />
            <BulletItem label="Disputes and contested claims" color={RED} />
            <BulletItem label="Repeated same-person IOUs with low counterparty diversity" color={RED} />
            <BulletItem label="High active exposure" color={AMBER} />
            <BulletItem label="Abusive lending behavior" color={RED} />
          </>
        );

      case 5:
        return (
          <>
            <Text style={s.stepIntro}>
              These agreement types do not affect IOU Trust by default, even when recorded in the app:
            </Text>
            <BulletItem label="Family or no-score IOUs" color="#9CA3AF" />
            <BulletItem label="Self or no-score IOUs" color="#9CA3AF" />
            <BulletItem label="Private record-only agreements" color="#9CA3AF" />
            <BulletItem label="Cancelled or archived agreements" color="#9CA3AF" />
            <BulletItem label="Unverified claims" color="#9CA3AF" />
          </>
        );

      case 6:
        return (
          <>
            <Text style={s.stepIntro}>Your data stays private. You stay in control.</Text>
            <BulletItem label="Phone and email can help someone find you in the app" color={BLUE} />
            <BulletItem label="Only your consent can reveal your trust data to others" color={BLUE} />
            <BulletItem label="Your Trust Report is private by default" color={BLUE} />
            <BulletItem label="You choose who can view it, for how long, and at what scope" color={BLUE} />
            <BulletItem label="You can revoke access and see a full access log at any time" color={BLUE} />
          </>
        );

      case 7:
        return (
          <>
            <Text style={s.stepIntro}>
              Before continuing, confirm that you understand how IOU Trust works.
            </Text>
            {CONFIRMATIONS.map((label, i) => (
              <CheckRow
                key={i}
                label={label}
                checked={checked[i]}
                onToggle={() => toggleCheck(i)}
              />
            ))}
            {!allChecked && !submitError && (
              <Text style={s.checkHint}>Check all boxes to continue.</Text>
            )}
            {submitError && (
              <Text style={s.errorText}>{submitError}</Text>
            )}
          </>
        );

      default:
        return null;
    }
  }

  const nextDisabled = (isLast && !allChecked) || submitting;

  return (
    <SafeAreaView style={s.root}>
      {/* Progress bar */}
      <View style={s.progressWrap}>
        <View style={s.progressTrack}>
          <View
            style={[
              s.progressFill,
              { width: `${((step + 1) / TOTAL_STEPS) * 100}%` as any },
            ]}
          />
        </View>
        <Text style={s.progressLabel}>{step + 1} of {TOTAL_STEPS}</Text>
      </View>

      {/* Step title */}
      <View style={s.titleWrap}>
        <Text style={s.stepTitle}>{STEP_TITLES[step]}</Text>
      </View>

      {/* Scrollable content */}
      <ScrollView
        style={s.scroll}
        contentContainerStyle={s.contentPad}
        showsVerticalScrollIndicator={false}
        keyboardShouldPersistTaps="handled"
      >
        {renderContent()}
        <View style={{ height: 24 }} />
      </ScrollView>

      {/* Navigation buttons */}
      <View style={s.navRow}>
        <TouchableOpacity
          style={[s.navBtn, s.navBtnSecondary, step === 0 && s.navBtnHidden]}
          onPress={goPrev}
          disabled={step === 0 || submitting}
          activeOpacity={0.75}
        >
          <Text style={s.navBtnSecondaryText}>Back</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={[s.navBtn, s.navBtnPrimary, nextDisabled && s.navBtnDisabled]}
          onPress={goNext}
          disabled={nextDisabled}
          activeOpacity={0.85}
        >
          {submitting ? (
            <ActivityIndicator color="#fff" size="small" />
          ) : (
            <Text style={s.navBtnPrimaryText}>
              {isLast ? "I Understand" : "Next"}
            </Text>
          )}
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: BG },

  progressWrap: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 20,
    paddingTop: 16,
    paddingBottom: 8,
  },
  progressTrack: {
    flex: 1,
    height: 5,
    borderRadius: 3,
    backgroundColor: "#E5E7EB",
    overflow: "hidden",
  },
  progressFill: {
    height: "100%",
    borderRadius: 3,
    backgroundColor: GREEN,
  },
  progressLabel: {
    fontSize: 12,
    fontWeight: "700",
    color: "#9CA3AF",
    minWidth: 42,
    textAlign: "right",
  },

  titleWrap: {
    paddingHorizontal: 20,
    paddingBottom: 12,
  },
  stepTitle: {
    fontSize: 22,
    fontWeight: "900",
    color: "#111",
    lineHeight: 28,
  },

  scroll: { flex: 1 },
  contentPad: { paddingHorizontal: 20, paddingTop: 4 },

  stepIntro: {
    fontSize: 15,
    color: "#444",
    lineHeight: 23,
    marginBottom: 18,
  },

  quoteCard: {
    backgroundColor: "#F0FDF4",
    borderRadius: 12,
    padding: 16,
    marginBottom: 18,
    borderLeftWidth: 3,
    borderLeftColor: GREEN,
  },
  quoteText: {
    fontSize: 15,
    fontWeight: "700",
    color: GREEN_DARK,
    lineHeight: 22,
    fontStyle: "italic",
  },

  bulletRow: {
    flexDirection: "row",
    gap: 12,
    marginBottom: 14,
    alignItems: "flex-start",
  },
  bulletDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    marginTop: 6,
    flexShrink: 0,
  },
  bulletLabel: { fontSize: 15, fontWeight: "700", color: "#111", lineHeight: 22 },
  bulletBody: { fontSize: 13, color: "#667085", lineHeight: 20, marginTop: 2 },

  pillarCard: {
    flexDirection: "row",
    gap: 12,
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 12,
    marginBottom: 10,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: "#E5E7EB",
    alignItems: "flex-start",
  },
  pillarNumCircle: {
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: GREEN,
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    marginTop: 1,
  },
  pillarNumText: { color: "#fff", fontWeight: "900", fontSize: 13 },
  pillarTitle: { fontSize: 14, fontWeight: "800", color: "#111", marginBottom: 3 },
  pillarBody: { fontSize: 12, color: "#667085", lineHeight: 18 },

  checkRow: {
    flexDirection: "row",
    gap: 12,
    marginBottom: 16,
    alignItems: "flex-start",
  },
  checkbox: {
    width: 24,
    height: 24,
    borderRadius: 6,
    borderWidth: 2,
    borderColor: "#D1D5DB",
    backgroundColor: "#fff",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    marginTop: 1,
  },
  checkboxChecked: {
    borderColor: GREEN_DARK,
    backgroundColor: GREEN_DARK,
  },
  checkmark: { color: "#fff", fontSize: 14, fontWeight: "900", lineHeight: 16 },
  checkLabel: { flex: 1, fontSize: 14, color: "#444", lineHeight: 22 },
  checkLabelChecked: { color: "#111", fontWeight: "700" },
  checkHint: {
    fontSize: 13,
    color: "#9CA3AF",
    marginTop: 4,
    textAlign: "center",
  },
  errorText: {
    fontSize: 13,
    color: RED,
    marginTop: 8,
    textAlign: "center",
    lineHeight: 20,
  },

  navRow: {
    flexDirection: "row",
    gap: 12,
    paddingHorizontal: 20,
    paddingTop: 12,
    paddingBottom: 16,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#E5E7EB",
    backgroundColor: BG,
  },
  navBtn: {
    flex: 1,
    paddingVertical: 14,
    borderRadius: 12,
    alignItems: "center",
    justifyContent: "center",
  },
  navBtnPrimary: { backgroundColor: GREEN_DARK },
  navBtnSecondary: {
    backgroundColor: "#fff",
    borderWidth: 1,
    borderColor: "#E5E7EB",
  },
  navBtnDisabled: { opacity: 0.4 },
  navBtnHidden: { opacity: 0 },
  navBtnPrimaryText: { color: "#fff", fontWeight: "800", fontSize: 15 },
  navBtnSecondaryText: { color: "#374151", fontWeight: "700", fontSize: 15 },
});

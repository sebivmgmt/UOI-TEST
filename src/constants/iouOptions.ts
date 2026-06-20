import type { QuickDateKey } from "../utils/dateUtils";

export type Frequency = "weekly" | "biweekly" | "monthly";

// Conservative platform APR cap for standard peer IOUs.
// Based on the stricter of the common state thresholds relevant to IOU's current
// user base (Georgia ~16% for written small loans, Florida ~18%).
// This is a UX guard only — the backend remains authoritative.
// This constant must eventually be replaced by a jurisdiction-aware compliance
// rule engine that evaluates borrower/lender state, loan amount, loan type,
// exemptions, and licensing status before setting an enforceable cap.
export const STANDARD_IOU_MAX_APR_PCT = 16;

export const WEEKDAY_OPTIONS = [
  { label: "Sun", value: 0 },
  { label: "Mon", value: 1 },
  { label: "Tue", value: 2 },
  { label: "Wed", value: 3 },
  { label: "Thu", value: 4 },
  { label: "Fri", value: 5 },
  { label: "Sat", value: 6 },
] as const;

export const QUICK_DATE_OPTIONS: { key: QuickDateKey; label: string }[] = [
  { key: "today", label: "Today" },
  { key: "tomorrow", label: "Tomorrow" },
  { key: "nextFriday", label: "Next Friday" },
];

export function frequencyLabel(value: Frequency): string {
  if (value === "weekly") return "Weekly";
  if (value === "biweekly") return "Biweekly";
  return "Monthly";
}

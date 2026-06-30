import type { QuickDateKey } from "../utils/dateUtils";

export type Frequency = "weekly" | "biweekly" | "monthly";

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

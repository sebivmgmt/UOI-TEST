export type QuickDateKey = "today" | "tomorrow" | "nextFriday";

export function formatDateInput(date: Date): string {
  const y = date.getFullYear();
  const m = `${date.getMonth() + 1}`.padStart(2, "0");
  const d = `${date.getDate()}`.padStart(2, "0");
  return `${y}-${m}-${d}`;
}

export function formatFancyDate(date: Date): string {
  return date.toLocaleDateString(undefined, {
    weekday: "long",
    month: "long",
    day: "numeric",
    year: "numeric",
  });
}

export function parseDateInput(value: string): Date | null {
  const trimmed = value.trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) return null;

  const [y, m, d] = trimmed.split("-").map(Number);
  const date = new Date(y, m - 1, d);

  if (
    date.getFullYear() !== y ||
    date.getMonth() !== m - 1 ||
    date.getDate() !== d
  ) {
    return null;
  }

  return date;
}

export function startOfLocalDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

export function addDays(date: Date, days: number): Date {
  const base = startOfLocalDay(date);
  return new Date(base.getFullYear(), base.getMonth(), base.getDate() + days);
}

export function nextWeekdayDate(targetWeekday: number): Date {
  const today = startOfLocalDay(new Date());
  const currentWeekday = today.getDay();
  let offset = (targetWeekday - currentWeekday + 7) % 7;
  if (offset === 0) offset = 7;
  return addDays(today, offset);
}

export function inferWeekdayFromDate(dateValue: string): number | null {
  const parsed = parseDateInput(dateValue);
  if (!parsed) return null;
  return parsed.getDay();
}

export function quickDateValue(key: QuickDateKey): Date {
  const today = startOfLocalDay(new Date());

  if (key === "today") return today;
  if (key === "tomorrow") return addDays(today, 1);
  return nextWeekdayDate(5);
}

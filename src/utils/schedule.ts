// src/utils/schedule.ts
export type ScheduleFrequency = 'weekly' | 'biweekly' | 'monthly';

export type ScheduleItem = {
  due_date: string;
  amount_cents: number;
};

type GenerateScheduleArgs = {
  principalCents: number;
  aprBps?: number;
  termMonths: number;
  frequency: ScheduleFrequency;
  firstDueDate: Date;
};

const MS_PER_DAY = 24 * 60 * 60 * 1000;

function startOfLocalDay(date: Date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function formatLocalDate(date: Date) {
  const y = date.getFullYear();
  const m = `${date.getMonth() + 1}`.padStart(2, '0');
  const d = `${date.getDate()}`.padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function addDays(date: Date, days: number) {
  return new Date(startOfLocalDay(date).getTime() + days * MS_PER_DAY);
}

function daysInMonth(year: number, monthIndexZeroBased: number) {
  return new Date(year, monthIndexZeroBased + 1, 0).getDate();
}

function addMonthsClamped(date: Date, monthsToAdd: number) {
  const base = startOfLocalDay(date);
  const originalDay = base.getDate();

  const targetYear = base.getFullYear();
  const targetMonth = base.getMonth() + monthsToAdd;

  const monthStart = new Date(targetYear, targetMonth, 1);
  const maxDay = daysInMonth(monthStart.getFullYear(), monthStart.getMonth());
  const safeDay = Math.min(originalDay, maxDay);

  return new Date(monthStart.getFullYear(), monthStart.getMonth(), safeDay);
}

function getPeriods(termMonths: number, frequency: ScheduleFrequency) {
  const safeMonths = Math.max(1, Math.floor(termMonths || 0));

  if (frequency === 'monthly') return safeMonths;
  // 26 biweekly periods per year (52 weeks ÷ 2), matching getRatePerPeriod
  if (frequency === 'biweekly') return Math.round(safeMonths * (26 / 12));
  // 52 weekly periods per year, matching getRatePerPeriod
  return Math.round(safeMonths * (52 / 12));
}

function getRatePerPeriod(aprBps: number, frequency: ScheduleFrequency) {
  const apr = (aprBps || 0) / 10000;

  if (frequency === 'monthly') return apr / 12;
  if (frequency === 'biweekly') return apr / 26;
  return apr / 52;
}

function buildPaymentAmounts(
  principalCents: number,
  aprBps: number,
  periods: number,
  frequency: ScheduleFrequency
) {
  const principalDollars = principalCents / 100;
  const ratePer = getRatePerPeriod(aprBps, frequency);

  const rawPayment =
    ratePer > 0
      ? (principalDollars * ratePer) / (1 - Math.pow(1 + ratePer, -periods))
      : principalDollars / periods;

  const roundedBaseCents = Math.round(rawPayment * 100);
  const amounts = Array.from({ length: periods }, () => roundedBaseCents);

  // Absorb per-payment rounding error into the last payment.
  // For 0% APR: target is the exact principal.
  // For APR: target is the nearest-cent sum of the amortized schedule.
  const targetTotal =
    ratePer > 0
      ? Math.round(rawPayment * periods * 100)
      : principalCents;
  const diff = targetTotal - roundedBaseCents * periods;
  amounts[amounts.length - 1] += diff;

  return amounts;
}

export function generateSchedule({
  principalCents,
  aprBps = 0,
  termMonths,
  frequency,
  firstDueDate,
}: GenerateScheduleArgs): ScheduleItem[] {
  const periods = getPeriods(termMonths, frequency);
  const first = startOfLocalDay(firstDueDate);
  const amounts = buildPaymentAmounts(
    principalCents,
    aprBps,
    periods,
    frequency
  );

  const out: ScheduleItem[] = [];

  for (let i = 0; i < periods; i++) {
    let dueDate: Date;

    if (frequency === 'monthly') {
      dueDate = addMonthsClamped(first, i);
    } else if (frequency === 'biweekly') {
      dueDate = addDays(first, i * 14);
    } else {
      dueDate = addDays(first, i * 7);
    }

    out.push({
      due_date: formatLocalDate(dueDate),
      amount_cents: amounts[i],
    });
  }

  return out;
}
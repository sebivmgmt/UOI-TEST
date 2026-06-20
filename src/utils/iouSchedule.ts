import { generateSchedule } from "./schedule";
import type { Frequency } from "../constants/iouOptions";

export function buildScheduleRows(
  iouId: string,
  principalCents: number,
  aprBps: number,
  months: number,
  freq: Frequency,
  firstPaymentDate: Date
) {
  return generateSchedule({
    principalCents,
    aprBps,
    frequency: freq,
    termMonths: months,
    firstDueDate: firstPaymentDate,
  }).map((p) => ({
    iou_id: iouId,
    due_date: p.due_date,
    amount_cents: p.amount_cents,
    status: "scheduled",
  }));
}

import { supabase } from "../supabase";
import { generateSchedule } from "../utils/schedule";
import { formatDateInput } from "../utils/dateUtils";
import type { Frequency } from "../constants/iouOptions";

export type CreateIouParams = {
  title: string;
  lenderId: string;
  borrowerId: string;
  principalCents: number;
  aprBps: number;
  termMonths: number;
  frequency: Frequency;
  firstPaymentDate: Date;
  createdBy: string;
  counterpartyId: string;
};

export async function createIou(params: CreateIouParams): Promise<{ id: string }> {
  const {
    title,
    lenderId,
    borrowerId,
    principalCents,
    aprBps,
    termMonths,
    frequency,
    firstPaymentDate,
    createdBy,
    counterpartyId,
  } = params;

  if (!lenderId) throw new Error("lenderId is required");
  if (!borrowerId) throw new Error("borrowerId is required");
  if (lenderId === borrowerId) throw new Error("lenderId and borrowerId must differ");
  if (!Number.isInteger(aprBps) || aprBps < 0)
    throw new Error("aprBps must be a non-negative integer");

  const schedulePreview = generateSchedule({
    principalCents,
    aprBps,
    termMonths,
    frequency,
    firstDueDate: firstPaymentDate,
  });

  const { data: iou, error: iouErr } = await supabase
    .from("ious")
    .insert([
      {
        title,
        lender_id: lenderId,
        borrower_id: borrowerId,
        principal_cents: principalCents,
        apr_bps: aprBps,
        start_date: formatDateInput(firstPaymentDate),
        term_months: termMonths,
        frequency,
        status: "open",
        created_by: createdBy,
        requested_action_by: counterpartyId,
        total_installments: schedulePreview.length,
        paid_installments: 0,
      },
    ])
    .select("id")
    .single();

  if (iouErr || !iou) throw iouErr ?? new Error("Insert failed");

  const rows = schedulePreview.map((p) => ({
    iou_id: iou.id,
    due_date: p.due_date,
    amount_cents: p.amount_cents,
    status: "scheduled",
  }));

  const { error: payErr } = await supabase.from("payments").insert(rows);
  if (payErr) throw payErr;

  return { id: iou.id };
}

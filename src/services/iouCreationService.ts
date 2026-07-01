import { supabase } from "../supabase";
import { formatDateInput } from "../utils/dateUtils";
import { TERMS_VERSION, PRIVACY_VERSION } from "../constants/legalVersions";
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
  } = params;

  if (!lenderId) throw new Error("lenderId is required");
  if (!borrowerId) throw new Error("borrowerId is required");
  if (lenderId === borrowerId) throw new Error("lenderId and borrowerId must differ");
  if (!Number.isInteger(aprBps) || aprBps < 0)
    throw new Error("aprBps must be a non-negative integer");

  const { data, error } = await supabase.rpc("create_iou_with_schedule", {
    p_title: title,
    p_lender_id: lenderId,
    p_borrower_id: borrowerId,
    p_principal_cents: principalCents,
    p_apr_bps: aprBps,
    p_start_date: formatDateInput(firstPaymentDate),
    p_term_months: termMonths,
    p_frequency: frequency,
    p_terms_version: TERMS_VERSION,
    p_privacy_version: PRIVACY_VERSION,
  });

  if (error) throw error;

  const rows = Array.isArray(data) ? data : data ? [data] : [];

  if (rows.length !== 1)
    throw new Error(`RPC returned ${rows.length} rows; expected exactly one`);

  const row = rows[0];

  if (!row || typeof row.id !== "string" || !row.id.trim())
    throw new Error("RPC returned no valid id");

  if (row.status !== "open")
    throw new Error(`Unexpected IOU status from RPC: ${row.status}`);

  const totalInstallments = Number(row.total_installments);
  const scheduledCount = Number(row.scheduled_count);

  if (!Number.isSafeInteger(totalInstallments) || totalInstallments <= 0)
    throw new Error("RPC returned invalid installment count");

  if (!Number.isSafeInteger(scheduledCount) || scheduledCount <= 0)
    throw new Error("RPC returned invalid scheduled payment count");

  if (scheduledCount !== totalInstallments)
    throw new Error(
      `Schedule incomplete: expected ${totalInstallments} payments, got ${scheduledCount}`
    );

  return { id: row.id };
}

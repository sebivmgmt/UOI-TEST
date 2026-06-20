import { supabase } from "../supabase";
import { sha256HexPaymentReceipt } from "../utils/paymentReceipt";

type PaymentRow = {
  id: string;
  iou_id: string;
  amount_cents: number;
  paid_at: string | null;
  status: string;
};

export async function createPaymentReceipt(paymentId: string) {
  const { data: payment, error: paymentError } = await supabase
    .from("payments")
    .select("id, iou_id, amount_cents, paid_at, status")
    .eq("id", paymentId)
    .single<PaymentRow>();

  if (paymentError) throw paymentError;
  if (!payment) throw new Error("Payment not found");
  if (!payment.paid_at) throw new Error("Payment is missing paid_at");

  const { payload, hash } = await sha256HexPaymentReceipt({
    payment_id: payment.id,
    iou_id: payment.iou_id,
    amount_cents: payment.amount_cents,
    paid_at: payment.paid_at,
    method: "manual",
    currency: "USD",
  });

  const { error } = await supabase.from("payment_receipts").upsert(
    {
      payment_id: payment.id,
      iou_id: payment.iou_id,
      amount_cents: payment.amount_cents,
      currency: "USD",
      method: "manual",
      paid_at: payment.paid_at,
      payload_json: payload,
      receipt_hash: hash,
    },
    { onConflict: "payment_id" }
  );

  if (error) throw error;

  return { hash, payload };
}
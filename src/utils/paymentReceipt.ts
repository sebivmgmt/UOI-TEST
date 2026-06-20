import * as Crypto from "expo-crypto";

export type PaymentReceiptInput = {
  payment_id: string;
  iou_id: string;
  amount_cents: number;
  paid_at: string;
  method?: string;
  currency?: string;
};

function canonicalize(input: any): any {
  if (Array.isArray(input)) return input.map(canonicalize);
  if (input && typeof input === "object") {
    const out: Record<string, any> = {};
    for (const k of Object.keys(input).sort()) out[k] = canonicalize(input[k]);
    return out;
  }
  return input;
}

export function buildPaymentReceiptPayload(input: PaymentReceiptInput) {
  return canonicalize({
    v: 1,
    payment_id: input.payment_id,
    iou_id: input.iou_id,
    amount_cents: input.amount_cents,
    paid_at: input.paid_at,
    method: input.method ?? "manual",
    currency: input.currency ?? "USD",
  });
}

export async function sha256HexPaymentReceipt(
  input: PaymentReceiptInput
): Promise<{ payload: any; hash: string }> {
  const payload = buildPaymentReceiptPayload(input);
  const canon = JSON.stringify(payload);

  const hash = await Crypto.digestStringAsync(
    Crypto.CryptoDigestAlgorithm.SHA256,
    canon
  );

  return { payload, hash };
}
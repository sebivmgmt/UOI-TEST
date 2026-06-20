// src/utils/receipt.ts
import * as Crypto from "expo-crypto";
import { supabase } from "../supabase";

/** Canonical JSON: sort keys recursively so hash is stable */
function canonicalize(input: any): any {
  if (Array.isArray(input)) return input.map(canonicalize);
  if (input && typeof input === "object") {
    const out: Record<string, any> = {};
    for (const k of Object.keys(input).sort()) out[k] = canonicalize(input[k]);
    return out;
  }
  return input;
}

export async function sha256HexCanonical(obj: any): Promise<string> {
  const canon = JSON.stringify(canonicalize(obj));
  const hash = await Crypto.digestStringAsync(
    Crypto.CryptoDigestAlgorithm.SHA256,
    canon
  );
  return hash; // hex
}

/**
 * Create an append-only receipt for an IOU event.
 * eventType examples: 'iou_created' | 'lender_signed' | 'borrower_signed' | 'payment_marked_paid'
 */
export async function recordReceipt(iouId: string, eventType: string, payload: any) {
  const user = (await supabase.auth.getUser()).data.user;
  if (!user) throw new Error("Not signed in");
  const body = {
    iou_id: iouId,
    event_type: eventType,
    payload_json: payload,
    // hash over {iou_id, event_type, payload_json, created_by, created_at: ISO at client time}
    // created_at will be server time, but we include client_ts in payload for determinism
  };

  const client_ts = new Date().toISOString();
  const preimage = { ...body, created_by: user.id, client_ts };
  const hash_sha256 = await sha256HexCanonical(preimage);

  const { error } = await supabase.from("receipts").insert({
    ...body,
    hash_sha256,
    created_by: user.id,
  });
  if (error) throw error;
  return hash_sha256;
}
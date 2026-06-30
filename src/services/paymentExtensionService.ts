// src/services/paymentExtensionService.ts
import { supabase } from '../supabase';

export type PaymentExtensionRow = {
  id: string;
  due_date: string;
  extension_status: string | null;
  extension_requested_until: string | null;
};

export class ExtensionError extends Error {
  readonly userMessage: string;
  readonly raw: unknown;

  constructor(userMessage: string, raw: unknown) {
    super(userMessage);
    this.name = 'ExtensionError';
    this.userMessage = userMessage;
    this.raw = raw;
  }
}

function toUserMessage(raw: unknown): string {
  const msg =
    raw instanceof Error
      ? raw.message
      : typeof raw === 'object' && raw !== null && 'message' in raw
        ? String((raw as { message: unknown }).message)
        : String(raw);

  const m = msg.toLowerCase();

  if (
    m.includes('not authorized') ||
    m.includes('permission denied') ||
    m.includes('only the borrower') ||
    m.includes('only the lender')
  )
    return 'You are not authorized to perform this action.';
  if (m.includes('already paid') || m.includes('payment is paid'))
    return 'This payment has already been paid.';
  if (
    m.includes('not active') ||
    m.includes('iou is not active') ||
    m.includes('iou must be active')
  )
    return 'This IOU is no longer active.';
  if (
    m.includes('14 day') ||
    m.includes('14-day') ||
    m.includes('exceeds the') ||
    m.includes('too far')
  )
    return 'The requested date exceeds the 14-day extension limit.';
  if (
    m.includes('must be in the future') ||
    m.includes('must be after') ||
    m.includes('before due')
  )
    return 'The extension date must be in the future and after the original due date.';
  if (
    m.includes('already requested') ||
    m.includes('pending extension') ||
    m.includes('already pending')
  )
    return 'An extension request is already pending for this payment.';
  if (
    m.includes('already approved') ||
    m.includes('already decided') ||
    m.includes('already denied')
  )
    return 'An extension has already been decided for this payment.';

  return 'Could not process the extension. Please try again.';
}

function extractRow(data: unknown): PaymentExtensionRow {
  const row = Array.isArray(data) ? data[0] : data;
  if (typeof row !== 'object' || row === null)
    throw new Error('Unexpected response from server');
  const r = row as Record<string, unknown>;
  if (typeof r.id !== 'string' || typeof r.due_date !== 'string')
    throw new Error('Unexpected response from server');
  return {
    id: r.id,
    due_date: r.due_date,
    extension_status: typeof r.extension_status === 'string' ? r.extension_status : null,
    extension_requested_until:
      typeof r.extension_requested_until === 'string' ? r.extension_requested_until : null,
  };
}

export async function requestPaymentExtension(
  paymentId: string,
  requestedUntil: string,
  reason: string | null,
): Promise<PaymentExtensionRow> {
  try {
    const { data, error } = await supabase.rpc('request_payment_extension', {
      p_payment_id: paymentId,
      p_requested_until: requestedUntil,
      p_reason: reason,
    });
    if (error) throw error;
    return extractRow(data);
  } catch (e: unknown) {
    if (__DEV__) console.error('[paymentExtensionService] requestPaymentExtension failed', e);
    throw new ExtensionError(toUserMessage(e), e);
  }
}

export async function decidePaymentExtension(
  paymentId: string,
  decision: 'approved' | 'denied',
): Promise<PaymentExtensionRow> {
  try {
    const { data, error } = await supabase.rpc('decide_payment_extension', {
      p_payment_id: paymentId,
      p_decision: decision,
    });
    if (error) throw error;
    return extractRow(data);
  } catch (e: unknown) {
    if (__DEV__) console.error('[paymentExtensionService] decidePaymentExtension failed', e);
    throw new ExtensionError(toUserMessage(e), e);
  }
}

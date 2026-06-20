import { supabase } from '../supabase';
import { ItemAssignment, Participant, ReceiptDraft } from '../context/receiptSplitContext';

function isUUID(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
}

export type PersistedSplit = {
  splitId: string;
  itemDbIdMap: Record<string, string>; // localItemId → receipt_split_items.id
};

export type PersistedParticipants = {
  participantDbIdMap: Record<string, string>; // localParticipantId → receipt_split_participants.id
};

// ─── Step 1: ReceiptReview confirm ────────────────────────────────────────────
// Creates receipt_splits + receipt_split_items in one transaction-like sequence.
// ONLY called from ReceiptReviewScreen.handleContinue — never earlier in the flow.
export async function persistReceiptSplit(draft: ReceiptDraft): Promise<PersistedSplit> {
  const { data: userData } = await supabase.auth.getUser();
  const ownerId = userData.user?.id;
  if (!ownerId) throw new Error('Not authenticated');

  const subtotalCents = draft.items.reduce(
    (sum, it) => sum + Math.round(it.price * 100) * it.quantity,
    0
  );
  const totalCents = subtotalCents + draft.taxCents + draft.tipCents;

  const { data: split, error: splitError } = await supabase
    .from('receipt_splits')
    .insert({
      owner_id: ownerId,
      restaurant_name: draft.restaurantName,
      receipt_date: draft.date,
      image_url: draft.imageUri && draft.imageUri !== 'mock' ? draft.imageUri : null,
      subtotal_cents: subtotalCents,
      tax_cents: draft.taxCents,
      tip_cents: draft.tipCents,
      total_cents: totalCents,
    })
    .select('id')
    .single();
  if (splitError) {
    console.error('[persistReceiptSplit] receipt_splits insert error:', splitError);
    throw splitError;
  }

  const splitId: string = (split as any).id;
  const itemDbIdMap: Record<string, string> = {};

  if (draft.items.length > 0) {
    const itemRows = draft.items.map((it, idx) => {
      const unitPriceCents = Math.round(it.price * 100);
      return {
        receipt_split_id: splitId,
        local_item_id: it.id,
        name: it.name,
        quantity: it.quantity,
        unit_price_cents: unitPriceCents,
        total_price_cents: unitPriceCents * it.quantity,
        sort_order: idx,
      };
    });
    const { data: itemData, error: itemsError } = await supabase
      .from('receipt_split_items')
      .insert(itemRows)
      .select('id, local_item_id');
    if (itemsError) {
      console.error('[persistReceiptSplit] receipt_split_items insert error:', itemsError);
      throw itemsError;
    }
    for (const row of (itemData ?? []) as any[]) {
      itemDbIdMap[row.local_item_id] = row.id;
    }
  }

  return { splitId, itemDbIdMap };
}

// ─── Step 2: ReceiptParticipants confirm ──────────────────────────────────────
// Creates receipt_split_participants.
// Participants without a UUID id (e.g. mock friends) are inserted with user_id = null.
// The generate_ious_from_receipt_split RPC will skip null-user_id rows.
export async function persistParticipants(
  splitId: string,
  participants: Participant[]
): Promise<PersistedParticipants> {
  const rows = participants.map(p => ({
    receipt_split_id: splitId,
    user_id: isUUID(p.id) ? p.id : null,
    name: p.name,
    email: p.email ?? null,
    is_owner: p.isOwner ?? false,
    local_participant_id: p.id,
  }));

  const { data, error } = await supabase
    .from('receipt_split_participants')
    .insert(rows)
    .select('id, local_participant_id');
  if (error) throw error;

  const participantDbIdMap: Record<string, string> = {};
  for (const row of (data ?? []) as any[]) {
    participantDbIdMap[row.local_participant_id] = row.id;
  }
  return { participantDbIdMap };
}

// ─── Step 3: AssignItems (debounced) ─────────────────────────────────────────
// Syncs assignments by deleting all existing rows for this split and re-inserting.
// Called max once per 400 ms while user is editing assignments.
// Skips any participant or item whose DB id is unknown (guards against mapping gaps).
export async function upsertAssignments(
  splitId: string,
  assignments: ItemAssignment[],
  participantDbIdMap: Record<string, string>,
  itemDbIdMap: Record<string, string>
): Promise<void> {
  const { error: deleteError } = await supabase
    .from('receipt_item_assignments')
    .delete()
    .eq('receipt_split_id', splitId);
  if (deleteError) throw deleteError;

  const rows: any[] = [];
  for (const assignment of assignments) {
    const dbItemId = itemDbIdMap[assignment.itemId];
    if (!dbItemId) continue;
    for (const localParticipantId of assignment.participantIds) {
      const dbParticipantId = participantDbIdMap[localParticipantId];
      if (!dbParticipantId) continue;
      rows.push({
        receipt_split_id: splitId,
        item_id: dbItemId,
        participant_id: dbParticipantId,
        split_mode: assignment.splitMode,
        manual_amount_cents:
          assignment.splitMode === 'manual' && assignment.manualAmounts?.[localParticipantId] != null
            ? Math.round((assignment.manualAmounts[localParticipantId]!) * 100)
            : null,
      });
    }
  }

  if (rows.length > 0) {
    const { error } = await supabase.from('receipt_item_assignments').insert(rows);
    if (error) throw error;
  }
}

// ─── Step 4: Recalculate totals (RPC) ────────────────────────────────────────
// Triggers the server to recompute receipt_split_totals for this split.
// The realtime subscription in AssignItems picks up the updated rows automatically.
export async function refreshSplitTotals(splitId: string): Promise<void> {
  const { error } = await supabase.rpc('calculate_receipt_split_totals', {
    p_receipt_split_id: splitId,
  });
  if (error) throw error;
}

// ─── Read receipt_split_totals ────────────────────────────────────────────────
export type SplitTotalRow = {
  local_participant_id: string;
  item_cents: number;
  tax_cents: number;
  tip_cents: number;
  total_cents: number;
  generated_iou_id: string | null;
};

export async function fetchSplitTotals(splitId: string): Promise<SplitTotalRow[]> {
  const { data, error } = await supabase
    .from('receipt_split_totals')
    .select('local_participant_id, item_cents, tax_cents, tip_cents, total_cents, generated_iou_id')
    .eq('receipt_split_id', splitId);
  if (error) throw error;
  return (data ?? []) as SplitTotalRow[];
}

// ─── Step 5: ReceiptSummary "Send IOUs" ───────────────────────────────────────
// Calls generate_ious_from_receipt_split RPC. Server-side rules:
//   - Only receipt owner may call this.
//   - Owner's own share is skipped.
//   - Participants with user_id = null are skipped.
//   - Rows with an existing generated_iou_id are skipped (idempotent).
//   - Each IOU: frequency = 'one_time', status = 'draft', one scheduled payment.
export async function generateIousFromSplit(
  splitId: string,
  dueDate: string
): Promise<{ iou_count: number }> {
  const { data, error } = await supabase.rpc('generate_ious_from_receipt_split', {
    p_receipt_split_id: splitId,
    p_due_date: dueDate,
  });
  if (error) throw error;
  return data as { iou_count: number };
}

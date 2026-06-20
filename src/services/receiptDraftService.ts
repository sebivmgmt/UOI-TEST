import { ReceiptDraft, ReceiptItem } from '../context/receiptSplitContext';

let counter = 2000;
function newId() { return `item-${++counter}-${Date.now()}`; }

export function createDraftItem(name = ''): ReceiptItem {
  return { id: newId(), name, price: 0, quantity: 1 };
}

export function addItemToDraft(draft: ReceiptDraft, item: ReceiptItem): ReceiptDraft {
  return { ...draft, items: [...draft.items, item] };
}

export function removeItemFromDraft(draft: ReceiptDraft, itemId: string): ReceiptDraft {
  return { ...draft, items: draft.items.filter(it => it.id !== itemId) };
}

export function updateDraftItem(
  draft: ReceiptDraft,
  itemId: string,
  patch: Partial<Pick<ReceiptItem, 'name' | 'price' | 'quantity'>>
): ReceiptDraft {
  return {
    ...draft,
    items: draft.items.map(it => it.id === itemId ? { ...it, ...patch } : it),
  };
}

export function updateDraftTax(draft: ReceiptDraft, taxCents: number): ReceiptDraft {
  return { ...draft, taxCents };
}

export function updateDraftTip(draft: ReceiptDraft, tipCents: number): ReceiptDraft {
  return { ...draft, tipCents };
}

export function draftSubtotalCents(draft: ReceiptDraft): number {
  return draft.items.reduce(
    (sum, it) => sum + Math.round(it.price * 100) * it.quantity,
    0
  );
}

export function validateDraft(draft: ReceiptDraft): { valid: boolean; error?: string } {
  if (draft.items.length === 0) return { valid: false, error: 'Add at least one item.' };
  if (draft.items.some(it => !it.name.trim())) return { valid: false, error: 'All items need a name.' };
  return { valid: true };
}

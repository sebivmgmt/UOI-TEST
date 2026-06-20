import { ReceiptDraft } from '../context/receiptSplitContext';

export type ParseResult =
  | { ok: true; draft: ReceiptDraft }
  | { ok: false; error: string };

export async function parseReceiptImage(imageUri: string): Promise<ParseResult> {
  await new Promise(resolve => setTimeout(resolve, 1200));

  const draft: ReceiptDraft = {
    id: `draft-${Date.now()}`,
    restaurantName: 'The Corner Bistro',
    date: new Date().toISOString().split('T')[0],
    imageUri,
    items: [
      { id: 'item-1', name: 'Wagyu Burger', price: 24, quantity: 1 },
      { id: 'item-2', name: 'Truffle Fries', price: 12, quantity: 1 },
      { id: 'item-3', name: 'Caesar Salad', price: 15, quantity: 1 },
      { id: 'item-4', name: 'Nachos', price: 14, quantity: 1 },
      { id: 'item-5', name: 'Craft Beer', price: 9, quantity: 2 },
      { id: 'item-6', name: 'Sparkling Water', price: 6, quantity: 2 },
    ],
    taxCents: 850,
    tipCents: 1500,
  };

  return { ok: true, draft };
}

export function createEmptyDraft(): ReceiptDraft {
  return {
    id: `draft-${Date.now()}`,
    restaurantName: '',
    date: new Date().toISOString().split('T')[0],
    items: [],
    taxCents: 0,
    tipCents: 0,
  };
}

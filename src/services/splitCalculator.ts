import { ItemAssignment, Participant, ReceiptItem } from '../context/receiptSplitContext';

export type ParticipantTotal = {
  participantId: string;
  itemCents: number;
  taxCents: number;
  tipCents: number;
  totalCents: number;
};

export type SplitResult = {
  totals: ParticipantTotal[];
  subtotalCents: number;
  taxCents: number;
  tipCents: number;
  grandTotalCents: number;
};

function toCents(dollars: number): number {
  return Math.round(dollars * 100);
}

export function formatCents(cents: number): string {
  const abs = Math.abs(cents);
  const dollars = Math.floor(abs / 100);
  const remainder = abs % 100;
  const sign = cents < 0 ? '-' : '';
  return `${sign}$${dollars}.${remainder.toString().padStart(2, '0')}`;
}

function largestRemainderRound(shares: number[], total: number): number[] {
  const floored = shares.map(s => Math.floor(s));
  const remainders = shares.map((s, i) => ({ index: i, remainder: s - floored[i] }));
  let remaining = total - floored.reduce((a, b) => a + b, 0);
  remainders.sort((a, b) => b.remainder - a.remainder);
  const result = [...floored];
  for (let i = 0; i < remaining; i++) {
    result[remainders[i].index] += 1;
  }
  return result;
}

export function calculateSplit(
  items: ReceiptItem[],
  participants: Participant[],
  assignments: ItemAssignment[],
  taxCents: number,
  tipCents: number
): SplitResult {
  if (participants.length === 0) {
    return { totals: [], subtotalCents: 0, taxCents, tipCents, grandTotalCents: taxCents + tipCents };
  }

  const itemCentsMap: Record<string, number> = {};
  participants.forEach(p => { itemCentsMap[p.id] = 0; });

  let subtotalCents = 0;

  for (const item of items) {
    const itemTotal = toCents(item.price) * item.quantity;
    subtotalCents += itemTotal;

    const assignment = assignments.find(a => a.itemId === item.id);

    if (!assignment || assignment.participantIds.length === 0) {
      const share = itemTotal / participants.length;
      const shares = participants.map(() => share);
      const rounded = largestRemainderRound(shares, itemTotal);
      participants.forEach((p, i) => { itemCentsMap[p.id] += rounded[i]; });
      continue;
    }

    if (assignment.splitMode === 'manual' && assignment.manualAmounts) {
      assignment.participantIds.forEach(pid => {
        const cents = toCents(assignment.manualAmounts![pid] ?? 0);
        itemCentsMap[pid] = (itemCentsMap[pid] ?? 0) + cents;
      });
      continue;
    }

    const count = assignment.participantIds.length;
    const share = itemTotal / count;
    const shares = assignment.participantIds.map(() => share);
    const rounded = largestRemainderRound(shares, itemTotal);
    assignment.participantIds.forEach((pid, i) => {
      itemCentsMap[pid] = (itemCentsMap[pid] ?? 0) + rounded[i];
    });
  }

  const totalItemCents = Object.values(itemCentsMap).reduce((a, b) => a + b, 0);

  const taxShares: number[] = [];
  const tipShares: number[] = [];

  participants.forEach(p => {
    const ratio = totalItemCents > 0 ? itemCentsMap[p.id] / totalItemCents : 1 / participants.length;
    taxShares.push(taxCents * ratio);
    tipShares.push(tipCents * ratio);
  });

  const taxRounded = largestRemainderRound(taxShares, taxCents);
  const tipRounded = largestRemainderRound(tipShares, tipCents);

  const totals: ParticipantTotal[] = participants.map((p, i) => {
    const ic = itemCentsMap[p.id] ?? 0;
    const tc = taxRounded[i];
    const tipc = tipRounded[i];
    return {
      participantId: p.id,
      itemCents: ic,
      taxCents: tc,
      tipCents: tipc,
      totalCents: ic + tc + tipc,
    };
  });

  const grandTotalCents = subtotalCents + taxCents + tipCents;

  return { totals, subtotalCents, taxCents, tipCents, grandTotalCents };
}

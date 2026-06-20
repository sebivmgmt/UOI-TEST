import { Participant, ReceiptDraft } from '../context/receiptSplitContext';
import { SplitResult } from './splitCalculator';

export type MockIou = {
  id: string;
  fromParticipantId: string;
  toParticipantId: string;
  amountCents: number;
  description: string;
  status: 'pending';
  createdAt: string;
};

export async function generateSplitIous(
  draft: ReceiptDraft,
  participants: Participant[],
  payerId: string,
  splitResult: SplitResult
): Promise<MockIou[]> {
  await new Promise(resolve => setTimeout(resolve, 800));

  const ious: MockIou[] = [];
  const now = new Date().toISOString();

  for (const total of splitResult.totals) {
    if (total.participantId === payerId) continue;
    if (total.totalCents <= 0) continue;

    ious.push({
      id: `iou-split-${Date.now()}-${total.participantId}`,
      fromParticipantId: total.participantId,
      toParticipantId: payerId,
      amountCents: total.totalCents,
      description: `Split: ${draft.restaurantName || 'Restaurant'} — ${draft.date}`,
      status: 'pending',
      createdAt: now,
    });
  }

  return ious;
}

import React, { createContext, useCallback, useContext, useState } from 'react';

export type ReceiptItem = {
  id: string;
  name: string;
  price: number;
  quantity: number;
};

export type Participant = {
  id: string;
  name: string;
  email?: string | null;
  avatar_url?: string | null;
  isOwner?: boolean;
};

export type SplitMode = 'equal' | 'manual';

export type ItemAssignment = {
  itemId: string;
  participantIds: string[];
  splitMode: SplitMode;
  manualAmounts?: Record<string, number>;
};

export type ReceiptDraft = {
  id: string;
  splitId?: string; // DB receipt_splits.id — set after ReceiptReview persist
  restaurantName: string;
  date: string;
  imageUri?: string;
  items: ReceiptItem[];
  taxCents: number;
  tipCents: number;
};

export type ReceiptSplitState = {
  draft: ReceiptDraft | null;
  participants: Participant[];
  payerId: string | null;
  assignments: ItemAssignment[];
  // DB id maps populated after each persistence step
  itemDbIdMap: Record<string, string>;        // localItemId → receipt_split_items.id
  participantDbIdMap: Record<string, string>; // localParticipantId → receipt_split_participants.id
};

type ReceiptSplitContextValue = ReceiptSplitState & {
  setDraft: (draft: ReceiptDraft | null) => void;
  setParticipants: (participants: Participant[]) => void;
  setPayerId: (id: string | null) => void;
  setAssignments: (assignments: ItemAssignment[]) => void;
  updateAssignment: (assignment: ItemAssignment) => void;
  setItemDbIdMap: (map: Record<string, string>) => void;
  setParticipantDbIdMap: (map: Record<string, string>) => void;
  reset: () => void;
};

const defaultState: ReceiptSplitState = {
  draft: null,
  participants: [],
  payerId: null,
  assignments: [],
  itemDbIdMap: {},
  participantDbIdMap: {},
};

const ReceiptSplitContext = createContext<ReceiptSplitContextValue | null>(null);

export function ReceiptSplitProvider({ children }: { children: React.ReactNode }) {
  const [state, setState] = useState<ReceiptSplitState>(defaultState);

  const setDraft = useCallback((draft: ReceiptDraft | null) => {
    setState(prev => ({ ...prev, draft }));
  }, []);

  const setParticipants = useCallback((participants: Participant[]) => {
    setState(prev => ({ ...prev, participants }));
  }, []);

  const setPayerId = useCallback((payerId: string | null) => {
    setState(prev => ({ ...prev, payerId }));
  }, []);

  const setAssignments = useCallback((assignments: ItemAssignment[]) => {
    setState(prev => ({ ...prev, assignments }));
  }, []);

  const updateAssignment = useCallback((assignment: ItemAssignment) => {
    setState(prev => {
      const existing = prev.assignments.findIndex(a => a.itemId === assignment.itemId);
      if (existing >= 0) {
        const next = [...prev.assignments];
        next[existing] = assignment;
        return { ...prev, assignments: next };
      }
      return { ...prev, assignments: [...prev.assignments, assignment] };
    });
  }, []);

  const setItemDbIdMap = useCallback((map: Record<string, string>) => {
    setState(prev => ({ ...prev, itemDbIdMap: map }));
  }, []);

  const setParticipantDbIdMap = useCallback((map: Record<string, string>) => {
    setState(prev => ({ ...prev, participantDbIdMap: map }));
  }, []);

  const reset = useCallback(() => {
    setState(defaultState);
  }, []);

  return (
    <ReceiptSplitContext.Provider
      value={{ ...state, setDraft, setParticipants, setPayerId, setAssignments, updateAssignment, setItemDbIdMap, setParticipantDbIdMap, reset }}
    >
      {children}
    </ReceiptSplitContext.Provider>
  );
}

export function useReceiptSplit(): ReceiptSplitContextValue {
  const ctx = useContext(ReceiptSplitContext);
  if (!ctx) throw new Error('useReceiptSplit must be used within ReceiptSplitProvider');
  return ctx;
}

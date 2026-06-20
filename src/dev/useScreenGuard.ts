// src/dev/useScreenGuard.ts
import { useEffect } from 'react';
import { setDevState } from './DevOverlay';

export type GuardCheck = { label: string; pass: boolean; note?: string };

export function useScreenGuard(screen: string, checks: GuardCheck[]) {
  useEffect(() => {
    setDevState(screen, checks);
  }, [screen, JSON.stringify(checks)]);
}

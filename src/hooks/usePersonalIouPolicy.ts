import { useState, useEffect, useCallback, useRef } from "react";
import { fetchPersonalIouPolicy } from "../services/personalIouPolicyService";

export type PersonalIouPolicyStatus =
  | "supported"
  | "missing_state"
  | "unsupported_state"
  | "unavailable";

export type PersonalIouPolicyResult = {
  policyStatus: PersonalIouPolicyStatus | null;
  supported: boolean;
  maxAprBps: number | null;
  policyVersion: string | null;
  policyEffectiveAt: string | null;
  loading: boolean;
  error: string | null;
  refresh: () => Promise<void>;
};

export function usePersonalIouPolicy(
  borrowerId: string | null | undefined
): PersonalIouPolicyResult {
  const [policyStatus, setPolicyStatus] =
    useState<PersonalIouPolicyStatus | null>(null);
  const [supported, setSupported] = useState(false);
  const [maxAprBps, setMaxAprBps] = useState<number | null>(null);
  const [policyVersion, setPolicyVersion] = useState<string | null>(null);
  const [policyEffectiveAt, setPolicyEffectiveAt] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Monotonic counter — incremented on each fetch; stale responses are discarded.
  const fetchIdRef = useRef(0);

  const doFetch = useCallback(async (bid: string) => {
    const fetchId = ++fetchIdRef.current;

    setPolicyStatus(null);
    setSupported(false);
    setMaxAprBps(null);
    setPolicyVersion(null);
    setPolicyEffectiveAt(null);
    setError(null);
    setLoading(true);

    try {
      const policy = await fetchPersonalIouPolicy(bid);

      if (fetchIdRef.current !== fetchId) return;

      setPolicyStatus(policy.policyStatus);
      setSupported(policy.supported);
      setMaxAprBps(policy.maxAprBps);
      setPolicyVersion(policy.policyVersion);
      setPolicyEffectiveAt(policy.policyEffectiveAt);
    } catch {
      if (fetchIdRef.current !== fetchId) return;
      setError("policy_fetch_failed");
    } finally {
      if (fetchIdRef.current === fetchId) {
        setLoading(false);
      }
    }
  }, []);

  useEffect(() => {
    if (!borrowerId) {
      fetchIdRef.current++;
      setPolicyStatus(null);
      setSupported(false);
      setMaxAprBps(null);
      setPolicyVersion(null);
      setPolicyEffectiveAt(null);
      setLoading(false);
      setError(null);
      return;
    }
    void doFetch(borrowerId);
  }, [borrowerId, doFetch]);

  const refresh = useCallback(async () => {
    if (borrowerId) await doFetch(borrowerId);
  }, [borrowerId, doFetch]);

  return {
    policyStatus,
    supported,
    maxAprBps,
    policyVersion,
    policyEffectiveAt,
    loading,
    error,
    refresh,
  };
}

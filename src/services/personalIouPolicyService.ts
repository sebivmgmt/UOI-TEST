import { supabase } from "../supabase";

export type PersonalIouPolicyStatus =
  | "supported"
  | "missing_state"
  | "unsupported_state"
  | "unavailable";

export type PersonalIouPolicy = {
  policyStatus: PersonalIouPolicyStatus;
  supported: boolean;
  maxAprBps: number | null;
  policyVersion: string | null;
  policyEffectiveAt: string | null;
};

const NON_SUPPORTED_STATUSES = new Set<string>([
  "missing_state",
  "unsupported_state",
  "unavailable",
]);

function parseAndValidate(raw: unknown): PersonalIouPolicy {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("policy_resolution_failed");
  }

  const r = raw as Record<string, unknown>;

  if (typeof r.policy_status !== "string") {
    throw new Error("policy_resolution_failed");
  }
  if (typeof r.supported !== "boolean") {
    throw new Error("policy_resolution_failed");
  }

  const supported = r.supported;
  const statusStr = r.policy_status;

  if (supported) {
    // supported branch: status must be exactly "supported" — reject contradictory combos
    if (statusStr !== "supported") {
      throw new Error("policy_resolution_failed");
    }
    const bps = r.max_apr_bps;
    if (
      typeof bps !== "number" ||
      !Number.isFinite(bps) ||
      !Number.isInteger(bps) ||
      bps < 0
    ) {
      throw new Error("policy_resolution_failed");
    }
    // trim() rejects whitespace-only strings
    if (typeof r.policy_version !== "string" || !r.policy_version.trim()) {
      throw new Error("policy_resolution_failed");
    }
    if (typeof r.policy_effective_at !== "string" || !r.policy_effective_at.trim()) {
      throw new Error("policy_resolution_failed");
    }
    return {
      policyStatus: "supported",
      supported: true,
      maxAprBps: bps,
      policyVersion: r.policy_version,
      policyEffectiveAt: r.policy_effective_at,
    };
  } else {
    // non-supported branch: status must be one of the non-supported values — reject contradictory combos
    if (!NON_SUPPORTED_STATUSES.has(statusStr)) {
      throw new Error("policy_resolution_failed");
    }
    // all three payload fields must be null (not just absent)
    if (r.max_apr_bps != null) throw new Error("policy_resolution_failed");
    if (r.policy_version != null) throw new Error("policy_resolution_failed");
    if (r.policy_effective_at != null) throw new Error("policy_resolution_failed");
    return {
      policyStatus: statusStr as PersonalIouPolicyStatus,
      supported: false,
      maxAprBps: null,
      policyVersion: null,
      policyEffectiveAt: null,
    };
  }
}

export async function fetchPersonalIouPolicy(borrowerId: string): Promise<PersonalIouPolicy> {
  if (!borrowerId || !borrowerId.trim()) {
    throw new Error("policy_resolution_failed");
  }

  const { data, error } = await supabase.rpc("get_personal_iou_policy", {
    p_borrower_id: borrowerId,
  });

  if (error) {
    throw new Error("policy_resolution_failed");
  }

  return parseAndValidate(data);
}

import { supabase } from "../supabase";

export type OfficialScoreV22 = {
  user_id: string;
  model_version: string;
  public_score: number;
  visible_trust: number;
  trust_tier: string;
  active_exposure_points: number;
};

export type MyScoreV22 = {
  shadow_score: number;
  visible_trust: number;
  trust_tier: string;
  active_exposure_points: number;
  model_version: string;
};

function isMyScoreV22(v: unknown): v is MyScoreV22 {
  if (typeof v !== "object" || v === null) return false;
  const r = v as Record<string, unknown>;
  return (
    typeof r.shadow_score === "number" &&
    typeof r.visible_trust === "number" &&
    typeof r.trust_tier === "string" &&
    typeof r.active_exposure_points === "number" &&
    typeof r.model_version === "string"
  );
}

function isOfficialScoreV22(v: unknown): v is OfficialScoreV22 {
  if (typeof v !== "object" || v === null) return false;
  const r = v as Record<string, unknown>;
  return (
    typeof r.user_id === "string" &&
    typeof r.model_version === "string" &&
    typeof r.public_score === "number" &&
    typeof r.visible_trust === "number" &&
    typeof r.trust_tier === "string" &&
    typeof r.active_exposure_points === "number"
  );
}

// Maps a backend trust_tier string to a display color.
// Driven by backend tier, not score thresholds.
export function tierColor(tier: string | null | undefined, colors: {
  strong: string;
  rising: string;
  starter: string;
  watch: string;
  muted: string;
  critical: string;
}): string {
  if (!tier) return colors.muted;
  const t = tier.toLowerCase();
  if (t.includes("strong") || t === "lending") return colors.strong;
  if (t === "rising") return colors.rising;
  if (t === "starter") return colors.starter;
  if (t === "watch") return colors.watch;
  return colors.critical;
}

// Formats a trust_tier string for display (capitalize first letter, replace underscores).
export function formatTierLabel(tier: string | null | undefined): string {
  if (!tier) return "—";
  const s = tier.replace(/_/g, " ");
  return s.charAt(0).toUpperCase() + s.slice(1);
}

// Own score — calls get_my_current_trust_score. Returns null on any failure.
export async function getMyOfficialIouScoreV22(): Promise<MyScoreV22 | null> {
  const { data, error } = await supabase.rpc("get_my_current_trust_score");
  if (error || !data) return null;
  const row = Array.isArray(data) ? data[0] : data;
  return isMyScoreV22(row) ? row : null;
}

// Single other-user score. Returns null for unknown user or on failure.
export async function getPublicIouScoreV22(userId: string): Promise<OfficialScoreV22 | null> {
  const { data, error } = await supabase.rpc("get_public_iou_score_v22", {
    p_user_id: userId,
  });
  if (error || !data) return null;
  const row = Array.isArray(data) ? data[0] : data;
  return isOfficialScoreV22(row) ? row : null;
}

// Batch other-user scores. Returns Map keyed by user_id; absent for unknown users or on failure.
export async function getPublicIouScoresV22(
  userIds: string[]
): Promise<Map<string, OfficialScoreV22>> {
  const result = new Map<string, OfficialScoreV22>();
  const deduped = [...new Set(userIds.filter(Boolean))];
  if (!deduped.length) return result;
  const { data, error } = await supabase.rpc("get_public_iou_scores_v22", {
    p_user_ids: deduped,
  });
  if (error || !data) return result;
  for (const row of Array.isArray(data) ? data : []) {
    if (isOfficialScoreV22(row)) result.set(row.user_id, row);
  }
  return result;
}

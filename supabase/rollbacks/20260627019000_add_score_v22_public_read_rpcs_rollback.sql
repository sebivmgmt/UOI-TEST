-- ============================================================================
-- Rollback: Score v2.2 Public Read RPCs
-- Reverts: 20260627019000_add_score_v22_public_read_rpcs.sql
-- DEV project only: colkilearqxuyldzjutw
--
-- What this rollback does:
--   1. Drops get_public_iou_scores_v22(uuid[]) first (batch RPC)
--   2. Drops get_public_iou_score_v22(uuid) second (single-user RPC)
--
-- What this rollback does NOT do:
--   - Does not alter or remove the official-read cutover
--     (score_v22_current_state_internal, get_my_current_trust_score,
--      trust_report_shadow_v, get_trust_report_for_viewer are unchanged)
--   - Does not modify profiles.iou_score or profiles.active_exposure_points
--   - Does not delete v2.2 evidence (score_v2_contributions, trust_outcome_events,
--     score_agreements, trust_score_snapshots)
-- ============================================================================

-- Drop batch RPC first (no dependency on the single-user RPC)
drop function if exists public.get_public_iou_scores_v22(uuid[]);

-- Drop single-user RPC second
drop function if exists public.get_public_iou_score_v22(uuid);

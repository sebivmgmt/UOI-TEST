-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: add_iou_apr_cap_constraint
-- Created:   2026-05-24
-- Status:    Already applied to remote. This file records the change in
--            migration history so the repo matches the live database state.
--
-- Adds a conservative platform APR cap of 16% (1600 bps) to the ious table.
-- Backend is authoritative; the frontend STANDARD_IOU_MAX_APR_PCT = 16 in
-- iouOptions.ts mirrors this constraint as a UX guard only.
--
-- NOT VALID: one legacy open IOU exists with apr_bps = 1700 (17.00% APR)
-- and matching stored contract_text. That row is intentionally excluded from
-- validation — retroactively constraining it would make the stored contract
-- text inaccurate. The constraint applies to all future inserts and updates.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_constraint WHERE conname = 'ious_apr_bps_standard_cap_check'
  ) THEN
    ALTER TABLE public.ious
      ADD CONSTRAINT ious_apr_bps_standard_cap_check
        CHECK (apr_bps IS NULL OR (apr_bps >= 0 AND apr_bps <= 1600))
        NOT VALID;
  END IF;
END;
$$;

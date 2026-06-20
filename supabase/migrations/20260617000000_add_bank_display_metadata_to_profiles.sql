-- Add bank display metadata columns to profiles.
--
-- These fields are written exclusively by the dwolla-attach-funding-source Edge
-- Function after confirmed Dwolla funding-source attachment. The client must not
-- write them. Column-level UPDATE privileges are revoked from the authenticated
-- role, matching the pattern established for ach_status / phone_verified /
-- identity_status / iou_score.
--
-- Schema state as of 2026-06-18:
--   bank_name     — exists (verified against live dev schema)
--   account_mask  — exists (verified against live dev schema)
--   bank_provider — not present; added here
--   bank_account_mask — not present; added here
--
-- All four ADD COLUMN statements use IF NOT EXISTS and are safe to re-run.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS bank_provider         TEXT,
  ADD COLUMN IF NOT EXISTS bank_account_mask     TEXT,
  ADD COLUMN IF NOT EXISTS account_mask          TEXT,
  ADD COLUMN IF NOT EXISTS bank_name             TEXT;

-- Revoke client UPDATE privilege on bank display columns.
-- REVOKE is a no-op if the privilege was never granted; safe to re-run.
REVOKE UPDATE (bank_provider, bank_account_mask, account_mask, bank_name)
  ON public.profiles
  FROM authenticated;

-- Revoke client UPDATE privilege on bank-linking columns.
-- These may already be revoked by a prior profiles-security migration.
-- Re-running REVOKE is safe and idempotent in PostgreSQL.
REVOKE UPDATE (bank_linked, plaid_linked, plaid_account_id, plaid_institution_name)
  ON public.profiles
  FROM authenticated;

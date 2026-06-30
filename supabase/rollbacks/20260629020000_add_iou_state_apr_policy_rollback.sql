-- Rollback for:
--   20260629020000_add_iou_state_apr_policy.sql
--
-- This removes only the new jurisdiction-policy infrastructure. It does not
-- alter profiles.state, existing APR values, legal documents, or Score v2.2.

begin;

drop trigger if exists ious_state_apr_policy_enforcement_trg
  on public.ious;

drop function if exists public.enforce_iou_state_apr_policy();

alter table public.ious
  drop constraint if exists
    ious_state_policy_snapshot_completeness_check,
  drop constraint if exists
    ious_borrower_max_apr_bps_check,
  drop constraint if exists
    ious_borrower_state_code_check;

alter table public.ious
  drop column if exists state_policy_effective_at,
  drop column if exists state_policy_version,
  drop column if exists borrower_max_apr_bps,
  drop column if exists borrower_state_code;

drop table if exists public.iou_state_apr_policy;

commit;

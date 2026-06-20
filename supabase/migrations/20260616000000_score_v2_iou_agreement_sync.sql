-- IOU Score v2 — IOU → score_agreements synchronization
--
-- Problem:
-- score_agreements rows were only ever populated by a one-time backfill
-- (20260526008000) and a one-time same-pair recalculation (20260526009000).
-- Both incorrectly derived status from ious.archived_at / a raw 'open' check,
-- and nothing has kept score_agreements in sync with ious since. Archiving
-- and restoring an IOU left its shadow agreement permanently stale.
--
-- Fix:
-- A single reusable function, sync_score_agreement_for_iou(), becomes the
-- only writer of derived score_agreements status/ceiling/metadata going
-- forward. It is invoked by triggers on ious (insert, and update of
-- financially-meaningful columns only) and by a one-time backfill pass at
-- the bottom of this migration that re-syncs every existing personal IOU
-- through the exact same code path — not a separate correction formula.
--
-- Product rule (do not violate):
-- Archiving is personal organization only. ious.archived_at / is_archived
-- must NEVER affect score_agreements.status, score_ceiling, outcome
-- history, or exposure. They are intentionally excluded from both the
-- status CASE expression below and the update-trigger's WHEN clause.
--
-- This migration does NOT:
--   * touch profiles.iou_score or any live score
--   * apply score contributions (score_contributed is preserved, never set)
--   * touch payments, pay_and_receipt(), outcome logging, or trust_outcome_events
--   * change any Score v2 math (score_v2_obligation_weight / score_v2_score_ceiling
--     / score_v2_same_pair_multiplier are reused exactly as-is)
--   * address the legacy exposure/archive problem (recompute_iou_exposure) — deferred
--
-- Safe to re-run: function bodies use CREATE OR REPLACE, triggers are
-- dropped and recreated, and the backfill pass goes through the same
-- conflict-safe upsert as ordinary runtime syncs.

begin;

-- ── 1. sync_score_agreement_for_iou ──────────────────────────────────────────
--
-- Loads one IOU, derives its score_agreements lifecycle status purely from
-- financial fields, and upserts the personal_iou shadow agreement.
--
-- Lifecycle (financial fields only — archived_at/is_archived never read):
--   cancelled  -> deleted_at is not null, or status in ('canceled','cancelled')
--   completed  -> status = 'paid'
--   active     -> activated_at is not null and status in ('open','late')
--   draft      -> everything else, including an unactivated 'open' IOU
--
-- score_ceiling is forced to 0 only for 'cancelled' rows.
-- score_contributed is intentionally omitted from the DO UPDATE SET list
-- so existing values are always preserved on conflict.
create or replace function public.sync_score_agreement_for_iou(p_iou_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_iou public.ious%rowtype;
  v_status text;
  v_agreement_id uuid;

  v_existing_id uuid;
  v_old_user_id uuid;
  v_old_counterparty_id uuid;

  v_proof_tier integer := 1;
  v_verification_tier integer := 1;

  v_existing_metadata jsonb := '{}'::jsonb;
  v_sync_metadata jsonb := '{}'::jsonb;
begin
  if p_iou_id is null then
    return null;
  end if;

  select *
  into v_iou
  from public.ious
  where id = p_iou_id
  for update;

  if not found then
    return null;
  end if;

  select
    sa.id,
    sa.user_id,
    sa.counterparty_id,
    coalesce(sa.proof_tier, 1),
    coalesce(sa.verification_tier, 1),
    coalesce(sa.metadata, '{}'::jsonb)
  into
    v_existing_id,
    v_old_user_id,
    v_old_counterparty_id,
    v_proof_tier,
    v_verification_tier,
    v_existing_metadata
  from public.score_agreements sa
  where sa.source_type = 'personal_iou'
    and sa.source_id = p_iou_id
  for update;

  if not found then
    v_existing_id := null;
    v_old_user_id := null;
    v_old_counterparty_id := null;
    v_proof_tier := 1;
    v_verification_tier := 1;
    v_existing_metadata := '{}'::jsonb;
  end if;

  if v_iou.borrower_id is null
     or v_iou.lender_id is null then

    if v_existing_id is not null then
      update public.score_agreements
      set
        status = 'cancelled',
        score_ceiling = 0,
        metadata =
          (coalesce(metadata, '{}'::jsonb) - 'archived_at')
          || jsonb_build_object(
            'legacy_status',
            v_iou.status,
            'derived_score_status',
            'cancelled',
            'source_eligible',
            false,
            'deleted_at',
            v_iou.deleted_at,
            'inactive_shadow_ceiling_zeroed',
            true,
            'synced_at',
            now(),
            'sync_source',
            'sync_score_agreement_for_iou'
          )
      where id = v_existing_id;

      perform public.recalculate_score_v2_personal_iou_pair(
        v_old_user_id,
        v_old_counterparty_id
      );
    end if;

    return v_existing_id;
  end if;

  -- ── Financial-truth-only status derivation ──────────────────────────────
  -- archived_at / is_archived are intentionally NOT referenced here.
  v_status :=
    case
      when v_iou.deleted_at is not null
        or v_iou.status in ('canceled', 'cancelled')
        then 'cancelled'

      when v_iou.status = 'paid'
        then 'completed'

      when v_iou.activated_at is not null
        and v_iou.status in ('open', 'late')
        then 'active'

      else 'draft'
    end;

  v_sync_metadata :=
    (coalesce(v_existing_metadata, '{}'::jsonb) - 'archived_at')
    || jsonb_build_object(
      'source_table',
      'ious',
      'legacy_status',
      v_iou.status,
      'derived_score_status',
      v_status,
      'source_eligible',
      true,
      'title',
      v_iou.title,
      'apr_bps',
      v_iou.apr_bps,
      'source_created_at',
      v_iou.created_at,
      'deleted_at',
      v_iou.deleted_at,
      'inactive_shadow_ceiling_zeroed',
      (v_status = 'cancelled'),
      'synced_at',
      now(),
      'sync_source',
      'sync_score_agreement_for_iou'
    );

  if v_existing_id is null then
    v_sync_metadata :=
      v_sync_metadata
      || jsonb_build_object(
        'shadow_backfill',
        false
      );
  end if;

  insert into public.score_agreements (
    user_id,
    source_type,
    source_id,
    counterparty_id,
    amount_cents,
    term_months,
    frequency,
    status,
    proof_tier,
    verification_tier,
    obligation_weight,
    score_ceiling,
    score_contributed,
    same_pair_index,
    same_pair_multiplier,
    activated_at,
    completed_at,
    metadata
  )
  values (
    v_iou.borrower_id,
    'personal_iou',
    v_iou.id,
    v_iou.lender_id,
    v_iou.principal_cents,
    v_iou.term_months,
    v_iou.frequency,
    v_status,
    v_proof_tier,
    v_verification_tier,
    public.score_v2_obligation_weight(
      'personal_iou',
      v_iou.principal_cents,
      v_iou.term_months,
      v_iou.frequency,
      v_proof_tier,
      v_verification_tier,
      1,
      v_sync_metadata
    ),
    case
      when v_status = 'cancelled'
        then 0
      else public.score_v2_score_ceiling(
        'personal_iou',
        v_iou.principal_cents,
        v_iou.term_months,
        v_iou.frequency,
        v_proof_tier,
        v_verification_tier,
        1,
        v_sync_metadata
      )
    end,
    0,
    1,
    public.score_v2_same_pair_multiplier(1),
    v_iou.activated_at,
    case
      when v_status = 'completed'
        then now()
      else null
    end,
    v_sync_metadata
  )
  on conflict (source_id)
    where source_type = 'personal_iou'
      and source_id is not null
  do update set
    user_id = excluded.user_id,
    counterparty_id = excluded.counterparty_id,
    amount_cents = excluded.amount_cents,
    term_months = excluded.term_months,
    frequency = excluded.frequency,
    status = excluded.status,
    activated_at = excluded.activated_at,
    completed_at =
      case
        when excluded.status = 'completed'
          then coalesce(
            public.score_agreements.completed_at,
            excluded.completed_at
          )
        else null
      end,
    -- score_contributed deliberately omitted — never overwritten.
    metadata = excluded.metadata
  returning id
  into v_agreement_id;

  if v_old_user_id is not null
     and v_old_counterparty_id is not null
     and (
       v_old_user_id is distinct from v_iou.borrower_id
       or v_old_counterparty_id
         is distinct from v_iou.lender_id
     ) then

    perform public.recalculate_score_v2_personal_iou_pair(
      v_old_user_id,
      v_old_counterparty_id
    );
  end if;

  perform public.recalculate_score_v2_personal_iou_pair(
    v_iou.borrower_id,
    v_iou.lender_id
  );

  return v_agreement_id;
end;
$function$;

revoke execute on function public.sync_score_agreement_for_iou(uuid) from public;
grant execute on function public.sync_score_agreement_for_iou(uuid) to service_role;


-- ── 2. Trigger wrapper ────────────────────────────────────────────────────
create or replace function public.trg_sync_score_agreement_for_iou()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.sync_score_agreement_for_iou(new.id);
  return new;
end;
$function$;


-- ── 3. Triggers ───────────────────────────────────────────────────────────
--
-- AFTER INSERT: every newly created IOU gets a shadow agreement immediately.
drop trigger if exists ious_score_agreement_sync_insert_trg on public.ious;
create trigger ious_score_agreement_sync_insert_trg
  after insert on public.ious
  for each row
  execute function public.trg_sync_score_agreement_for_iou();

-- AFTER UPDATE: only fires for columns that affect financial/scoring truth.
-- archived_at and is_archived are intentionally absent from the UPDATE OF
-- clause and WHEN clause — archiving/unarchiving an IOU must never touch
-- score_agreements.
drop trigger if exists ious_score_agreement_sync_update_trg on public.ious;
create trigger ious_score_agreement_sync_update_trg
  after update of status, deleted_at, activated_at, borrower_id, lender_id,
    principal_cents, term_months, frequency, apr_bps, title
  on public.ious
  for each row
  when (
    new.status is distinct from old.status
    or new.deleted_at is distinct from old.deleted_at
    or new.activated_at is distinct from old.activated_at
    or new.borrower_id is distinct from old.borrower_id
    or new.lender_id is distinct from old.lender_id
    or new.principal_cents is distinct from old.principal_cents
    or new.term_months is distinct from old.term_months
    or new.frequency is distinct from old.frequency
    or new.apr_bps is distinct from old.apr_bps
    or new.title is distinct from old.title
  )
  execute function public.trg_sync_score_agreement_for_iou();


-- ── 4. One-time backfill through the same function ──────────────────────────
--
-- Re-syncs every existing personal IOU via sync_score_agreement_for_iou —
-- the same code path triggers will use going forward. No separate formula.
-- On a fresh DEV database this processes zero rows cleanly.
select public.sync_score_agreement_for_iou(i.id)
from public.ious i
where i.borrower_id is not null
  and i.lender_id is not null;

commit;

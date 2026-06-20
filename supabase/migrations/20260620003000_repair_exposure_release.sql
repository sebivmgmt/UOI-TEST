begin;
-- ---------------------------------------------------------------------------
-- Migration: Repair exposure release
-- ---------------------------------------------------------------------------
-- Root cause: loan_exposure_release_trigger was disabled, and
-- handle_exposure_release() used a broken subtraction formula —
-- ceil(principal_cents / 10000) — which performs integer division and
-- produces 0 for any principal below $100.  Nothing called
-- recalculate_profile_exposure() after completion.
--
-- Fix:
--   1. Replace handle_exposure_release() to delegate entirely to
--      recompute_iou_exposure(), which is status-aware and pro-rates
--      against remaining unpaid principal.  It does not depend on
--      ious.status already being updated.
--   2. Drop and recreate loan_exposure_release_trigger with the correct
--      null-to-non-null WHEN guard and enable it.
--   3. One-time backfill: call recompute_iou_exposure() for every
--      activated IOU to zero stale exposure on paid/deleted/archived
--      obligations and re-pro-rate active ones.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. Replace the trigger function
-- ---------------------------------------------------------------------------
create or replace function public.handle_exposure_release()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  -- Defensive guard: only act when paid_at transitions null → non-null.
  -- The WHEN clause on the trigger already enforces this at the engine
  -- level; this guard makes the function safe if called directly.
  if new.paid_at is null then
    return new;
  end if;
  if old.paid_at is not null then
    return new;
  end if;

  -- Delegate entirely to the canonical, status-aware function.
  -- recompute_iou_exposure():
  --   • zeros ious.exposure_points when status=paid/deleted/archived, or
  --     when no unpaid balance remains;
  --   • pro-rates for active IOUs with partial remaining balance;
  --   • always calls recalculate_profile_exposure() to re-sum the profile
  --     from current IOU state — never directly mutates the profile.
  perform public.recompute_iou_exposure(new.iou_id);

  return new;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2. Recreate and enable the trigger
-- ---------------------------------------------------------------------------
drop trigger if exists loan_exposure_release_trigger on public.payments;

create trigger loan_exposure_release_trigger
  after update of paid_at
  on public.payments
  for each row
  when (
    new.paid_at is not null
    and old.paid_at is distinct from new.paid_at
  )
  execute function public.handle_exposure_release();

-- ---------------------------------------------------------------------------
-- 3. One-time reconciliation of all activated IOUs
--    recompute_iou_exposure() handles each case:
--      - paid / deleted / archived  → exposure_points = 0, profile zeroed
--      - active with no balance     → exposure_points = 0, profile zeroed
--      - active with remaining      → pro-rated, profile re-summed
-- ---------------------------------------------------------------------------
do $$
declare
  v_iou_id uuid;
begin
  for v_iou_id in
    select id
    from public.ious
    where activated_at is not null
    order by activated_at
  loop
    perform public.recompute_iou_exposure(v_iou_id);
  end loop;
end;
$$;

commit;
